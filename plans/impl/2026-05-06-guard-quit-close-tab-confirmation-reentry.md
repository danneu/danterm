# Guard quit and close-tab confirmation re-entry

## Bug and goal

Every path that wants to ask the user before quitting emits
`Effect.showTerminateConfirmation`, which lands in `app/AppRuntime.swift:367-390`
and calls `alert.beginSheetModal(for: window)`. AppKit *queues* sheets
attached to the same window, so N rapid emits produce N stacked sheets;
the same shape applies to `Effect.showCloseTabConfirmation` at
`app/AppRuntime.swift:344-365`. In the incident, synthetic Cmd+Q events
queued hundreds of sheets faster than the user could cancel and DanTerm
had to be killed. Goal: introduce a single ephemeral pending-
confirmation slot on `AppModel` so any call site that tries to emit
*any* confirmation effect (quit OR close-tab) while one is already
pending becomes a no-op, eliminating sheet stacking both within a kind
(rapid Cmd+Q) and across kinds (Cmd+Q while a close-tab sheet is up).

## Test cases (write first; verify failing for the right reason)

All tests live in the pure-compile subset and run via `just test`. New
quit tests go in `tests/UpdateLifecycleTests.swift`; new close-tab
tests go in `tests/UpdateTabTests.swift`. Each test isolates one
property; together they cover every call site that emits a
confirmation effect AND every dismissal transition that must clear
the slot.

All assertions follow the existing harness style: count the effects,
then pattern-match each one (`if case .terminate = effects[0]`). `Effect`
is not `Equatable`, so direct array equality is not used.

### Quit confirmation guard

1. **`testRequestQuitSetsPending`** -- from idle, dispatch
   `.requestQuit`. Assert one effect, pattern-matches
   `.showTerminateConfirmation`, AND
   `model.pendingConfirmation == .terminate`. Pins down: emitting the
   effect updates the slot to the right kind.
2. **`testRequestQuitWhileQuitPendingIsNoOp`** -- dispatch
   `.requestQuit`, then `.requestQuit` again. Assert second call
   returns zero effects. Pins down: same-kind re-entry guard.
3. **`testCloseTabLastTabWhileQuitPendingIsNoOp`** -- set
   `model.pendingConfirmation = .terminate`, then `.closeTab(id:)` on
   the sole tab (so `wouldQuitFromClose` is true). Assert zero
   effects, group/tab/pane state unchanged. Pins down: `.closeTab`'s
   wouldQuit branch (line 100) respects the slot.
4. **`testClosePaneLastPaneWhileQuitPendingIsNoOp`** -- slot set
   `.terminate`, then `.closePane(paneId:)` on the only pane. Assert
   zero effects, no `.destroySurface` pattern present, `model.panes`
   unchanged. Pins down: `.closePane`'s wouldQuit branch (line 186)
   respects the slot.
5. **`testDeleteGroupLastGroupTabsWhileQuitPendingIsNoOp`** -- build
   `model.groups` directly with two groups (one holding all tabs, the
   other empty -- bypassing the API since auto-pruning normally
   forbids this state), set slot `.terminate`, dispatch
   `.deleteGroup(id: tabsGroupId, moveTabs: false)`. Assert zero
   effects, both groups still present. Pins down: `.deleteGroup`'s
   last-group termination branch (line 937) respects the slot.
6. **`testConfirmTerminateClearsPending`** -- slot set `.terminate`,
   dispatch `.confirmTerminate`. Assert one effect that pattern-
   matches `.terminate`, AND `model.pendingConfirmation == nil`. Pins
   down: confirm clears the slot.
7. **`testCancelTerminateClearsPending`** -- slot set `.terminate`,
   dispatch `.cancelTerminate`. Assert zero effects AND
   `model.pendingConfirmation == nil`. Pins down: cancel clears the
   slot.
8. **`testRequestQuitAgainAfterCancel`** -- end-to-end:
   `.requestQuit`, `.cancelTerminate`, `.requestQuit`. Assert the
   final dispatch re-emits `.showTerminateConfirmation` (one effect,
   pattern-matched). Pins down: re-emit works after a real cancel
   cycle.

### Close-tab confirmation guard

