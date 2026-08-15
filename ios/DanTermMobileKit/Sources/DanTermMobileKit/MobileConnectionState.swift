// Defines the phone's complete user-facing connection and service-ending vocabulary.
import DanTermClient
import DanTermProtocol

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
    case listingPanes
    case ready
    case hostNotFound
    case serverUnreachable
    case refusedByMac(MobileMacRefusal)
    case versionMismatch(Int)
    case connectionLost
    case deviceSetupFailure
    case streamEnded(String?)
    case requestRefused(String)

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
        case .notAdmitted: .refusedByMac(.notAdmitted)
        case .identityUnresolved: .refusedByMac(.identityUnresolved)
        case .connectionLimit: .refusedByMac(.connectionLimit)
        case .auditUnavailable: .refusedByMac(.auditUnavailable)
        case .unsupportedProtocol(let version): .versionMismatch(version)
        case .closedBeforeHello, .invalidHello, .oversizedLine: .connectionLost
        }
    }

    /// Preserves the producer's ordinary end reason as an ending rather than a failure.
    public static func streamEnded(reason: String?) -> Self { .streamEnded(reason) }

    /// Preserves a server error reply and its reason independently from transport state.
    public static func requestRefused(reason: String) -> Self { .requestRefused(reason) }
}

/// Holds reconnect progress and one resumable cursor per pane independently from UIKit.
public struct MobileConnectionModel: Equatable, Sendable {
    public private(set) var state = MobileConnectionState.disconnected
    public private(set) var target: String?
    private var cursorsByPane: [PaneId: PaneTapeCursor] = [:]

    /// Creates a disconnected model with no saved stream positions.
    public init() {}

    /// Begins a first connection or explicit retry without discarding resume positions.
    public mutating func connect(to target: String) {
        self.target = target
        state = .connecting
    }

    /// Advances from the protocol handshake to the one explicit pane-list refresh.
    public mutating func didHandshake() {
        state = .listingPanes
    }

    /// Marks the connection ready after its pane list has loaded.
    public mutating func didLoadPanes() {
        state = .ready
    }

    /// Records a terminal connection outcome while retaining every resume cursor.
    public mutating func didEnd(with state: MobileConnectionState) {
        self.state = state
    }

    /// Saves only the newest exact cursor that the replica has applied.
    public mutating func record(_ cursor: PaneTapeCursor, forPane paneId: PaneId) {
        cursorsByPane[paneId] = cursor
    }

    /// Starts a new pane at an exact fence and resumes a known pane from its last cursor.
    public func startPosition(forPane paneId: PaneId) -> PaneTapeStartPosition {
        cursorsByPane[paneId].map(PaneTapeStartPosition.cursor) ?? .now
    }
}
