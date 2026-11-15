#!/usr/bin/env bash
# Runs the DubbingUITests bundle on an iOS simulator and prints a per-test result list.
# Build and test invocation matches README.md#build-and-test; this script only adds the
# simulator preparation the UI tests need (a clean permission state) and the result summary.
set -euo pipefail

DEVICE="${QA_SIM_DEVICE:-iPhone 17 Pro}"
RUNTIME="${QA_SIM_RUNTIME:-26.5}"
DERIVED="${QA_DERIVED_DATA:-build/DerivedData}"
RESULT="${QA_RESULT_BUNDLE:-build/ui-smoke.xcresult}"
BUNDLE_ID="com.ryankim.Dubbing"

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
device, runtime = sys.argv[1], sys.argv[2]
for key, devices in json.load(sys.stdin)["devices"].items():
    if key.endswith("iOS-" + runtime.replace(".", "-")):
        for d in devices:
            if d["name"] == device:
                print(d["udid"]); raise SystemExit
raise SystemExit("no simulator named %s on iOS %s" % (device, runtime))
' "$DEVICE" "$RUNTIME")"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" reset all "$BUNDLE_ID" || true

rm -rf "$RESULT"
set +e
xcodebuild -project Dubbing.xcodeproj -scheme Dubbing \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT" -only-testing:DubbingUITests \
  CODE_SIGNING_ALLOWED=NO test
STATUS=$?
set -e

if [ -d "$RESULT" ]; then
  xcrun xcresulttool get test-results tests --path "$RESULT" | python3 -c '
import json, sys
def walk(node, trail):
    kids = node.get("children", [])
    if not kids:
        print("%-7s %s" % (node.get("result", "?"), "/".join(trail + [node.get("name", "?")])))
    for kid in kids:
        walk(kid, trail + [node.get("name", "?")])
for root in json.load(sys.stdin).get("testNodes", []):
    walk(root, [])
'
fi
exit "$STATUS"
