# Tidy two redundant lookups in the projection loops (consistency, not perf)

## Context

Two of DanTerm's pure projections (`Projections.swift`) detour through an
id-based lookup for a value the enumerating loop already holds, then re-derive
it from the raw model. This batch removes those two detours.

**These are cleanups, justified by consistency and single-source-of-truth --
not performance.** The reconciler runs at most ~13 Hz (the 75ms coalesced sweep
-- `AppRuntime.swift:75`, `Msg.swift:224-232`), and the structures involved hold
single-digit pane/tab counts, so the work removed is unmeasurable. There is no
profile motivating this, and none is claimed. The reconciliation ADR
(`docs/design/2026-05-27-model-driven-view-reconciliation.md`, "Projection Scan
Cost") explicitly forbids speculative perf refactors here (a shared `allPanes`,
fine-grained reactivity, a top-level model-equality short-circuit); this batch
introduces **no new abstraction, cache, or precompute** -- it only deletes two
redundant indirections so each loop reads its fields one consistent way.

Both changes are **behavior-preserving by construction** -- the value read off
the loop variable is *defined* to equal what the id-based helper re-derives, and
both equalities are already pinned by existing tests. No new test is required.

The two items are independent and individually shippable. They use the brief's
original canonical item numbers (1 = pane toolbar; 3 = focus borders); the
brief's item 2 (sidebar tally threading) and item 4 (group-collapse writer) are
**out of scope** -- see the closing section for why.

**Recommended landing order: item 1, then item 3** -- two trivial pure cleanups,
either order is fine.

---

## Item 1 -- `desiredPaneToolbar`: read the `PaneModel` already in hand

`Projections.swift`. `desiredPaneToolbar(in:tally:)` walks `model.allPanes`, so
it already holds each `PaneModel` -- and reads `pane.title`/`pane.cwd`/`pane.progress`
etc. directly for 7 of the 9 toolbar fields. But for title+cwd it routes through
the id-based `paneToolbarText(for: pane.id, in: model)`, whose `model.pane(id)`
(`Model.swift:220`) re-walks the groups->tabs->leaves tree to re-find the pane it
was just handed. Title/cwd are the lone two fields detouring through a lookup
while the other seven read straight off `pane`.

**Fix:** read `pane.title`/`pane.cwd` straight off the enumerated `PaneModel` in
the loop, like the other seven fields. This is a consistency cleanup -- it makes
the loop read every field one way and deletes an indirection that re-finds a
value already in scope. Do **not** add a `PaneModel` overload for this -- it would
wrap zero logic behind a single call site. (Unifying rule for this batch: *share
logic, don't wrap nothing* -- contrast item 3, where the lone-leaf predicate **is**
shared logic and so earns an overload rather than an inlined copy.)

Change the loop body in `desiredPaneToolbar(in:tally:)` (`Projections.swift:234-238`):

```swift
// before
let (title, cwd) = paneToolbarText(for: pane.id, in: model)
result[pane.id] = PaneToolbarRender(
  title: title,
  cwd: cwd,
  // ...remaining 7 fields already read straight off `pane`...
)
// after -- read straight off the enumerated pane, like the other seven fields.
// The id-based lookup re-found the pane in the model tree; the pane in hand is
// the same value for a known pane, so this drops a redundant indirection.
result[pane.id] = PaneToolbarRender(
  title: pane.title,
  cwd: pane.cwd,
  // ...remaining fields unchanged...
)
```

**Delete** the id-based `paneToolbarText(for:in:)` (`Projections.swift:74`) once
this is its last production caller. After the switch its only remaining callers
are its own four direct unit tests -- it has **no** cold/production callers (grep
`paneToolbarText` across `app/` and `lib/`: the sole non-test, non-definition
reference is the `Projections.swift:235` line this item removes). Keeping it would
leave an orphaned helper whose unknown-pane `"Terminal"` fallback is dead code (the
hot loop only ever enumerates known panes), preserved solely by a test of a path
no runtime code reaches. So remove it together with its four helper tests:

- Delete `paneToolbarText(for:in:)` from `Projections.swift`.
- Delete the four `paneToolbarText*` `@Test`s in `PaneToolbarTests.swift`
  (`:13`/`:30`/`:47`/`:59`) -- including the `...DefaultTitleForUnknownPane`
  test, which pinned exactly the now-dead fallback. **Keep** the five
  `formatToolbarLabel*` tests in that same file (`:76`-`:119`) -- they exercise a
  different helper and are untouched.
- Trim the `paneToolbarText` clause from the file's top-of-file `//` preamble
  (`PaneToolbarTests.swift:1-6`) so it describes only `formatToolbarLabel`.

Do **not** expand to the sibling `desiredPaneConfig` loop -- it has no equivalent
redundant lookup.

