# Fix `./build-lib.sh` SDK 26.5 link failure via zig-overlay brew bottle

## Context

`./build-lib.sh` fails on 2026-05-28 with a wall of "undefined symbol"
errors for every libSystem function (`_abort`, `_bzero`,
`_clock_gettime`, `__availability_version_check`, ...) referenced from
zig's bundled `libcompiler_rt.a` and the build runner. No DanTerm code
changed.

Root cause: on 2026-05-27 Apple's Command Line Tools were upgraded to
26.5. The new SDK rewrote `/usr/lib/libSystem.B.tbd`'s `targets:` line
from `arm64-macos` to `arm64e-macos` (same change first shipped by
Xcode 26.4). Zig 0.15.2's MachO linker
(`src/link/MachO/Dylib.zig`'s `TargetMatcher`) only matches
`aarch64-macos` against the old form, so it silently fails to resolve
the stub and every libSystem symbol comes out undefined. The fix
landed on Zig master (PR #31673, `TargetMatcher` refactor) and is in
Zig 0.16; per Ghostty issue #11991 it will **not** be back-ported to
0.15.x. Ghostty's own Zig 0.16 migration (issue #12228) is open and
in-progress; Ghostty `1.3.2-dev` still declares
`minimum_zig_version = "0.15.2"`, so DanTerm's pinned v1.3.0 cannot
move to 0.16 to inherit the fix.

The bug also reaches CI. `ci.yml` (`build`, `release-build-check`)
and `release-stable.yml` (`release`) all `runs-on: macos-26` and pull
stock Zig 0.15.2 via `mlugg/setup-zig@v2`. Today CI is green only
because the GhosttyKit cache (key `hashFiles('build-lib.sh')`) is
hitting on artifacts built before the SDK regression; every job skips
the `Build GhosttyKit` step. The next thing that invalidates the
cache -- a `build-lib.sh` edit, a `.ghostty-version` bump, the 7-day
unused-cache eviction, GitHub retiring `macos-15` (the older-SDK
runner that `cache-ghosttykit.yml` uses to keep the cache warm), or
a tag push that lands on a fresh release runner -- will hit the
broken zig and fail. A tag push is the worst-time discovery moment.

Ghostty solved this same bug for their own builds in PR #12363 by
switching their Darwin nix devShell to consume
**`mitchellh/zig-overlay`'s `packages.<system>.brew."0.15.2"`**
namespace -- a Nix derivation that wraps Homebrew's binary bottle
of patched Zig 0.15.2. The zig-overlay README documents the
derivation as self-contained: "all dylib dependencies (LLVM, LLD,
zstd) are bundled and patched so no Homebrew installation is
required at runtime." Confirmed:
`nix eval --raw 'github:mitchellh/zig-overlay#packages.aarch64-darwin.brew."0.15.2".version'`
resolves to `0.15.2`. Homebrew maintains the patch; zig-overlay
packages the bottle; we consume via `nix shell`. No vendored patch,
no source rebuild, no hosting.

Intended outcome: every GhosttyKit build path -- local
`just build-lib`, all three CI workflows -- consumes the same
patched Zig 0.15.2 from `zig-overlay.packages.<system>.brew."0.15.2"`,
without sudo, without mutating the system SDK.

## Approach

Define one patched-Zig contract for every GhosttyKit build path:

1. **DanTerm's flake** (`my-apps/danterm/flake.nix`) gains a
   `mitchellh/zig-overlay` input and exposes
   `packages.${system}.zig_0_15` as
   `zig-overlay.packages.${system}.brew."0.15.2"`.
2. **`build-lib.sh`** swaps `ZIG_PKG="nixpkgs#zig_0_15"` for
   `ZIG_PKG="$SCRIPT_DIR#zig_0_15"`, pulling Zig from the local flake.
3. **CI workflows** drop `mlugg/setup-zig` for GhosttyKit builds.
   Each GhosttyKit job installs Nix
   (`DeterminateSystems/nix-installer-action@v22`, already used in
   `ci.yml`'s `cliff-smoke` job and `release-stable.yml`'s release
   job) and calls `./build-lib.sh all`, the same entry point local
   builds use. This collapses three CI steps (clone, cache-gated
   inline zig build, copy artifacts) into one cache-gated script
   call, with no duplication of zig build flags between bash and
   YAML.

This is the same fix mechanism Ghostty themselves apply
(PR #12363). The brew bottle is built by Homebrew, packaged by
zig-overlay, consumed by both projects. If Homebrew's bottle ever
regresses, Ghostty's own CI breaks first and we benefit from their
larger fix loop.

The flake exposes `zig_0_15` only as a `packages.<system>` output,
**not** added to `overlays.default`. `~/world` consumes
`danterm.overlays.default` (per `~/world/agent-docs/flake-architecture.md`'s
"Overlay policy" section, which lists `danterm.overlays.default`
among the reserved global-replacement overlays) and we don't want
every consumer of that overlay to inherit a patched system-wide
zig -- the patch is for the GhosttyKit build only.

## Critical files

### 1. Edit: `my-apps/danterm/flake.nix`

**Add the input** next to the existing `nixpkgs` input:

```nix
inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
inputs.zig-overlay = {
  url = "github:mitchellh/zig-overlay";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Following our `nixpkgs` keeps `flake.lock` from carrying a second
nixpkgs node. The brew derivation is self-contained (LLVM/LLD/zstd
dylibs bundled from Homebrew's bottle), so the bundled deps come
from Homebrew regardless of which nixpkgs wraps the derivation.

**Update the outputs destructuring**:

```nix
outputs = { self, nixpkgs, zig-overlay }:
```

**Add the `zig_0_15` package output** in the `appSystems` branch of
`packages.forEachSystem` (currently the branch that holds just
`default = pkgs.danterm`):

```nix
} // nixpkgs.lib.optionalAttrs (builtins.elem system appSystems) {
  default = pkgs.danterm;
  # Patched Zig 0.15.2 for macOS 26.4+ SDK compatibility.
  #
  # Apple's Xcode 26.4 / Command Line Tools 26.4-26.5 rewrote
  # /usr/lib/libSystem.B.tbd's targets from `arm64-macos` to
  # `arm64e-macos`. Zig 0.15.2's MachO linker
  # (src/link/MachO/Dylib.zig's TargetMatcher) only matches
  # `aarch64-macos` against the old form, so without a patch every
  # libSystem symbol -- _abort, _bzero, _clock_gettime,
  # __availability_version_check, ... -- is undefined and
  # `./build-lib.sh` fails before producing GhosttyKit.xcframework.
  # The fix is in Zig 0.16 (PR #31673) but will NOT be back-ported
  # to 0.15.x (per Ghostty issue #11991).
  #
  # This re-exports mitchellh/zig-overlay's Homebrew-bottled patched
  # 0.15.2. Homebrew applies the fix; zig-overlay wraps the bottle
  # as a self-contained Nix derivation (LLVM/LLD/zstd dylibs
  # bundled). Ghostty itself uses this mechanism (PR #12363).
  #
  # Exposed only as packages.<system>, NOT added to overlays.default:
  # the patch is for the GhosttyKit build only; ~/world's overlay
  # consumers should not inherit a patched system-wide zig.
  #
  # Remove this re-export (and the zig-overlay input) once
  # .ghostty-version bumps to a tag that requires Zig 0.16+ -- then
  # `nixpkgs#zig_0_16` is sufficient.
  #
  # Refs:
  #   - https://codeberg.org/ziglang/zig/issues/31658 (root cause)
  #   - https://codeberg.org/ziglang/zig/pulls/31673  (upstream fix)
  #   - https://github.com/ghostty-org/ghostty/issues/11991 (Ghostty hit it)
  #   - https://github.com/ghostty-org/ghostty/pull/12363 (Ghostty's fix)
  zig_0_15 = zig-overlay.packages.${system}.brew."0.15.2";
}
```

### 2. Refresh: `my-apps/danterm/flake.lock`

```
nix flake lock
```

Adds the `zig-overlay` pin. No other inputs change.

### 3. Edit: `my-apps/danterm/build-lib.sh`

Three changes, because `build-lib.sh` is becoming the single
GhosttyKit-build entry point shared by local and CI.

**(a)** Change the `ZIG_PKG` constant (line 20) so `nix shell`
resolves zig from the local flake instead of the system nixpkgs
registry:

```bash
# Pull zig from this repo's flake -- it carries a patch for
# macOS 26.4+ SDK compatibility (see flake.nix for details).
# gettext stays on system nixpkgs; it doesn't need the patch.
ZIG_PKG="$SCRIPT_DIR#zig_0_15"
```

**(b)** Add `-Dxcframework-target=native` to the `zig build`
invocation (currently lines 85-89). CI passes this flag today in
every workflow (`ci.yml:131`, `release-stable.yml:63`,
`cache-ghosttykit.yml:58`); `docs/ci.md:41` notes the universal
build fails due to x86_64 cross-compilation SDK issues. Adding the
flag to `build-lib.sh` keeps the unified-entry-point approach
honest -- without it, CI's `./build-lib.sh all` would silently
attempt a universal build and fail.

```bash
nix shell "$ZIG_PKG" nixpkgs#gettext --command zig build \
    -Demit-xcframework \
    -Dxcframework-target=native \
    -Demit-macos-app=false \
    -Dsentry=false \
    -Doptimize=ReleaseFast
