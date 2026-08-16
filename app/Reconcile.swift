// View reconciler: derives AppKit/session state from the model after every send()
// (and after a restore commit). Stage 3 stands up the scaffolding -- reconcile(),
// ReconcilerCaches, and the first keyed pass reconcileFocusBorders -- that stages
// 4-8 extend. Pure projections live in Projections.swift (AppKit-free, unit
// tested); the reconcile* passes here are thin impure executors. The sidebar's
// ordered pass lives in SidebarReconcileDriver so the UI harness can drive it.
//
// Template for adding a pass (per the migration plan):
//   1. a pure projection in Projections.swift returning an Equatable value
//   2. a cache field on ReconcilerCaches (or a cache-owning driver for an ordered pass)
//   3. a reconcileX() running the projection through applyDiff (or, for a single
//      panel, a direct compare against a single-optional cache field)
//   4. delete the matching Command case + its perform arm, in the same stage
import Cocoa

/// Per-pass diff caches, bundled so teardown resets them all by re-init (a newly
/// added field resets for free). Each cache holds the last value its pass applied,
/// so the next diff applies only the delta. Reset in
/// `AppRuntime.tearDownCurrentSession` so a post-restore reconcile is a clean
/// build, not a stale diff.
struct ReconcilerCaches {
    // focusBorders rides the runtime-owned PaneHost's wrapper, which survives
    // container edits, so this cache needs no cross-pass invalidation.
    var focusBorders: [PaneId: BorderState] = [:]
    // paneConfig also rides the persisted terminal session in `sessions`, so the
    // cache needs no cross-pass invalidation.
    var paneConfig: [PaneId: PaneConfigKey] = [:]
    // Pane toolbar and search overlay state rides the runtime-owned PaneHost, so
    // structural container edits do not invalidate either cache.
    var paneToolbar: [PaneId: PaneToolbarRender] = [:]
    var searchOverlay: [PaneId: SearchOverlayRender] = [:]   // key present iff search active
    // The last container projection reconciled per tab. It includes layout inputs,
    // so ratio-only changes reach hidden and visible containers alike.
    var containerShape: [TabId: ContainerShape] = [:]
    // Single-struct-compare cache: the last window chrome reconcileWindowChrome applied.
    // Its three hosts (window, chromeView, dock tile) persist across container edits,
    // so this cache needs no cross-pass invalidation. nil == not yet applied.
    var windowChrome: WindowChromeProjection? = nil
    // Single-optional preferences projection cache. nil == no open preferences
    // draft/panel; a non-nil value is the last form render pushed into the panel.
    var preferencesPanel: PreferencesPanelProjection? = nil
    // Single-optional alerts-popover cache. nil means no open popover projection
    // has been applied; non-nil is the last value pushed while the popover was shown.
    var alertsPopover: AlertsPopoverProjection? = nil
    // Single-optional TODO popover cache. nil means the model wants no popover;
    // non-nil owns both its existence and its last rendered content.
    var todoPopover: TodoPopoverProjection? = nil
    // Single-optional theme-browser content cache. nil == no browser open; non-nil
    // == last focused-pane theme content applied.
    var themeBrowser: ThemeBrowserProjection? = nil
    // Single-optional MRU switcher cache (the windowChrome template, plus a hide
    // transition): the last switcher projection reconcileSwitcher applied. nil == no MRU
    // cycle == panel ordered out. The panel persists across container edits, so this
    // cache needs no cross-pass invalidation.
    var switcher: SwitcherProjection? = nil
    // Single-optional confirmation cache. Unlike switcher, the panel is
    // destroyed on teardown, so nil after ReconcilerCaches() re-init correctly
    // means "no panel, nothing shown".
    var confirmation: ConfirmationProjection? = nil
}

