// The phone's whole reconnect policy: which failures are worth another attempt, and when
// the next attempt may run.
//
// The policy is pure. It performs no attempt, opens no socket, and owns no timer: it
// consumes injected events -- attempt outcomes, clock ticks, network-path status, app
// lifecycle, user gestures -- and answers with one decision the shell executes. Keeping
// the whole decision here is what makes the retry rules testable without a device, and
// what keeps retry from becoming a second path that mutates resume state.
//
// What does not belong here: the user-facing wording of a failure (the shell's), how an
// attempt is performed (`MobileSessionAttempt`'s), and any stored resume position
// (`MobileConnectionModel`'s).
import DanTermClient
import DanTermProtocol
import Foundation

/// Distinguishes a connection that never started serving from one that went down.
///
/// Only the caller knows which half of a connection's life ended, and silence means
/// different things in each: a stream that never answered is a Mac that is not reachable,
/// while silence on a serving stream is a connection that was lost.
public enum MobileConnectionPhase: Equatable, Sendable {
    case establishing
    case established
}

/// Every way an attempt or a live connection can end, in the typed form the producing
/// layer reports.
///
/// It exists because the collapsed user-facing state is not enough to schedule against: a
/// malformed hello and a dropped stream both present as "Connection lost", and only the
/// second is worth retrying. Both maps below are exhaustive switches with no default, so
/// a new cause fails to compile rather than shipping unscheduled or unpresented.
public enum MobileConnectionFailure: Equatable, Sendable {
    case transport(TCPSocketTransportError, phase: MobileConnectionPhase)
    case conversation(DanTermClientError, phase: MobileConnectionPhase)
    case streamEnded(reason: String?)
    case requestRefused(reason: String)
    /// The phone could not make sense of what it got, or of its own setup: a reply with
    /// neither result nor error, a replica that rejected the stream, an error no typed
    /// layer produced. It is the phone's own defect, so no server can change it.
    case deviceSetup

    /// The remedy this failure presents to the user. The vocabulary is unchanged by retry:
    /// recovery decorates this state, it never replaces it.
    public var state: MobileConnectionState {
        switch self {
        // A transport failure words the same in both phases: none of them is silence, and
        // each already names a condition rather than a stage.
        case .transport(let error, _): MobileConnectionState.failure(error)
        case .conversation(let error, .establishing):
            MobileConnectionState.establishmentFailure(error)
        case .conversation(let error, .established): MobileConnectionState.failure(error)
        case .streamEnded(let reason): MobileConnectionState.streamEnded(reason: reason)
        case .requestRefused(let reason): MobileConnectionState.requestRefused(reason: reason)
        case .deviceSetup: MobileConnectionState.deviceSetupFailure
        }
    }

    /// Whether another attempt can change this outcome, and how soon.
    public var retryClass: MobileRetryClass {
        switch self {
        case .transport(let error, _):
            switch error {
            // A typo or a tailnet that cannot resolve the name is not fixed by waiting,
            // and a socket this device cannot configure is a local setup defect.
            case .unresolvedHost, .configureFailed, .configureTimeoutFailed: .manual
            case .connectFailed, .connectTimedOut, .timedOut, .readFailed, .writeFailed,
                 .peerClosed: .transient
            }
        case .conversation(let error, _):
            switch error {
            // A peer that closed before speaking has not said anything wrong, so it reads
            // as an interruption rather than a violation.
            case .closedBeforeHello, .peerSilent: .transient
            // The refusing server states the deadline by which it has reclaimed a dead
            // peer's slot; a refusal that stated none falls back to the contract default.
            case .connectionLimit(let bound): .capacity(after: bound ?? .standard)
            case .cancelled, .invalidHello, .oversizedLine, .unsupportedProtocol,
                 .notAdmitted, .identityUnresolved, .auditUnavailable: .manual
            }
        // A producer that ended its stream and a server that refused a request both
        // answered; repeating the question gets the same answer, and a defect on this
        // phone reruns unchanged on the next attempt.
        case .streamEnded, .requestRefused, .deviceSetup: .manual
        }
    }
}

