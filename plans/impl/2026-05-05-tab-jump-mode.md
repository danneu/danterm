# Tab Jump Mode (cmd-shift-f)

## Context

Today, jumping to a non-adjacent tab in the sidebar requires either cmd-shift-i
(MRU cycle, only useful for very recent tabs) or repeated next/prev tab
keystrokes through every intermediate tab. With many tabs open, that's slow.

This feature adds a hint-mode style jump: cmd-shift-f shows a single-character
key badge on each visible sidebar tab row, and the next keystroke jumps focus
directly to that tab. The mapping is positional/deterministic so muscle memory
builds: the first visible tab is always `a`, the second always `s`, and so on
through the home row, top row, then bottom row (32 keys total). Tabs beyond
slot 32 get no badge.

The underlying key map remains lowercase so unshifted target keystrokes work,
but the visible sidebar badges render as uppercase letters on a
`controlAccentColor` background.

This is the v1 ship. Notable decisions:

- **QWERTY-only.** Keyboard locale detection (Carbon TIS) is deferred. On
  non-QWERTY layouts the rendered badge and the physical key the user must
  press will mismatch. Documented limitation for v1.
- **Visual slot, not logical slot.** Slot N = the N-th currently-visible row.
  Collapsed-group children get no badge. NSOutlineView's row indexing already
  enumerates only expanded rows, so this falls out for free.
- **Single-char labels only.** No 2-char recursion (easy-motion style). 32 is
  enough; beyond that, fuzzy switcher is the right tool.
- **Group header rows are not labeled.** Tabs only.

## Architecture fit

The MRU tab switcher (cmd-shift-i) is the structural template:

- App-level `NSEvent.addLocalMonitorForEvents` in `AppRuntime` intercepts
  keystrokes when an ephemeral mode flag in `AppModel` is non-nil
  (`AppRuntime.swift:78-107`, classifier in `ModelOperations.swift:934-959`).
- A pure classifier in `ModelOperations.swift` maps keycode + modifiers +
  active-flag to an action. Tested without Cocoa.
- Mode state lives on `AppModel` as an optional struct (like `mruCycle`,
  `Model.swift:143-167`). Never serialized.
- Activation/commit/cancel are three Msgs handled in `Update.swift`, returning
  Effects that show/hide overlay UI.

Jump mode mirrors this exactly, except the "overlay UI" is just a key-badge
view added to each sidebar tab cell -- no separate floating panel.

## Files to modify

### Pure logic (testable subset)

**`app/ModelOperations.swift`** -- add file-level helpers (matching the
existing file's style of top-level `let`/`func`, not static members of a
namespace type -- see lines 1-30 for the convention):

```swift
// MARK: - Tab Jump Mode

let jumpModeKeySequence: [Character] = Array("asdfghjkl;qwertyuiop[]zxcvbnm,./")

// Pure: assign a key per visible tab in order, capped at jumpModeKeySequence.count.
func assignJumpKeys(visibleTabs: [TabId]) -> [TabId: Character] { ... }
```

Add a jump-specific input kind alongside `SwitcherInputKind` (keycode alone
is insufficient -- the classifier needs the printable character to return
`.commit(char:)`):

```swift
enum JumpInputKind {
    case keyDown(keyCode: UInt16, character: Character?)  // character is the lowercased
                                                          // charactersIgnoringModifiers
    case flagsChanged
    case mouseDown
}
```

Add a sibling pure classifier `classifyJumpInput(kind:, modifiers:,
jumpActive:) -> JumpAction` distinct from `classifySwitcherInput`. Actions:

- `.activate` -- `.keyDown(keyCode: kVK_ANSI_F = 0x03, _)` with cmd+shift
  when `jumpActive: false`.
- `.commit(char: Character)` -- `.keyDown(_, character: c)` with no modifiers
  when `jumpActive: true` and `c` is non-nil.
- `.cancel` -- Escape `.keyDown`, **or** any `.keyDown` carrying cmd/option/
  control (and shift other than the implicit-shift case for `:`/`<`/`>`/`?`
  -- treat shift-bearing as cancel for v1) while `jumpActive: true`.
- `.passthrough` -- everything else, **including all `.flagsChanged` events**
  when `jumpActive: true`. This is critical: when the user releases the
  cmd/shift modifiers after activating jump mode, that release fires
  `.flagsChanged`. Jump mode must not classify modifier-only changes as
  cancel, or the mode self-destructs before the target keystroke arrives.

AppRuntime is responsible for constructing the `JumpInputKind` from the raw
NSEvent (extracting `event.charactersIgnoringModifiers?.lowercased().first`
into the `character` field) before calling the classifier. The classifier
remains pure and testable.

