// Pure representation of coding-agent sessions reported from a pane. This file
// owns validation of untrusted hook/snapshot strings plus the small known-agent
// catalog used for toolbar and recovery text. Keep it free of AppKit and IPC
// transport details; callers hand raw strings in and get safe display text out.
import Foundation

/// An agent session reported as currently running inside a pane.
///
/// The live value is intentionally not Codable: checkpoints persist the raw
/// `AgentSessionSnapshot` DTO, then validate again at recovery-message consumption.
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
            return "[DanTerm] You were inside \(displayName) session \(sessionId) -- resume with: \(command)"
        }
        return "[DanTerm] You were inside a \(displayName) session \(sessionId)"
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

/// Display and resume-command metadata for agent kinds DanTerm knows by name.
enum AgentCatalog {
    static func displayName(for kind: String) -> String {
        switch kind {
        case "claude":
            return "Claude"
        case "codex":
            return "Codex"
        default:
            return kind.capitalized
        }
    }

    static func resumeCommand(for session: AgentSession) -> String? {
        switch session.kind {
        case "claude":
            return "claude -r \(session.sessionId)"
        case "codex":
            return "codex resume \(session.sessionId)"
        default:
            return nil
        }
    }
}
