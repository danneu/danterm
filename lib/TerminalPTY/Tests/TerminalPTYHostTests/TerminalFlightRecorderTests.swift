// Behavioral proofs for the bounded live-pane recorder independent of real PTY timing.
import Foundation
import DanTermProtocol
import PaneProcessLifecycle
import TerminalCore
import TerminalCoreRecording
@testable import TerminalPTYHost
import Synchronization
import Testing

struct TerminalFlightRecorderTests {
    @Test("opening capture stays suffix-scoped at both recorder retention caps")
    func openingCaptureAtRetentionCaps() {
        // Intent: cursor and now openings never remap the retained prefix at either cap.
        // Why it exists: reconnect cost must stay proportional to the requested suffix.
        // Scenario: event-count and byte-budget recorders retain two events around a cursor.
        let configurations = [
            TerminalFlightRecorderConfiguration(
                budgetBytes: 1_024,
                eventLimit: 2,
                eventOverheadBytes: 64
            ),
            TerminalFlightRecorderConfiguration(
                budgetBytes: 130,
                eventLimit: 8,
                eventOverheadBytes: 64
            ),
        ]

        for configuration in configurations {
            let recorder = TerminalFlightRecorder(
                initialGeometry: .init(columns: 80, rows: 24, pinned: false),
                configuration: configuration,
                now: { 0 }
            )
            recorder.record(.feed([1]))
            recorder.record(.feed([2]))
            let cursor = recorder.liveCursor()
            recorder.record(.feed([3]))

            let beginning = recorder.streamFence(request: .beginning { _ in false }) {
                fatalError("raw backlog must not pair state")
            }
            let placed = recorder.streamFence(
                request: .cursor(cursor, unplaceablePolicy: .retained)
            ) {
                fatalError("placed raw suffix must not pair state")
            }
            let now = recorder.streamFence(request: .now(requiresState: false)) {
                fatalError("raw now opening must not pair state")
            }

            #expect(beginning.retained.events.map(\.sequence) == [1, 2])
            guard case .placed(let suffix) = placed.requested else {
                Issue.record("expected a cursor from this recorder to remain placeable")
                continue
            }
            #expect(placed.retained.events.isEmpty)
            #expect(suffix.events.map(\.sequence) == [2])
            #expect(now.retained.events.isEmpty)
        }
    }

    @Test("follow subscriptions push one batch per ready interval and install delivered history")
    func followSubscriptionsOwnCursorAndReadiness() throws {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        let subscriptionId = UUID()
        let decisions = Mutex<[Bool]>([])
        let deliveries = Mutex<[TerminalFlightRecordingFollowBatch]>([])

        let accepted = recorder.addFollowSubscription(
            id: subscriptionId,
            from: recorder.liveCursor(),
            replicaHistoryIsComplete: false,
            decide: { _, historyIsComplete in
                decisions.withLock { $0.append(historyIsComplete) }
                return .events
            },
            deliver: { batch in deliveries.withLock { $0.append(batch) } }
        )
        #expect(accepted)

        recorder.markFollowSubscriptionReady(
            id: subscriptionId,
            replicaHistoryIsComplete: false
        )
        recorder.record(.feed([1]))
        recorder.record(.feed([2]))
        #expect(deliveries.withLock { $0.count } == 1)
        #expect(deliveries.withLock { $0.first?.snapshot.events.map(\.sequence) } == [0])

        recorder.markFollowSubscriptionReady(
            id: subscriptionId,
            replicaHistoryIsComplete: true
        )
        #expect(deliveries.withLock { $0.count } == 2)
        #expect(deliveries.withLock { $0.last?.snapshot.events.map(\.sequence) } == [1])
        #expect(decisions.withLock { $0 } == [false, true])
    }

