# Upgrading Ghostty

How to update the pinned Ghostty version used by DanTerm.

## Places to update

There are four files that reference the Ghostty tag:

| File | What to change |
|------|---------------|
| `build-lib.sh` | `GHOSTTY_TAG="v1.3.0"` (line 22) |
| `.github/workflows/ci.yml` | `GHOSTTY_TAG: v1.3.0` in the `env:` block |
| `.github/workflows/release-stable.yml` | `GHOSTTY_TAG: v1.3.0` in the `env:` block |
| `docs/ci.md` | Pinned versions section |

If the new Ghostty version requires a different Zig version, also update:

| File | What to change |
|------|---------------|
| `build-lib.sh` | `ZIG_PKG="nixpkgs#zig_0_15"` (line 23) |
| `.github/workflows/ci.yml` | `version: 0.15.2` in the `mlugg/setup-zig` step |
| `.github/workflows/release-stable.yml` | Same `mlugg/setup-zig` step |
| `docs/ci.md` | Pinned versions section |

## Steps

1. **Check Ghostty release notes** for breaking API changes or new Zig
   requirements.

2. **Update all four tag references** listed above.

3. **Rebuild locally:**

   ```bash
   ./build-lib.sh
   just build
   ```

   This clones the new tag into `.ghostty-src/`, builds GhosttyKit, and compiles
   the Swift app against it. Fix any build errors from API changes.

4. **Run tests:**

   ```bash
   just test
   ```

5. **Open a PR.** CI will build GhosttyKit from scratch (cache miss due to new
   tag) and verify the Swift app compiles.

6. **After the PR merges,** the GhosttyKit build is cached for subsequent CI
   runs (see below).

## CI cache

Both workflows cache `lib/GhosttyKit.xcframework` and `lib/ghostty-themes`
using `actions/cache@v5`. The cache key includes the Ghostty tag, so upgrading
the tag automatically invalidates the cache:

```
ghosttykit-v2-{GHOSTTY_TAG}-{hash of build-lib.sh}-{runner.os}-{runner.arch}
```

The first CI run after a tag change will rebuild GhosttyKit (~5-10 min). All
subsequent runs on the same tag hit the cache and skip the build.

### Warming the cache

The CI and release workflows share the same cache key format, so a cache
populated by a CI run is reused by the release workflow (and vice versa). After
merging the upgrade PR, the cache is already warm from the PR's CI run. No extra
steps needed.

### Cache invalidation

The cache also busts when `build-lib.sh` changes (via `hashFiles`). This means
build flag changes (e.g. adding `-Dxcframework-target=native`) also trigger a
rebuild even if the tag stays the same.
