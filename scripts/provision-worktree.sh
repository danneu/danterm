#!/usr/bin/env bash
# Link shared external prerequisites from the primary checkout into this worktree.
set -euo pipefail

fail() {
    echo "provision-worktree: $*" >&2
    exit 1
}

WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || fail "run this command from a DanTerm linked worktree"
WORKTREE_ROOT="$(cd "$WORKTREE_ROOT" && pwd -P)"
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || fail "could not locate the shared Git directory"
PRIMARY_ROOT="$(cd "$COMMON_DIR/.." && pwd -P)"

[[ "$WORKTREE_ROOT" != "$PRIMARY_ROOT" ]] \
    || fail "the current checkout is the primary checkout, not a linked worktree"

PREREQUISITES=(
    "references"
)

# Validate the full operation before creating anything so a missing source or a
# conflicting worktree path cannot leave a partially provisioned checkout.
for relative_path in "${PREREQUISITES[@]}"; do
    source_path="$PRIMARY_ROOT/$relative_path"
    target_path="$WORKTREE_ROOT/$relative_path"

    [[ -d "$source_path" ]] \
        || fail "primary checkout prerequisite is missing: $relative_path"
    [[ -n "$(find "$source_path" -mindepth 1 -print -quit 2>/dev/null)" ]] \
        || fail "primary checkout prerequisite is empty: $relative_path"

    if [[ -L "$target_path" ]] && [[ "$target_path" -ef "$source_path" ]]; then
        continue
    fi
    [[ ! -e "$target_path" && ! -L "$target_path" ]] \
        || fail "worktree path already exists and is not the expected link: $relative_path"
done

for relative_path in "${PREREQUISITES[@]}"; do
    source_path="$PRIMARY_ROOT/$relative_path"
    target_path="$WORKTREE_ROOT/$relative_path"
    if [[ -L "$target_path" ]] && [[ "$target_path" -ef "$source_path" ]]; then
        continue
    fi
    mkdir -p "$(dirname "$target_path")"
    ln -s "$source_path" "$target_path"
done

echo "provision-worktree: linked shared prerequisites from $PRIMARY_ROOT"
