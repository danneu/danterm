# Plan: dedup `normalizedLiveTabIds` into its 5 inlined copies

## Context

`lib/DanTermCore/Sources/DanTermCore/Update.swift` defines a private helper
that dedupes a list of `TabId`s and drops ids whose tab no longer exists:

```swift
// Update.swift:2516
private func normalizedLiveTabIds(_ ids: [TabId], in model: AppModel) -> [TabId] {
    var seen = Set<TabId>()
    return ids.filter { id in
        guard !seen.contains(id), tabLocation(id, in: model) != nil
        else { return false }
        seen.insert(id)
        return true
    }
}
```

It is already used by two handlers (`.requestCloseTabs` at line 129,
`.confirmCloseTabs` at line 963). But the **identical** filter body is
copy-pasted inline into five more `Msg` handlers in the same file. The copies
are byte-for-byte equivalent to the helper (differing only in the local
variable name `validIds` and one-line `seen.insert(id); return true`).

This is pure duplication -- no behavioral divergence, no bug -- so the goal is
to collapse the five copies onto the existing helper. The win is removing ~25
lines and eliminating future-divergence risk; the change is behavior-preserving.

Verified the pattern is **contained**: a repo-wide sweep found no sibling
"dedup typed ids + drop stale" blocks for `PaneId`/`GroupId` or elsewhere, so
this refactor does not widen beyond these five sites.

## Change

### 1. Test coverage -- no new test (and why the "gap" can't be closed)

The first draft of this plan proposed adding a
`testClearAlertsForTabsDedupesAndIgnoresStale` test on the theory that
`.clearAlertsForTabs` was the one handler lacking a duplicate-id test. That
test was dropped after review: **neither half of the normalization --
deduplication nor stale-id dropping -- is behaviorally observable for
`.clearAlertsForTabs`**, so any test claiming to pin either would be a false
guard (it would pass even with that half of the filter deleted), and pinning it
would require a structure-sensitive test (spying on call counts) -- which this
project's test-quality bar forbids.

Why both halves are inert here, from the handler body (`Update.swift:453-472`)
and its helpers:

- `paneIdsForTab(_:in:)` (`ModelOperations.swift:482`) returns `[]` for a tab id
  that is in no group; `unreadAlertPaneIds(for:in:)` (`Update.swift:2494`)
  returns only panes that *still* have `isUnread` alerts; `markAlertsReadForPane`
  (`Update.swift:2485`) flips only `isUnread` alerts and is idempotent.
- **Dedup is inert:** for input `[id1, id1, ...]`, the first `id1` clears pane1's
  unread alerts and the second `id1` finds no unread panes, so it does nothing.
- **Stale-drop is inert:** a stale id reaching the loop yields
  `paneIdsForTab -> []`, hence `unreadPaneIds -> []`, so the loop body is skipped
  and `affectedPaneIds` stays empty -- exactly as if the id had been filtered
  out first. An all-stale batch returns `[]` either way (via the
  `!affectedPaneIds.isEmpty` guard instead of the `!validIds.isEmpty` guard).
- So for any input the final model state and the always-`[]` return are
  identical whether or not the duplicate/stale ids are normalized away.

Net: removing either half of the filter from this handler changes no observable
output, so there is genuinely nothing to assert about normalization here. Rely
on the existing `.clearAlertsForTabs` tests for the behavior that *is*
observable -- the batch-clear and no-op contracts:
`testClearAlertsForTabsClearsAllSelected`,
`testClearAlertsForTabsRefreshesOnlyTabsWithUnreadAlerts`,
`testClearAlertsForTabsNoUnreadIsNoop`, and `testClearAlertsForTabsAllStaleIsNoop`
(all in `UpdateAlertTests.swift`). Note the last one pins the *observable* no-op
(empty commands, real alerts untouched), not the internal stale-drop branch,
which -- per the above -- cannot be distinguished behaviorally. These stay green
across the swap and are the regression net for this handler.

This makes the refactor a pure, test-additive-free, behavior-preserving swap:
the only files touched are `Update.swift`. The normalization behavior that *is*
observable elsewhere (`.moveTabs`, `.extractTabsToNewGroup`, and the helper's
existing close-tab callers, where a double-move or double-close *does* change
output) is already pinned by their own `*DedupesAndIgnoresStale` tests, which
exercise the shared helper after the swap.

