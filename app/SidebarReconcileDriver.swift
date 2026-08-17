// Owns the sidebar projection cache and the complete ordered reconcile pass.
// SidebarView remains the renderer and row-op executor.
import Cocoa

/// Reports what the sidebar pass applied so UI tests can verify deferred paints
/// without reading the driver's private cache.
struct SidebarReconcileResult {
    let appliedProjection: SidebarProjection
    let unappliedTabIds: Set<TabId>
    let unappliedGroupIds: Set<GroupId>
    /// Facts the pass discovered about the view, for the runtime to dispatch once
    /// the sweep has returned. The pass never sends them itself.
    let followUps: [Msg]
}

/// Owns the only sidebar reconcile pipeline and its last-applied projection.
/// Constructing a new driver guarantees that its first pass is a full rebuild.
final class SidebarReconcileDriver {
    private var appliedProjection: SidebarProjection?

    /// Reconciles with the alert tally already computed by the runtime sweep.
    @discardableResult
    func reconcile(
        _ model: AppModel,
        tally: UnreadAlertTally,
        in sidebarView: SidebarView
    ) -> SidebarReconcileResult {
        let newProjection = desiredSidebar(in: model, tally: tally)
        let rawOps = computeSidebarRowOps(old: appliedProjection, new: newProjection)
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
            old: appliedProjection,
            new: newProjection,
            suppressedRenameTarget: sidebarView.activeRenameTarget,
            unappliedTabIds: unapplied.tabs,
            unappliedGroupIds: unapplied.groups)
        appliedProjection = advancedProjection
        return SidebarReconcileResult(
            appliedProjection: advancedProjection,
            unappliedTabIds: unapplied.tabs,
            unappliedGroupIds: unapplied.groups,
            followUps: unapplied.followUps)
    }

    /// Reconciles callers that do not already hold an unread-alert tally.
    @discardableResult
    func reconcile(_ model: AppModel, in sidebarView: SidebarView) -> SidebarReconcileResult {
        reconcile(model, tally: unreadAlertTally(for: model), in: sidebarView)
    }
}
