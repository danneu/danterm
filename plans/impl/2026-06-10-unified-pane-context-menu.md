# Unify pane context menus into PaneWrapperView.makePaneMenu()

## Context

DanTerm has two hand-built pane context menus that have drifted apart:

- **Surface right-click**: `TerminalView.menu(for:)` (`app/TerminalView.swift:285-330`)
  builds Copy (only if selection) / Paste / Split Right / Split Down / Close Pane
  inline, wrapped in ghostty-specific event handshaking (consumed-right-click
  check, ctrl+click synthetic `GHOSTTY_MOUSE_RIGHT` press).
- **Toolbar menu**: `PaneWrapperView.makePaneMenu()` (`app/PaneWrapperView.swift:420-467`)
  builds Split Right / Split Down / Copy cwd / Copy Agent Session ID / Zoom /
  Close Pane. Consumed by the "..." button (`showPaneMenu`, line 469) and by
  `ToolbarDragHandleView` via its `paneMenuProvider` closure (lines 228, 528).

The duplication means Split/Close exist twice, and the surface menu lacks
Copy cwd / agent session / Zoom. Goal: one builder, `makePaneMenu()`, serving
all three entry points. Per user decision:

- **Clipboard items (Copy/Paste) appear only on the surface right-click menu**,
  via a `makePaneMenu(includeClipboard:)` parameter. Toolbar menus keep their
  current shape; the surface menu gains Copy cwd, Copy Agent Session ID, and
  Zoom.
- **Full TDD**: promote the real `PaneWrapperView` into the `tests-ui` harness
  and write failing menu-composition tests first.

Review rounds added two corrections: menu items must strongly retain the
ephemeral wrapper (`NSMenuItem.target` is weak), and two core messages the
menu sends (`.toggleZoomPane`, `.closePane`) must become pane-scoped like
`.splitPane` already is -- which also fixes a pre-existing ghost-pane bug
when a background tab's shell exits.

## Key facts (verified)

- `TerminalView` already holds `weak var paneWrapper: PaneWrapperView?`
  (`app/TerminalView.swift:32`), set in `PaneWrapperView.init` (line 92) and
  cleared in its `deinit` with an `=== self` guard (lines 303-304). So **no new
  provider closure is needed**: `menu(for:)` returns
  `paneWrapper?.makePaneMenu(includeClipboard: true)`. No new lifetime surface.
- Lifetime is safe at menu-build time: `TerminalView`s persist across
  reconciles (in `AppRuntime.surfaces`); wrappers are ephemeral and re-point
  `paneWrapper` in init. Rebuilds are synchronous on the main thread, so no
  mouse event can observe a nil wrapper mid-rebuild; worst case `menu(for:)`
  returns nil (no menu pops).
- Lifetime is NOT free while the menu is open: `NSMenuItem.target` is `weak`
  (`representedObject` is `strong`) -- verified in the macOS SDK
  `NSMenuItem.h:94/99`. If a reconcile rebuilds the wrapper while its menu is
  tracking, weak wrapper targets nil out and actions become silent no-ops.
  This is a latent bug in today's toolbar menu too. Fix: every
  wrapper-targeted item sets `representedObject = self` so the item strongly
  retains the wrapper for the menu's lifetime. Clipboard items target the
  persistent `terminalView` and don't need the anchor.
- Not every wrapper-sent message is pane-scoped in the pure update today, so
  a retained stale menu firing after a selection change could hit the wrong
  tab: `.toggleZoomPane` carries no paneId and always toggles the selected
  tab (`Update.swift:1133-1143`), and `.closePane` resolves
  `selectedTab(in:)` (`Update.swift:205-246`) -- even though `.splitPane`
  already resolves the pane's own tab via `tabForPane(paneId, in:)`
  (`Update.swift:156-164`). Worse, the `.closePane` gap is reachable without
  any menu: `.surfaceClosed` (`Update.swift:791`) routes a background-tab
  pane's shell exit into `.closePane`, where `removeLeaf` on the selected
  tab's tree finds nothing and returns it unchanged
  (`ModelOperations.swift:176-182`) -- the dead pane stays as a ghost in its
  real tab and the selected tab's `isZoomed` gets clobbered. Fix in core
  (Phase 2b / step 7a): make both messages pane-scoped, mirroring
  `.splitPane`. After that, every wrapper menu action is pane-scoped and a
  stale menu's dispatch is *correct* -- it acts on the pane the user clicked,
  in that pane's own tab -- so no view-layer guard is needed. Copy cwd /
  agent session are pane-scoped reads already; clipboard items act on the
  persistent surface.
