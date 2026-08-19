#!/usr/bin/env bash
# Enforces that the generated chip artwork and the chip renderer stand alone:
# they import CoreGraphics and nothing else, and they compile as two loose files
# with no other source from their package.
#
# That isolation is not a style rule. `icon/render-check.sh` grades the renderer
# by compiling exactly these two files with `swiftc` against `icon/render-check`,
# so an import or a reference reaching into the rest of the ChipArtwork package
# breaks the only check that proves a chip still looks like the preview page --
# and it breaks it in a script no gate runs, months after the change.
#
# Reading the imports is not enough on its own: a reference to a sibling type
# needs no import inside a module, and only a real compile sees it. Both halves
# run here.
#
# Usage: scripts/chip-artwork-isolation-gate.sh [SOURCE_DIR]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Test seam: the self-test points the gate at a fixture pair of tiny files, so
# each verdict is proved without the real artwork. Nothing else passes this.
SOURCE_DIR="${1:-$REPO_ROOT/lib/ChipArtwork/Sources/ChipArtwork}"

FILES=(ChipArtwork.swift ChipRenderer.swift)
ALLOWED_IMPORT="CoreGraphics"

fail() { echo "chip-artwork-isolation-gate: $*" >&2; exit 1; }

paths=()
for name in "${FILES[@]}"; do
    path="$SOURCE_DIR/$name"
    [[ -f "$path" ]] || fail "$path is missing; this gate names a file that no longer exists."
    paths+=("$path")
done

for path in "${paths[@]}"; do
    while read -r module; do
        [[ "$module" == "$ALLOWED_IMPORT" ]] && continue
        fail "$path imports $module. These two files must name $ALLOWED_IMPORT and nothing
    else, so icon/render-check.sh can compile them loose. Whatever needs the other
    module belongs in a sibling file such as ChipKindArtwork.swift."
    done < <(sed -n 's/^[[:space:]]*\(@[A-Za-z]*[[:space:]]*\)*import[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_.]*\).*/\2/p' "$path")
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! swiftc -typecheck -module-name ChipArtworkIsolationProbe "${paths[@]}" \
    -module-cache-path "$WORK/module-cache" 2>"$WORK/errors"; then
    cat "$WORK/errors" >&2
    fail "the artwork and the renderer do not compile on their own. They may use nothing
    from the rest of their package -- icon/render-check.sh builds exactly these two
    files. Move whatever they reached for into a sibling file."
fi

echo "chip-artwork-isolation-gate: ${#paths[@]} files compile against $ALLOWED_IMPORT alone"
