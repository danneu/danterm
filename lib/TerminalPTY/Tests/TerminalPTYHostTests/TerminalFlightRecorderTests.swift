// Behavioral proofs for the bounded live-pane recorder independent of real PTY timing.
import Foundation
import DanTermProtocol
import TerminalCoreRecording
@testable import TerminalPTYHost
import Synchronization
import Testing

struct TerminalFlightRecorderTests {
    @Test("follow notices stay coalesced until their cursor snapshot rearms them")
    func followNoticesCoalesceUntilSnapshot() {
        let recorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        let subscriptionId = UUID()
        let noticeCount = Mutex(0)
        recorder.addFollowNotice(
            id: subscriptionId,
            from: .beginning,
            notify: { noticeCount.withLock { $0 += 1 } }
        )

        recorder.record(.feed([1]))
        recorder.record(.feed([2]))
        #expect(noticeCount.withLock { $0 } == 1)

        let first = recorder.followCursorSnapshot(
            subscriptionId: subscriptionId,
            from: .beginning
        )
        #expect(first?.events.map(\.sequence) == [0, 1])
        recorder.record(.resize(columns: 100, rows: 30))
        recorder.record(.feed([3]))
        #expect(noticeCount.withLock { $0 } == 2)

        let second = recorder.followCursorSnapshot(
            subscriptionId: subscriptionId,
            from: first?.nextCursor ?? .beginning
        )
        #expect(second?.events.map(\.sequence) == [2, 3])
    }

    @Test("follow registration signals backlog and removal stops later notices")
    func followNoticeBacklogAndRemoval() {
        let recorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.feed([1]))
        let subscriptionId = UUID()
        let noticeCount = Mutex(0)

        recorder.addFollowNotice(
            id: subscriptionId,
            from: .beginning,
            notify: { noticeCount.withLock { $0 += 1 } }
        )
        #expect(noticeCount.withLock { $0 } == 1)

        recorder.removeFollowNotice(id: subscriptionId)
        recorder.record(.feed([2]))
        #expect(noticeCount.withLock { $0 } == 1)
        #expect(recorder.followCursorSnapshot(
            subscriptionId: subscriptionId,
            from: .beginning
        ) == nil)
    }

    @Test("retains ordered events with monotonic elapsed timestamps")
    func retainsOrderedTimedEvents() {
        let clock = TestFlightClock([100, 112, 111, 140])
        let recorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: clock.now
        )

        recorder.record(.feed([0x41, 0x42]))
        recorder.record(.resize(columns: 100, rows: 30))
        recorder.record(.feed([0x43]))

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.event) == [
            .feed([0x41, 0x42]),
            .resize(columns: 100, rows: 30),
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: clock.now
        )

        recorder.record(.write([1, 2]), origin: 120)
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: clock.now
        )

        recorder.record(.write([1]), origin: 40)

        #expect(recorder.capture().snapshot.events.map(\.originElapsedNanoseconds) == [0])
    }

    @Test("payload budget evicts the minimal oldest whole-event prefix")
    func payloadBudgetEvictsMinimalPrefix() {
        let recorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 134, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )

        recorder.record(.write([1, 2, 3]))
        recorder.record(.write([4, 5, 6, 7]))

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.event) == [.write([4, 5, 6, 7])])
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedWriteBytes == 3)
    }

    @Test("per-event overhead bounds many tiny chunks")
    func eventOverheadBoundsTinyChunks() {
        let recorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 2, eventOverheadBytes: 64),
            now: { 0 }
        )

        recorder.record(.feed([1]))
        recorder.record(.resize(columns: 90, rows: 25))
        recorder.record(.feed([2]))

        let snapshot = recorder.capture().snapshot
        #expect(snapshot.events.map(\.event) == [
            .resize(columns: 90, rows: 25),
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 16, eventOverheadBytes: 8),
            now: { 0 }
        )

        recorder.record(.feed([1, 2, 3]))
        recorder.record(.write([4, 5]))
        recorder.record(.resize(columns: 90, rows: 25))
        recorder.record(.feed([]))
        recorder.record(.write([6]))
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 2, eventOverheadBytes: 8),
            now: { 0 }
        )
        recorder.record(.feed([1, 2, 3]))
        recorder.record(.write([4, 5]))
        recorder.record(.feed([6]))
        recorder.record(.write([7, 8, 9, 10]))
        recorder.record(.feed([11, 12]))
        recorder.record(.write([13]))

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
            initialDimensions: .init(columns: 80, rows: 24),
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
        recorder.record(.resize(columns: 100, rows: 30))

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
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.feed([1, 2]))
        recorder.record(.write([9, 10, 11]))
        recorder.record(.resize(columns: 100, rows: 30))

        let origin = recorder.fromNowOrigin()
        recorder.record(.feed([3]))
        let snapshot = recorder.cursorSnapshot(from: origin.cursor)

        #expect(origin.initial == .init(columns: 100, rows: 30))
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.resize(columns: 100, rows: 30))

        let origin = recorder.backlogOrigin()
        #expect(origin.initial == .init(columns: 80, rows: 24))
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
            initialDimensions: .init(columns: 80, rows: 24),
            bootstrapExecutable: "/unused"
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
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .production,
            now: { 0 }
        )
        bulkRecorder.record(.feed(Array(repeating: 0xFF, count: 8 * 1_024 * 1_024 - 128)))

        // A full ring of input-direction events, each with the widest origin stamp the clock
        // can produce. That is the costliest per-event encoding the schema admits, so a ring
        // of output events of the same size fits wherever this one does.
        let tinyRecorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .production,
            now: { 0 }
        )
        for _ in 0..<32_768 {
            tinyRecorder.record(.write([0xFF]), origin: .max)
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
}

/// Wraps one recorded event in the notification the producer sends it in, so the size this
/// file measures is the size that actually has to cross the socket. The record shape mirrors
/// the producer's in DanTermSupport, which this package cannot import.
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
            "record": .object(record),
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