/// How soon, if ever, an automatic attempt may follow a failure.
///
/// This is scheduling, deliberately separate from `MobileConnectionState`: that enum is
/// the user's remedy vocabulary, and folding retry into it would couple presentation to
/// scheduling and invite policy-shaped states.
public enum MobileRetryClass: Equatable, Sendable {
    /// An interruption another attempt can heal.
    case transient
    /// The Mac had no connection slot. The bound is that server's reclamation deadline,
    /// so it is the earliest moment a retry can help rather than compete.
    case capacity(after: IpcLivenessBound)
    /// Nothing an automatic attempt can change; the user's gesture is the remedy.
    case manual
}

/// Everything the policy must be told, from the shell that observes it.
public enum MobileReconnectEvent: Equatable, Sendable {
    /// The in-flight attempt, or the connection it established, ended with this cause.
    case attemptFailed(MobileConnectionFailure)
    /// The in-flight attempt reached a serving connection.
    case attemptConnected
    /// The shell's retry timer fired.
    case clockFired
    /// The phone's network path became usable, or stopped being usable.
    case networkPathChanged(usable: Bool)
    case appForegrounded
    case appBackgrounded
    /// The user asked to connect -- the Go button, or picking a pane.
    case userRequestedConnect
    /// The user dropped the connection or the attempt.
    case userCancelled
}

/// The only thing the policy asks the shell to do.
public enum MobileReconnectDecision: Equatable, Sendable {
    /// Start one attempt now.
    case attemptNow
    /// Schedule a `clockFired` event for this time.
    case wait(until: TimeInterval)
    /// Cancel any pending timer and schedule nothing.
    case rest
}

/// What the app is doing about the current failure, presented beside the causal state.
///
/// It is separate from `MobileConnectionState` so the user always sees both what happened
/// and what is being done about it. `none` after give-up is deliberate: the plain terminal
/// failure state with its manual remedy is the honest presentation of rest.
public enum MobileRecoveryPhase: Equatable, Sendable {
    case none
    case attempting
    case waiting(until: TimeInterval)
    /// The clock is suspended because no attempt could succeed without a network path.
    case waitingForNetwork
}

/// Decides when the phone attempts a connection, and when it stops trying.
///
/// The type is a value: a caller holds one, feeds it events with an explicit clock
/// reading, and acts on what it returns. `handle` is the only entry point that advances
/// it, and it marks its own attempt in flight when it returns `attemptNow`, so a second
/// trigger arriving before the outcome cannot start an overlapping attempt.
public struct MobileReconnectPolicy: Equatable, Sendable {
    /// The bounded shape of one automatic episode.
    ///
    /// The delays are per remaining attempt and their count *is* the budget, so the
    /// episode's total effort is stated in one place and cannot grow by accident.
    public struct Schedule: Equatable, Sendable {
        /// The wait before each successive automatic attempt. A leading zero makes the
        /// common blip heal without a visible pause.
        public let delays: [TimeInterval]
        /// How long a connection must serve before it counts as stable enough to rearm
        /// the budget. Without it, a connect-then-die flap would retry forever.
        public let stabilityWindow: TimeInterval

        public init(delays: [TimeInterval], stabilityWindow: TimeInterval) {
            precondition(delays.isEmpty == false, "an episode needs at least one attempt")
            self.delays = delays
            self.stabilityWindow = stabilityWindow
        }

        /// Five attempts over about a minute, then rest. Long enough to cover a lift
        /// between cells or a router reboot, short enough that a closed lid costs little.
        public static let standard = Schedule(delays: [0, 2, 5, 15, 30], stabilityWindow: 60)
    }

    /// What the policy owes the connection right now.
    private enum Standing: Equatable {
        /// Nothing outstanding: connected, attempting, or never started.
        case clear
        /// An automatic attempt is due at `scheduledAt`. `notBefore` is the class's own
        /// floor, which a signal may advance the schedule to but never past.
        case waiting(scheduledAt: TimeInterval, notBefore: TimeInterval)
        /// The budget is spent. A signal buys one attempt, no earlier than `notBefore`.
        case gaveUp(notBefore: TimeInterval)
        /// Only a user gesture can change this outcome.
        case manual
    }

    private let schedule: Schedule
    private var standing = Standing.clear
    private var attemptsUsed = 0
    private var attemptInFlight = false
    private var foregrounded = true
    private var pathUsable = true
    private var connectedAt: TimeInterval?

