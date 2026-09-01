// Behavioral tests for the saturated-history resize probe.
//
// These pin the two properties that make the probe worth committing: each recipe
// still covers the depth regime it claims -- the `v2` recipes budget-saturated,
// `v1` deliberately line-bounded below the budget, so a reader is never handed a
// cheap operation on a shallow history under a saturated label -- and it reports
// a distribution rather than a point estimate
// (which is what `research/28/D1` pitch 2 required of the frozen recipe). No duration is
// asserted anywhere -- the probe is descriptive by decision, and a unit test
// that asserted a time would invent the frame-budget verdict `D1` withheld.
import Foundation
import Testing
import TerminalCore
import TerminalProbeArguments
@testable import TerminalResizeProbeSupport

@Suite("Saturated-history resize probe")
struct TerminalResizeProbeSupportTests {
    /// Evidence that a bounded recipe prefix forced retained-history eviction.
    private struct SaturationEvidence {
        var terminal: Terminal
        let linesFed: Int
    }

    @Test("The v1 recipe retains every line it feeds and stays below the budget")
    func standardRecipeIsLineBoundedNotBudgetBounded() {
        // Intent: `.standard` evicts nothing -- its retained depth is decided by
        //   `lineCount`, and its whole run's charge sits well under the budget the
        //   arena admits.
        // Why it exists: `.standard` is the frozen v1 recipe the probe binary still
        //   ships as its default, and every other test in this file reads it as "the
        //   non-saturating one" -- `saturatingRecipesChargePastTheBudgetCeiling` names
        //   it as such to justify its own absence from that argument list. That premise
        //   was never actually asserted: the assertion this replaced claimed
        //   saturation and tested `scrollbackRowCount < lineCount`, which the
        //   viewport's own rows satisfy whether or not a single line is ever evicted.
        //   If the payload or the geometry drifted until v1 did saturate, `v1` and
        //   `v2` would stop being two different regimes and `research/28/F7`'s recorded
        //   distribution would quietly change meaning.
        let recipe = ResizeProbeRecipe.standard
        // A prefix, not the whole recipe: per-line charge is deterministic for a
        // fixed-width payload, so the budget question is arithmetic once the charge
        // is measured, and measuring it costs a fifth of feeding all 10,000 lines.
        let prefixLineCount = 2_048
        var terminal = Terminal(columns: recipe.columns, rows: recipe.rows)!
        terminal.feed(recipeBytes(for: recipe, in: 0..<prefixLineCount))

        // Exact, not a lower bound: everything fed is retained except the rows still
        // in the viewport, which is the statement "nothing was evicted" -- and it
        // also pins that a payload line is one retained row, so a payload or width
        // that started soft-wrapping would fail here rather than silently halve the
        // cells the recipe retains per row.
        #expect(terminal.scrollbackRowCount == prefixLineCount - (recipe.rows - 1))

        let census = terminal.memoryCensus
        #expect(census.hasRetainedStorageOverdraft == false)
        let chargePerLine = Double(census.retainedChargedBytes) / Double(prefixLineCount)
        let projectedCharge = chargePerLine * Double(recipe.lineCount)
        // 1.25x because per-line charge creeps upward with depth as the index and
        // side tables amortize (~373 B/line at this prefix, ~388 B/line at 10,000),
        // so the prefix slightly understates the full run. The real headroom is ~4x;
        // this fails long before a recipe edit could make v1 saturate by accident.
        #expect(projectedCharge * 1.25 < Double(census.retainedArenaCapacityBytes))
    }

