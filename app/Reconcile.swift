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
import DanTermProtocol

/// Per-pass diff caches, bundled so teardown resets them all by re-init (a newly
/// added field resets for free). Each cache holds the last value its pass applied,
/// so the next diff applies only the delta. Reset in
/// `AppRuntime.tearDownCurrentSession` so a post-restore reconcile is a clean
/// build, not a stale diff.
struct ReconcilerCaches {
    var effectiveBindings: [KeybindingActionID: [KeyChord]]? = nil
    // focusBorders rides the runtime-owned PaneHost's wrapper, which survives
    // container edits, so this cache needs no cross-pass invalidation.
    var focusBorders: [PaneId: BorderState] = [:]
    // Reported terminal focus rides the session owned by each PaneHost. The map
    // remains unseeded so a newborn pane receives one explicit initial value.
    var reportedTerminalFocus: [PaneId: Bool] = [:]
    // paneConfig also rides the terminal session the PaneHost owns, so the cache
    // needs no cross-pass invalidation.
    var paneConfig: [PaneId: PaneConfigKey] = [:]
    // Search overlay state rides the runtime-owned PaneHost, so structural
    // container edits do not invalidate this cache.
    var searchOverlay: [PaneId: SearchOverlayRender] = [:]   // key present iff search active
    // The last container projection reconciled per tab. It includes layout inputs,
    // so ratio-only changes reach hidden and visible containers alike, and
    // visibility, so this cache is the only record of which tab the last pass
    // showed -- nothing re-derives that by scanning AppKit's isHidden flags.
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
    // transition): the last switcher projection applied to the switcher surface.
    // nil == no MRU cycle == overlay hidden. The overlay persists across container
    // edits, so this cache needs no cross-pass invalidation.
    var switcher: SwitcherProjection? = nil
    // Single-optional confirmation cache. Unlike switcher, the surface discards
    // its panel on teardown, so nil after ReconcilerCaches() re-init correctly
    // means "no panel, nothing shown".
    var confirmation: ConfirmationProjection? = nil
    // Single-optional FIFO-head notice cache. The panel survives between queued notices.
    var notice: NoticeProjection? = nil
}

extension AppRuntime {
    /// Reconcile derived AppKit/session state from the model. Runs after commands
    /// in send() and at the end of a restore commit.
    /// Ordered containers -> existence -> pane config -> content/chrome -> occlusion:
    /// containers detach removed wrappers before session teardown releases their hosts;
    /// chrome then renders into the stable surviving wrappers, and occlusion stays last.
    /// A pass originates no Msg: a fact it discovers goes into the runtime's outbox,
    /// which delivers it only after this sweep has returned and every pass cache has
    /// advanced. A pass that sent for itself would re-enter the sweep against a
    /// stale cache.
    func reconcile() {
        reconcileConfigurableMenuBindings()
        reconcileContainers()               // eager: selected visible, rest mounted+hidden
        reconcileSessionExistence()         // release hosts only after containers detach dead wrappers
        reconcilePaneConfig()
        let alertTally = unreadAlertTally(for: model)
        reconcileFocusBorders(tally: alertTally)
        reconcilePaneChrome(tally: alertTally)
        reconcileThemeBrowser()
        reconcileSidebar(tally: alertTally)
        reconcileWindowChrome(tally: alertTally)
        // The four dialogs, each through the surface the runtime was given. The
        // switcher goes through the overlay pass: it re-applies on every step of
        // a cycle and never comes forward to key.
        reconcileOverlay(
            desiredSwitcher(in: model, tally: alertTally),
            cache: &caches.switcher,
            surface: dialogSurfaces.switcher
        )
        reconcileDialog(
            desiredConfirmation(in: model),
            cache: &caches.confirmation,
            surface: dialogSurfaces.confirmation
        )
        reconcileDialog(
            desiredNotice(in: model),
            cache: &caches.notice,
            surface: dialogSurfaces.notice
        )
        reconcileDialog(
            desiredPreferencesPanel(in: model),
            cache: &caches.preferencesPanel,
            surface: dialogSurfaces.preferences
        )
        reconcileAlertsPopover()
        reconcileTodoPopover()
        // Focus runs after every existence pass: repair the responder first,
        // then derive what each child is told from the settled claimant.
        reconcilePaneFocus()
        reconcileReportedTerminalFocus()
        syncPaneVisibility()  // existing occlusion pass; stays last
    }

