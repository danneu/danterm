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
├── ModelOperations.swift   # Pure model core: split-tree ops, AppModel queries, MRU/jump/event-protocol, tab color
├── Projections.swift        # Pure view projections + diff (AppKit-free peer to Reconcile.swift)
├── TabTodo.swift            # Pure tab-todo popover model: rows, drag/drop, reorder
├── Persistence.swift        # Model <-> disk: snapshot/export, restore, checkpoints, session-lock, scrollback trunc
├── DanTermConfig.swift     # User-facing config (init file, preferences)
├── GhosttyApp.swift        # Wraps ghostty_app_t, runtime callbacks → Msg
├── TerminalView.swift      # NSView subclass hosting ghostty_surface_t
├── SplitContainerView.swift # Renders split tree as nested NSSplitViews
├── SidebarView.swift       # NSOutlineView sidebar: tabs, groups, drag/drop
├── ...                     # Pane views, drag/drop, search, themes, preferences, window chrome
└── Info.plist              # App bundle metadata

lib/DanTermCore/
├── Package.swift                       # Nested SwiftPM manifest: library + Swift Testing test target.
├── Sources/DanTermCore/                # The 22 pure files compiled into the app's own module via the
│                                       # root manifest's `sources:`, AND compiled standalone as a
│                                       # `DanTermCore` library here. See docs/design/.
└── Tests/DanTermCoreTests/             # Swift Testing suites (auto-discovered).
    ├── TestSupport.swift              # Shared fixtures (makeModel, createTab, hasEffect,
    │                                  # paneSnapshot helpers, makeMruModel).
    ├── Update*Tests.swift             # Tests for each Msg domain (tab, pane, ghostty, group,
    │                                  # lifecycle, search, theme, alert, preferences, remote,
    │                                  # mru, jump, ipc, todo, tab-todo).
    ├── ModelOperationsTests.swift     # Split tree + every desired* projection.
    ├── SnapshotTests.swift            # Init file decode/validate.
    └── ...                            # Config, scrollbar math, drag/drop, theme parsing, export,
                                       # checkpoint (recovery-path seam), sidebar, switcher events,
                                       # todo popover state, custom title, IPC connection,
                                       # CLI path installer, pane toolbar, etc.

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

Every non-trivial method should have a comment explaining intent, not mechanics.
For AppKit delegate/protocol methods, identify which protocol is being targeted
so it's clear the method isn't just a custom addition.

```swift
// NSSplitViewDelegate: called on divider double-click. We reset to 50/50 instead of collapsing.
func splitView(_ splitView: NSSplitView, ...) -> Bool {
```

### File header comments

