# Pivot: make `reconcileMru` cheap on the hot path (drop the dirty-flag idea)

## Context

A performance audit flagged that `update(&model, msg)` runs three functions on
every `Msg` via an unconditional `defer` (`app/Update.swift:13-17`), and that
`reconcileMru` (`app/ModelOperations.swift:870-886`) does real work each time:
two full `model.groups.flatMap(\.tabs)` passes (each materializes a throwaway
`[TabModel]`, copying every tab value with COW refcount traffic), a `Set<TabId>`
build, a fresh `rebuilt` array, and a `moveToFront` that always mutates. Verified
true: `send()` calls `update()` unconditionally (`app/AppRuntime.swift:234`); the
`coalescesReconcile` flag (`app/Msg.swift:193-200`) only defers the *view*
`reconcile()` sweep, never `update()`. So under event-spammy TUIs the
`surfaceTitle`/`surfaceCwd`/`surfaceProgress` callbacks
(`app/GhosttyApp.swift:244,256,427`, no upstream debounce) drive `reconcileMru`
at the raw event rate, recomputing an identical `mruOrder` in steady state.

The audit proposed a handler-set **dirty flag**. We are pivoting away from it: it
re-sprinkles tab-mutation tracking into every handler — exactly the burden the
single-chokepoint `defer` was built to remove (see its comment at
`app/Update.swift:7-12`) — and risks silent MRU staleness (miss one flag-set and
the cmd-shift-o switcher drops a tab). It also contradicts the codebase's
documented anti-drift stance (`app/Model.swift:205-211` deliberately rejects
stored derived indices). The two popover functions in the same `defer`
(`todoPopoverStrandKey`, `reconcileTodoPopover`) already short-circuit on
`model.todoPopover == nil`, so they are effectively free in steady state and are
**out of scope**.

Intended outcome: keep the unconditional chokepoint (no behavior change, no
handler edits, no stored state), but make `reconcileMru` skip the redundant
rebuild in steady state and stop materializing `[TabModel]` arrays — while
dissolving the one duplicated, provably-wasteful id-set idiom it shares with
three siblings.

## Approach (Focused scope)

### 1. New pure helper: `liveTabIds(in:)`

Add a free function in `app/ModelOperations.swift` near the other model queries
(`tabById(_:in:)`, `adjacentTabId(direction:in:)`, `totalTabCount(_:)`), matching
the `(in model: AppModel)` convention. Build the set in one in-place pass — no
`flatMap(\.tabs)` materialization (the `SidebarItemStore.swift:191-224` loop is
the existing precedent for this):

```swift
/// Live tab ids across all groups, built in one in-place pass. Prefer this over
/// `Set(model.groups.flatMap(\.tabs).map(\.id))`, which materializes a throwaway
/// `[TabModel]` (copying every tab value) just to read ids. Hot: reconcileMru
/// calls this on every Msg.
func liveTabIds(in model: AppModel) -> Set<TabId> {
  var ids = Set<TabId>()
  for group in model.groups {
    for tab in group.tabs { ids.insert(tab.id) }
  }
  return ids
}
```

### 2. Rewrite `reconcileMru` with the helper + a sound steady-state early-out

Behavior-preserving. The early-out is the whole point: when `mruOrder` is already
canonical, return before allocating `rebuilt` or running `moveToFront`.

```swift
func reconcileMru(_ model: inout AppModel) {
  let liveTabs = liveTabIds(in: model)

  // Steady-state fast path: when mruOrder is already canonical, the rebuild
  // below reproduces it unchanged, so skip the allocation + hoist. Common under
  // title/cwd/progress spam.
  if mruOrderIsCanonical(model, liveTabs: liveTabs) { return }

  var seen = Set<TabId>()
  var rebuilt: [TabId] = []
  rebuilt.reserveCapacity(liveTabs.count)
  for tabId in model.mruOrder where liveTabs.contains(tabId) && seen.insert(tabId).inserted {
    rebuilt.append(tabId)
  }
  for group in model.groups {
    for tab in group.tabs where seen.insert(tab.id).inserted {
      rebuilt.append(tab.id)
    }
  }
  model.mruOrder = rebuilt
  if model.mruCycle == nil, let sel = model.selectedTabId {
    moveToFront(&model.mruOrder, sel)
  }
}

/// True iff `mruOrder` is already the canonical reconciliation output: a
/// duplicate-free permutation of the live tab set whose head honors the hoist
/// invariant (unless cycling suppresses it). One pass rejects any stale id or
/// repeat; the final count check then confirms full coverage.
private func mruOrderIsCanonical(_ model: AppModel, liveTabs: Set<TabId>) -> Bool {
  guard model.mruCycle != nil || model.mruOrder.first == model.selectedTabId else {
    return false
  }
  var seen = Set<TabId>()
  seen.reserveCapacity(liveTabs.count)
  for id in model.mruOrder {
    guard liveTabs.contains(id), seen.insert(id).inserted else { return false }
  }
  return seen.count == liveTabs.count
}
```

Why the predicate must prove *exact coverage*, not just matching counts — two
distinct holes break a count-based check. (1) Stale swap — a single `Msg` can
remove A and add B while keeping `mruOrder.count` equal, so `[A, ghost]` for live
`{A, B}` matches on count yet drops B. (2) Duplicate — `[A, A]` for live `{A, B}`
also matches on count, with every entry live and a valid head, yet repeats A and
drops B. The single-pass check rejects stale ids (not in `liveTabs`) and repeats
(`seen.insert` reports `inserted == false`), then requires `seen.count ==
liveTabs.count`; together these prove `mruOrder` is a duplicate-free permutation
of the live set.

