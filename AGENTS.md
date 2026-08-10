# DanTerm

Custom macOS terminal emulator running on its own Swift terminal engine
(`lib/TerminalCore` for the grid, parser, and renderer; `lib/TerminalPTY` for
process lifecycle). It was built on libghostty until that dependency was removed
outright: there is no Zig, no xcframework, and no second backend left. Read
[docs/design/2026-08-06-swift-terminal-engine.md](docs/design/2026-08-06-swift-terminal-engine.md)
before planning or implementing engine work.

## Boundaries

Don't edit -- it is regenerated, and manual edits make the reference unreliable:

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
nearest enclosing named identifier when the point itself is unnamed. This form
is for external trees under `references/`; see **Citing docs** for DanTerm's own
documents.

Rules for how much weight source carries, and how you turn a probe into a
finding:

- **Source picks the probe; it does not replace running one.** A shell's
  behavior is established by a real binary in a real PTY, and a terminal's by
  feeding bytes to `TerminalCore.Terminal`. Reading the code tells you which
  experiment to run.
- **Reproduce from bytes, not from the GUI.** When an application misbehaves in
  a pane, capture its byte stream and replay it into `TerminalCore` headlessly:
  `danterm pane tape` for anything reproducible live, or a `pty.fork()` harness
  when the stimulus is one the GUI cannot issue -- a synthetic `SIGWINCH`, a
  specific `TIOCSWINSZ` geometry. Mark the byte offset of the stimulus so the
  capture splits into before and after halves, then confirm the cause by
  ablation: strip one sequence from the replay and show the symptom disappears.
  A cause you have not ablated is a hypothesis.
- **References are input, not authority.** On compatibility -- what a sequence
  does, what a shell emits -- match them; that's the requirement. On design --
  data model, where state lives, API shape -- they are only ideas: take the edge
  cases they found, then build the simplest ideal solution for DanTerm. Their
  structure encodes their history, not our constraints. "Ghostty does X" is not
  a rationale.

## Architecture

Elm architecture (unidirectional data flow). Model and update logic are pure and
fully unit-testable without Cocoa or the terminal engine.

```
User/engine action
    → Msg
    → update(&model, msg, env:) -> [Command]   (pure)
    → AppRuntime.perform(command)               (side effects)
    → view rebuild / session creation / etc.
```

Three layers, split across two symlinked modules plus the runtime:

- `DanTermCore` -- pure, deterministic domain logic; no IO, AppKit, or engine.
- `DanTermSupport` -- portable side effects (sockets, timers, CLI-path installer,
  recovery store); depends on `DanTermProtocol` + Foundation, never on `DanTermCore`.
- `app/` -- AppKit runtime, the `Command` interpreter, file IO, and the host for
  the `TerminalCore` / `TerminalPTY` engine packages.

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

## Design bar

Before you weigh any fix, work out the ideal one: the simplest structure
in which the problem can't happen. Keep that option on the table in every
proposal, plan, and review. The size of the refactor is not a reason to
drop it: "smaller diff", "less churn", and "for now" describe effort, and
effort doesn't decide anything here. If you recommend something other than
the ideal, say what's wrong with the ideal itself -- a constraint it
breaks, a behavior it loses, a risk it can't remove. "Something cheaper
exists" is not an argument against it.

The cheap fix is sometimes right, but that's the user's call, and they
can only make it if the ideal is in front of them. So when you recommend
the cheap fix, show the ideal next to it, say plainly that this is a
trade-off, and write the ideal into the plan or commit so it doesn't
disappear. An easy fix chosen over an ideal nobody named is a decision
nobody made.

A worked example of this bar is
[agent-docs/perf-granularity-mismatch.md](agent-docs/perf-granularity-mismatch.md):
the structural lift is the fix and a cache is the fallback -- and the
smell is strongest exactly where workarounds have piled up enough to make
the easy path look settled.

Backwards compatibility is not a constraint on the ideal solution. DanTerm has
one user, who upgrades by replacing the app, so "it would break existing X" is
never a reason to reject the ideal: break formats, names, and flags freely
instead of writing shims or migrations. Exception is external compatibility
(control sequences, shell output, terminfo). If you think a specific break
matters anyway, raise it with the user and let them confirm or reject the
concern -- don't quietly design around it.

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

### Prose

Plain, simple English in active voice -- in comments, docs, plans, commit
messages, and replies alike. The reader should parse every sentence correctly on
the first pass, with nothing to decode: no garden paths, no compressed
headline-style grammar, no clever compression.

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

### Citing docs

- Cite research outside `docs/research/` as `research/N/ID`, such as
  `research/15/F4`; the prefix names the tree, and
  [docs/research/README.md](docs/research/README.md) resolves the stable number
  to a path. Inside `docs/research/`, keep the portable bare cross-doc form such
  as `9/F3` required by `FORMAT.md`.
