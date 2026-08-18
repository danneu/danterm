// Bounded in-memory capture of one live pane's feed and resize drive sequence. The PTY
// owner records without encoding or IO; dump callers fence a value snapshot for later work.
import PaneProcessLifecycle
import DequeModule
import Foundation
import TerminalCore
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
    /// Identifies the recorder lifetime whose sequence and byte spaces the cursor names.
    public let recorderLifetimeId: UUID
    /// Sequence that the next snapshot should attempt to return first.
    public let nextSequence: UInt64
    /// Lifetime feed bytes recorded before `nextSequence`.
    public let feedBytesBeforeNextSequence: Int
    /// Lifetime write bytes recorded before `nextSequence`.
    public let writeBytesBeforeNextSequence: Int

    /// Starts a backlog read before the recorder's first lifetime event.
    public static let beginning = Self(
        recorderLifetimeId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        nextSequence: 0,
        feedBytesBeforeNextSequence: 0,
        writeBytesBeforeNextSequence: 0
    )

    /// Preserves every coordinate needed to distinguish an exact per-direction gap from
    /// delivered history.
    public init(
        recorderLifetimeId: UUID,
        nextSequence: UInt64,
        feedBytesBeforeNextSequence: Int,
        writeBytesBeforeNextSequence: Int
    ) {
        self.recorderLifetimeId = recorderLifetimeId
        self.nextSequence = nextSequence
        self.feedBytesBeforeNextSequence = feedBytesBeforeNextSequence
        self.writeBytesBeforeNextSequence = writeBytesBeforeNextSequence
    }
}

/// Separates a cursor the recorder can place from untrusted coordinates it must not use.
public enum TerminalFlightRecordingCursorPlacement: Equatable, Sendable {
    /// The recorder accepted the cursor and measured its retained suffix.
    case placed(TerminalFlightRecordingCursorSnapshot)
    /// The coordinates cannot name a position in this recorder lifetime.
    case unplaceable

    /// Lets stream policy branch on invalid provenance without unpacking a valid snapshot.
    public var isUnplaceable: Bool {
        if case .unplaceable = self { true } else { false }
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
    public let initial: NeutralTerminalGeometry
    /// Cursor that excludes every event recorded before this owner fence.
    public let cursor: TerminalFlightRecordingCursor
}

/// One finite capture of the whole retained tape, fenced as a single moment.
///
/// A finite dump is a cursored read from the recorder's beginning, not a separate kind of
/// read: the same origin and the same cursor snapshot a follow stream starts from. Pairing
/// them in one value is what makes the pair atomic, so a dump cannot report geometry from
/// before an event it then omits.
public struct TerminalFlightRecordingCapture: Equatable, Sendable {
    /// Recorder birth geometry with the cursor the retained events are measured against.
    public let origin: TerminalFlightRecordingOrigin
    /// Every retained event, plus the exact lifetime loss before the oldest of them.
    public let snapshot: TerminalFlightRecordingCursorSnapshot
}

/// Captures every input the stream policy needs in one owner-queue turn.
///
/// Everything here except `state` is cheap to read, and `state` is unserialized: a stream
/// that decides to ship events never pays for terminal bytes it would discard.
public struct TerminalFlightRecordingStreamFence: Sendable {
    /// Recorder birth geometry and its real lifetime cursor at sequence zero.
    public let origin: TerminalFlightRecordingOrigin
    /// Live geometry with the cursor past every event recorded before this fence, for an
    /// opening that begins at the fenced moment rather than replaying up to it.
    public let live: TerminalFlightRecordingOrigin
    /// The whole retained suffix for raw fallback and beginning requests.
    public let retained: TerminalFlightRecordingCursorSnapshot
    /// Placement of the requester's supplied cursor in this recorder lifetime.
    public let requested: TerminalFlightRecordingCursorPlacement
    /// The fenced terminal beside the first event outside it, serialized only if the stream
    /// selects a synchronization.
    public let state: TerminalFlightRecordingStatePairing
}

/// Pairs a followed suffix with the fenced state at the same notice-rearming owner fence.
public struct TerminalFlightRecordingFollowFence: Sendable {
    /// Retained events and exact loss from the subscriber's previous cursor.
    public let snapshot: TerminalFlightRecordingCursorSnapshot
    /// The fenced terminal at `snapshot.nextCursor`, serialized only if the stream selects a
    /// synchronization to repair loss with.
    public let state: TerminalFlightRecordingStatePairing
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

    private let initial: NeutralTerminalGeometry
    private let lifetimeId: UUID
    /// The last geometry an applied event stated, so a tail-only stream and a state sync
    /// both report the grid and its pinnedness as one fact rather than a grid alone.
    private var currentGeometry: NeutralTerminalGeometry
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
    private var nextSequence: UInt64 = 0
    private var totalFeedBytes = 0
    private var totalWriteBytes = 0
    private var followNotices: [UUID: FollowNotice] = [:]