extension AppRuntime {
    /// Reconcile derived AppKit/session state from the model. Runs after commands
    /// in send() and at the end of a restore commit.
    /// Ordered containers -> existence -> pane config -> content/chrome -> occlusion:
    /// containers detach removed wrappers before session teardown releases their hosts;
    /// chrome then renders into the stable surviving wrappers, and occlusion stays last.
    func reconcile() {
        reconcileContainers()               // eager: selected visible, rest mounted+hidden
        reconcileSessionExistence()         // release hosts only after containers detach dead wrappers
        reconcilePaneConfig()
        let alertTally = unreadAlertTally(for: model)
        reconcileFocusBorders(tally: alertTally)
        reconcilePaneChrome(tally: alertTally)
        reconcilePaneFocus()                 // after chrome creates any desired search field
        reconcileSidebar(tally: alertTally)
        reconcileWindowChrome(tally: alertTally)
        reconcileSwitcher(tally: alertTally)      // single-optional MRU projection; nil (no mruCycle) -> orderOut
        reconcileConfirmation()
        reconcilePreferencesPanel()
        reconcileAlertsPopover()
        reconcileTodoPopover()
        reconcileThemeBrowser()
        syncPaneVisibility()  // existing occlusion pass; stays last
    }

    /// Tear down sessions whose pane left the model after containers detach wrappers.
    /// Selection is the pure `sessionsToTearDown` (= live sessions - model.allPaneIds);
    /// the executor body is the former teardown command. Session *creation* stays
    /// a command, so the reconciler only ever destroys.
    func reconcileSessionExistence() {
        for paneId in sessionsToTearDown(liveSessionIds: Set(sessions.keys), model: model) {
            tearDownSession(paneId)
        }
    }

    /// Container pass: reconcile the per-tab SplitContainerViews (eager -- every tab is
    /// mounted, the selected one visible, the rest hidden). Existing containers
    /// receive direct structural or ratio-only layout updates.
    func reconcileContainers() {
        guard contentArea != nil else { return }
        let new = desiredContainerShapes(in: model)
        let ops = computeContainerOps(old: caches.containerShape, new: new, selectedTabId: model.selectedTabId)

        let previouslyVisibleTabId = tabContainers.first(where: { !$0.value.isHidden })?.key
        if containerOpsStrandVisible(ops: ops, previouslyVisibleTabId: previouslyVisibleTabId)
            || containerOpsEditVisibleTree(
                ops: ops,
                previouslyVisibleTabId: previouslyVisibleTabId
            ) {
            cancelPaneDrag()
        }

        // Apply ops (remove -> build/tree/layout/zoom -> setVisible).
        for op in ops {
            switch op {
            case .remove(let tabId):
                removeTabContainer(tabId)
            case .build(let tabId):
                if let tab = tabById(tabId, in: model) {
                    _ = buildAndInsertContainer(for: tab)  // visibility set by the following setVisible op
                }
            case .setTree(let tabId):
                guard let tab = tabById(tabId, in: model),
                      let container = tabContainers[tabId] else { break }
                container.setRootNode(tab.paneTree.root)
            case .setLayout(let tabId):
                guard let tab = tabById(tabId, in: model) else { break }
                tabContainers[tabId]?.setRootNode(tab.paneTree.root)
            case .setZoomedPane(let tabId, let paneId):
                tabContainers[tabId]?.setZoomedPane(paneId)
            case .setVisible(let tabId, let visible):
                guard let container = tabContainers[tabId] else { break }
                container.isHidden = !visible
                container.ensureLaidOut()
            }
        }
        caches.containerShape = new
    }

    /// Push each pane's (focused, bell) ring to its pane wrapper, diffed against
    /// the focusBorders cache so unchanged panes are skipped. The ring is pane
    /// chrome, so it takes the same route as the toolbar and search overlay:
    /// `findPaneWrapper(for:)`, which resolves through the persistent `PaneHost`
    /// rather than whichever container currently parents the wrapper.
    /// The default no-op `remove` is correct here: a pane's wrapper is torn
    /// down elsewhere, so a key leaving the projection only prunes the cache.
    func reconcileFocusBorders(tally: UnreadAlertTally) {
        applyDiff(desiredFocusBorders(in: model, tally: tally), &caches.focusBorders, apply: { paneId, state in
            findPaneWrapper(for: paneId)?.setFocusRing(focused: state.focused, hasBell: state.bell)
        })
    }

