// Behavioral proofs for the bounded live-pane recorder independent of real PTY timing.
import Foundation
import DanTermProtocol
import TerminalCoreRecording
@testable import TerminalPTYHost
import Synchronization
import Testing

struct TerminalFlightRecorderTests {
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

    @Test("disabled host configuration retains no flight recording")
    func disabledHostRetainsNothing() throws {
        let host = try TerminalPTYHost(
            initialDimensions: .init(columns: 80, rows: 24),
            bootstrapExecutable: "/unused",
            recordsFlightTape: false
        )

        host.deliverOutputForTesting(Array("not retained".utf8))

        #expect(host.fencedFlightRecording() == nil)
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
