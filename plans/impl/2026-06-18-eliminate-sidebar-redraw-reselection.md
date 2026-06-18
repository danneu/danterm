# Eliminate the sidebar's per-sweep redraw + reselection

## Context

DanTerm coalesces high-frequency cosmetic messages (`surfaceTitle`, `surfaceCwd`,
`surfaceProgress`, `ghosttySearchTotal`, `ghosttySearchSelected`,
`splitRatioChanged`) into a reconcile sweep every 75 ms / ~13 Hz
(`AppRuntime.swift`, `reconcileCoalesceInterval = 0.075`). So whenever any pane
streams output, `reconcile()` -> `reconcileSidebar()` -> `sidebarView.applySidebarOps(...)`
runs ~13x/second.

`applySidebarOps` (`app/SidebarView.swift:240`) runs an **unconditional**
selection-restore + emphasis-refresh tail after applying its op list:

```swift
applyRestoreSelection(restoreSet, selectedTabId: model.selectedTabId)   // unconditional
refreshRowEmphasis(focusedTabId: model.selectedTabId)                   // unconditional
```

Two cost centers fire on every sweep even when nothing the sidebar cares about changed:

1. **`refreshRowEmphasis`** (`:441`) loops every visible row and assigns
   `forceEmphasizedSelection`, whose `didSet` (`:37`) marks the row
   `needsDisplay = true` on **every** assignment with no equality check. AppKit
   schedules the redraw purely off the dirty flag -- it does not skip identical
   pixels -- so each sweep forces a full sidebar redraw pass.
2. **`applyRestoreSelection`** (`:384`) rebuilds an `IndexSet` via O(rows)
   `row(forItem:)` lookups and calls `selectRowIndexes(...)` even when the result
   already equals `outlineView.selectedRowIndexes`. A same-value `selectRowIndexes`
   is not a cheap no-op (it does selection-processing work and can redraw rows).

**What actually churns the sidebar.** The `SidebarProjection` excludes progress,
search, and split ratio, so those sweeps produce an **empty** op list -- the whole
tail is pure waste. `surfaceTitle`/`surfaceCwd` *do* feed `tab.displayTitle` /
`subtitle` (`Model.swift:127-128`), so a busy unnamed tab produces a `reloadTab`
op -- but that op touches only the cell's text, never selection or emphasis, so the
tail is still waste on those sweeps too.

This scales with visible-row-count x sweep-rate and competes with input on the main
thread. **Outcome wanted:** a cosmetic sweep dirties no sidebar rows and issues no
reselection; emphasis still tracks a genuine focus change; the 2026-06-11
blank-tab-title field-editor safety is preserved exactly.

## Approach

Three coordinated edits, **all in `app/SidebarView.swift`**. No core / `Projections.swift`
changes (see rationale). The selection fix is approach **(b)** from the brief --
a correct-by-construction equality short-circuit, robust regardless of *why* the
sweep ran -- chosen over an external "ops changed OR selection changed" gate because
it reads live AppKit state and so cannot be fooled by selection drift from a
non-reconcile path.

