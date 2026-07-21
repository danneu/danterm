// Pane-scoped terminal semantics and their bounded pending-delivery representation.

/// Carries complete terminal meanings without exposing parser or pane identity details.
public enum TerminalSemanticEvent: Equatable, Sendable {
    case title(String)
    case workingDirectory(String?)
    case bell
    case legacyPrivateShell(String)
}

/// Associates a retained event with its latest position in terminal stream order.
struct PendingTerminalSemanticEvent: Equatable, Sendable {
    var order: UInt64
    var event: TerminalSemanticEvent

    var byteCost: Int {
        switch event {
        case let .title(value), let .legacyPrivateShell(value):
            value.utf8.count
        case let .workingDirectory(value):
            value?.utf8.count ?? 0
        case .bell:
            0
        }
    }
}
