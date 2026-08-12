// Bounded in-memory capture of one live pane's feed and resize drive sequence. The PTY
// owner records without encoding or IO; dump callers fence a value snapshot for later work.
import PaneProcessLifecycle
import DequeModule
import Foundation
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

/// Locates one byte-carrying event inside its own direction's lifetime byte stream.
///
/// The direction is the event itself: a feed event's offset counts feed bytes only, and a write
/// event's counts write bytes only. Keeping the two streams apart is what lets a reader turn an
/// offset back into a position, which a single interleaved counter cannot do.
public struct TerminalFlightRecordingPayloadSpan: Equatable, Sendable {
    /// Zero-based count of this direction's bytes recorded before this event.
    public let byteOffset: Int
    /// Bytes this event carries; zero is a real, recordable transfer.
    public let byteLength: Int

    /// Keeps the two coordinates together so neither can be read without the other.
    public init(byteOffset: Int, byteLength: Int) {
        precondition(byteOffset >= 0)
        precondition(byteLength >= 0)
        self.byteOffset = byteOffset
        self.byteLength = byteLength
    }
}

/// Pairs one neutral transition with capture time relative to pane construction.
public struct TerminalFlightRecordingEvent: Equatable, Sendable {
    /// Lifetime-monotonic position assigned before retention bounds can evict the event.
    public let sequence: UInt64
    /// Replayable transition captured at the PTY owner's actual application boundary.
    public let event: NeutralTerminalRecordingEvent
    /// Monotonic time since this pane's recorder was constructed.
    public let elapsedNanoseconds: UInt64
    /// When the event that produced these bytes occurred, on the same scale as
    /// `elapsedNanoseconds`. Nil means the bytes originated at the pane owner itself and had
    /// no earlier origin -- never zero, which is a real position on the scale. The distance
    /// between the two stamps is time the app held the bytes before they crossed.
    public let originElapsedNanoseconds: UInt64?
    /// Where these bytes sit in their own direction's stream. Nil for an event that carries
    /// no bytes at all, such as a resize.
    public let payload: TerminalFlightRecordingPayloadSpan?

    /// Keeps timing and byte-position metadata beside, but behaviorally independent from, the
    /// replay event.
    public init(
        sequence: UInt64,
        event: NeutralTerminalRecordingEvent,
        elapsedNanoseconds: UInt64,
        originElapsedNanoseconds: UInt64? = nil,
        payload: TerminalFlightRecordingPayloadSpan? = nil
    ) {
        self.sequence = sequence
        self.event = event
        self.elapsedNanoseconds = elapsedNanoseconds
        self.originElapsedNanoseconds = originElapsedNanoseconds
        self.payload = payload
    }
}

/// Resumable position whose per-direction watermarks make later eviction gaps exactly measurable.
public struct TerminalFlightRecordingCursor: Equatable, Sendable {
    /// Sequence that the next snapshot should attempt to return first.
    public let nextSequence: UInt64
    /// Lifetime feed bytes recorded before `nextSequence`.
    public let feedBytesBeforeNextSequence: Int
    /// Lifetime write bytes recorded before `nextSequence`.
    public let writeBytesBeforeNextSequence: Int

    /// Starts a backlog read before the recorder's first lifetime event.
    public static let beginning = Self(
        nextSequence: 0,
        feedBytesBeforeNextSequence: 0,
        writeBytesBeforeNextSequence: 0
    )

    /// Preserves every coordinate needed to distinguish an exact per-direction gap from
    /// delivered history.
    public init(
        nextSequence: UInt64,
        feedBytesBeforeNextSequence: Int,
        writeBytesBeforeNextSequence: Int
    ) {
        precondition(feedBytesBeforeNextSequence >= 0)
        precondition(writeBytesBeforeNextSequence >= 0)
        self.nextSequence = nextSequence
        self.feedBytesBeforeNextSequence = feedBytesBeforeNextSequence
        self.writeBytesBeforeNextSequence = writeBytesBeforeNextSequence
    }
}

