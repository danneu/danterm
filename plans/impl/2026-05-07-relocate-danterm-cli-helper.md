# Fix: relocate `danterm` CLI helper to `Contents/Helpers/`

## Context

DanTerm v0.0.51 ships a corrupted bundle: the GUI Mach-O at
`Contents/MacOS/DanTerm` has been silently overwritten by the CLI
binary during the release CI build. Installed apps print
`danterm: missing command` and exit instead of opening a window.

Confirmed in the user's installed copy at
`/Users/dan/Applications/Home Manager Apps/DanTerm.app`:

- `file Contents/MacOS/DanTerm` → 235 KB Mach-O (the CLI), not the
  multi-megabyte GUI.
- Running it directly prints `danterm: missing command`.
- `codesign --verify` and `spctl --assess` both pass — the corrupted
  file is properly signed and notarized, because Apple's checks don't
  verify that the binary named in `CFBundleExecutable` is actually a
  GUI app.

### Root cause

`build-app.sh:36-37`:

```sh
cp "$BIN_PATH/DanTerm"    "$APP_PATH/Contents/MacOS/DanTerm"   # 5+ MB GUI
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/MacOS/danterm"   # 235 KB CLI
```

GitHub Actions macOS runners use case-insensitive APFS by default. On
that FS, `Contents/MacOS/DanTerm` and `Contents/MacOS/danterm` resolve
to the same inode. The second `cp` overwrites the GUI in place; the
file's case-preserved name stays `DanTerm`, but its bytes become the
CLI's. `release-stable.yml:95-99` then signs the colliding file (twice)
and `--deep`-signs the bundle. The zipped artifact contains exactly one
file at `Contents/MacOS/DanTerm`; an unzip on a case-sensitive FS
preserves that single broken file.

The dev build escaped this because dev-build.sh names the GUI
`DanTerm Dev` (with a space), which is case-distinct from `danterm`.

### Fix

Move the CLI helper to `Contents/Helpers/danterm`. The new location is
in a different directory from the GUI binary, so the path collision
cannot recur on any filesystem. `Contents/Helpers/` is also the
canonical nested-helper-tool path under TN2206, which the codesign
toolchain handles correctly under `--deep`.

Add a defensive inode check at the end of `build-app.sh` so this class
of bug fails the build immediately if it ever recurs (e.g. someone
moves the helper back to `MacOS/` under a different name that still
collides).

## Change set

Eight files. The build-app/dev-build path move, a content invariant
guard in `build-app.sh`, the Swift installer default, the test
fixtures, the docs, and **both** CI workflows (PR validation +
release).

### 1. `build-app.sh:36-38`

Before:

```sh
cp "$BIN_PATH/DanTerm"    "$APP_PATH/Contents/MacOS/DanTerm"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/MacOS/danterm"
chmod +x "$APP_PATH/Contents/MacOS/danterm"
```

After:

```sh
cp "$BIN_PATH/DanTerm" "$APP_PATH/Contents/MacOS/DanTerm"
mkdir -p "$APP_PATH/Contents/Helpers"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/Helpers/danterm"
chmod +x "$APP_PATH/Contents/Helpers/danterm"

# Defense in depth. Two distinct failure modes can produce a signed
# bundle that won't launch:
#
#   1. A case-insensitive FS would collapse the GUI and CLI paths
#      into one inode (the v0.0.51 bug).
#   2. A copy-source mistake could write CLI bytes into both files
#      across distinct inodes.
#
# Fail the build immediately on either.
GUI="$APP_PATH/Contents/MacOS/DanTerm"
CLI="$APP_PATH/Contents/Helpers/danterm"
GUI_INODE=$(stat -f %i "$GUI")
CLI_INODE=$(stat -f %i "$CLI")
if [ "$GUI_INODE" = "$CLI_INODE" ]; then
    echo "Error: GUI and CLI bundle paths collided (same inode)" >&2
    exit 1
fi
if cmp -s "$GUI" "$CLI"; then
    echo "Error: GUI and CLI bundle binaries have identical content" >&2
    exit 1
fi
```

