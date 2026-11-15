#!/usr/bin/env bash
# Canonical native build and test recipe for the Dubbing iOS app.
#
#   scripts/qa/ios-build-test.sh [all|build|test]
#
#   build  resolve packages, build the shared Dubbing scheme for an iOS 26.x
#          simulator, and stage Dubbing.app (plus a zip) at a stable path
#   test   resolve packages and run the DubbingTests unit tests (this builds
#          too, and stages the app)
#   all    build, then test (default)
#
# Works from a fresh checkout on any Mac with Xcode 26+ and on Revyl's runner.
# It never edits the Xcode project, scheme, or build settings.
#
# Environment overrides (all optional):
#   QA_SIM_UDID       exact simulator UDID; skips automatic selection
#   QA_SIM_DEVICE     simulator model name (default "iPhone 17 Pro")
#   QA_SIM_RUNTIME    preferred iOS runtime version (default "26.5"); when it is
#                     not installed the highest installed iOS 26.x is used
#   QA_OUT_DIR        results directory (default <repo>/build/qa)
#   QA_DERIVED_DATA   derived data path (default <repo>/build/DerivedData)
#   QA_CONFIGURATION  Xcode build configuration (default "Debug")
#   QA_COMMIT_SHA     commit to record in the summary when there is no .git
#                     (Revyl uploads a workspace archive without .git)
#
# Outputs in QA_OUT_DIR: summary.txt, resolve.log, build.log, test.log,
# build.xcresult, test.xcresult, Dubbing.app, Dubbing.app.zip.
# Exit codes: 0 success, 1 build or test failure, 2 environment or usage error.

set -euo pipefail

MODE="${1:-all}"
case "$MODE" in
  all | build | test) ;;
  *)
    echo "usage: $0 [all|build|test]" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="Dubbing.xcodeproj"
SCHEME="Dubbing"
TEST_TARGET="DubbingTests"
CONFIGURATION="${QA_CONFIGURATION:-Debug}"
OUT_DIR="${QA_OUT_DIR:-$ROOT/build/qa}"
DERIVED_DATA="${QA_DERIVED_DATA:-$ROOT/build/DerivedData}"
PACKAGES_DIR="$ROOT/build/SourcePackages"
WANT_DEVICE="${QA_SIM_DEVICE:-iPhone 17 Pro}"
WANT_RUNTIME="${QA_SIM_RUNTIME:-26.5}"
APP_BUILT="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphonesimulator/Dubbing.app"

fail_env() {
  echo "error: $*" >&2
  exit 2
}

command -v xcodebuild >/dev/null 2>&1 || fail_env "xcodebuild not found; this script needs macOS with Xcode 26 or newer"
command -v xcrun >/dev/null 2>&1 || fail_env "xcrun not found; this script needs macOS with Xcode 26 or newer"

XCODE_VERSION_LINES="$(xcodebuild -version 2>&1)" || fail_env "xcodebuild -version failed: $XCODE_VERSION_LINES"
XCODE_VERSION="$(printf '%s\n' "$XCODE_VERSION_LINES" | tr '\n' ' ' | sed 's/ *$//')"
XCODE_MAJOR="$(printf '%s\n' "$XCODE_VERSION_LINES" | sed -n 's/^Xcode \([0-9]*\).*/\1/p' | head -n 1)"
[ "${XCODE_MAJOR:-0}" -ge 26 ] || fail_env "Xcode 26 or newer is required (found: $XCODE_VERSION)"

COMMIT_SHA="${QA_COMMIT_SHA:-}"
if [ -z "$COMMIT_SHA" ]; then
  COMMIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "unknown (no .git; set QA_COMMIT_SHA)")"
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/build.xcresult" "$OUT_DIR/test.xcresult" "$OUT_DIR/Dubbing.app" "$OUT_DIR/Dubbing.app.zip" \
  "$OUT_DIR/summary.txt" "$OUT_DIR/resolve.log" "$OUT_DIR/build.log" "$OUT_DIR/test.log"

# Prints "<ios version>|<device name>|<udid>" for every available iOS simulator.
list_ios_devices() {
  xcrun simctl list devices available | awk '
    /^-- .* --$/ { runtime = ""; if ($2 == "iOS") runtime = $3; next }
    runtime != "" && match($0, /\([0-9A-Fa-f]+-[0-9A-Fa-f-]+\)/) {
      udid = substr($0, RSTART + 1, RLENGTH - 2)
      name = substr($0, 1, RSTART - 1)
      sub(/^ +/, "", name)
      sub(/ +$/, "", name)
      print runtime "|" name "|" udid
    }'
}