**`app/Model.swift`** -- add ephemeral state. **Must conform to Equatable**
because `AppModel: Equatable` (`Model.swift:154`) -- without it, synthesized
equality breaks:

```swift
struct JumpModeState: Equatable {
    let keyMap: [TabId: Character]   // built at activation time
}
var jumpMode: JumpModeState? = nil   // alongside mruCycle
```

**`app/Msg.swift`** -- add three cases:

- `.jumpModeActivated(visibleTabs: [TabId])` -- runtime supplies the visible
  order; update() calls `assignJumpKeys` and stores the result.
- `.jumpModeKeyPressed(char: Character)` -- update() looks up tab in keyMap;
  if found, clears jumpMode and routes to `.selectTab`; if not found, clears
  jumpMode (cancel-and-discard, no passthrough -- matches leap.nvim).
- `.jumpModeCanceled` -- escape or window-deactivation.

**`app/Update.swift`** -- handle the three Msgs. Effects to emit:

- On `.jumpModeActivated`: **first, force-cancel any active MRU cycle** to
  avoid overlap (the MRU switcher and jump mode are mutually exclusive
  ephemeral modes). If `model.mruCycle != nil`, set it to nil and append
  `.hideSwitcherOverlay` to the returned effects -- without this, a still-
  active MRU cycle will (a) suppress selectedTab hoist via `reconcileMru`
  (`ModelOperations.swift:850`), and (b) still commit on subsequent
  modifier release (`Update.swift:1269`), overriding the jump-selected
  tab. After clearing MRU state, populate `model.jumpMode` and append the
  sidebar-reload effect so badges render.
- On `.jumpModeKeyPressed`: clear `model.jumpMode` first, then look up the
  char in the captured keyMap. If a `TabId` is found, **also verify the tab
  still exists** with `tabLocation(targetId, in: model) != nil` (the keyMap
  is frozen at activation; a tab could close between activation and
  keypress -- without this guard, `applySelectTab` happily assigns
  `model.selectedTabId` to a deleted tab id, since
  `applySelectTab` (`Update.swift:1246`) does not verify existence). If
  the tab is stale or the char is unmapped, return only the sidebar-reload
  effect with no selection change. If the tab is live, fold in the result
  of internally invoking `applySelectTab(id:)`; **always** append the
  sidebar-reload effect, even when `applySelectTab` returns no effects (it
  short-circuits when the target tab is already selected -- without an
  explicit reload, badges stay onscreen with stale model state).
- On `.jumpModeCanceled`: clear `model.jumpMode`, return the sidebar-reload
  effect.
- **Extend the existing `.appResignedActive` handler** (`Update.swift:858`,
  triggered from `AppDelegate.swift:662`): when `model.jumpMode != nil` at
  the moment the app loses focus, also clear `model.jumpMode` and append
  the sidebar-reload effect. Without this, switching apps mid-jump leaves
  badges visible forever.

Rule for tests and implementation: **every code path that exits jump mode
returns a sidebar-reload effect.** Assert this explicitly in update tests.

### UI / runtime wiring

**`app/AppRuntime.swift`** -- extend `installSwitcherEventMonitor` (line 78):

- **Extend the monitor's event mask** to include `.leftMouseDown`,
  `.rightMouseDown`, and `.otherMouseDown` in addition to the existing
  `.keyDown` and `.flagsChanged`. Required for click-outside cancellation
  (the existing mask receives only key/flag events).
- When `model.jumpMode != nil` and the event is `.keyDown`: feed
  `event.charactersIgnoringModifiers` lowercased and the modifier flags
  through `classifyJumpInput`. Dispatch `.jumpModeKeyPressed(char)`,
  `.jumpModeCanceled`, or pass through accordingly. Eat the event (return
  nil) for commit/cancel; let passthrough events flow.
- When `model.jumpMode != nil` and the event is `.flagsChanged`: classifier
  returns passthrough; do not dispatch anything. Return the event so other
  monitors/responders see it.
- When `model.jumpMode != nil` and the event is a mouse-down: hit-test
  against the sidebar (see SidebarView API below). If the click landed on
  a sidebar row, that row's normal click handler will dispatch
  `.selectTab` -- still dispatch `.jumpModeCanceled` and **return the
  event** so the click activates the tab normally. If the click landed
  outside the sidebar, dispatch `.jumpModeCanceled` and return the event.
- When activating jump mode (from menu or shortcut): call the new
  `SidebarView.visibleTabIdsInRowOrder()` API (below) to get the visible
  tab list, then dispatch `.jumpModeActivated(visibleTabs:)`.

