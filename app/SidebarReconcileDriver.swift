// Owns the sidebar projection cache and the complete ordered reconcile pass.
// SidebarView remains the renderer and row-op executor.
import Cocoa

/// Reports what the sidebar pass applied so UI tests can verify deferred paints
/// without reading the driver's private cache.
struct SidebarReconcileResult {
    let appliedProjection: SidebarProjection
    let unappliedTabIds: Set<TabId>
    let unappliedGroupIds: Set<GroupId>
}

/// Owns the only sidebar reconcile pipeline. A fresh view has no applied
/// projection, so its first pass is a full rebuild.
@MainActor
final class SidebarReconcileDriver {
    /// Reconciles with the alert tally already computed by the runtime sweep.
    @discardableResult
    func reconcile(
        _ model: AppModel,
        tally: UnreadAlertTally,
        in sidebarView: SidebarView
    ) -> SidebarReconcileResult {
        let oldProjection = sidebarView.appliedProjection
        let newProjection = desiredSidebar(in: model, tally: tally)
        let rawOps = computeSidebarRowOps(old: oldProjection, new: newProjection)
        let renameTarget = sidebarView.activeRenameTarget
        let guarded = guardSidebarRenameOps(
            ops: rawOps,
            renameTarget: renameTarget,
            new: newProjection)
        let unapplied = sidebarView.applySidebarOps(
            guarded.ops,
            projection: newProjection,
            renameTargetToEnd: guarded.clearRename ? renameTarget : nil)
        let advancedProjection = advanceSidebarCache(
            old: oldProjection,
            new: newProjection,
            suppressedRenameTarget: sidebarView.activeRenameTarget,
            unappliedTabIds: unapplied.tabs,
            appliedGroupRenders: unapplied.groupRenders)
        sidebarView.finishSidebarReconcile(with: advancedProjection)
        return SidebarReconcileResult(
            appliedProjection: advancedProjection,
            unappliedTabIds: unapplied.tabs,
            unappliedGroupIds: unapplied.groups)
    }

    /// Reconciles callers that do not already hold an unread-alert tally.
    @discardableResult
    func reconcile(_ model: AppModel, in sidebarView: SidebarView) -> SidebarReconcileResult {
        reconcile(model, tally: unreadAlertTally(for: model), in: sidebarView)
    }
}
