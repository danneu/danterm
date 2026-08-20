// The vocabulary of terminal semantics: what the parser can mean, and nothing about
// how a meaning is retained until a consumer takes it. Retention lives next door in
// TerminalSemanticEventRetention.swift.

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
