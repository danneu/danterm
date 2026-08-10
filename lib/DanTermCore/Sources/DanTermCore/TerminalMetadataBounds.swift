// Deterministic per-value byte guard for terminal-originated pane metadata.
// This is DanTerm's independent model-side cap; it does not sum against the
// engine's own retention budget -- see docs/terminal-capabilities.md for the
// per-layer contract.
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
