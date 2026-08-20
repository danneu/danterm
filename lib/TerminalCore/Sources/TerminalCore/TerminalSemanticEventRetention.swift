// The one implementation of J6 retention for terminal semantic events: which of
// them coalesce, what each costs in bytes, and how many events and bytes an
// undelivered batch may hold. Both the engine's own pending accumulator and the
// PTY host's pending update signal accumulate through this type, so the rule
// cannot exist in two versions that drift apart.
//
// What does not belong here: anything that is not a terminal semantic. Clipboard
// writes, damage generations, and the pane's input acknowledgements all have
// their own owners and their own rules, and none of them is bounded by J6.

/// Accumulates terminal semantic events under one bounded retention rule.
///
/// Callers own two things this type deliberately does not. Stream order is one:
/// the same sequence numbers a caller's non-terminal semantics too, so `order`
/// arrives from outside. Bytes retained elsewhere in the same budget are the
/// other -- the engine's hyperlink targets share this ceiling, so the engine
/// reports them on every admission and frees them when told the batch is over
/// budget.
public struct TerminalSemanticEventRetention: Equatable, Sendable {
    /// The most discrete events one undelivered batch retains. Excess events are
    /// dropped as complete units; a retained event is never truncated.
    public static let maximumDiscreteEventCount = 100

    /// The byte ceiling this batch shares with whatever the caller reports as
    /// `externalRetainedBytes`.
    public static let maximumRetainedBytes = 256 * 1_024

    private(set) var title: PendingTerminalSemanticEvent?
    private(set) var workingDirectory: PendingTerminalSemanticEvent?
    private(set) var progress: PendingTerminalSemanticEvent?
    private(set) var discrete: [PendingTerminalSemanticEvent] = []

    public init() {}

    /// True when nothing is retained, so an owner can price its pending work.
    public var isEmpty: Bool {
        title == nil && workingDirectory == nil && progress == nil && discrete.isEmpty
    }

    /// The bytes retained here, for an owner pricing the rest of the shared budget.
    public var retainedBytes: Int {
        (title?.byteCost ?? 0)
            + (workingDirectory?.byteCost ?? 0)
            + (progress?.byteCost ?? 0)
            + discrete.reduce(0) { $0 + $1.byteCost }
    }

    /// Admits one event at `order`, coalescing it over the value it replaces when
    /// the event is a replaceable one.
    ///
    /// `externalRetainedBytes` is what the caller retains in the same budget.
    /// A caller that can free some of it retries once on `.droppedForBytes`;
    /// `.droppedForCount` cannot be helped by freeing bytes.
    @discardableResult
    public mutating func admit(
        _ event: TerminalSemanticEvent,
        order: UInt64,
        externalRetainedBytes: Int = 0
    ) -> TerminalSemanticEventAdmission {
        let candidate = PendingTerminalSemanticEvent(order: order, event: event)
        switch event {
        case .title:
            return admit(candidate, replacing: \.title, externalRetainedBytes: externalRetainedBytes)
        case .workingDirectory:
            return admit(
                candidate,
                replacing: \.workingDirectory,
                externalRetainedBytes: externalRetainedBytes
            )
        case .progress:
            return admit(
                candidate,
                replacing: \.progress,
                externalRetainedBytes: externalRetainedBytes
            )
        case .bell, .integrationReady, .commandStarted, .commandEnded, .connectionDeclared,
            .desktopNotification:
            guard discrete.count < Self.maximumDiscreteEventCount else { return .droppedForCount }
            guard fits(candidate.byteCost, releasing: 0, beside: externalRetainedBytes) else {
                return .droppedForBytes
            }
            discrete.append(candidate)
            return .admitted
        }
    }

    /// Everything retained, in terminal stream order, each value still carrying the
    /// order it was admitted at.
    ///
    /// An owner whose channel carries non-terminal semantics too reads this rather than
    /// `takeAll()`: it has to interleave those values back into one order, and only the
    /// order each retained value ended up at can tell it where.
    public var retainedInStreamOrder: [PendingTerminalSemanticEvent] {
        var events = discrete
        if let title { events.append(title) }
        if let workingDirectory { events.append(workingDirectory) }
        if let progress { events.append(progress) }
        events.sort { $0.order < $1.order }
        return events
    }

    /// Removes everything retained and returns it in terminal stream order.
    public mutating func takeAll() -> [TerminalSemanticEvent] {
        let events = retainedInStreamOrder
        title = nil
        workingDirectory = nil
        progress = nil
        discrete.removeAll(keepingCapacity: true)
        return events.map(\.event)
    }

    /// Keeps the retained value when the newer one does not fit, so byte pressure
    /// never costs the consumer a value it could still have been told about.
    private mutating func admit(
        _ candidate: PendingTerminalSemanticEvent,
        replacing slot: WritableKeyPath<Self, PendingTerminalSemanticEvent?>,
        externalRetainedBytes: Int
    ) -> TerminalSemanticEventAdmission {
        let released = self[keyPath: slot]?.byteCost ?? 0
        guard fits(candidate.byteCost, releasing: released, beside: externalRetainedBytes) else {
            return .droppedForBytes
        }
        self[keyPath: slot] = candidate
        return .admitted
    }

    private func fits(_ byteCost: Int, releasing released: Int, beside external: Int) -> Bool {
        retainedBytes - released + byteCost + external <= Self.maximumRetainedBytes
    }
}

/// States why one admission attempt retained the event or did not, so a caller
/// that shares the byte budget knows whether freeing its own bytes can help.
public enum TerminalSemanticEventAdmission: Equatable, Sendable {
    case admitted
    /// The batch already holds its full count of discrete events.
    case droppedForCount
    /// The event does not fit the shared byte ceiling.
    case droppedForBytes
}

/// Associates a retained event with its latest position in terminal stream order,
/// and prices it against the byte ceiling.
///
/// A coalescing value takes a fresh order on every admission, which is what makes a
/// replaced title or working directory deliver at the newest value's position rather
/// than the position of the value it replaced.
public struct PendingTerminalSemanticEvent: Equatable, Sendable {
    /// Position in the caller's stream order, so a caller can interleave its own
    /// semantics back into one sequence.
    public internal(set) var order: UInt64
    public internal(set) var event: TerminalSemanticEvent

    var byteCost: Int {
        switch event {
        case let .title(value), let .commandStarted(value):
            value.utf8.count
        case let .desktopNotification(title, body):
            title.utf8.count + body.utf8.count
        case let .connectionDeclared(.remote(identity: identity)):
            identity.map { $0.user.utf8.count + $0.host.utf8.count } ?? 0
        case let .workingDirectory(value):
            value?.utf8.count ?? 0
        case .bell, .integrationReady, .commandEnded, .connectionDeclared(.local), .progress:
            0
        }
    }
}
