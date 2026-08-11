// Deterministic byte guards at DanTerm's engine-to-pane and model admission
// boundaries. These are independent of the engine parser's own cap; see
// docs/terminal-capabilities.md for the per-layer contract.
import Foundation

/// Defines DanTerm's defensive per-value share of the terminal metadata
/// allowance established at the backend boundary.
enum TerminalMetadataBounds {
    static let maximumValueBytes = 64 * 1024
}

extension String {
    /// Checks untrusted terminal text by encoded bytes so multibyte values use
    /// the same limit at every layer.
    var fitsTerminalMetadataValueLimit: Bool {
        utf8.count <= TerminalMetadataBounds.maximumValueBytes
    }
}

extension SessionReport {
    /// Centralizes admission of bounded lifecycle metadata before model mutation.
    var isAdmitted: Bool {
        switch self {
        case .commandStarted(let command):
            command.fitsTerminalMetadataValueLimit
        case .remoteIdentityReported(let identity):
            identity.user.utf8.count + identity.host.utf8.count
                <= TerminalMetadataBounds.maximumValueBytes
        case .integrationReady, .commandEnded, .remoteDetected, .connectionEnded,
             .agentAttached, .agentActivityChanged, .agentDetached:
            true
        }
    }
}
