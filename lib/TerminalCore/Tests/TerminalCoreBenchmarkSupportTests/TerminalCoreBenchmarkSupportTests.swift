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
            chunks: [Array("x".utf8)],
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

    @Test("length framing preserves committed fixture chunk boundaries")
    func lengthFramingPreservesChunks() throws {
        var framed = Data()
        for chunk in [Data("abc".utf8), Data("de".utf8)] {
            var length = UInt64(chunk.count).bigEndian
            framed.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
            framed.append(chunk)
        }

        #expect(try decodeBenchmarkChunks(framed) == [Array("abc".utf8), Array("de".utf8)])
    }
}