/// One owner-fenced cursor read, including exact loss before its retained event suffix.
public struct TerminalFlightRecordingCursorSnapshot: Equatable, Sendable {
    /// Oldest sequence still present at the time of the fence.
    public let firstRetainedSequence: UInt64
    /// Retained events at or after the requested cursor, ordered by sequence.
    public let events: [TerminalFlightRecordingEvent]
    /// Exact whole-event loss between the requested cursor and retained suffix.
    public let droppedEventCount: UInt64
    /// Exact feed-byte loss between the requested cursor and retained suffix.
    public let droppedFeedBytes: Int
    /// Exact write-byte loss between the requested cursor and retained suffix.
    public let droppedWriteBytes: Int
    /// Cursor immediately after every event returned by this snapshot.
    public let nextCursor: TerminalFlightRecordingCursor

    /// Next lifetime sequence to be assigned after this snapshot's fence.
    public var nextSequence: UInt64 { nextCursor.nextSequence }
}

/// Atomically pairs the geometry for a tail-only stream with its first event cursor.
public struct TerminalFlightRecordingOrigin: Equatable, Sendable {
    /// Pane geometry immediately before the cursor's first possible event.
    public let initial: NeutralTerminalDimensions
    /// Cursor that excludes every event recorded before this owner fence.
    public let cursor: TerminalFlightRecordingCursor
}

/// Immutable dump boundary whose arrays retain feed storage by reference until encoding ends.
public struct TerminalFlightRecordingSnapshot: Equatable, Sendable {
    /// Pane geometry when the recorder was constructed; retention eviction does not advance it.
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