### 2. `dev-build.sh:30-31`

The dev build never collided (GUI is `DanTerm Dev`), but keep the
layout consistent with prod so the `CLIPathInstaller` looks in one place:

```sh
mkdir -p "$APP_PATH/Contents/Helpers"
cp "$BIN_PATH/DanTermCLI" "$APP_PATH/Contents/Helpers/danterm"
chmod +x "$APP_PATH/Contents/Helpers/danterm"
```

### 3. `.github/workflows/release-stable.yml`

Two changes. First, add an explicit invariant check **before** the
per-file codesign call (so a bad bundle fails the workflow with a
clear error instead of getting signed and notarized):

```yaml
- name: Verify release bundle layout
  run: |
    APP_PATH="build/DanTerm.app"
    test -x "$APP_PATH/Contents/MacOS/DanTerm"
    test -x "$APP_PATH/Contents/Helpers/danterm"
    if cmp -s "$APP_PATH/Contents/MacOS/DanTerm" "$APP_PATH/Contents/Helpers/danterm"; then
        echo "Error: GUI and CLI bundle binaries have identical content" >&2
        exit 1
    fi
```

Second, update the per-file codesign target on line 96:

```yaml
codesign --force --options runtime \
  --sign "${{ env.SIGNING_IDENTITY }}" \
  "$APP_PATH/Contents/Helpers/danterm"
```

Keep the subsequent `codesign --force --deep` of the outer bundle on
line 97 unchanged. The pattern (sign nested code first, then `--deep`
the outer) is the TN2206-recommended order; do not collapse the two
calls into one.

### 4. `.github/workflows/ci.yml` — `Verify release bundle` step

Currently at lines 182-191 the PR-validation job asserts only that
`Contents/MacOS/DanTerm` exists and `Contents/MacOS/danterm` is
executable — it doesn't compare the two, so the v0.0.51 collapse
slipped through.

Replace with:

```yaml
- name: Verify release bundle
  run: |
    APP_PATH="build/DanTerm.app"
    test -x "$APP_PATH/Contents/MacOS/DanTerm"
    test -x "$APP_PATH/Contents/Helpers/danterm"
    if cmp -s "$APP_PATH/Contents/MacOS/DanTerm" "$APP_PATH/Contents/Helpers/danterm"; then
        echo "Error: GUI and CLI bundle binaries have identical content" >&2
        exit 1
    fi
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
    [ "$VERSION" = "0.0.0-test" ] || { echo "Version mismatch: $VERSION"; exit 1; }
    codesign --force --deep --sign - "$APP_PATH"
    codesign -v "$APP_PATH"
    echo "Release build validation passed"
```

Same `cmp -s` invariant the production build enforces, but on PR CI —
so the bundle layout regression is caught before merge, not at release
time.

### 5. `app/CLIPathInstaller.swift:27-33`

The current default `sourceURL` closure has two branches: a primary
path that derives from `Bundle.main.executableURL` (which resolves to
`Contents/MacOS/danterm` in real bundles — this is the branch that
runs in production), and a fallback that uses
`Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/danterm")`.
Editing only the fallback would leave production looking at the old
path.

Replace the entire closure with a single `bundleURL`-based path —
`Bundle.main.bundleURL` is reliably non-nil, so the fallback split is
not needed:

```swift
sourceURL: {
    Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/danterm", isDirectory: false)
},
```

### 6. `tests/CLIPathInstallerTests.swift`

Update the fixture at line 117 to point at the new path. Read the
nearby setup code first — if it `mkdir`s a fake `MacOS/` directory for
the fixture, that needs to become `Helpers/` so the source URL the test
constructs actually resolves to a real file:

```swift
let sourceURL = root.appendingPathComponent("DanTerm.app/Contents/Helpers/danterm")
```

