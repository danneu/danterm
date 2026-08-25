#!/usr/bin/env bash
# Copies the iOS app bundle's payload: the built product, plus every resource the
# phone reads at runtime.
#
# It is a script of its own because scripts/ios-app.sh cannot run without an SDK, a
# simulator or paired device, and a signing identity, while this step is pure file
# copying. Splitting it is what lets scripts/tests/ios-app_test.sh prove the payload
# is complete without any of that.
#
# Every source is a fixed repository path. A resource that moves has to fail here by
# name: the bundle would otherwise sign, install, and launch into nothing, and no
# compile or lint would have seen it.
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: assemble-ios-app.sh REPOSITORY_ROOT BINARY_DIR ICON_DIR ICON_INFO APP_PATH" >&2
    exit 2
fi

repository_root="$1"
binary_dir="$2"
icon_source="$3"
icon_info_source="$4"
app_path="$5"

symbols_source="$repository_root/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly"
plist_source="$repository_root/ios/DanTermMobileApp/Info.plist"
theme_source="$repository_root/themes/Builtin Dark.json"
product_source="$binary_dir/DanTermMobileApp"

# Checked up front, all of them, before anything is written: a bundle half-assembled
# and then abandoned is easy to mistake for a stale one.
require() {
    [[ -f "$1" ]] || {
        echo "assemble-ios-app: missing '$1'" >&2
        exit 1
    }
}

require "$product_source"
require "$plist_source"
require "$symbols_source/SymbolsNerdFontMono-Regular.ttf"
require "$symbols_source/LICENSE"
require "$theme_source"
require "$icon_source/Assets.car"
require "$icon_info_source"

rm -rf "$app_path"
mkdir -p "$app_path/NerdFontsSymbolsOnly" "$app_path/Themes"
cp "$product_source" "$app_path/DanTermMobileApp"
cp "$plist_source" "$app_path/Info.plist"
cp "$symbols_source/SymbolsNerdFontMono-Regular.ttf" "$app_path/NerdFontsSymbolsOnly/"
cp "$symbols_source/LICENSE" "$app_path/NerdFontsSymbolsOnly/"
cp "$theme_source" "$app_path/Themes/"
cp -R "$icon_source"/. "$app_path/"
python3 - "$app_path/Info.plist" "$icon_info_source" <<'PY'
import plistlib
import sys

plist_path, icon_info_path = sys.argv[1:]
with open(plist_path, "rb") as stream:
    plist = plistlib.load(stream)
with open(icon_info_path, "rb") as stream:
    plist.update(plistlib.load(stream))
with open(plist_path, "wb") as stream:
    plistlib.dump(plist, stream)
PY
