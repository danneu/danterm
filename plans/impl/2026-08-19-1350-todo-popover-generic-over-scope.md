# CHROME-1: one TODO popover controller generic over its scope

## Context

`app/TodoPopoverControllerBase.swift` emulates an abstract class: 21 members
whose bodies are `fatalError("subclass must override")`. Swift cannot check
that emulation -- a missing override or a third TODO scope compiles and traps
at runtime. Its two subclasses (`app/TodoPopoverView.swift#TodoPopoverViewController`,
`app/TabTodoPopoverView.swift#TabTodoPopoverViewController`) implement the
same algorithm twice: projection apply with first-responder capture and
restore, selection preservation across every mutating Msg, list key routing,
and the Cmd-key table. The split leaks outward: `Reconcile.applyTodoPopover`
switches on the projection to pick a class, and
`AppRuntime.closeTodoShortcutHelpPopover` casts the same content view
controller twice for a method that lives on the base.

Source: audit finding CHROME-1 (`docs/scratch/2026-08-18-construction-audit.md`,
verified 2026-08-19 against the current tree). This buys structure and future
safety, not a bug fix: the one genuine source divergence
(`cancelEditAndReturnToList`'s focus fallback) is unreachable in production
because `apply` reconciles the edit target first. A design pressure-test of
the single-controller shape against every scope-varying behavior (state
ownership, drag/drop, sectioned rows, re-entrant post-add selection, key
handling) found no case it cannot express without behavior change.

## Decision

One `TodoPopoverViewController<Scope: TodoPopoverScope>` replaces the base
class and its two subclasses; pane and tab become two conforming scope types,
not subclasses. `Scope` carries associated projection, row, and edit-target
types, so the controller's `TodoPopoverState<Scope.EditTarget>` stays fully
typed and no target erasure is needed. The scope vends
everything scope-specific: a uniform row description (optional item,
selectability, header-ness, an opaque edit-target token, section identity),
static chrome (titles, placeholder, shortcut-help scope, drag type, extra
header buttons, empty-state), target resolution, Msg construction for every
mutating action, drag payload handling, and the tab-only behaviors (bucket
moves, post-add selection, header-click side effect). The controller owns the
algorithm once and never branches on scope identity.

Decisive constraints:

- A generic `NSViewController` subclass may expose `@objc` actions and satisfy
  `NSTableViewDataSource` / `NSTableViewDelegate` / `NSTextViewDelegate`
  dispatch, but only from its primary class declaration: Swift rejects both an
  `@objc` member and an `@objc` protocol conformance in an extension of a
  generic class. So every ObjC-facing member of the controller lives in the
  class body. Verified 2026-08-19 with a compiled AppKit probe (target/action
  through the ObjC runtime and `NSTableView` data-source dispatch both reach a
  generic controller).
- `Reconcile` must not name the scope type, so the controller conforms to a
  small non-generic protocol vending `apply(TodoPopoverProjection)` (plus the
  shortcut-help close entry point `AppRuntime` needs); that protocol is the
  only outward seam.
- The scope is an app-layer value; AppKit may appear in it (cell building).
  The pure resolvers it wraps stay in DanTermCore where they are already
  tested.
- `Reconcile.applyTodoPopover` collapses to one apply call;
  `presentTodoPopover` keeps its switch only to choose the anchor and
  construct the scope value from the projection case.
- Ordering (risk mitigation, from the audit's sequencing): land in three
  independently green commits --
  1. `AppRuntime` cleanup that is correct today: collapse the double cast in
     `closeTodoShortcutHelpPopover` to one cast to the base, and delete
     `closeTabTodoShortcutHelpPopover` (zero callers, dead code).
  2. Characterize, against today's tree, every behavior the refactor moves
     behind the scope boundary and no suite currently pins. Tab-suite parity
     with the pane suite on shared behaviors: Cmd-N while editing,
     Cmd-Backspace survivor selection, Escape in list mode sends the toggle
     Msg, compose/table focus preservation across apply. Plus, in both suites,
     the drag and key paths the scope will own -- see PO6. These must pass
     against today's tree; if one fails, that failure is a real bug fixed as
     its own commit before the refactor.
  3. The refactor beneath the green suites.
- `test-ui.sh` holds an explicit source list; file adds/removes/renames under
  `app/` must update it (`scripts/tests/test-ui-harness_test.sh` gates this).
- Popover and responder lifetime rules bind:
  `docs/design/2026-06-09-appkit-lifetime-safety.md`.

## Invariants

- I1 **Pure refactor.** No observable behavior changes. Both UI suites pass
  with no assertion edited; only fixture construction may change shape.
- I2 **Intentional per-scope differences survive.** Tab swallows
  Cmd-Shift-H/L, pane lets them bubble; pane row checkbox sends
  `toggleTodoDone`, tab rows send explicit `setTodoDone`; tab selects the
  newly added todo after compose submit, pane does not; after an accepted
  drop the pane restores the todo that was selected before it while the tab
  selects the dropped todo under its new owner; tab pane-section header click
  focuses the pane and dismisses the popover.
- I3 **No runtime override points.** No `fatalError("subclass must
  override")` member remains; a scope that misses a requirement fails to
  compile; a third TODO scope is a new conforming type, not a class. Only
  behavior that is correct for every scope may carry a default implementation
  on `TodoPopoverScope`; every scope-specific requirement (target resolution,
  Msg construction, drag payload and drop acceptance, bucket moves, post-add
  selection, header-click side effect, static chrome) has no default, so
  omitting it is a compile error rather than silently inherited behavior.
- I4 **Post-add ordering.** The compose-submit flow snapshots scope state
  before `runtime.send` and runs post-add selection after it, because
  `.addTodo` reconciles inside the send frame and re-enters `apply`
  synchronously in production. The unified flow must stay correct under that
  re-entrancy, as both controllers are today.
- I5 **Nearest-row fallback generalizes, not changes.** The unified
  nearest-selectable-row search adopts the tab algorithm (in-range, forward,
  backward, else compose/deselect); on the pane's flat uniformly-selectable
  lists it is behavior-identical at every reachable call site. The direction
  difference was never drift (audit Correction) and must not surface as a
  pane behavior change.

## Proof obligations

- PO1 (I1, I2, I5): `tests-ui/TodoPopoverViewTests.swift` (22 tests) and
  `tests-ui/TabTodoPopoverViewTests.swift` (18 + the commit-2 additions) pass
  before and after commit 3 with no assertion edits. `just test-ui`.
- PO2 (I1): the commit-2 characterization tests pass against the pre-refactor
  tree, proving the behaviors already hold where the suites were silent.
- PO3 (I1): the pure suites the controllers drive -- `TodoPopoverStateTests`,
  `TabTodoTests`, `TodoShortcutCatalogTests`, `UpdateTodoTests`,
  `ProjectionsTests` -- are untouched and green. `just test`.
- PO4 (I3): discharged by compilation -- the base class's override points are
  deleted, so the trap is not expressible.
- PO5 (I4): the tab post-add scenario in PO6 discharges the re-entrant
  compose-submit ordering.
- PO6 (I1, I2, I3): commit 2 pins, in both suites, the paths that become scope
  requirements and that no test currently reaches --
  - drop acceptance, its Msg, and the selection it leaves: pane reorder
    accepted, sending the pane reorder Msg, and restoring the todo that was
    selected before the drop; tab same-bucket reorder and tab cross-bucket
    move, each accepted, sending its own Msg, and leaving the dropped todo
    selected at its new owner. A scope that returns `false` from `acceptDrop`,
    dispatches the other scope's Msg, or loses selection across the
    synchronous reapply must fail here.
  - Shift-H/L: tab moves the selected todo between buckets and keeps it
    selected under its new owner, pane does nothing.
  - Cmd-Shift-H/L: tab swallows the key, pane lets it bubble (assert the
    unhandled result, not just the absence of a Msg).
  - post-add selection after compose submit: tab selects the newly added todo,
    pane leaves selection alone.

  Every scenario above runs through a shim that applies the updated projection
  during `send`, so the assertion is about selection after the re-entrant
  apply, not after a post-hoc one.

## Non-goals

- No behavior fixes ride along. The unreachable `cancelEditAndReturnToList`
  divergence is unified structurally, not fixed as a bug; the pane keeps
  letting Cmd-Shift-H/L bubble; the toggle-vs-set checkbox Msg difference
  stays.
- No model, reducer, or other DanTermCore changes: the refactor is confined to
  `app/` and `tests-ui/`. `TodoPopoverState` is already generic over an
  `Equatable` target, so the typed scope needs nothing added to core.
- No change to popover presentation, anchoring, or the
  `TodoPopoverDelegateAdapter` close path.
- No unification of the two projections or their `desired*` builders; the
  scope boundary absorbs the difference.

## Rejected ideas

- The audit's cheaper fallback (keep the subclass split; move required
  members to a protocol so a missing one is a compile error): removes the
  trap but leaves the duplicated apply/selection algorithm, which is where
  drift lives. Rejected by the design bar; the ideal is feasible (GO from the
  pressure-test).
- A non-generic controller holding an existentially-typed scope, with the edit
  target erased at the controller boundary: rejected once a compiled probe
  showed a generic `NSViewController` handles `@objc` actions and table
  dispatch (see the constraint above). Erasure would add a mechanism and a
  core `Hashable` conformance that the typed shape does not need.

## Implementation discretion

- The exact `TodoPopoverScope` surface (roughly fifteen requirements fell out
  of the pressure-test), subject to the default rule in I3; file layout of the
  unified controller, the outward apply protocol, and the two scope types.

## Critical files

- `app/TodoPopoverControllerBase.swift` -- becomes the single controller +
  scope protocol home.
- `app/TodoPopoverView.swift`, `app/TabTodoPopoverView.swift` -- collapse to
  scope values plus their cell building and drag payloads.
- `app/Reconcile.swift` (`presentTodoPopover`, `applyTodoPopover`),
  `app/AppRuntime.swift` (`closeTodoShortcutHelpPopover`).
- `tests-ui/TodoPopoverViewTests.swift`, `tests-ui/TabTodoPopoverViewTests.swift`,
  `test-ui.sh`.

Reuse, don't re-derive: `TodoPopoverState`, `classifyListAction` /
`classifyInputAction`, `firstSelectableRow` / `nextSelectableRow` /
`sectionLocalIndex`, the `resolveTabTodo*` family, `newlyAddedTabTodoTarget`,
`TabTodoRow`'s accessors, `todoShortcutSections(scope:)` -- all already in
DanTermCore with tests.

## Verification

Per commit: `just test` (core gate) and `just test-ui > .build/ui.log 2>&1`,
then grep the log once. After commit 3, additionally: launch a dev instance
with `just launch-slot`, open a pane TODO popover and a tab TODO popover, and
walk the keyboard surface (compose, edit, cancel, Cmd-N, Cmd-Backspace,
Shift-J/K reorder, tab-only Shift-H/L bucket move, Escape, ? help popover)
plus drag reorder in both and a cross-bucket drag in the tab popover. This
walk is supplementary confirmation; PO6 is what must catch a broken scope.
Stop the slot when done.

## Commit progress
- [x] 1. refactor(app): close todo shortcut help through the controller base
- [ ] 2. test(ui): pin the todo popover behaviors the scope boundary will own
- [ ] 3. refactor(app): one TODO popover controller generic over its scope
