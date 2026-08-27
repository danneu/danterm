// Pure enriched-recovery scheduling policy for bounded writes and quiescence.

/// Describes runtime work requested by one deterministic recovery-policy event.
enum RecoveryCheckpointAction: Equatable, Sendable {
    case none
    case schedule(deadline: UInt64)
    case write(revision: UInt64)
    case cancel
}

/// Tracks which primary-history revision is dirty without owning clocks, timers, or disk IO.
struct RecoveryCheckpointPolicy: Equatable, Sendable {
    private let window: UInt64
    private var latestRevision: UInt64 = 0
    private var coveredRevision: UInt64 = 0
    private var writeInFlightRevision: UInt64?
    private var isTerminated = false

    private(set) var scheduledDeadline: UInt64?

    init(window: UInt64) {
        self.window = window
    }

    var isDirty: Bool {
        latestRevision > coveredRevision
    }

    mutating func mutation(at instant: UInt64) -> RecoveryCheckpointAction {
        guard isTerminated == false else { return .none }
        latestRevision &+= 1
        guard scheduledDeadline == nil else { return .none }
        let deadline = instant &+ window
        scheduledDeadline = deadline
        return .schedule(deadline: deadline)
    }

    mutating func deadlineReached(at instant: UInt64) -> RecoveryCheckpointAction {
        guard isTerminated == false,
              writeInFlightRevision == nil,
              let deadline = scheduledDeadline,
              instant >= deadline,
              isDirty
        else { return .none }
        scheduledDeadline = nil
        writeInFlightRevision = latestRevision
        return .write(revision: latestRevision)
    }

    mutating func writeCompleted(
        revision: UInt64,
        succeeded: Bool,
        at instant: UInt64
    ) -> RecoveryCheckpointAction {
        guard writeInFlightRevision == revision else { return .none }
        writeInFlightRevision = nil
        if succeeded {
            coveredRevision = max(coveredRevision, revision)
            guard isDirty else {
                scheduledDeadline = nil
                return .cancel
            }
            if let overdueWrite = beginOverdueWrite(at: instant) {
                return overdueWrite
            }
            return .none
        }
        if let overdueWrite = beginOverdueWrite(at: instant) {
            return overdueWrite
        }
        guard scheduledDeadline == nil else { return .none }
        let deadline = instant &+ window
        scheduledDeadline = deadline
        return .schedule(deadline: deadline)
    }

    /// Marks the policy terminated so no later event can arm a timer or start a write. The exit
    /// path writes unconditionally after this, because that write also refreshes the model
    /// snapshot the policy knows nothing about -- so there is no decision here to return.
    mutating func terminate() {
        isTerminated = true
        scheduledDeadline = nil
        writeInFlightRevision = nil
    }

    private mutating func beginOverdueWrite(at instant: UInt64) -> RecoveryCheckpointAction? {
        guard let deadline = scheduledDeadline, instant >= deadline else { return nil }
        scheduledDeadline = nil
        writeInFlightRevision = latestRevision
        return .write(revision: latestRevision)
    }
}
