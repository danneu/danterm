# Display strings are single-line by type

## Context

A tab row in the sidebar shows its title in a label that can wrap. The row is a
fixed 40 pt (`SidebarView.swift`, `heightOfRowByItem`), so a title carrying a
newline wraps to a second line and pushes the subtitle and pane strip out of the
row.

Nothing prevents that title from carrying a newline. User-supplied names --
rename, CLI launch title, group rename -- are flattened on admission by
`String.singleLineName` (`lib/DanTermCore/Sources/DanTermCore/EntityTitle.swift`),
but a terminal-reported title (OSC 0/2) is not: it passes a 64 KiB byte cap
(`TerminalMetadataBounds.isAdmitted`) and is then stored verbatim
(`PaneLifecycleReducer.reduceSession`). Any program can put `\n` or a raw
control character into a tab title with one escape sequence.

The same untrusted text reaches other single-line surfaces -- the switcher row,
the window title, the alerts popover, the close-tab confirmation -- and the
per-label workaround has already been applied twice by hand
(`PaneWrapperView.swift`, `remoteSessionLabel` and `agentSessionLabel` both set
`usesSingleLineMode`), each time for one label, never for the class.

### Why the fix is not in the reducer

Flattening `.title` where it is stored would fix the reported symptom in two
lines. It is the wrong boundary. `cwd` and `command` are reported by the same
mechanism and can carry the same characters, but they are *functional* data: a
new pane inherits `cwd`, IPC clients match panes on exact `cwd` and `title`
(`integrations/danterm/SKILL.md` makes pane title a targeting field), and the
snapshot round-trip must reproduce what was captured. Normalizing them in the
model would corrupt data that is not only displayed.

So the boundary that can hold the invariant is the one where model state becomes
a display string: the projection layer. The outcome: a value that is going to be
laid out as one line has a *type* that cannot hold more than one line, and every
projection carries that type instead of `String`.

## Direction

Introduce `DisplayLine` in `DanTermCore`: a value type whose only initializer
normalizes. It is the declared type of every display string that leaves core.

The model, IPC JSON, and checkpoints keep terminal-reported text **verbatim**.
Normalization happens exactly once, at the display projection boundary.

### Normalization

`DisplayLine(raw)` collapses each run of Unicode `White_Space` to a single
space, drops leading and trailing runs, and strips scalars of general category
`Cc` (C0 and C1) and the bidi overrides/isolates U+202A-202E and U+2066-2069.

Two properties this must have, both testable:

- Words are not glued across a line break. `"a\nb"` is `"a b"`, not `"ab"` --
  `\n` is both whitespace and a control character, so whitespace splitting has
  to happen before control stripping.
- Category `Format` is not stripped wholesale, so ZWJ (U+200D) survives and an
  emoji sequence in a title still renders as one glyph.

Normalization is idempotent.

`String.singleLineName` is rebuilt on the same primitive and keeps its own
admission semantics (nil when nothing survives). It gains control-character
stripping, which is a real behavior change: a pasted rename containing BEL or
ESC no longer reaches the model.

### Type shape

`DisplayLine` is `Equatable`, `Hashable`, `Sendable`,
`CustomStringConvertible`, and `ExpressibleByStringLiteral` (literal
initialization runs the same normalizer, so nothing is laundered; it also lets
the `"Terminal"` defaults and the existing `#expect(tabTitle(tab) == "vim")`
comparisons stand unchanged).

It deliberately does **not** conform to `ExpressibleByStringInterpolation` --
that conformance would make `let t: DisplayLine = "\(rawTitle)"` compile and
silently defeat the type. Say so in a comment at the declaration, because the
next reader's instinct will be to add it.

No `Codable`: nothing `DisplayLine`-typed is persisted or wire-encoded, and the
conformance would invite exactly the decision rejected above. Composition
happens on `String` and re-wraps.

AppKit reads the value out as `.text`, not through interpolation, so every
readout site is greppable.

### Scope of adoption

The boundary is the **render-ready payload field**, not the helper that sources
it. Two invariants define it:

