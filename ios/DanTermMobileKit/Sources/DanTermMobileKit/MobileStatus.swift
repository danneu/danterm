// Composes the one line of status the phone shows, from the four separately owned facts
// that make it up.
//
// It is a pure value so the wording, the severity, and the composition rules are testable
// where the iOS app target has no tests at all. Each fact has exactly one writer and its
// own slot, which is what makes the old borrow -- a stream condition stored in the
// connection state and reversed by hand with a flag -- unspellable here.
//
// What does not belong here: colors, fonts, and any other UIKit decision (the shell's),
// when a retry runs (`MobileReconnectPolicy`'s), and where it resumes from
// (`MobileResumePolicy`'s).
import Foundation

/// The outcome of the most recent completed request that was not the tape subscription.
///
/// It is a level-triggered fact rather than an event: the next completed request replaces
/// it and a successful one clears it, so a refusal cannot outlive the condition it reports
/// and no caller has to remember to expire it.
public enum MobileRequestOutcome: Equatable, Sendable {
    case succeeded
    case refused(reason: String)
}

/// How loudly the status reads, so the shell chooses a color without re-deciding meaning.
///
/// `degraded` exists because something can go wrong on a connection that is still serving;
/// styling that as a failure would tell the user their connection is gone when it is not.
public enum MobileStatusSeverity: Equatable, Sendable {
    case normal
    case degraded
    case failed
}

/// One rendered status line: what it says and how it should read.
public struct MobileStatusLine: Equatable, Sendable {
    public let text: String
    public let severity: MobileStatusSeverity

    public init(text: String, severity: MobileStatusSeverity) {
        self.text = text
        self.severity = severity
    }
}

/// Holds the four status facts apart and composes them on demand.
///
/// Composition is a function of the stored facts and the clock, never of the order they
/// were written in, so the shell can report each observation as it arrives and never has
/// to undo one fact to state another.
public struct MobileStatus: Equatable, Sendable {
    /// Readable so the shell projects other controls from the same stored fact instead
    /// of keeping a second copy of the connection state that could disagree with this one.
    public private(set) var connection = MobileConnectionState.disconnected
    private var connectionDetail: String?
    private var recovery = MobileRecoveryPhase.none
    /// The replica's own condition, or nothing when no stream is attached.
    private var stream: PaneReplicaState?
    /// Nothing until a non-tape request has completed on this connection.
    private var requestOutcome: MobileRequestOutcome?

    /// Creates the status of an app that has not connected yet.
    public init() {}

    /// Records why the connection is in the state it is, with the caller's own wording when
    /// it knows something the state cannot carry, such as the target it is dialing.
    public mutating func noteConnection(_ state: MobileConnectionState, detail: String? = nil) {
        connection = state
        connectionDetail = detail
    }

    /// Records what the app is doing about the current failure.
    public mutating func noteRecovery(_ phase: MobileRecoveryPhase) {
        recovery = phase
    }

    /// Records the replica's condition; nothing means there is no stream to describe.
    public mutating func noteStream(_ state: PaneReplicaState?) {
        stream = state
    }

    /// Records how the newest completed non-tape request ended; nothing means none has.
    public mutating func noteRequestOutcome(_ outcome: MobileRequestOutcome?) {
        requestOutcome = outcome
    }

    /// Composes the line to show now. The clock is a parameter because a scheduled retry
    /// is worded as the time remaining, which only the moment of display can state.
    public func line(at now: TimeInterval) -> MobileStatusLine {
        var parts = [connectionDetail ?? connection.label]
        // A stream condition and a request outcome describe a connection that is serving.
        // Beside any other connection state they would claim something about a connection
        // that is not there, so they are simply not part of the line.
        if connection.standing == .serving {
            if let clause = stream?.label { parts.append(clause) }
            if let clause = requestOutcome?.label { parts.append(clause) }
        }
        if let clause = recovery.label(at: now) { parts.append(clause) }
        return MobileStatusLine(text: parts.joined(separator: " - "), severity: severity)
    }

    private var severity: MobileStatusSeverity {
        switch connection.standing {
        case .failed: .failed
        case .idle: .normal
        case .serving: isDegraded ? .degraded : .normal
        }
    }

    /// Something has gone wrong on a connection that is nonetheless still serving.
    private var isDegraded: Bool {
        if case .gap = stream { return true }
        if case .refused = requestOutcome { return true }
        return false
    }
}

/// How a connection state reads to the user, derived once so severity and the decision to
/// show a serving connection's facts cannot disagree.
private enum MobileConnectionStanding: Equatable {
    /// The connection is carrying a stream right now.
    case serving
    /// Nothing is wrong and nothing is serving.
    case idle
    /// The connection is not serving because something went wrong.
    case failed
}

private extension MobileConnectionState {
    /// Total over the vocabulary with no residual arm, so a state added later cannot
    /// inherit failure styling by default -- it fails to compile until someone chooses.
    var standing: MobileConnectionStanding {
        switch self {
        case .ready: .serving
        case .disconnected, .connecting, .listingPanes: .idle
        case .hostNotFound, .serverUnreachable, .refusedByMac, .versionMismatch,
             .connectionLost, .deviceSetupFailure, .streamEnded, .requestRefused,
             .streamDesynchronized: .failed
        }
    }

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .listingPanes: "Loading panes"
        case .ready: "Connected"
        case .hostNotFound: "Host not found"
        case .serverUnreachable: "Server unreachable"
        case .refusedByMac(let reason): "Refused by the Mac: \(reason.label)"
        case .versionMismatch(let version): "Version mismatch: protocol \(version)"
        case .connectionLost: "Connection lost"
        case .deviceSetupFailure: "Device setup failure"
        case .streamEnded(let reason): "Stream ended\(reason.map { ": \($0)" } ?? "")"
        case .requestRefused(let reason): "Request refused: \(reason)"
        case .streamDesynchronized: "Stream out of step with the Mac"
        }
    }
}

private extension MobileMacRefusal {
    var label: String {
        switch self {
        case .notAdmitted: "node not admitted"
        case .identityUnresolved: "identity unresolved"
        case .connectionLimit: "connection limit"
        case .auditUnavailable: "audit unavailable"
        }
    }
}

private extension PaneReplicaState {
    /// Words what the replica is holding, or nothing when it is exact and has nothing to
    /// add to the connection state beside it.
    var label: String? {
        switch self {
        case .exact: nil
        case .awaitingSynchronization: "waiting for exact state"
        // The producer already sent the replacement sync, so the wait ends on its own.
        case .gap(.declared): "stream gap; waiting for exact state"
        // Said only for the moment before the shell ends the connection over it: the
        // producer sends no repair for a gap it does not know about.
        case .gap(.detected): "stream out of step with the Mac"
        }
    }
}

private extension MobileRequestOutcome {
    /// Words a refusal, and says nothing at all about a request that worked.
    var label: String? {
        switch self {
        case .succeeded: nil
        case .refused(let reason): "request refused: \(reason)"
        }
    }
}

private extension MobileRecoveryPhase {
    /// Words the pending recovery, or nothing when there is none to report.
    func label(at now: TimeInterval) -> String? {
        switch self {
        case .none: nil
        case .attempting: "reconnecting"
        case .waiting(let until): "retrying in \(Int(max(0, until - now).rounded(.up)))s"
        case .waitingForNetwork: "waiting for network"
        }
    }
}
