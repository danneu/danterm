#!/usr/bin/env bash
# Self-test for build-lib.sh fetch mode: updating an existing .ghostty-src/ to
# the pinned tag must not abort when a stale local `tip` tag has diverged from
# origin's `tip`. Ghostty publishes a rolling `tip` tag that moves with main; a
# plain `git fetch --tags` would try to update the stale local `tip` ("would
# clobber existing tag"), exit non-zero, and trip build-lib.sh's `set -e` before
# the pinned-tag checkout ever runs. Pins the targeted single-tag refspec that
# fetches only $GHOSTTY_TAG and leaves every other tag, including `tip`, alone.
#
# Offline and CI-portable: needs only git, runs the real `git fetch` against a
# local origin (no network), and asserts the landed commit via `rev-parse` --
# never `git describe`, which the colliding-tag bug this guards could itself fool.
set -euo pipefail
unset GITHUB_ENV

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_LIB="$ROOT_DIR/build-lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

init_repo() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.invalid"
    git -C "$dir" config user.name "Test User"
}

# Origin fixture: commit A tagged v0.0.1, commit B tagged v0.0.2, and a rolling
# `tip` tag at B -- the moving tag that diverges from the cache's stale copy.
origin="$TMP/origin"
mkdir -p "$origin"
init_repo "$origin"
printf 'a\n' > "$origin/file"
git -C "$origin" add file
git -C "$origin" commit -q -m "A"
git -C "$origin" tag v0.0.1
printf 'b\n' > "$origin/file"
git -C "$origin" add file
git -C "$origin" commit -q -m "B"
git -C "$origin" tag v0.0.2
git -C "$origin" tag tip

# Cache fixture (the .ghostty-src stand-in): checked out at v0.0.1 with a STALE
# local `tip` at A -- a different commit than origin's `tip` (B). This is the
# exact divergence that makes a `--tags` fetch reject the `tip` update.
cache="$TMP/.ghostty-src"
mkdir -p "$cache"
init_repo "$cache"
git -C "$cache" remote add origin "$origin"
git -C "$cache" fetch -q --depth 1 origin "refs/tags/v0.0.1:refs/tags/v0.0.1"
git -C "$cache" checkout -q v0.0.1
git -C "$cache" tag tip v0.0.1

version_file="$TMP/.ghostty-version"
printf 'v0.0.2\n' > "$version_file"

# Fetch must advance the cache to the pinned tag without aborting on the
# divergent `tip`. The old `git fetch --tags` line rejects the clobbering tip
# and exits non-zero here; the targeted single-tag refspec leaves tip untouched.
GHOSTTY_VERSION_FILE="$version_file" GHOSTTY_CACHE_DIR="$cache" \
    "$BUILD_LIB" fetch >"$TMP/stdout" 2>"$TMP/stderr" \
    || fail "fetch aborted (divergent tip clobber?); stderr: $(cat "$TMP/stderr")"

# Assert the checkout landed on v0.0.2 by commit OID. Compare via rev-parse, not
# `git describe`, so the colliding-tag bug can't fool the assertion itself.
head="$(git -C "$cache" rev-parse HEAD)"
want="$(git -C "$cache" rev-parse "v0.0.2^{commit}")"
[ "$head" = "$want" ] || fail "cache HEAD ($head) not at v0.0.2 ($want) after fetch"

echo "build-lib tip-tag fetch self-test passed"
