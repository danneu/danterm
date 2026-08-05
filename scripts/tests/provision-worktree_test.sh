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

mkdir -p \
    "$SOURCE/lib/GhosttyKit.xcframework" \
    "$SOURCE/lib/ghostty-themes" \
    "$SOURCE/references"
printf 'framework\n' > "$SOURCE/lib/GhosttyKit.xcframework/Info.plist"
printf 'theme\n' > "$SOURCE/lib/ghostty-themes/FixtureTheme"
printf 'reference\n' > "$SOURCE/references/fixture"

source_status_before="$(git -C "$SOURCE" status --short)"
source_digest_before="$(find "$SOURCE/lib/GhosttyKit.xcframework" "$SOURCE/lib/ghostty-themes" "$SOURCE/references" -type f -exec shasum -a 256 {} + | sort)"

# A fresh linked worktree receives every shared input without copying or changing
# the source checkout. Repeating the command preserves the same links.
(
    cd "$WORKTREE"
    "$PROVISIONER"
    "$PROVISIONER"
)

for path in lib/GhosttyKit.xcframework lib/ghostty-themes references; do
    [[ -L "$WORKTREE/$path" ]] || fail "$path was not linked"
    [[ "$(cd "$(dirname "$WORKTREE/$path")" && cd "$(readlink "$WORKTREE/$path")" && pwd)" == "$SOURCE/$path" ]] \
        || fail "$path does not resolve to the primary checkout"
done
python3 - "$REPO_ROOT" "$WORKTREE" <<'PY'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location(
    "terminal_benchmark_snapshot",
    pathlib.Path(sys.argv[1]) / "scripts/terminal_benchmark_snapshot.py",
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.digest_prerequisites(pathlib.Path(sys.argv[2]))
PY

source_status_after="$(git -C "$SOURCE" status --short)"
source_digest_after="$(find "$SOURCE/lib/GhosttyKit.xcframework" "$SOURCE/lib/ghostty-themes" "$SOURCE/references" -type f -exec shasum -a 256 {} + | sort)"
[[ "$source_status_after" == "$source_status_before" ]] \
    || fail "provisioning changed the primary checkout status"
[[ "$source_digest_after" == "$source_digest_before" ]] \
    || fail "provisioning changed shared prerequisite contents"

# Missing primary prerequisites fail before creating any partial target links.
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
mkdir -p "$MISSING_SOURCE/lib/GhosttyKit.xcframework"
printf 'framework\n' > "$MISSING_SOURCE/lib/GhosttyKit.xcframework/Info.plist"

if (cd "$MISSING_WORKTREE" && "$PROVISIONER") >"$TEST_ROOT/missing.out" 2>"$TEST_ROOT/missing.err"; then
    fail "provisioning succeeded with missing primary prerequisites"
fi
grep -qF 'lib/ghostty-themes' "$TEST_ROOT/missing.err" \
    || fail "missing-prerequisite error did not identify lib/ghostty-themes"
[[ ! -e "$MISSING_WORKTREE/lib/GhosttyKit.xcframework" ]] \
    || fail "failure left a partial prerequisite link"

echo "provision-worktree_test: ok"