**Why this stays an in-executor guard, not a new pure projection.** The decision
"is the live NSOutlineView selection already correct" is a comparison against live
view state an AppKit-free projection cannot see -- and it is the *full* view-owned
selection state: both `outlineView.selectedRowIndexes` (the set) and
`outlineView.selectedRow` (the lead/last-selected row, which the two-phase restore
pins to the focused tab for shift-click and keyboard range anchoring). The pure
*what* already exists and is unit-tested: `resolveReloadSelection`
(in `ModelOperations.swift`) decides the desired selection set and
`shouldForceSidebarRowEmphasis` (`ModelOperations.swift:54`) the desired emphasis.
Adding a projection here would duplicate selection state the view owns by design
(the reconciler ADR's `ReconcilerCaches` deliberately excludes sidebar selection).
So the new logic is a thin executor guard that **reads** view/model state and
**writes** only NSViews -- never `AppModel` -- honoring the Read-Only Model Rule.

### 1. Equality guard on `forceEmphasizedSelection.didSet` (`:37`)

Inherently safe; makes the emphasis assignment idempotent so a sweep that re-asserts
the same flag dirties zero rows, and a real focus change dirties only the two rows
that actually flipped.

```swift
var forceEmphasizedSelection = false {
    didSet { if forceEmphasizedSelection != oldValue { needsDisplay = true } }
}
```

### 2. Early-return no-op guard in `applyRestoreSelection` (`:384`)

Insert directly after the `focusRow` / `nonFocusRows` loop (current `:396`),
**before** the field-editor block. Leave the field-editor block (`:398-417`) and the
`selectRowIndexes` branches (`:419-437`) **unchanged**.

The guard must reproduce the *full* view-owned selection state the restore would
produce -- not just the selected index **set** but also the **lead** row. The
two-phase restore (`:419-428`) deliberately makes `focusRow` the last-selected row so
shift-click and keyboard range extension anchor on the focused tab (`:382` doc
comment; `outlineViewSelectionDidChange` at `:584` keys the model focus off
`selectedRow`). So a sweep can leave the set correct while the lead still points at a
non-focused tab -- e.g. focus moves (via a terminal click, cmd+number, or a CLI
`focus`) to a tab *already in* a multi-selection whose lead is a different selected
tab; that is an inline reconcile with empty ops (selection is not in the projection).
Skipping on set-equality alone would strand the wrong lead, so the guard also requires
`selectedRow == focusRow` whenever a focus row exists.

```swift
// Correct-by-construction no-op guard for the coalesced ~13Hz sweep, which re-runs
// this with an unchanged selection while a pane streams output. Bail before touching
// NSOutlineView only when the restore would be a complete no-op: the selected index
// SET already matches AND (when a focus row exists) the focused tab is already the
// lead/last-selected row the two-phase restore would make it. When restoreSet is empty
// the branches below leave the selection untouched, so the target IS the live set
// (focusRow nil, no lead to enforce) -- matching today's "no branch fires" behavior.
let live = outlineView.selectedRowIndexes
let targetSelection: IndexSet = restoreSet.isEmpty
    ? live
    : { var s = nonFocusRows; if let f = focusRow { s.insert(f) }; return s }()
let leadMatches = focusRow.map { outlineView.selectedRow == $0 } ?? true
if targetSelection == live && leadMatches { return }
```

**Rename safety holds.** The skip condition is a strict subset of
`targetSelection == live`, which is the negation of the field-editor block's
`willChangeSelection` (`:407`), so a skipped sweep is always one that block would have
treated as no-change -- it never drops a needed rename-end. Every sweep that does real
work (set differs, *or* only the lead is wrong) falls through to the unchanged
field-editor block + two-phase restore, so the 2026-06-11 protection is byte-for-byte
intact. And when it does skip, it additionally avoids the two-phase restore's transient
phase-1 deselect of `focusRow` -- strictly safer for a live editor than today.

Correctness of the cases the existing branches produce, all preserved:
- `restoreSet` empty -> target = live, focusRow nil (lead not enforced) -> skip ==
  today's "selection untouched".
- focus hidden in a collapsed group (focusRow nil, nonFocusRows empty, restoreSet
  non-empty) -> target = `{}`, no lead to enforce -> clears iff live is non-empty ==
  today's `selectRowIndexes(IndexSet(), ...)`, minus the redundant call when already empty.
- normal -> target = nonFocusRows U {focusRow}, lead must already be `focusRow` ==
  exactly the set *and* lead the two-phase branches install.

### 3. Gate `refreshRowEmphasis` at its call site in `applySidebarOps` (`:263`)

Emphasis is a pure function of (focused tab, set of rows). New/recycled rows already
get their flag from `outlineView(_:rowViewForItem:)` (`:571`, reads
`currentModel?.selectedTabId`, and `currentModel` is reassigned at `:244` *before*
the tail), so the periodic refresh is only needed when focus moved or rows changed.
`priorFocusedTabId` is already captured at `:243`.

```swift
applyRestoreSelection(restoreSet, selectedTabId: model.selectedTabId)
// Skip the all-rows emphasis loop on cosmetic churn sweeps. Scrolled-in rows are
// emphasized at vend time (rowViewForItem); only a focus move or a structural op
// changes an already-visible row's emphasis.
if !ops.isEmpty || priorFocusedTabId != model.selectedTabId {
    refreshRowEmphasis(focusedTabId: model.selectedTabId)
}
```

Edit #1 and edit #3 are complementary: #3 skips the loop on empty-op unchanged-focus
sweeps; #1 makes the loop redraw-free on the `reloadTab` sweeps where #3 still runs
(ops non-empty) and on focus-change sweeps (only the 2 flipped rows redraw).

## Out of scope / do not touch

- **`isReloading`** (`:241-242`, defer) -- approach (b) early-returns *inside* that
  window; the flag stays correctly scoped, suppressing the selection/collapse feedback
  loop. Unchanged.
- **The `scrollRowToVisible` gate** (`:267-271`) -- already gated on a real focus
  change; a separate block after the tail. Unchanged.
- **The field-editor block internals** (`:398-417`) and `selectRowIndexes` branches
  (`:419-437`) -- left byte-for-byte to minimize risk to the 2026-06-11 path. The new
  guard sits above them. Note for any future cleanup: do **not** assume
  `willChangeSelection` (`:407`) is always true past the guard -- it is not. A
  *lead-only* fall-through (`targetSelection == live` but `selectedRow != focusRow`)
  reaches the block with `intended == live`, so `willChangeSelection == false`,
  intentionally leaving the rename-end a no-op before the two-phase restore fixes the
  lead. Only *set-changing* fall-throughs make it true, so the recompute must stay.
- **`computeSidebarRowOps` / `desiredSidebar` / `ReconcilerCaches`** -- no projection
  or cache change; this is purely about *applying* an unchanged projection cheaply.

## Testing (TDD, write red first)

Per the module boundary, the AppKit executor is not reachable from the pure core test
target; it is covered by the `tests-ui/` harness (real `SidebarView`, needs a GUI
session; runs via `just test-ui`, registered in `PaneSplitViewTests.main()`).

**Pure layer (`lib/DanTermCore/Tests/`): no new tests.** The desired-state *what*
is already pinned: `resolveReloadSelectionTests` and the five
`shouldForceSidebarRowEmphasis*` tests (`ModelOperationsTests.swift:1745-1786`). This
change adds no pure logic -- the new guards compare against live `NSOutlineView`
state, which is inherently AppKit-coupled. State this explicitly rather than adding a
hollow test.

**test-ui layer (`tests-ui/`):**

1. **Headline, red-first -- "a cosmetic sidebar sweep marks no row for redraw"**
   (add to `SidebarSelectionCacheTests.swift`, reusing `makeSidebarSelectionHarness` /
   `sidebarOverflowModel` / `applyInitialSidebarModel` / `applySidebarTransition` /
   `materializeSidebarRows`). Build a multi-row model, materialize, then
   `displayIfNeeded` the outline to clear `needsDisplay`. Apply an **empty-ops,
   same-model** transition (the existing scroll test already shows this shape). Assert
   every visible `SidebarRowView.needsDisplay == false` and `selectedRowIndexes`
   unchanged. **Red today** (the unconditional tail dirties rows: `refreshRowEmphasis`
   re-asserts `forceEmphasizedSelection` -> `didSet`, plus the redundant
   `selectRowIndexes` reselect); **green after edits #2 and #3** -- on the empty-ops
   same-focus path edit #3 skips the emphasis loop and edit #2 skips the reselect. This
   path does *not* exercise edit #1 (the loop never runs, so its `didSet` guard never
   fires); test 2 covers that. The `needsDisplay == false` assertion is only meaningful
   against a clean post-`displayIfNeeded` baseline -- the red-today check is the
   safeguard, so if it is unexpectedly green today, re-ground the baseline before
   trusting it.