# Prints each installed iOS 26.x runtime version.
list_ios26_runtimes() {
  xcrun simctl list runtimes available | awk '$1 == "iOS" && $2 ~ /^26\./ { print $2 }'
}

# Reads "<version>|..." lines and prints the preferred runtime first, then newest to oldest.
prefer_runtime() {
  sort -t'|' -k1,1Vr | awk -F'|' -v want="$WANT_RUNTIME" '
    { if ($1 == want) first = first $0 "\n"; else rest = rest $0 "\n" }
    END { printf "%s%s", first, rest }'
}

select_simulator() {
  local devices match runtime
  devices="$(list_ios_devices)"

  if [ -n "${QA_SIM_UDID:-}" ]; then
    match="$(printf '%s\n' "$devices" | awk -F'|' -v id="$QA_SIM_UDID" '$3 == id' | head -n 1)"
    [ -n "$match" ] || fail_env "QA_SIM_UDID=$QA_SIM_UDID is not an available iOS simulator"
    printf '%s\n' "$match"
    return
  fi

  match="$(printf '%s\n' "$devices" | awk -F'|' -v name="$WANT_DEVICE" '$1 ~ /^26\./ && $2 == name' |
    prefer_runtime | head -n 1)"
  if [ -n "$match" ]; then
    printf '%s\n' "$match"
    return
  fi

  # The device model is missing: create it on the preferred runtime, else the newest iOS 26.x.
  runtime="$(list_ios26_runtimes | sed 's/$/|/' | prefer_runtime | head -n 1 | tr -d '|')"
  if [ -n "$runtime" ]; then
    local type_id="com.apple.CoreSimulator.SimDeviceType.${WANT_DEVICE// /-}"
    local runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-${runtime//./-}"
    if xcrun simctl create "$WANT_DEVICE" "$type_id" "$runtime_id" >/dev/null 2>&1; then
      match="$(list_ios_devices | awk -F'|' -v v="$runtime" -v name="$WANT_DEVICE" '$1 == v && $2 == name' | head -n 1)"
      if [ -n "$match" ]; then
        printf '%s\n' "$match"
        return
      fi
    fi
  fi

  match="$(printf '%s\n' "$devices" | awk -F'|' '$1 ~ /^26\./ && $2 ~ /^iPhone/' | prefer_runtime | head -n 1)"
  [ -n "$match" ] || fail_env "no iOS 26.x iPhone simulator is installed (see: xcrun simctl list devices available)"
  printf '%s\n' "$match"
}

SELECTED="$(select_simulator)"
SIM_RUNTIME="$(printf '%s' "$SELECTED" | cut -d'|' -f1)"
SIM_NAME="$(printf '%s' "$SELECTED" | cut -d'|' -f2)"
SIM_UDID="$(printf '%s' "$SELECTED" | cut -d'|' -f3)"

BUILD_RESULT="not run"
TEST_RESULT="not run"
TEST_DETAILS=""
APP_NOTE=""
EXIT_CODE=0

# Prints totals and failing test names from an .xcresult, falling back to the log.
describe_tests() {
  local xcresult="$1" log="$2" json
  json="$(xcrun xcresulttool get test-results summary --path "$xcresult" 2>/dev/null || true)"
  if [ -n "$json" ] && command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
total = s.get("totalTestCount", 0)
print("%d total, %d passed, %d failed, %d skipped" % (
    total, s.get("passedTests", 0), s.get("failedTests", 0), s.get("skippedTests", 0)))
for f in s.get("testFailures", []):
    print("failing: %s: %s" % (f.get("testIdentifierString") or f.get("testName", "?"), f.get("failureText", "").strip()))
if total == 0:
    print("warning: the result bundle reports zero tests")
' && return
  fi
  grep -E "^Test run with |Executed [0-9]+ tests?|✘ Test " "$log" || echo "no test counts found in $log"
}