    /// Encodes the immutable snapshot as one replayable raw-capture document off the owner queue.
    public func encodedRecording() throws -> Data {
        let recording = NeutralTerminalRecording(
            provenance: .liveCapture(),
            initial: initial,
            events: events.map(\.event)
        )
        let baseData = try JSONEncoder().encode(recording)
        guard var document = try JSONSerialization.jsonObject(with: baseData) as? [String: Any],
              var encodedEvents = document["events"] as? [[String: Any]],
              encodedEvents.count == events.count
        else {
            throw EncodingError.invalidValue(
                recording,
                .init(codingPath: [], debugDescription: "recording did not encode as an object")
            )
        }

        for index in encodedEvents.indices {
            encodedEvents[index]["elapsedNanoseconds"] = events[index].elapsedNanoseconds
            if let origin = events[index].originElapsedNanoseconds {
                encodedEvents[index]["originElapsedNanoseconds"] = origin
            }
        }
        document["events"] = encodedEvents
        document["truncation"] = [
            "isTruncated": isTruncated,
            "droppedEventCount": droppedEventCount,
            "droppedPayloadBytes": droppedPayloadBytes,
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }
}

/// Owner-queue-only FIFO that releases evicted payload storage without shifting an array.
package final class TerminalFlightRecorder {
    /// Owner-queue state for one edge-triggered subscriber; the ring remains the event buffer.
    private final class FollowNotice {
        let notify: @Sendable () -> Void
        var isOutstanding = false

        init(notify: @escaping @Sendable () -> Void) {
            self.notify = notify
        }
    }

    /// Keeps retention accounting beside each event without allocating an object per entry.
    private struct Slot {
        let event: TerminalFlightRecordingEvent
        let payloadBytes: Int
        let feedBytesBeforeEvent: Int
        let writeBytesBeforeEvent: Int
    }

    private let initial: NeutralTerminalDimensions
    private var currentDimensions: NeutralTerminalDimensions
    private let configuration: TerminalFlightRecorderConfiguration
    private let now: @Sendable () -> UInt64
    private let startedNanoseconds: UInt64
    private var lastElapsedNanoseconds: UInt64 = 0
    /// Retains a contiguous lifetime-sequence run: slot `i` has sequence
    /// `slots[0].event.sequence + i`.
    /// Never let this COW value escape a snapshot; map to arrays so later owner-queue writes
    /// stay unique. Deque keeps its high-water allocation after head eviction; that is accepted
    /// because the retained count remains bounded per pane.
    private var slots: Deque<Slot> = []
    private var accountedBytes = 0
    private var droppedEventCount = 0
    /// Lifetime evicted payload across both directions. Per-direction loss is not accumulated
    /// here: `cursorSnapshot` measures it exactly, against the caller's own cursor, from the
    /// retained head's watermarks.
    private var droppedPayloadBytes = 0
    private var nextSequence: UInt64 = 0
    private var totalFeedBytes = 0
    private var totalWriteBytes = 0
    private var followNotices: [UUID: FollowNotice] = [:]

    package init(
        initialDimensions: TerminalDimensions,
        configuration: TerminalFlightRecorderConfiguration = .production,
        now: @escaping @Sendable () -> UInt64
    ) {
        initial = .init(
            columns: initialDimensions.columns,
            rows: initialDimensions.rows
        )
        currentDimensions = initial
        self.configuration = configuration
        self.now = now
        startedNanoseconds = now()
    }

    /// `origin` is when the event that produced these bytes occurred, on this recorder's own
    /// clock, and belongs only to bytes travelling toward the child. Callers pass nil for
    /// anything that originated at the pane owner. Unlike the transfer stamp, origins are not
    /// forced monotonic along the sequence: they describe their own event, not this one.
    package func record(_ event: NeutralTerminalRecordingEvent, origin: UInt64? = nil) {
        let current = now()
        let measured = current >= startedNanoseconds ? current - startedNanoseconds : 0
        let elapsed = max(lastElapsedNanoseconds, measured)
        lastElapsedNanoseconds = elapsed
        let originElapsed = origin.map { $0 >= startedNanoseconds ? $0 - startedNanoseconds : 0 }
        let direction = Self.direction(of: event)
        let payloadBytes = direction?.byteCount ?? 0
        let payload = direction.map { direction in
            TerminalFlightRecordingPayloadSpan(
                byteOffset: direction.isFeed ? totalFeedBytes : totalWriteBytes,
                byteLength: direction.byteCount
            )
        }
        let slot = Slot(
            event: .init(
                sequence: nextSequence,
                event: event,
                elapsedNanoseconds: elapsed,
                originElapsedNanoseconds: originElapsed,
                payload: payload
            ),
            payloadBytes: payloadBytes,
            feedBytesBeforeEvent: totalFeedBytes,
            writeBytesBeforeEvent: totalWriteBytes
        )
        nextSequence += 1
        if let direction {
            if direction.isFeed {
                totalFeedBytes += direction.byteCount
            } else {
                totalWriteBytes += direction.byteCount
            }
        }
        if case .resize(let columns, let rows) = event {
            currentDimensions = .init(columns: columns, rows: rows)
        }
        slots.append(slot)
        accountedBytes += payloadBytes + configuration.eventOverheadBytes
        enforceBounds()
        assert(
            slots.isEmpty
                || slots[slots.count - 1].event.sequence
                    == slots[0].event.sequence + UInt64(slots.count - 1)
        )
        for notice in followNotices.values where notice.isOutstanding == false {
            notice.isOutstanding = true
            notice.notify()
        }
    }

    /// Arms one subscriber at its established cursor and signals immediately when it trails.
    package func addFollowNotice(
        id: UUID,
        from cursor: TerminalFlightRecordingCursor,
        notify: @escaping @Sendable () -> Void
    ) {
        precondition(followNotices[id] == nil)
        precondition(cursor.nextSequence <= nextSequence)
        let notice = FollowNotice(notify: notify)
        followNotices[id] = notice
        if cursor.nextSequence < nextSequence {
            notice.isOutstanding = true
            notice.notify()
        }
    }

    /// Removes the append edge before its subscription or callback owner can disappear.
    package func removeFollowNotice(id: UUID) {
        followNotices.removeValue(forKey: id)
    }

    /// Takes one cursored suffix and atomically rearms the next append edge for this subscriber.
    package func followCursorSnapshot(
        subscriptionId: UUID,
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorSnapshot? {
        guard let notice = followNotices[subscriptionId] else { return nil }
        let snapshot = cursorSnapshot(from: cursor)
        notice.isOutstanding = false
        return snapshot
    }

    package func snapshot() -> TerminalFlightRecordingSnapshot {
        return TerminalFlightRecordingSnapshot(
            initial: initial,
            events: slots.map(\.event),
            accountedBytes: accountedBytes,
            droppedEventCount: droppedEventCount,
            droppedPayloadBytes: droppedPayloadBytes
        )
    }

    package func cursorSnapshot(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorSnapshot {
        precondition(cursor.nextSequence <= nextSequence)
        precondition(cursor.feedBytesBeforeNextSequence <= totalFeedBytes)
        precondition(cursor.writeBytesBeforeNextSequence <= totalWriteBytes)

        let firstRetainedSequence = slots.first?.event.sequence ?? nextSequence
        let firstRetainedFeedBytes = slots.first?.feedBytesBeforeEvent ?? totalFeedBytes
        let firstRetainedWriteBytes = slots.first?.writeBytesBeforeEvent ?? totalWriteBytes
        let firstReturnedSequence = max(cursor.nextSequence, firstRetainedSequence)
        let firstReturnedIndex = Int(firstReturnedSequence - firstRetainedSequence)
        let events = slots[firstReturnedIndex...].map(\.event)

        let hasGap = cursor.nextSequence < firstRetainedSequence
        return TerminalFlightRecordingCursorSnapshot(
            firstRetainedSequence: firstRetainedSequence,
            events: events,
            droppedEventCount: hasGap ? firstRetainedSequence - cursor.nextSequence : 0,
            droppedFeedBytes: hasGap
                ? firstRetainedFeedBytes - cursor.feedBytesBeforeNextSequence
                : 0,
            droppedWriteBytes: hasGap
                ? firstRetainedWriteBytes - cursor.writeBytesBeforeNextSequence
                : 0,
            nextCursor: liveCursor()
        )
    }

    package func fromNowOrigin() -> TerminalFlightRecordingOrigin {
        TerminalFlightRecordingOrigin(initial: currentDimensions, cursor: liveCursor())
    }

    /// Pairs recorder birth geometry with the cursor that requests all retained history.
    package func backlogOrigin() -> TerminalFlightRecordingOrigin {
        TerminalFlightRecordingOrigin(initial: initial, cursor: .beginning)
    }

    private func liveCursor() -> TerminalFlightRecordingCursor {
        .init(
            nextSequence: nextSequence,
            feedBytesBeforeNextSequence: totalFeedBytes,
            writeBytesBeforeNextSequence: totalWriteBytes
        )
    }

    private func enforceBounds() {
        while accountedBytes > configuration.budgetBytes
            || slots.count > configuration.eventLimit
        {
            guard !slots.isEmpty else { break }
            let evicted = slots.removeFirst()
            accountedBytes -= evicted.payloadBytes + configuration.eventOverheadBytes
            droppedEventCount += 1
            droppedPayloadBytes += evicted.payloadBytes
        }
    }

    /// Names the byte-carrying direction of an event, or nil when it carries none. Every event
    /// that carries bytes is charged to the retention budget, so the retained suffix stays
    /// inside the per-pane budget the IPC line ceiling was chosen against.
    private static func direction(
        of event: NeutralTerminalRecordingEvent
    ) -> PayloadDirection? {
        switch event {
        case .feed(let bytes): return PayloadDirection(isFeed: true, byteCount: bytes.count)
        case .write(let bytes): return PayloadDirection(isFeed: false, byteCount: bytes.count)
        default: return nil
        }
    }

    /// Pairs the direction an event's bytes travel with how many of them there are, so the
    /// two facts are read out of the event exactly once.
    private struct PayloadDirection {
        let isFeed: Bool
        let byteCount: Int
    }
}
