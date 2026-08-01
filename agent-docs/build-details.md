# Build details

Reference for the DanTerm build pipeline. Read when touching `build-lib.sh`,
the dev/release Swift build scripts, or the xcframework linker setup. The dev
build recipes in the `Justfile` wrap the scripts described here; `just release`
is a separate inline tag/push recipe that's covered by the `## Boundaries` rule
in `AGENTS.md`.

## build-lib.sh

- Clones Ghostty at a pinned tag (currently v1.3.0).
- Builds with `nix shell "$SCRIPT_DIR#zig_0_15" nixpkgs#gettext --command zig
  build`.
- Flags: `-Demit-xcframework -Dxcframework-target=native -Demit-macos-app=false
  -Dsentry=false -Doptimize=ReleaseFast`.
- xcframework output path is `lib/GhosttyKit.xcframework/` (NOT `zig-out/`).
- As of v1.3.0, dependency URLs use a CDN (`deps.files.ghostty.org`); the old
  iTerm2-Color-Schemes URL staleness issue is resolved.

## Swift compilation

Build scripts use `swift build` via `Package.swift`, the single source of
truth for Swift sources, framework dependencies, and linker flags.

- `dev-build.sh` -- debug mode by default (fast incremental rebuilds), or
  SwiftPM release mode with `--release`. Both modes use dev icons, the dev
  bundle ID, and development signing. The default installs to `~/Applications`;
  `--no-install` stops after producing `.build/DanTerm Dev.app`. Wrapped by
  `just build` / `just build-run` for debug and `just build-optimized` / `just
  build-run-optimized` for optimized dev builds. The optimized variants are
  not production releases and do not publish anything.
- `scripts/dev-slot-launcher.py` -- claims a user-global slot from 1 through 8,
  runs `dev-build.sh --no-install`, stages and signs the slot clone, emits its
  JSON handle, and directly execs the app with fresh/background policy. Wrapped
  by `just launch`, `just launch-optimized`, and the foreground notification-
  permission path `just launch-prime`. Slot 0 is never claimed. The build-only
  `DanTermInstanceIdentityTool` resolves each clone's identity and paths through
  `DanTermProtocol` so the launcher does not duplicate the naming scheme.
- `build-app.sh` -- release mode (`--configuration release`, applies `-O`),
  production icons, optional `--version` stamping. Called by CI and release
  workflows.

The xcframework contains a static library (`libghostty.a`) + C headers with
a module map, NOT a `.framework` bundle. `Package.swift` declares
`GhosttyKit` as a `.binaryTarget` and specifies the required frameworks in
`linkerSettings`:

- `-lc++` -- libghostty statically links SPIRV-Cross and glslang (C++).
- `-framework Carbon` -- keyboard layout APIs (TIS*).

## Requirements

- nix: `zig_0_15` comes from this repo's flake (zig-overlay's Homebrew-bottled
  patched 0.15.2, for macOS 26.4+ SDK compatibility); `gettext` stays on system
  nixpkgs.
- Xcode with Metal toolchain: `xcodebuild -downloadComponent
  MetalToolchain`.
- The GhosttyKit xcframework must be built before compiling the Swift app.
