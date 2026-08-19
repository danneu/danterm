// Pure representation of coding-agent sessions reported from a pane. This file
// owns validation of untrusted hook strings and defensively validates directly
// constructed snapshot DTOs, plus the small known-agent
// catalog used for toolbar and recovery text. Keep it free of AppKit and IPC
// transport details; callers hand raw strings in and get safe display text out.
import DanTermProtocol
import Foundation

/// An agent session reported as currently running inside a pane.
///
/// The live value is intentionally not Codable: checkpoints use a strict DTO
/// that the shared init-file loader validates before restore succeeds.
struct AgentSession: Equatable {
    private static let toolbarLabelPrefixLength = 6

    var kind: String
    var sessionId: String

    /// Validate untrusted hook or snapshot strings before they reach toolbar text
    /// or a terminal-printed recovery line.
    init?(kind: String, sessionId: String) {
        let normalizedKind = kind.lowercased()
        guard Self.isValidKind(normalizedKind),
              Self.isValidSessionId(sessionId)
        else {
            return nil
        }

        self.kind = normalizedKind
        self.sessionId = sessionId
    }

    /// Text for the pane toolbar's agent chip: a compact, lowercase kind only.
    /// The full session id lives in the chip tooltip so the chip stays compact.
    var toolbarLabel: String {
        Self.truncatedToolbarLabel(kind)
    }

    var recoveryMessage: String {
        let displayName = AgentCatalog.displayName(for: kind)
        if let command = AgentCatalog.resumeCommand(for: self) {
            return "[DanTerm] Restored \(displayName) session. Resume with:\n  \(command)"
        }
        return "[DanTerm] Restored a \(displayName) session: \(sessionId)"
    }

    private static func isValidKind(_ value: String) -> Bool {
        guard (1...32).contains(value.count),
              let first = value.unicodeScalars.first,
              isAsciiLowercaseLetterOrDigit(first)
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isAsciiLowercaseLetterOrDigit(scalar) || scalar == "_" || scalar == "-"
        }
    }

    private static func isValidSessionId(_ value: String) -> Bool {
        guard (1...128).contains(value.count),
              let first = value.unicodeScalars.first,
              isAsciiLetterOrDigit(first)
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isAsciiLetterOrDigit(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == ":"
                || scalar == "@"
                || scalar == "+"
                || scalar == "-"
        }
    }

    private static func isAsciiLowercaseLetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        (97...122).contains(Int(scalar.value)) || (48...57).contains(Int(scalar.value))
    }

    private static func isAsciiLetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        (97...122).contains(Int(scalar.value))
            || (65...90).contains(Int(scalar.value))
            || (48...57).contains(Int(scalar.value))
    }

    private static func truncatedToolbarLabel(_ value: String) -> String {
        guard value.count > toolbarLabelPrefixLength else { return value }
        return "\(value.prefix(toolbarLabelPrefixLength))…"
    }
}

/// Compose restored terminal text so the captured scrollback and one-time agent
/// recovery hint travel through the same shell replay path.
func recoveryReplayText(scrollback: String?, agentSession: AgentSessionSnapshot?) -> String? {
    let hint = agentSession
        .flatMap { AgentSession(kind: $0.kind, sessionId: $0.sessionId) }?
        .recoveryMessage
    let history = (scrollback?.isEmpty == false) ? scrollback : nil
    switch (history, hint) {
    case let (history?, hint?):
        let separator = history.hasSuffix("\n") ? "\n" : "\n\n"
        return "\(history)\(separator)\(hint)\n"
    case let (history?, nil):
        return history
    case let (nil, hint?):
        return "\(hint)\n"
    case (nil, nil):
        return nil
    }
}

/// The agents DanTerm knows by name. One case per agent, so adding an agent
/// cannot leave it known to one lookup and unknown to another -- every piece of
/// per-agent metadata hangs off this enum.
///
/// The raw value is the reported `AgentSession.kind`, already lowercased by
/// `AgentSession.init`.
enum KnownAgent: String {
    case claude
    case codex

    init?(kind: String) {
        self.init(rawValue: kind)
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var chipKind: ChipKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    func resumeCommand(sessionId: String) -> String {
        switch self {
        case .claude: return "claude --resume \(sessionId)"
        case .codex: return "codex resume \(sessionId)"
        }
    }
}

extension ChipKind {
    /// Decides the chip a pane shows from its agent lifecycle.
    ///
    /// The one place the known-agent collapse happens: an agent DanTerm ships no
    /// mark for lands on `.agent`, and no client repeats this mapping because the
    /// roster carries the answer.
    init(agent: AgentLifecycle) {
        guard case .attached(let session, _) = agent else {
            self = .terminal
            return
        }
        self = KnownAgent(kind: session.kind)?.chipKind ?? .agent
    }
}

/// Metadata lookups for an agent kind reported as a raw string, each falling
/// back to what DanTerm can still say about an agent it does not know.
enum AgentCatalog {
    static func displayName(for kind: String) -> String {
        KnownAgent(kind: kind)?.displayName ?? kind.capitalized
    }

    static func resumeCommand(for session: AgentSession) -> String? {
        KnownAgent(kind: session.kind)?.resumeCommand(sessionId: session.sessionId)
    }
}