2. **Isolates edit #1, red-first -- "a `reloadTab` sweep with unchanged focus marks no
   row background for redraw"** (same file/harness). Build a multi-row model,
   materialize, `displayIfNeeded` to clear `needsDisplay`. Apply a transition that
   changes **one tab's `displayTitle`** with the selection unchanged -- a single
   `reloadTab` op, so edit #3's `!ops.isEmpty` term keeps `refreshRowEmphasis` running
   (this is the dominant busy-unnamed-tab churn case). Assert every visible
   `SidebarRowView.needsDisplay == false`. The reloaded tab's title redraw lands on its
   `NSTableCellView.textField` (a subview), not the `SidebarRowView`'s own
   background/selection layer that `forceEmphasizedSelection` dirties, so the row-view
   assertion isolates the emphasis-redraw path. **Red if edit #1 is reverted** -- the
   loop re-asserts every row's flag to its current value and the unguarded `didSet`
   dirties the whole sidebar; green with edit #1 (same-value assignment no longer
   dirties). This is the test that pins the headline "changing title -> no per-frame
   redraw" outcome; test 1's empty-ops path cannot, since edit #3 gates the loop out there.

3. **Existing-behavior guard, red against a set-only guard -- "an empty-op sweep
   restores the focused tab as the lead/last-selected row"** (add to
   `SidebarSelectionCacheTests.swift`). Build tabs `[t0..t5]`, selected = `t0`,
   materialize. Programmatically make the selected **set** `{t0, t5}` but the **lead**
   `t5`: `selectRowIndexes({t0}, false)` then `selectRowIndexes({t5}, true)` (this
   harness wires no runtime, so `selectionDidChange` is a no-op and the test model keeps
   `selectedTabId == t0`). Apply an **empty-ops same-model** transition; assert
   `outline.selectedRow == row(t0)` and the set is still `{t0, t5}`. Pins the
   focused-row-lead contract the two-phase restore (`:419-428`) owns: passes on current
   `master` and after the lead-aware guard, but **fails against a set-only
   `if targetSelection == live` guard** (which skips and strands `t5` as lead). The
   existing "focus change ... within a multi-selection" test
   (`SidebarSelectionCacheTests.swift:117`) cannot cover this axis -- there the newly
   focused row (29) was already extended-selected last, so its lead already coincides
   with the new focus.

