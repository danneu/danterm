# Make sidebar group reload state one value

## Problem

The sidebar group row paints five attributes: name, unread alert count, tab
count, first-row separator state, and collapse state. The diff and
deferred-repaint cache split them between a four-field reload list and a
separate collapse field. A future attribute can be added to one enumeration
without the other. The row can then miss a repaint, or the cache can claim an
unapplied repaint succeeded.

The split already leaves one failed repaint unrecoverable. A collapse operation
records a failed row repaint, but cache retention advances the collapse field.
The next diff therefore emits no operation to retry stale caret and badge
visibility.

The tab-row path does not have this hazard because it compares and retains one
rendered value.

## Decision

Make the group row's complete rendered state one nested Equatable value. Keep
only row identity and child tabs outside it.

Use the grouped value as the shared boundary for row-operation decisions,
deferred-repaint retention, and group-cell painting. A collapse-state change
uses the structural collapse operation, which also repaints the whole current
rendered value. Other rendered changes use the group reload operation.

For every group row the reconcile pass paints, the executor reports the
effective rendered value it applied. This includes paints during selection
restore and full rebuilds, plus a title preserved by a live field editor. An
off-screen row counts as applied because its stored item supplies that value
when the row mounts. Cache advancement records reported values, keeps the prior
value for a group the pass did not paint, and takes the new value when no prior
value exists.

This is a source-breaking internal refactor. Do not preserve forwarding
properties for the former fields.

## Invariants

- I1: Every input to group-row painting belongs to one rendered value used by
  both the row diff and deferred-repaint retention.
- I2: The cache holds each group's effective rendered value reported by the
  executor. A group the pass did not paint keeps its prior rendered value; a
  group with no prior value takes its new rendered value.
- I3: The group cell receives only the rendered value. The sidebar item keeps
  the full projection for identity, collapse reporting, and rebuilds.
- I4: A collapse change emits the structural collapse operation, not a group
  reload, and that operation repaints all current rendered attributes.
- I5: Sidebar behavior does not otherwise change.

## Proof obligations

- PO1: A non-collapse rendered change emits a group reload. A collapse change,
  alone or with other rendered changes, emits the structural collapse operation
  and repaints the complete new rendered value.
- PO2: Successful reload and collapse operations advance the cache to the
  effective rendered value, including a title preserved by a live editor.
  Failed or suppressed paints retain the prior value and retry the required
  operation. A successful collapse during a live rename does not emit another
  collapse operation on the next diff.
- PO3: Selection-restore repaints and full rebuilds report every group render
  they apply, so the next diff does not repaint identical pixels.
- PO4: An off-screen group operation advances the cache and paints that value
  when the row mounts; it does not re-emit work on every pass.
- PO5: Render retention does not roll back child-tab structure, and a new group
  without a prior cache value starts from its new rendered value.
- PO6: A UI test drives the group-cell painter through collapsed and expanded
  rendered values and verifies the title, separator, caret, alert badge, and tab
  count outputs, including collapse-dependent badge visibility.
- PO7: Run the targeted DanTermCore reconciliation tests and lint during the
  implementation loop. Run `just test` before commit and `just test-ui` for the
  changed AppKit cell boundary.

## Non-goals

- Do not change sidebar row-operation ordering, rename policy, collapse
  behavior, or refused-operation repair.
- Do not generalize this into a wider projection framework. No sibling instance
  of the duplicated reload/retention enumeration exists in the current tree.
- Do not change the tab-row cache path; executor-reported rendered values are
  scoped to group rows.
- Do not add tests that assert private storage layout. Tests must assert reload,
  retry, structural retention, or rendered behavior.

## Implementation discretion

- Naming and declaration placement inside the existing sidebar projection
  section are left to implementation, provided the grouped value is the only
  rendered-state authority.

## Follow Up

- Update `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileFramePresenter.swift:135` to pass the required `searchReadout` argument so the mobile package and portability gates build again.
- Stabilize `tests-ui/PreferencesPanelTests.swift:65`; its native keybinding-table visibility assertion failed on both UI-suite runs while all sidebar UI cases passed.