**`app/AppDelegate.swift`** -- add Tab menu item near line 281:

```swift
let jumpItem = NSMenuItem(title: "Jump to Tab...", action: #selector(jumpToTab(_:)), keyEquivalent: "f")
jumpItem.keyEquivalentModifierMask = [.command, .shift]
tabMenu.addItem(jumpItem)
```

`@objc func jumpToTab(_ sender: Any?)` asks the runtime to enter jump mode
(runtime then queries the sidebar and dispatches `.jumpModeActivated`).
The menu item gives macOS-native discoverability and Help-menu search; no
overlap with cmd-f (Find) since that's already bound to scrollback search.

**`app/SidebarView.swift`** --

Add a public API so `AppRuntime` and `AppDelegate` don't need to reach into
the private `outlineView` (`SidebarView.swift:147`):

```swift
// Public: returns the currently-visible tab ids in top-to-bottom row order.
// Group rows and collapsed-group children are excluded.
func visibleTabIdsInRowOrder() -> [TabId]

// Public: returns true if the given screen point lands on this sidebar.
// Used by AppRuntime for click-outside detection during jump mode.
func containsScreenPoint(_ point: NSPoint) -> Bool
```

Both implementations live inside `SidebarView` and use the existing private
`outlineView` reference -- no encapsulation break.

Modify `configureTabCell` (around line 1167). **The badge update must be
idempotent**: this method is reused for in-place row refreshes from
`updateTabRow` (`SidebarView.swift:361`) on alerts, title changes, etc.
A naive "addArrangedSubview every call" stacks duplicate badges:

- Define a stable identifier (e.g. `NSUserInterfaceItemIdentifier("jumpModeBadge")`).
- At the top of badge-handling: look for an existing arranged subview in
  `accessoryStack` matching that identifier. Reuse if found.
- When `model.jumpMode != nil` and this tab's id is in `jumpMode.keyMap`:
  ensure exactly one badge exists (create with the identifier if missing,
  reuse otherwise), render its mapped character uppercase on a
  `controlAccentColor` background, ensure it is the **trailing** arranged
  subview (use `accessoryStack.insertArrangedSubview` with the correct index, or
  `removeArrangedSubview` + `addArrangedSubview` to re-anchor).
- When `model.jumpMode == nil`, this tab's id is unmapped, or the tab is
  beyond slot 32: if a badge with that identifier exists in
  `accessoryStack`, remove it (and remove from view hierarchy); otherwise
  do nothing.
- For tabs beyond slot 32 (no key in keyMap): no badge. Optionally dim the
  row's title alpha to signal "no jump available" -- defer to taste.

### Tests

**`tests/TestHarness.swift`** -- if any new test file is created (see
below), register its top-level entry function in `TestRunner.main()`.
Test discovery is manual; missing the registration silently runs zero
tests in the new file (`TestHarness.swift:5`, also documented in the
exploration report).

**`tests/ModelOperationsTests.swift`** -- new section:

- `assignJumpKeys([])` returns `[:]`.
- `assignJumpKeys` with N <= 32 tabs returns expected `[TabId: Character]`
  matching the documented sequence.
- `assignJumpKeys` with N > 32 tabs returns exactly 32 entries, the rest
  unmapped.

**`tests/SwitcherEventTests.swift`** (or new `JumpEventTests.swift`) --
mirror existing classifier tests:

- cmd+shift+F (`.keyDown`) with `jumpActive: false` returns `.activate`.
- Plain `a` (`.keyDown`, no modifiers) with `jumpActive: true` returns
  `.commit(char: "a")`.
- Escape (`.keyDown`) with `jumpActive: true` returns `.cancel`.
- A modifier-bearing `.keyDown` (e.g. cmd+a) with `jumpActive: true`
  returns `.cancel`.
- **A `.flagsChanged` event with `jumpActive: true` returns `.passthrough`**
  -- this guards the cmd/shift release-after-activation regression.
- A bare `.keyDown` for the F key with `jumpActive: true` returns
  `.commit(char: "f")` (i.e., does not re-trigger activation when already
  in jump mode).

**`tests/UpdateTabTests.swift`** (or new `UpdateJumpTests.swift`) -- mirror
the MRU cycle tests. **If you add a new test file**, you must also register
its top-level test function in `tests/TestHarness.swift` (test discovery is
manual -- see `TestHarness.swift:5`; an unregistered file silently runs
zero tests):

- `.jumpModeActivated(visibleTabs:)` populates `model.jumpMode.keyMap`
  with `assignJumpKeys` output and returns the sidebar-reload Effect.