    public init(schedule: Schedule = .standard) {
        self.schedule = schedule
    }

    /// Advances the policy by one event and states what the shell should do next.
    public mutating func handle(
        _ event: MobileReconnectEvent,
        at now: TimeInterval
    ) -> MobileReconnectDecision {
        switch event {
        case .attemptFailed(let failure):
            attemptInFlight = false
            rearmIfConnectionWasStable(endingAt: now)
            standing = standing(after: failure, at: now)
        case .attemptConnected:
            attemptInFlight = false
            connectedAt = now
            standing = .clear
        case .clockFired:
            break
        case .networkPathChanged(let usable):
            pathUsable = usable
            if usable { armForSignal(at: now) }
        case .appForegrounded:
            foregrounded = true
            armForSignal(at: now)
        case .appBackgrounded:
            // The shell cancels the attempt on its way out, and iOS suspends the app, so
            // nothing may remain scheduled. The standing survives, because foreground
            // return is itself the trigger that resumes the episode. A connection or
            // attempt the shell dropped on the way out is one the app still owes, so it
            // becomes due the moment the app returns -- without restoring the budget,
            // which only stability or a gesture does.
            foregrounded = false
            if connectedAt != nil || attemptInFlight {
                rearmIfConnectionWasStable(endingAt: now)
                standing = .waiting(scheduledAt: now, notBefore: now)
            }
            attemptInFlight = false
            connectedAt = nil
        case .userCancelled:
            attemptInFlight = false
            connectedAt = nil
            standing = .manual
        case .userRequestedConnect:
            // The gesture is the manual remedy itself, so it restores the whole policy
            // from any class or phase and answers to neither the path nor a class floor.
            connectedAt = nil
            attemptsUsed = 0
            standing = .clear
            guard attemptInFlight == false else { return .rest }
            attemptInFlight = true
            return .attemptNow
        }
        return automaticDecision(at: now)
    }

    /// States what the shell should show beside the causal failure. Pure: unlike `handle`,
    /// asking does not advance the policy.
    public func recoveryPhase(at now: TimeInterval) -> MobileRecoveryPhase {
        if attemptInFlight { return .attempting }
        guard case .waiting(let scheduledAt, _) = standing, foregrounded else { return .none }
        guard pathUsable else { return .waitingForNetwork }
        return .waiting(until: max(scheduledAt, now))
    }

    private mutating func automaticDecision(at now: TimeInterval) -> MobileReconnectDecision {
        guard attemptInFlight == false, foregrounded, pathUsable else { return .rest }
        guard case .waiting(let scheduledAt, _) = standing else { return .rest }
        guard scheduledAt <= now else { return .wait(until: scheduledAt) }
        attemptInFlight = true
        attemptsUsed += 1
        standing = .clear
        return .attemptNow
    }

    /// Schedules the next automatic attempt, or gives up, according to the failure's class.
    private func standing(
        after failure: MobileConnectionFailure,
        at now: TimeInterval
    ) -> Standing {
        switch failure.retryClass {
        case .manual:
            return .manual
        case .transient:
            guard attemptsUsed < schedule.delays.count else { return .gaveUp(notBefore: now) }
            return .waiting(scheduledAt: now + schedule.delays[attemptsUsed], notBefore: now)
        case .capacity(let bound):
            let floor = now + bound.seconds
            guard attemptsUsed < schedule.delays.count else { return .gaveUp(notBefore: floor) }
            return .waiting(
                scheduledAt: max(now + schedule.delays[attemptsUsed], floor),
                notBefore: floor
            )
        }
    }

    /// Brings a pending attempt forward to its class floor when a real signal arrives. A
    /// signal never restores the budget: only a stable connection or a gesture does, so a
    /// flapping path costs one attempt per restoration rather than a fresh episode.
    private mutating func armForSignal(at now: TimeInterval) {
        switch standing {
        case .waiting(_, let notBefore), .gaveUp(let notBefore):
            standing = .waiting(scheduledAt: max(now, notBefore), notBefore: notBefore)
        case .clear, .manual:
            break
        }
    }

    private mutating func rearmIfConnectionWasStable(endingAt now: TimeInterval) {
        if let connectedAt, now - connectedAt >= schedule.stabilityWindow { attemptsUsed = 0 }
        connectedAt = nil
    }
}
