# Upgrading Ghostty

How to update the pinned Ghostty version used by DanTerm.

## Places to update

The Ghostty tag has one source of truth:

| File | What to change |
|------|---------------|
| `.ghostty-version` | Replace the single `vX.Y.Z` line |

If the new Ghostty version requires a different Zig version, also update:

| File | What to change |
|------|---------------|
| `flake.nix` | The single Zig pin: the `zig_0_15` re-export (`zig-overlay`'s `brew."0.15.2"`) and the `zig-overlay` input |
| `build-lib.sh` | `ZIG_PKG="$SCRIPT_DIR#zig_0_15"` (only if the flake attr is renamed) |
| `.github/workflows/ci.yml` | nix-installer + `./build-lib.sh all` -- no per-workflow Zig pin to change |
| `.github/workflows/release-stable.yml` | Same |
| `.github/workflows/cache-ghosttykit.yml` | Same |
| `docs/ci.md` | Pinned versions section |

## Steps

1. **Check Ghostty release notes** for breaking API changes or new Zig
   requirements.

   Re-audit `App.drainMailbox` early returns and every embedded
   `App.Mailbox.push` path, including the `.surface_message` wrapper in
   `apprt/surface.zig`. `TickCoalescer` assumes `ghostty_app_tick` fully drains
   the app mailbox, so no push path should enqueue an early-returning
   `App.Message` such as `.quit`.

2. **Update `.ghostty-version`** to the new tag:

   ```bash
   echo v1.4.0 > .ghostty-version
   ```

3. **Rebuild GhosttyKit locally:**

   ```bash
   just build-lib
   ```

   This clones the new tag into `.ghostty-src/` and builds GhosttyKit. Fix any
   build errors from upstream API changes.

4. **Build the app and run tests:**

   ```bash
   just build
   just test
   ```

5. **Open a PR.** CI will build GhosttyKit from scratch (cache miss due to new
   tag) and verify the Swift app compiles.

6. **After the PR merges,** the GhosttyKit build is cached for subsequent CI
   runs (see below).

## CI cache

The CI, release, and cache-warmer workflows cache `lib/GhosttyKit.xcframework`
and `lib/ghostty-themes` using `actions/cache@v5`. Each workflow loads the tag
from `.ghostty-version` through `scripts/load-ghostty-version.sh`. The cache key
includes the validated tag, so upgrading the tag automatically invalidates the
cache:

```
ghosttykit-v2-{GHOSTTY_TAG}-{hash of build-lib.sh, flake.nix, flake.lock}-{runner.os}-{runner.arch}
```

The first CI run after a tag change will rebuild GhosttyKit (~5-10 min). All
subsequent runs on the same tag hit the cache and skip the build.

### Warming the cache

The CI, release, and cache-warmer workflows share the same cache key format, so
a cache populated by one workflow is reused by the others where GitHub's cache
scope allows it. After merging the upgrade PR,
`.github/workflows/cache-ghosttykit.yml` also runs on master because
`.ghostty-version` is part of its path trigger. No extra steps are needed.

### Cache invalidation

The cache also busts when `build-lib.sh`, `flake.nix`, or `flake.lock` changes
(via `hashFiles`). This means build flag changes (e.g. adding
`-Dxcframework-target=native`) and flake-side changes (e.g. bumping the
`zig-overlay` input) both trigger a rebuild even if the tag stays the same --
which is what stops a flake-only zig bump from silently reusing a GhosttyKit
built with the old, unpatched zig.
