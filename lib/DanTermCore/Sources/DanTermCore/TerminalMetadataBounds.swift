// Deterministic byte accounting and alert eviction for terminal-originated
// pane metadata. This keeps DanTerm's final retention layer bounded without
// introducing a second queue or coupling the pure model to TerminalCore.
import Foundation

/// Defines DanTerm's defensive per-value and per-pane shares of the terminal
/// metadata allowance established at the backend boundary.
enum TerminalMetadataBounds {
    static let maximumValueBytes = 64 * 1024
    static let maximumPaneBytes = 512 * 1024
}

extension String {
    /// Checks untrusted terminal text by encoded bytes so multibyte values use
    /// the same limit at every layer.
    var fitsTerminalMetadataValueLimit: Bool {
        utf8.count <= TerminalMetadataBounds.maximumValueBytes
    }
}

/// Reports the retained terminal-originated string bytes attributed to one
/// pane, including its current fields and alert history.
func terminalMetadataBytes(for paneId: PaneId, in model: AppModel) -> Int {
    let fieldBytes: Int
    if let pane = model.pane(paneId) {
        fieldBytes = pane.title.utf8.count
            + (pane.cwd?.utf8.count ?? 0)
            + (pane.lastCommand?.utf8.count ?? 0)
            + (pane.remoteSession?.user.utf8.count ?? 0)
            + (pane.remoteSession?.host.utf8.count ?? 0)
            + (pane.agentSession?.kind.utf8.count ?? 0)
            + (pane.agentSession?.sessionId.utf8.count ?? 0)
    } else {
        fieldBytes = 0
    }
    return model.alerts.reduce(fieldBytes) { total, alert in
        guard alert.paneId == paneId else { return total }
        return total + alert.title.utf8.count + alert.body.utf8.count
    }
}

/// Preserves current pane fields and newest alerts by removing that pane's
/// oldest retained alerts until its 512 KiB share is satisfied.
func enforceTerminalMetadataBudget(for paneId: PaneId, in model: inout AppModel) {
    while terminalMetadataBytes(for: paneId, in: model) > TerminalMetadataBounds.maximumPaneBytes,
          let oldestIndex = model.alerts.lastIndex(where: { $0.paneId == paneId })
    {
        model.alerts.remove(at: oldestIndex)
    }
}
