# One TodoOwner: unify the pane/tab todo surface and the todo.* wire

Implements audit finding S07 (docs/scratch/2026-08-11-simplification-audit.md)
plus an IPC extension: the 7 `todo.*` methods gain a pane-or-tab owner target.
Folds in the S51 rider (phantom-typed todo ids). Verified against the tree as
of 2026-08-12, after commit 5a296702 (S50) moved IPC dispatch into
`IpcDispatch.swift`.

## Problem

Todo editing exists twice, keyed by PaneId and by TabId, differing only in
which accessor writes the array:

- 9 mirrored Msg pairs plus `moveTodo` (Msg.swift), ~200 lines of
  line-for-line-equivalent reducer arms (Update.swift), 4 popover Commands,
  and three structurally identical two-case enums (`TodoSource`,
  `TodoDestination`, `TodoPopoverScope`).
- The halves have drifted: `.deleteTodo` and `.clearCompletedTodos` lack the
  owner-exists guard their tab twins carry. Benign today (the pane mutator
  silently no-ops and every todo arm returns no commands); a real bug the
  moment a todo arm emits anything.
- The 7 `todo.*` IPC methods (of 26 total) are structurally pane-only, so tab
  todos are readable (`ls`, `pane.info`) but not writable from any remote
  client. `setTodoDone` for tabs exists in the reducer with no production
  sender at all.
- Todo ids are the last raw ids in the system (`UUID` in Msg payloads,
  `String` on the wire), against the repo rule that entity ids are
  phantom-typed.

An iOS thin client will speak this IPC protocol. Unifying the owner shape
before a second client is written against the pane-only wire is the last time
the change is free; `moveTodo` already proves the unified shape works (it
takes source and destination as owner enums).

## Decision

One public `TodoOwner { case pane(PaneId); case tab(TabId) }`, declared in
DanTermProtocol beside the id aliases (DanTermCore already depends on
DanTermProtocol; the CLI parses into it), used by the model, the Msg surface,
the Commands, the IPC catalog, and the CLI. `TodoSource`, `TodoDestination`,
and `TodoPopoverScope` delete; `TabTodoEditTarget` restructures to carry an
owner plus a todo id. `TodoShortcutScope` stays (payload-free help-text
scope, not an owner).

- **Msg**: the 18 mirrored cases become 9 owner-parameterized verbs (keeping
  the pane-flavored names) plus `moveTodo(from: TodoOwner, ..., to:
  TodoOwner, ...)`. The tab flavor of `setTodoDone` becomes
  production-reachable via the wire instead of being deleted.
- **Model**: one accessor pair on AppModel — read an owner's todos, mutate an
  owner's todos in place — is the only code that switches on `TodoOwner` for
  storage. `updateTab` is promoted from a private Update.swift free function
  to an AppModel method to make that possible. `appendTodo` generalizes to
  any owner and keeps returning the created item (the wire's add reply needs
  it for both owners).
