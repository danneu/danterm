# MRU Tab Switcher

## Context

When many DanTerm tabs are open, the user jumps between them based on
notifications/bells but loses track of which tab they were on before the current
one. The user wants a "cmd-tab style" switcher: hold a modifier, tap a key to
walk back through a history of recently-used tabs, release the modifier to
commit and refocus the chosen tab.

Goals:

- Maintain an MRU (most-recently-used) ordering of tabs, **one entry per tab**
  (changing pane within a tab does not create a new MRU entry).
- Bind **`cmd-shift-o` (older, primary)** and **`cmd-shift-i` (newer, reverse)**
  to step through the MRU. cmd-shift-o is the dominant key, mirroring cmd-tab;
  cmd-shift-i mirrors cmd-shift-tab.
- Show a small, fast vertical list overlay while the modifier is held.
- Release `cmd` or `shift` -> commit (focus chosen tab, move it to MRU front).
- `Escape` -> cancel (no reorder, no focus change).
- While cycling, the MRU order is **frozen** so repeated taps actually walk the
  history instead of toggling between two tabs.
- **Full Cmd-Tab parity for cursor movement**: the cursor wraps in both
  directions, both on summon and mid-cycle.
  - First cmd-shift-o from idle: cursor lands on **index 1** (next-most-recent).
  - First cmd-shift-i from idle: cursor lands on **last index** (least-recently-used).
  - Stepping past either end wraps around.
- MRU is ephemeral: rebuilt at launch from current tab order, never persisted.

## Design summary

Pure state lives on `AppModel` and is updated by new `Msg` cases handled in
`Update.swift`. The switcher overlay is an `NSPanel` with `.nonactivatingPanel`
style, prebuilt at launch and just shown/hidden -- this is the same pattern
used by AltTab/HopTab/BetterTabbing and avoids first-frame latency. Modifier
release detection uses `NSEvent.addLocalMonitorForEvents` (existing menu
keyEquivalents cannot observe `flagsChanged`).

## Model changes

`app/Model.swift` (currently AppModel at line 132-144) -- add two ephemeral
fields, both excluded from `AppModelSnapshot`:

```swift
// MRU ordering of tabs. Index 0 = most recently used. Rebuilt from current
// tab ordering on app launch (see AppRuntime initialization).
var mruOrder: [TabId] = []

// Non-nil while the user is holding the cycle modifier. While set, mruOrder
// must NOT be reordered on selectTab; cursorIndex moves through frozenOrder
// and a final commit applies the reorder.
var mruCycle: MruCycleState? = nil
```

```swift
struct MruCycleState: Equatable {
    let frozenOrder: [TabId]   // snapshot of mruOrder at cycle start
    var cursorIndex: Int       // 0 = current tab, 1 = previous, etc.
}
```

Notes:

- Don't touch `AppModelSnapshot` / `toSnapshot()` / `validateAndBuild()`. Keep
  the snapshot version at 1.
- After `validateAndBuild()` returns, AppRuntime initializes `mruOrder` to the
  list of all live tab IDs in display order, with `selectedTabId` (if any)
  moved to the front.

## Msg additions (`app/Msg.swift`)

```swift
case mruCycleStepped(direction: MruDirection)   // hold path: tapped cmd-shift-i/-o
case mruCycleCommitted                           // hold path: released cmd or shift
case mruCycleCanceled                            // pressed Esc while cycling
case mruCycleOneShot(direction: MruDirection)   // menu fallback: step + commit atomically
```

```swift
enum MruDirection { case older, newer }
```

`older` advances cursorIndex (toward less-recently-used). `newer` retreats it.

## Effect additions (`app/Effect.swift`)

```swift
case showSwitcherOverlay     // ensure panel is visible and redrawn from model
case hideSwitcherOverlay     // ordering panel out
```

`showSwitcherOverlay` is idempotent; emit it on every step. `hideSwitcherOverlay`
fires on commit/cancel.

