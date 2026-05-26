// View reconciler: derives AppKit/surface state from the model after every send()
// (and after a restore commit). Stage 3 stands up the scaffolding -- reconcile(),
// ReconcilerCaches, and the first keyed pass reconcileFocusBorders -- that stages
// 4-8 extend. Pure projections live in ModelOperations.swift (AppKit-free, unit
// tested); the reconcile* passes here are the thin impure executors that apply the
// diff to AppKit and are manual-QA-only.
//
// Template for adding a pass (per the migration plan):
//   1. a pure projection in ModelOperations.swift returning an Equatable value
//   2. a cache field on ReconcilerCaches (resets for free via tearDownCurrentSession)
//   3. a reconcileX() running the projection through applyDiff (or, for a single
//      panel, a direct compare against a single-optional cache field)
//   4. delete the matching Effect case + its perform arm, in the same stage
import Cocoa

/// Per-pass diff caches, bundled so teardown resets them all by re-init (a newly
/// added field resets for free). Each cache holds the last value its pass applied,
/// so the next diff applies only the delta. Reset in
/// `AppRuntime.tearDownCurrentSession` so a post-restore reconcile is a clean
/// build, not a stale diff.
struct ReconcilerCaches {
    // focusBorders rides the persisted TerminalView in `surfaces`, which survives
    // container rebuilds, so this cache needs no cross-pass invalidation.
    var focusBorders: [PaneId: BorderState] = [:]
    // paneToolbar / searchOverlay are the first *host-recreated* caches: their host is
    // the PaneWrapperView, which a container rebuild destroys (toolbar + overlay are
    // subviews of the wrapper). Stage 4 keeps them coherent via finalizeTabSelection's
    // post-build chrome rehydrate -- which re-applies the current model values onto a
    // fresh wrapper, equal to the cache so no divergence. Stage 8 replaces that with
    // explicit per-pane cache invalidation when it folds containers into the reconciler.
    var paneToolbar: [PaneId: PaneToolbarRender] = [:]
    var searchOverlay: [PaneId: SearchOverlayRender] = [:]   // key present iff search active
    // Single-optional ordered-pass cache (like the eventual switcher cache): the last
    // sidebar projection reconcileSidebar applied. computeSidebarRowOps diffs the new
    // projection against this into ordered NSOutlineView row ops. nil == not yet built
    // (first reconcile inserts all rows via reloadAll). NSOutlineView owns selection, so it
    // is excluded from the projection and reapplied separately (resolveReloadSelection).
    var sidebar: SidebarProjection? = nil
    // Single-struct-compare cache: the last window chrome reconcileWindowChrome applied.
    // Its three hosts (window, chromeView, dock tile) persist across container rebuilds,
    // so this cache needs no cross-pass invalidation. nil == not yet applied.
    var windowChrome: WindowChromeProjection? = nil
}

extension AppRuntime {
    /// Reconcile derived AppKit/surface state from the model. Runs after the
    /// command phase in send() and at the end of a restore commit. Ordered so the
    /// occlusion pass stays last (it reads `surfaces`). Stages 4-8 insert their
    /// passes ahead of syncSurfaceVisibility().
    func reconcile() {
        reconcileFocusBorders()
        reconcilePaneChrome()
        reconcileSidebar()
        reconcileWindowChrome()
        syncSurfaceVisibility()  // existing occlusion pass; stays last
    }

