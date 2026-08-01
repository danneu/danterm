// Bounded in-memory capture of one live pane's feed and resize drive sequence. The PTY
// owner records without encoding or IO; dump callers fence a value snapshot for later work.
import PaneLifecycle
import TerminalCoreRecording

/// Bounds retained payload and metadata independently so both bulk and tiny PTY chunks fit.
package struct TerminalFlightRecorderConfiguration: Sendable {
    package static let production = Self(
        budgetBytes: 8 * 1_024 * 1_024,
        eventLimit: 32_768,
        eventOverheadBytes: 128
    )

    package let budgetBytes: Int
    package let eventLimit: Int
    package let eventOverheadBytes: Int

    package init(budgetBytes: Int, eventLimit: Int, eventOverheadBytes: Int) {
        precondition(budgetBytes >= 0)
        precondition(eventLimit >= 0)
        precondition(eventOverheadBytes >= 0)
        self.budgetBytes = budgetBytes
        self.eventLimit = eventLimit
        self.eventOverheadBytes = eventOverheadBytes
    }
}

/// Pairs one neutral transition with capture time relative to pane construction.
public struct TerminalFlightRecordingEvent: Equatable, Sendable {
    /// Replayable transition captured at the PTY owner's actual application boundary.
    public let event: NeutralTerminalRecordingEvent
    /// Monotonic time since this pane's recorder was constructed.
    public let elapsedNanoseconds: UInt64

    /// Keeps timing metadata beside, but behaviorally independent from, the replay event.
    public init(event: NeutralTerminalRecordingEvent, elapsedNanoseconds: UInt64) {
        self.event = event
        self.elapsedNanoseconds = elapsedNanoseconds
    }
}

/// Immutable dump boundary whose arrays retain feed storage by reference until encoding ends.
public struct TerminalFlightRecordingSnapshot: Equatable, Sendable {
    /// Pane geometry that existed before the first retained transition.
    public let initial: NeutralTerminalDimensions
    /// Oldest-to-newest retained transitions with their inert capture timestamps.
    public let events: [TerminalFlightRecordingEvent]
    /// Retained payload plus conservative per-event allocation overhead.
    public let accountedBytes: Int
    /// Lifetime count of whole events removed from the recording head.
    public let droppedEventCount: Int
    /// Lifetime payload bytes represented by removed events.
    public let droppedPayloadBytes: Int

    /// True once any event was dropped, even if later writes leave ample free budget.
    public var isTruncated: Bool { droppedEventCount > 0 }
}

/// Owner-queue-only FIFO that releases evicted payload storage without shifting an array.
package final class TerminalFlightRecorder {
    private final class Node {
        let event: TerminalFlightRecordingEvent
        let payloadBytes: Int
        var next: Node?

        init(event: TerminalFlightRecordingEvent, payloadBytes: Int) {
            self.event = event
            self.payloadBytes = payloadBytes
        }
    }

    private let initial: NeutralTerminalDimensions
    private let configuration: TerminalFlightRecorderConfiguration
    private let now: @Sendable () -> UInt64
    private let startedNanoseconds: UInt64
    private var lastElapsedNanoseconds: UInt64 = 0
    private var head: Node?
    private var tail: Node?
    private var eventCount = 0
    private var accountedBytes = 0
    private var droppedEventCount = 0
    private var droppedPayloadBytes = 0

    package init(
        initialDimensions: TerminalDimensions,
        configuration: TerminalFlightRecorderConfiguration = .production,
        now: @escaping @Sendable () -> UInt64
    ) {
        initial = .init(
            columns: initialDimensions.columns,
            rows: initialDimensions.rows
        )
        self.configuration = configuration
        self.now = now
        startedNanoseconds = now()
    }

    deinit {
        while let current = head {
            head = current.next
            current.next = nil
        }
        tail = nil
    }

    package func record(_ event: NeutralTerminalRecordingEvent) {
        let current = now()
        let measured = current >= startedNanoseconds ? current - startedNanoseconds : 0
        let elapsed = max(lastElapsedNanoseconds, measured)
        lastElapsedNanoseconds = elapsed
        let payloadBytes = Self.payloadBytes(of: event)
        let node = Node(
            event: .init(event: event, elapsedNanoseconds: elapsed),
            payloadBytes: payloadBytes
        )
        if let tail {
            tail.next = node
        } else {
            head = node
        }
        tail = node
        eventCount += 1
        accountedBytes += payloadBytes + configuration.eventOverheadBytes
        enforceBounds()
    }

    package func snapshot() -> TerminalFlightRecordingSnapshot {
        var events: [TerminalFlightRecordingEvent] = []
        events.reserveCapacity(eventCount)
        var node = head
        while let current = node {
            events.append(current.event)
            node = current.next
        }
        return TerminalFlightRecordingSnapshot(
            initial: initial,
            events: events,
            accountedBytes: accountedBytes,
            droppedEventCount: droppedEventCount,
            droppedPayloadBytes: droppedPayloadBytes
        )
    }

    private func enforceBounds() {
        while accountedBytes > configuration.budgetBytes
            || eventCount > configuration.eventLimit
        {
            guard let evicted = head else { break }
            head = evicted.next
            if head == nil { tail = nil }
            eventCount -= 1
            accountedBytes -= evicted.payloadBytes + configuration.eventOverheadBytes
            droppedEventCount += 1
            droppedPayloadBytes += evicted.payloadBytes
        }
    }

    private static func payloadBytes(of event: NeutralTerminalRecordingEvent) -> Int {
        if case .feed(let bytes) = event { return bytes.count }
        return 0
    }
}
