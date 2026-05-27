# DanTerm

Custom terminal emulator built on libghostty (the Zig library from Ghostty).

## App design goals

- Split pane system
- Tab system: Holds a split pane group of Ghostty surfaces
- Notifications where notif click focuses the tab + terminal pane where notif
  originated

## Architecture

Elm architecture (unidirectional data flow): views dispatch `Msg` values,
`update` produces a new `AppModel` + `[Command]`, and `AppRuntime` performs
commands (creating surfaces, rebuilding views, sending notifications, etc.).
Model and update logic are pure and fully unit-testable without Cocoa or
GhosttyKit.

```
app/
├── main.swift              # Entry point: ghostty_init, NSApp setup
├── AppDelegate.swift       # Window creation, menu bar, notification delegate
├── AppRuntime.swift        # Holds model + surfaces, dispatches Msg, performs Commands
├── Model.swift             # AppModel, TypedId<Tag>, model structs, snapshot validation
├── Msg.swift               # All messages (user actions, ghostty callbacks, lifecycle)
├── Command.swift           # Commands (side effects) update() returns; AppRuntime.perform runs them
├── Update.swift            # Pure update function: (inout AppModel, Msg) -> [Command]
├── ModelOperations.swift   # Pure helpers: split tree ops, query helpers, bell counts
├── DanTermConfig.swift     # User-facing config (init file, preferences)
├── GhosttyApp.swift        # Wraps ghostty_app_t, runtime callbacks → Msg
├── TerminalView.swift      # NSView subclass hosting ghostty_surface_t
├── SplitContainerView.swift # Renders split tree as nested NSSplitViews
├── SidebarView.swift       # NSOutlineView sidebar: tabs, groups, drag/drop
├── ...                     # Pane views, drag/drop, search, themes, preferences, window chrome
└── Info.plist              # App bundle metadata

tests/
├── TestHarness.swift          # Test runner, assertions, helpers
├── Update*Tests.swift         # Tests for each Msg domain (tab, pane, ghostty, group, lifecycle, search, theme, alert, preferences, remote)
├── ModelOperationsTests.swift # Split tree operation tests
├── SnapshotTests.swift        # Init file decode/validate tests
└── ...                        # Config, scrollbar math, drag/drop, theme parsing, export tests

docs/
├── ci.md                   # CI/CD pipeline, code signing, notarization
├── design/
│   ├── index.md            # Design-decision index
│   └── ...                 # ADR-style design notes
└── upgrading-ghostty.md    # Upgrading Ghostty version, CI cache
```

### Data flow

```
User/Ghostty action
    → Msg
    → update(&model, msg) -> [Command]   (pure)
    → AppRuntime.perform(command)         (side effects)
    → view rebuild / surface creation / etc.
```

### Typed IDs

All entity IDs use phantom-typed wrappers (`TypedId<Tag>`) so the compiler
rejects e.g. passing a `PaneId` where a `TabId` is expected:

```swift
typealias TabId   = TypedId<TabTag>
typealias PaneId  = TypedId<PaneTag>
typealias GroupId = TypedId<GroupTag>
typealias SplitId = TypedId<SplitTag>
```

## Code Style

Every `.swift` file should have a top-level comment explaining the file's purpose.

Every non-trivial method should have a comment explaining intent, not mechanics.
For AppKit delegate/protocol methods, identify which protocol is being targeted
so it's clear the method isn't just a custom addition.

```swift
// NSSplitViewDelegate: called on divider double-click. We reset to 50/50 instead of collapsing.
func splitView(_ splitView: NSSplitView, ...) -> Bool {
```

## Build

Two-step build:

1. **Build GhosttyKit** (manual, cached — only re-run when Ghostty version changes):

   ```
   ./build-lib.sh
   ```

   Output: `lib/GhosttyKit.xcframework/` (static library, not a .framework bundle)

2. **Compile and run the Swift app.**

### Dev build

```
just build
```

This compiles to `.build/DanTerm Dev.app`. Use it to verify the app compiles.

To build, install to `~/Applications`, and launch:

```
just build-run
```

The dev build uses bundle ID `com.danneu.danterm-dev` so it can run side by side
with the production `DanTerm.app` without conflicts.

`just build` maps to `./dev-build.sh` and `just build-run` maps to `./dev-build-run.sh`.

### Tests

Pure unit tests (no GhosttyKit or Cocoa needed):

```
just test
```

We practice TDD: when implementing a feature or fixing a bug, write the failing
test first, verify it fails for the expected reason, then change the code and
verify the test passes.

## Build Details

### build-lib.sh

