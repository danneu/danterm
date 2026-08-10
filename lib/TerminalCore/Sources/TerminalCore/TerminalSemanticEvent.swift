// Pane-scoped terminal semantics and their bounded pending-delivery representation.

/// Carries complete terminal meanings without exposing parser or pane identity details.
public enum TerminalSemanticEvent: Equatable, Sendable {
    case title(String)
    case workingDirectory(String?)
    case bell
    case commandStarted(String)
    case commandEnded
    case remoteStarted
    case remoteHost(user: String, host: String)
    case desktopNotification(title: String, body: String)
    case progress(TerminalProgress?)
}

/// Represents the progress states DanTerm exposes in pane chrome.
public enum TerminalProgress: Equatable, Sendable {
    case set(percent: UInt8)
    case indeterminate
    case error(percent: UInt8?)
    case pause(percent: UInt8?)
}

/// Associates a retained event with its latest position in terminal stream order.
struct PendingTerminalSemanticEvent: Equatable, Sendable {
    var order: UInt64
    var event: TerminalSemanticEvent

    var byteCost: Int {
        switch event {
        case let .title(value), let .commandStarted(value):
            value.utf8.count
        case let .desktopNotification(title, body):
            title.utf8.count + body.utf8.count
        case let .remoteHost(user, host):
            user.utf8.count + host.utf8.count
        case let .workingDirectory(value):
            value?.utf8.count ?? 0
        case .bell, .commandEnded, .remoteStarted, .progress:
            0
        }
    }
}