## Update logic (`app/Update.swift`)

### Single chokepoint: `reconcileMru(&model)`

Many handlers mutate tab membership and `selectedTabId` without going through
`.selectTab` / `.closeTab` -- including `movePaneToTab` (Update.swift:304,
sourceTab removal), `movePaneToNewTab` (Update.swift:386, new tab created),
`surfaceCreationFailed` (Update.swift:745-751, tab removed if last pane fails),
`deleteGroup` (Update.swift:875-900), and any restore/import that replaces the
model. Sprinkling MRU updates across all of these is fragile.

Instead, add one pure helper in `app/ModelOperations.swift` and call it once
at the bottom of `update(&model:msg:)` before returning effects:

```swift
// Idempotent. Rebuilds mruOrder as a live-only, deduplicated list preserving
// existing recency, then appends any live tab not yet present (at the back);
// when not cycling, hoists selectedTabId to index 0 so mruOrder[0] always
// equals the focused tab. Enforces the "one entry per tab" invariant even
// if duplicates somehow leaked in.
func reconcileMru(_ model: inout AppModel) {
    let liveTabs = Set(model.groups.flatMap(\.tabs).map(\.id))
    var seen = Set<TabId>()
    var rebuilt: [TabId] = []
    for tabId in model.mruOrder {
        guard liveTabs.contains(tabId), seen.insert(tabId).inserted else { continue }
        rebuilt.append(tabId)
    }
    for tab in model.groups.flatMap(\.tabs) where !seen.contains(tab.id) {
        rebuilt.append(tab.id)
        seen.insert(tab.id)
    }
    model.mruOrder = rebuilt
    if model.mruCycle == nil, let sel = model.selectedTabId {
        moveToFront(&model.mruOrder, sel)
    }
}
```

Call site: **`defer { reconcileMru(&model) }` at the very top of `update()`,
before the switch.** Each case in the current `update()` (`app/Update.swift:18`
onward) returns its `[Effect]` directly from inside the switch arm
(e.g. line 1094), so code placed *after* the switch would never execute.
`defer` runs after the case's `return`, and because `model` is `inout`, the
caller still sees the reconciled state. This is the single invariant
chokepoint -- no individual handler needs to know about MRU.

**Restore/import:** `update()` is bypassed when AppRuntime replaces the model
wholesale. Audit found exactly two direct write sites:
- `AppRuntime.swift:49` -- initial `self.model = AppModel(...)` in init.
  Already covered by the "initialize MRU at startup" step below.
- `AppRuntime.swift:861` -- `model = staged.model` inside
  `commitRestoreSession(_:)`. Add an explicit `reconcileMru(&self.model)`
  call **immediately after the assignment**, before
  `refreshContentTitlebar()` / `rebuildContentView()` / `sidebarView?.reload`.

These are the only two non-`update()` model writes. This guarantees the
first switcher invocation after launch or restore sees a populated
`mruOrder`.

This also handles `createTab` and `closeTab` for free (the new tab gets
appended/hoisted; the closed tab gets pruned), so those handlers need no
direct edits.

### Pure helper: `resolveLiveCycle`

Tabs can be removed *while the cycle is active and the overlay is on screen*
(via `closeTab`, `surfaceCreationFailed`, last-pane `closePane`, or external
automation). `reconcileMru` only touches `mruOrder` -- `frozenOrder` stays
frozen by design so cycling is stable. That means both the commit handler
and the panel renderer need to project `frozenOrder` through the current
live tab set, with the cursor remapped sensibly. Add to
`app/ModelOperations.swift`:

```swift
struct ResolvedCycle: Equatable {
    var liveOrder: [TabId]   // frozenOrder filtered to currently-live tabs
    var cursorIndex: Int     // index into liveOrder; valid because liveOrder is non-empty
}

// Pure. Returns nil iff every tab in frozenOrder has been removed.
// Cursor remap rules:
//   1. If the original cursor target id is still live, point to its new index.
//   2. Otherwise, walk backward from the original cursor through frozenOrder
//      to the nearest preceding live id (so the highlight does not skip
//      forward past the user's intent).
//   3. If no preceding live id exists, fall back to liveOrder index 0.
func resolveLiveCycle(_ cycle: MruCycleState, in model: AppModel) -> ResolvedCycle?
```

Both `.mruCycleCommitted` and `SwitcherPanel.render(from:)` route through
this helper, never reading `frozenOrder` / `cursorIndex` directly.

### Cycle handlers (new)

- `.mruCycleStepped(direction:)`:
  - **If `mruOrder.isEmpty`, return `[]`** -- nothing to cycle through.
    Avoids modulo-by-zero in the wraparound math below.
  - If `mruCycle == nil`: start a cycle with `frozenOrder = mruOrder`,
    `cursorIndex = 0` (sentinel for "current tab"); the step below moves it.
  - Apply the step with **wraparound in both directions**, full Cmd-Tab parity:
    - `.older`: `cursorIndex = (cursorIndex + 1) % count`
    - `.newer`: `cursorIndex = (cursorIndex - 1 + count) % count`
  - Net effect:
    - First `.older` from idle: 0 -> 1 (next-most-recent).
    - First `.newer` from idle: 0 -> `count - 1` (least-recently-used; like cmd-shift-tab).
    - Mid-cycle past either end: wraps around.
  - Emit `showSwitcherOverlay`.
  - Do NOT call `selectTab` here. Focus only changes on commit.
- `.mruCycleCommitted`:
  - If `mruCycle == nil`, no-op.
  - Call `resolveLiveCycle(cycle, in: model)` (defined below). If it returns
    `nil` (no live tabs left), treat as cancel: clear `mruCycle`, emit
    `hideSwitcherOverlay`, return.
  - Read `chosenId = resolved.liveOrder[resolved.cursorIndex]`. Clear `mruCycle`.
  - If `chosenId != selectedTabId`, dispatch the existing `.selectTab(id:)`
    handler (extract its body into a private helper `applySelectTab(&model,
    id:)` returning `[Effect]` and reuse it from both call sites; do not
    duplicate the focus / rebuildContentView / scheduleCheckpoint logic).
  - Emit `hideSwitcherOverlay`. (The deferred chokepoint reconcile then
    hoists chosenId to MRU front automatically.)
- `.mruCycleCanceled`:
  - Clear `mruCycle`. Do not change focus. Emit `hideSwitcherOverlay`.
  - Reconcile is a no-op for ordering since `selectedTabId` did not change
    and cycle was just cleared (the hoist runs but `selectedTabId` is
    already at index 0 from before the cycle started).
- `.mruCycleOneShot(direction:)` (menu fallback):
  - Equivalent to `mruCycleStepped(direction)` immediately followed by
    `mruCycleCommitted`. Used by the Tab menu items so that even with no
    local NSEvent monitor installed, the menu actions still work as a
    one-tap "jump to N-th most recent tab" without leaving the overlay
    stuck open.

### Helper

Add to `app/ModelOperations.swift` (a pure helper, easy to unit-test):

```swift
func moveToFront<T: Equatable>(_ array: inout [T], _ value: T)
```

## AppRuntime changes (`app/AppRuntime.swift`)

1. **Initialize MRU at startup**: after model hydration, call
   `reconcileMru(&model)` once. The chokepoint already does the right thing
   (appends every live tab, hoists `selectedTabId` to front).
2. **Build switcher panel eagerly** at app launch (latency win -- pay
   first-frame cost once). Store as `var switcherPanel: SwitcherPanel?`.