Every `.swift` file opens with a top-of-file `//` comment block on line 1, above
the imports. (We do not use Xcode's `//  FileName.swift` banner.) A single line is
fine for a small, focused file; for anything larger the block should convey:

- what the file contains / what it is generally for
- its intent
- what belongs in it — and, by implication, what does not
- why it earns its own file

Use `//`, not `///`: the header describes the file, not a declaration.

```swift
// Before -- accurate, but undersells a hub file:
// Core value types for the DanTerm Elm-style application model.
import Foundation
```

```swift
// After:
// Pure value types for DanTerm's Elm-style model: typed IDs (`TypedId<Tag>`), the
// tab/pane/group/alert structs, and snapshot validation. This is the data the pure
// core (`update`, `ModelOperations`) and the reconciler both read. Keep it free of
// AppKit and side effects -- Cocoa views live in TerminalView/SidebarView, runtime
// effects in AppRuntime -- which is what keeps the whole model layer unit-testable
// without Cocoa or GhosttyKit. Its own file because nearly everything imports it.
import Foundation
```

### Doc comments on declarations

Give every new type (`class`/`struct`/`enum`/`actor`/`protocol`) and every
top-level function a `///` doc comment that justifies *why it exists*: capture
intent, an invariant, ownership, or call-site coupling — not the signature. For a
*member* (method or property), add one only when it is `public` (the `lib/` module
boundary) or a non-obvious entry point called from another file or type; the gate
below settles the rest.

- Prefer one to three lines. If deleting the comment would lose nothing a reader
  could not recover from the code itself, do not write it.
- Skip: protocol conformances whose purpose is the protocol (`Equatable`,
  `Codable`, `CustomStringConvertible`, ...), enum cases already covered by an
  enum-level doc, and test-only fixtures/helpers.

```swift
// Good -- says why this type is split out and states an invariant a reader can't infer:
/// Ephemeral view state with no natural AppKit owner that the reconciler reads as a
/// second input (alongside `AppModel`) and never clobbers. Deliberately minimal.
struct ViewLocalState { var sidebarRenameTarget: RenameTarget? }

// Bad:
/// The view-local state struct.   // restates the name
/// Helper used by the runtime.    // vague: which helper, and why does it exist?
struct ViewLocalState { var sidebarRenameTarget: RenameTarget? }
```

### Test preambles

Every individual test opens with a `//` preamble of three labeled sections. This
applies to both test idioms: a Swift Testing `@Test("...") func ...` in the
core package (`lib/DanTermCore/Tests/DanTermCoreTests/`, preamble at the top of
the method body) and an XCTest `func testX()` in the protocol package
(`lib/DanTermProtocol/Tests/`, preamble at the top of the method body too).

1. **Intent** — the behavior this test verifies.
2. **Why it exists** — the risk it guards: a regression for a bug-fix test, or
   the behavior contract it pins down for a spec-first test.
3. **Scenario** — the concrete user/system story the test models. If the test was
   written for a specific bug or incident, name it; otherwise describe the
   user-facing behavior being specified. Do not invent an incident — DanTerm is
   TDD-first, so most tests are spec-first and legitimately have none.

```swift
// Core Swift Testing (lib/DanTermCore/Tests/) -- a bug-fix test, so the
// Scenario names the real incident:
@Test("movePane(.splitRight) threads the moved pane's payload through insertAtLeaf")
func movePaneSplitRightThreadsPayload() {
    // Intent: moving a pane via .splitRight preserves the moved pane's full
    //   payload (cwd, theme, todos) at its new split position.
    // Why it exists: locks down the moveLeaf -> insertAtLeaf path, the only route
    //   through insertAtLeaf, against silently dropping pane state.
    // Scenario: earlier code rebuilt a fresh default leaf from the bare pane id,
    //   so dragging a pane to split-right wiped its cwd/theme/todos; this is the
    //   regression that fix is pinned against.
    var model = makeModel()
    // ...
}

// XCTest (lib/DanTermProtocol/Tests/) -- a spec-first test, so the Scenario is
// the behavior, no incident:
func testTabNewParsesBackgroundFlag() throws {
    // Intent: `--background` parses into params["background"] == .bool(true).
    // Why it exists: pins the CLI -> JSON contract the app's IPC handler reads.
    // Scenario: `danterm tab new --background` issued by an agent; the flag must
    //   survive parsing so the new tab opens in the background. Spec-first -- no
    //   incident to cite, and none should be invented.
    let command = try parseCLI(["tab", "new", "--background"])
    // ...
}
```

### Test architecture

The 22 pure model/update files live in `lib/DanTermCore/Sources/DanTermCore/`.
They are compiled twice by independent SwiftPM builds:

- **The root app target** (`DanTerm` executable in `./Package.swift`) compiles
  them into its own module via `sources: ["app", "lib/DanTermCore/Sources/DanTermCore"]`.
  No `import DanTermCore` in the app; the core stays plain `internal`. The
  nested `app/DanTermCore -> ../lib/DanTermCore/Sources/DanTermCore` symlink
  keeps the SwiftPM `path: "."` exclude list to a stable per-source-directory
  shape.
- **The nested test package** (`lib/DanTermCore/Package.swift`) compiles them as
  a standalone `DanTermCore` library and runs the Swift Testing suites against
  `@testable import DanTermCore`. The package does NOT depend on the
  `DanTerm` executable or GhosttyKit, so a core file that adds an app-only
  symbol or `import GhosttyKit` fails to compile under `swift test`.

`just test` runs the protocol XCTest suite, the core Swift Testing suite, and
the local **core-purity lint** (`scripts/core-purity-lint.sh`) that forbids
`import Cocoa`/`AppKit`/`SwiftUI` in `lib/DanTermCore/Sources/DanTermCore`.
The lint is R1's only guard against Cocoa creep (the nested package alone
can't catch system-framework imports), and its self-test
(`scripts/tests/core-purity-lint_test.sh`) pins the regex's edge cases.

See [docs/design/2026-05-28-core-module-via-symlink.md](docs/design/2026-05-28-core-module-via-symlink.md)
for the design decision behind compiling core same-module into the app
(`path: "."` + symlink) while a nested package tests it in isolation, and
why that beats a separate `DanTermCore` module.

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
- [docs/design/2026-05-28-core-module-via-symlink.md](docs/design/2026-05-28-core-module-via-symlink.md) -- Pure core compiled same-module via symlink, tested via nested SwiftPM package.

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
