# Plan: compute the unread-alert tally once per reconcile

## Context

`reconcile()` (app/Reconcile.swift:83) runs both inline on structural messages
and on a coalesced ~75 ms sweep (~13 Hz) whenever any pane streams output. Every
run rescans `model.alerts` repeatedly: once per pane (twice, really) and again
per tab and per group. With many tabs/panes open and busy, that rescan is the
dominant repeating main-thread cost and competes with input responsiveness. A
high-pane/high-tab latency report is what prompted this.

`model.alerts` is hard-capped at 100 (Update.swift:746,777); panes and tabs are
uncapped. So the cost is O(panes x alerts + tabs x alerts) per reconcile, with a
`Set(allPaneIds(...))` allocated per tab (twice, via the sidebar's per-tab and
per-group rollups).

This is the fix the reconciler ADR pre-authorized. From
`docs/design/2026-05-27-model-driven-view-reconciliation.md` ("Projection Scan
Cost"): *"the measured fix is to compute that input once in `reconcile()` and
thread it through all alert consumers: `paneHasUnreadAlert`, the inline toolbar
count in `desiredPaneToolbar`, `unreadAlertCount`, `groupUnreadAlertCount`, and
`totalUnreadAlertCount`."* This plan follows that blessed shape.

**Intended outcome:** identical unread counts everywhere (no behavior change),
with each reconcile dropping from O(panes x alerts + tabs x alerts) to
O(alerts + panes + tabs) and shedding the per-tab `Set` allocations.

## Scope

- **IN:** one unread-alert tally computed at the top of `reconcile()`, threaded
  through the five alert-consuming projections.
- **OUT (do not fold in):** the repeated `model.allPanes` rebuild
  (Model.swift:228) -- the ADR says don't precompute it; and the separate "bell /
  commandStarted reconcile inline instead of coalescing" findings.

## Decisions (resolved)

1. **Threading = delegating overload.** Each of the five projections keeps its
   current no-arg `(in model:)` form as a thin wrapper that computes the tally
   and delegates to a new `(in model:, tally:)` form. `reconcile()` calls the
   `tally:` form once. Rationale: the projections have no production callers
   except the reconcile executors, so the only thing the no-arg form serves is
   tests + any cold caller; its worst case is recomputing the tally at exactly
   today's baseline cost (never a regression). This keeps the diff surgical, the
   single tally builder authoritative, and existing projection tests unchanged.
   Rejected: a required `tally:` param (forces mechanical test migration for no
   real safety gain) and a precomputed-context struct (couples the whole
   projection cluster to a shared bag for one value; least faithful to the ADR's
   "thread it through all alert consumers").
2. **`SidebarView.swift` direct callers = deferred.** The four helpers are also
   called by `SidebarView` cell/menu config (626/944/1179/1290) reading
   `currentModel?.alerts`. These fire only when a row's content changes (a
   `reloadTab`/`reloadGroup` op) or on menu summon / collapse toggle -- human-
   paced, one row at a time, NOT on the 13 Hz output sweep. Keeping the four
   helpers leaves these callers and their tests correct with zero change. (The
   sidebar's existing double-compute -- counts in `desiredSidebar` for the diff
   AND again in cell config for display -- is a possible later cleanup, out of
   scope here.)
3. **Keep the four helpers; build the tally independently.** `paneHasUnreadAlert`,
   `unreadAlertCount`, `groupUnreadAlertCount`, `totalUnreadAlertCount` stay
   (they have direct unit tests and the deferred SidebarView callers). The tally
   is a NEW single-pass computation -- it does NOT call the helpers (that would
   re-incur the per-tab cost). The helpers become the tally's equivalence oracle
   in tests.

## The tally type + builder

New code beside the four helpers in
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` (after line 710),
under a new `// MARK: - Unread Alert Tally` with a comment cross-referencing the
helpers it must match. Pure: reads only `model.alerts` and the split trees; no
AppKit/GhosttyKit, no ambient input (passes `scripts/core-purity-lint.sh` with no
seam markers).

