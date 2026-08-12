# Build details

Reference for the DanTerm build pipeline. Read when touching the dev or release
build scripts, the app bundle layout, or `Package.swift`. The dev build recipes
in the `justfile` wrap the scripts described here; `just release` is a separate
inline tag/push recipe that's covered by the `## Boundaries` rule in `AGENTS.md`.

There is no prebuild step. DanTerm builds from Swift source only -- since
libghostty was removed there is no Zig, no xcframework, and no binary target to
produce before the first `swift build`.

## Swift compilation

Build scripts use `swift build` via `Package.swift`, the single source of truth
for Swift sources, package dependencies, and linker flags. The root package
declares the `DanTerm` app, the `DanTermCLI` (`danterm`) executable, the
build-only `DanTermInstanceIdentityTool`, and the `DanTermProtocol` library. It
depends on two local packages, `lib/TerminalCore` and `lib/TerminalPTY`, which
carry the terminal engine; the app target links only Cocoa, QuartzCore,
CoreText, and UniformTypeIdentifiers.

- `dev-build.sh` -- debug mode by default (fast incremental rebuilds), or
  SwiftPM release mode with `--release`. Both modes use dev icons, the dev
  bundle ID, and development signing. The default installs to `~/Applications`;
  `--no-install` stops after producing `.build/DanTerm Dev.app`. Wrapped by
  `just build` / `just replace-dev` for debug and `just build-optimized` / `just
  replace-dev-optimized` for optimized dev builds. The optimized variants are
  not production releases and do not publish anything.
- `scripts/dev-slot-launcher.py` -- claims a user-global slot from 1 through 8,
  runs `dev-build.sh --no-install`, stages and signs the slot clone, emits its
  JSON handle once the detached app's control socket accepts connections, having
  started it with fresh/background policy before exiting, so a caller piping the launcher reaches end-of-file at once and the
  app's own output lands in `<slot cache>/logs/slot-<n>.log`. Wrapped
  by `just launch-slot`, `just launch-slot-optimized`, and the foreground
  notification-permission path `just launch-slot-prime`. Slot 0 is never
  claimed. The build-only `DanTermInstanceIdentityTool` resolves each clone's
  identity and paths through `DanTermProtocol` so the launcher does not
  duplicate the naming scheme.
- `build-app.sh` -- release mode (`--configuration release`, applies `-O`),
  production icons, optional `--version` stamping. Called by CI and release
  workflows. It does not sign or notarize.

## Two SwiftPM invocations, three bundled executables

`PTYSessionBootstrap` lives in `lib/TerminalPTY` and is its own executable
product, so both `dev-build.sh` and `build-app.sh` run a *second* `swift build`
against that package before assembling the bundle. The engine spawns the
bootstrap per session and reports itself not ready when the bundled copy is
missing, so a build that skips it produces an app whose panes never start.

A release bundle therefore has three executable/signing boundaries:

- `Contents/MacOS/DanTerm` -- the app.
- `Contents/Helpers/danterm` -- the CLI. `build-app.sh` asserts it is neither
  the same inode nor byte-identical to the app binary, because a case-insensitive
  filesystem or a copy-source mistake yields a signed bundle that will not launch.
- `Contents/Helpers/PTYSessionBootstrap` -- the per-session PTY bootstrap.

Dev bundles add `Contents/Helpers/danterm-instance-identity`.

Both scripts also stage `Contents/Resources`: the icon `Assets.car`, the three
agent hook scripts under `danterm-hooks/` (raw scripts, so `jq` -- and `danterm`
for the session hooks -- must be on the runtime PATH), the whole
`shell-integration` tree including `vendor/`, and the theme catalog plus bundled
symbol font packed by `scripts/bundle-theme-resources.sh`. Each of those staging
steps asserts its assets landed, so a silently thinned copy fails the build
rather than the user's shell.

Themes are tracked JSON under `themes/`, refreshed by
`scripts/import-themes.py` from a pinned iTerm2-Color-Schemes release. That
upstream archive is named `ghostty-themes.tgz`, which is an upstream naming
detail, not a build dependency.

## Requirements

- Xcode / the Swift 6.2 toolchain. `Package.swift` sets
  `swift-tools-version: 6.2` and `platforms: [.macOS(.v26)]`.
- A development signing identity (`Apple Development`) for `dev-build.sh`.
- `python3` for the theme catalog packer and the dev slot launcher.