- **I1.** Every string meant to be presented on one line is `DisplayLine`-typed
  at the point it leaves core, and a view never composes such a string from raw
  strings or domain objects. Text that is deliberately not single-line stays
  raw: an alert body (a sender's message, which may legitimately wrap) and the
  search needle (live user-typed text echoed into a field).
- **I2.** `DisplayLine` is constructed only when building a render-ready value:
  a projection, a display-bearing `Command`, or stored derived presentation such
  as `AlertModel.title`. Terminal-reported model facts, shared source helpers,
  IPC, and persistence stay raw `String`.

I2 is load-bearing: `tabDisplayTitle` feeds `pane info`'s `tab.title` in
`IpcEntityEncoder.swift` as well as the sidebar. Typing the helper itself would
either normalize the wire value -- contradicting the non-goal below -- or force
IPC to reach through `.text` and launder it back. So `ModelOperations`'
title helpers, `paneCommandChromeText`, and the rest of the shared source
helpers stay `String`; their projection call sites wrap.

Render-ready fields that become `DisplayLine`:

- `WindowChromeProjection`, `SidebarTabProjection`, `SidebarGroupProjection`,
  `SwitcherRow`, and `PaneToolbarRender` (see below).
- `Command.showCloseTabConfirmation`'s tab title and `Command.sendNotification`'s
  title/subtitle, which reach NSAlert and notification text without passing
  through any projection.
- `AlertModel.title` (stored derived presentation, rendered straight into a
  label) and `TabTodoRow.paneSectionHeader`.

`AlertModel.body` stays raw, per I1. `AlertPresentation.swift` already states
that the sender's body is never rewritten, and that contract stands.

`PaneToolbarRender` violates I1 twice today. It carries `title`, `cwd`, and
`command` separately and lets the *view* compose them
(`PaneWrapperView.updateToolbar` calls `paneCommandChromeText`), and it hands
over the `RemoteSession` and `AgentSession` domain objects, from which the view
composes the remote pill's text, the agent pill's text, and the pane chip's
tooltip. A remote identity's user and host arrive base64-encoded in the
`DanTermShell=3;connection;remote` sequence and are as untrusted as the title.

All four composed strings -- chrome text, remote pill, agent pill, chip tooltip
-- become `DisplayLine` fields built in `desiredPaneToolbar`, and the domain
objects stop crossing. An accessory's visibility follows from its composed value
being nil. The chip tooltip must keep naming the agent kind and the full session
id it names today. The render keeps non-string fields (`progress`, `chipKind`,
counts, flags) as they are.

### AppKit labels

The type constrains the value; it does not make a label in a fixed-height row
declare its own constraint. Both stay. Every fixed-height label that receives a
`DisplayLine` lays out on exactly one line and truncates rather than wraps,
whatever string it is handed: the sidebar tab title and subtitle fields, the
sidebar group header, the switcher name label, the alerts popover title, the
pane toolbar label, the window chrome title, and the tab-todo header row.
`LinkPreviewView.swift` shows the property set that achieves this;
`PaneWrapperView`'s remote and agent session labels are half-configured today
and come up to the same standard, so the rule reads as one rule.

The sidebar tab title field also goes editable for inline rename, and it must
not be possible to type a newline into it: Return commits the rename.

## Non-goals

- Changing what the model stores. Terminal-reported title, cwd, and command stay
  byte-for-byte as reported.
- Changing IPC JSON or checkpoint contents. Both stay raw; this is the shape
  `docs/design/2026-08-10-session-owned-terminal-reported-facts.md` D5 already
  decided, and IPC clients target panes by exact title and cwd.
- A lint enforcing "no bare `String` on a projection struct". Considered and
  declined: the rule has legitimate exceptions (the search-overlay needle is
  user-typed text echoed live), so it would need a suppression list from day
  one. The type and the sweep test carry the invariant.

## Accepted risks

- A new render-boundary field can still be declared `String` and skip
  normalization. The sweep test catches it for every boundary the plan
  enumerates; a field on a render boundary added later would not be caught until
  someone extends the sweep.
- `singleLineName` gaining control-character stripping changes admission of user
  names. Intended, and pinned by a test.

## Documentation

- Add a decision to `docs/design/2026-08-10-session-owned-terminal-reported-facts.md`
  beside D5: model, IPC, and checkpoints store terminal-reported text verbatim;
  normalization happens once, when a render-ready payload is built, carried by
  `DisplayLine`. Without it, the next person who sees a newline in `danterm ls`
  output will "fix" it in the reducer.
- `integrations/danterm/SKILL.md` documents a `jq -r` recipe that prints one
  line per pane from `.title` and `.cwd`. Since those stay verbatim, note there
  that they may contain newlines and control characters and that a script
  needing one record per pane should use `@tsv`.

## Verification

Proof obligations. Behavioral, asserted through projection output and model
state -- not through `DisplayLine`'s internals, except in its own unit suite.

1. **Normalization contract.** New `DisplayLineTests`: newline, CR/LF, tab, VT,
   FF and space runs each collapse to one space; C0/C1 and bidi overrides are
   stripped; words are not glued across a line break; leading/trailing
   whitespace is gone; the result is idempotent; ordinary text, CJK, and a ZWJ
   emoji sequence survive; literal initialization normalizes identically.
2. **User-name admission.** New `EntityTitleTests` (there are none today):
   whitespace-only and control-only input is rejected as nil; an embedded
   newline collapses; a trailing BEL is stripped.
3. **No display string is multi-line (I1).** A sweep over hostile inputs
   (`"a\nb"`, `"a\r\nb"`, an ESC-prefixed OSC fragment, mixed whitespace runs,
   newlines only) driven through real `.sessionReport` messages, asserting that
   no string reaching a view contains a newline or a control scalar. The sweep
   covers every render boundary the plan types, not only the four main
   projections: `desiredSidebar`, `desiredWindowChrome`, `desiredSwitcher`,
   `desiredPaneToolbar` (including the composed remote pill, agent pill, and
   chip tooltip, driven by a `DanTermShell=3;connection;remote` identity whose
   decoded user carries a newline), the alerts popover rows, the tab-todo pane
   section headers, and the emitted `showCloseTabConfirmation` and
   `sendNotification` commands. This is the test that catches a future field
   added raw.
4. **The model keeps the raw value.** After `.title("a\nb")`, `.cwd` with a
   newline, and `.commandStarted` with a newline, session state is byte-identical
   to what was reported. This pins the architectural claim and fails loudly if
   someone later "fixes" normalization in the reducer.
5. **IPC and checkpoints keep the raw value (I2).** `pane info`'s `tab.title`
   and `ls`'s pane title equal the reported string byte-for-byte, for a title
   containing a newline -- the same tab whose sidebar projection is flat. A
   snapshot round-trip preserves the raw title while the restored tab's display
   title is flat.
6. **Display surfaces are flat for a hostile title.** Tab title and subtitle,
   the close-tab confirmation's title, and the alert presentation's title.
7. **Raw text stays raw (I1's exceptions).** The emitted notification body is
   byte-identical to the sender's, for a body containing newlines.
8. **The pane chip tooltip still names the agent.** For an attached agent, the
   tooltip carries the agent kind and the full session id, as it does today.
9. **The labels stay one line on their own.** In `just test-ui`, handed a
   multi-line string directly -- not a `DisplayLine`, so the assertion survives
   that layer being removed: every hardened label lays out one line and
   truncates. Sidebar tab title, sidebar subtitle, group header, switcher name,
   alerts popover title, window chrome title, tab-todo header row, and the pane
   toolbar label with its remote and agent accessories.
   (`tests-ui/SidebarProjectionRowTests.swift` and
   `tests-ui/PaneWrapperViewTests.swift` already build these in a real window.)
   This is the obligation that would have caught the original bug.
10. **Renaming a tab cannot produce a newline.** In `just test-ui`, Return in
    the sidebar's rename field editor commits the rename rather than inserting a
    line break.

TDD order: each test is written first and fails for the stated reason.

Gate: `just test`. Commit 4 additionally needs `just test-ui` from a GUI
session. End-to-end check in a real window: `just launch-slot`, then drive a
pane with `printf '\033]0;line one\nline two\007'` and confirm the sidebar row
shows one line and keeps its subtitle and pane strip.

## Commit progress

- [x] 1. Add `DisplayLine` and rebuild `singleLineName` on the shared
      normalizer. No consumer adopts it yet; the only behavior change is
      control-character stripping in user-name admission. Obligations 1-2.
- [x] 2. Move pane-toolbar composition from the view into `desiredPaneToolbar`:
      `PaneToolbarRender`'s `title`/`cwd`/`command` become one composed field,
      and its `RemoteSession`/`AgentSession` become the composed remote pill,
      agent pill, and chip tooltip, all still `String`. Stands on its own -- the
      view stops receiving raw `cwd` and raw remote identities -- and isolates
      the mechanical UI-test call-site churn. Obligation 8.
- [x] 3. Type every render-ready value as `DisplayLine` (I1) while the shared
      model and IPC helpers stay `String` (I2), with the AppKit readouts.
      Obligations 3-7, plus the design-doc decision and the SKILL.md note.
- [ ] 4. Harden the single-line labels. Obligations 9-10. Separate because it is
      the only commit needing a GUI session and the only one that can regress
      the rename field editor.

## Implementation notes

- `just test-ui` could not compile at all before this work started: the harness
  is a raw `swiftc` build over an explicit file list, and `PaneTapeFollow.swift`
  had begun naming `IpcConnection` without the list being extended. Obligations
  9-10 need that suite, so the one-line repair landed as its own commit ahead of
  the plan's commits rather than riding inside one of them.
- `PaneToolbarRender`'s composed field is named `label`, and the accessory
  fields `remoteLabel`, `agentLabel`, and `chipTooltip`. Each accessory's
  visibility now follows its value being nil, so `agentLabel` is nil for every
  agent whose chip already names it -- the `chipKind == .agent` rule the view
  used to apply moved into the projection with it.
- `AlertPresentation`'s own `title` and `subtitle` are typed, not just the two
  places the plan names (`AlertModel.title` and `.sendNotification`). Both of
  those read from it, so typing the stored alert and the command separately
  would have meant wrapping the same value twice and letting them drift.
- The sweep drives a remote identity as a `RemoteSession` on a
  `.connectionDeclared` report rather than as a `DanTermShell=3` sequence: the
  base64 decode lives in `TerminalCore.Terminal`, a different module, so the
  report is the value that decode produces.
- `SidebarRenameRecycleTests` used a long title ending in a space. That trailing
  space no longer survives the projection, so the title gained a final word --
  the test is about row recycling, not about trimming.