```

DanTerm targets aarch64-darwin only (`package.nix`'s
`meta.platforms`), so dropping x86_64 from the xcframework is
invariant-preserving for local consumers -- the universal output
today is dead weight.

**(c)** After copying the xcframework, also copy
`zig-out/share/ghostty/themes` to `$LIB_DIR/ghostty-themes`. CI's
cache today persists both paths (`actions/cache` `path:` list in
all three workflows); `build-app.sh:67-80` looks first in
`lib/ghostty-themes` and falls back to `.ghostty-src/zig-out/share/ghostty/themes`.
On a CI cache hit `.ghostty-src/zig-out` doesn't exist, so themes
**must** live in `lib/ghostty-themes` for the bundle step to
succeed. Today the inline workflow step does this copy; with
`./build-lib.sh all` as the unified entry, the script must own it.

```bash
THEMES_SRC="$CACHE_DIR/zig-out/share/ghostty/themes"
if [ ! -d "$THEMES_SRC" ] || [ -z "$(ls -A "$THEMES_SRC" 2>/dev/null)" ]; then
    echo "Error: themes not found or empty at $THEMES_SRC" >&2
    exit 1
fi
rm -rf "$LIB_DIR/ghostty-themes"
cp -R "$THEMES_SRC" "$LIB_DIR/ghostty-themes"
```

Update the closing "Done!" log line to mention both artifacts.

### 4. Add: `scripts/tests/build-lib-contract_test.sh`

Section #3 adds three behaviors to `build-lib.sh` that no existing
test pins: (a) the build invocation uses `"$SCRIPT_DIR#zig_0_15"`
(so the patched flake-side zig is used, not stock `nixpkgs#zig_0_15`),
(b) the `-Dxcframework-target=native` flag is passed (so the build
doesn't silently fall into a broken universal cross-compile), and
(c) both `lib/GhosttyKit.xcframework/` and `lib/ghostty-themes/`
are populated after a successful build (CI's cache-hit path
depends on both). The existing shell self-tests
(`core-purity-lint_test.sh`, `load-ghostty-version_test.sh`,
`build-lib-stale-guard_test.sh`) don't exercise the build
invocation -- the stale-guard test only covers the pre-build tag
check. Reverting any of (a)-(c) would land green under `just test`.

Add a new test at `scripts/tests/build-lib-contract_test.sh` that:

1. Creates a temp workdir to act as the fake `SCRIPT_DIR`.
2. Symlinks `build-lib.sh`, `scripts/`, `.ghostty-version`, and
   `flake.nix`/`flake.lock` into the workdir (so the script
   resolves the same flake the real repo would).
3. Initializes a fake `.ghostty-src/` as a minimal git checkout
   tagged exactly to `.ghostty-version`'s value, so the
   `build_xcframework` stale-tag guard passes. The test invokes
   `./build-lib.sh build` directly (bypassing `fetch_ghostty`,
   which would touch the network).
4. Places PATH-shimmed `nix` and `xcodebuild` that:
   - Log every invocation's full argv to a captured file in the
     workdir.
   - For `nix shell ... --command zig build ...`: create non-empty
     `.ghostty-src/macos/GhosttyKit.xcframework/` (at least one
     file inside) and `.ghostty-src/zig-out/share/ghostty/themes/`
     (at least one file inside) so the script's existence and
     non-empty checks pass and the copy step has source data.
   - For `xcodebuild`: exit 0 silently (the script calls
     `xcodebuild -downloadComponent MetalToolchain` before the
     zig build).
5. Runs `./build-lib.sh build` and asserts:
   - The captured `nix` argv contains `"$WORKDIR#zig_0_15"` as
     the zig-package arg (i.e. the script computed `ZIG_PKG`
     against the real `SCRIPT_DIR`).
   - The captured zig argv contains `-Dxcframework-target=native`.
   - `lib/GhosttyKit.xcframework/` exists and contains at least
     one file.
   - `lib/ghostty-themes/` exists and contains at least one file.
6. Cleans up the temp workdir on exit (trap).

Wire the new test into **both** `Justfile` and CI so it gates
every change path -- local-only wiring would let a PR land green
on CI cache-hits even after the contract regressed.

- **`Justfile`'s `test` recipe** -- next to the other three shell
  self-tests. Per AGENTS.md `## Build`, that recipe currently runs
  `core-purity-lint_test.sh`, `load-ghostty-version_test.sh`, and
  `build-lib-stale-guard_test.sh`; add a fourth line invoking
  `build-lib-contract_test.sh`.
- **`.github/workflows/ci.yml`'s `validator-self-test` job**
  (`ubuntu-latest`, currently lines 208-217). It already runs
  `load-ghostty-version_test.sh` and `build-lib-stale-guard_test.sh`;
  add a third step running `./scripts/tests/build-lib-contract_test.sh`.
  The test is portable to Ubuntu by design -- it uses PATH-shimmed
  `nix` and `xcodebuild` and never invokes the real toolchains, so
  it can stay on `ubuntu-latest` (cheaper than `macos-26`) and
  still gate every PR independent of GhosttyKit cache state.

**Mark the new file executable** when creating it (both `Justfile`
and CI invoke it as `./scripts/tests/build-lib-contract_test.sh`,
which requires the execute bit; without it the run fails with
"Permission denied" before any contract assertion fires):

```
chmod +x scripts/tests/build-lib-contract_test.sh
```

Git stores the executable bit, so the mode persists across commit
and clone. If a contributor's editor reset the bit, restore it
with `git update-index --chmod=+x scripts/tests/build-lib-contract_test.sh`.

This test pins the contract end-to-end: reverting any of the
three section-#3 changes flips the relevant assertion red on both
local `just test` and PR CI. It stays behavioral (asserts the
observable invocation and the observable output paths) and
structure-insensitive (a refactor that preserves both leaves it
passing).

### 5. Edit: `.github/workflows/ci.yml`

Both the `build` (lines 96-145) and `release-build-check` (lines
146-206) jobs (each on `macos-26`) currently do:

```yaml
- uses: mlugg/setup-zig@v2
  with:
    version: 0.15.2
- name: Clone Ghostty source
  run: |
    git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git .ghostty-src
- name: Cache GhosttyKit
  # ...
- name: Build GhosttyKit
  if: steps.cache-ghosttykit.outputs.cache-hit != 'true'
  run: |
    cd .ghostty-src
    zig build -Demit-xcframework ...
    cd ..
    mkdir -p lib
    cp -R .ghostty-src/macos/GhosttyKit.xcframework lib/
    cp -R .ghostty-src/zig-out/share/ghostty/themes lib/ghostty-themes
```

Three problems with this shape:

- `mlugg/setup-zig` pulls unpatched Zig 0.15.2 -- broken on
  macos-26.
- The inline `zig build` duplicates flags `build-lib.sh` should own.
- "Clone Ghostty source" runs **unconditionally**, even on cache
  hit, wasting ~5-15s and a network round-trip on every cache-hit
  build.

Replace `mlugg/setup-zig` with the nix installer (already used in
this file by `cliff-smoke`), **remove the separate clone step**,
and replace the inline build with `./build-lib.sh all` gated on
cache miss. `build-lib.sh all` runs `fetch_ghostty` (clones
`.ghostty-src` if absent, fetches the pinned tag if present at a
different rev) then `build_xcframework`.

**Step ordering matters.** Keep the `Cache GhosttyKit` step
immediately after `Load Ghostty version`, so its `cache-hit`
output is known before any heavyweight setup. Gate **both** the
nix install and the build on `cache-hit != 'true'`. Cache-hit
runs skip the installer entirely -- no network round-trip, no
~30s of installer work for a job that already has the artifact:

```yaml
- name: Cache GhosttyKit
  id: cache-ghosttykit
  uses: actions/cache@v5
  with:
    path: |
      lib/GhosttyKit.xcframework
      lib/ghostty-themes
    key: ghosttykit-v2-${{ steps.ghostty-version.outputs.tag }}-${{ hashFiles('build-lib.sh', 'flake.nix', 'flake.lock') }}-${{ runner.os }}-${{ runner.arch }}

- uses: DeterminateSystems/nix-installer-action@v22
  if: steps.cache-ghosttykit.outputs.cache-hit != 'true'

- name: Build GhosttyKit
  if: steps.cache-ghosttykit.outputs.cache-hit != 'true'
  run: ./build-lib.sh all
```

Neither `build` nor `release-build-check` uses Nix anywhere else
in the job, so gating the installer is safe in both.

After this and section #3, `./build-lib.sh all` (a) clones or
fetches Ghostty source at the pinned tag, (b) calls
`nix shell "$SCRIPT_DIR#zig_0_15" ... -- zig build -Dxcframework-target=native ...`,
and (c) copies both the xcframework and `ghostty-themes` into
`lib/`. CI's GhosttyKit setup collapses from three steps to one,
and cache-hit builds skip the clone entirely (the `Build GhosttyKit`
step is gated on cache miss; nothing else touches `.ghostty-src`).

The "Load Ghostty version" step stays -- the cache key still needs
`steps.ghostty-version.outputs.tag`.

### 6. Edit: `.github/workflows/release-stable.yml`

The `release` job (`macos-26`) already installs Nix at line 31
(`DeterminateSystems/nix-installer-action@v22`). **Leave that
install unconditional** -- later steps in this job rely on Nix:
the "Create GitHub Release" step runs
`nix run nixpkgs#git-cliff` (line 175) and the "Compute release
zip hash" step runs `nix hash convert` and `nix-prefetch-url`
(line 191). Gating the installer on `cache-hit` would break the
cache-hit release path.

The cache-gated changes are limited to the GhosttyKit build:

- Drop the `mlugg/setup-zig` step at line 40.
- Drop the "Clone Ghostty source" step at line 44.
- Replace the inline GhosttyKit build (lines 57-70) with a single
  `./build-lib.sh all` call gated on `cache-hit != 'true'`.

Result is one cache-gated step that handles fetch + build, while
the unconditional Nix install at line 31 continues to feed the
release-bookkeeping steps that need it.

### 7. Edit: `.github/workflows/cache-ghosttykit.yml`

This job is on `macos-15` and currently builds successfully because
the older SDK is unaffected. Apply the same swap (nix-installer +
`./build-lib.sh all`, dropping both `mlugg/setup-zig` and "Clone
Ghostty source"). Reasons: keeps every GhosttyKit job using the
same patched zig; prevents silent drift if GitHub eventually
retires `macos-15` runners.

Add `DeterminateSystems/nix-installer-action@v22` gated on
`cache-hit != 'true'`, placed **after** the `Cache GhosttyKit`
step (which already exists at lines 33-40 and runs unconditionally)
and **before** the gated `Build GhosttyKit` step. The job has no
other Nix usage today, so skipping the installer on cache-hit is
safe. Final shape mirrors `ci.yml`'s build job:

```yaml
- name: Cache GhosttyKit
  # ... (existing, with updated key per section #8)
- uses: DeterminateSystems/nix-installer-action@v22
  if: steps.cache-ghosttykit.outputs.cache-hit != 'true'
- name: Build GhosttyKit
  if: steps.cache-ghosttykit.outputs.cache-hit != 'true'
  run: ./build-lib.sh all
```

Also extend this workflow's `on.push.paths:` trigger (lines 10-15)
so the cache warmer re-runs when the new Nix-side build inputs
change. Add `flake.nix` and `flake.lock` next to the existing
`build-lib.sh` and `.ghostty-version` entries. Without this, a
flake-only change (e.g. bumping the zig-overlay input) would land
on master without warming the cache, and the next tag-triggered
release would discover a cold cache and rebuild on a runner that
may not have an older-SDK escape hatch.

### 8. Extend the GhosttyKit cache key to cover all build inputs

The `actions/cache` step in every GhosttyKit workflow today keys on
just `hashFiles('build-lib.sh')`:

```
ghosttykit-v2-${{ steps.ghostty-version.outputs.tag }}-${{ hashFiles('build-lib.sh') }}-${{ runner.os }}-${{ runner.arch }}
```

After this plan, the GhosttyKit build also depends on `flake.nix`
(the zig-overlay input + `packages.<system>.zig_0_15` re-export)
and `flake.lock` (the zig-overlay pin). A future flake-only change
-- bumping the zig-overlay input, dropping the override once
`.ghostty-version` moves to a Zig-0.16-requiring tag -- would
silently reuse a stale `lib/GhosttyKit.xcframework` and bypass the
build path this plan protects.

Update the cache key in all four cache steps
(`ci.yml:123` and `ci.yml:173`, `release-stable.yml:55`,
`cache-ghosttykit.yml:40`) to:

```
ghosttykit-v2-${{ steps.ghostty-version.outputs.tag }}-${{ hashFiles('build-lib.sh', 'flake.nix', 'flake.lock') }}-${{ runner.os }}-${{ runner.arch }}
```

`hashFiles` accepts multiple paths.

Note on first-PR caching: adding files to the `hashFiles` call
changes its output even when those files are unchanged versus
master (the previous hash didn't include them at all), so existing
master caches won't be hit on the first PR that lands this work.
That's not a correctness issue: the merge commit touches
`flake.nix` and `flake.lock`, which now sit in
`cache-ghosttykit.yml`'s `on.push.paths:` trigger (per section #7),
so the cache warmer fires on merge and repopulates the cache under
the new key before the next tag-triggered release.

### 9. Update build/CI docs

Same-change doc updates so reference docs don't go stale:

- `agent-docs/build-details.md:12` -- the `nix shell` example: update
  the source (`nixpkgs#zig_0_15` -> `"$SCRIPT_DIR#zig_0_15"`) **and**
  the flag list to include `-Dxcframework-target=native`, so the doc
  matches the new canonical command.
- `agent-docs/build-details.md:42` -- "Requirements" list still
  says "nix (for `zig_0_15` and `gettext`)". Reword to note that
  `zig_0_15` now comes from the repo's flake
  (via zig-overlay's Homebrew-bottled patched 0.15.2),
  while `gettext` stays on system nixpkgs.
- `docs/upgrading-ghostty.md:17` -- the table row pointing at
  `ZIG_PKG="nixpkgs#zig_0_15"` becomes
  `ZIG_PKG="$SCRIPT_DIR#zig_0_15"`.
- `docs/upgrading-ghostty.md:18-20` -- the three `mlugg/setup-zig`
  rows become "nix-installer + `./build-lib.sh all`" (point at the
  workflow that runs the build, not the version pin).
- `docs/upgrading-ghostty.md:21` -- the `docs/ci.md` row stays
  but with the same Pinned-versions wording change below.
- `docs/ci.md:33` -- replace the "Zig `0.15.2` -- set in the
  `mlugg/setup-zig` action" bullet with "Zig `0.15.2` -- pulled
  from DanTerm's flake (`flake.nix`'s `zig_0_15` re-exports
  mitchellh/zig-overlay's Homebrew-bottled patched 0.15.2);
  installed via nix-installer in every GhosttyKit job".
- `docs/upgrading-ghostty.md:62-89` ("CI cache" section) -- the
  documented cache key form (line 71) becomes
  `ghosttykit-v2-{GHOSTTY_TAG}-{hash of build-lib.sh, flake.nix, flake.lock}-{runner.os}-{runner.arch}`.
  Update the "Cache invalidation" prose (lines 85-89) to add: "and
  when `flake.nix` or `flake.lock` changes". Mention that this is
  what protects against a flake-only zig-overlay bump silently
  being skipped.

## Verification

Order matters -- step 1 has to succeed before step 4 means anything.

1. Confirm the new flake input resolves and the package surfaces at
   the right version:
   ```
   nix eval --raw "$PWD#zig_0_15.version"
   ```
   Expect `0.15.2`.
2. Confirm `nix shell` produces a working zig binary:
   ```
   nix shell "$PWD#zig_0_15" --command zig version
   ```
   Expect `0.15.2`.
3. Clear the project's stale zig cache from the previously failing
   build (per Zig issue #31658's workaround notes):
   ```
   rm -rf .ghostty-src/.zig-cache
   ```
   If step 4 still emits stale `undefined symbol` errors after
   this, **then** -- and only as an optional troubleshooting
   escalation -- consider also clearing the global cache with
   `rm -rf ~/.cache/zig`. That path is shared with any other zig
   projects on the machine; don't reach for it by default.
4. Run the previously failing command end-to-end:
   ```
   just build-lib
   ```
   Expect: no `undefined symbol: _abort` errors,
   "Building GhosttyKit XCFramework..." then "Done!".
5. Confirm both artifacts the unified entry point now owns are
   present and non-empty:
   ```
   ls lib/GhosttyKit.xcframework/
   ls lib/ghostty-themes/ | head
   test "$(ls lib/ghostty-themes/ | wc -l | tr -d ' ')" -gt 0
   ```
   The `lib/ghostty-themes` check is what guards the cache-hit CI
   path (themes must persist to cache or `build-app.sh` fails at
   bundle time).
6. Confirm the Swift side still links against the rebuilt
   xcframework:
   ```
   just build
   ```
   Expect a successful build to `.build/DanTerm Dev.app`.
7. Confirm the new self-test is executable, wired in, and actually
   pins the contract:
   ```
   test -x scripts/tests/build-lib-contract_test.sh
   just test
   ```
   The `test -x` check guards against the file landing as `0644`
   (in which case `just test` would fail with "Permission denied"
   before any assertion ran). Expect `build-lib-contract_test.sh`
   to appear in the `just test` output and pass alongside the
   existing three shell self-tests. Then confirm the test fails
   if the contract regresses: temporarily remove the
   `-Dxcframework-target=native` line from `build-lib.sh` and
   re-run `just test` -- expect `build-lib-contract_test.sh` to
   fail with a clear assertion failure. Restore the line and re-run
   to confirm green.
8. CI cache-miss path (the broken-SDK regression this plan exists
   to fix): on the PR branch, intentionally invalidate the
   GhosttyKit cache -- either by touching `build-lib.sh` (which
   already hashes into the cache key) or by bumping the cache key
   suffix -- and push. Confirm `ci.yml`'s `build` job runs
   `./build-lib.sh all` on macos-26 and succeeds. Then revert the
   touch so the cache is reusable.
9. Sanity-check the workflow swap: re-read `ci.yml`,
   `release-stable.yml`, and `cache-ghosttykit.yml`. Confirm no job
   still references `mlugg/setup-zig`; confirm every GhosttyKit
   build step is `./build-lib.sh all`; confirm every
   `actions/cache` key is
   `hashFiles('build-lib.sh', 'flake.nix', 'flake.lock')`; confirm
   `cache-ghosttykit.yml`'s `on.push.paths:` includes the
   `flake.nix` and `flake.lock` entries; confirm the
   `nix-installer-action` step in `ci.yml`'s `build` and
   `release-build-check` jobs and in `cache-ghosttykit.yml` is
   gated on `cache-hit != 'true'`, while `release-stable.yml`'s
   existing top-of-job `nix-installer-action` remains
   unconditional; confirm `ci.yml`'s `validator-self-test` job
   runs `build-lib-contract_test.sh` alongside the existing two
   self-tests.
10. Cache-key invalidation smoke test: on the PR branch, touch only
    `flake.nix` (e.g. add a trailing blank line) and confirm CI's
    GhosttyKit cache misses ("Cache not found" in job logs). Revert
    the touch before merging. This verifies that flake-only changes
    invalidate the cache, which is what protects against silently
    reusing a stale GhosttyKit built with unpatched zig.
11. After merging the PR to master, confirm the `Cache GhosttyKit`
    workflow ran on the merge commit (its `on.push.paths:` trigger
    now matches `flake.nix` and `flake.lock`) and the post-job
    cache save succeeded **before** pushing the next `v*` tag.
    Otherwise the release workflow lands on a cold cache and must
    rebuild GhosttyKit, costing ~10 macOS-minutes (at 10x rate)
    instead of seconds.

## Out of scope

- No change to `~/world` -- this is local to DanTerm.
- No `darwin-rebuild switch` required.
- `lib/DanTermProtocol`, `lib/DanTermCore`, `app/`, `cli/` are not
  touched.
- The Swift compile path (`build-app.sh`, `dev-build.sh`,
  `Package.swift`) is unaffected; only the GhosttyKit (Zig) build
  path moves.
- No vendored zig patch file -- this plan deliberately consumes
  Homebrew's patched bottle via zig-overlay rather than maintaining
  our own patch.

## Implementation notes

- `docs/upgrading-ghostty.md`: added a `flake.nix` row to the "different Zig
  version" table (above the `build-lib.sh` row). Section #9 listed literal edits
  for the `build-lib.sh` row and the three workflow rows but not `flake.nix` --
  yet after this change `flake.nix` (the `zig_0_15` re-export + `zig-overlay`
  input) is the single place the patched Zig version is pinned, so the upgrade
  guide would otherwise omit the real pin location.
- Added two explanatory comments beyond the plan's literal snippets where the
  bare code would be cryptic: a pointer comment on the `zig-overlay` flake input
  (the detailed rationale lives on the `zig_0_15` package output below it), and a
  refresh of `build-lib.sh`'s file-header Requirements/Output lines, which had
  gone stale on the zig source (now the flake) and the second output
  (`lib/ghostty-themes`).
- `nix flake lock` pulled in two transitive `zig-overlay` nodes besides the
  followed `nixpkgs`: `flake-compat` and `systems`. Expected and unavoidable
  (they're `zig-overlay`'s own inputs); `nixpkgs` itself was not re-pinned.
- The `flake.nix` diff is larger than the logical change (~45 lines): the
  environment's nixfmt edit-hook reflowed the whole file from the repo's prior
  compact style to canonical multi-line form. Kept per user direction; only the
  `zig-overlay` input, the `outputs` arg, and the `zig_0_15` output are logical.
- End-to-end `just build` (verification step 6) surfaced a *second* macOS 26.x
  blocker the plan's scope didn't anticipate: with the SDK link error fixed, the
  build reaches Ghostty v1.3.0's `LibtoolStep`, and Apple's CLT 26.x
  `/usr/bin/libtool` drops the non-8-byte-aligned `libghostty_zcu.o` when
  combining the static archives -- shipping a `libghostty-fat.a` without the
  apprt C API (`ghostty_app_new`, ...), so the Swift app fails to link. Fixed in
  the same change (per user direction, no separate plan): `build-lib.sh` shims
  `libtool` for the zig build to `ranlib`-normalize each input archive first (a
  port of Ghostty main commit `a83a82b`, "normalize input archives before Darwin
  libtool merge"), and asserts the built archive exports `_ghostty_app_free` via
  `nm` so a regression fails the build instead of producing a broken xcframework.
  The contract test gained an `nm` shim plus a negative scenario for the guard.
  Verified: `just build-lib` + `just build` both succeed on macOS 26.x.
- The apprt-symbol guard captures `nm` output and matches in-shell rather than
  `nm ... | grep -q`: under `set -o pipefail`, `grep -q` closing the pipe on the
  first hit makes `nm` die of SIGPIPE, which would spuriously fail the guard.

## Follow Up

- The "Load Ghostty version" step in all four GhosttyKit workflows (`ci.yml`
  `build` + `release-build-check`, `release-stable.yml`, `cache-ghosttykit.yml`)
  still writes `GHOSTTY_TAG` to `$GITHUB_ENV`. That env var was consumed only by
  the now-removed "Clone Ghostty source" step; the cache key uses the `tag`
  step-*output*, not the env var. The `echo "GHOSTTY_TAG=..." >> "$GITHUB_ENV"`
  line is now dead in those jobs and could be dropped. Left in place because
  section #5 explicitly kept the step intact.
- Remove the `build-lib.sh` `libtool` shim and the apprt-symbol `nm` guard (and
  the contract test's `nm` shim + negative scenario) once `.ghostty-version`
  moves to a Ghostty release that carries the `LibtoolStep` ranlib fix (commit
  `a83a82b`). It's on `main` / 1.3.2-dev; neither v1.3.0 (current pin) nor v1.3.1
  (latest tag) includes it, so a plain tag bump won't suffice yet.
