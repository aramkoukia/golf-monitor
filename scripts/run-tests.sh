#!/bin/zsh
# Builds the unit tests and runs them inside the app on an iOS Simulator by
# injecting the test bundle directly (no Xcode test manager needed — useful
# on locked-down machines and CI where `xcodebuild test` can't connect).
#
#   scripts/run-tests.sh                       # all tests
#   scripts/run-tests.sh ShotFinderTests       # one class (XCTest filter)
#   SIM_UDID=<udid> scripts/run-tests.sh       # pick the simulator
#
# Plain `xcodebuild test` (or ⌘U in Xcode) runs the same tests normally.
set -euo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-All}"
DERIVED="${DERIVED_DATA:-/tmp/gm-dd}"
UDID="${SIM_UDID:-$(xcrun simctl list devices available | grep -m1 -E 'iPhone 1[5-9] Pro \(' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')}"
[[ -n "$UDID" ]] || { echo "No iPhone simulator found; set SIM_UDID"; exit 2; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "▸ Building for testing ($UDID)…"
xcodebuild build-for-testing -project GolfMonitor.xcodeproj -scheme GolfMonitor \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO > "$DERIVED-build-for-testing.log" 2>&1 \
  || { grep -E 'error:' "$DERIVED-build-for-testing.log" | sort -u; echo "Build failed"; exit 1; }

APP="$DERIVED/Build/Products/Debug-iphonesimulator/GolfMonitor.app"
xcrun simctl install "$UDID" "$APP"
CONTAINER="$(xcrun simctl get_app_container "$UDID" com.example.golfmonitor)"
PLATFORM=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer
LOG="$DERIVED-tests.log"

echo "▸ Running tests: $FILTER"
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$PLATFORM/usr/lib/libXCTestBundleInject.dylib" \
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$PLATFORM/Library/Frameworks:$PLATFORM/Library/PrivateFrameworks" \
SIMCTL_CHILD_DYLD_LIBRARY_PATH="$PLATFORM/usr/lib" \
SIMCTL_CHILD_XCInjectBundleInto="$CONTAINER/GolfMonitor" \
SIMCTL_CHILD_XCInjectBundle="$CONTAINER/PlugIns/GolfMonitorTests.xctest" \
SIMCTL_CHILD_XCTestBundlePath="$CONTAINER/PlugIns/GolfMonitorTests.xctest" \
SIMCTL_CHILD_GM_TEST_OUT="${GM_TEST_OUT:-/tmp/gm-test-out}" \
  xcrun simctl launch --console-pty --terminate-running-process "$UDID" com.example.golfmonitor \
  -XCTest "$FILTER" > "$LOG" 2>&1 || true

grep -E "error:|failed \(|Executed [0-9]+ test" "$LOG" | grep -v "^$" || true
if grep -q "' failed (" "$LOG" || ! grep -q "Executed" "$LOG"; then
  echo "✗ Tests failed (full log: $LOG)"
  exit 1
fi
echo "✓ Tests passed (full log: $LOG)"