    @Test(
        "Each saturating recipe's shipped line count charges past the arena it fills",
        arguments: [
            ResizeProbeRecipe.saturating,
            ResizeProbeRecipe.sparseSaturating,
            ResizeProbeRecipe.wideSaturating,
        ]
    )
    func saturatingRecipesChargePastTheBudgetCeiling(recipe: ResizeProbeRecipe) {
        // Intent: for each saturating recipe, the depth at which its own payload's
        //   charge fills the production arena is at or before the `lineCount` it
        //   ships -- so the recipe reaches the budget ceiling rather than stopping
        //   at its line bound.
        // Why it exists: a recipe that quietly stops saturating still prints a full
        //   distribution, and nobody reading the report can tell it now describes
        //   resizing a shallow history. Each recipe carries its own version of that
        //   hazard:
        //   - `.saturating`: `.standard`'s 10,000 lines saturated the pre-packing
        //     representation (6,756 rows) but stopped saturating once retained rows
        //     were packed, which made a resize sample cover 1.47x depth rather than
        //     the ~14x the budget now admits. That regression is what this recipe
        //     exists to have caught.
        //   - `.sparseSaturating`: sparse rows are the cheapest content in the
        //     corpus, so this recipe needs the most lines of the three to reach the
        //     ceiling, and it is the one most likely to stop saturating when a
        //     future representation makes a row cheaper again.
        //   - `.wideSaturating`: wide rows are the most expensive content, so this
        //     recipe needs the fewest lines -- and is the one most likely to be left
        //     saturating by line count if its budget-reaching depth is misjudged.
        // `.standard` is deliberately absent: it is the non-saturating v1 recipe,
        // covered by `standardRecipeIsLineBoundedNotBudgetBounded` instead.
        //
        // Arithmetic rather than observation, because observing the ceiling costs
        // ~301,000 line feeds across the three recipes. Each payload is a fixed shape,
        // so per-line charge is deterministic and the saturation depth is a division;
        // `wideSaturatingRecipeEvictsWithinItsBound` keeps the cheapest of the three on
        // the observed path so this division stays tied to a measured eviction.
        let prefixLineCount = Self.chargeMeasurementPrefixLineCount(for: recipe)
        var terminal = Terminal(columns: recipe.columns, rows: recipe.rows)!
        terminal.feed(recipeBytes(for: recipe, in: 0..<prefixLineCount))

        // The prefix must not itself have evicted, or the charge read below is the
        // arena's ceiling rather than the payload's rate and the division degenerates
        // into `capacity / (capacity / prefix) == prefix`, which passes for any recipe
        // whose `lineCount` exceeds the prefix. Exact equality is that guard and also
        // pins one payload line to one retained row, so a payload or width that started
        // soft-wrapping fails here instead of halving the rate silently.
        #expect(terminal.scrollbackRowCount == prefixLineCount - (recipe.rows - 1))

        let census = terminal.memoryCensus
        #expect(census.hasRetainedStorageOverdraft == false)
        let chargePerLine = Double(census.retainedChargedBytes) / Double(prefixLineCount)
        #expect(chargePerLine > 0)
        // Stated as a depth rather than a projected byte total so a failure names the
        // number that has to change: the line count the recipe ships.
        //
        // Conservative in the safe direction: per-line charge creeps *upward* with depth
        // as the index and side tables amortize (measured, per payload: dense 339 -> 373
        // B/line between 512 and 2,048 lines, sparse 58.7 -> 63.1 between 512 and 16,384,
        // wide 1,278 -> 1,415 between 512 and 2,048). A prefix therefore understates the
        // rate and *overstates* the depth at which the arena fills, so clearing this bound
        // from a prefix implies clearing it at full depth.
        //
        // A margin, not just the ceiling: `impliedDepth <= lineCount` passes at 1.003x,
        // which is how `.sparseSaturating` came to ship a margin of exactly that and
        // nobody noticed. A bound that cannot tell "saturates" from "barely saturates"
        // lets a charge-rate change erode the last percent silently, and the recipe then
        // prints a full distribution of a line-bounded history. 1.5x is the largest factor
        // every shipped recipe clears -- measured margins are dense 2.85x, sparse 2.01x,
        // wide 5.40x -- so the tightest recipe still has 1.34x of headroom, and the
        // measurement is exact integer arithmetic over a deterministic payload, so there
        // is no sampling noise for that headroom to absorb. It fails while the recipe is
        // still saturating, which is the point: the fix is an edit to a constant, not an
        // incident.
        let impliedSaturationLineCount =
            Double(census.retainedArenaCapacityBytes) / chargePerLine
        #expect(impliedSaturationLineCount * 1.5 <= Double(recipe.lineCount))
    }