```swift
/// Precomputed unread-alert counts for one AppModel snapshot: per-pane, rolled
/// up per-tab and per-group, plus the grand total. Built once at the top of
/// reconcile() and threaded into the alert consumers so each is a dictionary
/// lookup, not an alerts rescan. MUST stay numerically identical to the four
/// helpers above. `total` counts ALL unread alerts -- including a stale-pane
/// alert whose `paneId` matches no live pane -- matching totalUnreadAlertCount;
/// byTab/byGroup count only alerts whose pane lives in that tab's tree, matching
/// unreadAlertCount.
struct UnreadAlertTally: Equatable {
    var byPane: [PaneId: Int]
    var byTab: [TabId: Int]
    var byGroup: [GroupId: Int]
    var total: Int
}

/// O(alerts + panes + tabs): one pass buckets unread alerts by pane (and counts
/// the total), then one tree walk rolls the per-pane counts up to tabs/groups.
func unreadAlertTally(for model: AppModel) -> UnreadAlertTally {
    var byPane: [PaneId: Int] = [:]
    var total = 0
    for alert in model.alerts where alert.isUnread {
        byPane[alert.paneId, default: 0] += 1
        total += 1
    }
    var byTab: [TabId: Int] = [:]
    var byGroup: [GroupId: Int] = [:]
    for group in model.groups {
        var groupCount = 0
        for tab in group.tabs {
            let tabCount = sumUnread(in: tab.rootNode, byPane: byPane)
            byTab[tab.id] = tabCount
            groupCount += tabCount
        }
        byGroup[group.id] = groupCount
    }
    return UnreadAlertTally(byPane: byPane, byTab: byTab, byGroup: byGroup, total: total)
}

/// Sum the per-pane unread counts of every leaf in a split tree. Allocation-free
/// (unlike Set(allPaneIds(...))), which is the point on the reconcile hot path.
private func sumUnread(in node: SplitNodeModel, byPane: [PaneId: Int]) -> Int {
    switch node {
    case .leaf(let pane):
        return byPane[pane.id] ?? 0
    case .split(_, _, let first, let second, _):
        return sumUnread(in: first, byPane: byPane) + sumUnread(in: second, byPane: byPane)
    }
}
```