    /// Push each pane's (focused, bell) border to its TerminalView, diffed against
    /// the focusBorders cache so unchanged panes are skipped. Replaces the deleted
    /// `.refreshPaneBorder` effect; the executor (TerminalView.setFocusBorder) is
    /// unchanged -- only the computation moved into the pure `desiredFocusBorders`.
    /// The default no-op `remove` is correct here: a pane's TerminalView is torn
    /// down elsewhere, so a key leaving the projection only prunes the cache.
    func reconcileFocusBorders() {
        applyDiff(desiredFocusBorders(in: model), &caches.focusBorders, apply: { paneId, state in
            surfaces[paneId]?.setFocusBorder(state.focused, hasBell: state.bell)
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
    func reconcilePaneChrome() {
        applyDiff(desiredPaneToolbar(in: model), &caches.paneToolbar, apply: { paneId, render in
            guard let contentArea = contentArea else { return }
            findPaneWrapper(for: paneId, in: contentArea)?.updateToolbar(
                title: render.title,
                cwd: render.cwd,
                progress: render.progress,
                isRemote: render.isRemote,
                remoteSession: render.remoteSession,
                unreadAlertCount: render.unreadAlertCount,
                totalTodoCount: render.totalTodoCount,
                uncompletedTodoCount: render.uncompletedTodoCount
            )
        })
        applyDiff(desiredSearchOverlays(in: model), &caches.searchOverlay, apply: { paneId, render in
            guard let contentArea = contentArea else { return }
            let search = SearchModel(needle: render.needle, total: render.total, selected: render.selected)
            findPaneWrapper(for: paneId, in: contentArea)?.showSearchOverlay(search: search, runtime: self)
        }, remove: { paneId in
            guard let contentArea = contentArea else { return }
            findPaneWrapper(for: paneId, in: contentArea)?.hideSearchOverlay()
        })
    }

    /// Granular NSOutlineView sidebar diff -- the one ordered op-list pass. The pure
    /// `computeSidebarRowOps` diffs the projection against `caches.sidebar` into an
    /// ordered insert/remove/reload/collapse script (inconsistent batch ops crash
    /// NSOutlineView hard, so all the diff logic stays pure + tested); the thin executor
    /// `SidebarView.applySidebarOps` issues the matching outline mutations. Selection is
    /// view-owned: the executor captures the live multi-selection, applies the ops, then
    /// reapplies through `resolveReloadSelection` (replacing the deleted
    /// `.setSidebarSelection` effect). The narrow rename guard suppresses only a `reload`
    /// of the live-editing row (its title/attrs belong to the field editor) while
    /// structural ops still apply; a structural op on that row ends the edit and clears
    /// the sidecar. Replaces the deleted `reloadSidebar` / `setSidebarSelection` /
    /// `updateSidebarTabRow` / `updateSidebarGroupRow` effects + the imperative
    /// `reload(model:)`.
    func reconcileSidebar() {
        guard let sidebarView = sidebarView else { return }
        let new = desiredSidebar(in: model)
        let rawOps = computeSidebarRowOps(old: caches.sidebar, new: new)
        let guarded = guardSidebarRenameOps(
            ops: rawOps,
            renameTarget: viewLocalState.sidebarRenameTarget,
            new: new)
        if guarded.clearRename {
            // A structural op removed/moved the edited row (or a wholesale rebuild ran):
            // end the now-orphaned edit so the field editor never strands.
            viewLocalState.sidebarRenameTarget = nil
        }
        sidebarView.applySidebarOps(
            guarded.ops, model: model, clearActiveRename: guarded.clearRename)
        // Advance the cache. If a reload was suppressed for the still-editing row,
        // retain its prior projection so the deferred attr update re-fires on edit-end.
        caches.sidebar = advanceSidebarCache(
            old: caches.sidebar, new: new,
            suppressedRenameTarget: viewLocalState.sidebarRenameTarget)
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
    func reconcileWindowChrome() {
        let new = desiredWindowChrome(in: model)
        guard caches.windowChrome != new else { return }
        window?.title = new.windowTitle
        chromeView?.updateTitle(new.contentTitle)
        chromeView?.updateBellBadge(count: new.unreadCount)
        NSApp.dockTile.badgeLabel = new.unreadCount > 0 ? "\(new.unreadCount)" : nil
        NSApp.dockTile.display()
        chromeView?.tabTodoButton.update(
            totalCount: new.tabTodoTotal, uncompletedCount: new.tabTodoUncompleted)
        caches.windowChrome = new
    }
}