- **`.jumpModeActivated(visibleTabs:)` while `model.mruCycle != nil`**
  clears `model.mruCycle`, populates `model.jumpMode`, and returns
  Effects that include both `.hideSwitcherOverlay` and the sidebar-reload
  Effect. Guards the MRU-overlap regression.
- `.jumpModeKeyPressed("a")` with three tabs visible selects the first tab,
  clears `model.jumpMode`, returns Effects that include the sidebar-reload
  Effect (in addition to whatever `applySelectTab` returned).
- **`.jumpModeKeyPressed("a")` when the keyed tab is already the selected
  tab still returns the sidebar-reload Effect** (the
  `applySelectTab`-no-op-path regression -- without this, badges remain
  onscreen with stale model state).
- `.jumpModeKeyPressed("z")` (key beyond what's mapped given few tabs)
  clears `model.jumpMode` without changing `model.selectedTabId` and
  returns the sidebar-reload Effect.
- **`.jumpModeKeyPressed("a")` after the keyMap-mapped tab has been
  removed from the model** (simulate by deleting the tab between
  activation and keypress): clears `model.jumpMode`, leaves
  `model.selectedTabId` unchanged, returns only the sidebar-reload
  Effect. Guards against the stale-tab-id regression in
  `applySelectTab`.
- `.jumpModeCanceled` clears `model.jumpMode` without selection change
  and returns the sidebar-reload Effect.
- **`.appResignedActive` while `model.jumpMode != nil`** clears
  `model.jumpMode` and returns Effects that include the sidebar-reload
  Effect (regression guard for app-switch-during-jump).
- **`.appResignedActive` while `model.jumpMode == nil`** behaves as
  before -- no jump-mode-related Effects emitted (guards against
  unintentional sidebar reloads on every app switch).

## Existing functions/utilities reused

- `TabId.selectTab` Msg path (`Msg.swift:26`, `SidebarView.swift:498`) --
  the canonical activation. Don't reinvent.
- `classifySwitcherInput` pattern (`ModelOperations.swift:934-959`) --
  pure key classifier; extend or sibling.
- `NSEvent` local monitor in `AppRuntime.installSwitcherEventMonitor`
  (`AppRuntime.swift:78-107`) -- extend with a jump-mode branch.
- `accessoryStack` in `TabCell` (`SidebarView.swift:1120-1128`) -- existing
  trailing-edge stack for badges; just add a new element.
- `outlineView.numberOfRows` + `outlineView.item(atRow:)` for visible-row
  enumeration (already used at `SidebarView.swift:74,104,1185`).

## Verification

1. `just test` -- pure tests pass for `assignJumpKeys`, classifier, and
   update logic.
2. `just build-run` -- launches dev build.
3. Manual end-to-end:
   - Open 5+ tabs across multiple groups.
   - cmd-shift-f: accent-colored badges appear on every visible tab. Verify
     slot 1 displays `A`, slot 2 displays `S`, ..., slot 10 displays `;`.
   - Press unshifted `g` (slot 5): focus jumps to that tab; badges disappear;
     the ghostty pane has keyboard focus.
   - **Hold cmd-shift-f, release cmd and shift, *then* press the target
     key.** Badges must still be visible after the modifier release;
     jump mode must not self-cancel on `.flagsChanged`.
   - **Press the badge key for the tab that is already focused.** Badges
     must clear; selection unchanged is fine, but no stale badges.
   - cmd-shift-f, then Escape: badges appear and then disappear with no
     selection change.
   - cmd-shift-f, then a key that's not assigned (e.g. type `1`): jump
     mode cancels, no selection change, the `1` is NOT sent to the focused
     terminal.
   - **cmd-shift-f, then click somewhere outside the sidebar** (e.g. on
     the terminal pane): jump mode cancels, badges clear, the click is
     delivered to the terminal pane normally (focus moves to the clicked
     pane if applicable).
   - **cmd-shift-f, then click a sidebar tab row directly:** jump mode
     cancels and the click selects that tab via the normal click path.
   - Collapse a group containing the currently-keyed tab, re-enter
     jump mode: keys re-assign to the new visible row order.
   - Open >32 tabs: only the first 32 visible rows have badges.
   - **cmd-shift-f, then switch to another app via cmd-tab:** badges
     clear; on returning, no stale jump state remains.
   - Verify cmd-f (Find) and cmd-shift-i (MRU) still work unchanged.

## Out of scope (v1)

- Non-QWERTY keyboard layouts (need Carbon TIS lookup; defer).
- 2-char labels for >32 tabs (defer; fuzzy switcher would be the better
  long-term answer).
- Labeling group-header rows.
- Sticky per-tab keys that survive reordering.
