#!/usr/bin/env bash
# Contract test for scripts/bundle-theme-resources.sh: the bundler is the only thing
# that puts the runtime theme catalog and the symbol font into an app bundle, and both
# release and dev builds call it late enough that a silent no-op ships a broken app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "bundle-theme-resources_test: $*" >&2
    exit 1
}

root="$TEST_ROOT/repo"
symbols="$root/lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly"
mkdir -p "$root/scripts" "$root/themes" "$symbols"
cp "$ROOT_DIR/scripts/bundle-theme-resources.sh" "$root/scripts/"
cp "$ROOT_DIR/scripts/pack-theme-catalog.py" "$root/scripts/"
cp "$ROOT_DIR/themes/0x96f.json" "$root/themes/"
printf 'font\n' > "$symbols/SymbolsNerdFontMono-Regular.ttf"
printf 'license\n' > "$symbols/LICENSE"

app="$TEST_ROOT/app/DanTerm.app"
if ! "$root/scripts/bundle-theme-resources.sh" "$root" "$app" >"$TEST_ROOT/out" 2>&1; then
    echo "--- bundler output ---" >&2
    cat "$TEST_ROOT/out" >&2
    fail "the bundler failed on a complete repository fixture"
fi

resources="$app/Contents/Resources"
[[ -f "$resources/themes/catalog.json" ]] \
    || fail "the bundle has no packed theme catalog"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$resources/themes/catalog.json" \
    || fail "the packed theme catalog is not valid JSON"
grep -qF '0x96f' "$resources/themes/catalog.json" \
    || fail "the packed catalog does not contain the fixture theme"
[[ -f "$resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf" ]] \
    || fail "the bundle is missing the Nerd Fonts symbol font"
[[ -f "$resources/NerdFontsSymbolsOnly/LICENSE" ]] \
    || fail "the bundle is missing the symbol font license"

echo "bundle-theme-resources tests passed"