- **Commands**: the 4 popover Commands become `showTodoPopover(owner:)` /
  `dismissTodoPopover(owner:)`. AppRuntime collapses to a single NSPopover
  handle plus a single owner-carrying delegate adapter: the model's
  `todoPopover` slot is single, so two handles encode a state the model
  forbids. The two content reconcile passes and the two projection types
  stay (that unification is S02's job).
- **Wire**: each `todo.*` method takes exactly one of the flat params
  `"pane"` / `"tab"` (mutually exclusive, following the `tab.rename` flat-key
  and `tab.new` exactly-one-of precedents). CLI form:
  `todo <verb> (--pane <pane-id> | --tab <tab-id>) ...`. JSON reply shapes
  are unchanged.
- **TodoId** (S51 rider): `TodoId = TypedId<TodoTag>` replaces `UUID`/raw
  `String` todo ids internally and in the typed request catalog. Required, not
  severable: leaving it out leaves the repo's phantom-typed-id invariant
  violated, keeps the CLI accepting malformed todo ids as arbitrary strings,
  and keeps the redundant per-verb id parsing in the catalog and dispatcher
  that this plan exists to remove.
- **Interaction verbs**: one verb per interaction everywhere — checkbox
  clicks send the explicit-value verb (`setTodoDone`), keyboard toggle sends
  `toggleTodoDone`. (Today the tab popover's tab rows toggle while its pane
  rows set.)
- **Popover mutual exclusion** simplifies to one rule: toggling a popover
  open dismisses whatever popover was open (any owner, including same-kind
  switches), dismiss preceding show in the emitted command list; the show
  interpreter also defensively dismisses before presenting, so the sequence
  is idempotent.

Ordering constraint: the wire, dispatch, CLI, and SKILL.md change as one unit
— the structural proof tests in three suites pin the exact decode/usage
strings and must move in lockstep with them.

## Invariants

- I1 — Every todo verb has identical semantics for pane and tab owners. The
  one exception, preserved deliberately: popover stranding — a pane-anchored
  popover survives tree edits while its pane exists; a tab-anchored popover
  dies when the tab's container shape changes.
- I2 — A todo verb addressed to an unknown owner is a silent no-op that emits
  no commands (uniform guard; retires the drift by construction).
- I3 — At most one todo popover is open; opening one closes any other, and a
  stale close notification for a popover that is no longer the open one does
  not clear the newer state.
- I4 — Wire contract: each `todo.*` method requires exactly one of `pane` /
  `tab` and fails with -32602 otherwise — `"pane or tab required"` when
  neither is present, `"exactly one of pane or tab required"` when both are;
  per-key errors keep the existing catalog vocabulary (`"... must be a
  string"`, `"... not found"`, `"invalid todo"`). Reply shapes
  (`{todos: [...]}`, `{todo: {...}}`, `{ok: true}`) are byte-compatible with
  today.
- I5 — Tab todos are fully editable over IPC and CLI: every verb works
  against a tab owner, and add returns the created item for both owners.
- I6 — The persisted snapshot JSON and the pasteboard drag-payload JSON keep
  today's schema: a todo id is a bare UUID string at both boundaries, never a
  keyed object. Owner and id types convert at those boundaries only, so a
  checkpoint written before this change still restores.
- I7 — `just test` stays green at every landed commit.

## Proof obligations

- PO1 (I1) — the merged reducer suite runs every verb parameterized over both
  owners; the five stranding tests and the pane-vs-tab stranding difference
  are preserved in behavior; all 10 cross-owner `moveTodo` cases survive.
- PO2 (I2) — per-verb unknown-owner tests for both owners, asserting no
  mutation and no commands (these pin the drift fix).
- PO3 (I3) — popover exclusivity tests updated to the unified emission
  (dismiss-previous then show, including same-kind switches); the stale-close
  race test is preserved.
- PO4 (I4) — protocol round-trip suite gains tab-flavored representative
  commands for all 7 methods; new tests for the neither-key and both-keys
  rejections with the exact messages; the UpdateIpcTests targeting table
  updates its 7 todo rows and the previously-untestable `"tab not found"`
  path gets a test.
- PO5 (I5) — IPC lifecycle tests (list/add/edit/done/open/delete/
  clear-completed) run against a tab owner, including add's reply carrying
  the created item.
- PO6 (I6) — the existing snapshot and drag-payload tests pass unmodified, but
  they round-trip in memory and so do not pin the encoding; add the pins:
  a legacy checkpoint JSON fixture with string-valued pane and tab todo ids
  that restores its todos, and assertions on encoded JSON that a todo id
  serializes as a bare string in both the snapshot and the drag payload.
- PO7 (I4, TodoId) — CLI parser tests for all 7 verbs in both owner forms,
  plus the neither-flag and both-flags rejections with the exact usage text,
  and local rejection of a malformed todo id.

## Non-goals

- S02 (popover existence as a reconcile pass) — popovers stay
  command-driven; this plan stops at one command pair, one handle, two
  content passes.
- New wire verbs (`todo.reorder`, `todo.move`) — reorder and cross-owner move
  stay GUI-only; adding a method later is cheap once the owner shape exists.
- S52 (deriving CLI help from the parser) — the hand-synced help text just
  gets updated.
- Unifying the two popover projections or view controllers beyond the shared
  base they already have.

## Accepted risks

- AR1 — Same-kind popover switches now emit an explicit dismiss-previous
  command they previously handled implicitly in the interpreter. This is a
  deliberate simplification (one rule instead of two coordinated half-rules);
  the defensive dismiss in the show arm makes it idempotent.
- AR2 — S02, when it lands, will rewrite the popover command/interpreter code
  this plan produces. Accepted: the single-handle shape this plan leaves is
  the shape S02 builds on, so the churn is bounded and directional.

## Rejected ideas

- RI1 — Keeping two NSPopover handles to minimize churn before S02: rejected
  because the model's single `todoPopover` slot forbids two open popovers,
  and the two-handle shape encodes exactly that impossible state.
- RI2 — A nested owner object on the wire (`{"owner": {...}}`): rejected in
  favor of flat mutually exclusive `pane`/`tab` keys, matching both existing
  targeting conventions in the catalog.

## Implementation discretion

- The parameterized-fixture shape for the merged reducer suite (how the
  pane/tab fixtures build their models and read todos back).
- Naming and placement of the internal owner accessors and dispatch helpers.

## Critical files

`lib/DanTermProtocol/Sources/DanTermProtocol/TypedId.swift` (TodoOwner,
TodoId), `IpcRequest.swift`, `CLIParser.swift`;
`lib/DanTermCore/Sources/DanTermCore/Msg.swift`, `Update.swift`,
`Model.swift`, `ModelOperations.swift`, `TabTodo.swift`, `Command.swift`,
`IpcDispatch.swift`; `app/AppRuntime.swift`, `Reconcile.swift`,
`TodoPopoverView.swift`, `TabTodoPopoverView.swift`, `AppDelegate.swift`,
`PaneWrapperView.swift`; `integrations/danterm/SKILL.md` (command list,
targeting rule, decision table, recipes, stdout shapes);
`cli/main.swift` (help text); test suites named in the proof obligations,
plus `tests-ui/` shims and the UI-test reducer replica.

## Verification

- `just test` at every commit; targeted iteration via
  `swift test --package-path lib/DanTermCore --filter "UpdateTodo|UpdateIpc"`
  and `swift test --package-path lib/DanTermProtocol`.
- `just test-ui > /tmp/ui.log 2>&1` once from a GUI session (excluded from
  the gate).
- Live end-to-end after the wire lands: `just launch-slot`, harvest a tab id
  via `danterm --socket <slot> ls`, then `todo add --tab`, `todo list --tab`,
  `todo done --tab`, `todo clear-completed --tab`; error probes (neither
  flag, both flags, dead tab id); visual check that the tab popover shows the
  CLI-added item and Cmd-' / Cmd-Shift-' still swap popovers cleanly.