    package init(
        lifetimeId: UUID = UUID(),
        initialGeometry: NeutralTerminalGeometry,
        configuration: TerminalFlightRecorderConfiguration = .production,
        now: @escaping @Sendable () -> UInt64
    ) {
        initial = initialGeometry
        self.lifetimeId = lifetimeId
        currentGeometry = initial
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
        if case .resize(let columns, let rows, let pinned) = event {
            currentGeometry = .init(columns: columns, rows: rows, pinned: pinned)
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

    /// Reads the whole retained tape as one finite capture, in the same vocabulary a follow
    /// stream reads its suffix in, so both captures build the same records downstream.
    package func capture() -> TerminalFlightRecordingCapture {
        TerminalFlightRecordingCapture(
            origin: backlogOrigin(),
            snapshot: cursorSnapshot(from: .beginning)
        )
    }

    package func cursorSnapshot(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorSnapshot {
        if cursor == .beginning {
            return uncheckedCursorSnapshot(from: backlogCursor())
        }
        guard case .placed(let snapshot) = cursorPlacement(from: cursor) else {
            preconditionFailure("cursor must be placed before taking a snapshot")
        }
        return snapshot
    }

    /// Validates remote-capable cursor coordinates before any index arithmetic or subtraction.
    package func cursorPlacement(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorPlacement {
        guard cursor.recorderLifetimeId == lifetimeId,
              cursor.feedBytesBeforeNextSequence >= 0,
              cursor.writeBytesBeforeNextSequence >= 0,
              cursor.nextSequence <= nextSequence,
              cursor.feedBytesBeforeNextSequence <= totalFeedBytes,
              cursor.writeBytesBeforeNextSequence <= totalWriteBytes,
              coordinatesMatchRetainedPosition(cursor)
        else { return .unplaceable }
        return .placed(uncheckedCursorSnapshot(from: cursor))
    }

    private func uncheckedCursorSnapshot(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorSnapshot {

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

    /// Whether the last applied geometry stated a pinned grid. Read at the same owner fence
    /// as a state pairing, so exact state and its pinnedness cannot come from different turns.
    package var pinned: Bool { currentGeometry.pinned }

    package func fromNowOrigin() -> TerminalFlightRecordingOrigin {
        TerminalFlightRecordingOrigin(initial: currentGeometry, cursor: liveCursor())
    }

    /// Pairs recorder birth geometry with the cursor that requests all retained history.
    package func backlogOrigin() -> TerminalFlightRecordingOrigin {
        TerminalFlightRecordingOrigin(initial: initial, cursor: backlogCursor())
    }

    package func liveCursor() -> TerminalFlightRecordingCursor {
        .init(
            recorderLifetimeId: lifetimeId,
            nextSequence: nextSequence,
            feedBytesBeforeNextSequence: totalFeedBytes,
            writeBytesBeforeNextSequence: totalWriteBytes
        )
    }

    private func backlogCursor() -> TerminalFlightRecordingCursor {
        .init(
            recorderLifetimeId: lifetimeId,
            nextSequence: 0,
            feedBytesBeforeNextSequence: 0,
            writeBytesBeforeNextSequence: 0
        )
    }

    private func coordinatesMatchRetainedPosition(
        _ cursor: TerminalFlightRecordingCursor
    ) -> Bool {
        let firstRetainedSequence = slots.first?.event.sequence ?? nextSequence
        if cursor.nextSequence < firstRetainedSequence {
            let firstFeed = slots.first?.feedBytesBeforeEvent ?? totalFeedBytes
            let firstWrite = slots.first?.writeBytesBeforeEvent ?? totalWriteBytes
            return cursor.feedBytesBeforeNextSequence <= firstFeed
                && cursor.writeBytesBeforeNextSequence <= firstWrite
        }
        if cursor.nextSequence == nextSequence {
            return cursor.feedBytesBeforeNextSequence == totalFeedBytes
                && cursor.writeBytesBeforeNextSequence == totalWriteBytes
        }
        let index = Int(cursor.nextSequence - firstRetainedSequence)
        guard slots.indices.contains(index) else { return false }
        return cursor.feedBytesBeforeNextSequence == slots[index].feedBytesBeforeEvent
            && cursor.writeBytesBeforeNextSequence == slots[index].writeBytesBeforeEvent
    }

    /// Evicts oldest-first without accumulating loss totals. Loss is not a property of the
    /// recorder but of the distance between a reader's cursor and the retained head, and
    /// `cursorSnapshot` measures exactly that from the head slot's own watermarks.
    private func enforceBounds() {
        while accountedBytes > configuration.budgetBytes
            || slots.count > configuration.eventLimit
        {
            guard !slots.isEmpty else { break }
            let evicted = slots.removeFirst()
            accountedBytes -= evicted.payloadBytes + configuration.eventOverheadBytes
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