    /// Pushes one complete validated binding map into the AppKit menu surface.
    func reconcileConfigurableMenuBindings() {
        guard let desired = effectiveBindings(overrides: model.config.keybindingOverrides).value,
              desired != caches.effectiveBindings
        else { return }
        configurableMenuBindingSurface?.apply(desired)
        caches.effectiveBindings = desired
    }

    /// Tear down panes that left the model after containers detach wrappers.
    /// Selection is the pure `sessionsToTearDown` (= live panes - model.allPaneIds);
    /// the executor body is the former teardown command. Pane *creation* stays
    /// a command, so the reconciler only ever destroys.
    func reconcileSessionExistence() {
        for paneId in sessionsToTearDown(liveSessionIds: Set(paneHosts.keys), model: model) {
            tearDownSession(paneId)
        }
    }

    /// Container pass: reconcile the per-tab SplitContainerViews (eager -- every tab is
    /// mounted, the selected one visible, the rest hidden). Existing containers
    /// receive direct structural or ratio-only layout updates.
    func reconcileContainers() {
        guard contentArea != nil else { return }
        let new = desiredContainerShapes(in: model)
        let ops = computeContainerOps(old: caches.containerShape, new: new)

        // "What did the last pass show" comes from the shape cache, which owns the
        // fact, rather than from scanning the containers' own isHidden flags.
        if containerOpsStrandVisible(ops: ops, cachedShapes: caches.containerShape)
            || containerOpsEditVisibleTree(ops: ops, cachedShapes: caches.containerShape) {
            cancelPaneDrag()
        }

        // Apply ops (remove first, then each tab's build/tree/layout/zoom/visibility).
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
                // Only the reveal half lays out. A hidden container already carries
                // model-derived geometry -- the tree, ratio, and zoom ops apply the
                // layout themselves -- so hiding one costs no layout solve.
                if visible { container.ensureLaidOut() }
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
            paneSession(for: paneId)?.applyTheme(key.theme)
            paneSession(for: paneId)?.setFontSize(key.fontSize)
            paneSession(for: paneId)?.setFontFamily(key.fontFamily)
            paneSession(for: paneId)?.setCopyOnSelect(key.copyOnSelect)
            paneSession(for: paneId)?.setGridOverride(key.gridOverride)
        }, remove: { paneId in
            paneSession(for: paneId)?.clearTheme()
        })
    }

    /// Push each pane's toolbar render and search overlay to its PaneWrapperView.
    /// The wrapper owns toolbar equality while search remains diffed here. Replaces
    /// the deleted `.refreshPaneToolbar`,
    /// `.showSearchOverlay`, and `.hideSearchOverlay` effects (and the imperative
    /// toolbar refreshes in `send()`); the executors (`applyToolbarRender`,
    /// `showSearchOverlay`, `hideSearchOverlay`) receive the projection computed
    /// by this pass.
    ///
    /// Every desired toolbar render is offered on each reconcile. A missing
    /// wrapper consumes nothing, and the wrapper skips an equal render only after
    /// it applied one. Search overlay is keyed iff search is active, so the key
    /// disappears on `.endSearch` while the wrapper survives -- a non-default
    /// `remove` tears the overlay down (the disappear-but-host-survives discipline).
    func reconcilePaneChrome(tally: UnreadAlertTally) {
        offerPaneToolbarRenders(
            desiredPaneToolbar(in: model, tally: tally),
            wrapperFor: { paneId in findPaneWrapper(for: paneId) }
        )
        applyDiff(desiredSearchOverlays(in: model), &caches.searchOverlay, apply: { paneId, render in
            let search = SearchModel(needle: render.needle, status: render.status)
            findPaneWrapper(for: paneId)?.showSearchOverlay(search: search, runtime: self)
        }, remove: { paneId in
            findPaneWrapper(for: paneId)?.hideSearchOverlay()
        })
    }

    /// Drives the sidebar through its single cache-owning reconcile pipeline. What
    /// the pass discovers about the view goes into the outbox from the site that
    /// discovered it, so nothing travels back through this call.
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

    /// The single-optional presentation pass: diff against the pass cache, apply
    /// on any change, hide when the projection goes away.
    ///
    /// The surface is the pass's only route to the screen. No window is built or
    /// ordered here, so a runtime given surfaces that present nothing puts
    /// nothing on screen, whatever hosts it also holds.
    private func reconcileOverlay<Projection: Equatable>(
        _ new: Projection?,
        cache: inout Projection?,
        surface: any OverlaySurface<Projection>
    ) {
        guard cache != new else { return }
        if let new {
            surface.apply(new)
        } else {
            surface.hide()
        }
        cache = new
    }

    /// The overlay pass plus one raise on the closed-to-open transition, which is
    /// what every dialog that takes key focus needs and nothing else does. A
    /// refresh while the dialog is open re-applies without raising, so a
    /// projection change cannot pull first responder off the pane underneath.
    ///
    /// What "raise" means belongs to the surface: centering and key focus for the
    /// notice and confirmation panels, key focus alone for preferences.
    private func reconcileDialog<Projection: Equatable>(
        _ new: Projection?,
        cache: inout Projection?,
        surface: any DialogSurface<Projection>
    ) {
        let opening = cache == nil && new != nil
        reconcileOverlay(new, cache: &cache, surface: surface)
        if opening { surface.raise() }
    }

    /// Creates, refreshes, or silently closes the model-projected alerts popover.
    func reconcileAlertsPopover() {
        reconcileAlertAgeRefresh()
        let new = desiredAlertsPopover(in: model, now: coreEnv.now())
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
            let viewController = TodoPopoverController(scope: PaneTodoPopoverScope(paneId: pane.paneId), runtime: self)
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
            let viewController = TodoPopoverController(scope: TabTodoPopoverScope(tabId: tab.tabId), runtime: self)
            viewController.loadViewIfNeeded()
            viewController.apply(tab)
            todoPopover = presentTransientPopover(viewController, delegate: delegate, from: anchor)
        }
        todoPopoverDelegate = delegate
    }

    /// Applies changed content without disturbing an open popover's local edit state.
    /// The open controller ignores a projection that is not its own scope's.
    private func applyTodoPopover(_ projection: TodoPopoverProjection) {
        (todoPopover?.contentViewController as? TodoPopoverApplying)?.apply(projection)
    }

    /// Creates, refreshes, or removes the model-projected theme browser overlay.
    func reconcileThemeBrowser() {
        let new = desiredThemeBrowser(in: model)
        guard caches.themeBrowser != new else { return }
        if let projection = new {
            if themeBrowserView == nil {
                guard let contentArea else {
                    preconditionFailure("theme browser content area is missing")
                }
                let browser = ThemeBrowserView()
                browser.runtime = self
                contentArea.addSubview(browser)
                NSLayoutConstraint.activate([
                    browser.topAnchor.constraint(equalTo: contentArea.topAnchor),
                    browser.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
                    browser.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
                ])
                themeBrowserView = browser
            }
            themeBrowserView?.apply(projection)
        } else {
            themeBrowserView?.removeFromSuperview()
            themeBrowserView = nil
        }
        caches.themeBrowser = new
    }
}
