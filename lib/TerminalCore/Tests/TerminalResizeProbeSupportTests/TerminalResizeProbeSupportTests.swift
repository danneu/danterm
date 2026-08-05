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

    @Test("The saturating recipe fills the budget: feeding more lines buys no more rows")
    func saturatingRecipeReachesTheBudgetCeiling() {
        // Intent: `.saturating`'s line count is enough that retained depth is
        //   decided by the byte budget rather than by how many lines were fed --
        //   feeding a further screenful adds no retained row.
        // Why it exists: `.standard`'s 10,000 lines saturated the pre-packing
        //   representation (6,756 rows) but stopped saturating once retained rows
        //   were packed, which made a resize sample cover 1.47x depth rather than
        //   the ~14x the budget now admits. A recipe that quietly stops saturating
        //   still prints a distribution, and nobody reading it can tell -- so the
        //   ceiling is asserted by the observable it actually claims.
        let recipe = ResizeProbeRecipe.saturating
        var terminal = makeSaturatedTerminal(recipe: recipe)
        let atCeiling = terminal.scrollbackRowCount

        // The recipe's own payload, for the reason spelled out in
        // `sparseRecipeReachesTheBudgetCeiling`: a denser overfeed evicts more than it
        // admits under a content-denominated bound, and the count falls.
        for line in recipe.lineCount..<(recipe.lineCount + 200) {
            terminal.feed(Array("\(recipe.payload.line(line))\r\n".utf8))
        }

        #expect(atCeiling > 0)
        #expect(atCeiling < recipe.lineCount)
        // A band rather than an equality or a one-sided bound since doc 31: the bound is charged
        // bytes, and where the equilibrium settles inside a row is phase-dependent -- a trimmed
        // head frees a display row without freeing a whole line's charge, and the ring's
        // chunk-seam pads (`31/DD14`) move with the write cursor -- so an overfeed at the ceiling
        // lands a few rows either side of where the fill left it. What the recipe claims -- that
        // feeding 200 more lines buys no more depth -- is the direction, not the exact figure,
        // and a couple of rows against 200 fed is that claim holding, in either direction.
        #expect(terminal.scrollbackRowCount < atCeiling + 100)
        #expect(terminal.scrollbackRowCount > atCeiling - 100)
    }

    @Test("The sparse recipe's rows are a fraction of the dense recipe's width")
    func sparsePayloadIsShorterThanDense() {
        // Intent: `.sparse` emits short shell-history-shaped lines, where `.dense`
        //   emits the ~50-column line `saturated-resize-v1` and `v2` both feed.
        // Why it exists: the sparse recipe exists to measure the content regime
        //   where a *content-sized* row representation retains its deepest history
        //   -- `alacritty/history` priced at 186.3 B/row and 56,273 rows at 10 MiB
        //   against the dense payload's 6,756. If this payload ever drifted long,
        //   the recipe would keep saturating and keep printing a distribution while
        //   silently measuring the dense regime a second time.
        // Scenario: the corpus recording this payload stands in for is a shell
        //   history -- `ls`, `cd ..`, `git status` -- not program output.
        let sparse = (0..<64).map { ResizeProbePayload.sparse.line($0).count }
        let dense = (0..<64).map { ResizeProbePayload.dense.line($0).count }
        let meanSparse = Double(sparse.reduce(0, +)) / 64.0
        let meanDense = Double(dense.reduce(0, +)) / 64.0

        #expect(meanSparse < meanDense / 4.0)
        #expect(sparse.allSatisfy { $0 > 0 })
    }

    @Test("The sparse recipe fills the budget: feeding more lines buys no more rows")
    func sparseRecipeReachesTheBudgetCeiling() {
        // Intent: `.sparseSaturating`'s line count is enough that retained depth is
        //   decided by the byte budget rather than by how many lines were fed.
        // Why it exists: same hazard `saturatingRecipeReachesTheBudgetCeiling`
        //   guards, and sharper here -- sparse rows are the cheapest content in the
        //   corpus, so this recipe needs the most lines of any of the three to reach
        //   the ceiling, and it is the one most likely to stop saturating when a
        //   future representation makes a row cheaper again.
        let recipe = ResizeProbeRecipe.sparseSaturating
        var terminal = makeSaturatedTerminal(recipe: recipe)
        let atCeiling = terminal.scrollbackRowCount

        // Overfed with the recipe's *own* payload, not a longer marker line. A
        // denser overfeed evicts more cheap rows than it admits and the count
        // falls, which reads as a failure while actually confirming saturation.
        for line in recipe.lineCount..<(recipe.lineCount + 200) {
            terminal.feed(Array("\(recipe.payload.line(line))\r\n".utf8))
        }

        #expect(atCeiling > 0)
        #expect(atCeiling < recipe.lineCount)
        // A band rather than an equality or a one-sided bound since doc 31: the bound is charged
        // bytes, and where the equilibrium settles inside a row is phase-dependent -- a trimmed
        // head frees a display row without freeing a whole line's charge, and the ring's
        // chunk-seam pads (`31/DD14`) move with the write cursor -- so an overfeed at the ceiling
        // lands a few rows either side of where the fill left it. What the recipe claims -- that
        // feeding 200 more lines buys no more depth -- is the direction, not the exact figure,
        // and a couple of rows against 200 fed is that claim holding, in either direction.
        #expect(terminal.scrollbackRowCount < atCeiling + 100)
        #expect(terminal.scrollbackRowCount > atCeiling - 100)
    }

    @Test("The wide payload fills the standard recipe's width exactly")
    func widePayloadFillsTheStandardWidth() {
        // Intent: `.wide` emits a line exactly as long as the recipe's 179 columns.
        // Why it exists: this recipe exists to maximize retained *cells*, which is
        //   the term a row cap does not bound. A payload one character short still
        //   saturates and still prints a distribution; a payload one character long
        //   soft-wraps every line into a second, nearly empty row and halves the
        //   cells per row. Either drift measures a different regime silently.
        #expect(ResizeProbePayload.wide.line(0).count == 179)
        #expect(ResizeProbePayload.wide.line(7).count == 179)
        #expect(ResizeProbeRecipe.wideSaturating.columns == 179)
    }

    @Test("The wide recipe fills the budget: feeding more lines buys no more rows")
    func wideRecipeReachesTheBudgetCeiling() {
        // Intent: `.wideSaturating`'s line count reaches the byte budget.
        // Why it exists: the same premise the other two ceiling tests pin. Wide rows
        //   are the most expensive content in the corpus, so this recipe needs the
        //   fewest lines -- and is the one most likely to be left saturating by line
        //   count if its budget-reaching depth is ever misjudged.
        let recipe = ResizeProbeRecipe.wideSaturating
        var terminal = makeSaturatedTerminal(recipe: recipe)
        let atCeiling = terminal.scrollbackRowCount

        for line in recipe.lineCount..<(recipe.lineCount + 200) {
            terminal.feed(Array("\(recipe.payload.line(line))\r\n".utf8))
        }

        #expect(atCeiling > 0)
        #expect(atCeiling < recipe.lineCount)
        // A band rather than an equality or a one-sided bound since doc 31: the bound is charged
        // bytes, and where the equilibrium settles inside a row is phase-dependent -- a trimmed
        // head frees a display row without freeing a whole line's charge, and the ring's
        // chunk-seam pads (`31/DD14`) move with the write cursor -- so an overfeed at the ceiling
        // lands a few rows either side of where the fill left it. What the recipe claims -- that
        // feeding 200 more lines buys no more depth -- is the direction, not the exact figure,
        // and a couple of rows against 200 fed is that claim holding, in either direction.
        #expect(terminal.scrollbackRowCount < atCeiling + 100)
        #expect(terminal.scrollbackRowCount > atCeiling - 100)
    }

    @Test("A recipe's identity names its version, so v2's numbers cannot be read as v1's")
    func recipeIdentityNamesItsVersion() {
        // Intent: the two frozen recipes carry distinct, self-describing identities.
        // Why it exists: the saturating recipe changes what a sample covers by an
        //   order of magnitude. Redefining `saturated-resize-v1` in place would
        //   make `F7`'s recorded distribution and this one look comparable.
        #expect(ResizeProbeRecipe.standard.identity.hasPrefix("saturated-resize-v1-"))
        #expect(ResizeProbeRecipe.saturating.identity.hasPrefix("saturated-resize-v2-"))
        #expect(
            ResizeProbeRecipe.sparseSaturating.identity
                .hasPrefix("saturated-sparse-resize-v1-")
        )
        #expect(
            ResizeProbeRecipe.wideSaturating.identity
                .hasPrefix("saturated-wide-resize-v1-")
        )
        let identities = Set(
            [ResizeProbeRecipe.standard, .saturating, .sparseSaturating, .wideSaturating]
                .map(\.identity)
        )
        #expect(identities.count == 4)
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