    @Test("raw follow batches never pair terminal state and synchronizations pair once")
    func followPairingMatchesDecision() {
        let pairingCount = Mutex(0)
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.setFollowStatePairingSource {
            pairingCount.withLock { $0 += 1 }
            return nil
        }
        let rawId = UUID()
        let syncId = UUID()
        let raw = Mutex<[TerminalFlightRecordingFollowBatch]>([])
        let sync = Mutex<[TerminalFlightRecordingFollowBatch]>([])
        let rawAccepted = recorder.addFollowSubscription(
            id: rawId,
            from: recorder.liveCursor(),
            replicaHistoryIsComplete: false,
            decide: { _, _ in .events },
            deliver: { batch in raw.withLock { $0.append(batch) } }
        )
        #expect(rawAccepted)
        let syncAccepted = recorder.addFollowSubscription(
            id: syncId,
            from: recorder.liveCursor(),
            replicaHistoryIsComplete: false,
            decide: { _, _ in .synchronize },
            deliver: { batch in sync.withLock { $0.append(batch) } }
        )
        #expect(syncAccepted)
        recorder.markFollowSubscriptionReady(id: rawId, replicaHistoryIsComplete: false)
        recorder.markFollowSubscriptionReady(id: syncId, replicaHistoryIsComplete: false)

        recorder.record(.feed([1]))

        #expect(raw.withLock { $0.first?.state } == nil)
        #expect(sync.withLock { $0.first?.state } == nil)
        #expect(pairingCount.withLock { $0 } == 1)
    }