### 7. `scripts/tests/danterm-cli_test.sh:8` and `docs/ci.md:44`

Replace `Contents/MacOS/danterm` with `Contents/Helpers/danterm` in
both. The shell test's `CLI_PATH` and the doc string both reference the
old location. While updating the shell test, make the launch wait check
for a real pane and selected tab before exporting `DANTERM_PANE` and
`DANTERM_TAB`; the socket can appear before the first pane is ready, and
exporting `null` makes the CLI reject the context before the helper path
is actually exercised. Also replace the raw JSON-RPC `nc -N -U` probe
with a small Unix-socket Python probe because the system `nc` shipped on
current macOS interprets `-N` as an adaptive write-timeout option, not
EOF-after-stdin.

## Out of the change set (verified untouched)

- **`package.nix`**: pulls `DanTerm-${version}.zip` from the GitHub
  release and unpacks into `$out/Applications/DanTerm.app/`. The
  `installPhase` is `cp -R . $out/Applications/DanTerm.app/` with no
  reference to internal layout. Bumping `version` and `sha256` after
  v0.0.52 ships is the only change here, and that PR is auto-generated
  by the release workflow.
- **`hm-module.nix`**: references the GUI binary at
  `Contents/MacOS/DanTerm` only — unaffected.
- **`justfile` release recipe**: bumps `Info.plist` version and tags;
  no bundle-internal paths.
- **`lib/DanTermProtocol/Sources/DanTermProtocol/SocketPath.swift:7-9`**:
  IPC socket path is bundle-ID-derived
  (`~/Library/Caches/<bundle-id>/control.sock`), not helper-relative.
- **`plans/impl/2026-05-06-danterm-cli.md`**: the path choice in that
  plan is superseded by this fix. Left as historical record of the
  original (flawed) layout decision.

## Verification

### Local, before tagging

The primary pre-tag check must exercise the **production** build
script (`build-app.sh`), since that's what CI runs and what shipped
the broken v0.0.51. `just build` runs `dev-build.sh` (the dev path
that never collided), so it would not have caught the bug.

1. `./build-app.sh --version "0.0.52-test"` produces
   `build/DanTerm.app`. With the new inode and content guards, a
   collision (or a bytewise-identical CLI/GUI) would fail the build
   instead of silently producing a broken bundle.
2. `ls -la build/DanTerm.app/Contents/MacOS/ build/DanTerm.app/Contents/Helpers/`
   shows both files. `MacOS/DanTerm` is multi-MB; `Helpers/danterm` is
   the smaller CLI Mach-O.
3. `stat -f %i build/DanTerm.app/Contents/MacOS/DanTerm
   build/DanTerm.app/Contents/Helpers/danterm` returns two distinct
   inode numbers (also enforced by the build guard).
4. `cmp -s build/DanTerm.app/Contents/MacOS/DanTerm
   build/DanTerm.app/Contents/Helpers/danterm; echo $?` returns
   non-zero (different content; also enforced by the build guard).
5. `file build/DanTerm.app/Contents/MacOS/DanTerm` reports a Mach-O
   *not* of size 235 KB.
6. Run the GUI Mach-O directly:
   `build/DanTerm.app/Contents/MacOS/DanTerm`
   — opens an NSApp window. Does **not** print
   `danterm: missing command`.
7. Run the helper directly:
   `build/DanTerm.app/Contents/Helpers/danterm`
   — prints `danterm: missing command` and exits 1 (current no-args
   behavior of the CLI). Verifies the helper Mach-O is the CLI, not
   another stray copy of the GUI.
8. `codesign --force --deep --sign - build/DanTerm.app && \
    codesign --verify --deep --strict --verbose=2 build/DanTerm.app`
   passes (ad-hoc local sign; the real Developer ID + notarization
   path runs in CI).
9. Dev parity check: `just build` (which runs `dev-build.sh`) also
   produces `~/Applications/DanTerm Dev.app/Contents/Helpers/danterm`
   alongside `Contents/MacOS/DanTerm Dev`.
