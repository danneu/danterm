// Proofs for the occupancy probe's corpus and its summary arithmetic -- the two parts of
// the probe that can be wrong without being obviously wrong. Timing itself is deliberately
// untested: a wall-clock bracket has no assertable value, which is exactly why everything
// around it has to be.
import Testing
import TerminalCore

@testable import TerminalOccupancyProbeSupport

/// Guards the corpus against silently drifting away from the stimulus doc 19 measured.
struct OccupancyCorpusTests {
    @Test("the corpus places a needle at the documented cadence and nowhere else")
    func needleCadence() {
        // Intent: NEEDLE_ appears on exactly every 97th line, so a search has matches to
        //   step through without every row matching.
        // Why it exists: the match count is the probe's independent variable -- a corpus
        //   that accidentally matched every line would price a different job and still
        //   report plausible milliseconds. Doc 19's numbers are only comparable across
        //   revisions if this cadence is fixed.
        let lines = (0..<200).map(occupancyCorpusLine)
        let matching = lines.indices.filter { lines[$0].contains("NEEDLE_") }

        #expect(matching == [0, 97, 194])
    }

    @Test("the corpus varies line width so the scan is not measuring one row shape")
    func widthVariation() {
        // Intent: consecutive lines differ in length, cycling rather than staying flat.
        // Why it exists: a fixed-width corpus makes every row's projected-cell end
        //   identical, which is the one shape a scan is least likely to be
        //   representative of. `19/F6` reads a flat per-cell constant; that reading is
        //   only meaningful if the rows were not uniform to begin with.
        let widths = (0..<8).map { occupancyCorpusLine($0).count }

        #expect(Set(widths).count > 1)
        // The cycle repeats every 7 lines. Compared at 1 and 8 rather than 0 and 7 because
        // line 0 also carries a needle, which is the one index where both variables move.
        #expect(occupancyCorpusLine(1).count == occupancyCorpusLine(8).count)
    }

    @Test("the corpus is deterministic across calls")
    func determinism() {
        // Intent: the same index always produces the same line.
        // Why it exists: two probe runs compared against each other must have fed the
        //   same bytes. Nothing here reads a clock or a random source today, and this
        //   fails the moment something does.
        #expect(occupancyCorpusLine(42) == occupancyCorpusLine(42))
        #expect(occupancyCorpusLine(42) != occupancyCorpusLine(43))
    }

    @Test("a saturated terminal reaches history depth and retains matches")
    func saturationReachesDepth() {
        // Intent: the corpus actually fills scrollback and leaves searchable matches.
        // Why it exists: the probe's headline numbers are all "at a saturated history".
        //   If the feed were too short, every case would report the shallow-history cost
        //   under a saturated label -- a wrong number that still looks reasonable.
        var terminal = makeOccupancyTerminal(columns: 80, rows: 24, lines: 4_000)

        #expect(terminal.scrollbackRowCount > 0)
        let found = terminal.beginSearch("NEEDLE_")
        #expect(found)
    }
}

/// Guards the summary arithmetic the report prints, which no reader can check by eye.
struct OccupancySummaryTests {
    @Test("a summary reports the mean, extremes, and count of its samples")
    func summaryArithmetic() {
        let summary = OccupancySample(name: "case", milliseconds: [2.0, 4.0, 6.0])

        #expect(summary.iterations == 3)
        #expect(summary.meanMilliseconds == 4.0)
        #expect(summary.minMilliseconds == 2.0)
        #expect(summary.maxMilliseconds == 6.0)
    }

    @Test("a summary converts its mean into the sustainable rate a key repeat is judged against")
    func sustainableRate() {
        // Intent: mean milliseconds becomes operations per second.
        // Why it exists: `19/F11`'s whole argument is a comparison between service rate
        //   and macOS key-repeat arrival rate, so the probe reports the rate rather than
        //   leaving each reader to divide -- and a reciprocal is easy to invert by
        //   accident in a way no one notices in a table.
        let summary = OccupancySample(name: "case", milliseconds: [50.0, 50.0])

        #expect(summary.operationsPerSecond == 20.0)
    }

    @Test("a summary of an instantaneous case reports no rate rather than infinity")
    func degenerateRate() {
        // Intent: a mean of zero yields nil, not a division by zero.
        // Why it exists: this is now the expected reading for cached navigation
        //   (`19/D3`: 99.3 ms -> ~0.00 ms), so the degenerate case is the success case
        //   and must not print `inf`.
        let summary = OccupancySample(name: "case", milliseconds: [0.0, 0.0])

        #expect(summary.operationsPerSecond == nil)
    }

    @Test("a summary below the timing floor reports no rate rather than a huge one")
    func subResolutionRate() {
        // Intent: a mean too small to have been measured meaningfully yields nil.
        // Why it exists: a bracket around a cache hit reads a few hundred nanoseconds,
        //   and dividing that into 1000 produces a confident-looking "3.8 million per
        //   second". That number is the timer's noise floor, not a throughput, and
        //   printing it next to a real key-repeat rate invites a comparison that means
        //   nothing. Nil forces the caller to say so in words instead.
        let summary = OccupancySample(name: "case", milliseconds: [0.0004, 0.0006])

        #expect(summary.operationsPerSecond == nil)
    }

    @Test("a summary just above the timing floor still reports a rate")
    func aboveResolutionRate() {
        // Pins the floor as a floor rather than an open-ended "small means nil": a job
        // costing a hundredth of a millisecond is slow enough to divide.
        let summary = OccupancySample(name: "case", milliseconds: [0.02, 0.02])

        #expect(summary.operationsPerSecond == 50_000)
    }
}