    @Test("a pane refuses its ninth follow subscription without disturbing the first eight")
    func followSubscriptionCapIsEight() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        let accepted = (0..<TerminalFlightRecorder.maximumFollowSubscriptions).map { _ in
            recorder.addFollowSubscription(
                id: UUID(),
                from: recorder.liveCursor(),
                replicaHistoryIsComplete: false,
                decide: { _, _ in .events },
                deliver: { _ in }
            )
        }
        #expect(accepted.allSatisfy { $0 })
        #expect(recorder.addFollowSubscription(
            id: UUID(),
            from: recorder.liveCursor(),
            replicaHistoryIsComplete: false,
            decide: { _, _ in .events },
            deliver: { _ in }
        ) == false)
        #expect(recorder.followSubscriptionCount == 8)
    }

    @Test("retains ordered events with monotonic elapsed timestamps")
    func retainsOrderedTimedEvents() {
        let clock = TestFlightClock([100, 112, 111, 140])
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: clock.now
        )

        recorder.record(.feed([0x41, 0x42]))
        recorder.record(.resize(columns: 100, rows: 30, pinned: false))
        recorder.record(.feed([0x43]))

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.event) == [
            .feed([0x41, 0x42]),
            .resize(columns: 100, rows: 30, pinned: false),
            .feed([0x43]),
        ])
        #expect(snapshot.events.map(\.elapsedNanoseconds) == [12, 12, 40])
        #expect(snapshot.droppedEventCount == 0)
    }

    @Test("an origin stamp is retained on the recorder's own elapsed scale")
    func originStampsShareTheElapsedScale() {
        // Intent: an origin submitted on the recorder's clock is retained as elapsed time
        //   since the recorder started, comparable with the transfer stamp beside it, and an
        //   event with no earlier origin retains none.
        // Why it exists: I3. Two stamps on different bases, or an absent origin recorded as
        //   zero, would both read as a measurement the tape never made.
        let clock = TestFlightClock([100, 140, 150])
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: clock.now
        )

        recorder.recordWrite([1, 2], origin: 120, attribution: .user)
        recorder.record(.feed([3]))

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.elapsedNanoseconds) == [40, 50])
        #expect(snapshot.events.map(\.originElapsedNanoseconds) == [20, nil])
    }

    @Test("an origin older than the recorder is retained at its start")
    func originBeforeRecorderStartClampsToZero() {
        // Intent: an origin from before this recorder existed is retained as its start rather
        //   than wrapping around the unsigned subtraction beneath it.
        // Why it exists: a pane's first keystroke can be encoded from an event the system
        //   created before the pane's recorder was constructed.
        let clock = TestFlightClock([100, 140])
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: clock.now
        )

        recorder.recordWrite([1], origin: 40, attribution: .user)

        #expect(recorder.capture().snapshot.events.map(\.originElapsedNanoseconds) == [0])
    }

    @Test("payload budget evicts the minimal oldest whole-event prefix")
    func payloadBudgetEvictsMinimalPrefix() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 134, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )

        recorder.record(.feed([1, 2, 3]))
        recorder.record(.feed([4, 5, 6, 7]))

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.event) == [.feed([4, 5, 6, 7])])
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedFeedBytes == 3)
    }

    @Test("bytes written toward the child are charged to the retention budget")
    func writePayloadIsChargedToTheBudget() {
        // Intent: a write event costs its payload plus the per-event overhead, exactly as a
        //   feed of the same size does, and evicts against the same budget.
        // Why it exists: retention charges payload bytes per event, so an event type that
        //   carried bytes for free would let a paste-heavy pane hold far more than its budget.
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 134, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )

        recorder.recordWrite([1, 2, 3], origin: nil, attribution: .user)
        recorder.recordWrite([4, 5, 6, 7], origin: nil, attribution: .user)

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.event) == [.write([4, 5, 6, 7])])
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedWriteBytes == 3)
    }

    @Test("per-event overhead bounds many tiny chunks")
    func eventOverheadBoundsTinyChunks() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 130, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )

        recorder.record(.feed([1]))
        recorder.record(.feed([2]))
        recorder.record(.feed([3]))

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.event) == [.feed([2]), .feed([3])])
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedFeedBytes == 1)
    }

    @Test("event-count cap evicts before the byte budget")
    func eventCountCapEvictsOldest() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 2, eventOverheadBytes: 64),
            now: { 0 }
        )

        recorder.record(.feed([1]))
        recorder.record(.resize(columns: 90, rows: 25, pinned: false))
        recorder.record(.feed([2]))

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.event) == [
            .resize(columns: 90, rows: 25, pinned: false),
            .feed([2]),
        ])
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedFeedBytes == 1)
    }

    @Test("byte offsets advance independently for the feed and write directions")
    func byteOffsetsAdvanceIndependentlyPerDirection() {
        // Intent: every byte-carrying event reports where its bytes sit within its own
        //   direction's lifetime stream, and an event that carries no bytes reports no span.
        // Why it exists: a reader locating retained bytes needs one coordinate per direction.
        //   A single shared counter would report a feed offset that no feed byte occupies, so
        //   no consumer could turn an offset back into a position in either stream.
        // Scenario: a pane interleaves child output, an input write, a resize, an empty feed,
        //   another write, and more output.
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 16, eventOverheadBytes: 8),
            now: { 0 }
        )

        recorder.record(.feed([1, 2, 3]))
        recorder.recordWrite([4, 5], origin: nil, attribution: .user)
        recorder.record(.resize(columns: 90, rows: 25, pinned: false))
        recorder.record(.feed([]))
        recorder.recordWrite([6], origin: nil, attribution: .user)
        recorder.record(.feed([7, 8]))

        #expect(recorder.capture().snapshot.events.map(\.payload) == [
            .init(byteOffset: 0, byteLength: 3),
            .init(byteOffset: 0, byteLength: 2),
            nil,
            .init(byteOffset: 3, byteLength: 0),
            .init(byteOffset: 2, byteLength: 1),
            .init(byteOffset: 3, byteLength: 2),
        ])
    }

    @Test("a cursor gap reports evicted feed and write bytes separately")
    func cursorGapReportsPerDirectionLoss() {
        // Intent: the loss between a requested cursor and the retained suffix is stated per
        //   direction, and the next cursor carries both watermarks.
        // Why it exists: a summed loss count cannot be subtracted from either direction's
        //   offsets, which would leave every byte position after a gap unverifiable. The
        //   trailing reader below starts from a cursor whose two watermarks differ and whose
        //   values differ from the retained head's, so each subtraction is pinned to its own
        //   direction: reading either coordinate from the other stream changes both answers.
        // Scenario: a slow follower that consumed the first output chunk and the first input
        //   write asks again after eviction dropped the two events that came next.
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 2, eventOverheadBytes: 8),
            now: { 0 }
        )
        recorder.record(.feed([1, 2, 3]))
        recorder.recordWrite([4, 5], origin: nil, attribution: .user)
        recorder.record(.feed([6]))
        recorder.recordWrite([7, 8, 9, 10], origin: nil, attribution: .user)
        recorder.record(.feed([11, 12]))
        recorder.recordWrite([13], origin: nil, attribution: .user)

        let fromBeginning = recorder.cursorSnapshot(from: .beginning)
        let fromTrailingReader = recorder.cursorSnapshot(from: .init(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: 2,
            feedBytesBeforeNextSequence: 3,
            writeBytesBeforeNextSequence: 2
        ))

        #expect(fromBeginning.firstRetainedSequence == 4)
        #expect(fromBeginning.droppedEventCount == 4)
        #expect(fromBeginning.droppedFeedBytes == 4)
        #expect(fromBeginning.droppedWriteBytes == 6)
        #expect(fromTrailingReader.droppedEventCount == 2)
        #expect(fromTrailingReader.droppedFeedBytes == 1)
        #expect(fromTrailingReader.droppedWriteBytes == 4)
        #expect(fromTrailingReader.nextCursor == .init(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: 6,
            feedBytesBeforeNextSequence: 6,
            writeBytesBeforeNextSequence: 7
        ))
    }

    @Test("cursor snapshots retain stable lifetime sequences across eviction")
    func cursorSnapshotsRetainStableSequences() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 2, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.feed([1]))
        recorder.record(.feed([2, 3]))

        let delivered = recorder.cursorSnapshot(from: .beginning)
        let suffix = recorder.cursorSnapshot(from: .init(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: 1,
            feedBytesBeforeNextSequence: 1,
            writeBytesBeforeNextSequence: 0
        ))
        recorder.record(.feed([4, 5, 6, 7]))
        recorder.record(.resize(columns: 100, rows: 30, pinned: false))

        let retained = recorder.cursorSnapshot(from: delivered.nextCursor)
        let truncatedBacklog = recorder.cursorSnapshot(from: .beginning)
        #expect(delivered.events.map(\.sequence) == [0, 1])
        #expect(suffix.events.map(\.sequence) == [1])
        #expect(delivered.nextCursor == .init(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: 2,
            feedBytesBeforeNextSequence: 3,
            writeBytesBeforeNextSequence: 0
        ))
        #expect(retained.firstRetainedSequence == 2)
        #expect(retained.events.map(\.sequence) == [2, 3])
        #expect(retained.droppedEventCount == 0)
        #expect(retained.droppedFeedBytes == 0)
        #expect(retained.nextCursor == .init(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: 4,
            feedBytesBeforeNextSequence: 7,
            writeBytesBeforeNextSequence: 0
        ))
        #expect(truncatedBacklog.droppedEventCount == 2)
        #expect(truncatedBacklog.droppedFeedBytes == 3)
        #expect(truncatedBacklog.events.map(\.sequence) == [2, 3])
    }

    @Test("cursor gap counts only undelivered events evicted after an earlier batch")
    func cursorGapExcludesPreviouslyDeliveredEvictions() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 2, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.feed([1]))
        recorder.record(.feed([2, 3]))
        let delivered = recorder.cursorSnapshot(from: .beginning)

        recorder.record(.feed([4, 5, 6, 7]))
        recorder.record(.feed([8, 9, 10, 11, 12]))
        recorder.record(.feed([13, 14, 15, 16, 17, 18]))

        let snapshot = recorder.cursorSnapshot(from: delivered.nextCursor)
        #expect(snapshot.firstRetainedSequence == 3)
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedFeedBytes == 4)
        #expect(snapshot.events.map(\.sequence) == [3, 4])
        #expect(snapshot.events.map(\.event) == [
            .feed([8, 9, 10, 11, 12]),
            .feed([13, 14, 15, 16, 17, 18]),
        ])
    }

    @Test("cursor inside the retained range uses its offset from the retained head")
    func cursorInsideRetainedRangeAfterEviction() {
        // Intent: a cursor within an evicted recorder's retained range returns the exact suffix.
        // Why it exists: pins down the non-zero retained base and non-zero cursor offset that
        //   index-backed storage must translate into a buffer-relative position.
        // Scenario: a polling reader resumes from sequence 3 after sequences 0 and 1 were evicted.
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 3, eventOverheadBytes: 64),
            now: { 0 }
        )
        for payloadSize in 1...5 {
            recorder.record(.feed(Array(repeating: UInt8(payloadSize), count: payloadSize)))
        }

        let snapshot = recorder.cursorSnapshot(from: .init(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: 3,
            feedBytesBeforeNextSequence: 6,
            writeBytesBeforeNextSequence: 0
        ))

        #expect(snapshot.firstRetainedSequence == 2)
        #expect(snapshot.events.map(\.sequence) == [3, 4])
        #expect(snapshot.droppedEventCount == 0)
        #expect(snapshot.droppedFeedBytes == 0)
    }

    @Test("caught-up cursor remains empty after head eviction")
    func caughtUpCursorAfterEviction() {
        // Intent: a caught-up cursor returns no events when the retained sequence base is non-zero.
        // Why it exists: pins down the offset-at-end boundary for index-backed recorder storage.
        // Scenario: a polling reader asks again after consuming all five lifetime events.
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 3, eventOverheadBytes: 64),
            now: { 0 }
        )
        for payloadSize in 1...5 {
            recorder.record(.feed(Array(repeating: UInt8(payloadSize), count: payloadSize)))
        }
        let cursor = TerminalFlightRecordingCursor(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: 5,
            feedBytesBeforeNextSequence: 15,
            writeBytesBeforeNextSequence: 0
        )

        let snapshot = recorder.cursorSnapshot(from: cursor)

        #expect(snapshot.events.isEmpty)
        #expect(snapshot.firstRetainedSequence == 2)
        #expect(snapshot.droppedEventCount == 0)
        #expect(snapshot.droppedFeedBytes == 0)
        #expect(snapshot.nextCursor == cursor)
    }

    @Test("cursors from another recorder lifetime are unplaceable at every sequence")
    func foreignLifetimeCursorsAreUnplaceable() {
        let firstLifetime = UUID()
        let secondLifetime = UUID()
        let oldRecorder = TerminalFlightRecorder(
            lifetimeId: firstLifetime,
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        oldRecorder.record(.feed([1]))
        let belowNewHead = oldRecorder.capture().snapshot.nextCursor
        oldRecorder.record(.feed([2]))
        oldRecorder.record(.feed([3]))
        oldRecorder.record(.feed([4]))
        let aboveNewHead = oldRecorder.capture().snapshot.nextCursor
        let newRecorder = TerminalFlightRecorder(
            lifetimeId: secondLifetime,
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 1, eventOverheadBytes: 64),
            now: { 0 }
        )
        newRecorder.record(.feed([3]))
        newRecorder.record(.feed([4]))
        newRecorder.record(.feed([5]))

        #expect(newRecorder.cursorPlacement(from: belowNewHead).isUnplaceable)
        #expect(newRecorder.cursorPlacement(from: aboveNewHead).isUnplaceable)
        #expect(newRecorder.cursorPlacement(from: .beginning).isUnplaceable)
        #expect(belowNewHead.recorderLifetimeId == firstLifetime)
        #expect(newRecorder.capture().snapshot.nextCursor.recorderLifetimeId == secondLifetime)
    }

    @Test("out-of-range coordinates in the current lifetime are unplaceable")
    func outOfRangeCurrentLifetimeCursorIsUnplaceable() {
        let lifetimeId = UUID()
        let recorder = TerminalFlightRecorder(
            lifetimeId: lifetimeId,
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.feed([1]))

        let future = TerminalFlightRecordingCursor(
            recorderLifetimeId: lifetimeId,
            nextSequence: 2,
            feedBytesBeforeNextSequence: 1,
            writeBytesBeforeNextSequence: 0
        )
        let impossibleWatermark = TerminalFlightRecordingCursor(
            recorderLifetimeId: lifetimeId,
            nextSequence: 1,
            feedBytesBeforeNextSequence: 2,
            writeBytesBeforeNextSequence: 0
        )
        let negativeWatermark = TerminalFlightRecordingCursor(
            recorderLifetimeId: lifetimeId,
            nextSequence: 1,
            feedBytesBeforeNextSequence: -1,
            writeBytesBeforeNextSequence: 0
        )

        #expect(recorder.cursorPlacement(from: future).isUnplaceable)
        #expect(recorder.cursorPlacement(from: impossibleWatermark).isUnplaceable)
        #expect(recorder.cursorPlacement(from: negativeWatermark).isUnplaceable)
    }

    @Test("zero byte budget can fully drain retained events")
    func zeroByteBudgetFullyDrainsRecorder() {
        // Intent: a recorder may retain no slots while preserving lifetime sequence and loss totals.
        // Why it exists: pins down the empty-buffer fallback used by snapshots and invariants.
        // Scenario: a pane configured with no recording budget receives two feed events.
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 0, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.feed([1, 2]))
        recorder.record(.feed([3, 4, 5]))

        let dump = recorder.capture().snapshot
        let cursorSnapshot = recorder.cursorSnapshot(from: .beginning)

        #expect(dump.events.isEmpty)
        #expect(cursorSnapshot.events.isEmpty)
        #expect(cursorSnapshot.firstRetainedSequence == cursorSnapshot.nextSequence)
        #expect(cursorSnapshot.droppedEventCount == 2)
        #expect(cursorSnapshot.droppedFeedBytes == 5)
    }

    @Test("production recorder preserves order across repeated ring wraparound")
    func productionRecorderRingWraparound() {
        // Intent: bounded storage preserves a contiguous retained run and exact cursor suffix at scale.
        // Why it exists: pins down ordering across circular-buffer wraparound after repeated eviction.
        // Scenario: a busy pane records three times the production event limit before a reader polls.
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .production,
            now: { 0 }
        )
        let eventLimit = 32_768
        let recordedCount = 3 * eventLimit
        for _ in 0..<recordedCount {
            recorder.record(.feed([1]))
        }

        let dump = recorder.capture().snapshot
        let firstRetainedSequence = UInt64(recordedCount - eventLimit)
        let midSequence = firstRetainedSequence + UInt64(eventLimit / 2)
        let suffix = recorder.cursorSnapshot(from: .init(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: midSequence,
            feedBytesBeforeNextSequence: Int(midSequence),
            writeBytesBeforeNextSequence: 0
        ))

        #expect(dump.events.count == eventLimit)
        #expect(dump.events.first?.sequence == firstRetainedSequence)
        #expect(dump.events.last?.sequence == UInt64(recordedCount - 1))
        #expect(suffix.events.map(\.sequence) == Array(midSequence..<UInt64(recordedCount)))
    }

    @Test("from-now origin pairs current geometry with the next event cursor")
    func fromNowOriginIsAtomicRecorderState() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.feed([1, 2]))
        recorder.recordWrite([9, 10, 11], origin: nil, attribution: .user)
        recorder.record(.resize(columns: 100, rows: 30, pinned: false))

        let origin = recorder.fromNowOrigin()
        recorder.record(.feed([3]))
        let snapshot = recorder.cursorSnapshot(from: origin.cursor)

        #expect(origin.initial == .init(columns: 100, rows: 30, pinned: false))
        // Both watermarks ride the origin. A tail-only stream that lost the write watermark
        // would report every write byte recorded before it began as loss on its first gap.
        #expect(origin.cursor == .init(
            recorderLifetimeId: recorder.backlogOrigin().cursor.recorderLifetimeId,
            nextSequence: 3,
            feedBytesBeforeNextSequence: 2,
            writeBytesBeforeNextSequence: 3
        ))
        #expect(snapshot.events.map(\.sequence) == [3])
        #expect(snapshot.events.map(\.event) == [.feed([3])])
        #expect(snapshot.droppedFeedBytes == 0)
        #expect(snapshot.droppedWriteBytes == 0)
    }

    @Test("backlog origin pairs birth geometry with the beginning cursor")
    func backlogOriginUsesBirthGeometry() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.resize(columns: 100, rows: 30, pinned: false))

        let origin = recorder.backlogOrigin()
        #expect(origin.initial == .init(columns: 80, rows: 24, pinned: false))
        #expect(origin.cursor.nextSequence == 0)
        #expect(origin.cursor.feedBytesBeforeNextSequence == 0)
        #expect(origin.cursor.writeBytesBeforeNextSequence == 0)

        // A finite capture is that same origin paired with the read it describes, taken as one
        // moment. Geometry read apart from the events would let a dump state the pane's shape
        // from before an event it then reports.
        let capture = recorder.capture()
        #expect(capture.origin == origin)
        #expect(capture.snapshot == recorder.cursorSnapshot(from: .beginning))
    }

    // Intent: a host built the way the shipping app builds one records from birth.
    // Why it exists: the recorder used to be gated on a bundle capability the
    //   notarized bundle could never set, so a production pane kept no evidence of
    //   itself. This replaces the coverage for that recorder-less configuration,
    //   which no longer exists: the initializer takes no input that suppresses a tape.
    @Test("a host built through the shipping initializer retains a flight recording")
    func shippingHostRetainsFlightRecording() throws {
        let host = try TerminalPTYHost(
            launchInput: LaunchPolicyInput(
                accountShell: nil,
                executablePaths: [],
                requestedWorkingDirectory: nil,
                homeDirectory: nil,
                accessibleDirectories: [],
                inheritedEnvironment: [],
                advertisedEnvironment: [],
                paneEnvironment: [],
                command: nil,
                launchCommand: nil,
                initialDimensions: .init(columns: 80, rows: 24)
            ),
            bootstrapExecutable: "/unused",
            productIdentity: .test
        )

        host.stageFixtureOutput(Array("retained".utf8))

        #expect(
            host.fencedFlightRecordingCapture().snapshot.events.map(\.event)
                == [.feed(Array("retained".utf8))]
        )
    }

    // Intent: no single record a production-bounded recorder can produce exceeds the IPC line
    //   ceiling once it is wrapped in the `pane.tape.event` notification that carries it.
    // Why it exists: the tape now reaches a reader as one framed line per record, so the
    //   ceiling applies to the largest record, not to the whole capture. A retention budget
    //   that admits one event larger than a line would make that pane's tape unreadable, and
    //   no smaller record before or after it would show the problem.
    // Scenario: one pane fills its whole payload budget with a single burst of output, and
    //   another fills its whole event ring with the costliest small record the schema admits.
    @Test("no single record from a production-bounded recorder exceeds one JSON-RPC line")
    func productionBoundsFitIPCLine() throws {
        let bulkRecorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .production,
            now: { 0 }
        )
        bulkRecorder.record(.feed(Array(repeating: 0xFF, count: 8 * 1_024 * 1_024 - 128)))

        // A full ring of input-direction events, each with the widest origin stamp the clock
        // can produce. That is the costliest per-event encoding the schema admits, so a ring
        // of output events of the same size fits wherever this one does.
        let tinyRecorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .production,
            now: { 0 }
        )
        for _ in 0..<32_768 {
            tinyRecorder.recordWrite([0xFF], origin: .max, attribution: .user)
        }

        for recorder in [bulkRecorder, tinyRecorder] {
            let events = recorder.capture().snapshot.events
            #expect(events.isEmpty == false)
            var widestLine = Data()
            for event in events {
                let line = try encodeIpcLine(paneTapeEventNotification(event))
                if line.count > widestLine.count { widestLine = line }
            }
            #expect(widestLine.count <= IpcLineFramer.maxLineBytes)
            #expect(
                try JSONDecoder().decode(JsonRpcRequest.self, from: widestLine).method
                    == Methods.paneTapeEvent
            )
        }
    }

    // Intent: a production-configured recorder drops every interaction-intent kind it is
    // handed and keeps only the boundary vocabulary.
    // Why it exists: host call sites record unconditionally, so the configuration is the
    // only thing standing between a live pane's tape and events a following replica would
    // apply -- mirrored selection, a yanked viewport, doubled keystroke records.
    // Scenario: one pane is driven through every recordable kind; its production tape keeps
    // the feed, the write, and the resize.
    @Test("a production-configured recorder keeps only boundary events")
    func productionConfigurationRecordsNoInteractionIntent() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .production,
            now: { 0 }
        )

        recordEveryKind(into: recorder)

        let expected: [NeutralTerminalRecordingEvent] = [
            .feed([1, 2, 3]),
            .write([4, 5]),
            .resize(columns: 100, rows: 30, pinned: true),
        ]
        #expect(recorder.capture().snapshot.events.map(\.event) == expected)
    }

    // Intent: the complete configuration records every kind in the order it was applied,
    // and the interaction kinds carry neither a payload span nor an origin stamp.
    // Why it exists: characterization replay reproduces a pane from this order alone, and a
    // payload span on a byteless event would misplace every later byte-carrying one.
    @Test("the complete configuration records every applied kind in order")
    func completeConfigurationRecordsInteractionIntentInOrder() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .complete,
            now: { 0 }
        )

        recordEveryKind(into: recorder)

        let events = recorder.capture().snapshot.events
        let expected: [NeutralTerminalRecordingEvent] = [
            .feed([1, 2, 3]),
            .input(key: .character("a"), modifiers: []),
            .paste("hé"),
            .focus(true),
            .mouse(.init(action: .move, column: 2, row: 3)),
            .viewport(.byRows(-4)),
            .write([4, 5]),
            .resize(columns: 100, rows: 30, pinned: true),
        ]
        #expect(events.map(\.event) == expected)
        let interaction = events.filter { event in
            switch event.event {
            case .input, .paste, .focus, .mouse, .viewport: true
            default: false
            }
        }
        #expect(interaction.count == 5)
        #expect(interaction.allSatisfy { $0.payload == nil })
        #expect(interaction.allSatisfy { $0.originElapsedNanoseconds == nil })
    }

    // Intent: interaction events sit between byte-carrying ones without moving either
    // direction's lifetime watermark.
    // Why it exists: a cursor turns a byte offset back into a position, so an interaction
    // event that advanced a watermark would silently shift every following payload span.
    @Test("interaction events leave both byte watermarks where they were")
    func interactionEventsNeverAdvanceByteWatermarks() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .complete,
            now: { 0 }
        )

        recorder.record(.feed([1, 2, 3]))
        recorder.record(.paste("hello"))
        recorder.recordWrite([9, 9], origin: nil, attribution: .user)
        recorder.record(.mouse(.init(action: .move, column: 0, row: 0)))
        recorder.record(.feed([4]))

        let expected: [TerminalFlightRecordingPayloadSpan?] = [
            .init(byteOffset: 0, byteLength: 3),
            nil,
            .init(byteOffset: 0, byteLength: 2),
            nil,
            .init(byteOffset: 3, byteLength: 1),
        ]
        #expect(recorder.capture().snapshot.events.map(\.payload) == expected)
        #expect(recorder.liveCursor().feedBytesBeforeNextSequence == 4)
        #expect(recorder.liveCursor().writeBytesBeforeNextSequence == 2)
    }

    // Intent: a paste is charged its UTF-8 byte count against the retention budget, yet
    // evicting it reports no lost feed or write bytes.
    // Why it exists: a paste can carry megabytes, so leaving it uncharged would let one
    // clipboard drop blow past the per-pane budget the IPC line ceiling was chosen against;
    // charging it as feed or write bytes would instead report a byte gap that never existed.
    @Test("a bounded recorder charges a paste but reports no payload loss when it evicts")
    func boundedConfigurationChargesPasteWithoutReportingByteLoss() {
        let recorder = TerminalFlightRecorder(
            initialGeometry: .init(columns: 80, rows: 24, pinned: false),
            configuration: .init(
                budgetBytes: 16,
                eventLimit: 64,
                eventOverheadBytes: 0,
                recordsInteractionIntent: true
            ),
            now: { 0 }
        )

        recorder.record(.paste("abcdefgh"))
        recorder.record(.feed([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))

        let snapshot = recorder.capture().snapshot
        let expected: [NeutralTerminalRecordingEvent] = [.feed([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])]
        #expect(snapshot.events.map(\.event) == expected)
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedFeedBytes == 0)
        #expect(snapshot.droppedWriteBytes == 0)
    }

    /// Drives one recorder through every kind `record` accepts, so a configuration test can
    /// assert on what survived rather than on what it chose to offer.
    private func recordEveryKind(into recorder: TerminalFlightRecorder) {
        recorder.record(.feed([1, 2, 3]))
        recorder.record(.input(key: .character("a"), modifiers: []))
        recorder.record(.paste("hé"))
        recorder.record(.focus(true))
        recorder.record(.mouse(.init(action: .move, column: 2, row: 3)))
        recorder.record(.viewport(.byRows(-4)))
        recorder.recordWrite([4, 5], origin: nil, attribution: .user)
        recorder.record(.resize(columns: 100, rows: 30, pinned: true))
    }
}