10. `just test` passes (covers both the protocol-library tests and the
    pure app-update harness; do not invoke a root `swift test` — that
    would build the GUI/CLI app targets, not just the nested protocol
    package). `CLIPathInstallerTests` exercises the updated fixture
    path.
11. `DANTERM_CLI_TEST_ALLOW_APP_CONTROL=1 bash scripts/tests/danterm-cli_test.sh`
    runs end-to-end against a fresh dev build. Note: this opt-in
    variable exists because the script launches and quits *DanTerm
    Dev* (only the dev bundle, not the production app) — see lines
    10-13 of the script.

### Release flow (v0.0.52)

1. `just release patch` — bumps `Info.plist` to `0.0.52`, tags `v0.0.52`,
   pushes. CI runs `release-stable.yml`.
2. After CI completes, download `DanTerm-0.0.52.zip` from the GitHub
   release page and repeat steps 2-7 above on the *released* artifact.
   This is the real test: that artifact comes off the case-insensitive
   CI runner volume, so its bundle layout is what matters.
3. Auto-generated PR bumps `package.nix` to `version = "0.0.52"` with
   the new sha256. Merge it.
4. `world:rebuild` (or whatever the user runs to rebuild home-manager).
5. Launch `~/Applications/Home Manager Apps/DanTerm.app` — window
   appears.
6. From the running app, "DanTerm › Install `danterm` Command in PATH"
   menu item now creates `/usr/local/bin/danterm` symlinked to
   `Contents/Helpers/danterm`. From a fresh non-DanTerm shell:
   `which danterm` prints `/usr/local/bin/danterm`; `danterm` prints
   `danterm: missing command` and exits 1 (current no-args behavior).
   Then from inside a DanTerm pane (where `$DANTERM_SOCK` is set),
   `danterm ls` prints the model JSON.

### Post-release housekeeping (out of plan scope)

After v0.0.52 is verified working, edit the v0.0.51 GitHub release
notes to flag it as broken (`THIS RELEASE IS BROKEN; UPGRADE TO 0.0.52`)
so anyone hitting it from search engines is warned. GitHub releases
themselves cannot be deleted without breaking SHA-pinned consumers, so
flagging is the right move.

## Critical files

- `/Users/dan/world/my-apps/danterm/build-app.sh:36-38` — relocate CLI
  copy + add inode/content guards.
- `/Users/dan/world/my-apps/danterm/dev-build.sh:30-31` — same relocate.
- `/Users/dan/world/my-apps/danterm/.github/workflows/release-stable.yml:96`
  — update codesign target; add explicit `Verify release bundle layout`
  step before sign.
- `/Users/dan/world/my-apps/danterm/.github/workflows/ci.yml:182-191`
  — replace `Verify release bundle` step with the new path + `cmp -s`
  invariant.
- `/Users/dan/world/my-apps/danterm/app/CLIPathInstaller.swift:24-38`
  — replace the entire `Dependencies.default.sourceURL` closure with
  a single bundleURL-relative path. (The plan said line 32; the actual
  default lives in lines 24-38 and has two branches.)
- `/Users/dan/world/my-apps/danterm/tests/CLIPathInstallerTests.swift:117`
  — verify and update surrounding fixture setup so the constructed
  source URL points at a real file under `Helpers/`.
- `/Users/dan/world/my-apps/danterm/scripts/tests/danterm-cli_test.sh:8`
  — `CLI_PATH`.
- `/Users/dan/world/my-apps/danterm/docs/ci.md:44` — doc string.
- `/Users/dan/world/my-apps/danterm/lib/DanTermProtocol/Sources/DanTermProtocol/SocketPath.swift:7-9`
  (read-only; confirms IPC socket path is unaffected).
- `/Users/dan/world/my-apps/danterm/package.nix:9-11`
  (read-only; bot PR bumps after v0.0.52 ships).