- `app/PaneWrapperView.swift:3` `import GhosttyKit` is vestigial (zero
  GhosttyKit symbols used) -- removing it lets the file compile in the
  tests-ui harness.
- `contextSplitRight`/`contextSplitDown`/`contextClosePane`
  (`app/TerminalView.swift:351-364`) are referenced only by the inline menu
  being deleted.
- The tests-ui harness (`test-ui.sh`) compiles a curated file list without
  GhosttyKit; `tests-ui/SidebarViewTestShim.swift` currently supplies a fake
  `PaneWrapperView`, fake `TerminalView`, fake `AppRuntime`, and a duplicate
  `paneDragType`. The real `TerminalView` can never enter the harness (needs
  GhosttyKit + live surface), so the one-line `menu(for:)` tail stays
  manual-smoke-only.

## Final menu shapes

`makePaneMenu(includeClipboard: Bool = false)`; `autoenablesItems = false`.

Surface right-click (`includeClipboard: true`):

| # | Item | Target / action | State |
|---|------|-----------------|-------|
| 1 | Copy | `terminalView` / `copySelection(_:)` | enabled iff `terminalView.hasSelection` (disabled, not hidden) |
| 2 | Paste | `terminalView` / `pasteClipboard(_:)` | enabled |
| 3 | separator | | |
| 4-11 | (same as toolbar menu below) | | |

Toolbar "..." button and toolbar right-click (`includeClipboard: false`, i.e.
unchanged from today):

Split Right / Split Down / separator / Copy cwd (enabled iff pane cwd != nil) /
Copy Agent Session ID (present only when `agentSession != nil`) / separator /
Zoom-or-Unzoom Pane (enabled iff `hasSplits || isZoomed`) / Close Pane.

Intended behavior change: surface right-click gains Copy cwd, Copy Agent
Session ID, Zoom; its Copy item changes from hidden-without-selection to
disabled-without-selection.

## Steps

### Phase 1 -- harness enablement (no app behavior change)

1. Remove `import GhosttyKit` from `app/PaneWrapperView.swift:3`. Confirm with
   `just build`.
2. `test-ui.sh`: add to the compile list `app/TodoToolbarButton.swift`,
   `app/SearchOverlayView.swift`, `app/PaneWrapperView.swift` (before
   `app/SplitContainerView.swift`), and the new
   `tests-ui/PaneWrapperViewTests.swift`.
3. `tests-ui/SidebarViewTestShim.swift`:
   - Delete the shim `class PaneWrapperView` and shim `let paneDragType`
     (both now come from the real file).
   - Extend the shim `TerminalView`: `weak var paneWrapper: PaneWrapperView?`,
     test-settable `var hasSelection = false`, and recording
     `@objc func copySelection(_:)` / `@objc func pasteClipboard(_:)`
     (append to a `var performedActions: [String]`).
   - Add a minimal `class ScrollableTerminalView: NSView` shim
     (`init(terminalView:)`).
   - Extend the shim `AppRuntime` with the drag API `ToolbarDragHandleView`
     compiles against: `startPaneDrag(paneId:)`, `updatePaneDrag(screenPoint:)`,
     `endPaneDrag()`, `currentPaneDrop() -> (source: PaneId, target: PaneId,
     intent: PaneDropIntent)?` returning nil (`PaneDropIntent` is core,
     already in the harness).