- Clones Ghostty at a pinned tag (currently v1.3.0)
- Builds with: `nix shell nixpkgs#zig_0_15 nixpkgs#gettext --command zig build`
- Flags: `-Demit-xcframework -Demit-macos-app=false -Dsentry=false -Doptimize=ReleaseFast`
- XCFramework output path is `lib/GhosttyKit.xcframework/` (NOT `zig-out/`)
- As of v1.3.0, dependency URLs use a CDN (`deps.files.ghostty.org`), so the old
  iTerm2-Color-Schemes URL staleness issue is resolved

### Swift compilation

Both build scripts use `swift build` via `Package.swift`, which is the single
source of truth for Swift sources, framework dependencies, and linker flags.

- **`dev-build.sh`** — debug mode (fast incremental rebuilds), dev icons, dev
  bundle ID, installs to `~/Applications`
- **`build-app.sh`** — release mode (`--configuration release`, applies `-O`),
  production icons, optional `--version` stamping. Called by CI and release
  workflows.

The xcframework contains a **static library** (`libghostty.a`) + C headers with a
module map, NOT a `.framework` bundle. `Package.swift` declares `GhosttyKit` as a
`.binaryTarget` and specifies the required frameworks in `linkerSettings`:

- `-lc++` is needed because libghostty statically links SPIRV-Cross and glslang (C++).
- `-framework Carbon` is needed for keyboard layout APIs (TIS\*).

## Requirements

- nix (for `zig_0_15` and `gettext`)
- Xcode with Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`
- The GhosttyKit xcframework must be built before compiling the Swift app

## Reference Sources

The Ghostty source is cloned locally at `.ghostty-src/` (by `build-lib.sh`).
When you need to reference the libghostty C API, read files from there directly
instead of making web requests. Key files:

- `.ghostty-src/include/ghostty.h` — full C API header (types, structs, functions)
- `.ghostty-src/macos/Sources/Ghostty/` — Ghostty's own macOS Swift app (reference impl)
- `.ghostty-src/src/apprt/embedded.zig` — embedded runtime (implements the C API)

If you need to reference any other external library, clone it locally first so
you can read it directly. Never use web requests to read source code when you
can have a local clone.

Also see `github:manaflow-ai/cmux` — another macOS terminal built on libghostty
(vertical tabs, AI agent notifications). Useful reference for feature work.

Don't guess at API signatures, delegate protocols, enum cases, or framework
behavior. Check local sources first; if insufficient, search online and read
official docs before writing code.

## CI/CD

GitHub Actions builds, signs, notarizes, and publishes `.dmg` + `.zip` releases.

- **CI** (`.github/workflows/ci.yml`) — PRs: build only, ad-hoc signing
- **Stable** (`.github/workflows/release-stable.yml`) — `v*` tags: signed + notarized GitHub Release

Release with: `just release patch|minor|major`

See [docs/ci.md](docs/ci.md) for details on secrets, signing, and troubleshooting.

## Design Docs

- [docs/design/index.md](docs/design/index.md) -- ADR-style design-decision index.
- [docs/design/2026-03-05-display-scaling.md](docs/design/2026-03-05-display-scaling.md) -- Display scaling (HiDPI/Retina), content scale invariants, zero-frame guards.

## Operational Docs

- [docs/ci.md](docs/ci.md) -- CI/CD pipeline, code signing, notarization, troubleshooting.
- [docs/upgrading-ghostty.md](docs/upgrading-ghostty.md) -- Upgrading Ghostty version, CI cache.

## GitHub API

Use `gh` CLI for all GitHub API requests.

## CLI API Documentation

When changing the `danterm` CLI command surface, flags, stdout shape, targeting
semantics, or parser error usage, update `integrations/danterm/SKILL.md` in the
same change. Keep the skill's CLI API section and recipes synced with
`cli/main.swift` and `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`
so agent users see the current command contract.

## Plan Review Protocol

When reviewing a plan:

- List findings ordered by severity.
- For each finding: state issue, impact, and include one recommended fix.
- Prescriptions must be singular: do not present multiple options in the report.
- After listing findings, assess the overall plan viability.
- If you think there's an even better + simpler + more robust solution, tell the
  user so that they can consider pivoting to a new, better plan.

Decision rule:

- For each finding, consider the best resolutions and their trade-offs internally, then choose the best solution.
- If multiple open-ended solutions exist, brainstorm with the user until one
  solution is agreed.
- After alignment, report only that agreed solution.

Example (single finding):

- High: Plan stores tab state in both `Model.tabs` and each `TerminalView`.
  Impact: Dual source of truth causes state drift — closing a pane may leave stale entries in the tab list, leading to crashes on focus.
  Recommended fix: Keep `Model.tabs` as the single source of truth; `TerminalView` should read tab state from the model, never cache it locally.

## Git commits

Use Conventional Commits-style commit messages.