**Behavior preservation:** the loop variable `pane` is exactly the `PaneModel`
that `model.pane(pane.id)` returns (both come from the same `model.allPanes`
walk), so `(pane.title, pane.cwd)` is identical to the non-fallback branch of
the id-based helper. The `"Terminal"` fallback is unreachable here -- the pane
was just enumerated from the tree.

**Guarded by (existing):** `desiredPaneToolbarDerivesAllFields`
(`ModelOperationsTests.swift:2997`) asserts every field of the projection --
including `title == "vim"` and `cwd == "/work/proj"` -- so it carries the title/cwd
behavioral coverage that the deleted `paneToolbarText*` helper tests held;
`desiredPaneToolbarKeyedOverEveryLivePane` (`:3043`) pins the key set. Projection
output is byte-for-byte unchanged, so both stay green. No new test required -- this
item only *removes* the four now-orphaned helper tests (above), it adds none.

---

## Item 3 -- `desiredFocusBorders`: one predicate body for the focus rule

`Projections.swift`. `desiredFocusBorders(in:tally:)` calls
`isFocusedAndVisible(pane.id, in: model)` per pane (`:199`), and that helper
re-resolves `selectedTab(in: model)` (`ModelOperations.swift:451`) on every
iteration, though the selected tab is loop-invariant and only its `focusedPaneId`
can ever be focused.

**Fix:** add a `TabModel?` overload of `isFocusedAndVisible` that holds the
predicate (so the focus rule has exactly one definition), resolve
`selectedTab(in: model)` once before the loop, and pass the resolved tab to the
overload per pane. The value here is **single-source-of-truth, not speed**: after
the change the `desiredFocusBorders` loop, the `in model:` convenience form, and
`testIsFocusedAndVisible` all funnel through one predicate body, so the lone-leaf
suppression rule can't drift between copies. (The per-pane `selectedTab` scan it
also removes is incidental and marginal -- per-`Msg`, not per-frame, N tiny.)
This is item 1's contrast: the predicate is real shared logic, so it earns an
overload; item 1's title/cwd is not, so it inlines.

Add a `TabModel?` overload beside `isFocusedAndVisible` (`Projections.swift:165`)
and make the existing `in model:` form forward to it:

```swift
/// Whether `paneId` draws the green focus border, given an already-resolved tab.
/// Single source of truth for the rule (the focused pane of the selected,
/// non-lone-leaf tab). The `in model:` form and `desiredFocusBorders`' hot loop
/// both funnel through this, so the lone-leaf suppression is defined in one place.
func isFocusedAndVisible(_ paneId: PaneId, in tab: TabModel?) -> Bool {
  guard let tab, tab.focusedPaneId == paneId else { return false }
  if case .leaf = tab.rootNode { return false }
  return true
}

/// Convenience form for callers/tests that have not pre-resolved the selected
/// tab. Resolves `selectedTab(in:)` and forwards to the `TabModel?` predicate
/// above -- the hot `desiredFocusBorders` loop pre-resolves once and skips this.
func isFocusedAndVisible(_ paneId: PaneId, in model: AppModel) -> Bool {
  isFocusedAndVisible(paneId, in: selectedTab(in: model))
}
```

(This preserves the doc the existing `in model:` overload already carries
(`Projections.swift:164`); both top-level overloads stay documented, per the
declaration-comment rule in `AGENTS.md`.)

(The two overloads resolve unambiguously: same `in` label, distinct parameter
types -- a `TabModel?` picks the predicate, an `AppModel` picks the forward.
Neither type is convertible to the other.)

Rewrite the loop in `desiredFocusBorders(in:tally:)` (`Projections.swift:195`):

```swift
func desiredFocusBorders(in model: AppModel, tally: UnreadAlertTally) -> [PaneId: BorderState] {
  // Resolve the selected tab once -- it is loop-invariant. Pass the resolved tab
  // to the `TabModel?` overload so the lone-leaf rule stays in one place; `bell`
  // is independent, so a lone-leaf tab can still show the red unread-alert border.
  let selected = selectedTab(in: model)
  var result: [PaneId: BorderState] = [:]
  for pane in model.allPanes {
    result[pane.id] = BorderState(
      focused: isFocusedAndVisible(pane.id, in: selected),
      bell: (tally.byPane[pane.id] ?? 0) > 0
    )
  }
  return result
}
```

**Critical:** the lone-leaf suppression (`if case .leaf = tab.rootNode { return
false }`) now lives in exactly one body -- the `TabModel?` overload -- which both
the hot loop and `testIsFocusedAndVisible` (via the `in model:` forward) exercise.
A single definition is what removes the regression surface, and it avoids the
orphaned-copy risk an inline rewrite would have created (the loop is
`isFocusedAndVisible`'s only production caller today, so inlining would leave the
kept function test-only).