9. **`testRequestCloseTabMultiPaneSetsPending`** -- two tabs in the
   model, the first split into two panes; dispatch
   `.requestCloseTab(id: firstTabId)`. Assert one effect that
   pattern-matches `.showCloseTabConfirmation` AND
   `model.pendingConfirmation == .closeTab`. Pins down: emit + slot
   set.
10. **`testRequestCloseTabWhileCloseTabPendingIsNoOp`** -- slot set
    `.closeTab`, dispatch `.requestCloseTab(id:)` on a multipane tab.
    Assert zero effects. Pins down: same-kind re-entry guard.
11. **`testConfirmCloseTabClearsPendingAndDispatches`** -- create at
    least two tabs, split the *first* tab into two panes (so closing
    it is NOT the last-tab path and `wouldQuitFromClose` is false),
    set slot `.closeTab`, dispatch
    `.confirmCloseTab(id: firstTabId)`. Assert effects contain
    `.destroySurface` for each pane in that tab, the tab is removed
    from `model.groups[0].tabs`, AND
    `model.pendingConfirmation == nil`. Pins down: confirm clears the
    slot and routes through `.closeTab` to actually destroy the panes
    (not into the wouldQuit branch).
12. **`testConfirmCloseTabLastMultiPaneRoutesToTerminate`** -- single
    tab in the model, split into two panes (so the tab is BOTH the
    last tab and multipane, making `wouldQuitFromClose` true inside
    the recursive `.closeTab`). Set slot `.closeTab`, dispatch
    `.confirmCloseTab(id: tabId)`. Assert one effect that pattern-
    matches `.showTerminateConfirmation`, NO `.destroySurface` effect
    for any pane, the tab is still present in
    `model.groups[0].tabs`, both panes still present in
    `model.panes`, AND `model.pendingConfirmation == .terminate`.
    Pins down the chain: `.confirmCloseTab` clears the slot, recursive
    `.closeTab` hits its wouldQuit branch, `emitTerminateConfirmation`
    sees a nil slot and successfully emits + retags. Without this
    test, an implementation that forgot to clear the slot before
    delegating would silently no-op confirming the last multipane
    tab, since the recursive emit would see `.closeTab` still pending.
13. **`testCancelCloseTabClearsPending`** -- slot set `.closeTab`,
    dispatch `.cancelCloseTab`. Assert zero effects AND
    `model.pendingConfirmation == nil`. Pins down: cancel clears the
    slot.

### Cross-kind guard (the High-severity case)

14. **`testRequestQuitWhileCloseTabPendingIsNoOp`** -- slot set
    `.closeTab` (close-tab sheet imagined to be up), dispatch
    `.requestQuit`. Assert zero effects, no `.showTerminateConfirmation`
    pattern. Pins down: a close-tab sheet blocks a new quit sheet from
    queuing.
15. **`testRequestCloseTabWhileQuitPendingIsNoOp`** -- slot set
    `.terminate`, dispatch `.requestCloseTab(id:)` on a multipane tab.
    Assert zero effects, no `.showCloseTabConfirmation` pattern. Pins
    down: a quit sheet blocks a new close-tab sheet from queuing.

### Pure response-mapper tests

Live in `tests/UpdateLifecycleTests.swift` (or a new
`ConfirmationResponseTests.swift` file wired into `TestRunner.main`).
The mapper exists so AppRuntime cannot accidentally regress to "send
nothing on cancel," which is exactly the pre-fix close-tab behavior.

16. **`testCloseTabConfirmationResponseConfirm`** -- call
    `closeTabConfirmationResponse(isConfirm: true, tabId: id)`,
    pattern-match `.confirmCloseTab(let returnedId)`, assert
    `returnedId == id`. Pins down: confirm path carries the tabId.
17. **`testCloseTabConfirmationResponseCancel`** -- call
    `closeTabConfirmationResponse(isConfirm: false, tabId: TabId())`,
    pattern-match `.cancelCloseTab`. Pins down: non-confirm path
    produces an explicit cancel Msg, not nothing.

### Existing tests to update (not new)

