// Declarative AppKit pane-focus classification and application. The ordered
// reconcile pipeline calls this only after pane chrome has created search fields.
import Cocoa

/// Classifies the main window's current responder by pane ownership.
enum PaneFocusClaimant: Equatable {
    case pane(PaneFocusTarget)
    case nonPane
    case none
}

@MainActor
extension AppRuntime {
    /// Repair pane-owned first responder from the model while preserving a
    /// deliberate main-window control outside the pane tree.
    func reconcilePaneFocus() {
        guard let desired = desiredPaneFocus(in: model) else { return }
        switch paneFocusClaimant() {
        case .pane(let actual) where actual == desired:
            return
        case .nonPane:
            return
        case .none, .pane:
            applyPaneFocus(desired)
        }
    }

    /// Resolve the live responder to a pane target, a deliberate non-pane
    /// claimant, or the unclaimed window state AppKit leaves after reparenting.
    func paneFocusClaimant() -> PaneFocusClaimant {
        guard let window, let responder = window.firstResponder else { return .none }
        if responder === window { return .none }

        for (paneId, session) in sessions {
            if responder === session.hostView {
                return .pane(.terminal(paneId))
            }
            if let view = responder as? NSView, view.isDescendant(of: session.hostView) {
                return .pane(.terminal(paneId))
            }
        }

        for paneId in model.allPaneIds {
            guard let field = findPaneWrapper(for: paneId)?.searchOverlay?.searchField else {
                continue
            }
            if responder === field || field.currentEditor() === responder {
                return .pane(.searchField(paneId))
            }
        }
        return .nonPane
    }

    /// Apply one already-projected pane target to the persistent AppKit host.
    private func applyPaneFocus(_ target: PaneFocusTarget) {
        switch target {
        case .terminal(let paneId):
            guard let session = sessions[paneId] else { return }
            window?.makeFirstResponder(session.hostView)
        case .searchField(let paneId):
            guard let field = findPaneWrapper(for: paneId)?.searchOverlay?.searchField else {
                return
            }
            window?.makeFirstResponder(field)
        }
    }
}
