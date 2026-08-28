// Bounded in-memory capture of one live pane's feed and resize drive sequence. The PTY
// owner records without encoding or IO; dump callers fence a value snapshot for later work.
import PaneProcessLifecycle
import DequeModule
import Foundation
import TerminalCore
import TerminalCoreRecording

/// Bounds retained payload and metadata independently so both bulk and tiny PTY chunks fit,
/// and states which vocabulary the tape is worth spending those slots on.
///
/// Vocabulary belongs beside retention because both answer the same question -- what is worth
/// a slot on this pane's tape. A live pane records only the boundary it must replay from; a
/// characterization pane records the interaction intent behind that boundary too.
package struct TerminalFlightRecorderConfiguration: Sendable {
    /// What a live pane records: bounded history, boundary vocabulary only.
    package static let production = Self(
        budgetBytes: 8 * 1_024 * 1_024,
        eventLimit: 32_768,
        eventOverheadBytes: 128
    )

    /// What a characterization pane records: every applied transition, never evicted, so the
    /// recording a replay is checked against is the pane's whole life.
    package static let complete = Self(
        budgetBytes: .max,
        eventLimit: .max,
        eventOverheadBytes: 0,
        recordsInteractionIntent: true
    )

    package let budgetBytes: Int
    package let eventLimit: Int
    package let eventOverheadBytes: Int
    /// Whether `.input`, `.paste`, `.focus`, `.mouse`, and `.viewport` reach the tape.
    ///
    /// Off is the production answer, and not merely to save room: a replica applies `.mouse`
    /// and `.viewport`, so recording them on a live pane would mirror this pane's selection
    /// and yank a follower's viewport.
    package let recordsInteractionIntent: Bool

    package init(
        budgetBytes: Int,
        eventLimit: Int,
        eventOverheadBytes: Int,
        recordsInteractionIntent: Bool = false
    ) {
        precondition(budgetBytes >= 0)
        precondition(eventLimit >= 0)
        precondition(eventOverheadBytes >= 0)
        self.budgetBytes = budgetBytes
        self.eventLimit = eventLimit
        self.eventOverheadBytes = eventOverheadBytes
        self.recordsInteractionIntent = recordsInteractionIntent
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

/// Names who chose the bytes of one write toward the child.
///
/// The fact has to be carried because it cannot be derived: a terminal reply and a plain user
/// send both cross the boundary with no origin stamp, so a reader that only sees the bytes
/// cannot tell an answer from a keystroke. This is capture metadata alone -- it never enters
/// `NeutralTerminalRecordingEvent`, so no replay and no pane-tape record can depend on it.
public enum TerminalFlightRecordingWriteAttribution: Equatable, Sendable {
    /// Somebody acted on this pane and these bytes encode that act.
    case user
    /// The pane settled its own business with the child: its launch line, a focus report.
    case pane
    /// The terminal answered a query the child asked.
    case reply
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
    /// Who chose these bytes, for a write; nil for every kind that writes nothing.
    public let writeAttribution: TerminalFlightRecordingWriteAttribution?

    /// Keeps timing and byte-position metadata beside, but behaviorally independent from, the
    /// replay event, and refuses a write whose chooser is unstated.
    public init(
        sequence: UInt64,
        event: NeutralTerminalRecordingEvent,
        elapsedNanoseconds: UInt64,
        originElapsedNanoseconds: UInt64? = nil,
        payload: TerminalFlightRecordingPayloadSpan? = nil,
        writeAttribution: TerminalFlightRecordingWriteAttribution? = nil
    ) {
        if case .write = event {
            precondition(writeAttribution != nil, "a recorded write must state who chose its bytes")
        } else {
            precondition(writeAttribution == nil, "only a write has a chooser to name")
        }
        self.writeAttribution = writeAttribution
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
    /// The fenced terminal beside the first event outside it. It is present only when the
    /// opening strategy selects a synchronization.
    public let state: TerminalFlightRecordingStatePairing?
}

/// Selects the recorder data an opening may need before stream policy runs.
public struct TerminalFlightRecordingStreamRequest: Sendable {
    /// Names the opening coordinate before the recorder places any supplied cursor.
    public enum Position: Sendable {
        /// Replay from the recorder's lifetime origin.
        case beginning
        /// Publish the live cursor without replaying retained events.
        case now
        /// Resume from a caller-supplied recorder coordinate.
        case cursor(TerminalFlightRecordingCursor)
    }

    /// Selects the only fallback data needed when a supplied cursor cannot be placed.
    public enum UnplaceablePolicy: Sendable {
        /// Preserve the retained ring as raw evidence.
        case retained
        /// Replace the unavailable suffix with fenced terminal state.
        case state
    }

    /// Opening coordinate the recorder must classify first.
    public let position: Position
    /// Fallback capture used only when `position` contains an unplaceable cursor.
    public let unplaceablePolicy: UnplaceablePolicy
    /// Decides whether one mapped suffix also needs state from the same owner turn.
    public let requiresState: @Sendable (TerminalFlightRecordingCursorSnapshot) -> Bool

    /// Requests the retained backlog and lets policy select state from its loss facts.
    public static func beginning(
        requiresState: @escaping @Sendable (TerminalFlightRecordingCursorSnapshot) -> Bool
    ) -> Self {
        .init(position: .beginning, unplaceablePolicy: .retained, requiresState: requiresState)
    }

    /// Requests the live cursor and optionally pairs it with current terminal state.
    public static func now(requiresState: Bool) -> Self {
        .init(position: .now, unplaceablePolicy: .state, requiresState: { _ in requiresState })
    }

    /// Requests one placed suffix and states the fallback for a rejected coordinate.
    public static func cursor(
        _ cursor: TerminalFlightRecordingCursor,
        unplaceablePolicy: UnplaceablePolicy,
        requiresState: @escaping @Sendable (TerminalFlightRecordingCursorSnapshot) -> Bool = { _ in false }
    ) -> Self {
        .init(
            position: .cursor(cursor),
            unplaceablePolicy: unplaceablePolicy,
            requiresState: requiresState
        )
    }
}

/// States whether one recorder-owned suffix can ship as events or needs owner state.
public enum TerminalFlightRecordingFollowDecision: Sendable {
    /// The retained suffix is sufficient by itself.
    case events
    /// The suffix must be replaced by state from the same owner turn.
    case synchronize
}

/// Carries one recorder-owned follow decision to deferred materialization.
public struct TerminalFlightRecordingFollowBatch: Sendable {
    /// The exact suffix claimed from the subscription's stored cursor.
    public let snapshot: TerminalFlightRecordingCursorSnapshot
    /// Owner state at `snapshot.nextCursor`, present only for a synchronization decision.
    public let state: TerminalFlightRecordingStatePairing?
    /// History standing used to decide this suffix.
    public let replicaHistoryIsComplete: Bool
    /// Time spent deciding and claiming this batch on the owner queue.
    public let ownerNanoseconds: UInt64
}

/// Owner-queue-only FIFO that releases evicted payload storage without shifting an array.
package final class TerminalFlightRecorder {
    /// Carries coordinates that this recorder has proved name one of its lifetime positions.
    private struct PlacedCursor {
        let rawValue: TerminalFlightRecordingCursor

        fileprivate init(_ rawValue: TerminalFlightRecordingCursor) {
            self.rawValue = rawValue
        }
    }

    /// One owner-queue subscription, including the callback box that survives each traversal.
    private final class FollowSubscription {
        var cursor: PlacedCursor
        var replicaHistoryIsComplete: Bool
        var isReady = false
        let decide: @Sendable (
            TerminalFlightRecordingCursorSnapshot,
            Bool
        ) -> TerminalFlightRecordingFollowDecision
        let deliver: @Sendable (TerminalFlightRecordingFollowBatch) -> Void

        init(
            cursor: PlacedCursor,
            replicaHistoryIsComplete: Bool,
            decide: @escaping @Sendable (
                TerminalFlightRecordingCursorSnapshot,
                Bool
            ) -> TerminalFlightRecordingFollowDecision,
            deliver: @escaping @Sendable (TerminalFlightRecordingFollowBatch) -> Void
        ) {
            self.cursor = cursor
            self.replicaHistoryIsComplete = replicaHistoryIsComplete
            self.decide = decide
            self.deliver = deliver
        }
    }

    /// Keeps retention accounting beside each event without allocating an object per entry.
    private struct Slot {
        let event: TerminalFlightRecordingEvent
        /// What this event costs the retention budget, which is not the same as what it
        /// contributes to a direction's watermark: a paste is charged and moves neither.
        let chargedBytes: Int
        let feedBytesBeforeEvent: Int
        let writeBytesBeforeEvent: Int
    }

    private let initial: NeutralTerminalGeometry
    private let lifetimeId: UUID
    /// The last geometry an applied event stated, so a tail-only stream and a state sync
    /// both report the grid and its pinnedness as one fact rather than a grid alone.
    package private(set) var currentGeometry: NeutralTerminalGeometry
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
    package static let maximumFollowSubscriptions = 8
    private var followSubscriptions: [UUID: FollowSubscription] = [:]
    private var followStatePairingSource: (() -> TerminalFlightRecordingStatePairing?)?

    package var followSubscriptionCount: Int { followSubscriptions.count }

    package func hasFollowSubscription(id: UUID) -> Bool {
        followSubscriptions[id] != nil
    }

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

    /// Records one transition that sends the child nothing.
    ///
    /// Writes have their own entry point because only a write has bytes travelling toward the
    /// child, and so only a write has an origin stamp and a chooser to name. Splitting the two
    /// is what makes "every write on the tape states who chose it" true by construction rather
    /// than by the discipline of each call site.
    package func record(_ event: NeutralTerminalRecordingEvent) {
        if case .write = event {
            preconditionFailure("record a write through recordWrite, which states who chose it")
        }
        append(event, origin: nil, writeAttribution: nil)
    }

    /// `origin` is when the event that produced these bytes occurred, on this recorder's own
    /// clock. Callers pass nil for anything that originated at the pane owner. Unlike the
    /// transfer stamp, origins are not forced monotonic along the sequence: they describe
    /// their own event, not this one.
    ///
    /// `attribution` is the fact the bytes themselves cannot carry -- a reply and a user send
    /// look identical on the wire -- so the submitting path has to state it here.
    package func recordWrite(
        _ bytes: [UInt8],
        origin: UInt64?,
        attribution: TerminalFlightRecordingWriteAttribution
    ) {
        append(.write(bytes), origin: origin, writeAttribution: attribution)
    }

    /// The one place an event reaches the ring, so the interaction-intent gate, the byte
    /// watermarks, and the retention charge are each applied exactly once. The gate lives here
    /// rather than at the call sites, so a capture site added later cannot forget it: every
    /// owner records unconditionally and the configuration decides what survives.
    private func append(
        _ event: NeutralTerminalRecordingEvent,
        origin: UInt64?,
        writeAttribution: TerminalFlightRecordingWriteAttribution?
    ) {
        guard configuration.recordsInteractionIntent || Self.isInteractionIntent(event) == false
        else { return }
        let current = now()
        let measured = current >= startedNanoseconds ? current - startedNanoseconds : 0
        let elapsed = max(lastElapsedNanoseconds, measured)
        lastElapsedNanoseconds = elapsed
        let originElapsed = origin.map { $0 >= startedNanoseconds ? $0 - startedNanoseconds : 0 }
        let direction = Self.direction(of: event)
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
                payload: payload,
                writeAttribution: writeAttribution
            ),
            chargedBytes: Self.budgetCharge(of: event),
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
        accountedBytes += slot.chargedBytes + configuration.eventOverheadBytes
        enforceBounds()
        assert(
            slots.isEmpty
                || slots[slots.count - 1].event.sequence
                    == slots[0].event.sequence + UInt64(slots.count - 1)
        )
        pushReadyFollowSubscriptions()
    }

    /// Installs the owner-local state source used only after policy selects synchronization.
    package func setFollowStatePairingSource(
        _ source: @escaping () -> TerminalFlightRecordingStatePairing?
    ) {
        followStatePairingSource = source
    }

    /// Registers one in-flight subscription, refusing work beyond the pane's fixed cap.
    @discardableResult
    package func addFollowSubscription(
        id: UUID,
        from cursor: TerminalFlightRecordingCursor,
        replicaHistoryIsComplete: Bool,
        decide: @escaping @Sendable (
            TerminalFlightRecordingCursorSnapshot,
            Bool
        ) -> TerminalFlightRecordingFollowDecision,
        deliver: @escaping @Sendable (TerminalFlightRecordingFollowBatch) -> Void
    ) -> Bool {
        precondition(followSubscriptions[id] == nil)
        guard followSubscriptions.count < Self.maximumFollowSubscriptions else { return false }
        guard let placedCursor = placedCursor(from: cursor) else { return false }
        followSubscriptions[id] = FollowSubscription(
            cursor: placedCursor,
            replicaHistoryIsComplete: replicaHistoryIsComplete,
            decide: decide,
            deliver: deliver
        )
        return true
    }

    /// Installs the flushed batch's history standing before admitting the next suffix.
    package func markFollowSubscriptionReady(
        id: UUID,
        replicaHistoryIsComplete: Bool
    ) {
        guard let subscription = followSubscriptions[id] else { return }
        subscription.replicaHistoryIsComplete = replicaHistoryIsComplete
        subscription.isReady = true
        pushFollowSubscription(subscription)
    }

    /// Removes one subscription before its transport callback owner can disappear.
    package func removeFollowSubscription(id: UUID) {
        followSubscriptions.removeValue(forKey: id)
    }

    private func pushReadyFollowSubscriptions() {
        for subscription in followSubscriptions.values where subscription.isReady {
            pushFollowSubscription(subscription)
        }
    }

    private func pushFollowSubscription(_ subscription: FollowSubscription) {
        guard subscription.isReady,
              subscription.cursor.rawValue.nextSequence < nextSequence
        else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let snapshot = cursorSnapshot(from: subscription.cursor)
        let decision = subscription.decide(snapshot, subscription.replicaHistoryIsComplete)
        let state: TerminalFlightRecordingStatePairing?
        switch decision {
        case .events:
            state = nil
        case .synchronize:
            state = followStatePairingSource?()
        }
        subscription.cursor = PlacedCursor(snapshot.nextCursor)
        subscription.isReady = false
        subscription.deliver(TerminalFlightRecordingFollowBatch(
            snapshot: snapshot,
            state: state,
            replicaHistoryIsComplete: subscription.replicaHistoryIsComplete,
            ownerNanoseconds: DispatchTime.now().uptimeNanoseconds - started
        ))
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
        let requestedCursor = cursor == .beginning ? backlogCursor() : cursor
        guard let placedCursor = placedCursor(from: requestedCursor) else {
            preconditionFailure("cursor must be placed before taking a snapshot")
        }
        return cursorSnapshot(from: placedCursor)
    }

    /// Validates remote-capable cursor coordinates before any index arithmetic or subtraction.
    package func cursorPlacement(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorPlacement {
        guard let placedCursor = placedCursor(from: cursor) else { return .unplaceable }
        return .placed(cursorSnapshot(from: placedCursor))
    }

    /// Mints the proof value used by every path that accepts raw cursor coordinates.
    private func placedCursor(
        from cursor: TerminalFlightRecordingCursor
    ) -> PlacedCursor? {
        guard cursor.recorderLifetimeId == lifetimeId,
              cursor.feedBytesBeforeNextSequence >= 0,
              cursor.writeBytesBeforeNextSequence >= 0,
              cursor.nextSequence <= nextSequence,
              cursor.feedBytesBeforeNextSequence <= totalFeedBytes,
              cursor.writeBytesBeforeNextSequence <= totalWriteBytes,
              coordinatesMatchRetainedPosition(cursor)
        else { return nil }
        return PlacedCursor(cursor)
    }

    /// Classifies the opening first, then maps only the suffix or fallback it consumes.
    package func streamFence(
        request: TerminalFlightRecordingStreamRequest,
        state: () -> TerminalFlightRecordingStatePairing
    ) -> TerminalFlightRecordingStreamFence {
        let origin = backlogOrigin()
        let live = fromNowOrigin()
        let empty = cursorSnapshot(from: PlacedCursor(live.cursor))
        let retained: TerminalFlightRecordingCursorSnapshot
        let requested: TerminalFlightRecordingCursorPlacement
        let needsState: Bool

        switch request.position {
        case .beginning:
            retained = cursorSnapshot(from: .beginning)
            requested = .placed(empty)
            needsState = request.requiresState(retained)
        case .now:
            retained = empty
            requested = .placed(empty)
            needsState = request.requiresState(empty)
        case .cursor(let cursor):
            switch cursorPlacement(from: cursor) {
            case .placed(let snapshot):
                retained = empty
                requested = .placed(snapshot)
                needsState = request.requiresState(snapshot)
            case .unplaceable:
                requested = .unplaceable
                switch request.unplaceablePolicy {
                case .retained:
                    retained = cursorSnapshot(from: .beginning)
                    needsState = false
                case .state:
                    retained = empty
                    needsState = true
                }
            }
        }
        return TerminalFlightRecordingStreamFence(
            origin: origin,
            live: live,
            retained: retained,
            requested: requested,
            state: needsState ? state() : nil
        )
    }

    /// Snapshots coordinates whose placement proof makes validation and failure impossible.
    private func cursorSnapshot(
        from placedCursor: PlacedCursor
    ) -> TerminalFlightRecordingCursorSnapshot {
        let cursor = placedCursor.rawValue

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
            accountedBytes -= evicted.chargedBytes + configuration.eventOverheadBytes
        }
    }

    /// Whether an event states what someone meant to do to the pane rather than what crossed
    /// its boundary. Only these kinds are gated: a replica applies them, and the byte-carrying
    /// kinds beside them are what every reader replays from.
    private static func isInteractionIntent(_ event: NeutralTerminalRecordingEvent) -> Bool {
        switch event {
        case .input, .paste, .focus, .mouse, .viewport: true
        case .feed, .write, .resize, .checkpoint: false
        }
    }

    /// What one event costs the retention budget. A paste is charged its own bytes even though
    /// it moves no watermark: it can carry a whole clipboard, and an uncharged one would let a
    /// single event push the retained suffix past the per-pane budget.
    private static func budgetCharge(of event: NeutralTerminalRecordingEvent) -> Int {
        switch event {
        case .feed(let bytes), .write(let bytes): bytes.count
        case .paste(let text): text.utf8.count
        case .input, .focus, .mouse, .resize, .viewport, .checkpoint: 0
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