/// Wraps one recorded event in the notification the producer sends it in, so the size this
/// file measures is the size that actually has to cross the socket. The record shape mirrors
/// the producer's in DanTermSupport, which this package cannot import.
///
/// The producer may put several records in one such notification and splits that line when it
/// would pass the framing bound. A group of one record has no boundary left to split at, so
/// the per-record bound this file measures is what the split rule rests on.
private func paneTapeEventNotification(
    _ event: TerminalFlightRecordingEvent
) throws -> JsonRpcRequest {
    var record: [String: JSONValue] = [
        "kind": .string("event"),
        "sequence": .number(Double(event.sequence)),
        "elapsedNanoseconds": .number(Double(event.elapsedNanoseconds)),
        "event": try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(event.event)
        ),
    ]
    if let origin = event.originElapsedNanoseconds {
        record["originElapsedNanoseconds"] = .number(Double(origin))
    }
    if let payload = event.payload {
        record["byteOffset"] = .number(Double(payload.byteOffset))
        record["byteLength"] = .number(Double(payload.byteLength))
    }
    return JsonRpcRequest(
        method: Methods.paneTapeEvent,
        params: .object([
            "subscription": .string(UUID().uuidString),
            "records": .array([.object(record)]),
        ])
    )
}

private final class TestFlightClock: Sendable {
    private let values: Mutex<ArraySlice<UInt64>>

    init(_ values: [UInt64]) {
        self.values = Mutex(values[...])
    }

    func now() -> UInt64 {
        values.withLock { $0.popFirst() ?? 0 }
    }
}
