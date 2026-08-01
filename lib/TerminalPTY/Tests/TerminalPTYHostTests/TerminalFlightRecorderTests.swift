// Behavioral proofs for the bounded live-pane recorder independent of real PTY timing.
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
