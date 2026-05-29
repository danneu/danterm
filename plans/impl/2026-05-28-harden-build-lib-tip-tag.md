# Harden build-lib.sh against Ghostty's rolling `tip` tag

## Context

`./build-lib.sh all` (and `fetch`) updates the cached Ghostty checkout in
`.ghostty-src/` to the pinned tag. The update step is:

```sh
# build-lib.sh:48
git -C "$CACHE_DIR" fetch --tags --depth 1 origin "$GHOSTTY_TAG"
```

The `--tags` flag fetches **all** remote tags, not just `$GHOSTTY_TAG`. Ghostty
publishes a rolling `tip` tag that moves with `main`. Once `.ghostty-src/` has a
stale local `tip` from an earlier fetch, the next `--tags` fetch tries to update
that local tag to the new remote target, git refuses
(`! [rejected] tip -> tip (would clobber existing tag)`), and the non-zero exit
trips `set -euo pipefail` -- aborting the whole build **before the version
checkout**, even though `$GHOSTTY_TAG` itself fetched fine.

This bit the v1.3.1 bump (worked around by checking out `v1.3.1` by hand, then
`./build-lib.sh build`). CI is unaffected for the *fetch* path because it does a
fresh `git clone --depth 1 --branch "$GHOSTTY_TAG"` (line 56) with no stale `tip`.

A second, related hazard from the same rolling tag: the cache-state check uses

```sh
# build-lib.sh:38
ghostty_tag_at_cache() { git -C "$CACHE_DIR" describe --tags --exact-match ...; }
```

`git describe --tags --exact-match` returns *some* tag at HEAD, and when several
tags share that commit it can pick the wrong one. If a stale local `tip` points
at the same commit as the pinned release tag (entirely possible -- release tags
are cut from `main`, which is what `tip` tracks), `describe` can report `tip`,
and `build_xcframework`'s stale guard (line 73-77) then rejects a *correct*
checkout as stale and exits 1. (An annotated `tip` outranks a lightweight
release tag under `describe`, so this is deterministic, not a coin flip.)

Goal: make both the fetch and the cache-state check ignore every tag but the one
we actually pin, so a divergent or colliding rolling tag can never derail a bump.

## Root cause

The rolling `tip` tag is a bystander that both build steps wrongly let influence
them: the fetch tries to *update* it (clobber), and the cache check can *read* it
instead of the pinned tag. We never need any tag but `$GHOSTTY_TAG`.

## The fix

Two narrow changes in `/Users/dan/world/my-apps/danterm/build-lib.sh`, both
scoping the steps down to the pinned tag only.

### 1. Fetch only the pinned tag (the clobber-abort)

Replace the `--tags` fetch with a single-tag refspec that also writes the pinned
tag into the local tag namespace (so the following `git checkout "$GHOSTTY_TAG"`
still resolves it):

```sh
# inside fetch_ghostty(), the `if [ -d "$CACHE_DIR/.git" ]` branch
# Fetch only the pinned tag. Plain `--tags` pulls every remote tag, including
# Ghostty's rolling `tip`; a stale local `tip` then can't be updated
# ("would clobber existing tag") and aborts the bump under `set -e`. Targeting
# refs/tags/<tag> writes the local tag ref (checkout below needs it) and leaves
# every other tag, including `tip`, untouched.
git -C "$CACHE_DIR" fetch --depth 1 origin \
    "refs/tags/$GHOSTTY_TAG:refs/tags/$GHOSTTY_TAG"
```

`refs/tags/<tag>:refs/tags/<tag>` fetches just that tag plus its objects and
updates the local tag ref. (`git fetch origin tag "$GHOSTTY_TAG"` is the exact
shorthand for the same refspec; the explicit form is used so the intent --
"write this one local tag" -- is self-evident.)

### 2. Decide cache freshness by commit OID, not by tag name (the false-stale)

Add a predicate that compares HEAD's commit to the commit `$GHOSTTY_TAG` points
at, instead of asking `describe` to *name* the tag at HEAD:

```sh
# True when the cache checkout's HEAD is exactly the commit $GHOSTTY_TAG names.
# Compares resolved commit OIDs rather than `git describe --exact-match`, which
# can report a *different* tag sharing the commit (e.g. Ghostty's rolling `tip`)
# and so mis-detect a correct checkout as stale. `^{commit}` peels annotated
# tags; returns non-zero (treated as "not current") if HEAD or the tag is absent.
cache_at_pinned_tag() {
    local head pinned
    head="$(git -C "$CACHE_DIR" rev-parse --verify --quiet HEAD)" || return 1
    pinned="$(git -C "$CACHE_DIR" rev-parse --verify --quiet "refs/tags/$GHOSTTY_TAG^{commit}")" || return 1
    [ "$head" = "$pinned" ]
}
```

Use it in both decision sites:

- `fetch_ghostty`: `if ! cache_at_pinned_tag; then ...fetch+checkout... fi`
- `build_xcframework`: `if ! cache_at_pinned_tag; then stale_source_error "$(ghostty_tag_at_cache)"; exit 1; fi`

Keep `ghostty_tag_at_cache()` only for **diagnostics** -- the `stale_source_error`
message, where reporting whatever the cache is actually at (`tip`, `unknown`,
another version) is the useful human hint. The two success echoes that currently
print `$(ghostty_tag_at_cache)` (lines 58, 79) should print `$GHOSTTY_TAG`
directly: once the decision is commit-based we *know* HEAD is at the pinned tag,
so echoing the pinned name is both accurate and immune to the `tip` collision.