    /// Push each themed pane's config through its terminal session, diffed against
    /// the paneConfig cache. A disappearing key clears the pane override.
    func reconcilePaneConfig() {
        applyDiff(desiredPaneConfig(in: model), &caches.paneConfig, apply: { paneId, key in
            sessions[paneId]?.applyTheme(key.theme)
            sessions[paneId]?.setFontSize(key.fontSize)
            sessions[paneId]?.setFontFamily(key.fontFamily)
            sessions[paneId]?.setCopyOnSelect(key.copyOnSelect)
        }, remove: { paneId in
            sessions[paneId]?.clearTheme()
        })
    }

    /// Push each pane's toolbar render and search overlay to its PaneWrapperView,
    /// each diffed against its cache. Replaces the deleted `.refreshPaneToolbar`,
    /// `.showSearchOverlay`, and `.hideSearchOverlay` effects (and the imperative
    /// toolbar refreshes in `send()`); the executors (`updateToolbar`,
    /// `showSearchOverlay`, `hideSearchOverlay`) are unchanged -- only the computation
    /// and triggering moved into the pure projections + this pass.
    ///
    /// Toolbar: keyed over all live panes, so a key leaves only when its pane is gone
    /// (the container pass already destroyed the wrapper) -- the default no-op `remove`
    /// just prunes the cache. Search overlay: keyed iff search is active, so the key
    /// disappears on `.endSearch` while the wrapper survives -- a non-default `remove`
    /// tears the overlay down (the disappear-but-host-survives discipline).
    func reconcilePaneChrome(tally: UnreadAlertTally) {
        applyDiff(
            desiredPaneToolbar(
                in: model,
                tally: tally
            ),
            &caches.paneToolbar,
            apply: { paneId, render in
            findPaneWrapper(for: paneId)?.updateToolbar(
                label: render.label,
                progress: render.progress,
                isRemote: render.isRemote,
                remoteLabel: render.remoteLabel,
                agentLabel: render.agentLabel,
                chipTooltip: render.chipTooltip,
                chipKind: render.chipKind,
                unreadAlertCount: render.unreadAlertCount,
                totalTodoCount: render.totalTodoCount,
                uncompletedTodoCount: render.uncompletedTodoCount,
                isZoomed: render.isZoomed,
                hasSplits: render.hasSplits
            )
        })
        applyDiff(desiredSearchOverlays(in: model), &caches.searchOverlay, apply: { paneId, render in
            let search = SearchModel(needle: render.needle, status: render.status)
            findPaneWrapper(for: paneId)?.showSearchOverlay(search: search, runtime: self)
        }, remove: { paneId in
            findPaneWrapper(for: paneId)?.hideSearchOverlay()
        })
    }

    /// Drives the sidebar through its single cache-owning reconcile pipeline.
    func reconcileSidebar(tally: UnreadAlertTally) {
        guard let sidebarView = sidebarView else { return }
        sidebarReconcileDriver.reconcile(model, tally: tally, in: sidebarView)
    }

    /// Push the window chrome -- window/content title, dock + toolbar-bell unread badge,
    /// and the tab-todo button rollup -- from one diffed `WindowChromeProjection`. The
    /// single-struct-compare template (the switcher pass follows it): compute the
    /// projection, bail if it equals the cache, else apply every channel and store it.
    /// Replaces the deleted `.setWindowTitle` / `.updateDockBadge` / `.updateToolbarBellBadge`
    /// effects (and the imperative badge block + `refreshTabTodoButton` switch in `send()`).
    /// All three hosts persist across container rebuilds, so no cross-pass invalidation; the
    /// sub-setters are idempotent, so applying all of them on any change is fine. Driven by
    /// the projected values -- never by re-reading the model (same discipline as Stage 4's
    /// toolbar), which is why the old model-reading `refreshContentTitlebar`/
    /// `refreshTabTodoButton` helpers are gone.
    func reconcileWindowChrome(tally: UnreadAlertTally) {
        let new = desiredWindowChrome(in: model, tally: tally)
        guard caches.windowChrome != new else { return }
        window?.title = new.windowTitle.text
        chromeView?.updateTitle(new.contentTitle.text)
        chromeView?.updateBellBadge(count: new.unreadCount)
        if let app = NSApp {
            app.dockTile.badgeLabel = new.unreadCount > 0 ? "\(new.unreadCount)" : nil
            app.dockTile.display()
        }
        chromeView?.tabTodoButton.update(
            totalCount: new.tabTodoTotal, uncompletedCount: new.tabTodoUncompleted)
        caches.windowChrome = new
    }