- Cite a design doc by path and id, then use the bare id within that same file;
  design docs are durable statements of their contracts, so a direct pointer
  is better than a paraphrase.
- Do not cite plan ids. Restate the invariant in the clause that would have
  carried the id, because plans are historical and their ids are not unique.
  When the same invariant needs restating across many files, graduate it to a
  design doc instead.

## Build

`swift build` (via the recipes below) is the whole toolchain. There is no
prebuild step: no xcframework, no Zig, no nix requirement for a dev build.

- `just launch-slot` -- **the way an agent runs the app.** Builds without
  installing, claims an isolated slot from 1 through 8, and execs it. Suffix
  `-optimized` for a release-configuration build, `-prime` only when a human is
  granting a slot notification permission. Drive the slot with an explicit
  `danterm --socket` argument every time; do not rely on ambient `DANTERM_SOCK`.
- `just build` / `just replace-dev` -- **the user's commands; do not run them
  unless asked.** Both overwrite `~/Applications/DanTerm Dev.app`, and
  `replace-dev` also quits the running instance the user may be working in.
  `bash ./dev-build.sh --no-install` is the compile-only form that touches
  nothing outside `.build/`. Dev bundle ID `com.danneu.danterm-dev` runs
  side-by-side with production `DanTerm.app`. Suffix `-optimized` for a
  release-configuration dev build (still not a release or publish operation).
- `just test` -- the local gate. Steps live in `scripts/run-test-suite.sh`, not
  the justfile; add new ones there, and only steps independent of every other
  one (no shared temp path, build directory, port, or socket). `just test-serial`
  when parallel interleaving is in the way.
- `just test-ui` -- AppKit UI harness. Excluded from the gate because it needs a
  WindowServer connection: it fails headless but runs fine from any shell in a
  logged-in GUI session, including an agent's.
- Targeted: `swift test --package-path lib/DanTermCore [--filter CheckpointTests]`.

**In a worktree:** run `just provision-worktree` before the first build, then
use the same `just launch-slot` path. See
[agent-docs/worktree-development.md](agent-docs/worktree-development.md).

## CLI

`integrations/danterm/SKILL.md` is the source of truth for the `danterm` CLI --
read it from the working tree, not the installed skill at
`~/.claude/skills/danterm`, which is provisioned from the last production
release and lags this branch. Changing the CLI surface (commands, flags, stdout
shape, parser errors) means updating that file in the same change.

DanTerm aims to be fully controllable remotely and programmatically, debugging
included. Use the API to reproduce an issue, confirm the root cause, and try
fixes. When it can't drive the action or report the state you need, extend the
API with a general, reusable command or query and update `SKILL.md`.

## Read before you touch it

| Working on | Read |
|---|---|
| The Swift terminal engine | [docs/design/2026-08-06-swift-terminal-engine.md](docs/design/2026-08-06-swift-terminal-engine.md) |
| Where a new terminal-reported pane fact lives | [docs/design/2026-08-10-terminal-reported-pane-facts.md](docs/design/2026-08-10-terminal-reported-pane-facts.md) |
| Layer placement, a new side-effecting utility, `core-purity-lint.sh` | [docs/design/2026-05-28-pure-core-support-split.md](docs/design/2026-05-28-pure-core-support-split.md) |
| Test architecture, the `app/DanTermCore` symlink, `lib/*/Package.swift` | [docs/design/2026-05-28-core-module-via-symlink.md](docs/design/2026-05-28-core-module-via-symlink.md) |
| An observer, NSEvent monitor, timer, popover, escaping closure, or C `userdata` callback | [docs/design/2026-06-09-appkit-lifetime-safety.md](docs/design/2026-06-09-appkit-lifetime-safety.md) |
| Sprite classification, geometry, rendering, or their tests | [docs/terminal-sprites.md](docs/terminal-sprites.md) |
| Measuring or optimizing terminal speed / memory | [agent-docs/terminal-performance.md](agent-docs/terminal-performance.md) |
| Adding a metric, freezing a threshold, acting on a difference between two numbers | [agent-docs/measurement-discipline.md](agent-docs/measurement-discipline.md) |
| `@inlinable`/`@usableFromInline` in `lib/TerminalCore`, or an `outlined copy` profile frame | [docs/design/2026-07-29-cross-module-value-dispatch.md](docs/design/2026-07-29-cross-module-value-dispatch.md) |
| HiDPI scaling, content scale, zero-frame guards | [docs/design/2026-03-05-display-scaling.md](docs/design/2026-03-05-display-scaling.md) |
| Build scripts, the dev/release bundle layout | [agent-docs/build-details.md](agent-docs/build-details.md) |
| CI, signing, notarization, releases | [docs/ci.md](docs/ci.md) |

Full ADR index: [docs/design/index.md](docs/design/index.md).
