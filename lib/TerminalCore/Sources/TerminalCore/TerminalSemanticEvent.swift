// Pane-scoped terminal semantics and their bounded pending-delivery representation.

/// Carries complete terminal meanings without exposing parser or pane identity details.
public enum TerminalSemanticEvent: Equatable, Sendable {
    case title(String)
    case workingDirectory(String?)
    case bell
    case integrationReady
    case commandStarted(String)
    case commandEnded(exitStatus: UInt8)
    case connectionDeclared(TerminalConnectionState)
    case desktopNotification(title: String, body: String)
    case progress(TerminalProgress?)
}

/// Carries one complete connection declaration from the shell that owns the prompt.
public enum TerminalConnectionState: Equatable, Sendable {
    case local
    case remote(identity: TerminalRemoteIdentity?)
}

/// Couples the two fields that identify a remote shell so partial identities are impossible.
public struct TerminalRemoteIdentity: Equatable, Sendable {
    public let user: String
    public let host: String

    public init(user: String, host: String) {
        self.user = user
        self.host = host
    }
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
        case let .connectionDeclared(.remote(identity: identity)):
            identity.map { $0.user.utf8.count + $0.host.utf8.count } ?? 0
        case let .workingDirectory(value):
            value?.utf8.count ?? 0
        case .bell, .integrationReady, .commandEnded, .connectionDeclared(.local), .progress:
            0
        }
    }
}