3. **Pure event classifier** in `app/ModelOperations.swift` -- truly pure,
   no AppKit imports, so tests run in the no-Cocoa target. Domain-native
   types only:

   ```swift
   enum SwitcherInputKind: Equatable {
       case keyDown(keyCode: UInt16)
       case flagsChanged
   }

   struct SwitcherModifiers: OptionSet, Hashable {
       let rawValue: Int
       static let command = SwitcherModifiers(rawValue: 1 << 0)
       static let shift   = SwitcherModifiers(rawValue: 1 << 1)
       static let option  = SwitcherModifiers(rawValue: 1 << 2)
       static let control = SwitcherModifiers(rawValue: 1 << 3)
   }

   enum SwitcherAction: Equatable {
       case passthrough
       case stepOlder
       case stepNewer
       case cancel
       case commit
   }

   // Pure. No NSEvent. No Msg. Equatable cleanly. Testable in the
   // no-Cocoa target.
   func classifySwitcherInput(
       kind: SwitcherInputKind,
       modifiers: SwitcherModifiers,    // already normalized
       cycleActive: Bool
   ) -> SwitcherAction
   ```

   Rules (any non-`.passthrough` result is swallowed by the caller):
   - `.keyDown(0x1F)` (o) with `modifiers == [.command, .shift]` -> `.stepOlder` (primary).
   - `.keyDown(0x22)` (i) with `modifiers == [.command, .shift]` -> `.stepNewer` (reverse).
   - `.keyDown(0x35)` (Esc) with `cycleActive == true` -> `.cancel`.
   - `.flagsChanged` with `cycleActive == true` and
     `!modifiers.contains(.command) || !modifiers.contains(.shift)`
     -> `.commit`. (Releasing **either** required modifier commits.)
   - Otherwise: `.passthrough`. Critical: plain `i` / `o`, option-i, ctrl-i,
     extra-modifier `cmd-shift-opt-i`, inactive Esc, and partial flag
     changes when not cycling all pass through untouched so TerminalView
     keeps receiving normal input.

4. **Install one local NSEvent monitor** in AppRuntime init. AppKit-side
   adapter maps NSEvent to the domain-native types and the action back to
   `Msg`:

   ```swift
   NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
       let kind: SwitcherInputKind = (event.type == .keyDown)
           ? .keyDown(keyCode: event.keyCode)
           : .flagsChanged
       var mods: SwitcherModifiers = []
       let raw = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
       if raw.contains(.command) { mods.insert(.command) }
       if raw.contains(.shift)   { mods.insert(.shift) }
       if raw.contains(.option)  { mods.insert(.option) }
       if raw.contains(.control) { mods.insert(.control) }

       let action = classifySwitcherInput(
           kind: kind,
           modifiers: mods,
           cycleActive: self.model.mruCycle != nil
       )

       switch action {
       case .passthrough: return event
       case .stepOlder:   self.send(.mruCycleStepped(direction: .older));  return nil
       case .stepNewer:   self.send(.mruCycleStepped(direction: .newer));  return nil
       case .cancel:      self.send(.mruCycleCanceled);                    return nil
       case .commit:      self.send(.mruCycleCommitted);                   return nil
       }
   }
   ```

5. **Perform new effects**:
   - `showSwitcherOverlay`: position panel centered on the screen of the
     current keyWindow, call `panel.render(from: model)`,
     `panel.orderFront(nil)`. Do NOT call `makeKeyAndOrderFront` -- the panel
     is non-activating; calling it would steal first-responder.
   - `hideSwitcherOverlay`: `panel.orderOut(nil)`.

## New file: `app/SwitcherPanel.swift`

Top-of-file comment required by the project style: "Non-activating NSPanel
that renders the MRU tab switcher overlay. Built once at app launch, shown
and hidden via Effects driven by mruCycle state."

