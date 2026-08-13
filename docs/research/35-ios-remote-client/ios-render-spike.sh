#!/bin/bash
# Reproduction recipe for F2: build TerminalRenderExecution for iOS, assemble a
# minimal iOS app around it, and run it on a simulator so a static
# RenderFramePlan reaches real pixels.
#
# Three things do not live in the tree and are applied here, then restored on
# exit: the iOS platform pin on lib/TerminalCore (F1 explains why a package-level
# pin cannot land while the same package holds host-only targets), and the
# NSFont/UIFont seam that is F2's own itemized result. Applying them from the
# script keeps the finding re-derived rather than asserted by a patched tree.
#
# There is no Xcode project and no xcodebuild anywhere in this: `swift build`
# compiles the executable, this script assembles the flat iOS bundle by hand the
# way build-app.sh assembles the macOS one, and simctl installs and launches it.
# Simulator only, so no signing and no provisioning profile.
#
# Usage: ios-render-spike.sh [simulator-udid]
# Every artifact lands under .build-ios-t2/ at the repository root, which the
# existing .build-ios-*/ gitignore rule already covers. The screenshots are the
# ones that settle which presentation paths produced pixels.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SPIKE="$ROOT/docs/research/35-ios-remote-client/ios-render-spike"
BUNDLE_ID="com.danneu.danterm.ios-render-spike"
OUT="$ROOT/.build-ios-t2"
APP="$OUT/IOSRenderSpike.app"
CONSOLE="$OUT/console.log"
SHOT_FIRST="$OUT/first-frame.png"
SHOT_MUTATED="$OUT/after-in-place-mutation.png"
SHOT_REATTACHED="$OUT/after-reattach.png"
mkdir -p "$OUT"

MANIFEST="$ROOT/lib/TerminalCore/Package.swift"
SOURCE="$ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIM_TRIPLE="arm64-apple-ios26.5-simulator"

# A leftover backup means an earlier run died before its trap could restore the
# tree, so what is on disk is the patched copy. Copying over the backup now
# would make the patches permanent and silent.
for file in "$MANIFEST" "$SOURCE"; do
  if [ -f "$file.t2-backup" ]; then
    echo "$file.t2-backup exists: an earlier run left the tree patched." >&2
    echo "Restore it (mv it back) before rerunning." >&2
    exit 1
  fi
done

restore() {
  for file in "$MANIFEST" "$SOURCE"; do
    if [ -f "$file.t2-backup" ]; then
      mv "$file.t2-backup" "$file"
    fi
  done
}
trap restore EXIT
trap 'restore; exit 130' INT TERM

cp "$MANIFEST" "$MANIFEST.t2-backup"
cp "$SOURCE" "$SOURCE.t2-backup"

sed -i '' 's/platforms: \[\.macOS(\.v26)\]/platforms: [.macOS(.v26), .iOS(.v26)]/' "$MANIFEST"
if ! grep -q '\.iOS(\.v26)' "$MANIFEST"; then
  echo "lib/TerminalCore/Package.swift: the iOS pin did not apply." >&2
  exit 1
fi

# The whole port, as F2 itemizes it: one import and one call site. NSFont is the
# only AppKit symbol the module names; UIFont answers monospacedSystemFont and
# fontName identically.
python3 - "$SOURCE" <<'PATCH'
import sys
path = sys.argv[1]
text = open(path).read()
old_import = "import AppKit\n"
new_import = (
    "#if canImport(AppKit)\n"
    "import AppKit\n"
    "typealias PlatformFont = NSFont\n"
    "#else\n"
    "import UIKit\n"
    "typealias PlatformFont = UIFont\n"
    "#endif\n"
)
old_call = "NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)"
new_call = "PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)"
if old_import not in text or old_call not in text:
    sys.exit("TerminalRenderExecution.swift: the F2 seam patch no longer applies")
open(path, "w").write(text.replace(old_import, new_import, 1).replace(old_call, new_call, 1))
PATCH

echo "== building the module for iOS (device triple too, to keep F1's pair) =="
swift build --package-path "$ROOT/lib/TerminalCore" \
  --build-path "$OUT/swiftpm-device" --target TerminalRenderExecution \
  --triple arm64-apple-ios26.5 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"
echo "PASS TerminalRenderExecution arm64-apple-ios26.5"

echo "== building the spike app =="
swift build --package-path "$SPIKE" --build-path "$OUT/swiftpm-spike" \
  --triple "$SIM_TRIPLE" --sdk "$SIM_SDK"
BIN="$OUT/swiftpm-spike/arm64-apple-ios-simulator/debug"

echo "== assembling the bundle =="
# Flat, unlike a macOS bundle: the binary, Info.plist, and resources sit at the
# top level, with no Contents/ and no MacOS/.
rm -rf "$APP"
mkdir -p "$APP"
cp "$BIN/IOSRenderSpike" "$APP/IOSRenderSpike"
cp "$SPIKE/Info.plist" "$APP/Info.plist"
# The packaged Nerd Font symbols face, copied the way scripts/bundle-theme-resources.sh
# copies it for the macOS app: into Bundle.main, at NerdFontsSymbolsOnly/.
# NerdFontSymbolsResource.packagedURL() refuses SwiftPM's Bundle.module whenever
# Bundle.main is a .app, so shipping only the generated .bundle silently leaves
# every private-use glyph as tofu -- the first assembly of this spike did exactly
# that, and the screenshot showed it.
mkdir -p "$APP/NerdFontsSymbolsOnly"
cp "$ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf" \
  "$APP/NerdFontsSymbolsOnly/"
cp "$ROOT/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/LICENSE" \
  "$APP/NerdFontsSymbolsOnly/"

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl list devices available | grep -m1 -o '([0-9A-F-]\{36\})' | tr -d '()')"
fi
echo "== simulator $DEVICE =="
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"

echo "== running =="
# One launch, three screenshots: the app deliberately stays alive so probe D
# (in-place mutation, 4s) and probe E (reattach, 10s) each get a screenshot
# taken after they fire and before the next one does. The console pipe is
# backgrounded and killed at the end.
xcrun simctl launch --console-pipe "$DEVICE" "$BUNDLE_ID" > "$CONSOLE" 2>&1 &
PIPE=$!
sleep 2
xcrun simctl io "$DEVICE" screenshot "$SHOT_FIRST"
sleep 4
xcrun simctl io "$DEVICE" screenshot "$SHOT_MUTATED"
sleep 6
xcrun simctl io "$DEVICE" screenshot "$SHOT_REATTACHED"
kill "$PIPE" 2>/dev/null || true
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true

echo
echo "console:    $CONSOLE"
echo "screenshot: $SHOT_FIRST (the first rendered frame, all three probes)"
echo "screenshot: $SHOT_MUTATED (after probe D mutated the surface in place)"
echo "screenshot: $SHOT_REATTACHED (after probe E reattached the same surface)"
grep '^SPIKE' "$CONSOLE" || true