    /// Show/redraw or hide the MRU switcher panel from one diffed `SwitcherProjection?`.
    /// The windowChrome single-struct-compare template, plus a hide transition: a `nil`
    /// projection (no `model.mruCycle`, or every frozen tab gone) orders the panel out;
    /// a non-nil one renders the rows + centers + orders front. Replaces the deleted
    /// `.showSwitcherOverlay` / `.hideSwitcherOverlay` effects -- the `mruCycle` mutation
    /// in the cycle handlers now drives this. Render + center + orderFront on each non-nil
    /// change is idempotent (matching the old per-step `.showSwitcherOverlay`); the `nil`
    /// transition is what hides the panel on cycle end/cancel. The panel persists across
    /// container rebuilds, so no cross-pass invalidation.
    func reconcileSwitcher(tally: UnreadAlertTally) {
        let new = desiredSwitcher(in: model, tally: tally)
        guard caches.switcher != new else { return }
        if let proj = new {
            // Non-activating: orderFront, never makeKeyAndOrderFront -- key would steal
            // first responder from the focused terminal pane.
            switcherPanel?.apply(rows: proj.rows, cursorIndex: proj.cursorIndex)
            switcherPanel?.centerOnScreen(of: window)
            switcherPanel?.orderFront(nil)
        } else {
            switcherPanel?.orderOut(nil)  // nil == no cycle == hide
        }
        caches.switcher = new
    }

    /// Show, refresh, or hide the non-modal confirmation panel from one
    /// diffed `ConfirmationProjection?`. Unlike reconcileSwitcher, the panel
    /// must take key focus on appear so Esc/Enter activate its buttons, but only
    /// on the nil -> non-nil transition. Later pane-count refreshes reconfigure
    /// the copy without re-centering a dragged panel or stealing key focus from
    /// the terminal pane the user is closing underneath it.
    func reconcileConfirmation() {
        let new = desiredConfirmation(in: model)
        guard caches.confirmation != new else { return }
        let wasShowing = caches.confirmation != nil
        if let proj = new {
            if confirmationPanel == nil {
                confirmationPanel = ConfirmationPanel(runtime: self)
            }
            confirmationPanel?.configure(proj)
            if !wasShowing {
                confirmationPanel?.center(on: window)
                confirmationPanel?.makeKeyAndOrderFront(nil)
            }
        } else {
            confirmationPanel?.orderOut(nil)
        }
        caches.confirmation = new
    }

    /// Create/show, render, or hide the preferences panel from one diffed
    /// `PreferencesPanelProjection?`. Mirrors reconcileConfirmation: nil
    /// means no draft and orders the panel out; non-nil lazily creates the panel,
    /// renders the form, and brings it key/front only on the open transition so
    /// per-keystroke projection changes do not steal key focus.
    func reconcilePreferencesPanel() {
        let new = desiredPreferencesPanel(in: model)
        guard caches.preferencesPanel != new else { return }
        let wasOpen = caches.preferencesPanel != nil
        if let proj = new {
            if preferencesPanel == nil {
                preferencesPanel = PreferencesPanel(runtime: self)
            }
            preferencesPanel?.apply(proj)
            if !wasOpen {
                preferencesPanel?.makeKeyAndOrderFront(nil)
            }
        } else {
            preferencesPanel?.orderOut(nil)
        }
        caches.preferencesPanel = new
    }

