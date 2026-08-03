// Behavioral tests for the saturated-history resize probe.
//
// These pin the two properties that make the probe worth committing: it really
// resizes a budget-saturated history (otherwise it measures a cheap operation on
// a shallow one), and it reports a distribution rather than a point estimate
// (which is what `28/D1` pitch 2 required of the frozen recipe). No duration is
// asserted anywhere -- the probe is descriptive by decision, and a unit test
// that asserted a time would invent the frame-budget verdict `D1` withheld.
import Testing
import TerminalCore
@testable import TerminalResizeProbeSupport

@Suite("Saturated-history resize probe")
struct TerminalResizeProbeSupportTests {
    @Test("The probe terminal is saturated against the budget, not merely deep")
    func probeTerminalIsBudgetSaturated() {
        // Intent: after setup, the retained history has been evicted down to the
        //   budget -- fewer rows survive than were fed.
        // Why it exists: this is the whole premise of the probe. If the payload
        //   ever shrank below the budget, every sample would still be collected
        //   and the distribution would still print, but it would describe
        //   resizing a small history and nobody reading the report could tell.
        let recipe = ResizeProbeRecipe.standard
        let terminal = makeSaturatedTerminal(recipe: recipe)

        #expect(terminal.scrollbackRowCount > 0)
        #expect(terminal.scrollbackRowCount < recipe.lineCount)
    }

    @Test("The probe alternates widths, so no sample times a no-op resize")
    func probeAlternatesWidths() {
        // Intent: consecutive timed resizes target different widths, and the run
        //   ends at one of the recipe's two widths.
        // Why it exists: resizing to the width a terminal already has is free.
        //   A probe that did that would report a distribution of near-zeros that
        //   looks like a fast resize rather than an absent one.
        let recipe = ResizeProbeRecipe(
            columns: 179, rows: 8, lineCount: 400,
            scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
            alternateColumns: 100, sampleCount: 4, warmupCount: 0
        )
        var widths: [Int] = []
        var terminal = makeSaturatedTerminal(recipe: recipe)
        for index in 0..<recipe.sampleCount {
            let width = index % 2 == 0 ? recipe.alternateColumns : recipe.columns
            terminal.resize(columns: width, rows: recipe.rows)
            // Width is read through the observable boundary rather than a stored
            // property: `columnCount` is private, and the last readable column is
            // the same fact stated in the terms a caller actually has.
            widths.append(
                terminal.cell(row: 0, column: recipe.columns - 1) == nil
                    ? recipe.alternateColumns
                    : recipe.columns
            )
        }

        #expect(widths == [100, 179, 100, 179])
    }

    @Test("The report carries the recipe that produced it")
    func reportCarriesItsRecipe() {
        // Intent: geometry, budget, row count, and repeat count travel with the
        //   distribution.
        // Why it exists: `28/D1` pitch 2 made this a condition of freezing the
        //   recipe at all, because `15/F18`'s deleted probe left behind numbers
        //   whose conditions had to be reconstructed from prose.
        let recipe = ResizeProbeRecipe(
            columns: 120, rows: 8, lineCount: 300,
            scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
            alternateColumns: 60, sampleCount: 2, warmupCount: 1
        )
        let report = measureSaturatedResize(recipe: recipe)

        #expect(report.recipeIdentity == recipe.identity)
        #expect(report.columns == 120)
        #expect(report.rows == 8)
        #expect(report.lineCount == 300)
        #expect(report.alternateColumns == 60)
        #expect(report.warmupCount == 1)
        #expect(report.scrollbackBudgetBytes == Terminal.productionScrollbackBudgetBytes)
        #expect(report.retainedRowCountAtStart > 0)
        #expect(report.distribution.sampleCount == 2)
        #expect(report.distribution.samplesNanoseconds.count == 2)
    }

    @Test("The distribution reports order statistics over the raw samples it keeps")
    func distributionReportsOrderStatistics() {
        // Intent: quantiles are nearest-rank over the sorted samples, and every
        //   raw sample survives in collection order.
        // Why it exists: an interpolated tail quantile over a few dozen samples
        //   reports a duration that never occurred, and a summary that discarded
        //   its samples cannot be re-reduced later -- `20/F12` had to recover
        //   exactly such samples by hand from per-block artifacts.
        let distribution = ResizeProbeDistribution(
            samplesNanoseconds: [50, 10, 30, 20, 40]
        )

        #expect(distribution.sampleCount == 5)
        #expect(distribution.minimumNanoseconds == 10)
        #expect(distribution.maximumNanoseconds == 50)
        #expect(distribution.medianNanoseconds == 30)
        #expect(distribution.p90Nanoseconds == 50)
        #expect(distribution.p99Nanoseconds == 50)
        #expect(distribution.meanNanoseconds == 30)
        #expect(distribution.samplesNanoseconds == [50, 10, 30, 20, 40])
    }

    @Test("An empty sample set reports zero samples rather than a zero duration")
    func emptySampleSetIsDistinctFromAFastResize() {
        // Intent: with no samples, `sampleCount` is 0 and the reader can tell.
        // Why it exists: the measurement-discipline rule this doc binds itself to
        //   requires "not measured" to be a state distinct from "measured fast".
        //   A zero median with no count beside it reads as an instant resize.
        let distribution = ResizeProbeDistribution(samplesNanoseconds: [])

        #expect(distribution.sampleCount == 0)
        #expect(distribution.medianNanoseconds == 0)
        #expect(distribution.samplesNanoseconds.isEmpty)
    }
}
