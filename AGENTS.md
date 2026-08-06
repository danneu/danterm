# DanTerm

Custom macOS terminal emulator, currently built on libghostty (the Zig library
from Ghostty). This experimental branch is replacing libghostty with a
DanTerm-owned Swift terminal engine: read
[plan-terminal-engine/README.md](plan-terminal-engine/README.md) before planning
or implementing that work.

## Boundaries

Don't edit -- both are regenerated, and manual edits get wiped or make the
reference unreliable:

- `lib/GhosttyKit.xcframework/` (rebuilt by `./build-lib.sh`)
- `references/` (pinned external checkouts; materialize with `just fetch-references`)

Don't run `just release patch|minor|major`, or any other release/publish
command, without explicit user instruction.

Don't guess API signatures, delegate protocols, enum cases, or framework
behavior -- check the local sources below first.

Use the `gh` CLI for GitHub API requests, not `curl`.

## Local source references

Real source for the systems DanTerm imitates or runs on -- ten terminal
emulators (`ghostty`, the engine DanTerm was built on, among them), `libvterm`,
the three shells, Darwin, and `swift-collections` -- is checked out at pinned
revisions under the gitignored `references/`. Run `just fetch-references [name]` (`--list` for the inventory)
and grep locally instead of fetching over the web or reasoning from memory.
Prefer `swift-collections` over hand-rolling a ring buffer, ordered set, bitset,
or heap. Layout and entry points:
[agent-docs/reference-sources.md](agent-docs/reference-sources.md).

Cite refetchable source trees as `file#identifier`, never `file:line`; use the
nearest enclosing named identifier when the point itself is unnamed.

Two rules govern how much weight source carries:

- **Source picks the probe; it does not replace running one.** A shell's
  behavior is established by a real binary in a real PTY, and a terminal's by
  feeding bytes to `TerminalCore.Terminal`. Reading the code tells you which
  experiment to run.
- **References are input, not authority.** On compatibility -- what a sequence
  does, what a shell emits -- match them; that's the requirement. On design --
  data model, where state lives, API shape -- they are only ideas: take the edge
  cases they found, then build the simplest ideal solution for DanTerm. Their
  structure encodes their history, not our constraints. "Ghostty does X" is not
  a rationale.

## Architecture

Elm architecture (unidirectional data flow). Model and update logic are pure and
fully unit-testable without Cocoa or GhosttyKit.

```
User/Ghostty action
    → Msg
    → update(&model, msg, env:) -> [Command]   (pure)
    → AppRuntime.perform(command)               (side effects)
    → view rebuild / session creation / etc.
```

Three layers, split across two symlinked modules plus the runtime:

- `DanTermCore` -- pure, deterministic domain logic; no IO, AppKit, or GhosttyKit.
- `DanTermSupport` -- portable side effects (sockets, timers, CLI-path installer,
  recovery store); depends on `DanTermProtocol` + Foundation, never on `DanTermCore`.
- `app/` -- AppKit + GhosttyKit runtime, the `Command` interpreter, file IO.

`app/DanTermCore` and `app/DanTermSupport` are tracked symlinks into
`lib/*/Sources/`, so both modules compile same-module into the app target -- no
`import DanTermCore` / `import DanTermSupport`. The nested packages under `lib/`
compile the same files standalone so they can be tested.

Cross-cutting features are layered across all three. IPC: method semantics in
core `update()`, envelope + line framing in `DanTermProtocol`, per-connection
socket lifecycle in `DanTermSupport.IpcConnection`, accept loop in
`app/IpcServer`. Persistence: pure snapshot/restore codec in core, path
resolution + file IO + session lock in `DanTermSupport.RecoveryStore`,
checkpoint scheduling and on-disk write in `app`.

The core seams its three ambient inputs -- home directory, fresh ids,
wall-clock time -- behind `CoreEnv`. Inject an explicit value when the result is
SAVED, SENT, or ASSERTED; leave it ambient when it is only SHOWN live and
discarded. `scripts/core-purity-lint.sh` enforces this; the worked example is in
[docs/design/2026-05-28-pure-core-support-split.md](docs/design/2026-05-28-pure-core-support-split.md).

All entity IDs are phantom-typed wrappers (`TabId = TypedId<TabTag>`, and the
same for panes, groups, splits) so the compiler rejects passing one where
another is expected.

## Code Style

Comments explain intent -- purpose, invariants, ownership, call-site coupling --
or non-obvious mechanics (a workaround, a subtle ordering, a tricky
calculation). Default to no comment unless one justifies itself: if deleting it
would lose nothing a reader could not recover from the code, don't write it.

- **File headers.** Every `.swift` file opens with a `//` block on line 1, above
  the imports -- not Xcode's `//  FileName.swift` banner, and not `///` (Swift
  has no file-level doc comment, so `///` would silently attach to the next
  declaration). One line is fine for a small file; a larger one should say what
  it holds, what does *not* belong in it, and why it earns its own file.
