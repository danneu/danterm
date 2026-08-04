# Retire `surface`: adopt the pane/session lexicon

## Context

DanTerm inherited `surface` from libghostty as the noun for a running terminal
instance. `.ghostty-src/src/Surface.zig#Surface` states why Ghostty chose it:
the word is deliberately non-committal because "it is left to the higher level
application runtime to determine if the surface is a window, a tab, a split, a
preview pane... This struct doesn't care."

DanTerm *is* that higher-level runtime, and it does know: the thing is a pane.
`Command.createSurface(paneId:)` passes in the exact fact the word exists to
avoid stating. The word is also taken on this platform -- `IOSurface` is an
Apple type meaning a shareable pixel buffer, and `app/TerminalView.swift`
already refers to Ghostty's `IOSurfaceLayer` -- so in a macOS codebase
`surface` reads as framebuffer memory, the wrong connotation for something that
owns a PTY and a child process.

The migration is already half-done and stalled.
`lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift#TerminalSessionEvent`
emits `titleChanged`, `cwdChanged`, `bell`, `progress`, `closeRequested`, and
`app/TerminalBackend.swift` defines `TerminalSession` / `createSession`. The
same events one hop later are still `Msg.surfaceTitle`, `Msg.surfaceCwd`,
`Msg.surfaceBell`. The new boundary speaks session; the model still speaks
surface.

Outcome: one noun for a running terminal, and a recorded definition of what a
pane is versus what a session is, so the eventual "one pane hosts more than one
session" question is a modeling change rather than a vocabulary excavation.

### Load-bearing premise

`surface` crosses no external boundary. It appears in no IPC method name
(`lib/DanTermProtocol/Sources/DanTermProtocol/Methods.swift`), no CLI flag, no
persisted snapshot key, and no config key -- only in prose comments and in
Swift identifiers. This is what makes the rename safe to land during Milestone
9, whose replacement gate requires persistence format and IPC routing to be
unchanged.

## Decision

Rename `surface` to `session` throughout DanTerm-owned code, now, as its own
commit, ahead of Milestone 10.

`surface` is retained in exactly three places, distinguished by meaning rather
than by file:

1. **Graphics** -- a pixel buffer, the Apple sense (`BitmapSurface` in the
   render-execution tests, `IOSurfaceLayer`).
2. **Ordinary English** -- a boundary or seam ("the public surface", "the CLI
   command surface", `ClipboardWriteSurface`, `RecordingClipboardSurface`).
3. **Ghostty adapter code** -- `ghostty_surface_t` and the files that wrap it,
   which are correctly named because they are backend-specific and are deleted
   by Milestone 10.

Everything else -- the noun for a running terminal instance -- becomes
`session`. The decisive cases, which fix the vocabulary for the rest:

```swift
case sessionTitle(paneId: PaneId, title: String)   // was surfaceTitle
case sessionCwd(paneId: PaneId, cwd: String?)
case sessionBell(paneId: PaneId)
case sessionClosed(paneId: PaneId)

case createSession(paneId: PaneId, cwd: String?, ...)   // was createSurface
```

Two identifiers change meaning, not just spelling:

- `effectiveSurfaceVisibility` becomes pane-scoped naming; it already returns
  `[PaneId: Bool]` and describes panes, not sessions.
- `SurfaceGeometry` is content scale plus backing pixels with no terminal in
  it. It becomes backing/display-scaling geometry, aligned with
  `docs/design/2026-03-05-display-scaling.md`, not session vocabulary.

A dated note in `docs/design/` records the lexicon: **pane** is the slot in the
split tree, **session** is the running terminal, and **attached/detached**
names the binding between them. It states the current steady-state 1:1
relationship as a fact about today rather than a definition, and carries the
reasoning above so the word cannot drift back in.

### Critical files

`Msg.swift`, `Command.swift`, `Projections.swift`, `ModelOperations.swift`, and
`SurfaceGeometry.swift` in `lib/DanTermCore/Sources/DanTermCore/`; `AppRuntime.swift`,
`Reconcile.swift`, and `TerminalView.swift` in `app/`; the mirroring test names
across `lib/DanTermCore/Tests/` and `tests-ui/`; a new `docs/design/` note plus
its `docs/design/index.md` entry. `AGENTS.md` describes the data flow as
"creating surfaces" and follows the rename mechanically.

## Invariants

- **I1.** In DanTerm-owned code, `session` is the only noun for a running
  terminal instance. `surface` survives only in the graphics sense, the
  ordinary-English sense, and inside Ghostty adapter code.
- **I2.** No externally observable artifact changes: IPC method names and
  payloads, CLI command surface, persisted snapshot format, config keys, and
  terminal byte output are all identical before and after.
- **I3.** Sessions are keyed by `PaneId`, and pane/session correspondence is 1:1
  at steady state. Creation failure, close, and reconciled teardown may leave a
  pane without a session or a session outliving its pane transiently. No
  durable detached session exists today. This is the current relationship, not
  the definition of either word.

## Proof obligations

- **PO1 (I2).** The persistence, characterization, and IPC method-name suites
  pass with their expectations unmodified. Only identifier spellings may change
  in test sources; no expected value, fixture, or recorded artifact may.
- **PO2 (I1).** A repository-wide audit of DanTerm-owned source, tests, and
  documentation finds no remaining `surface` in the terminal-instance sense.
  The three retained meanings are the only permitted survivors and are
  enumerated explicitly, so a hit is either a defect or an allowlisted entry.
- **PO3 (I3).** The design note states the pane/session/attached definitions and
  records the steady-state 1:1 correspondence plus its transient exceptions,
  with the detached-session direction named as future work.

## Verification

- `just test` and `just test-ui` green.
- `git diff` over `lib/DanTermCore/Tests/` shows renames only -- no changed
  assertions, fixtures, or recorded artifacts (this is PO1's real evidence).
- Build and launch the app, then exercise the paths whose events were renamed:
  a shell that sets its title, a `cd` that moves the reported cwd, a bell, a
  long-running command reporting progress, and closing a pane by exiting its
  shell. Sidebar and toolbar chrome must update as before.
- Restore a persisted session from before the rename to confirm the snapshot
  format is unchanged in practice, not only in test.

## Non-goals

- Splitting `PaneModel` into separate pane and session models, or introducing
  `SessionId`. That changes `PaneSnapshot` and what `danterm` CLI commands
  target, which fails Milestone 9's replacement gate. It is post-Milestone-10
  work that this plan's vocabulary and ADR exist to enable.
- Renaming inside Ghostty adapter files that Milestone 10 deletes.
- Any behavior change. This is a rename.

## Accepted risks

- **AR1.** A wide identifier diff will conflict with future `git merge master`
  runs. Accepted deliberately: the conflicts are mechanical rename collisions,
  and the alternative is writing new Milestone 9 code in the old vocabulary.

## Rejected ideas

- **RI1.** `terminal` as the noun -- diverges from the already-shipped
  `TerminalSession` and `TerminalSessionEvent`, which would leave two words again.
- **RI2.** `pane` as the noun -- collides with user-set titles. The existing
  `testSurfaceTitleDoesNotOverrideCustom` depends on distinguishing a
  terminal-reported title from a custom one, which `paneTitle` would blur.
- **RI3.** Recording the lexicon in `AGENTS.md` -- the reasoning is ADR-shaped
  and belongs with the other durable decisions in `docs/design/`, not in the
  everyday instructions file.

## Implementation discretion

- Whether PO2 becomes a lint step alongside `scripts/core-purity-lint.sh` or
  stays review-enforced.
- Exact spellings beyond the Msg and Command cases fixed above.
