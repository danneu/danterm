// Decides which connect gesture may read the draft target fields, and what an unusable
// draft is allowed to say.
//
// The two gestures that start a connection are about different things: the Go button names
// a server, and a pane row names a pane inside the episode that already produced the list.
// Running both through one shell route that re-read the text fields is what let a
// half-edited host answer a gesture about an established target, so the distinction lives
// here, where it has a test.
//
// What does not belong here: when an attempt runs (`MobileReconnectPolicy`'s), and how the
// connection status line reads (`MobileStatus`'s) -- a draft problem is never a connection
// cause and never composes with a recovery phase.
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

/// What a connect gesture resolved to. It carries a target or it carries a problem, so the
/// shell cannot report one as the other.
public enum MobileConnectGesture: Equatable, Sendable {
    /// Start an episode against this target.
    case connect(MobileServerTarget)
    /// The draft names no server. Report it beside the fields and leave the policy alone: a
    /// typo must not cancel a retry already owed to a good target.
    case reportDraft(MobileTargetDraftProblem)
    /// There is no episode to reconnect to, and this gesture may not read the draft.
    case ignore
}

/// Holds the target the current episode is about and answers each connect gesture from it.
public struct MobileConnectTarget: Equatable, Sendable {
    /// The target every attempt in the current episode reuses, until a gesture retargets it.
    public private(set) var established: MobileServerTarget?

    public init() {}

    /// The gesture that names a server -- the Go button, or the attempt made at launch. It
    /// is the only one that retargets the episode, and an unusable draft leaves the
    /// established target exactly as it was.
    public mutating func setTarget(from draft: MobileTargetDraft) -> MobileConnectGesture {
        let host = (draft.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false else { return .reportDraft(.hostMissing) }
        guard let portText = draft.port, let port = UInt16(portText) else {
            return .reportDraft(.portUnusable)
        }
        let target = MobileServerTarget(host: host, port: port)
        established = target
        return .connect(target)
    }

    /// The gesture that names a pane inside the episode that produced the list. It takes no
    /// draft, so the text fields have no way to answer it.
    public func reuseTarget() -> MobileConnectGesture {
        established.map(MobileConnectGesture.connect) ?? .ignore
    }
}