**Correctness subtlety (the #1 thing to get right):** `total` is computed
independently as the count of all unread alerts, NOT as a sum of the per-pane
buckets restricted to live panes. Note this is NOT about closed panes: normal
close paths prune a pane's alerts -- `closePane`/`closeTab` ->
`clearPaneSideTables` -> `removeAlertsForPane` (ModelOperations.swift:31,42),
pinned by `testClosePaneRemovesAlertsAndCleansUpThrottle`
(UpdateAlertTests.swift:334) -- so a closed pane leaves no dangling alert. The
real divergence source is **stale-pane alerts**: the model still permits an
unread alert whose `paneId` matches no live pane, which `.activateAlert` handles
via its "pane no longer exists" guard (Update.swift:858-866) and
`testActivateStaleAlertMarksReadButNoNavigation` pins (UpdateAlertTests.swift:204).
On such a model the two helper families genuinely diverge:
`totalUnreadAlertCount` counts the stale alert; `unreadAlertCount` /
`groupUnreadAlertCount` (tree-restricted) do not. The builder must preserve both:
`total += 1` over every unread alert (stale included), while `byTab`/`byGroup`
only sum panes reachable from a tab's `rootNode` (stale excluded). `byPane` holds
the stale `paneId` key too, but per-pane consumers only ever look up panes in
`model.allPanes`, so it is never surfaced there -- matching today.

## Signatures / call sites to change

### Projections (lib/DanTermCore/Sources/DanTermCore/Projections.swift)

For each of the five, keep the existing `(in model:)` signature as a one-line
delegating wrapper (with a short doc note: "recomputes the tally; hot-path
callers must pass the precomputed one"), and add a `(in model:, tally:)` form
that does the real work. The body edits:

| Projection | Current alert call (line) | New |
| --- | --- | --- |
| `desiredFocusBorders` | `paneHasUnreadAlert(pane.id, alerts: model.alerts)` (197) | `(tally.byPane[pane.id] ?? 0) > 0` |
| `desiredPaneToolbar` | `model.alerts.count { $0.paneId == pane.id && $0.isUnread }` (234) | `tally.byPane[pane.id] ?? 0` |
| `desiredSidebar` (group) | `groupUnreadAlertCount(for: group, alerts: model.alerts)` (398) | `tally.byGroup[group.id] ?? 0` |
| `desiredSidebar` (tab) | `unreadAlertCount(for: tab, alerts: model.alerts)` (406) | `tally.byTab[tab.id] ?? 0` |
| `desiredWindowChrome` | `totalUnreadAlertCount(model: model)` (339) | `tally.total` |
| `desiredSwitcher` | `unreadAlertCount(for: tab, alerts: model.alerts)` (777) | `tally.byTab[tabId] ?? 0` |

Example (sidebar):

```swift
/// Convenience: recomputes the tally. For tests / cold callers. The hot path
/// (reconcileSidebar) must call the tally form.
func desiredSidebar(in model: AppModel) -> SidebarProjection {
    desiredSidebar(in: model, tally: unreadAlertTally(for: model))
}

func desiredSidebar(in model: AppModel, tally: UnreadAlertTally) -> SidebarProjection {
    // ... unchanged except:
    //   unreadAlertCount: tally.byGroup[group.id] ?? 0   (group)
    //   unreadAlertCount: tally.byTab[tab.id] ?? 0        (tab)
}
```

`byTab`/`byGroup` always have a key for every tab/group in `model.groups` (pass 2
writes them all, even zero), so the `?? 0` is purely defensive there; `byPane`
defaults to 0 for panes with no unread alerts.

**Rewrite the now-false comments in this file** as part of these body edits --
three blocks currently assert the alert scans "intentionally stay local":

- `// MARK: - View Reconciler` header (Projections.swift:156-165): keep the part
  that says focus-borders / toolbar / pane-config still walk `model.allPanes`
  each sweep (true -- out of scope), but replace the "alert-derived renders
  rescan `model.alerts` per pane, which is O(panes x alerts)" claim with the new
  reality: alert counts now come from an `UnreadAlertTally` computed once in
  `reconcile()` and threaded in (the ADR's authorized fix); only the no-arg
  wrapper recomputes locally, for tests/cold callers.
- Window Chrome note (301-303): "Unread-alert scans intentionally stay local..."
  -> window chrome now reads `tally.total`.
- Sidebar note (346-348): "per-tab and per-group alert scans intentionally stay
  local..." -> sidebar rows now read `tally.byTab` / `tally.byGroup`.

### Reconcile executors (app/Reconcile.swift)

Compute the tally once at the top of `reconcile()` and thread it into the five
executors that call the alert projections. The other passes are untouched.

```swift
func reconcile() {
    reconcileSurfaceExistence()
    reconcilePaneConfig()
    let mountFocusTab = reconcileContainers()
    let alertTally = unreadAlertTally(for: model)   // computed once
    reconcileFocusBorders(tally: alertTally)
    reconcilePaneChrome(tally: alertTally)
    applyMountTimeFocus(mountFocusTab)
    reconcileSidebar(tally: alertTally)
    reconcileWindowChrome(tally: alertTally)
    reconcileSwitcher(tally: alertTally)
    // ... rest unchanged
}
```

Executor signature changes (each gains `tally: UnreadAlertTally` and forwards it
to its `desired*` call; `reconcilePaneChrome` forwards it only to
`desiredPaneToolbar`, leaving `desiredSearchOverlays` as-is):

- `reconcileFocusBorders(tally:)` -> `desiredFocusBorders(in: model, tally:)` (186)
- `reconcilePaneChrome(tally:)` -> `desiredPaneToolbar(in: model, tally:)` (219)
- `reconcileSidebar(tally:)` -> `desiredSidebar(in: model, tally:)` (255)
- `reconcileWindowChrome(tally:)` -> `desiredWindowChrome(in: model, tally:)` (287)
- `reconcileSwitcher(tally:)` -> `desiredSwitcher(in: model, tally:)` (309)

`unreadAlertTally(for:)` lives in the DanTermCore module and is reachable
same-module from app/ via the `app/DanTermCore` symlink -- no import needed.

### Not changed

- The four helpers in ModelOperations.swift (651-710) -- retained for the
  SidebarView callers and their tests.
- `SidebarView.swift` (626/944/1179/1290) -- deferred (decision 2).
- `model.allPanes` (Model.swift:228) -- out of scope; the projections still
  iterate it (O(panes), unchanged). The tally adds its own independent O(panes)
  tree walk; it does not touch `allPanes`.

## Test plan

The pure layer is the test boundary. New tests live in
`lib/DanTermCore/Tests/DanTermCoreTests/`.

**New `UnreadAlertTallyTests.swift` -- equivalence + edges (the core proof):**

- **Equivalence to the helpers** (spec-first). Build a representative model:
  2 groups, several tabs, multi-pane split trees, a mix of read and unread
  alerts. Assert, for that model:
  - every pane: `(tally.byPane[p] ?? 0) > 0 == paneHasUnreadAlert(p, alerts:)`
    and `tally.byPane[p] ?? 0 == model.alerts.count { $0.isUnread && $0.paneId == p }`
  - every tab: `tally.byTab[t] == unreadAlertCount(for: tab, alerts:)`
  - every group: `tally.byGroup[g] == groupUnreadAlertCount(for: group, alerts:)`
  - `tally.total == totalUnreadAlertCount(model:)`
  This pins the new single-pass computation to the retained, tested helpers.
- **Stale-pane alert** (regression guard for the subtlety above): a model with an
  unread alert whose `paneId` matches no live pane -- the stale-pane shape from
  `.activateAlert` / `testActivateStaleAlertMarksReadButNoNavigation`. Assert
  `tally.total` counts it (== `totalUnreadAlertCount`) while no `byTab`/`byGroup`
  entry includes it (== the tree-restricted helpers). Proves `total` is computed
  independently of the tree rollups. This is the one model shape where the helper
  families diverge (normal close paths prune a pane's alerts), so it is the case
  worth pinning.
- **Edges:** empty alerts -> all zero; read-only alerts excluded from every
  bucket; multiple unread alerts on one pane sum; a tab/group with zero alerts
  has a key valued 0.

**Wiring tests (each projection reads the tally, not a recompute):** pass a
synthetic tally with sentinel counts to each `tally:` form and assert the
projection surfaces it, e.g.
`desiredWindowChrome(in: model, tally: UnreadAlertTally(byPane: [:], byTab: [:], byGroup: [:], total: 99)).unreadCount == 99`,
and analogous one-liners for focus-border `bell`, toolbar `unreadAlertCount`,
sidebar tab/group counts, and switcher `alertCount`. These guard against a body
that ignores the tally and rescans. Place alongside the existing projection
tests (ReconcileTests.swift / ModelOperationsTests.swift).

**Unchanged, must still pass (regression):**

- Helper unit tests: `testUnreadAlertCount` (ModelOperationsTests.swift:1004),
  `testGroupUnreadAlertCount` (1040) -- helpers are untouched.
- Projection tests that call the no-arg forms, e.g.
  `desiredSidebarOrderedGroupsTabsAttrsCollapseJump` (3151): they resolve to the
  delegating wrapper, so they now exercise the tally path end-to-end with no edit.

No existing test needs migration (that is the payoff of the overload choice).

## Performance argument

Per reconcile, **before**:

- `desiredFocusBorders`: `paneHasUnreadAlert` scans alerts per pane -> O(panes x alerts)
- `desiredPaneToolbar`: inline `alerts.count {}` per pane -> O(panes x alerts)
- `desiredSidebar`: per group `groupUnreadAlertCount` (reduces over its tabs,
  each `Set(allPaneIds)` + `alerts.filter`) AND per tab `unreadAlertCount` again
  -> O(tabs x alerts + panes) with a per-tab `Set` allocation, done twice
- `desiredWindowChrome`: O(alerts)
- `desiredSwitcher`: O(tabs x alerts) over the live cycle

Dominant term: **O(panes x alerts + tabs x alerts)** plus per-tab `Set` allocs.

**After:** `unreadAlertTally(for: model)` is one O(alerts) bucket pass + one
O(panes) tree walk (+ O(tabs) + O(groups) dict writes) = **O(alerts + panes +
tabs)**, allocation-free in the rollup. Every consumer then does O(1) dictionary
lookups: focus-borders O(panes), toolbar O(panes), sidebar O(tabs + groups),
window chrome O(1), switcher O(cycle). The multiplicative `x alerts` factor and
the per-tab `Set` allocations are gone. Net: the reconcile alert work goes from
multiplicative to additive in `alerts`. (The independent `model.allPanes`
rebuilds remain, by ADR; they are O(panes) and unaffected.)

## Risks / rollback

- **Stale-pane / total divergence** -- the main correctness risk. The model
  permits an unread alert whose pane is in no tree (stale-pane alerts, not closed
  panes -- close prunes alerts); `total` must count it while the tab/group
  rollups must not. Mitigated by computing `total` independently and by the
  dedicated stale-pane test. Do not "simplify" `total` to a rollup sum.
- **Stale tally** -- if an executor saw a different `model` than the tally was
  built from. Can't happen: `reconcile()` does not mutate `model` (Read-Only
  Model Rule) and builds the tally from the same `self.model` snapshot it passes
  down. Do not cache the tally across reconciles.
- **Foot-gun of the no-arg overload** -- a future hot caller could use it and
  miss the speedup. Bounded (no-arg cost == today's baseline, never a
  regression) and mitigated by the doc note. Acceptable.
- **Rollback** -- low blast radius. Reverting the Projections.swift body edits +
  the Reconcile.swift threading + deleting the tally type/tests fully restores
  prior behavior; the four helpers were never touched.

## Suggested commits (Conventional Commits)

1. `feat(core): add UnreadAlertTally single-pass alert rollup`
   -- the tally type + `unreadAlertTally(for:)` + `sumUnread` in
   ModelOperations.swift, plus `UnreadAlertTallyTests.swift`. No callers yet;
   pure addition. Green under `swift test --package-path lib/DanTermCore`.
2. `perf(core): thread UnreadAlertTally through alert projections`
   -- add the `(in model:, tally:)` overloads to the five projections, switch
   their bodies to tally lookups, keep the no-arg delegating wrappers; rewrite
   the three now-false "scans intentionally stay local" comments (Projections.swift
   156-165 / 301-303 / 346-348) per the Projections section above; add the wiring
   tests. Existing projection tests pass via delegation.
3. `perf(reconcile): compute the unread-alert tally once per reconcile`
   -- Reconcile.swift: build the tally at the top of `reconcile()`, add `tally:`
   to the five executors, forward to the tally forms. App-target wiring. Amend the
   ADR's "Projection Scan Cost" section
   (docs/design/2026-05-27-model-driven-view-reconciliation.md:131-152) -- BOTH
   halves go stale, so rewrite both, not just the conditional:
   (a) the opening cost claim (133-136) currently reads "Projection passes
   deliberately rescan alerts and rebuild `allPanes` ... The cost is
   O(panes/tabs x alerts), with the sidebar's per-tab plus per-group unread
   rollups being the largest current instance" -- after this change alerts are
   precomputed once into `UnreadAlertTally` and threaded, so only `allPanes` is
   still rebuilt per sweep (deliberately, out of scope); keep that `allPanes` half
   of the framing (and the coalescing / human-scale rationale that still applies
   to it);
   (b) the decision paragraph (144-152, "Do not precompute this speculatively ...
   If profiling ever shows `reconcile()` hot, the measured fix is ...") -- record
   that the "high-pane/tab report" trigger fired and the measured fix (compute
   once in `reconcile()` + thread through the enumerated consumers) was applied,
   so it no longer reads as still-pending.
   Leave `Model.swift:226`'s back-reference to this section untouched -- it
   describes the `allPanes` rebuild, which stays true.

(2 and 3 may be squashed if preferred; keeping them split isolates the pure,
`just test`-covered core change from the app-target wiring that needs a build.)

## Verification

- `just test` -- the local gate: core Swift Testing (new tally + wiring tests,
  unchanged helper/projection tests), protocol XCTest, DanTermSupport, the
  core-purity lint (confirms the new pure code introduces no banned
  imports/ambient seams), and the shell self-tests. Do NOT run any
  rebuild/release command.
- `swift test --package-path lib/DanTermCore --filter UnreadAlertTally` -- focused
  run of the new suite while iterating.
- `just build` -- typecheck the app target; the Reconcile.swift executor
  signature changes are NOT covered by `just test`, so this is required.
- `just test-ui` -- GUI-session UI harness (sidebar selection/badges, toolbar):
  confirms bell badges and counts still render correctly end-to-end.
- Optional manual smoke: open many tabs/panes, stream output, fire bells; confirm
  per-pane bell borders, toolbar counts, sidebar tab/group badges, dock badge,
  and the switcher all match the alerts, and that input stays responsive under
  load.