```swift
final class SwitcherPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 1),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        contentView = SwitcherContentView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func render(from model: AppModel) {
        guard
            let cycle = model.mruCycle,
            let resolved = resolveLiveCycle(cycle, in: model),
            let view = contentView as? SwitcherContentView
        else { return }

        // Render only live tabs, with the cursor remapped to the live order.
        // This keeps the highlight correct even if a tab was removed while
        // the overlay was visible.
        let rows = resolved.liveOrder.compactMap { tabId -> SwitcherRow? in
            guard let tab = tabById(tabId, in: model) else { return nil }
            return SwitcherRow(
                tabId: tabId,
                name: tab.displayTitle,
                color: tab.color,
                alertCount: unreadAlertCount(for: tab, alerts: model.alerts)
            )
        }
        view.update(rows: rows, cursorIndex: resolved.cursorIndex)

        let height = max(1, CGFloat(rows.count) * SwitcherContentView.rowHeight
                          + SwitcherContentView.padding * 2)
        setContentSize(NSSize(width: 320, height: height))
    }
}
```

API references verified against the codebase:
- `tabById(_:in:)` -- ModelOperations.swift:319
- `TabModel.displayTitle` -- Model.swift:106
- `unreadAlertCount(for:alerts:)` -- ModelOperations.swift:501

`SwitcherContentView` is a plain `NSView` (not SwiftUI -- first-frame latency)
hosting an `NSStackView` of pre-allocated `SwitcherRowView` instances.
Background uses `NSVisualEffectView` with `.hudWindow` material -- copy the
config from `SearchOverlayView.swift:23-32` for visual consistency.

Render is O(N) string assignments; with N tabs in the dozens this is sub-ms.

## Menu items (`app/AppDelegate.swift`)

Add to the Tab menu (around line 263, near "Next Tab"):

- "Recent Tab (Older)" -- `cmd-shift-o` (primary) -- dispatches `mruCycleOneShot(.older)`
- "Recent Tab (Newer)" -- `cmd-shift-i` (reverse) -- dispatches `mruCycleOneShot(.newer)`

These provide discoverability and a working fallback. The local NSEvent
monitor consumes `cmd-shift-i/o` before menu equivalents fire under normal
operation, so the held-modifier path stays in charge. If the monitor is ever
removed or fails to install, the menu items take over with tap-and-jump
semantics (one-shot: step + immediate commit) -- not a stuck overlay.

## Tests

Match the style at `tests/UpdateTabTests.swift:6-21` (`update(&model, .msg)`
+ `hasEffect()` helper).

### `tests/UpdateMruTests.swift` (new)

MRU invariants:
- `selectTab` moves the selected tab to MRU index 0 when not cycling.
- `selectTab` does NOT reorder MRU when `mruCycle != nil`.
- `createTab` results in MRU containing the new tab id (post-reconcile).
- `closeTab` removes the tab from MRU.
- `paneBecameFirstResponder` does not change MRU order.

Reconciliation regression coverage (the chokepoint must catch all paths):
- `movePaneToTab` causing source-tab removal -- removed tab is pruned from
  MRU.
- `movePaneToNewTab` -- new tab id appears in MRU.
- `deleteGroup(moveTabs: false)` -- all deleted tab ids pruned; surviving
  selectedTabId hoisted to front.
- `deleteGroup(moveTabs: true)` -- moved tabs remain in MRU.
- `surfaceCreationFailed` causing tab removal (Update.swift:745-751) -- tab
  pruned from MRU.
- Restored / imported model: starting from a model where `mruOrder` is empty
  but tabs exist, after one `update()` cycle (any message), `mruOrder`
  contains every live tab and `selectedTabId` is at index 0.

Cycle handlers:
- `mruCycleStepped(.older)` with `mruOrder.isEmpty` returns `[]`, leaves
  `mruCycle` nil, emits no effects (regression: empty-MRU guard).
- `mruCycleStepped(.older)` from idle starts a cycle at cursorIndex 1, emits
  `showSwitcherOverlay`.
- `mruCycleStepped(.newer)` from idle wraps to the last index (cmd-shift-tab
  parity).
