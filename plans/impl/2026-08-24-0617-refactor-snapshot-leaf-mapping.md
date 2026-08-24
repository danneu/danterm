# Refactor snapshot leaf mapping

## Problem

`graftScrollback` rebuilds every app, group, and tab snapshot by listing its
fields. A new defaulted field can therefore keep the code compiling while the
graft silently drops that field. `TabSnapshot.todos` demonstrates the risk.

LOOKUP-2 made snapshot identities typed, but the production traversal still
owns scrollback-specific recursion and the snapshot test helper still converts
pane identities back to strings. Both preserve parts of the old boundary.

## Decision

Give the snapshot model one pane-leaf mapping traversal. The traversal
copies each complete container value and replaces only the child path that leads
to pane leaves. `graftScrollback` becomes a transform over that traversal and
uses `PaneId` values directly.

Only the child-bearing snapshot fields become mutable. Unrelated snapshot
fields stay immutable. Split-node recursion remains exhaustive so a future
change to a split case produces a compile error instead of a silent omission.

Replace the string-taking pane snapshot test helper with a `PaneId`-taking
helper; do not retain a string overload. Every caller uses typed pane identities
directly. Comments on the graft and checkpoint tests must describe its use by
export and both checkpoint tiers.

## Invariants

- **I1:** Mapping pane leaves preserves every app, group, tab, split, and pane
  field except values explicitly changed by the leaf transform.
- **I2:** Scrollback grafting changes only leaves whose typed pane identity has
  an entry in the scrollback map.
- **I3:** An unmatched or id-less leaf keeps its existing scrollback, and a
  stale map entry cannot create a pane.
- **I4:** Snapshot and test traversal paths do not format or parse UUID strings
  to match pane identities.
- **I5:** The refactor does not change snapshot JSON, file version, restore
  policy, checkpoint scheduling, or export behavior.

## Proof obligations

This is a behavior-preserving refactor. These obligations are regression fences
that are green before and after the change, not new TDD reds; PO1's populated
fixture makes the current preservation contract explicit.

- **PO1 (I1, I5):** An empty graft is identity for a fully populated snapshot,
  including tab and pane todos, typed identities, recovery fields, theme, font
  size, grid override, selection, focus, color, and collapse state.
- **PO2 (I1-I3):** In a split tree, a typed scrollback entry changes only its
  matching pane. The changed pane equals its original value apart from
  scrollback, while unmatched, id-less, and stale identities have no effect.
- **PO3 (I5):** A light capture with no reads encodes the same payload as its
  captured light projection.
- **PO4:** The focused DanTermCore graft and capture tests, the complete
  DanTermCore suite, `just lint`, and the final `just test` gate pass.

## Non-goals

- Redesigning persistence membership under LOOKUP-1.
- Changing how WIRE-5 produces or truncates scrollback text.
- Adding a migration, compatibility shim, or new snapshot version.

## Rejected ideas

- **RI1:** Store scrollback in a top-level pane-id map instead of leaf snapshots
  -- this would reintroduce parallel pane ownership that the tree-owns-panes
  design removed to prevent dual-source drift.

## Implementation discretion

- The exact internal method names and whether split recursion is a private
  member or a file-private function are left to implementation.
- Test fixture construction and test-file placement are left to implementation
  as long as the proof obligations remain behavioral and structure-insensitive.