**Behavior preservation:** the `TabModel?` overload is the prior
`isFocusedAndVisible(pane.id, in: model)` body with `selectedTab(in: model)`
lifted to its caller -- true iff the selected tab exists, its root is not a
`.leaf`, and its `focusedPaneId == pane.id`. The loop resolves `selected` once
and passes it per pane: identical result, `bell` untouched.
`testIsFocusedAndVisible` calls the `in model:` form, which now forwards to the
overload, so it still guards the live predicate, not an orphan.

**Guarded by (existing):** `desiredFocusBordersSinglePaneNoBorderBellOk`
(`:2916`, the lone-leaf branch), `desiredFocusBordersSplitTabFocusBellPerPane`
(`:2940`), `desiredFocusBordersKeyedOverAllLivePanes` (`:2972`), plus
`testIsFocusedAndVisible` (`:608`), which now exercises the `TabModel?` predicate
through the `in model:` forward. Output unchanged; all stay green. No new test
required.

---

## TDD / workflow note

Both items are pure-core refactors-under-test, not new behavior: their output is
unchanged, so the "failing test first" loop is degenerate. Run the cited suites
green *before* each edit to establish the baseline, make the change, confirm
still green.

## Layering

Both items are pure core (`Projections.swift`) -- no AppKit, no ambient inputs,
so `core-purity-lint` stays green. Respects the pure-core / runtime split
(`docs/design/2026-05-28-pure-core-support-split.md`).

---

## Tests / verification

Run from repo root.

1. **Core unit suites:** `swift test --package-path lib/DanTermCore`
   (targeted: `--filter ModelOperationsTests`, `--filter PaneToolbarTests`).
   Expect all green with no changes -- the projections' output is unchanged.

2. **Full local gate:** `just test`. Must pass before done.

3. **Manual spot-check (optional):** `just build-run` (dev bundle
   `com.danneu.danterm-dev`). Open several tabs/panes and confirm the pane
   toolbar title/cwd and the focus borders are unchanged.

---

## Out of scope

**Brief item 2 -- thread the `UnreadAlertTally` into the sidebar cells -- DROPPED.**
The original brief framed this as "the real win": `reconcileSidebar` already holds
the per-pass tally but the cells (`configureTabCell`, `configureGroupCell`)
re-derive the per-tab/per-group count via `unreadAlertCount` /
`groupUnreadAlertCount` (`ModelOperations.swift:698-705`). Cut because:

- The benefit is unmeasurable -- those helpers walk a single-digit pane tree and
  filter a single-digit alerts array, only on granular row reloads. No profile
  shows the sidebar reconcile is hot, and the ADR cautions against precomputing
  further shared reconcile inputs absent one.
- It does **not** reduce duplication -- it *adds* a path. The plan kept the
  helpers (cold callers, tests, `applyGroupCollapseState` still use them) and
  added an `if let tally { byTab[id] } else { recompute }` branch in two cell
  configurers, plus an optional `tally:` param threaded through ~5 executor hops.
  After the change there are more ways to compute the badge count, not fewer --
  the opposite of a clarity win, and a violation of this batch's "share logic,
  don't wrap nothing" rule.
- Its one genuinely-new test (a sentinel-tally wiring assertion) needs a
  WindowServer, so it is **not in the `just test`/CI gate** -- a forwarding-hop
  regression would be caught only when someone manually runs `just test-ui`. That
  is a permanent dual-path complexity tax whose correctness the default gate does
  not protect.

Reconsider only if (a) a profile shows sidebar reconcile is genuinely hot, or
(b) it is done together with the deferred item 4, so the writer collapses to a
single tally-reading path instead of gaining a guarded second one.

**Brief item 4 -- consolidate the group-collapse cell writer -- DEFERRED (with
the user).** Folding `applyGroupCollapseState` (`SidebarView.swift:632`) into
`configureGroupCell` and expressing the bell as one predicate
(`bellBadge.isHidden = !(group.isCollapsed && count > 0)`) is real dead-code
tidy, but it touches the zero-coverage live collapse/expand interaction (the
`outlineViewItemDidCollapse`/`DidExpand` delegates capture a stale `GroupModel`
from `sidebarItem.kind`, so the consolidated path must re-fetch the fresh group
after `send`) and therefore **requires a new `tests-ui` assertion**. Take it as a
follow-up with that test. It does not block items 1/3.

**Design-doc-rejected optimizations -- do NOT introduce** (per
`docs/design/2026-05-27-model-driven-view-reconciliation.md`, "Projection Scan
Cost"): a shared/precomputed `allPanes` reconcile input; Solid-style fine-grained
reactivity; a top-level model-equality short-circuit; any speculative shared-input
precompute. These are all premature absent a profile.
