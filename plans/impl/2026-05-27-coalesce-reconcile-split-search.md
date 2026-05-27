# Coalesce reconcile() for split-ratio and search-count messages

## Context

Today's commit `1397939` ("perf(runtime): coalesce surface reconcile sweeps")
made `AppRuntime.send` defer the whole-model `reconcile()` sweep behind a 75 ms
trailing timer for high-frequency surface messages, opting in `.surfaceTitle`,
`.surfaceCwd`, and `.surfaceProgress` via `Msg.coalescesReconcile`
(`app/Msg.swift:193-200`). Its own Non-goals section explicitly anticipated this
follow-up: "Adding a future high-frequency message to `coalescesReconcile` is
safe by construction."

Two high-frequency message classes were left out, and each still triggers a full
synchronous `reconcile()` per tick on the main thread:

- **`.splitRatioChanged`** — `PaneSplitView.splitViewDidResizeSubviews`
  (`app/PaneSplitView.swift:60-69`) calls `onRatioChanged` on *every* resize
  tick, wired to `send(.splitRatioChanged)` (`app/SplitContainerView.swift:87-88`).
  This fires not just on divider drags but throughout window live-resize (AppKit
  auto-resizes split subviews continuously; the `isApplyingRatio` guard only
  covers DanTerm's *programmatic* `applyRatio`, set at
  `app/SplitContainerView.swift:112`). Nested splits multiply it — one message
  per split per tick. The resulting reconcile is a **provably empty diff**:
  `ContainerShape` deliberately drops ratios (`app/ModelOperations.swift:670-687`,
  the `_` in `case .split(... , _)`), pinned by the existing test
  `tests/ReconcileTests.swift:407-413` ("split ratio is excluded -- splitRatioChanged
  must not rebuild"), and no other projection reads ratios. So the whole sweep
  is wasted CPU competing with libghostty's own resize relayout.

- **`.ghosttySearchTotal` / `.ghosttySearchSelected`** — libghostty's search
  thread streams `total_matches` incrementally as it scans the scrollback
  (`.ghostty-src/src/terminal/search/Thread.zig:719-733`, in a tight
  tick -> notify -> `loop.run(.no_wait)` loop at `:188-236`), each emitting one
  `.ghosttySearch*` (`app/GhosttyApp.swift:461-483`). Unlike split-ratio, this
  reconcile is *not* empty — it re-renders the overlay's "N/M" match count from
  `searchState` (`app/Update.swift:1144-1154`). Coalescing throttles that live
  count to <=13 Hz mid-scan, exactly how the title already behaves; the count
  still settles to the exact final value.

**Outcome:** opting all three into `coalescesReconcile` removes the *per-tick*
split-ratio and search-count sweeps and bounds them to ~13 Hz, with no risk of
dropping a final value (the model still updates immediately on every message).
A single trailing sweep still fires per ~75 ms burst during continuous resize --
for split-ratio it stays an empty diff, so the residual work is negligible.

## Approach

Single-mechanism, safe-by-construction extension of the existing coalescing
path. **The only production change is three new cases in `Msg.coalescesReconcile`
plus a broadened doc comment.** Everything downstream is already message-agnostic
and correct:

- `reconcileDecision` (`app/ModelOperations.swift`) already gates on
  `msg.coalescesReconcile && !emitsPostReconcile`, returning `.reconcileNow`
  otherwise. No change.
- The update arms are unchanged and already take the coalesce path:
  `.splitRatioChanged` returns `[.scheduleCheckpoint]` (`app/Update.swift:1101-1106`)
  and the two search arms return `[]` (`app/Update.swift:1144-1154`) — all
  non-post-reconcile per `Command.isPostReconcile` (`app/Command.swift:99-115`),
  so none is forced inline. The model mutates immediately (ratio/count never
  lost), and `.scheduleCheckpoint`'s 2 s debounce still captures the final ratio
  for persistence.
- Structural messages (split/close/focus/bell/endSearch) are uncoalesced, so
  they hit `.reconcileNow` and flush any pending cosmetic sweep first.

### Change: `app/Msg.swift`

Extend the switch, grouping cases by *why* each qualifies, and broaden the doc
comment (it currently says "Only high-frequency surface metadata opts in", which
no longer describes `.splitRatioChanged`, a View message):

```swift
extension Msg {
    /// Whether this message is eligible to defer its reconcile() sweep so bursts
    /// coalesce. A message opts in when its sweep is either empty (split-ratio:
    /// ContainerShape drops ratios) or merely cosmetic and safe to throttle to
    /// ~13 Hz (title/cwd/progress, live search match count). update() still runs
    /// immediately, so the model stays current and the final value is never
    /// dropped; only the whole-model view sweep is deferred. The runtime evaluates
    /// this on the *translated* message, keeping title-channel IPC events on the
    /// inline path. Eligibility is necessary but not sufficient: reconcileDecision
    /// still forces an inline reconcile when update() emitted a post-reconcile
    /// command, so opting a message in here is always safe.
    var coalescesReconcile: Bool {
        switch self {
        // Cosmetic chrome a TUI/search updates at 30-60 Hz: the sweep produces a
        // real but throttleable diff (tab title/subtitle, progress, the search
        // overlay's live "N/M" match count).
        case .surfaceTitle, .surfaceCwd, .surfaceProgress,
             .ghosttySearchTotal, .ghosttySearchSelected:
            return true
        // Window/divider live-resize fires this every tick, but ContainerShape
        // drops split ratios (see ReconcileTests "split ratio is excluded"), so
        // the sweep is an empty diff -- pure waste; defer it.
        case .splitRatioChanged:
            return true
        default:
            return false
        }
    }
}
```

## Tests (TDD: write failing first)

The edit is in `tests/UpdateGhosttyTests.swift`, extending the policy test commit
`1397939` added (its sibling invariant test at `:146` is left untouched -- see
the "No second test is added" note below). Run `just test` to verify.

Per AGENTS.md "Test preambles", the renamed policy `test {}` body must open with
the three labeled sections (`// Intent`, `// Why it exists`, `// Scenario`). It is
spec-first, so the Scenario describes the behavior, not an invented incident --
Intent: the three new high-frequency messages classify as coalesce-eligible while
a post-reconcile command still forces inline. Why it exists: pins the coalescing
policy so a classification / pending-state / post-reconcile regression fails here.
Scenario: a divider drag and a streaming search emit bursts whose empty/cosmetic
sweep must defer into the 75 ms timer.

**The edit — policy test, red→green** (`:101`, "reconcileDecision coalesces only
eligible surface metadata"). Rename to "...only eligible high-frequency
messages" and add the three messages to `coalescedMessages`:

```swift
.splitRatioChanged(splitId: SplitId(), ratio: 0.3),
.ghosttySearchTotal(paneId: paneId, total: 42),
.ghosttySearchSelected(paneId: paneId, selected: 3)
```

This is the red: today `reconcileDecision(for: .splitRatioChanged, ...)` returns
`.reconcileNow` (because `coalescesReconcile` is false), but the loop asserts
`.scheduleCoalesced` (pending: false) / `.coalesceIntoPending` (pending: true).
Goes green after the `Msg.swift` change. The existing `inlineMessages` arm
(`.surfaceBell`, `.commandStarted`, ...) stays as the negative control. This is
the *complete* red→green for the production change: the test both enumerates
every coalesce-eligible message and flips back to `.reconcileNow` if the
`Msg.swift` cases are reverted.

**No second test is added** (revised after review). A
`commands.allSatisfy { !$0.isPostReconcile }` invariant on the new arms would be
strictly weaker than coverage that already exists: `tests/UpdatePaneTests.swift:77`
pins `.splitRatioChanged` to exactly `[.scheduleCheckpoint]`, and
`tests/UpdateSearchTests.swift:113/125` pin both search arms to `commands.isEmpty`
— any post-reconcile command added to these arms fails those loudly. The subtler
"`.scheduleCheckpoint` reclassified as post-reconcile" regression is also already
caught: the existing `:146` invariant test runs surface arms that emit
`[.scheduleCheckpoint]` (`app/Update.swift:700,706`) under the same
`allSatisfy { !$0.isPostReconcile }` assertion. So leave `:146` untouched — its
name stays accurate (surface-only).

No existing test changes behavior: the command-output tests named above plus
`tests/CheckpointTests.swift:138` assert `update()` output, which this change
leaves untouched; `tests/ReconcileTests.swift:407` (the ratio carveout) is
unchanged and keeps backing the empty-diff claim.

## Verification

1. `just test` — the extended policy test green; full suite passes.
2. `just build-run` — launch the dev app.
3. **Split-ratio (empty-diff win, expect zero visible change):** open a tab with
   2-3 nested splits; drag a divider and live-resize the window. Resize stays
   smooth; pane proportions track the divider and persist across a checkpoint/
   restart. (Optional: a temporary signpost/counter in `reconcile()` confirms
   sweeps drop to ~13 Hz during live-resize vs. per-tick today.)
4. **Search counts (throttle, expect ~13 Hz):** in a pane with large scrollback,
   start a search for a common token; the "N/M" count animates smoothly (not
   60 Hz flicker) and settles on the exact final total. Next/prev still updates
   the selected index promptly.
5. **Structural ops still instant:** splitting/closing a pane, switching tabs,
   and ending search reflect immediately (these flush any pending sweep inline).

## Non-goals

- Making `reconcile()` itself cheaper (memoization) — orthogonal, unnecessary
  once sweeps are bounded.
- Source-throttling `onRatioChanged` in `PaneSplitView` — the design commit
  `1397939` deliberately rejected (it risks dropping the final value and adds
  per-view state); coalescing the sweep is the chosen mechanism.
- A dedicated "never reconcile" decision for split-ratio — less robust than
  deferring (a future projection that reads ratio would silently break); the
  one cheap trailing sweep per burst is acceptable.