- Repeated `mruCycleStepped(.older)` advances; **wraps** past last back to 0.
- `mruCycleStepped(.newer)` retreats; **wraps** past 0 back to last.
- Single-tab MRU: stepping in either direction stays at index 0.
- `mruCycleCommitted` with cursorIndex > 0 emits the same effects as a
  direct `selectTab` (focusSurface, rebuildContentView, scheduleCheckpoint),
  emits `hideSwitcherOverlay`, and post-reconcile moves chosen tab to MRU
  front.
- `mruCycleCommitted` with cursorIndex == 0 is a focus no-op but still emits
  `hideSwitcherOverlay`.
- `mruCycleCanceled` clears `mruCycle`, does not change `selectedTabId`,
  emits `hideSwitcherOverlay`.
- `mruCycleOneShot(.older)` is equivalent to step + commit: focus changes
  in one message, no overlay state lingers.
- **Tab removed during an active cycle**: start cycle, advance cursor to
  index 2, then dispatch `closeTab` for the tab at index 2 (or
  `surfaceCreationFailed` for its only pane). Then dispatch
  `mruCycleCommitted`. Assert: commit filters dead ids out of `frozenOrder`,
  clamps cursor, and selects a *live* tab (or no-ops if list emptied).
  `selectedTabId` never points to a deleted id.
- **Restore reconciliation**: simulate a model where `mruOrder` is empty
  but multiple tabs exist (mimicking post-`commitRestoreSession` state, but
  exercised purely through the reconcile helper). After `reconcileMru`,
  assert `mruOrder` contains every live tab id and `selectedTabId` (if set)
  is at index 0.

### `tests/SwitcherEventTests.swift` (new) -- pure event classifier

`classifySwitcherInput` takes only domain-native types (no `NSEvent`,
no `Msg`), so this file imports nothing from AppKit and runs in the no-Cocoa
test target. Each case asserts the exact `SwitcherAction`:

- keyDown 'o' (0x1F) with `[.command, .shift]` -> `.stepOlder` (primary).
- keyDown 'i' (0x22) with `[.command, .shift]` -> `.stepNewer` (reverse).
- keyDown 'o' with `[.command]` only -> `.passthrough`.
- keyDown 'o' with `[.shift]` only -> `.passthrough`.
- keyDown 'o' with `[.command, .shift, .option]` -> `.passthrough` (extra mods).
- keyDown 'o' with no modifiers -> `.passthrough` (bare 'o' must reach terminal).
- keyDown 'i' with no modifiers -> `.passthrough`.
- keyDown other key (e.g. 0x00 'a') with `[.command, .shift]` -> `.passthrough`.
- keyDown Esc (0x35), cycleActive=false -> `.passthrough`.
- keyDown Esc, cycleActive=true -> `.cancel`.
- flagsChanged, cycleActive=false -> `.passthrough` (always).
- flagsChanged, cycleActive=true, modifiers=`[.command, .shift]`
  -> `.passthrough` (still holding both, no commit yet).
- flagsChanged, cycleActive=true, modifiers=`[.command]` -> `.commit`
  (released shift).
- flagsChanged, cycleActive=true, modifiers=`[.shift]` -> `.commit`
  (released cmd).
- flagsChanged, cycleActive=true, modifiers=`[]` -> `.commit` (released both).

### `tests/ModelOperationsTests.swift` (extend)

- `moveToFront`: empty array no-op; missing element no-op; existing element
  moves to index 0 once; idempotent if already at index 0.
- `reconcileMru`: full / empty / has-stale-id / missing-live-id / preserves
  order when nothing changes / does not hoist when `mruCycle != nil` /
  **deduplicates if the same TabId appears twice in `mruOrder`** (first
  occurrence wins, second is dropped) -- regression for the one-entry-per-tab
  invariant.
