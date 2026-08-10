#!/usr/bin/env bash
# Behavioral contract test for linked-worktree prerequisite provisioning.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROVISIONER="$REPO_ROOT/scripts/provision-worktree.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"

fail() {
    echo "provision-worktree_test: $*" >&2
    exit 1
}

SOURCE="$TEST_ROOT/source"
WORKTREE="$TEST_ROOT/worktree"
mkdir -p "$SOURCE"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name "Test User"
printf 'fixture\n' > "$SOURCE/tracked"
git -C "$SOURCE" add tracked
git -C "$SOURCE" commit -q -m initial
git -C "$SOURCE" worktree add -q -b worktree "$WORKTREE"

mkdir -p "$SOURCE/references"
printf 'reference\n' > "$SOURCE/references/fixture"

source_status_before="$(git -C "$SOURCE" status --short)"
source_digest_before="$(find "$SOURCE/references" -type f -exec shasum -a 256 {} + | sort)"

# A fresh linked worktree receives every shared input without copying or changing
# the source checkout. Repeating the command preserves the same links.
(
    cd "$WORKTREE"
    "$PROVISIONER"
    "$PROVISIONER"
)

[[ -L "$WORKTREE/references" ]] || fail "references was not linked"
[[ "$(cd "$WORKTREE/references" && pwd -P)" == "$SOURCE/references" ]] \
    || fail "references does not resolve to the primary checkout"

source_status_after="$(git -C "$SOURCE" status --short)"
source_digest_after="$(find "$SOURCE/references" -type f -exec shasum -a 256 {} + | sort)"
[[ "$source_status_after" == "$source_status_before" ]] \
    || fail "provisioning changed the primary checkout status"
[[ "$source_digest_after" == "$source_digest_before" ]] \
    || fail "provisioning changed shared prerequisite contents"

# A missing primary prerequisite fails without creating any target link.
MISSING_SOURCE="$TEST_ROOT/missing-source"
MISSING_WORKTREE="$TEST_ROOT/missing-worktree"
mkdir -p "$MISSING_SOURCE"
git -C "$MISSING_SOURCE" init -q
git -C "$MISSING_SOURCE" config user.email test@example.invalid
git -C "$MISSING_SOURCE" config user.name "Test User"
printf 'fixture\n' > "$MISSING_SOURCE/tracked"
git -C "$MISSING_SOURCE" add tracked
git -C "$MISSING_SOURCE" commit -q -m initial
git -C "$MISSING_SOURCE" worktree add -q -b missing-worktree "$MISSING_WORKTREE"

if (cd "$MISSING_WORKTREE" && "$PROVISIONER") >"$TEST_ROOT/missing.out" 2>"$TEST_ROOT/missing.err"; then
    fail "provisioning succeeded with missing primary prerequisites"
fi
grep -qF 'references' "$TEST_ROOT/missing.err" \
    || fail "missing-prerequisite error did not identify references"
[[ ! -e "$MISSING_WORKTREE/references" ]] \
    || fail "failure left a prerequisite link behind"

echo "provision-worktree_test: ok"
