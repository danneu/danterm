# Fix: `.splitRatioChanged` resolves the split's own tab, not the selected tab

## Context

`update()`'s `.splitRatioChanged(splitId:ratio:)` handler
(`lib/DanTermCore/Sources/DanTermCore/Update.swift:1165-1170`) mutates the
SELECTED tab via `updateSelectedTab` even though the message carries a
`SplitId`. On a miss, `setRatio` (`ModelOperations.swift:383-398`) silently
returns the tree unchanged, yet the handler still emits `.scheduleCheckpoint`.

This is reachable today, not just latent: containers are eagerly mounted --
every tab's `SplitContainerView` stays in the view hierarchy hidden, with
`autoresizingMask = [.width, .height]` (`Reconcile.swift:117-123`,
`AppRuntime.swift:1328`). Once a tab has been revealed (`ensureLaidOut()`
disarms `isApplyingRatio`) and then backgrounded, a window resize still
resizes its hidden `PaneSplitView`s, `splitViewDidResizeSubviews` fires
(`PaneSplitView.swift:60-69`; the 100px divider clamps make the effective
ratio genuinely change at small sizes), and `.splitRatioChanged` arrives
carrying a background tab's splitId. Today that update is silently dropped
(the background tab's persisted ratio goes stale, wrong after restore) and a
spurious checkpoint is scheduled per resize tick.

The fix mirrors the recent `.closePane`/`.toggleZoomPane` migration
(commit 8da7613) and the existing `tabForPane` pattern: resolve the split's
own tab, no-op cleanly on a miss. Side benefit: background-tab ratio changes
during window resize become correctly persisted to THEIR tab, which is the
behavior the eager-mount architecture wants. `.paneBecameFirstResponder`
(Update.swift:~507) already guards against exactly this hazard class for
panes; this brings splits in line.

## Changes

### 1. Failing tests first (TDD per AGENTS.md)

Add to `lib/DanTermCore/Tests/DanTermCoreTests/UpdatePaneTests.swift`, next to
`testSplitRatioChangedNoEffects` (line 116). Reuse `makeModel()`,
`createTab(&model)`, `hasEffect` from `TestSupport.swift`.

**Test (a): background tab's split mutates that tab, selected tab untouched.**

- Setup: `makeModel()`; `createTab` (tab A); `.splitPane(direction: .horizontal)`
  and capture tab A's root splitId; `createTab` again (tab B now selected,
  single leaf).
- Send `.splitRatioChanged(splitId: tabASplitId, ratio: 0.3)`.
- Assert: tab A's root split ratio == 0.3; tab B's rootNode is still a leaf;
  commands == exactly one `.scheduleCheckpoint` (it mutates, so it must
  persist -- same assertion shape as `testSplitRatioChangedNoEffects`).

**Test (b): unknown splitId is a pure no-op.**

- Setup: `makeModel()`; `createTab`; `.splitPane` (so a real tree exists).
- Snapshot the model, send `.splitRatioChanged(splitId: SplitId(), ratio: 0.25)`.
- Assert: `commands.isEmpty` (no `.scheduleCheckpoint`) and the model equals
  the snapshot (`AppModel` is the pure core's value type; if it isn't
  `Equatable`, assert the selected tab's rootNode ratio is unchanged instead).

Both tests get the three-section preamble (Intent / Why it exists / Scenario);
both are spec-first plus the verified resize incident -- Scenario for (a) can
cite the real path: backgrounded mounted container firing
`splitViewDidResizeSubviews` during window resize.

Run `swift test --package-path lib/DanTermCore --filter UpdatePaneTests` and
verify (a) fails on the ratio assertion and (b) fails on the command count,
for the expected reasons.

### 2. Core helper: `tabForSplit`

In `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`, next to
`tabForPane` (line 433):

```swift
/// The tab whose split tree contains `splitId`, or nil. Mirrors `tabForPane`:
/// id-carrying messages resolve their own tab so events from background
/// (mounted-but-hidden) containers land on the right tab.
func tabForSplit(_ splitId: SplitId, in model: AppModel) -> TabModel? {
  for group in model.groups {
    for tab in group.tabs {
      if containsSplit(tab.rootNode, splitId) { return tab }
    }
  }
  return nil
}
```

With a small recursive predicate beside the other tree walkers (near
`allPaneIds`, line 48):

```swift
/// Whether `splitId` names an interior split node of this tree.
func containsSplit(_ node: SplitNodeModel, _ splitId: SplitId) -> Bool {
  switch node {
  case .leaf:
    return false
  case .split(let id, _, let first, let second, _):
    return id == splitId || containsSplit(first, splitId) || containsSplit(second, splitId)
  }
}
```

(Early-exit predicate rather than an `allSplitIds` array to avoid allocating
on a per-resize-tick message.)

### 3. Handler change

`lib/DanTermCore/Sources/DanTermCore/Update.swift:1165-1170`:

```swift
case .splitRatioChanged(let splitId, let ratio):
    // Resolve the split's own tab, not the selected one: hidden background
    // containers stay mounted and fire splitViewDidResizeSubviews during
    // window resize, so this message can arrive for a non-selected tab.
    guard let tab = tabForSplit(splitId, in: model) else { return [] }
    updateTab(tab.id, in: &model) { t in
        t.rootNode = setRatio(t.rootNode, splitId: splitId, ratio: ratio)
    }
    // Persist split ratio so pane proportions are restored accurately.
    return [.scheduleCheckpoint]
```

No other call sites change. The remaining `updateSelectedTab` uses are
inherently selected-tab operations (zoom/focus/movePane-within-visible-
container) -- verified during investigation.

## Existing tests that must keep passing

- `UpdatePaneTests.testSplitRatioChangedNoEffects` (selected-tab case).
- `CheckpointTests.splitRatioChangedEmitsScheduleCheckpoint` (selected-tab).
- `UpdateGhosttyTests.reconcileDecisionCoalescesOnlyEligibleMessages` -- sends
  `.splitRatioChanged(splitId: SplitId(), ...)` but only to
  `reconcileDecision`, never through `update()`; unaffected.
- `ReconcileTests` ratio-carveout test -- unaffected (ContainerShape diffing,
  not the handler).

## Out of scope

- No CLI surface change (no IPC producer of this message), so no
  `integrations/danterm/SKILL.md` update.
- No app/ view changes -- the producer wiring in `SplitContainerView.swift:103`
  is already correct (it sends the right splitId; core was resolving it wrong).

## Verification

1. `swift test --package-path lib/DanTermCore --filter UpdatePaneTests` --
   new tests fail before the core change, pass after.
2. `just test` -- full local gate (protocol + core + support + purity lint +
   shell self-tests). The new helper is pure tree-walking, so the purity lint
   should be clean.
3. Optional manual check: `just build-run`, open tab A with a horizontal
   split, drag the divider off-center, open tab B, resize the window
   substantially, quit and relaunch -- tab A's divider should restore to the
   proportion it actually had at quit (before this fix it restores the stale
   pre-resize ratio).