- **Declarations.** Every new type and top-level function gets a `///` comment
  saying *why it exists* -- intent, an invariant, ownership, call-site coupling
  -- not the signature. Members only when `public` (the `lib/` boundary) or a
  non-obvious cross-file entry point. Skip protocol conformances whose purpose
  is the protocol (`Equatable`, `Codable`, ...) and test-only helpers.
- **AppKit delegate methods.** Name the protocol being satisfied, so the method
  doesn't read as a custom addition: `// NSSplitViewDelegate: called on divider
  double-click.`

### Object lifetime (no use-after-free)

Never let a longer-lived owner message a shorter-lived AppKit object after
teardown. A standalone `NSTextView` with `allowsUndo` owns its `UndoManager`
(not the window's); NotificationCenter observers and NSEvent monitors remove
their tokens in `deinit`; timers, stored escaping closures, and async hops use
`[weak self]` or a documented owner-bound lifetime; `Unmanaged`/C `userdata` is
app-lifetime or stays retained until after the matching `free`.

### Tests

TDD: write the failing test first, verify it fails for the expected reason, then
change the code and verify it passes.

A Swift Testing `@Test` earns a `//` preamble only when something non-trivial
belongs above the body -- a regression it pins down, or an invariant the test
name can't carry. Trivial spec-first tests just need a descriptive title. When
you write one, use three labeled sections: **Intent** (the behavior verified),
**Why it exists** (the risk it guards), **Scenario** (the concrete story; for a
bug fix, name the incident -- don't invent one, most tests here are spec-first
and legitimately have none).

## Build

`./build-lib.sh` once before the first Swift build, and again only when the
pinned Ghostty version changes.

- `just build` / `just build-run` -- compile `.build/DanTerm Dev.app` and install
  to `~/Applications/`. Dev bundle ID `com.danneu.danterm-dev` runs side-by-side
  with production `DanTerm.app`. Suffix `-optimized` for a release-configuration
  dev build (still not a release or publish operation).
- `just test` -- the local gate. Steps live in `scripts/run-test-suite.sh`, not
  the justfile; add new ones there, and only steps independent of every other
  one (no shared temp path, build directory, port, or socket). `just test-serial`
  when parallel interleaving is in the way.
- `just test-ui` -- AppKit UI harness. Excluded from the gate because it needs a
  WindowServer connection: it fails headless but runs fine from any shell in a
  logged-in GUI session, including an agent's.
- Targeted: `swift test --package-path lib/DanTermCore [--filter CheckpointTests]`.

**In a worktree:** run `just provision-worktree` first, and launch with
`just launch`, never `just build-run`, so the user's canonical dev app is not
replaced. Drive the launched slot with an explicit `danterm --socket` argument
every time; do not rely on ambient `DANTERM_SOCK`. See
[agent-docs/worktree-development.md](agent-docs/worktree-development.md).

## CLI

`integrations/danterm/SKILL.md` is the source of truth for the `danterm` CLI --
read it from the working tree, not the installed skill at
`~/.claude/skills/danterm`, which is provisioned from the last production
release and lags this branch. Changing the CLI surface (commands, flags, stdout
shape, parser errors) means updating that file in the same change.

## Read before you touch it

| Working on | Read |
|---|---|
| The Swift terminal engine | [plan-terminal-engine/README.md](plan-terminal-engine/README.md) |
| Layer placement, a new side-effecting utility, `core-purity-lint.sh` | [docs/design/2026-05-28-pure-core-support-split.md](docs/design/2026-05-28-pure-core-support-split.md) |
| Test architecture, the `app/DanTermCore` symlink, `lib/*/Package.swift` | [docs/design/2026-05-28-core-module-via-symlink.md](docs/design/2026-05-28-core-module-via-symlink.md) |
| An observer, NSEvent monitor, timer, popover, escaping closure, or C `userdata` callback | [docs/design/2026-06-09-appkit-lifetime-safety.md](docs/design/2026-06-09-appkit-lifetime-safety.md) |
| Sprite classification, geometry, rendering, or their tests | [docs/terminal-sprites.md](docs/terminal-sprites.md) |
| Measuring or optimizing terminal speed / memory | [agent-docs/terminal-performance.md](agent-docs/terminal-performance.md) |
| Adding a metric, freezing a threshold, acting on a difference between two numbers | [agent-docs/measurement-discipline.md](agent-docs/measurement-discipline.md) |
| `@inlinable`/`@usableFromInline` in `lib/TerminalCore`, or an `outlined copy` profile frame | [docs/design/2026-07-29-cross-module-value-dispatch.md](docs/design/2026-07-29-cross-module-value-dispatch.md) |
| HiDPI scaling, content scale, zero-frame guards | [docs/design/2026-03-05-display-scaling.md](docs/design/2026-03-05-display-scaling.md) |
| Build scripts, upgrading Ghostty | [agent-docs/build-details.md](agent-docs/build-details.md), [docs/upgrading-ghostty.md](docs/upgrading-ghostty.md) |
| CI, signing, notarization, releases | [docs/ci.md](docs/ci.md) |

Full ADR index: [docs/design/index.md](docs/design/index.md).