write_summary() {
  {
    echo "Dubbing iOS build/test summary"
    echo "Mode:           $MODE"
    echo "Commit:         $COMMIT_SHA"
    echo "Xcode:          $XCODE_VERSION"
    echo "Simulator:      $SIM_NAME, iOS $SIM_RUNTIME ($SIM_UDID)"
    echo "Configuration:  $CONFIGURATION"
    echo "Build:          $BUILD_RESULT"
    echo "Tests:          $TEST_RESULT"
    [ -z "$TEST_DETAILS" ] || printf '%s\n' "$TEST_DETAILS" | sed 's/^/  /'
    [ -z "$APP_NOTE" ] || printf '%s\n' "$APP_NOTE"
    echo "Overall:        $([ "$EXIT_CODE" -eq 0 ] && echo PASS || echo FAIL)"
  } >"$OUT_DIR/summary.txt"
  echo
  cat "$OUT_DIR/summary.txt"
}

finish() {
  write_summary
  exit "$EXIT_CODE"
}

stage_app() {
  if [ ! -d "$APP_BUILT" ]; then
    APP_NOTE="App:            missing at $APP_BUILT"
    return 1
  fi
  cp -R "$APP_BUILT" "$OUT_DIR/Dubbing.app"
  if command -v ditto >/dev/null 2>&1; then
    ditto -c -k --sequesterRsrc --keepParent "$OUT_DIR/Dubbing.app" "$OUT_DIR/Dubbing.app.zip"
  else
    (cd "$OUT_DIR" && zip -qry Dubbing.app.zip Dubbing.app)
  fi
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUT_DIR/Dubbing.app/Info.plist" 2>/dev/null || echo unknown)"
  APP_NOTE="App:            $OUT_DIR/Dubbing.app (bundle id $bundle_id)
Zipped app:     $OUT_DIR/Dubbing.app.zip"
}

run_logged() {
  local log="$1"
  shift
  echo "+ $*" | tee "$log"
  "$@" 2>&1 | tee -a "$log"
}

COMMON_ARGS=(
  -project "$ROOT/$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "platform=iOS Simulator,id=$SIM_UDID"
  -derivedDataPath "$DERIVED_DATA"
  -clonedSourcePackagesDirPath "$PACKAGES_DIR"
  -disableAutomaticPackageResolution
)

echo "Xcode: $XCODE_VERSION"
echo "Simulator: $SIM_NAME, iOS $SIM_RUNTIME ($SIM_UDID)"

if ! run_logged "$OUT_DIR/resolve.log" xcodebuild -resolvePackageDependencies \
  -project "$ROOT/$PROJECT" -scheme "$SCHEME" -clonedSourcePackagesDirPath "$PACKAGES_DIR"; then
  BUILD_RESULT="FAILED (package resolution, see resolve.log)"
  EXIT_CODE=1
  finish
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "build" ]; then
  if run_logged "$OUT_DIR/build.log" xcodebuild build "${COMMON_ARGS[@]}" \
    -resultBundlePath "$OUT_DIR/build.xcresult" CODE_SIGNING_ALLOWED=NO; then
    BUILD_RESULT="PASSED"
  else
    BUILD_RESULT="FAILED (see build.log, build.xcresult)"
    EXIT_CODE=1
  fi
fi

if [ "$EXIT_CODE" -eq 0 ] && { [ "$MODE" = "all" ] || [ "$MODE" = "test" ]; }; then
  if run_logged "$OUT_DIR/test.log" xcodebuild test "${COMMON_ARGS[@]}" \
    -only-testing:"$TEST_TARGET" -resultBundlePath "$OUT_DIR/test.xcresult" CODE_SIGNING_ALLOWED=NO; then
    TEST_RESULT="PASSED"
  else
    TEST_RESULT="FAILED (see test.log, test.xcresult)"
    EXIT_CODE=1
  fi
  if [ "$BUILD_RESULT" = "not run" ]; then
    if grep -q "BUILD FAILED" "$OUT_DIR/test.log"; then
      BUILD_RESULT="FAILED (see test.log)"
    else
      BUILD_RESULT="PASSED (built as part of the test run)"
    fi
  fi
  if [ -d "$OUT_DIR/test.xcresult" ]; then
    TEST_DETAILS="$(describe_tests "$OUT_DIR/test.xcresult" "$OUT_DIR/test.log")"
  else
    TEST_DETAILS="no result bundle was written; see test.log"
  fi
fi

if [ "$BUILD_RESULT" != "not run" ] && [ "${BUILD_RESULT#FAILED}" = "$BUILD_RESULT" ]; then
  stage_app || EXIT_CODE=1
fi

finish