4. **Gate**: create `tests-ui/PaneWrapperViewTests.swift` with an empty
   `func paneWrapperViewTests()`, register it in `UITestRunner.main`
   (`tests-ui/PaneSplitViewTests.swift:10-16`). `just test-ui` must compile
   and all existing suites pass.

### Phase 1b -- API scaffolding (no behavior change)

The Phase 2/2b tests reference `makePaneMenu(includeClipboard:)` and
`.toggleZoomPane(paneId:)`, which don't exist yet. A compile error in the
single-swiftc UI harness or in the core test target runs *nothing*, so
without this step the red gates would degrade to "doesn't compile" and
"existing suites pass" would be unobservable. Scaffold the two API shapes
first -- with no behavior change -- so every new test fails *behaviorally*.

4b. Shape-only changes, all behavior identical:
    - `app/PaneWrapperView.swift`: `makePaneMenu` gains
      `includeClipboard: Bool = false`, ignored for now.
    - `lib/DanTermCore/Sources/DanTermCore/Msg.swift`:
      `case toggleZoomPane` -> `case toggleZoomPane(paneId: PaneId?)`.
      The update handler binds and ignores the value
      (`case .toggleZoomPane:` -> `case .toggleZoomPane(_):`); mechanical
      sweep of call sites to `.toggleZoomPane(paneId: nil)` --
      `app/AppDelegate.swift:467`, `PaneWrapperView.zoomPaneAction`
      (line 504), and core tests.
4c. **Gate**: `just test`, `just test-ui`, `just build` all green (pure
    scaffolding; nothing observable changed).

### Phase 2 -- failing tests first