### 3. Adopt `liveTabIds(in:)` at the 3 other id-set sites (dedup, zero behavior change)

Each is the literal expression `Set(model.groups.flatMap(\.tabs).map(\.id))`:

- `app/ModelOperations.swift:901` (`resolveLiveCycle`) — replace with `liveTabIds(in: model)`.
- `app/Update.swift:1540` (`let before = ...`) — replace with `liveTabIds(in: model)`.
- `app/SidebarView.swift:257` — inline into the call to avoid shadowing the new
  function name with the existing local: pass `liveTabIds: liveTabIds(in: model)`
  to `resolveReloadSelection(...)` and delete the local `let liveTabIds`.

### Explicitly out of scope (and why)

- The popover functions in the `defer` — already short-circuit on no open popover.
- Cold `.flatMap(\.tabs).isEmpty` / `.count` / `.first?.id` sites in `Update.swift`,
  `totalTabCount` (`ModelOperations.swift:474`), `AppDelegate.swift:186`,
  `Projections.swift:494-495,578` — these run on user actions or the coalesced
  render sweep, not the raw Msg stream. Converting them is zero-perf-gain
  readability churn with nonzero regression risk; it does not belong in this
  `perf` change.

## Tests (TDD)

This is a behavior-preserving change, and the existing suite already pins the
contract the early-out must respect:

- `tests/ModelOperationsTests.swift:773` — no-op on full live order (canonical input → early-out path).
- `:782` — hoists selectedTabId (head not canonical → early-out correctly falls through to rebuild).
- `:791` — no hoist while cycling.
- `:801` prune / `:811` append / `:820` dedup / `:829` empty-restore — the rebuild branch.
- `tests/UpdateMruTests.swift` — createTab/selectTab/closeTab/movePaneToNewTab/surfaceCreationFailed/deleteGroup/restore integration.

Add **two** new tests in `tests/ModelOperationsTests.swift` (in the `reconcileMru`
section, after `:838`) — one per count-collision hole the existing tests do not
cover. Both pass against today's code (which always rebuilds) and must keep
passing once the fast path lands; together they guard that `mruOrderIsCanonical`
proves *exact coverage*, not just a matching count. Written spec-first:

```swift
test("reconcileMru does not early-out when count matches but a live tab is missing") {
    // Intent: when mruOrder has the same count as the live set but holds a stale
    //   id in place of a missing live id, reconcileMru still prunes the stale id
    //   and appends the missing live tab (no false steady-state skip).
    // Why it exists: pins one half of the fast path's soundness. A count-only
    //   check treats [A, ghost] as canonical for live {A, B} (count 2 == 2) and
    //   silently drops B from the switcher forever.
    // Scenario: spec-first. Models a single Msg that both removes a tab and leaves
    //   a stale mruOrder entry (e.g. a restore/import swap), keeping the counts
    //   equal. No incident to cite.
    let (m0, ids) = makeMruModel(tabCount: 2)   // live {A, B}
    var model = m0
    let ghost = TabId()
    model.mruOrder = [ids[0], ghost]            // count 2 == live count 2, but B missing
    model.selectedTabId = ids[0]
    reconcileMru(&model)
    try expect(!model.mruOrder.contains(ghost), "stale id must be pruned")
    try expectEqual(Set(model.mruOrder), Set(ids), "missing live tab must be appended")
}

test("reconcileMru does not early-out on a duplicate live id") {
    // Intent: when mruOrder repeats a live id ([A, A]) for live set {A, B}, the
    //   fast path must NOT fire; reconcileMru dedups to [A] and appends B.
    // Why it exists: pins the other half of the fast path's soundness, and the
    //   exact bug a count-only predicate hits. (count == liveTabs.count && every
    //   entry live && head == selected) ALL hold for [A, A] vs {A, B} -- count
    //   2 == 2, both entries live, head A == selected -- yet that state has a
    //   duplicate and is missing B. mruOrderIsCanonical must reject it via its
    //   no-repeat + full-coverage checks.
    // Scenario: spec-first. Models a corrupt/transient mruOrder with a repeated
    //   id; reconcile must restore the dedup + coverage invariant. No incident.
    let (m0, ids) = makeMruModel(tabCount: 2)   // live {A, B}
    var model = m0
    model.mruOrder = [ids[0], ids[0]]           // duplicate live id; B missing
    model.selectedTabId = ids[0]
    reconcileMru(&model)
    try expectEqual(model.mruOrder, [ids[0], ids[1]], "dedup to [A], then append B")
}
```

## Files to modify

- `app/ModelOperations.swift` — add `liveTabIds(in:)` and `mruOrderIsCanonical(_:liveTabs:)`; rewrite `reconcileMru`; swap `resolveLiveCycle`.
- `app/Update.swift` — swap line 1540 to `liveTabIds(in:)`.
- `app/SidebarView.swift` — inline `liveTabIds(in:)` at line 257.
- `tests/ModelOperationsTests.swift` — add the soundness test.

## Verification

1. `just test` — the 7 existing `reconcileMru` tests + `UpdateMruTests` + the two
   new soundness tests must all pass (behavior preserved).
2. `just build` — compiles clean (watch for the `liveTabIds` shadowing fix in
   `SidebarView.swift`).
3. Manual smoke (optional): run `just build-run`, open several tabs, then in one
   pane run a title/progress-spamming process (e.g. a loop emitting `OSC 0` title
   sets or a progress bar). Confirm cmd-shift-o cycles in correct MRU order and
   that switching tabs still hoists the newly-selected tab to the front — i.e. the
   early-out did not break ordering under the spam that now takes the fast path.
