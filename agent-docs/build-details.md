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
build-only identity and bundle-layout tools, and the `DanTermProtocol` library.
It depends on two local packages, `lib/TerminalCore` and `lib/TerminalPTY`,
which carry the terminal engine; the app target links only Cocoa, QuartzCore,
CoreText, and UniformTypeIdentifiers.

`lib/TerminalHostTools` is a third local package that nothing links. It holds the
two engine entry points that only run on a Mac -- `GlyphPreview`, an AppKit
window, and `TerminalMemoryProbe`, which shells out to `/usr/bin/vmmap`. They
live outside `lib/TerminalCore` because that package declares iOS support, and a
`platforms:` pin is a claim about every target in a package rather than the ones
someone checked. `scripts/ios-portability-gate.sh` holds that claim up on every
`just test` run: it finds the pinned packages by reading the manifests and
cross-compiles each one whole, test targets included. A target that cannot build
for iOS belongs in `TerminalHostTools`; it never belongs on an exemption list.

- `dev-build.sh` -- debug mode by default (fast incremental rebuilds), or
  SwiftPM release mode with `--release`. Both modes use dev icons, the dev
  bundle ID, and development signing. The default installs to `~/Applications`;
  `--no-install` stops after producing `.build/DanTerm Dev.app`. Wrapped by
  `just build` / `just replace-dev` for debug and `just build-optimized` / `just
  replace-dev-optimized` for optimized dev builds. The optimized variants are
  not production releases and do not publish anything.
- `scripts/dev-slot-launcher.py` -- claims a user-global slot from 1 through 8,
  runs `dev-build.sh --no-install`, stages and signs the slot clone, and starts
  it detached in its own session. It then emits the JSON handle once that app's
  control socket accepts connections, and exits, so a caller piping the launcher
  reaches end-of-file at once and the app's own output lands in
  `<slot cache>/logs/slot-<n>.log`. Wrapped by `just launch-slot`, `just
  launch-slot-optimized`, and the notification-permission path `just
  launch-slot-prime`, which differs only in letting the app activate and prompt.
  `--list` and `--stop <slot>` (`just slots` / `just stop-slot`) report and free
  the shared pool without building. Occupancy comes from each slot's lock, and
  that same file also holds the JSON record naming its occupant, so there is no
  second file to fall out of step with the lock. Slot 0 is never claimed. The
  emitted development layout resolves each clone's identity and paths through
  `DanTermProtocol`. The launcher rewrites that plan for the slot identity, then
  verifies the clone after its rename and signing step.
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

`BundleLayout` in `DanTermProtocol` declares each variant's identity, entries,
modes, copy sources, and exact-set directories. `DanTermBundleLayoutTool` emits
that declaration as JSON. `scripts/assemble-app-bundle.sh` consumes the plan for
release, development, benchmark, and viability bundles, and
`scripts/verify-bundle-layout.sh` checks the result against the same plan. Both
shipping producers verify after assembly. CI and release workflows verify again
after signing and after a ZIP round-trip.

The declaration covers `Contents/Resources`: the icon `Assets.car`, the three
agent hook scripts under `danterm-hooks/` (raw scripts, so `jq` -- and `danterm`
for the session hooks -- must be on the runtime PATH), the whole
`shell-integration` tree including `vendor/`, and the theme catalog plus bundled
symbol font. A missing, changed, incorrectly executable, or undeclared exact-set
entry fails verification.

Themes are tracked JSON under `themes/`, refreshed by
`scripts/import-themes.py` from a pinned iTerm2-Color-Schemes release. That
upstream archive is named `ghostty-themes.tgz`, which is an upstream naming
detail, not a build dependency.

## Stale build plans across the local packages

Adding a new `.swift` file to one local package does not invalidate the build
plan of a package that depends on it. The new file compiles when you build its
own package, while the dependent package still fails with `cannot find type X in
scope` -- so the error names the type you just added and points at the wrong
cause. `lib/DanTermCore` depends on `lib/DanTermProtocol`, so a new type in
`DanTermProtocol` is where this comes up.

Force a re-plan by touching the *dependent's* manifest, such as `touch
lib/DanTermCore/Package.swift`. Touching the manifest of the package that gained
the file does nothing, because that package's own plan was never stale.

## Requirements

- Xcode / the Swift 6.2 toolchain. `Package.swift` sets
  `swift-tools-version: 6.2` and `platforms: [.macOS(.v26)]`.
- A development signing identity (`Apple Development`) for `dev-build.sh`.
- `python3` for the theme catalog packer and the dev slot launcher.
