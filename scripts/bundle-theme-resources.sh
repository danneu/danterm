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

directory_has_entries() {
    [[ -d "$1" ]] && [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

python3 "$repository_root/scripts/pack-theme-catalog.py" \
    --source "$repository_root/themes" \
    --output "$resources/themes/catalog.json"

legacy_source="$repository_root/lib/ghostty-themes"
if ! directory_has_entries "$legacy_source"; then
    legacy_source="$repository_root/.ghostty-src/zig-out/share/ghostty/themes"
fi
if ! directory_has_entries "$legacy_source"; then
    echo "Ghostty themes are missing; run ./build-lib.sh once." >&2
    exit 1
fi

mkdir -p "$resources/ghostty"
cp -R "$legacy_source" "$resources/ghostty/themes"