    /// Creates, refreshes, or silently closes the model-projected alerts popover.
    func reconcileAlertsPopover() {
        let new = desiredAlertsPopover(in: model)
        guard caches.alertsPopover != new else { return }
        let wasOpen = caches.alertsPopover != nil
        if let projection = new {
            if wasOpen == false || alertsPopover == nil {
                dismissAlertsPopoverSilently()
                guard let anchor = chromeView?.bellButton else {
                    preconditionFailure("alerts popover anchor is missing")
                }
                let viewController = AlertsPopoverViewController()
                viewController.runtime = self
                viewController.loadViewIfNeeded()
                viewController.apply(projection)
                alertsPopover = presentTransientPopover(
                    viewController,
                    delegate: alertsPopoverDelegate,
                    from: anchor
                )
            } else {
                (alertsPopover?.contentViewController as? AlertsPopoverViewController)?
                    .apply(projection)
            }
        } else {
            dismissAlertsPopoverSilently()
        }
        caches.alertsPopover = new
    }

    /// Creates, refreshes, replaces, or silently closes the projected TODO popover.
    func reconcileTodoPopover() {
        let new = desiredTodoPopover(in: model)
        guard caches.todoPopover != new else { return }

        let oldOwner = caches.todoPopover.map(todoPopoverOwner)
        let newOwner = new.map(todoPopoverOwner)
        if oldOwner != newOwner || todoPopover == nil {
            dismissTodoPopoverSilently()
            if let new {
                presentTodoPopover(new)
            }
        } else if let new {
            applyTodoPopover(new)
        }
        caches.todoPopover = new
    }

    /// Returns the anchor identity carried by one TODO popover projection.
    private func todoPopoverOwner(_ projection: TodoPopoverProjection) -> TodoOwner {
        switch projection {
        case .pane(let pane): return .pane(pane.paneId)
        case .tab(let tab): return .tab(tab.tabId)
        }
    }

    /// Builds and anchors a TODO popover after containers have made its anchor real.
    private func presentTodoPopover(_ projection: TodoPopoverProjection) {
        let owner = todoPopoverOwner(projection)
        let delegate = TodoPopoverDelegateAdapter(owner: owner, runtime: self)
        switch projection {
        case .pane(let pane):
            guard let wrapper = findPaneWrapper(for: pane.paneId) else {
                preconditionFailure("eligible pane TODO anchor is missing")
            }
            let viewController = TodoPopoverViewController(paneId: pane.paneId, runtime: self)
            viewController.loadViewIfNeeded()
            viewController.apply(pane)
            todoPopover = presentTransientPopover(
                viewController,
                delegate: delegate,
                from: wrapper.todoButtonView
            )
        case .tab(let tab):
            guard let anchor = chromeView?.tabTodoButton else {
                preconditionFailure("eligible tab TODO anchor is missing")
            }
            let viewController = TabTodoPopoverViewController(tabId: tab.tabId, runtime: self)
            viewController.loadViewIfNeeded()
            viewController.apply(tab)
            todoPopover = presentTransientPopover(viewController, delegate: delegate, from: anchor)
        }
        todoPopoverDelegate = delegate
    }

    /// Applies changed content without disturbing an open popover's local edit state.
    private func applyTodoPopover(_ projection: TodoPopoverProjection) {
        switch projection {
        case .pane(let pane):
            (todoPopover?.contentViewController as? TodoPopoverViewController)?.apply(pane)
        case .tab(let tab):
            (todoPopover?.contentViewController as? TabTodoPopoverViewController)?.apply(tab)
        }
    }

    /// Push the focused pane's user theme into the open theme browser. The browser's
    /// filter and first-responder state stay view-local; nil means no browser is open.
    func reconcileThemeBrowser() {
        let new = themeBrowserView == nil ? nil : desiredThemeBrowser(in: model)
        guard caches.themeBrowser != new else { return }
        if let proj = new {
            themeBrowserView?.apply(proj)
        }
        caches.themeBrowser = new
    }
}
