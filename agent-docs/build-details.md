# Build details

Reference for the DanTerm build pipeline. Read when touching `build-lib.sh`,
the dev/release Swift build scripts, or the xcframework linker setup. The
build recipes `just build` and `just build-run` wrap the scripts described
here; `just release` is a separate inline tag/push recipe in the `Justfile`
that's covered by the `## Boundaries` rule in `AGENTS.md`.

## build-lib.sh

- Clones Ghostty at a pinned tag (currently v1.3.0).
- Builds with `nix shell nixpkgs#zig_0_15 nixpkgs#gettext --command zig
  build`.
- Flags: `-Demit-xcframework -Demit-macos-app=false -Dsentry=false
  -Doptimize=ReleaseFast`.
- xcframework output path is `lib/GhosttyKit.xcframework/` (NOT `zig-out/`).
- As of v1.3.0, dependency URLs use a CDN (`deps.files.ghostty.org`); the old
  iTerm2-Color-Schemes URL staleness issue is resolved.

## Swift compilation

Build scripts use `swift build` via `Package.swift`, the single source of
truth for Swift sources, framework dependencies, and linker flags.

- `dev-build.sh` -- debug mode (fast incremental rebuilds), dev icons, dev
  bundle ID, installs to `~/Applications`. Wrapped by `just build` and `just
  build-run`.
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

- nix (for `zig_0_15` and `gettext`).
- Xcode with Metal toolchain: `xcodebuild -downloadComponent
  MetalToolchain`.
- The GhosttyKit xcframework must be built before compiling the Swift app.
