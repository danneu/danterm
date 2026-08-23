#!/bin/bash
# Reproduction recipe for F2 and F3: build TerminalRenderExecution for iOS,
# assemble a minimal iOS app around it, and run it so real RenderFramePlans
# reach real pixels. One script for both targets, because the divergence
# between them is itself a result -- F2 measured the presentation mechanism on a
# simulator and F3 found that device CoreAnimation does not behave the same, so
# re-running either side has to stay possible.
#
# The two targets share everything but their ends: which triple and SDK to
# build for, and how the bundle is installed. Bundle assembly is shared on
# purpose. It carries the Nerd Font trap recorded under F2, which fails
# silently, and a second copy of it is a second place for that trap to come
# back.
#
# There is no Xcode project and no xcodebuild anywhere in this: `swift build`
# compiles the executable, this script assembles the flat iOS bundle by hand the
# way build-app.sh assembles the macOS one. The simulator needs no signing; the
# device is signed against an existing wildcard development profile and
# installed by devicectl over the same network pairing Xcode uses.
#
# This script patches nothing. Earlier revisions applied the iOS platform pin
# and the NSFont/UIFont seam per run and reverted them on exit; both are in the
# tree now, so this is a plain `swift build` against the shipped sources.
#
# Usage: ios-render-spike.sh [simulator|device] [target-id]
# Artifacts land under the iOS research descendant of .build-gate/.
set -eu

TARGET="${1:-simulator}"
case "$TARGET" in
  simulator|device) ;;
  *) echo "usage: ios-render-spike.sh [simulator|device] [target-id]" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/scripts/lib/build-paths.sh"
SPIKE="$ROOT/docs/research/35-ios-remote-client/ios-render-spike"
BUNDLE_ID="com.danneu.danterm.ios-render-spike"
TEAM="K4G3798DHZ"
OUT="$(danterm_gate_build_path "$ROOT" "research/ios-remote-client/render-spike/$TARGET")"
APP="$OUT/IOSRenderSpike.app"
mkdir -p "$OUT"

if [ "$TARGET" = simulator ]; then
  SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  TRIPLE="arm64-apple-ios26.5-simulator"
  BIN="$OUT/swiftpm/arm64-apple-ios-simulator/debug"
else
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  TRIPLE="arm64-apple-ios26.5"
  BIN="$OUT/swiftpm/arm64-apple-ios/debug"
fi

echo "== building the spike for $TRIPLE =="
swift build --package-path "$SPIKE" --build-path "$OUT/swiftpm" \
  --triple "$TRIPLE" --sdk "$SDK"

echo "== assembling the bundle =="
# Flat, unlike a macOS bundle: the binary, Info.plist, and resources sit at the
# top level, with no Contents/ and no MacOS/.
rm -rf "$APP"
mkdir -p "$APP"
cp "$BIN/IOSRenderSpike" "$APP/IOSRenderSpike"
cp "$SPIKE/Info.plist" "$APP/Info.plist"
if [ "$TARGET" = device ]; then
  # The checked-in plist names the simulator platform, and installd rejects
  # that on a device.
  plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$APP/Info.plist"
  plutil -replace DTPlatformName -string iphoneos "$APP/Info.plist"
fi

# The packaged Nerd Font symbols face, copied the way
# scripts/bundle-theme-resources.sh copies it for the macOS app: into
# Bundle.main, at NerdFontsSymbolsOnly/. NerdFontSymbolsResource.packagedURL()
# refuses SwiftPM's Bundle.module whenever Bundle.main is a .app, so shipping
# only the generated .bundle silently leaves every private-use glyph as tofu --
# the first assembly of this spike did exactly that, and the screenshot showed
# it.
mkdir -p "$APP/NerdFontsSymbolsOnly"
cp "$ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf" \
  "$APP/NerdFontsSymbolsOnly/"
cp "$ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/LICENSE" \
  "$APP/NerdFontsSymbolsOnly/"

if [ "$TARGET" = device ]; then
  # The signing material is not minted here. A wildcard development profile
  # that already lists this device covers any bundle id under the team, and its
  # embedded certificate is the identity codesign is asked for below. Pick the
  # profile by matching the wildcard app id, not by UUID, so a reissued profile
  # does not break the script.
  PROFILE="$(python3 - "$TEAM" <<'PICK'
import glob, os, plistlib, subprocess, sys
team = sys.argv[1]
best = None
for path in glob.glob(os.path.expanduser(
    "~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision"
)):
    raw = subprocess.run(["security", "cms", "-D", "-i", path],
                         capture_output=True).stdout
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

  echo "== signing =="
  cp "$PROFILE" "$APP/embedded.mobileprovision"
  cat > "$OUT/entitlements.plist" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>$TEAM.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM</string>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