- `resolveLiveCycle`:
  - `frozenOrder=[A,B,C,D]`, `cursor=2`, all live -> `liveOrder=[A,B,C,D]`,
    `cursor=2`.
  - `frozenOrder=[A,B,C,D]`, `cursor=2`, B removed (cursor target C still
    live) -> `liveOrder=[A,C,D]`, `cursor=1` (target id pinned).
  - `frozenOrder=[A,B,C,D]`, `cursor=2`, C removed (cursor target gone) ->
    `liveOrder=[A,B,D]`, `cursor=1` (snapped back to B, the nearest
    preceding live id) -- regression for dead-id-at-or-before-cursor.
  - `frozenOrder=[A,B,C,D]`, `cursor=0`, A removed -> `liveOrder=[B,C,D]`,
    `cursor=0` (no preceding live id, falls back to 0).
  - `frozenOrder=[A]`, `cursor=0`, A removed -> `nil`.

## Critical files

| File | Change |
|------|--------|
| `app/Model.swift` | Add `mruOrder: [TabId]` and `mruCycle: MruCycleState?` fields, plus the `MruCycleState` struct |
| `app/Msg.swift` | Add 4 cases (`mruCycleStepped`, `mruCycleCommitted`, `mruCycleCanceled`, `mruCycleOneShot`) plus the `MruDirection` enum |
| `app/Effect.swift` | Add 2 cases |
| `app/Update.swift` | Extract `selectTab` body into `applySelectTab(&model, id:) -> [Effect]`; add 4 new cycle handlers; add `defer { reconcileMru(&model) }` at the **top** of `update()` (before the switch; each case returns from inside the switch arm) |
| `app/ModelOperations.swift` | Add `moveToFront`, `reconcileMru`, `resolveLiveCycle`, `classifySwitcherInput`, plus types `ResolvedCycle` / `SwitcherInputKind` / `SwitcherModifiers` / `SwitcherAction` |
| `app/AppRuntime.swift` | Init mruOrder; build panel; install NSEvent monitor; handle 2 new effects |
| `app/AppDelegate.swift` | Add 2 menu items in Tab menu (~line 263) |
| `app/SwitcherPanel.swift` | New file: NSPanel + content view |
| `tests/UpdateMruTests.swift` | New file (MRU invariants, reconcile coverage, cycle handlers) |
| `tests/SwitcherEventTests.swift` | New file (pure event classifier coverage) |
| `tests/ModelOperationsTests.swift` | Add `moveToFront` and `reconcileMru` tests |

## Verification

1. `just test` -- all new unit tests pass.
2. `just build-run` -- launches dev build into `~/Applications`.
3. Open ~6 tabs. Manually walk through:
   - Tap `cmd-shift-o`: panel appears, cursor highlights second-most-recent
     tab. Release cmd-shift -> that tab becomes focused, panel disappears.
   - Tap `cmd-shift-i`: panel appears, cursor highlights LAST entry
     (least-recently-used) -- wraparound on summon, like cmd-shift-tab.
   - Hold `cmd-shift`, tap `o` four times on a 6-tab list: cursor walks 1->2->3->4.
     Release -> 5th-most-recent tab focused.
   - Hold `cmd-shift`, tap `o` past the last entry: cursor wraps back to 0.
   - Hold `cmd-shift`, tap `o` twice, then `i` once: cursor net at row 1.
   - Hold `cmd-shift`, tap `o`, then Escape: panel disappears, focus did NOT
     change, MRU did NOT reorder (verify by retriggering -- previous order
     intact).
   - Click between tabs in the sidebar normally; verify clicking tab A then B
     then A makes `cmd-shift-o` jump to B (i.e. selectTab updates MRU when
     not cycling).
   - Split a pane within a tab; verify focusing the new pane does NOT change
     MRU order (retrigger cmd-shift-o and confirm).
4. Type normally in a terminal pane -- verify `i`, `o`, plain tab, and other
   keys reach Ghostty unchanged (the local monitor must only swallow on the
   exact cmd-shift-o / cmd-shift-i / cycle-active-Esc / cycle-active-flagsChanged
   matches).
5. Close DanTerm and reopen -- verify MRU starts fresh from current tab order
   (no persistence).