### 2. Replace the five inlined blocks with the helper

In `lib/DanTermCore/Sources/DanTermCore/Update.swift`, at each site replace the
4-line `var seen = Set<TabId>() ... }` block with the one-liner. The handler's
parameter is `tabIds` at all five sites, so the replacement is uniform:

```swift
let validIds = normalizedLiveTabIds(tabIds, in: model)
```

Keep the local name `validIds` -- only the right-hand side changes -- so the
downstream references (`validIdSet`, the apply loops, the all-live no-op check)
stay intact and the diff stays tight. (The helper's existing callers name the
result `normalized`; do **not** rename `validIds` here, since `.moveTabs` and
`.extractTabsToNewGroup` reference it several times and `validIds` reads at
least as well as `normalized` at those sites.)

The five sites and their unchanged tails:

| Handler | Lines (block to replace) | Downstream that must stay intact |
|---|---|---|
| `.setTabColors` | 423-428 | `guard !validIds.isEmpty`, apply loop |
| `.clearCustomTitles` | 439-444 | `guard !validIds.isEmpty`, apply loop |
| `.clearAlertsForTabs` | 454-459 | `guard !validIds.isEmpty`, per-tab alert loop |
| `.moveTabs` | 1044-1049 | `validIdSet = Set(validIds)`, removal/insert math |
| `.extractTabsToNewGroup` | 1099-1104 | `validIds.count == totalTabs` check, `.moveTabs` delegation |

At `.extractTabsToNewGroup`, also delete the now-redundant narrating comment on
line 1098 (`// Dedupe and drop ids that no longer exist.`) -- the helper name
states that. The other four sites have no such comment.

The helper takes a non-`inout` `model`; all five handlers hold `model` as
`inout`. Passing an `inout` binding to a borrowing parameter is exactly what the
two existing callers (lines 129, 963) already do, so this compiles unchanged.

## Files modified

- `lib/DanTermCore/Sources/DanTermCore/Update.swift` -- 5 block replacements + 1 comment deletion. **Only file touched** (no test changes; see Step 1).

## Verification

The safety net is the existing tests passing **unchanged** (behavior-preserving
refactor). Every handler that has *observable* dedup-or-stale behavior already
has a test that exercises it through the (now shared) helper:

- `.setTabColors` -- `testSetTabColorsDedupesAndIgnoresStale`, `testSetTabColorsAllStaleIsNoop` (`UpdateTabTests.swift`)
- `.clearCustomTitles` -- `testClearCustomTitlesDedupesAndIgnoresStale`, `testClearCustomTitlesAllStaleIsNoop` (`CustomTitleTests.swift`)
- `.clearAlertsForTabs` -- `testClearAlertsForTabsClearsAllSelected`, `testClearAlertsForTabsAllStaleIsNoop` (+ the two other batch tests) (`UpdateAlertTests.swift`); both dedup *and* stale-drop are unobservable here (Step 1), so the batch-clear and observable-no-op contracts are the relevant net.
- `.moveTabs` -- `testMoveTabsDedupesAndIgnoresStaleIds`, `testMoveTabsAllStaleIdsIsNoop` (`UpdateGroupTests.swift`)
- `.extractTabsToNewGroup` -- `testExtractDedupesAndIgnoresStaleIds`, `testExtractAllStaleIdsIsNoop` (`UpdateGroupTests.swift`)
- Helper's existing callers -- `testRequestCloseTabsFiltersStaleIdsBeforeSingletonDelegation`, `testRequestCloseTabsDeduplicatesIdsForConfirmation` (`UpdateTabTests.swift`)

Steps:

1. `swift test --package-path lib/DanTermCore` -- full core suite green (covers
   all six handlers above). The dedup/stale tests are the regression guard.
2. `just test` -- the local gate (protocol + core + support + purity lint +
   shell self-tests) to confirm nothing else moved.

No app run or MCP needed: the change is confined to the pure core and is fully
exercised by the Swift Testing suite.
