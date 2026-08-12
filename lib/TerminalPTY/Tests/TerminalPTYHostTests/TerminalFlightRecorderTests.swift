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

        let snapshot = recorder.snapshot()
        #expect(snapshot.events.map(\.event) == [
            .feed([0x41, 0x42]),
            .resize(columns: 100, rows: 30),
            .feed([0x43]),
        ])
        #expect(snapshot.events.map(\.elapsedNanoseconds) == [12, 12, 40])
        #expect(snapshot.isTruncated == false)
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

        let snapshot = recorder.snapshot()
        #expect(snapshot.events.map(\.event) == [.feed([4, 5, 6, 7])])
        #expect(snapshot.accountedBytes == 68)
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedPayloadBytes == 3)
        #expect(snapshot.isTruncated)
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

        let snapshot = recorder.snapshot()
        #expect(snapshot.events.map(\.event) == [.write([4, 5, 6, 7])])
        #expect(snapshot.accountedBytes == 68)
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedPayloadBytes == 3)
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

        let snapshot = recorder.snapshot()
        #expect(snapshot.events.map(\.event) == [.feed([2]), .feed([3])])
        #expect(snapshot.accountedBytes == 130)
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedPayloadBytes == 1)
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

        let snapshot = recorder.snapshot()
        #expect(snapshot.events.map(\.event) == [
            .resize(columns: 90, rows: 25),
            .feed([2]),
        ])
        #expect(snapshot.droppedEventCount == 1)
        #expect(snapshot.droppedPayloadBytes == 1)
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
            nextSequence: 1,
            payloadBytesBeforeNextSequence: 1
        ))
        recorder.record(.feed([4, 5, 6, 7]))
        recorder.record(.resize(columns: 100, rows: 30))

        let retained = recorder.cursorSnapshot(from: delivered.nextCursor)
        let truncatedBacklog = recorder.cursorSnapshot(from: .beginning)
        #expect(delivered.events.map(\.sequence) == [0, 1])
        #expect(suffix.events.map(\.sequence) == [1])
        #expect(delivered.nextCursor == .init(nextSequence: 2, payloadBytesBeforeNextSequence: 3))
        #expect(retained.firstRetainedSequence == 2)
        #expect(retained.events.map(\.sequence) == [2, 3])
        #expect(retained.droppedEventCount == 0)
        #expect(retained.droppedPayloadBytes == 0)
        #expect(retained.nextCursor == .init(nextSequence: 4, payloadBytesBeforeNextSequence: 7))
        #expect(truncatedBacklog.droppedEventCount == 2)
        #expect(truncatedBacklog.droppedPayloadBytes == 3)
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
        #expect(snapshot.droppedPayloadBytes == 4)
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
            nextSequence: 3,
            payloadBytesBeforeNextSequence: 6
        ))

        #expect(snapshot.firstRetainedSequence == 2)
        #expect(snapshot.events.map(\.sequence) == [3, 4])
        #expect(snapshot.droppedEventCount == 0)
        #expect(snapshot.droppedPayloadBytes == 0)
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
            nextSequence: 5,
            payloadBytesBeforeNextSequence: 15
        )

        let snapshot = recorder.cursorSnapshot(from: cursor)

        #expect(snapshot.events.isEmpty)
        #expect(snapshot.firstRetainedSequence == 2)
        #expect(snapshot.droppedEventCount == 0)
        #expect(snapshot.droppedPayloadBytes == 0)
        #expect(snapshot.nextCursor == cursor)
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

        let dump = recorder.snapshot()
        let cursorSnapshot = recorder.cursorSnapshot(from: .beginning)

        #expect(dump.events.isEmpty)
        #expect(dump.accountedBytes == 0)
        #expect(cursorSnapshot.events.isEmpty)
        #expect(cursorSnapshot.firstRetainedSequence == cursorSnapshot.nextSequence)
        #expect(cursorSnapshot.droppedEventCount == 2)
        #expect(cursorSnapshot.droppedPayloadBytes == 5)
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

        let dump = recorder.snapshot()
        let firstRetainedSequence = UInt64(recordedCount - eventLimit)
        let midSequence = firstRetainedSequence + UInt64(eventLimit / 2)
        let suffix = recorder.cursorSnapshot(from: .init(
            nextSequence: midSequence,
            payloadBytesBeforeNextSequence: Int(midSequence)
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
        recorder.record(.resize(columns: 100, rows: 30))

        let origin = recorder.fromNowOrigin()
        recorder.record(.feed([3]))
        let snapshot = recorder.cursorSnapshot(from: origin.cursor)

        #expect(origin.initial == .init(columns: 100, rows: 30))
        #expect(origin.cursor == .init(nextSequence: 2, payloadBytesBeforeNextSequence: 2))
        #expect(snapshot.events.map(\.sequence) == [2])
        #expect(snapshot.events.map(\.event) == [.feed([3])])
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
        #expect(origin.cursor == .beginning)
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

        host.deliverOutputForTesting(Array("retained".utf8))

        #expect(
            host.fencedFlightRecording().events.map(\.event)
                == [.feed(Array("retained".utf8))]
        )
    }

    @Test("dump encoding produces one replayable raw recording document")
    func dumpEncodingProducesReplayableDocument() throws {
        let clock = TestFlightClock([100, 112, 125])
        let recorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 4, rows: 2),
            configuration: .init(budgetBytes: 1_024, eventLimit: 8, eventOverheadBytes: 64),
            now: clock.now
        )
        recorder.record(.feed([0x41, 0x00, 0xFF]))
        recorder.record(.resize(columns: 5, rows: 3))

        let data = try recorder.snapshot().encodedRecording()
        let recording = try JSONDecoder().decode(NeutralTerminalRecording.self, from: data)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let events = try #require(json["events"] as? [[String: Any]])
        let truncation = try #require(json["truncation"] as? [String: Any])

        #expect(recording.provenance == .liveCapture())
        #expect(recording.events == [.feed([0x41, 0x00, 0xFF]), .resize(columns: 5, rows: 3)])
        #expect(events.compactMap { ($0["elapsedNanoseconds"] as? NSNumber)?.uint64Value } == [12, 25])
        #expect(truncation["isTruncated"] as? Bool == false)
        #expect(truncation["droppedEventCount"] as? Int == 0)
        #expect(truncation["droppedPayloadBytes"] as? Int == 0)
        #expect(events.allSatisfy { $0["sequence"] == nil })
        _ = try recording.replay()
    }

    @Test("production recorder bounds fit complete JSON-RPC lines")
    func productionBoundsFitIPCLine() throws {
        let bulkRecorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .production,
            now: { 0 }
        )
        bulkRecorder.record(.feed(Array(repeating: 0xFF, count: 8 * 1_024 * 1_024 - 128)))

        let tinyRecorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .production,
            now: { 0 }
        )
        for _ in 0..<32_768 {
            tinyRecorder.record(.feed([0xFF]))
        }

        for snapshot in [bulkRecorder.snapshot(), tinyRecorder.snapshot()] {
            let document = try JSONDecoder().decode(JSONValue.self, from: snapshot.encodedRecording())
            let line = try encodeIpcLine(JsonRpcResponse(id: .number(1), result: document))
            #expect(line.count <= IpcLineFramer.maxLineBytes)
            #expect(try JSONDecoder().decode(JsonRpcResponse.self, from: line).result == document)
        }
    }

    @Test("dump encoding carries lifetime eviction metadata")
    func dumpEncodingCarriesEvictionMetadata() throws {
        let recorder = TerminalFlightRecorder(
            initialDimensions: .init(columns: 80, rows: 24),
            configuration: .init(budgetBytes: 65, eventLimit: 8, eventOverheadBytes: 64),
            now: { 0 }
        )
        recorder.record(.feed([1]))
        recorder.record(.feed([2]))

        let json = try #require(
            JSONSerialization.jsonObject(with: recorder.snapshot().encodedRecording())
                as? [String: Any]
        )
        let truncation = try #require(json["truncation"] as? [String: Any])

        #expect(truncation["isTruncated"] as? Bool == true)
        #expect(truncation["droppedEventCount"] as? Int == 1)
        #expect(truncation["droppedPayloadBytes"] as? Int == 1)
    }
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
