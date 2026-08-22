// Defines the phone's complete user-facing connection and service-ending vocabulary.
import DanTermClient

/// Names each Mac admission refusal separately because each one has a different remedy.
public enum MobileMacRefusal: Equatable, Sendable {
    case notAdmitted
    case identityUnresolved
    case connectionLimit
    case auditUnavailable
}

/// Presents connection failures as user remedies instead of transport implementation details.
public enum MobileConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready
    case hostNotFound
    case serverUnreachable
    case refusedByMac(MobileMacRefusal)
    case versionMismatch(Int)
    case connectionLost
    case deviceSetupFailure
    case streamEnded(String?)
    case requestRefused(String)
    /// The replica and the producer disagreed about the stream, so this connection ended.
    /// It names a cause like every other state here, not the live condition of a serving
    /// stream: the disagreement is what the phone is reconnecting away from.
    case streamDesynchronized

    /// Exhaustively maps every public TCP error to one user-facing remedy.
    public static func failure(_ error: TCPSocketTransportError) -> Self {
        switch error {
        case .unresolvedHost: .hostNotFound
        case .connectFailed, .connectTimedOut: .serverUnreachable
        case .configureFailed, .configureTimeoutFailed: .deviceSetupFailure
        case .timedOut, .readFailed, .writeFailed, .peerClosed: .connectionLost
        }
    }

    /// Exhaustively maps conversation errors without a residual generic state.
    public static func failure(_ error: DanTermClientError) -> Self {
        switch error {
        case .cancelled: .disconnected
        case .notAdmitted: .refusedByMac(.notAdmitted)
        case .identityUnresolved: .refusedByMac(.identityUnresolved)
        case .connectionLimit: .refusedByMac(.connectionLimit)
        case .auditUnavailable: .refusedByMac(.auditUnavailable)
        case .unsupportedProtocol(let version): .versionMismatch(version)
        case .closedBeforeHello, .invalidHello, .oversizedLine, .peerSilent: .connectionLost
        }
    }

    /// Words the same failures for a connection that was still being established.
    ///
    /// Only silence changes meaning with the phase, and the phase is what the caller
    /// knows: a stream that never started serving did not go down, it never answered, and
    /// the remedy the user needs is the one for a Mac that is not reachable. Keeping this
    /// distinction here leaves the total error-to-state map above free of phase.
    public static func establishmentFailure(_ error: DanTermClientError) -> Self {
        error == .peerSilent ? .serverUnreachable : failure(error)
    }

    /// Preserves the producer's ordinary end reason as an ending rather than a failure.
    public static func streamEnded(reason: String?) -> Self { .streamEnded(reason) }

    /// Preserves a server error reply and its reason independently from transport state.
    public static func requestRefused(reason: String) -> Self { .requestRefused(reason) }
}
