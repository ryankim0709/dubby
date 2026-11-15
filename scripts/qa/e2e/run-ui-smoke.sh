#!/usr/bin/env bash
# Runs the DubbingUITests bundle on an iOS simulator and writes a per-test result list.
# Build and test invocation follows README.md#build-and-test; this script adds the simulator
# preparation the UI tests need (a clean permission state) and the result and screenshot export.
#
#   scripts/qa/e2e/run-ui-smoke.sh
#
# Environment (all optional):
#   QA_SIM_DEVICE      simulator model name (default "iPhone 17 Pro")
#   QA_SIM_RUNTIME     preferred iOS runtime (default "26.5"); the highest installed 26.x is used otherwise
#   QA_DERIVED_DATA    derived data path (default build/DerivedData)
#   QA_OUT_DIR         results directory (default build/ui-smoke)
#   TEST_RUNNER_DUBIT_QA_SCENE_ID   scene id the tests open (xcodebuild passes TEST_RUNNER_ variables to the runner)
#
# Outputs in QA_OUT_DIR: test.log, results.txt, summary.json, ui-smoke.xcresult, attachments/.
# Exit codes: 0 all selected tests passed, 1 a test or the build failed, 2 environment error.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
DEVICE="${QA_SIM_DEVICE:-iPhone 17 Pro}"
RUNTIME="${QA_SIM_RUNTIME:-26.5}"
DERIVED="${QA_DERIVED_DATA:-build/DerivedData}"
OUT="${QA_OUT_DIR:-build/ui-smoke}"
RESULT="$OUT/ui-smoke.xcresult"
BUNDLE_ID="com.ryankim.Dubbing"

command -v xcodebuild >/dev/null 2>&1 || { echo "error: xcodebuild not found; this needs macOS with Xcode 26 or newer" >&2; exit 2; }
mkdir -p "$OUT"
rm -rf "$RESULT" "$OUT/attachments" "$OUT/test.log" "$OUT/results.txt" "$OUT/summary.json"

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
device, wanted = sys.argv[1], sys.argv[2]
found = {}
for key, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in key:
        continue
    version = key.split(".iOS-")[1].replace("-", ".")
    for d in devices:
        if d["name"] == device:
            found[version] = d["udid"]
if wanted in found:
    print(found[wanted])
else:
    candidates = sorted((v for v in found if v.startswith("26.")), key=lambda v: [int(p) for p in v.split(".")])
    if not candidates:
        sys.exit("no %s simulator on an iOS 26 runtime" % device)
    print(found[candidates[-1]])
' "$DEVICE" "$RUNTIME")" || { echo "error: could not select a simulator" >&2; exit 2; }

echo "Simulator $UDID ($DEVICE)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl privacy "$UDID" reset all "$BUNDLE_ID" || true
xcodebuild -version | tr '\n' ' ' | tee "$OUT/environment.txt"
echo

xcodebuild -project Dubbing.xcodeproj -scheme Dubbing \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT" -only-testing:DubbingUITests \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$OUT/test.log"
STATUS="${PIPESTATUS[0]}"

if [ -d "$RESULT" ]; then
  xcrun xcresulttool get test-results summary --path "$RESULT" > "$OUT/summary.json" 2>/dev/null || true
  xcrun xcresulttool get test-results tests --path "$RESULT" 2>/dev/null | python3 -c '
import json, sys
rows = []
def walk(node, trail):
    kids = node.get("children", [])
    name = node.get("name", "?")
    if not kids:
        rows.append((node.get("result", "?"), "/".join(trail + [name])))
    for kid in kids:
        walk(kid, trail + [name])
for root in json.load(sys.stdin).get("testNodes", []):
    walk(root, [])
for result, name in rows:
    print("%-8s %s" % (result, name))
print("TOTAL %d, PASSED %d, FAILED %d" % (len(rows), sum(r == "Passed" for r, _ in rows), sum(r == "Failed" for r, _ in rows)))
' | tee "$OUT/results.txt"
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT/attachments" >/dev/null 2>&1 || echo "note: attachments could not be exported" >&2
fi
exit "$STATUS"