    /// The prefix `saturatingRecipesChargePastTheBudgetCeiling` measures each payload's
    /// per-line charge over.
    ///
    /// Per payload rather than one constant because the rate a prefix reports is an
    /// understatement that shrinks with depth, and the margin bound above is only as
    /// trustworthy as the rate. `.dense` implies 42,100 lines against a shipped 120,000
    /// (2.85x) and `.wide` 11,100 against 60,000 (5.40x), both settled by 2,048 lines.
    /// `.sparse` is the slowest to amortize -- 58.7 B/line at 512, 63.1 at 16,384 -- and
    /// it is also the tightest recipe (500,000 against an implied 249,200, 2.01x), so it
    /// reads its rate at 16,384, which is within 0.2% of the 63.24 B/line the rate
    /// asymptotes to, against the 1.8% short it still is at 2,048.
    ///
    /// The prefix cost is fixed by these constants and not by any recipe's `lineCount`,
    /// which is what lets `.sparseSaturating` carry a real margin without this test
    /// paying for it -- only the manually-run probe binary feeds the shipped counts.
    private static func chargeMeasurementPrefixLineCount(for recipe: ResizeProbeRecipe) -> Int {
        recipe.payload == .sparse ? 16_384 : 2_048
    }

    @Test("The wide recipe's ceiling is observed, not projected")
    func wideSaturatingRecipeEvictsWithinItsBound() throws {
        // Intent: `.wideSaturating` produces observed eviction within its declared line
        //   bound, and 200 more lines past that point leave retained depth where it was
        //   -- the byte budget, not the feed, is deciding depth.
        // Why it exists: `saturatingRecipesChargePastTheBudgetCeiling` decides all three
        //   recipes by arithmetic on a measured charge rate, and arithmetic can be right
        //   about bytes while wrong about the machine -- the arena could refuse to fill,
        //   or fill without evicting. One recipe therefore stays on the path that watches
        //   an eviction happen, which anchors the division for the other two.
        //   `.wideSaturating` is the one, because it is the cheapest to saturate of the
        //   three: its rows are the most expensive content in the corpus, so it reaches
        //   the ceiling in ~12,000 lines where `.sparseSaturating` needs ~248,000.
        let recipe = ResizeProbeRecipe.wideSaturating
        let evidence = try #require(saturationEvidence(for: recipe))
        #expect(evidence.linesFed > 0)
        #expect(evidence.linesFed <= recipe.lineCount)

        var terminal = evidence.terminal
        let atCeiling = terminal.scrollbackRowCount

        // Overfed with the recipe's *own* payload, not a longer marker line. A
        // denser overfeed evicts more cheap rows than it admits under a
        // content-denominated bound and the count falls, which reads as a failure
        // while actually confirming saturation.
        terminal.feed(recipeBytes(for: recipe, in: evidence.linesFed..<(evidence.linesFed + 200)))

        #expect(atCeiling > 0)
        #expect(atCeiling < evidence.linesFed)
        // A band rather than an equality or a one-sided bound since doc 31: the bound is charged
        // bytes, and where the equilibrium settles inside a row is phase-dependent -- a trimmed
        // head frees a display row without freeing a whole line's charge, and the ring's
        // chunk-seam pads (`research/31/DD14`) move with the write cursor -- so an overfeed at the ceiling
        // lands a few rows either side of where the fill left it. What the recipe claims -- that
        // feeding 200 more lines buys no more depth -- is the direction, not the exact figure,
        // and a couple of rows against 200 fed is that claim holding, in either direction.
        #expect(terminal.scrollbackRowCount < atCeiling + 100)
        #expect(terminal.scrollbackRowCount > atCeiling - 100)
        #expect(terminal.memoryCensus.hasRetainedStorageOverdraft == false)
    }

    @Test("A shallow production-budget recipe is not saturation evidence")
    func shallowRecipeDoesNotReportSaturation() {
        // Intent: ordinary scrollback growth without eviction produces no saturation evidence.
        // Why it exists: a detector that mistakes viewport fill or retained-history growth for
        //   eviction would make the optimized guard pass before reaching the production budget.
        // Scenario: a short dense transcript scrolls well beyond the viewport but remains far
        //   below the production history budget.
        let recipe = ResizeProbeRecipe(
            columns: 179, rows: 66, lineCount: 1_000,
            scrollbackBudgetBytes: Terminal.scrollbackByteLimit,
            alternateColumns: 100, sampleCount: .declared(1), warmupCount: 0
        )

        #expect(saturationEvidence(for: recipe) == nil)
    }

