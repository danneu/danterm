// Proofs for the occupancy probe's corpus and its summary arithmetic -- the two parts of
// the probe that can be wrong without being obviously wrong. Timing itself is deliberately
// untested: a wall-clock bracket has no assertable value, which is exactly why everything
// around it has to be.
import Testing

// `@testable` for the budget-taking `Terminal` initializer, which is internal on purpose: the
// public one pins production's 16 MiB. `saturationReachesDepth` needs a small budget to watch
// eviction happen without paying for a production-sized history.
@testable import TerminalCore
@testable import TerminalOccupancyProbeSupport

/// Guards the corpus against silently drifting away from the stimulus doc 19 measured.
struct OccupancyCorpusTests {
    @Test("incremental needle entry reports one summed sample per iteration")
    func incrementalNeedleSamples() throws {
        let iterations = 2
        let report = runOccupancyProbe(columns: 20, rows: 5, lines: 20, iterations: iterations)
        let sample = try #require(report.samples.first {
            $0.name == OccupancyCase.searchIncrementalNeedle.rawValue
        })

        #expect(sample.iterations == iterations)
    }

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
        //   representative of. `research/19/F6` reads a flat per-cell constant; that reading is
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

    @Test("the shipped depth charges past the budget, and an evicting history keeps matches")
    func saturationReachesDepth() throws {
        // Intent: two things, one arithmetic and one observed. The shipped default depth,
        //   fed at the shipped geometry, charges several times the arena the production
        //   budget admits -- so it must evict long before the feed ends. And a history
        //   that has actually evicted still holds the corpus's needles, so the probe's
        //   search cases have something to find at depth.
        // Why it exists: the probe's headline numbers are all "at a saturated history".
        //   If the feed were too short, every case would report the shallow-history cost
        //   under a saturated label -- a wrong number that still looks reasonable. Two
        //   earlier forms of this test failed to check that. The first asserted
        //   `scrollbackRowCount > 0` at 4,000 lines; the second fed all 30,000 and
        //   asserted `scrollbackRowCount < 30_000`, which the 66-row viewport satisfies
        //   whether or not a single row is ever evicted -- the exact defect it was written
        //   to fix. Neither could fail if the depth stopped saturating.
        // Scenario: someone edits the corpus's line widths, or trims `lines` to make the
        //   probe start faster, and doc 19's numbers silently become shallow-history
        //   numbers under the same labels.

        // A prefix, not the shipped depth: the corpus's per-line charge is deterministic,
        // so the budget question is arithmetic once the charge is measured, and measuring
        // it costs a fifteenth of feeding all 30,000 lines.
        let prefixLineCount = 2_048
        var terminal = makeOccupancyTerminal(
            columns: OccupancyProbeDefaults.columns,
            rows: OccupancyProbeDefaults.rows,
            lines: prefixLineCount
        )

        // The prefix itself must not have evicted, or the charge it reports is a budget
        // ceiling rather than the corpus's own rate. The first line's needle still being
        // findable is that statement: nothing has fallen off the front.
        let prefixHoldsOldestNeedle = terminal.beginSearch("NEEDLE_0")
        #expect(prefixHoldsOldestNeedle)
        let census = terminal.memoryCensus
        #expect(census.hasRetainedStorageOverdraft == false)

        let chargePerLine = Double(census.retainedChargedBytes) / Double(prefixLineCount)
        let projectedCharge = chargePerLine * Double(OccupancyProbeDefaults.lines)
        // 1.5x, against a measured ~3.0x (~1,563 B/line x 30,000 = ~46.9 MB versus the
        // 16 MiB budget's 15,728,640-byte arena). The prefix understates the full run --
        // per-line charge creeps upward with depth as the index and side tables amortize
        // (~1,463 B/line at 512 lines, ~1,563 at 2,048) -- so this is a conservative floor
        // that still fails long before the depth could stop saturating by accident.
        #expect(projectedCharge >= Double(census.retainedArenaCapacityBytes) * 1.5)

        // The observed half, at an injected budget rather than the production one: the same
        // corpus, fed past a capacity it exceeds, really does evict, and search still finds
        // needles in what survives. `Terminal`'s budget-taking initializer is internal, which
        // is why this file reaches for `@testable`; at the production budget the identical
        // observation would cost the 30,000-line feed this test exists to avoid.
        let anchorBudgetBytes = 1 << 19
        var evicted = try #require(Terminal(
            columns: OccupancyProbeDefaults.columns,
            rows: OccupancyProbeDefaults.rows,
            scrollbackBudgetBytes: anchorBudgetBytes
        ))
        feedOccupancyCorpus(into: &evicted, from: 0, count: 1_024)

        // The oldest needle is gone -- that is eviction, and unlike a row count it cannot be
        // satisfied by rows sitting in the viewport.
        let evictedStillHoldsOldestNeedle = evicted.beginSearch("NEEDLE_0")
        #expect(evictedStillHoldsOldestNeedle == false)
        let evictedHoldsSomeNeedle = evicted.beginSearch("NEEDLE_")
        #expect(evictedHoldsSomeNeedle)
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
        // Why it exists: `research/19/F11`'s whole argument is a comparison between service rate
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
        //   (`research/19/D3`: 99.3 ms -> ~0.00 ms), so the degenerate case is the success case
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