`testRequestQuitWithOnePane` (`tests/UpdateLifecycleTests.swift:142`)
and `testRequestQuitWithMultiplePanes` (:153) gain a one-line
assertion that `model.pendingConfirmation == .terminate` after the
dispatch. `testCloseLastPaneShowsConfirmation`
(`tests/UpdateTabTests.swift:77`) and `testCloseLastTabShowsConfirmation`
(:92) gain the same. `testRequestCloseTabMultiPaneShowsConfirmation`
(:321) gains
`expectEqual(model.pendingConfirmation, .closeTab)`.
`testRequestCloseTabSinglePaneLastTabShowsTerminateConfirmation` (:341)
gains `expectEqual(model.pendingConfirmation, .terminate)` (the
single-pane last-tab path routes through `.closeTab`'s wouldQuit
branch).

## Model change

Add a single ephemeral slot to `AppModel` in
`app/Model.swift:160-175`, alongside the existing ephemeral flags
(`mruCycle`, `jumpMode`, `todoPopoverPaneId`). The kind of pending
confirmation is tagged so future kinds (e.g. close-pane) can extend
the enum without changing the guard shape.

```swift
// Ephemeral -- never serialized into AppModelSnapshot. Non-nil while a
// confirmation sheet is in flight. Both quit and close-tab share this
// single slot so neither kind can stack a sheet on top of the other.
enum PendingConfirmation: Equatable {
    case terminate
    case closeTab
}

// In AppModel:
var pendingConfirmation: PendingConfirmation? = nil
```

Defaults to `nil` at construction. `validateAndBuildDetailed`
(`app/Model.swift:295-463`, line 460) constructs `AppModel` via the
positional initializer `AppModel(groups:panes:selectedTabId:)` and
relies on default values for everything else, so restored models
correctly start with `pendingConfirmation == nil`.

## Helper extraction (single chokepoint)

Add two pure emit helpers and one pure response mapper to
`app/ModelOperations.swift` (already in the test-compiled subset).
Every call site that wants to raise a confirmation effect goes through
these helpers; `.showTerminateConfirmation` and
`.showCloseTabConfirmation` are never constructed inline anywhere else
in `Update.swift`. The chokepoint shape mirrors how `reconcileMru`
(line 850) is the one place that maintains MRU ordering.

Both emit helpers guard the *same* slot, which is what gives the cross-
kind guarantee: if `.closeTab` is pending, `emitTerminateConfirmation`
also returns `[]`, and vice versa.

```swift
// Emit a quit confirmation if no confirmation is already pending. Sets
// the slot when emitting; returns [] (no-op) when ANY confirmation is
// already in flight (including a close-tab one). Single chokepoint for
// every call site that wants to ask the user before quitting.
func emitTerminateConfirmation(_ model: inout AppModel) -> [Effect] {
    guard model.pendingConfirmation == nil else { return [] }
    model.pendingConfirmation = .terminate
    return [.showTerminateConfirmation(paneCount: model.panes.count)]
}

// Same shape for close-tab. Guards on the same slot as terminate, so a
// pending quit blocks a new close-tab sheet too.
func emitCloseTabConfirmation(
    _ model: inout AppModel, tabId: TabId, tabTitle: String,
    paneCount: Int, isLastTab: Bool
) -> [Effect] {
    guard model.pendingConfirmation == nil else { return [] }
    model.pendingConfirmation = .closeTab
    return [.showCloseTabConfirmation(
        tabId: tabId, tabTitle: tabTitle,
        paneCount: paneCount, isLastTab: isLastTab
    )]
}

// Maps an AppKit alert response back to the Msg AppRuntime should
// dispatch. Living here (a pure function in the test-compiled subset)
// means a unit test pins down "non-confirm produces an explicit
// cancelCloseTab," so AppRuntime cannot regress to the pre-fix
// behavior of sending nothing on cancel.
func closeTabConfirmationResponse(isConfirm: Bool, tabId: TabId) -> Msg {
    isConfirm ? .confirmCloseTab(id: tabId) : .cancelCloseTab
}
```

The terminate side already sends both `.confirmTerminate` and
`.cancelTerminate` from AppRuntime today, so a mapper there is not
strictly required by the bug; leaving it inline keeps the diff small.
If a regression bites later we can extract a `terminateConfirmationResponse`
helper symmetrically.

## Call-site rewrites in `app/Update.swift`

Every existing inline emit of a confirmation effect becomes a helper
call. No other behavior changes.

