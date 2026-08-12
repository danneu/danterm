# Eliminate sidebar associated-object state

## Problem

`SidebarView` uses Objective-C associated objects for two values on controls it
creates and owns:

- a group id attached to each reusable caret button;
- the active `RenameTarget` attached to an inline rename text field.

The rename target is also mirrored in `AppRuntime.viewLocalState`, so one edit
session has two owners whose clear-before-resign ordering must stay synchronized.
The associated-object keys are global mutable byte addresses, which require
`nonisolated(unsafe)` under Swift 6 even though the bytes themselves carry no
state.

Associated objects are a supported Objective-C runtime facility, but they solve
dynamic extension of objects. DanTerm owns these controls and can represent both
facts with typed Swift state instead. AppKit already supplies the edited control
to its text-editing delegate, supplies the originating control to target-action,
and supports custom state on view-based table cells and their subviews:

- [NSControlTextEditingDelegate](https://developer.apple.com/documentation/appkit/nscontroltexteditingdelegate)
- [NSControl target-action](https://developer.apple.com/documentation/appkit/nscontrol)
- [NSTableCellView](https://developer.apple.com/documentation/appkit/nstablecellview)
- [Table View Programming Guide: reuse](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TableView/TableViewOverview/TableViewOverview.html)
- [Objective-C associative references](https://developer.apple.com/documentation/objectivec/objc_setassociatedobject(_:_:_:_:))

This cleanup follows the Swift 6 migration. Swift 6 language mode is the
baseline, not work performed by this plan.

## Decision

Make `SidebarView` the sole owner of the active inline rename session: the
`RenameTarget` together with the exact `NSTextField` whose field editor owns the
draft. The reconciler reads the session's target through the existing view
handle, passes it to the pure rename guard, and asks the view to end the exact
target when a structural operation invalidates the edit. Delete the
single-purpose `ViewLocalState` wrapper and its `AppRuntime` storage.

AppKit delegate callbacks may act only when their control is identical to the
field stored in the active session. Identity never depends on row visibility,
cache traversal, or re-deriving a field from a target. Clear ownership
synchronously before ending a field edit, so reentrant or stale callbacks become
no-ops and cannot dispatch a second rename or clear a newer session. Starting
another rename explicitly commits the prior session with click-away semantics;
only after that completion may it resolve the successor's current cell and
install the new session. The successor cannot be captured earlier because the
prior commit may reconcile and change the mounted rows.

Cell reuse is an ownership boundary. Whenever a reused cell's rename state is
reset, also clear the active session if that cell contains the owned field. This
protects the case where AppKit discarded an editor without a delegate callback
before the cell entered the reuse pool.

Reconciliation reads the target before applying row operations for the pure
rename guard, then reads it again after applying them for cache advancement.
The latter means "this reload is still suppressed now"; operations may have
ended and repainted the edit between the two reads.

Give the group caret a typed stored `GroupId`. Configure it whenever a reusable
group cell is populated, and resolve caret actions from that typed identity.
Do not encode entity identity in `NSControl.tag`: it is an untyped `Int`, while
`GroupId` is a UUID-backed phantom-typed id. Delete the existing dead
group-title-field tag assignment for the same reason.

Remove `AssociatedKeys`, all associated-object operations in `SidebarView`, and
the two `nonisolated(unsafe)` declarations. Keep `RenameTarget` in the pure layer
because the rename guard and completion-message logic consume it. Use
`RenameTarget` directly for completion logic instead of maintaining the
duplicate `RenameAction` vocabulary.

Amend `docs/design/2026-05-27-model-driven-view-reconciliation.md` to state the
general rule: a pure reconciler helper may receive explicit state read from a
runtime-owned view handle. Do not preserve a concrete `ViewLocalState` concept
after it has no state to own.

## Invariants

- I1: Exactly one owner records which sidebar row is being renamed.
- I2: Enter commits once, Escape cancels, click-away commits once, and starting
  another rename preserves the existing transition behavior.
- I3: Every exit path clears ownership before asking AppKit to end the edit.
  Reentrant and stale delegate callbacks cannot dispatch twice or affect a newer
  edit.
- I4: Cosmetic reconciliation preserves a live edit. Removal, movement,
  collapse, selection change, full rebuild, or loss of the field editor ends an
  invalidated edit without stranding editable state.
- I5: Reused cells carry only the identity assigned during their latest
  configuration and never inherit editability, action identity, or rename
  ownership from a prior row.
- I6: Caret actions expand or collapse the group displayed by the sender.
- I7: The implementation compiles in Swift 6 with no Objective-C associated
  state or concurrency escape hatch for these controls.

## Proof obligations

- PO1 (I1, I3): UI tests prove that every rename exit clears ownership and that
  a callback from a non-active field cannot complete or cancel the active edit.
  The active session continues to identify its original field when the row is
  absent or a replacement field now paints that target.
- PO2 (I2): UI tests drive tab and group commit, cancel, click-away, and
  replacement by a second rename, including message order and exactly-once
  dispatch. Replacement commits the prior field's draft exactly once to the
  prior target before the successor session exists.
- PO3 (I4, I5): Existing rename/recycle regressions remain green for abandoned
  editors, selection changes, structural reconciliation, cosmetic sweeps, and
  reuse after teardown. New coverage proves that resetting a reused field whose
  editor was discarded clears the matching active session without an
  intervening reconcile. Group-row coverage proves that removal, a full rebuild,
  and selection change end a live group rename and restore non-editable,
  model-backed display state.
- PO4 (I6): A behavioral UI test reconfigures or reuses a group row, invokes its
  caret, and proves the action names the currently displayed group.
- PO5 (I7): `just test` and `just test-ui` pass. A source check confirms that
  current code and tests contain no `AssociatedKeys`, sidebar associated-object
  calls, `ViewLocalState`, or `RenameAction`, and that this change introduces no
  `nonisolated(unsafe)`.

Follow TDD: add or redirect each behavioral proof first, observe the expected
failure, then change production code and return both suites to green.

## Non-goals

- Do not change rename policy, group-collapse behavior, sidebar selection, or
  projection diff semantics.
- Do not move ephemeral rename state into `AppModel`, persistence, IPC, or the
  command/update loop.
- Do not replace AppKit's field editor or introduce a custom editing state
  machine.
- Do not redesign other associated-object users outside `SidebarView`.

## Rejected ideas

- RI1: Keep `AppRuntime.viewLocalState` as the sole rename owner. It removes the
  Objective-C storage but leaves a view-owned edit session on a broader owner and
  retains plumbing whose only consumer is the sidebar reconciler.
- RI2: Store the group id in `NSControl.tag`. Integer conversion loses the
  compiler-enforced `GroupId` boundary; hash conversion can collide.
- RI3: Keep associated objects and only annotate their key addresses. This makes
  the Swift 6 compiler accept the mechanism but preserves dynamic, duplicated
  state where typed storage is available.

## Implementation discretion

- The concrete private control or cell subclass that stores the caret's typed
  group identity.
- The names and visibility of the narrow `SidebarView` rename-state accessors,
  provided mutation remains view-owned and the reconciler cannot clear it
  independently.
