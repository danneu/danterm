// Defines a validated mobile server address and stateless validation of its editable draft.
// Active target ownership belongs only to MobileReconnectEpisode.
import Foundation

/// One validated server address, so an automatic attempt reuses what a gesture checked
/// rather than re-reading text fields the user may be halfway through editing.
public struct MobileServerTarget: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// The text of the two target fields, exactly as the user left them.
public struct MobileTargetDraft: Equatable, Sendable {
    public let host: String?
    public let port: String?

    public init(host: String?, port: String?) {
        self.host = host
        self.port = port
    }
}

/// Why a draft names no server, in its own vocabulary beside its own field.
///
/// It is deliberately not a `MobileConnectionState`: that vocabulary is total over
/// connection causes and every entry names a remedy against a target, which a form with no
/// target does not have. Keeping it separate is what makes a header reading `Enter a host
/// and port - retrying in 4s` unspellable rather than discouraged.
public enum MobileTargetDraftProblem: Equatable, Sendable {
    case hostMissing
    case portUnusable

    /// The wording the shell paints beside the field; it decides none of it.
    public var label: String {
        switch self {
        case .hostMissing: "Enter the Mac's host name"
        case .portUnusable: "Enter a port number from 0 to 65535"
        }
    }
}

/// The result of checking one draft, with no stored target or scheduling side effect.
public enum MobileTargetDraftValidation: Equatable, Sendable {
    case valid(MobileServerTarget)
    case reportDraft(MobileTargetDraftProblem)
}

extension MobileTargetDraft {
    /// Validates the Go fields without reading or changing the active reconnect episode.
    public func validate() -> MobileTargetDraftValidation {
        let host = (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false else { return .reportDraft(.hostMissing) }
        guard let port, let port = UInt16(port) else {
            return .reportDraft(.portUnusable)
        }
        let target = MobileServerTarget(host: host, port: port)
        return .valid(target)
    }
}