4. **Correctness -- "a focus change re-emphasizes the new row and de-emphasizes the
   old"** (same file). selected = A, materialize, assert row A's `SidebarRowView`
   `isEmphasized`/`forceEmphasizedSelection` true; transition to selected = B (no
   structural ops, focus moved), assert B now emphasized and A not. Guards that edit
   #3's focus-change term still fires (a gate that dropped it would leave emphasis
   stale -> red).

5. **Rename safety, spec-first invariant -- "a cosmetic sweep with unchanged
   selection leaves a live inline rename intact"** (add to
   `SidebarRenameRecycleTests.swift`, reusing `makeRenameRecycleHarness` /
   `beginRenamingTab` / `applyRenameRecycleTransition`). Begin a rename, apply an
   empty-ops same-selection transition, assert `textField.currentEditor() != nil` and
   `runtime.viewLocalState.sidebarRenameTarget` still set. Verify whether it is
   red-first: if the current redundant same-selection `selectRowIndexes` already
   aborts the editor, this is a real regression catch for approach (b); if it already
   passes, it stands as an invariant pin against future regressions to the guard.

6. **Regression must stay green (no new test).** The existing
   `SidebarRenameRecycleTests` "Cmd-T while a rename is live ends the edit instead of
   stranding it" exercises the selection-**changing** path: Cmd-T moves selection, so
   `targetSelection != live`, the guard does **not** early-return, and the field-editor
   end path runs exactly as before. Confirm it stays green -- it is the proof that
   approach (b) preserves the 2026-06-11 fix.

## Verification

1. `just test` -- unchanged pass; pure suite count unchanged (no core edits).
2. `just test-ui` -- new tests 1-5 green, existing sidebar suites (selection-cache,
   scroll-reveal, rename-recycle, badges) green.
3. `just build-run`, then manual:
   - Busy unnamed pane streaming a **progress meter + changing title** beside a static
     multi-tab sidebar: no flicker, no per-frame redraw, visibly lower CPU.
   - cmd+arrow / click between tabs: the focused row's blue accent tracks focus
     instantly (emphasis still correct).
   - Shift-click two tabs (lead = the second), then focus the *first* of the pair via a
     non-sidebar path (terminal click / cmd+number): a follow-up shift-click should
     extend the range from the now-focused first tab, confirming the lead row followed
     focus and the guard did not strand it.
   - Start an inline tab rename, let another pane churn output: the field editor stays
     live and editable; Cmd-T mid-rename still ends the edit cleanly (no blank title).
   - Scroll an overflowing sidebar so the focused tab is off-screen while a pane
     churns: the sidebar does **not** snap back (scroll gate intact).

## Implementation notes

- The reloadTab UI test allows the row whose title changed to be dirty, because
  AppKit marks that row view during the in-place cell text update. The regression
  assertion is that unchanged rows remain clean; reverting the emphasis didSet guard
  still dirties the rest of the sidebar and fails the test.
