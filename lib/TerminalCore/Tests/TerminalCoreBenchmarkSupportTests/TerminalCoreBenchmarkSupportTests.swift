// Behavioral tests for duration-stable headless Terminal.feed measurement policy.
import Foundation
import TerminalCore
import Testing
@testable import TerminalCoreBenchmarkSupport

@Suite("Terminal core benchmark support")
struct TerminalCoreBenchmarkSupportTests {
    @Test("feed batches create a fresh terminal for every execution")
    func feedBatchCreatesFreshTerminalPerExecution() throws {
        var creations = 0
        var clock = [UInt64](arrayLiteral: 0, 10, 10, 20, 20, 30).makeIterator()

        let duration = measureFeedBatch(
            fixture: CoreBenchmarkFixture(timed: [Array("x".utf8)]),
            executionCount: 3,
            makeTerminal: {
                creations += 1
                return Terminal(columns: 80, rows: 24)
            },
            now: { clock.next()! }
        )

        #expect(creations == 3)
        #expect(duration == 30)
    }

    @Test("calibration is excluded and short timed rounds restart at a larger fixed batch")
    func calibrationAndRetryAreNotReported() {
        var calls: [Int] = []
        var durations = [40, 120, 90, 110, 100, 220, 210, 200].makeIterator()

        let measurements = measureDurationStableFeed(
            iterations: 3,
            targetNanoseconds: 100,
            measureBatch: { batchCount in
                calls.append(batchCount)
                return UInt64(durations.next()!)
            }
        )

        #expect(calls == [1, 3, 3, 3, 3, 4, 4, 4])
        #expect(measurements.batchCount == 4)
        #expect(measurements.sampleDurationNanoseconds == [220, 210, 200])
        #expect(measurements.feedDurationNanoseconds == [55, 52, 50])
        #expect(measurements.sampleDurationNanoseconds.allSatisfy { $0 >= 100 })
    }

    @Test("framing preserves committed fixture chunk boundaries and their phases")
    func framingPreservesChunksAndPhases() throws {
        let framed =
            frameForTest(.setup, "s")
            + frameForTest(.timed, "abc")
            + frameForTest(.timed, "de")
            + frameForTest(.teardown, "t")

        let fixture = try decodeBenchmarkFixture(framed)

        #expect(fixture.setup == [Array("s".utf8)])
        #expect(fixture.timed == [Array("abc".utf8), Array("de".utf8)])
        #expect(fixture.teardown == [Array("t".utf8)])
    }

    @Test("only the timed phase is charged to the reported duration")
    func setupAndTeardownAreOutsideTheClock() {
        // Intent: a fixture that carries setup and teardown reports the timed span alone.
        // Why it exists: the kitten arms wrap their payload in an alt-screen enter and a
        //   RIS teardown, and kitten's own timer excludes both. If the harness charged
        //   them, a change that only sped up teardown could win a verdict on a stimulus
        //   whose reference measurement never saw it.
        var fed: [String] = []
        var clock = [UInt64](arrayLiteral: 100, 140).makeIterator()

        let duration = measureFeedBatch(
            fixture: CoreBenchmarkFixture(
                setup: [Array("setup".utf8)],
                timed: [Array("timed".utf8)],
                teardown: [Array("teardown".utf8)]
            ),
            executionCount: 1,
            makeTerminal: {
                fed.append("fresh")
                return Terminal(columns: 80, rows: 24)
            },
            now: { clock.next()! }
        )

        #expect(duration == 40)
        #expect(fed == ["fresh"])
    }

    @Test("an unknown phase byte is a named framing error")
    func unknownPhaseIsNamed() {
        // Intent: a frame tagged with a phase the harness does not define throws rather
        //   than silently landing in one of the three buckets.
        // Why it exists: the phase byte decides what is inside the clock, so a producer
        //   that writes a phase this harness does not know must stop the run, not have
        //   its bytes quietly timed.
        var framed = Data([9])
        var length = UInt64(1).bigEndian
        framed.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
        framed.append(Data("a".utf8))

        #expect(throws: CoreBenchmarkError.unknownPhase(9)) {
            _ = try decodeBenchmarkFixture(framed)
        }
    }

    @Test("a length prefix with fewer than eight bytes left is a named framing error")
    func truncatedLengthPrefixIsNamed() {
        // Intent: stdin that ends mid-length-prefix throws `.truncatedLength`.
        // Why it exists: this is the deserialization boundary two shipped executables
        //   `try` on stdin (TerminalCoreBenchmark, TerminalRetainedRowProbe), and the
        //   guard is what stands between a half-written fixture and an index-out-of-range
        //   trap. Nothing exercised either framing error before, so both crash defenses
        //   were load-bearing and unproven.
        #expect(throws: CoreBenchmarkError.truncatedLength) {
            _ = try decodeBenchmarkFixture(Data([1, 0, 0, 0, 1]))
        }
    }

    @Test("a chunk length longer than the remaining bytes is a named framing error")
    func truncatedChunkIsNamed() {
        // Intent: a well-formed prefix declaring more payload than the data holds throws
        //   `.truncatedChunk` rather than trapping on the slice.
        // Why it exists: same boundary as `truncatedLengthPrefixIsNamed`, and this is the
        //   half a truncated write actually produces -- the length lands, the payload
        //   does not.
        var framed = Data([CoreBenchmarkPhase.timed.rawValue])
        var length = UInt64(99).bigEndian
        framed.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
        framed.append(Data([0x61, 0x62]))

        #expect(throws: CoreBenchmarkError.truncatedChunk) {
            _ = try decodeBenchmarkFixture(framed)
        }
    }

    @Test("a bounded sustained feed re-enters its feed boundary once per cycle")
    func sustainedFeedReentersItsBoundaryEachCycle() {
        // Intent: `runSustainedFeed(maximumCycles:)` invokes the supplied boundary
        //   closure exactly once per cycle and stops at the bound.
        // Why it exists: the title previously claimed the measured *terminal* is
        //   recreated each cycle, which this body cannot check -- `runSustainedFeed`
        //   never touches a `Terminal`. That claim belongs to `measureFeedBatch` and is
        //   pinned by `feedBatchCreatesFreshTerminalPerExecution`. What is verifiable
        //   here is that the caller's boundary (in production, one `measureFeedBatch`
        //   call) is entered once per cycle, which is what `batches == 3` asserts.
        var batches = 0

        let completed = runSustainedFeed(maximumCycles: 3) {
            batches += 1
        }

        #expect(completed == 3)
        #expect(batches == 3)
    }

    /// Builds one frame the way the Python producers do, so the tests state the encoding
    /// rather than reusing the decoder's own view of it.
    private func frameForTest(_ phase: CoreBenchmarkPhase, _ text: String) -> Data {
        var framed = Data([phase.rawValue])
        var length = UInt64(text.utf8.count).bigEndian
        framed.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
        framed.append(Data(text.utf8))
        return framed
    }
}