ENTITLEMENTS
  # The identity is named by the certificate the chosen profile embeds, so the
  # signature and the profile cannot disagree.
  IDENTITY="$(python3 - "$PROFILE" <<'IDENT'
import hashlib, plistlib, subprocess, sys
profile = plistlib.loads(subprocess.run(
    ["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True).stdout)
print(hashlib.sha1(profile["DeveloperCertificates"][0]).hexdigest().upper())
IDENT
)"
  codesign --force --sign "$IDENTITY" \
    --entitlements "$OUT/entitlements.plist" --generate-entitlement-der \
    --timestamp=none "$APP"
  codesign --verify --verbose=2 "$APP"

  DEVICE="${2:-}"
  if [ -z "$DEVICE" ]; then
    xcrun devicectl list devices --json-output "$OUT/devices.json" >/dev/null 2>&1 || true
    DEVICE="$(python3 -c "
import json, sys
try:
    devices = json.load(open('$OUT/devices.json'))['result']['devices']
except Exception:
    devices = []
print(devices[0]['identifier'] if devices else '')
")"
  fi
  if [ -z "$DEVICE" ]; then
    echo "no paired device; pair one in Xcode first" >&2
    exit 1
  fi

  echo "== installing on $DEVICE =="
  xcrun devicectl device install app --device "$DEVICE" "$APP"

  echo
  echo "Launch it and watch the screen. SPIKE_MODE picks what runs:"
  echo "  (unset)     probes A-E, each stage advanced by a tap"
  echo "  ablate      probe D on a timer, so no touch is co-timed with the mutation"
  echo "  swapchain   probe F alone: the real swapchain driving a layer"
  echo "  xcrun devicectl device process launch --device $DEVICE --console \\"
  echo "    -e '{\"SPIKE_MODE\":\"swapchain\"}' $BUNDLE_ID"
  exit 0
fi

CONSOLE="$OUT/console.log"
SHOT_FIRST="$OUT/first-frame.png"
SHOT_MUTATED="$OUT/after-in-place-mutation.png"
SHOT_REATTACHED="$OUT/after-reattach.png"

SIMULATOR="${2:-}"
if [ -z "$SIMULATOR" ]; then
  # Newest runtime that can host the bundle's MinimumOSVersion, not simply the
  # first available device: older runtimes are still installed here, and
  # installd rejects the bundle on them with an error about updating the phone
  # that reads like a device problem rather than a picker problem.
  SIMULATOR="$(xcrun simctl list devices available --json | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
best = None
for runtime, entries in devices.items():
    if 'iOS' not in runtime or not entries:
        continue
    version = tuple(int(part) for part in runtime.rsplit('-', 2)[-2:])
    if version < (26, 0):
        continue
    if best is None or version > best[0]:
        best = (version, entries[0]['udid'])
print(best[1] if best else '')
")"
fi
if [ -z "$SIMULATOR" ]; then
  echo "no available iOS 26+ simulator; the bundle needs one" >&2
  exit 1
fi
echo "== simulator $SIMULATOR =="
xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR" -b
xcrun simctl install "$SIMULATOR" "$APP"

echo "== running =="
# One launch, three screenshots: on the simulator the app keeps F2's timers, so
# probe D (in-place mutation, 4s) and probe E (reattach, 10s) each get a
# screenshot taken after they fire and before the next one does. The console
# pipe is backgrounded and killed at the end. The device target has no
# equivalent, which is why its stages are driven by hand.
xcrun simctl launch --console-pipe "$SIMULATOR" "$BUNDLE_ID" > "$CONSOLE" 2>&1 &
PIPE=$!
# 3s, not 2s, for the first capture: at 2s the launch presentation has not
# settled, so the baseline differed from the later shots even in the panel
# holding an immutable CGImage, which cannot change. That made a whole-image
# comparison report a difference that had nothing to do with the surface.
sleep 3
xcrun simctl io "$SIMULATOR" screenshot "$SHOT_FIRST"
sleep 3
xcrun simctl io "$SIMULATOR" screenshot "$SHOT_MUTATED"
sleep 6
xcrun simctl io "$SIMULATOR" screenshot "$SHOT_REATTACHED"
kill "$PIPE" 2>/dev/null || true
xcrun simctl terminate "$SIMULATOR" "$BUNDLE_ID" 2>/dev/null || true

echo
echo "console:    $CONSOLE"
echo "screenshot: $SHOT_FIRST (the first rendered frame, all three probes)"
echo "screenshot: $SHOT_MUTATED (after probe D mutated the surface in place)"
echo "screenshot: $SHOT_REATTACHED (after probe E reattached the same surface)"
grep '^SPIKE' "$CONSOLE" || true