    private func saturationEvidence(for recipe: ResizeProbeRecipe) -> SaturationEvidence? {
        guard recipe.scrollbackBudgetBytes == Terminal.scrollbackByteLimit,
              var terminal = Terminal(columns: recipe.columns, rows: recipe.rows)
        else { return nil }

        let batchLineCount = 2_048
        var nextLine = 0
        while nextLine < recipe.lineCount {
            let batchEnd = min(nextLine + batchLineCount, recipe.lineCount)
            let retainedRowsBeforeBatch = terminal.scrollbackRowCount
            terminal.feed(recipeBytes(for: recipe, in: nextLine..<batchEnd))
            let linesInBatch = batchEnd - nextLine
            nextLine = batchEnd

            if retainedRowsBeforeBatch > 0,
               terminal.scrollbackRowCount < retainedRowsBeforeBatch + linesInBatch
            {
                return SaturationEvidence(terminal: terminal, linesFed: nextLine)
            }
        }
        return nil
    }

    private func recipeBytes(
        for recipe: ResizeProbeRecipe,
        in lines: Range<Int>
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lines.count * (recipe.columns + 2))
        for line in lines {
            bytes.append(contentsOf: recipe.payload.line(line).utf8)
            bytes.append(0x0D)
            bytes.append(0x0A)
        }
        return bytes
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
            scrollbackBudgetBytes: Terminal.scrollbackByteLimit,
            alternateColumns: 100, sampleCount: .declared(4), warmupCount: 0
        )
        var widths: [Int] = []
        var terminal = makeSaturatedTerminal(recipe: recipe)
        for index in 0..<recipe.sampleCount.value {
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

    @Test(
        "Every shipped recipe alternates to a width Terminal.resize acts on",
        arguments: [
            ResizeProbeRecipe.standard,
            ResizeProbeRecipe.saturating,
            ResizeProbeRecipe.sparseSaturating,
            ResizeProbeRecipe.wideSaturating,
        ]
    )
    func shippedRecipesAlternateToAnEffectiveWidth(recipe: ResizeProbeRecipe) {
        // Intent: each frozen recipe's alternate width is at least 2 and differs
        //   from its own width, so every timed sample resizes something.
        // Why it exists: `Terminal.resize` early-returns for a width below 2 and for
        //   a width equal to the current one. A recipe that alternated to such a
        //   width would still collect `sampleCount` samples and still print a full
        //   distribution -- of two clock reads. `probeAlternatesWidths` guards the
        //   alternation logic; this guards the constants it alternates between,
        //   which is the half that a future recipe edit can break.
        #expect(recipe.alternateColumns >= 2)
        #expect(recipe.alternateColumns != recipe.columns)
    }

    @Test("The report carries the recipe that produced it")
    func reportCarriesItsRecipe() {
        // Intent: geometry, budget, row count, and repeat count travel with the
        //   distribution.
        // Why it exists: `research/28/D1` pitch 2 made this a condition of freezing the
        //   recipe at all, because `research/15/F18`'s deleted probe left behind numbers
        //   whose conditions had to be reconstructed from prose.
        let recipe = ResizeProbeRecipe(
            columns: 120, rows: 8, lineCount: 300,
            scrollbackBudgetBytes: Terminal.scrollbackByteLimit,
            alternateColumns: 60, sampleCount: .declared(2), warmupCount: 1
        )
        let report = measureSaturatedResize(recipe: recipe)

        #expect(report.recipeIdentity == recipe.identity)
        #expect(report.payload == .dense)
        #expect(report.columns == 120)
        #expect(report.rows == 8)
        #expect(report.lineCount == 300)
        #expect(report.alternateColumns == 60)
        #expect(report.warmupCount == 1)
        #expect(report.scrollbackBudgetBytes == Terminal.scrollbackByteLimit)
        #expect(report.retainedRowCountAtStart > 0)
        #expect(report.distribution.sampleCount == 2)
        #expect(report.distribution.samplesNanoseconds.count == 2)
    }

    @Test("The report groups its samples by the direction each one resized")
    func reportGroupsSamplesByDirection() {
        // Intent: every timed sample appears under the width it resized to, so a
        //   statistic can be read for one direction rather than for the mixture of two.
        // Why it exists: the probe alternates narrow and wide on purpose -- a drag pays
        //   both -- but the two directions cost very different amounts, so every quantile
        //   of the combined samples lands inside one direction's population and moves
        //   between them for reasons that are not cost. Measured on the `wide` recipe:
        //   the narrowing resizes centre on 2.59 ms and the widening ones on 1.45 ms,
        //   which puts the combined median inside the widening group and the combined p95
        //   inside the narrowing one. The paired comparison decides on these groups
        //   instead, and it can only do that if the report carries them.
        // Scenario: spec-first.
        let recipe = ResizeProbeRecipe(
            columns: 120, rows: 8, lineCount: 300,
            scrollbackBudgetBytes: Terminal.scrollbackByteLimit,
            alternateColumns: 60, sampleCount: .declared(5), warmupCount: 0
        )
        let report = measureSaturatedResize(recipe: recipe)

        #expect(report.directions.map(\.toColumns) == [60, 120])
        #expect(report.directions.map(\.isNarrowing) == [true, false])
        // Five alternating samples starting at the narrow width: three narrowings, two
        // widenings, and every sample accounted for exactly once.
        #expect(report.directions.map(\.distribution.sampleCount) == [3, 2])
        #expect(
            report.directions.flatMap(\.distribution.samplesNanoseconds).sorted()
                == report.distribution.samplesNanoseconds.sorted()
        )
    }

    @Test("The report states the retained cells the timed resizes reflowed")
    func reportStatesRetainedCellCount() {
        // Intent: `retainedCellCountAtStart` is the stored cell count of the very history
        //   the timed samples ran against -- after the warm resizes, not before them.
        // Why it exists: a paired comparison of this probe fails on any difference in
        //   retained content between its arms, because an arm that reflows fewer cells is
        //   cheaper for a reason that is not an optimization. Rows alone cannot carry that
        //   check: a row that lost cells leaves the row count unmoved. The count must
        //   therefore be the post-warmup one, since the warm resizes reflow and a
        //   pre-warmup number would describe a history no sample measured.
        // Scenario: spec-first.
        let recipe = ResizeProbeRecipe(
            columns: 120, rows: 8, lineCount: 300,
            scrollbackBudgetBytes: Terminal.scrollbackByteLimit,
            alternateColumns: 60, sampleCount: .declared(2), warmupCount: 1
        )
        let report = measureSaturatedResize(recipe: recipe)

        var expected = makeSaturatedTerminal(recipe: recipe)
        expected.resize(columns: recipe.alternateColumns, rows: recipe.rows)
        #expect(report.retainedCellCountAtStart == expected.memoryCensus.retainedStoredCellCount)
        #expect(report.retainedCellCountAtStart > 0)
    }

    // Intent: the report states the content regime as data, for each regime there is.
    // Why it exists: retained depth varies by an order of magnitude with the payload and
    //   resize cost varies with depth, so a distribution whose regime is recoverable only by
    //   parsing `recipeIdentity`'s name is a distribution a rename can misattribute.
    // Scenario: spec-first.
    @Test("A report names the payload it was fed", arguments: [
        ResizeProbePayload.dense, .sparse, .wide,
    ])
    func reportNamesItsPayload(payload: ResizeProbePayload) {
        // A shallow history and one sample: this asserts what the report carries, not what a
        // saturated resize costs.
        let recipe = ResizeProbeRecipe(
            columns: 120, rows: 8, lineCount: 200,
            scrollbackBudgetBytes: Terminal.scrollbackByteLimit,
            alternateColumns: 60, sampleCount: .declared(1), warmupCount: 0,
            payload: payload
        )
        #expect(measureSaturatedResize(recipe: recipe).payload == payload)
    }

    // Intent: an override replaces the field it names and nothing else.
    // Why it exists: the two CLI flags are the only writers of a recipe that is otherwise
    //   frozen data. An override that also reset `payload` would report a distribution
    //   measured on one content regime under an identity claiming another -- the one failure
    //   the identity string exists to prevent.
    // Scenario: spec-first.
    @Test("Overriding a recipe's sample count leaves its shape and its identity alone")
    func overridingSampleCountKeepsEverythingElse() {
        let sparse = ResizeProbeRecipe.sparseSaturating
        let retimed = sparse.with(sampleCount: .declared(40))

        #expect(retimed.sampleCount == PositiveCount.declared(40))
        #expect(retimed.payload == .sparse)
        #expect(retimed.identity == sparse.identity)
        #expect(retimed == sparse.with(sampleCount: .declared(40)))
        // Every field but the named one, stated as one comparison: restoring the count
        // restores the whole value.
        #expect(retimed.with(sampleCount: sparse.sampleCount) == sparse)
    }

    // Intent: an alternate-width override changes the identity, because the width is part of
    //   the shape a report claims.
    // Why it exists: `--samples` and `--alternate-columns` are not symmetric -- one retimes
    //   the same shape, the other measures a different one -- and only the second may move
    //   `identity`.
    // Scenario: spec-first.
    @Test("Overriding the alternate width changes the identity and keeps the payload")
    func overridingAlternateWidthMovesTheIdentity() {
        let wide = ResizeProbeRecipe.wideSaturating
        let narrowed = wide.with(alternateColumns: 80)

        #expect(narrowed.alternateColumns == 80)
        #expect(narrowed.payload == .wide)
        #expect(narrowed.identity != wide.identity)
        #expect(narrowed.identity.hasSuffix("-to-80"))
        #expect(narrowed.with(alternateColumns: wide.alternateColumns) == wide)
    }

    @Test("The distribution reports order statistics over the raw samples it keeps")
    func distributionReportsOrderStatistics() {
        // Intent: quantiles are nearest-rank over the sorted samples, and every
        //   raw sample survives in collection order.
        // Why it exists: an interpolated tail quantile over a few dozen samples
        //   reports a duration that never occurred, and a summary that discarded
        //   its samples cannot be re-reduced later -- `research/20/F12` had to recover
        //   exactly such samples by hand from per-block artifacts.
        let distribution = ResizeProbeDistribution(first: 50, rest: [10, 30, 20, 40])

        #expect(distribution.sampleCount == 5)
        #expect(distribution.minimumNanoseconds == 10)
        #expect(distribution.maximumNanoseconds == 50)
        #expect(distribution.medianNanoseconds == 30)
        #expect(distribution.p90Nanoseconds == 50)
        // The comparison owner decides on the median and this quantile, so it is a
        // written field rather than arithmetic a reader repeats over the samples.
        #expect(distribution.p95Nanoseconds == 50)
        #expect(distribution.p99Nanoseconds == 50)
        #expect(distribution.meanNanoseconds == 30)
        #expect(distribution.samplesNanoseconds == [50, 10, 30, 20, 40])
    }

    @Test("A distribution with no samples cannot be decoded")
    func emptySampleSetIsNotADistribution() throws {
        // Intent: an artifact carrying no samples is refused at the boundary rather than
        //   decoded into a distribution whose every statistic reads zero.
        // Why it exists: the measurement-discipline rule this doc binds itself to requires
        //   "not measured" to be a state distinct from "measured fast", and zeros are not that
        //   state -- a zero median reads as an instant resize. In code the empty case is now
        //   unrepresentable; decoding is the one door left, so it refuses.
        let empty = Data(#"{"samplesNanoseconds": []}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ResizeProbeDistribution.self, from: empty)
        }
    }

    @Test("A decoded distribution reduces the samples it carries, not the summary beside them")
    func decodedDistributionIsReducedFromItsSamples() throws {
        // Intent: the statistics of a decoded distribution come from its raw samples.
        // Why it exists: the summary and the samples were two independent stored fields, so an
        //   artifact could carry a median that no sample in it supports and nothing would say
        //   so. `research/20/F12`'s whole reason for keeping raw samples is that a later reader
        //   can re-reduce them; that only holds if the reduction is the reported number.
        let stale = Data(#"{"samplesNanoseconds": [10, 30, 20], "medianNanoseconds": 999}"#.utf8)

        let decoded = try JSONDecoder().decode(ResizeProbeDistribution.self, from: stale)

        #expect(decoded.sampleCount == 3)
        #expect(decoded.medianNanoseconds == 20)
        #expect(decoded.minimumNanoseconds == 10)
        #expect(decoded.maximumNanoseconds == 30)
    }

    @Test("A distribution survives a round trip through its own artifact")
    func distributionRoundTrips() throws {
        let distribution = ResizeProbeDistribution(first: 50, rest: [10, 30, 20, 40])

        let data = try JSONEncoder().encode(distribution)
        let decoded = try JSONDecoder().decode(ResizeProbeDistribution.self, from: data)

        #expect(decoded == distribution)
    }
}