5. Fill `tests-ui/PaneWrapperViewTests.swift` with behavioral `uiTest` cases
   (helper builds an `AppModel` with one group/tab/pane carrying the
   cwd/agentSession under test, shim `AppRuntime(model:)`, shim
   `TerminalView`, real `PaneWrapperView(paneId:terminalView:isZoomed:hasSplits:runtime:)`).
   Drive actions behaviorally via `item.target?.perform(item.action, with: item)`
   and assert on `runtime.sentMessages` / shim `performedActions` (the
   SplitContainerViewTests pattern) -- no target/selector identity assertions.
   Cases:
   1. `includeClipboard: true` with selection, cwd, agentSession, splits:
      non-separator titles are exactly [Copy, Paste, Split Right, Split Down,
      Copy cwd, Copy Agent Session ID, Zoom Pane, Close Pane], all enabled.
   2. `includeClipboard: true`, no selection: Copy present but disabled;
      item count identical to case 1 (shape stability).
   3. `includeClipboard: false` (and the no-arg default): no Copy/Paste items;
      otherwise same composition as today's toolbar menu.
   4. Action routing: Copy/Paste record `copySelection`/`pasteClipboard` on
      the shim terminal; Split Right sends `.splitPane(paneId:, .horizontal)`;
      Close Pane sends `.requestClosePane`; Zoom sends
      `.toggleZoomPane(paneId: paneId)` (pane-scoped per step 7a, not the
      menubar's nil form).
   5. Model-dependent items: nil cwd -> Copy cwd disabled; nil agentSession ->
      no agent item.
   6. Zoom states: `hasSplits:false,isZoomed:false` -> "Zoom Pane" disabled;
      `isZoomed:true` -> "Unzoom Pane" enabled.
   7. Wiring: after init, `terminalView.paneWrapper === wrapper`
      (already true today; pins the seam `menu(for:)` relies on).
   8. Menu survives wrapper teardown: construct the wrapper and build the
      menu inside `autoreleasepool { }` (AppKit init paths routinely
      autorelease view references; without the pool the wrapper can survive
      the nil-out and the pre-fix run would silently pass), keeping only the
      menu, a `weak var observer` on the wrapper, and the runtime/terminal
      refs alive outside the pool. After the pool drains, assert the
      observer is still non-nil -- the menu's items must now be the only
      retainers, which makes the pre-fix failure deterministic (weak-only
      target -> wrapper deallocs -> observer nil) -- then perform the Close
      Pane item and assert `.requestClosePane` arrives.
   Each test gets the AGENTS.md preamble (Intent / Why it exists / Scenario;
   all spec-first).
6. **Gate**: `just test-ui` -- everything compiles (the APIs were
   scaffolded in 4b); the new cases fail *behaviorally* for the expected
   reasons (`includeClipboard: true` adds no Copy/Paste items yet; the
   zoom item still sends `.toggleZoomPane(paneId: nil)`; case 8's weak
   observer goes nil with today's weak-only targets); existing suites
   pass.

### Phase 2b -- core pane-scoping tests (pure, runs in `just test`)

6b. Failing Swift Testing cases in `lib/DanTermCore/Tests/DanTermCoreTests/`
    (slot into the existing `UpdatePaneTests.swift` / `UpdateTabTests.swift`
    suites; AGENTS.md preambles -- the `.surfaceClosed` one is a bug-fix
    test whose Scenario names the background-tab shell-exit ghost):
    - `.closePane` for a pane in a non-selected tab removes the leaf from
      THAT tab's tree and leaves the selected tab (tree, `isZoomed`)
      untouched; when it was that tab's last pane, the close cascades to
      `.closeTab` of the pane's own tab, not the selected one.
    - `.surfaceClosed` for a background-tab pane removes the pane from its
      tab (pins the ghost-pane regression) and does not clear the selected
      tab's `isZoomed`.
    - `.toggleZoomPane(paneId:)` for a pane in a non-selected split tab
      toggles THAT tab's `isZoomed`; `paneId: nil` keeps today's
      selected-tab behavior (menubar path).
    - Alert preservation in focus mode: closing a background-tab pane (via
      `.closePane` or `.surfaceClosed`) leaves the successor pane's unread
      alert unread AND removes the closed pane from its tab's tree. The
      removal assertion is what makes this case red pre-fix: today the
      close no-ops against the wrong (selected) tab's tree -- `removeLeaf`
      misses, `nextFocus` is nil, so `markAlertsReadForPane` never fires
      (`Update.swift:211, 233-235`) and the alert leg alone would pass
      trivially. The alert assertion is the forward constraint on step
      7a's `tab.id == selectedTabId` gate. The same close on the selected
      tab still marks the successor's alerts read (pins today's
      selected-tab behavior).
    - Vanished pane is a pure no-op: `.closePane` for a paneId present in
      no tab returns `[]` and leaves the model unchanged -- including the
      selected tab's `isZoomed` and no `.scheduleCheckpoint` (pins step
      7a's guard-return branch, the fully-stale-menu case; today this
      input clobbers the selected tab's zoom and emits a checkpoint).
6c. **Gate**: `swift test --package-path lib/DanTermCore` -- everything
    compiles (the Msg shape exists since 4b; the other cases use existing
    messages); the new cases fail *behaviorally*: closePane/surfaceClosed
    cases hit the selected-tab resolution (ghost pane, clobbered zoom),
    the alert case fails on its pane-removal assertion (pre-fix the
    background close no-ops on the wrong tree, so the pane survives; its
    marked-read leg is green pre-fix and exists to constrain 7a's
    selectedTabId gate, not to go red here), the zoom case sees the
    selected tab toggled instead of the pane's tab, the vanished-pane
    case sees mutation instead of a no-op. Existing core suites pass.

### Phase 3 -- implementation

7a. Core pane-scoping (`lib/DanTermCore/Sources/DanTermCore/`; the Msg
    shape and call-site sweep already landed as scaffolding in 4b):
    - `Update.swift` `.toggleZoomPane`: bind the paneId (no longer ignore
      it); resolve `tabForPane(paneId, in: model)` when paneId is non-nil,
      else `selectedTab(in:)` (nil = selected tab, mirroring `.splitPane`'s
      optional paneId); mutate via `updateTab(tab.id, in: &model)` instead
      of `updateSelectedTab`.
    - `Update.swift` `.closePane`: resolve the pane's own tab via
      `tabForPane(paneId, in: model)` (mirror `.splitPane`, lines 156-164);
      guard-return `[]` when the pane is in no tab; use the found `tab.id`
      for the last-pane `.closeTab` cascade and `updateTab(tab.id, ...)`
      for the tree/zoom/focus mutation. Gate the focus-mode
      `markAlertsReadForPane(nextFocus)` (lines 233-235) on
      `tab.id == model.selectedTabId`: for a background tab the survivor
      never actually gains user-visible focus, so its unread alerts must
      survive the close -- they clear later through the existing
      tab-selection path (`Update.swift:2313-2314`) when the user views
      the tab.
    - **Gate**: `just test` -- Phase 2b cases pass, existing core suites pass.

7. `app/TerminalView.swift`:
   - Add near `paneWrapper` (line 32):
     `var hasSelection: Bool` -- guard `surface` non-nil, wrap
     `ghostty_surface_has_selection`. One-line doc comment: drives the
     context menu's Copy item.
   - In `menu(for:)`: keep lines 286-304 verbatim (surface guard,
     rightMouseDown pass-through, ctrl+click capture check + synthetic right
     press). Replace the inline construction (lines 306-329) with:
     ```swift
     // Unified pane context menu: one builder (PaneWrapperView.makePaneMenu)
     // serves surface right-click, the "..." toolbar button, and the
     // drag-handle right-click. Only this entry point includes clipboard items.
     return paneWrapper?.makePaneMenu(includeClipboard: true)
     ```
   - Delete `contextSplitRight`/`contextSplitDown`/`contextClosePane`
     (lines 351-364). Keep `copySelection`/`pasteClipboard` (335-348); they
     become makePaneMenu targets. Update the `// NSView:` comment above
     `menu(for:)` and the `// MARK: - Context Menu Actions` section comment.
8. `app/PaneWrapperView.swift`:
   - The `includeClipboard: Bool = false` parameter already exists -- it
     landed as ignored scaffolding in step 4b (toolbar call sites at lines
     228 and 470 stay as-is). The work here is implementing its body: the
     `wrapperItem` helper and the clipboard prepend below.
   - Retain the wrapper from its own items: `NSMenuItem.target` is weak, so a
     reconcile that rebuilds this ephemeral wrapper while the menu is tracking
     would nil the targets and turn actions into silent no-ops (latent in
     today's toolbar menu too). Add a local item helper, mirroring the one
     being deleted from `TerminalView.menu(for:)`, and build all
     wrapper-targeted items (Split Right/Down, Copy cwd, agent session,
     Zoom, Close) through it:
     ```swift
     // NSMenuItem.target is weak; representedObject is strong. Anchor this
     // ephemeral wrapper to each item so a reconcile mid-track can't nil the
     // targets (lifetime-safety doc, "AppKit target that can outlive its referent").
     func wrapperItem(_ title: String, _ action: Selector) -> NSMenuItem {
         let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
         mi.target = self
         mi.representedObject = self
         return mi
     }
     ```
     (Clipboard items target the persistent `terminalView` and don't need the
     anchor.)
   - `zoomPaneAction` (line 503) switches from the scaffolded
     `.toggleZoomPane(paneId: nil)` to `.toggleZoomPane(paneId: paneId)` so
     the menu acts on this pane's tab even if selection changed while the
     menu was tracking (the menubar keeps `paneId: nil`).
   - When `includeClipboard`, prepend before Split Right:
     ```swift
     // Copy/Paste act on the terminal surface, so they target the terminal
     // view directly. Copy is disabled rather than hidden so the surface
     // menu's shape is stable with and without a selection.
     let copy = NSMenuItem(title: "Copy", action: #selector(TerminalView.copySelection(_:)), keyEquivalent: "")
     copy.target = terminalView
     copy.isEnabled = terminalView.hasSelection
     menu.addItem(copy)
     let paste = NSMenuItem(title: "Paste", action: #selector(TerminalView.pasteClipboard(_:)), keyEquivalent: "")
     paste.target = terminalView
     menu.addItem(paste)
     menu.addItem(.separator())
     ```
   - Update `makePaneMenu()`'s doc comment: single builder for all three entry
     points; clipboard section only for the surface menu. Touch the file
     header to mention it.
9. **Gates**: `just test-ui` (new tests pass), `just test` (including the
   Phase 2b core pane-scoping cases), `just build`.

## Deletions

- `app/TerminalView.swift`: inline menu construction (306-329 incl. local
  `item` helper), `contextSplitRight`, `contextSplitDown`, `contextClosePane`.
- `app/PaneWrapperView.swift:3`: `import GhosttyKit`.
- `tests-ui/SidebarViewTestShim.swift`: shim `PaneWrapperView` class, shim
  `paneDragType`.

## Verification

1. `just test` -- core/protocol/support + purity lint, including the new
   Phase 2b pane-scoping and alert-preservation tests.
2. `just test-ui` -- new PaneWrapperView suite + existing suites (needs a
   logged-in GUI session; fine from an agent shell).
3. `just build-run`, manual smoke:
   - Right-click surface: unified menu with Copy/Paste at top; Copy disabled
     without selection, enabled with one; Copy/Paste actually work.
   - Right-click inside a mouse-capturing TUI (e.g. `htop`): event goes to the
     app, no menu (consumed-check preserved).
   - Ctrl+click surface: menu pops, synthetic right press delivered;
     ctrl+click while mouse-captured shows no menu.
   - "..." button and toolbar right-click: unchanged menu, no Copy/Paste.
   - Copy cwd / agent session item enabled-or-present per pane state, from
     both surface and toolbar entry points.
   - Single pane: Zoom disabled; split: Zoom works; while zoomed, surface
     right-click shows enabled "Unzoom Pane" and it unzooms (wrapper
     re-pointing across rebuilds).
   - Split Right / Split Down / Close Pane from each entry point act on the
     clicked pane, not the focused one.
   - Toolbar pane drag-to-split still works (drag handle untouched).
   - Background-tab pane exit (ghost-pane fix): two tabs, split tab A, run
     `sleep 3; exit` in one of its panes, switch to tab B before it fires;
     after the exit, switch back -- the pane is gone from tab A's layout and
     tab B's zoom state is untouched.

## Risks

- `TerminalView.menu(for:)` tail is manual-smoke-only (real TerminalView
  can't enter the harness). Risk is one line; handshake preserved verbatim.
- The `toggleZoomPane(paneId:)` Msg change is a mechanical sweep across
  core tests and `AppDelegate.swift:467`, done as behavior-neutral
  scaffolding in step 4b; the compiler finds every site (exhaustive enum
  switch + case rename), so the risk is churn, not silent breakage.
- `.closePane` re-resolution changes behavior for `.surfaceClosed` on
  background-tab panes (ghost pane today -> removed). Intended; pinned by
  the Phase 2b regression test.
- A wrapperless mounted TerminalView would get no right-click menu;
  `buildView` always wraps today, so theoretical.
- Harness surface grows by three app files; if `SearchOverlayView` /
  `TodoToolbarButton` ever gain GhosttyKit deps the harness needs new shims
  (same accepted trade-off as SidebarView).

## Implementation notes

- All five Phase 2b core tests landed in `UpdatePaneTests.swift` under a new
  "Pane-Scoped Tab Resolution Tests" MARK (the plan offered
  UpdatePaneTests/UpdateTabTests; every case exercises a pane-domain message,
  so they stayed together in the pane suite).
- The shared `TwoTabFixture` pre-seeds `model.mruOrder` with the canonical
  order (selected first, then display order): `update()` canonicalizes
  `mruOrder` in a `defer` on every message, so a hand-built fixture with an
  empty `mruOrder` would make the vanished-pane test's whole-model equality
  assertion impossible to satisfy even after the fix.
- `TerminalView`'s `// MARK: - Context Menu Actions` section comment became
  `// MARK: - Clipboard Actions` since only `copySelection`/`pasteClipboard`
  remain after the deletion.
