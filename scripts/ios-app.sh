#!/bin/bash
# Builds, assembles, installs, and launches the SwiftPM UIKit client.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ios_app_output() {
  printf '%s/.spm-build/ios-app/%s\n' "$ROOT" "$1"
}

if [ "${1:-}" = "--list-build-paths" ]; then
  printf 'ios-app\tapp\t%s\n' "$(ios_app_output simulator)"
  exit 0
fi

TARGET="${1:-simulator}"
case "$TARGET" in
  simulator|device) ;;
  *) echo "usage: ios-app.sh [simulator|device] [target-id]" >&2; exit 1 ;;
esac

PACKAGE="$ROOT/ios/DanTermMobileApp"
BUNDLE_ID="com.danneu.danterm.ios"
TEAM="${DANTERM_IOS_TEAM:-K4G3798DHZ}"
OUT="$(ios_app_output "$TARGET")"
APP="$OUT/DanTerm.app"

mkdir -p "$OUT"
if [ "$TARGET" = "simulator" ]; then
  SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  TRIPLE="arm64-apple-ios26.5-simulator"
  BIN="$OUT/swiftpm/arm64-apple-ios-simulator/debug"
else
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  TRIPLE="arm64-apple-ios26.5"
  BIN="$OUT/swiftpm/arm64-apple-ios/debug"
fi

echo "== building DanTerm for $TRIPLE =="
swift build --package-path "$PACKAGE" --build-path "$OUT/swiftpm" \
  --triple "$TRIPLE" --sdk "$SDK"

echo "== assembling $APP =="
"$ROOT/scripts/assemble-ios-app.sh" "$ROOT" "$BIN" "$APP"

if [ "$TARGET" = "simulator" ]; then
  SIMULATOR="${2:-}"
  if [ -z "$SIMULATOR" ]; then
    SIMULATOR="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    if "iOS" not in runtime or not entries:
        continue
    version = tuple(int(part) for part in runtime.rsplit("-", 2)[-2:])
    if version < (26, 0):
        continue
    if best is None or version > best[0]:
        best = (version, entries[0]["udid"])
print(best[1] if best else "")
')"
  fi
  if [ -z "$SIMULATOR" ]; then
    echo "no available iOS 26+ simulator" >&2
    exit 1
  fi
  echo "== installing on simulator $SIMULATOR =="
  xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
  xcrun simctl bootstatus "$SIMULATOR" -b
  xcrun simctl install "$SIMULATOR" "$APP"
  xcrun simctl terminate "$SIMULATOR" "$BUNDLE_ID" 2>/dev/null || true
  echo "== launching =="
  SIMCTL_CHILD_DANTERM_IOS_HOST="${DANTERM_IOS_HOST:-}" \
    SIMCTL_CHILD_DANTERM_IOS_PORT="${DANTERM_IOS_PORT:-7420}" \
    SIMCTL_CHILD_DANTERM_IOS_SMOKE_INPUT="${DANTERM_IOS_SMOKE_INPUT:-}" \
    xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID"
  exit 0
fi

plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$APP/Info.plist"
plutil -replace DTPlatformName -string iphoneos "$APP/Info.plist"
PROFILE="$(python3 - "$TEAM" <<'PICK'
import glob, os, plistlib, subprocess, sys
team = sys.argv[1]
best = None
for path in glob.glob(os.path.expanduser(
    "~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision"
)):
    raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
    if not raw:
        continue
    profile = plistlib.loads(raw)
    if profile["Entitlements"].get("application-identifier") != f"{team}.*":
        continue
    if best is None or profile["ExpirationDate"] > best[0]:
        best = (profile["ExpirationDate"], path)
print(best[1] if best else "")
PICK
)"
if [ -z "$PROFILE" ]; then
  echo "no wildcard development profile for team $TEAM" >&2
  exit 1
fi
cp "$PROFILE" "$APP/embedded.mobileprovision"
python3 - "$TEAM" "$BUNDLE_ID" "$OUT/entitlements.plist" <<'ENTITLEMENTS'
import plistlib, sys
team, bundle, output = sys.argv[1:]
with open(output, "wb") as handle:
    plistlib.dump({
        "application-identifier": f"{team}.{bundle}",
        "com.apple.developer.team-identifier": team,
        "get-task-allow": True,
    }, handle)
ENTITLEMENTS
IDENTITY="$(python3 - "$PROFILE" <<'IDENTITY'
import hashlib, plistlib, subprocess, sys
raw = subprocess.run(["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True).stdout
profile = plistlib.loads(raw)
print(hashlib.sha1(profile["DeveloperCertificates"][0]).hexdigest().upper())
IDENTITY
)"
codesign --force --sign "$IDENTITY" --entitlements "$OUT/entitlements.plist" \
  --generate-entitlement-der --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

DEVICE="${2:-}"
if [ -z "$DEVICE" ]; then
  xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1 || true
  DEVICE="$(python3 - "$OUT/devices.json" <<'DEVICE'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
print(devices[0]["identifier"] if devices else "")
DEVICE
)"
fi
if [ -z "$DEVICE" ]; then
  echo "no paired device; pair one in Xcode first" >&2
  exit 1
fi
echo "== installing on device $DEVICE =="
xcrun devicectl device install app --device "$DEVICE" "$APP"
LAUNCH_ENV="$(python3 - "${DANTERM_IOS_HOST:-}" "${DANTERM_IOS_PORT:-7420}" <<'LAUNCH'
import json, sys
print(json.dumps({"DANTERM_IOS_HOST": sys.argv[1], "DANTERM_IOS_PORT": sys.argv[2]}))
LAUNCH
)"
xcrun devicectl device process launch --device "$DEVICE" -e "$LAUNCH_ENV" "$BUNDLE_ID"
