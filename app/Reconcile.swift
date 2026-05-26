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
    // container rebuilds, so this cache needs no cross-pass invalidation (later
    // host-recreated caches like paneToolbar will). Later stages add their fields.
    var focusBorders: [PaneId: BorderState] = [:]
}

extension AppRuntime {
    /// Reconcile derived AppKit/surface state from the model. Runs after the
    /// command phase in send() and at the end of a restore commit. Ordered so the
    /// occlusion pass stays last (it reads `surfaces`). Stages 4-8 insert their
    /// passes ahead of syncSurfaceVisibility().
    func reconcile() {
        reconcileFocusBorders()
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
}
