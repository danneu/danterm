// The wall-clock arm of the bounded-tail-read cost claim, kept out of the `just test` gate.
//
// `TerminalHistoryTailTests.tailReadCostTracksTheBudgetNotTheCapacity` owns the contract and
// asserts it deterministically, in display rows walked. That is the right shape for a gate: rows
// are exactly what the bound bounds, and they do not move when the test pool is busy. But rows
// are a proxy for the thing anyone actually cares about -- seconds on a checkpoint -- and a
// change that kept the row count while making each row far more expensive would pass the gate.
// This probe is where that gets checked, by hand, against a real clock.
//
// It is env-gated because a wall-clock ratio cannot be made reliable inside a parallel pool: the
// gate form failed twice at ratio 5.0 against a 4x bound (0.244s vs 0.196s) and passed every
// isolated rerun. Run it deliberately, on an idle machine:
//
//     DANTERM_HISTORY_TAIL_PROBE=1 swift test --package-path lib/TerminalCore \
//         --filter TerminalHistoryTailCostProbe
//
// It prints; it asserts nothing about the numbers. Reading them is a person's job.
import Foundation
import Testing

@testable import TerminalCore

/// Times the bounded tail read against the whole projection over two history depths.
///
/// Serialized and env-gated: it is a measurement, and a measurement taken beside 970 other tests
/// is not one.
@Suite(.serialized)
struct TerminalHistoryTailCostProbe {
    static let probeIsEnabled =
        ProcessInfo.processInfo.environment["DANTERM_HISTORY_TAIL_PROBE"] != nil

    @Test("tail-read wall clock against history depth", .enabled(if: probeIsEnabled))
    func tailReadWallClock() throws {
        func seconds(_ body: () -> Void) -> Double {
            let start = ContinuousClock.now
            body()
            let elapsed = (ContinuousClock.now - start).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }

        // Interleaved arms and a minimum over rounds, which is what makes two timings
        // comparable at all: noise is one-sided, so the minimum is the closest estimate of the
        // real cost, and interleaving puts any load spike on both arms rather than one.
        // See agent-docs/measurement-discipline.md.
        let small = try historyProjectionTerminal(lines: 400)
        let large = try historyProjectionTerminal(lines: 3_200)
        var smallTail = Double.infinity
        var largeTail = Double.infinity
        var smallFull = Double.infinity
        var largeFull = Double.infinity
        for round in 0..<6 {
            let s = seconds { _ = small.primaryHistoryTailText(maxLines: 200, maxChars: 20_000) }
            let l = seconds { _ = large.primaryHistoryTailText(maxLines: 200, maxChars: 20_000) }
            let sf = seconds { _ = small.primaryHistoryText }
            let lf = seconds { _ = large.primaryHistoryText }
            guard round > 0 else { continue }  // discard the warm-up round
            smallTail = min(smallTail, s)
            largeTail = min(largeTail, l)
            smallFull = min(smallFull, sf)
            largeFull = min(largeFull, lf)
        }

        print("history-tail cost probe (min of 5 rounds, seconds)")
        print("  tail  400 lines: \(smallTail)")
        print("  tail 3200 lines: \(largeTail)   ratio \(largeTail / smallTail)")
        print("  full  400 lines: \(smallFull)")
        print("  full 3200 lines: \(largeFull)   ratio \(largeFull / smallFull)")
        print("  tail rows walked: \(Instrument.projectionRow.measure { _ = large.primaryHistoryTailText(maxLines: 200, maxChars: 20_000) })")
        print("  full rows walked: \(Instrument.projectionRow.measure { _ = large.primaryHistoryText })")
    }
}