- `case .closeTab` line 100: `return emitTerminateConfirmation(&model)`
- `case .closePane` line 186: `return emitTerminateConfirmation(&model)`
- `case .requestQuit` line 844: `return emitTerminateConfirmation(&model)`
- `case .deleteGroup` line 937: `return emitTerminateConfirmation(&model)`
- `case .requestCloseTab` line 91:
  `return emitCloseTabConfirmation(&model, tabId: id, tabTitle: tab.displayTitle, paneCount: paneCount, isLastTab: isLastTab)`

Update the dismissal handlers at lines 914-918:

```swift
case .confirmTerminate:
    model.pendingConfirmation = nil
    return [.terminate]

case .cancelTerminate:
    model.pendingConfirmation = nil
    return []
```

## New `Msg` cases for close-tab dismissal symmetry

The close-tab confirmation is currently asymmetric: AppRuntime sends
`.closeTab(id:)` on confirm and **nothing** on cancel
(`app/AppRuntime.swift:355-365`). With a slot to clear, the cancel
path must explicitly fire a Msg, so introduce two new Msgs in
`app/Msg.swift` next to `.confirmTerminate` / `.cancelTerminate`:

```swift
case confirmCloseTab(id: TabId)
case cancelCloseTab
```

Handle them in `app/Update.swift` next to the terminate handlers:

```swift
case .confirmCloseTab(let id):
    model.pendingConfirmation = nil
    return update(&model, .closeTab(id: id))

case .cancelCloseTab:
    model.pendingConfirmation = nil
    return []
```

## AppRuntime wiring (`app/AppRuntime.swift:344-390`)

`case .showCloseTabConfirmation:` -- both the `beginSheetModal` and
`runModal` (no-window fallback) branches replace their inline send
calls with the new mapper, so the same wiring covers both paths and
the cancel branch can never silently drop the Msg again:

```swift
let isConfirm = response == .alertFirstButtonReturn
self?.send(closeTabConfirmationResponse(isConfirm: isConfirm, tabId: tabId))
```

`case .showTerminateConfirmation:` already sends `.confirmTerminate`
on confirm and `.cancelTerminate` on cancel for both modal paths
(lines 376-389), so no AppRuntime change is needed there beyond
verifying the cancel branches still fire the cancel Msg on the edit.

## Snapshot / persistence implications

`AppModelSnapshot` (`app/Model.swift:199-203`) encodes only `groups`,
`panes`, and `selectedTabId`. Adding the `pendingConfirmation`
ephemeral to `AppModel` does not change `toSnapshot`
(`app/ModelOperations.swift:556-609`), the `Codable` payload, or
`validateAndBuildDetailed`. No schema bump, no migration, no
checkpoint changes. A crash mid-confirmation is forgotten on restart,
which is correct (no sheet exists post-restart, so there's nothing to
track).

## Risks

- **Sheet completion handler never fires.** If `AppRuntime` were
  deallocated before the sheet completes (`[weak self]` captures nil)
  or AppKit dismissed the sheet without invoking the handler
  (programmatic `NSApp.endSheet`), the slot would stick non-nil and
  every future `.requestQuit` / `.requestCloseTab` would no-op. In
  practice DanTerm has exactly one `AppRuntime` for the app lifetime
  and never calls `endSheet` programmatically, so this is theoretical.
  Acceptable for this fix; recovery is `kill <pid>`, and the next
  launch starts with `pendingConfirmation == nil` because it isn't
  persisted.
- **Behavioral asymmetry for close-tab confirm.** Previously the
  AppRuntime confirm-button handler called `send(.closeTab(id:))`
  directly. After this change it sends `.confirmCloseTab(id:)` which
  recurses into `.closeTab`. Functionally identical for a single
  dispatch; the only observable difference is one extra Msg in the
  trace. No existing test pins down which Msg the runtime sends, so
  no breakage expected.

## Out of scope (deferred)

A `confirm-on-quit = true|false` config flag (some users prefer
immediate quit on Cmd+Q with no sheet at all) is logically separate
from this re-entrancy fix. Tracking it here would tangle two
unrelated decisions in one diff: the flag-based guard is purely
defensive against re-entry, while skipping the sheet entirely is a
UX preference. Defer to a follow-up plan once this fix lands.
