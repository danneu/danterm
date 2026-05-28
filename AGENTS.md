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
app/                              # App target (root Package.swift, path: "app").
├── main.swift, AppDelegate.swift, AppRuntime.swift, GhosttyApp.swift, TerminalView.swift,
│   SplitContainerView.swift, SidebarView.swift, Reconcile.swift, ...   # AppKit + GhosttyKit
├── DanTermCore -> ../lib/DanTermCore/Sources/DanTermCore   # tracked symlink; the pure core
│                                                          # is compiled same-module into the app
│                                                          # target (no `import DanTermCore`).
└── Info.plist

lib/
├── DanTermCore/                  # Pure model/update, no AppKit/GhosttyKit. Same files as the
│   ├── Sources/DanTermCore/      # symlink above; compiled standalone here for tests:
│   │                             #   Model.swift, Msg.swift, Command.swift, Update.swift,
│   │                             #   ModelOperations.swift, Projections.swift, Persistence.swift,
│   │                             #   TabTodo.swift, DanTermConfig.swift, ...
│   └── Tests/DanTermCoreTests/   # Swift Testing suites (auto-discovered).
└── DanTermProtocol/              # CLI parser + IPC envelope, shared by app/ and cli/.

docs/design/                      # ADR-style design notes; index at docs/design/index.md.
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

Comments explain intent -- purpose, invariants, ownership, call-site coupling --
or non-obvious mechanics where the code itself isn't enough (a workaround, a
subtle ordering, a tricky calculation). The default is no comment unless one
justifies itself. Per-context gates -- file headers, declarations, tests -- are
in the subsections below.

For AppKit delegate/protocol methods, name the protocol being targeted so it's
clear the method isn't just a custom addition:

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

Use `//`, not `///`: Swift has no file-level doc comment. A `///` block at the
top of a file silently attaches to the next declaration below it (or to nothing
if the file has none), so it would either misattribute the header or vanish
from DocC and Quick Help entirely. The header describes the file, so it lives
in `//`.

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

Every individual test opens with a `//` preamble of three labeled sections at
the top of the method body. Applies to both idioms: Swift Testing
`@Test("...") func ...` in `lib/DanTermCore/Tests/` and XCTest `func testX()`
in `lib/DanTermProtocol/Tests/` -- same shape in both.

1. **Intent** — the behavior this test verifies.
2. **Why it exists** — the risk it guards: a regression for a bug-fix test, or
   the behavior contract it pins down for a spec-first test.
3. **Scenario** — the concrete user/system story the test models. If the test was
   written for a specific bug or incident, name it; otherwise describe the
   user-facing behavior being specified. Do not invent an incident — DanTerm is
   TDD-first, so most tests are spec-first and legitimately have none.

```swift
// A bug-fix test, so the Scenario names the real incident:
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
```

### Test architecture

The 22 pure model/update files live in `lib/DanTermCore/Sources/DanTermCore/`.
They are compiled twice by independent SwiftPM builds:

- **The root app target** (`DanTerm` executable in `./Package.swift`) uses
  `path: "app"` and reaches the core through the tracked symlink
  `app/DanTermCore -> ../lib/DanTermCore/Sources/DanTermCore`. SwiftPM walks
  the symlink and compiles the core files into the app's own module, so there
  is no `import DanTermCore` in the app and the core stays plain `internal`
  with zero access-control churn.
- **The nested test package** (`lib/DanTermCore/Package.swift`) compiles them as
  a standalone `DanTermCore` library and runs the Swift Testing suites against
  `@testable import DanTermCore`. The package does NOT depend on the
  `DanTerm` executable or GhosttyKit, so a core file that adds an app-only
  symbol or `import GhosttyKit` fails to compile under `swift test`.

`just test` runs the protocol XCTest suite, the core Swift Testing suite, the
local **core-purity lint** (`scripts/core-purity-lint.sh`) that forbids
`import Cocoa`/`AppKit`/`SwiftUI` in `lib/DanTermCore/Sources/DanTermCore`, and
the shell self-tests for the lint, Ghostty version validator, and build-lib
stale-source guard. The lint is R1's only guard against Cocoa creep (the nested
package alone can't catch system-framework imports), and its self-test
(`scripts/tests/core-purity-lint_test.sh`) pins the regex's edge cases.

See [docs/design/2026-05-28-core-module-via-symlink.md](docs/design/2026-05-28-core-module-via-symlink.md)
for the design decision behind compiling core same-module into the app
(`path: "app"` + symlink) while a nested package tests it in isolation, and
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

`just test` is the local gate. It runs six steps in order:

- `swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests`
  -- the protocol XCTest suite (CLI parser, IPC envelope).
- `swift test --package-path lib/DanTermCore` -- the core Swift Testing suite
  (pure model/update; no GhosttyKit or Cocoa needed).
- `./scripts/core-purity-lint.sh` -- forbids `import Cocoa`/`AppKit`/`SwiftUI`
  in `lib/DanTermCore/Sources/DanTermCore` (the nested package alone can't
  catch system-framework imports).
- `./scripts/tests/core-purity-lint_test.sh` -- self-test for the lint above.
- `./scripts/tests/load-ghostty-version_test.sh` -- self-test for the single
  Ghostty version validator.
- `./scripts/tests/build-lib-stale-guard_test.sh` -- self-test for the
  build-lib stale-source guard.

Targeted runs:

- Full core suite: `swift test --package-path lib/DanTermCore`
- One core suite or test: `swift test --package-path lib/DanTermCore --filter CheckpointTests`
- Protocol suite: `swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests`
- UI harness (AppKit, needs a display): `just test-ui` (runs `./test-ui.sh`)
- App compile check: `just build`

The legacy top-level `test.sh` hand-rolled harness was removed in the
DanTermCore migration; the core suite now lives in the nested SwiftPM package
at `lib/DanTermCore/` and is reached via `swift test --package-path
lib/DanTermCore`.

We practice TDD: when implementing a feature or fixing a bug, write the failing
test first, verify it fails for the expected reason, then change the code and
verify the test passes.

## Build Details

### build-lib.sh

- Clones Ghostty at the tag pinned via `.ghostty-version`
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

## Git commits

Use Conventional Commits-style commit messages.
