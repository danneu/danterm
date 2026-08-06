#!/usr/bin/env bash
# Pack DanTerm's runtime theme catalog and the bundled symbol font into an app bundle.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 REPOSITORY_ROOT APP_PATH" >&2
    exit 2
fi

repository_root="$1"
app_path="$2"
resources="$app_path/Contents/Resources"

python3 "$repository_root/scripts/pack-theme-catalog.py" \
    --source "$repository_root/themes" \
    --output "$resources/themes/catalog.json"

symbols_source="$repository_root/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly"
mkdir -p "$resources/NerdFontsSymbolsOnly"
cp "$symbols_source/SymbolsNerdFontMono-Regular.ttf" "$resources/NerdFontsSymbolsOnly/"
cp "$symbols_source/LICENSE" "$resources/NerdFontsSymbolsOnly/"