### Why not the implementor's two suggestions (for change 1)

- **Drop `--tags` entirely** (`git fetch --depth 1 origin "$GHOSTTY_TAG"`):
  without a `:dest` refspec the result lands only in `FETCH_HEAD`; whether
  `refs/tags/$GHOSTTY_TAG` gets created depends on git's opportunistic
  tag-following, so the following `git checkout "$GHOSTTY_TAG"` relies on luck.
  The explicit refspec guarantees the local tag exists.
- **`--tags --force`**: works, but still over-fetches every remote tag and
  force-moves the local `tip` on every bump for no reason. We don't want `tip`.

No `+` (force) prefix on the refspec: release tags are immutable and the new
pinned tag won't pre-exist locally, so forcing buys nothing and would only serve
to silently accept an upstream-moved release tag. The stale local `tip` left
behind in `.ghostty-src/` is now genuinely inert -- nothing fetches it (change 1)
and nothing reads it for the freshness decision (change 2).

## Regression tests

Two distinct rolling-`tip` failure modes, two fixtures, both offline and CI-portable
(need only `git`), following the house conventions in the existing self-tests
(`set -euo pipefail`, `mktemp -d` + `trap`, local git fixtures, `grep`/exit-code
assertions).

### A. Fetch must not abort on a *divergent* `tip` -- new file

Add `/Users/dan/world/my-apps/danterm/scripts/tests/build-lib-fetch_test.sh`,
exercising the real `git fetch` against a **local** origin (no network):

1. **Origin fixture repo**: commit A tagged `v0.0.1`; commit B tagged `v0.0.2`;
   a `tip` tag pointing at B.
2. **Cache repo** (`.ghostty-src` stand-in): `git init`, add the origin repo's
   path as remote `origin`, fetch + checkout `v0.0.1`, then create a **stale**
   local `tip` tag at A -- a *different* commit than origin's `tip` (B). This is
   the exact "stale local tip" that triggers the clobber.
3. `.ghostty-version` fixture = `v0.0.2`.
4. Run `GHOSTTY_VERSION_FILE=... GHOSTTY_CACHE_DIR=... "$BUILD_LIB" fetch`.

Assert: exit 0, and `git -C "$cache" rev-parse HEAD` equals
`git -C "$cache" rev-parse "v0.0.2^{commit}"` (the checkout landed). Assert via
`rev-parse`, not `describe`, so the assertion itself is collision-proof. Fails
on the current `--tags` line (clobber abort), passes with the targeted refspec.

### B. Build guard must not false-reject on a *colliding* `tip` -- extend the contract test

The false-stale bug lives in `build_xcframework`'s guard, which needs the full
nix/xcodebuild/nm shim harness to reach. `build-lib-contract_test.sh` already
builds that harness and already asserts a successful build against a cache
checked out at the pinned tag (lines 53-63, 108-109) -- the ideal host. Extend
its fixture with **one line + comment**: after tagging the cache at `$GHOSTTY_TAG`,
add a colliding annotated `tip` at the same commit:

```sh
# Regression: a rolling `tip` tag colliding with the pinned commit must not fool
# the cache-state check. `tip` is annotated, so it outranks the lightweight
# pinned tag under `git describe --tags`; the old describe-based guard would
# report HEAD as `tip` and wrongly reject this correct checkout as stale.
git -C "$CACHE_DIR" tag -a -m tip tip
```

The test's existing "build succeeds" assertion now also guards this regression:
old (describe-based) guard -> reports `tip` -> stale error -> build fails ->
test fails; new (commit-OID) guard -> passes. No new shims; the contract test is
already a CI step, so this case is automatically covered in CI.

### Wiring (covers finding: CI runs self-tests individually, not `just test`)

CI's `validator-self-test` job enumerates each shell self-test as its own step
(`.github/workflows/ci.yml:176-188`) and does **not** invoke `just test`, so the
*new* file (A) must be wired in both places; the contract-test change (B) needs
no wiring (already in both):

- `/Users/dan/world/my-apps/danterm/justfile` (`test` recipe): add
  `./scripts/tests/build-lib-fetch_test.sh` immediately after the stale-guard test.
- `.github/workflows/ci.yml` `validator-self-test`: add a step beside the
  stale-guard and contract steps:
  ```yaml
  - name: build-lib tip-tag fetch self-test
    run: ./scripts/tests/build-lib-fetch_test.sh
  ```

### Docs touch-up (optional, low priority)

`AGENTS.md`'s `just test` description says "three shell self-tests" and already
omits the existing `build-lib-contract_test.sh` (the justfile runs four; the new
file makes five). Refresh that enumeration to match the justfile while here.

## Verification

End-to-end, offline:

1. **New fetch test:** `bash scripts/tests/build-lib-fetch_test.sh` -> pass line, exit 0.
2. **Contract test (collision case):** `bash scripts/tests/build-lib-contract_test.sh` -> still passes with the added colliding `tip`.
3. **TDD check both pin their bugs:** stash each build-lib.sh change in turn and
   rerun the matching test -- (A) must fail with a clobber/non-zero error against
   the old `--tags` line; (B) must fail with a stale-source error against the old
   `describe`-based guard. Restore the fixes -> both pass.
4. **Full local gate:** `just test` -> all green.
5. **Real bump smoke test (manual, network):** with a `.ghostty-src/` carrying a
   stale `tip`, `./build-lib.sh all` now updates to the pinned tag and builds
   without aborting or false-rejecting.
