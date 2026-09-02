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

usage() {
  echo "usage: ios-app.sh [simulator|device] [--slot <n>] [target-id]" >&2
  exit 1
}

TARGET="${1:-simulator}"
case "$TARGET" in
  simulator) ICON_PLATFORM="iphonesimulator" ;;
  device) ICON_PLATFORM="iphoneos" ;;
  *) usage ;;
esac
[ $# -gt 0 ] && shift

SLOT=""
TARGET_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) SLOT="${2:-}"; [ -n "$SLOT" ] || usage; shift 2 ;;
    -*) usage ;;
    *) TARGET_ID="$1"; shift ;;
  esac
done

# A slot derives its listen port from its own identity, so no default port names it.
# Reading the endpoint back off the slot is the only way to get a client that connects
# without the caller copying it by hand.
if [ -n "$SLOT" ]; then
  # The survey is read into a variable rather than piped: `python3 -` takes its program
  # on stdin, so a heredoc and a pipe cannot both feed one invocation.
  SLOT_SURVEY="$("$ROOT/scripts/dev-slot-launcher.py" --list)"
  SLOT_ENDPOINT="$(python3 - "$SLOT" "$SLOT_SURVEY" <<'SLOT_ENDPOINT'
import json, sys
slot, survey = sys.argv[1], sys.argv[2]
entry = next((e for e in json.loads(survey) if str(e.get("slot")) == slot), None)
if entry is None:
    sys.exit(f"ios-app.sh: no slot {slot}")
if entry.get("free"):
    sys.exit(f"ios-app.sh: slot {slot} is free -- launch it with `just launch-slot --tailnet`")
tailnet = entry.get("tailnet")
if tailnet is None:
    sys.exit(
        f"ios-app.sh: slot {slot} has no tailnet listener -- "
        "relaunch it with `just launch-slot --tailnet`"
    )
# A slot still waiting on its bind reports an endpoint it is not yet serving.
if tailnet.get("state") != "listening":
    sys.exit(
        f"ios-app.sh: slot {slot} tailnet is {tailnet.get('state')}: "
        f"{tailnet.get('reason', 'no reason given')}"
    )
host, port = tailnet["endpoint"].rsplit(":", 1)
print(host, port)
SLOT_ENDPOINT
)"
  read -r SLOT_HOST SLOT_PORT <<<"$SLOT_ENDPOINT"
  echo "== slot $SLOT is listening on $SLOT_HOST:$SLOT_PORT =="
fi

# A launch target overrides the server the user saved in the app, for that run only, so
# only an explicit `--slot` supplies one. An ordinary run leaves both variables absent --
# not empty -- and the phone dials whatever it has saved. The variables are never read
# from the invoking shell: a stale export left over from an earlier slot session used to
# aim an ordinary run at a slot that had already been released.
LAUNCH_TARGET=()
if [ -n "$SLOT" ]; then
  LAUNCH_TARGET=(DANTERM_IOS_HOST="$SLOT_HOST" DANTERM_IOS_PORT="$SLOT_PORT")
fi

PACKAGE="$ROOT/ios/DanTermMobileApp"
BUNDLE_ID="com.danneu.danterm.ios"
TEAM="${DANTERM_IOS_TEAM:-K4G3798DHZ}"
OUT="$(ios_app_output "$TARGET")"
APP="$OUT/DanTerm.app"
ICON_OUT="$OUT/app-icon"
ICON_INFO="$OUT/app-icon-info.plist"

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
rm -rf "$ICON_OUT"
mkdir -p "$ICON_OUT"
xcrun actool "$ROOT/icon/AppIcon.icon" \
  --app-icon AppIcon \
  --compile "$ICON_OUT" \
  --output-partial-info-plist "$ICON_INFO" \
  --minimum-deployment-target 26.0 \
  --platform "$ICON_PLATFORM" \
  --target-device iphone
"$ROOT/scripts/assemble-ios-app.sh" "$ROOT" "$BIN" "$ICON_OUT" "$ICON_INFO" "$APP"

if [ "$TARGET" = "simulator" ]; then
  SIMULATOR="$TARGET_ID"
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
  # Smoke input is passed independently of the target: the probe drives the first pane of
  # whatever server the phone connects to, saved or slot.
  CHILD_ENV=("${LAUNCH_TARGET[@]/#/SIMCTL_CHILD_}")
  if [ -n "${DANTERM_IOS_SMOKE_INPUT:-}" ]; then
    CHILD_ENV+=(SIMCTL_CHILD_DANTERM_IOS_SMOKE_INPUT="$DANTERM_IOS_SMOKE_INPUT")
  fi
  env ${CHILD_ENV[@]+"${CHILD_ENV[@]}"} xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID"
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

DEVICE="$TARGET_ID"
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
DEVICE_ENV=(${LAUNCH_TARGET[@]+"${LAUNCH_TARGET[@]}"})
if [ -n "${DANTERM_IOS_SMOKE_INPUT:-}" ]; then
  DEVICE_ENV+=(DANTERM_IOS_SMOKE_INPUT="$DANTERM_IOS_SMOKE_INPUT")
fi
# An absent variable is what tells the phone to use its saved server, so the JSON names
# only the variables this run actually sets. `devicectl` rejects an empty JSON object, so
# a run that sets nothing omits the flag rather than passing `{}`.
LAUNCH_ENV_FLAG=()
if [ ${#DEVICE_ENV[@]} -gt 0 ]; then
  LAUNCH_ENV_FLAG=(-e "$(python3 - "${DEVICE_ENV[@]}" <<'LAUNCH'
import json, sys
print(json.dumps(dict(entry.split("=", 1) for entry in sys.argv[1:])))
LAUNCH
)")
fi
xcrun devicectl device process launch --device "$DEVICE" \
  ${LAUNCH_ENV_FLAG[@]+"${LAUNCH_ENV_FLAG[@]}"} "$BUNDLE_ID"
