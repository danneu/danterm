#!/usr/bin/env bash
# Pack DanTerm's runtime catalog and retain raw Ghostty themes for the legacy backend.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 REPOSITORY_ROOT APP_PATH" >&2
    exit 2
fi

repository_root="$1"
app_path="$2"
resources="$app_path/Contents/Resources"

# -L because `just provision-worktree` links lib/ghostty-themes into a worktree rather
# than copying it. Without it `find` refuses to descend a symlink named on its command
# line, so `-mindepth 1` matches nothing and a populated directory reads as empty --
# while the `-d` test right before it follows the link and disagrees.
directory_has_entries() {
    [[ -d "$1" ]] && [[ -n "$(find -L "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

python3 "$repository_root/scripts/pack-theme-catalog.py" \
    --source "$repository_root/themes" \
    --output "$resources/themes/catalog.json"

symbols_source="$repository_root/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly"
mkdir -p "$resources/NerdFontsSymbolsOnly"
cp "$symbols_source/SymbolsNerdFontMono-Regular.ttf" "$resources/NerdFontsSymbolsOnly/"
cp "$symbols_source/LICENSE" "$resources/NerdFontsSymbolsOnly/"

legacy_source="$repository_root/lib/ghostty-themes"
if ! directory_has_entries "$legacy_source"; then
    legacy_source="$repository_root/.ghostty-src/zig-out/share/ghostty/themes"
fi
if ! directory_has_entries "$legacy_source"; then
    echo "Ghostty themes are missing; run ./build-lib.sh once." >&2
    exit 1
fi

mkdir -p "$resources/ghostty"
# -H resolves a symlinked $legacy_source (the worktree shape) so the bundle receives the
# themes themselves. Plain -R would copy the link, leaving the app pointing at an
# absolute path outside itself that works only on the machine that built it. It stops at
# the argument: anything linked *inside* the theme tree is still copied as found.
cp -RH "$legacy_source" "$resources/ghostty/themes"
