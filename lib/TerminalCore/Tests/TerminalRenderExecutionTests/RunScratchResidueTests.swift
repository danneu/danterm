// Cross-run isolation proofs for `drawTextRuns`' per-run scratch collections.
//
// `drawTextRuns` accumulates each run's sprites, glyphs, and fallback cells into
// scratch collections that are reused across runs of the same draw. Every test
// here draws two runs that produce disjoint categories of content and pins each
// run's pixels to the same run drawn alone, so a collection that carries one
// run's contents into the next shows up as extra ink instead of silently
// duplicating geometry. Separate from the per-family sprite suites: those prove
// what one run draws, these prove what a run does *not* inherit.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct RunScratchResidueTests {
    @Test("Sprite rects and box-drawing strokes do not leak into a later text run")
    func spriteRectsAndStrokesDoNotLeak() throws {
        // Intent: the shared sprite-rect accumulator and the box-drawing stroke
        //   accumulator are empty when a run that draws no sprites is reached.
        // Why it exists: both accumulators are hoisted above the run loop, so a
        //   missing reset would refill the earlier run's rects and re-stroke its
        //   lines in the later run's foreground color.
        // Scenario: a box-drawn frame or braille plot on one row followed by
        //   ordinary colored text on another -- any TUI with a border.
        try expectRunsRenderInIsolation(
            producer: "\u{2500}\u{2571}\u{28FF}",
            consumer: "X"
        )
    }

    @Test("Shaded block-element rects do not leak into a later text run")
    func shadedSpriteRectsDoNotLeak() throws {
        // Intent: every shade bucket of the block-element dictionary is empty
        //   when a run that draws no shaded blocks is reached.
        // Why it exists: the dictionary is hoisted with its keys retained and
        //   its inner arrays cleared in place, which is a different clearing
        //   mechanism than the flat accumulators use and can fail on its own.
        // Scenario: a shaded progress bar or meter on one row followed by
        //   ordinary colored text on another.
        try expectRunsRenderInIsolation(
            producer: "\u{2591}\u{2592}\u{2593}",
            consumer: "X",
            columns: 6
        )
    }

    @Test("Legacy-computing rects do not leak into a later text run")
    func legacySpriteRectsDoNotLeak() throws {
        // Intent: every alpha bucket of the legacy-computing dictionary is empty
        //   when a run that draws no legacy-computing sprites is reached.
        // Why it exists: the second keyed dictionary clears its inner arrays in
        //   place exactly like the shaded one, and nothing but its own test
        //   would catch it being missed from the reset sweep.
        // Scenario: sixel-style legacy block art on one row followed by
        //   ordinary colored text on another.
        try expectRunsRenderInIsolation(
            producer: "\u{1FB00}\u{1FB70}\u{1FB95}",
            consumer: "X",
            columns: 6
        )
    }

    @Test("Geometric, powerline, and branch geometries do not leak into a later text run")
    func flatSpriteGeometriesDoNotLeak() throws {
        // Intent: the geometric-shape, powerline, and branch-drawing
        //   accumulators are all empty when a run that draws none of them is
        //   reached.
        // Why it exists: these three are drawn by per-element loops with no
        //   `isEmpty` guard to hide a leak, so residue is drawn unconditionally.
        // Scenario: a powerline prompt segment beside a branch glyph on one row
        //   followed by ordinary colored text on another.
        try expectRunsRenderInIsolation(
            producer: "\u{25E2}\u{E0B0}\u{F5D0}",
            consumer: "X",
            columns: 6
        )
    }

    @Test("Mapped glyphs and their positions do not leak into a later sprite run")
    func glyphPipelineDoesNotLeak() throws {
        // Intent: the character buffer, candidate cells, mapped glyphs, and
        //   glyph positions are all empty when a run that maps no glyphs is
        //   reached.
        // Why it exists: `CTFontDrawGlyphs` is handed a glyph array and a
        //   position array that must agree in count and content with the cells
        //   the run owns; residue in any one of the four either redraws an
        //   earlier run's text or pairs a glyph with a foreign position.
        // Scenario: ordinary text on one row followed by a box-drawn rule on
        //   another -- the reverse order of the sprite-leak case.
        try expectRunsRenderInIsolation(
            producer: "AB",
            consumer: "\u{2500}"
        )
    }

    @Test("A run that maps fewer glyphs than the one before it draws only its own")
    func glyphPipelineDoesNotLeakIntoAShorterRun() throws {
        // Intent: a text run preceded by a longer text run maps, positions, and
        //   draws exactly its own glyphs.
        // Why it exists: the sprite-consumer case above cannot see residue in
        //   `characters`, the glyph buffer, or `positions`, because a run that
        //   maps nothing never indexes them. Only a shorter *text* run reads
        //   those stale slots -- as a wrong glyph in its own cell, or as its own
        //   glyph drawn at the earlier run's coordinates.
        // Scenario: a long line of output followed by a short one, which is what
        //   nearly every consecutive pair of text runs in a frame looks like.
        try expectRunsRenderInIsolation(
            producer: "AB",
            consumer: "X"
        )
    }

    @Test("Fallback cells do not leak into a later sprite run")
    func fallbackCellsDoNotLeak() throws {
        // Intent: the fallback-cell accumulator is empty when a run with no
        //   fallback cells is reached.
        // Why it exists: fallback cells are drawn on their own attributed-string
        //   path, so residue there duplicates a cluster the later run never
        //   owned and no glyph-path assertion would see it.
        // Scenario: text the base face cannot map (Arabic here) on one row
        //   followed by a box-drawn rule on another.
        try expectRunsRenderInIsolation(
            producer: "ا",
            consumer: "\u{2500}"
        )
    }
}

/// Draws `producer` and `consumer` as two runs of one frame, separated by a blank
/// row so neither run's glyph overhang can reach the other's cells, and pins both
/// rows to the same content drawn without the other run present. The two runs use
/// different foreground colors: residue is redrawn at the producing run's own
/// coordinates, so a leak surfaces as the producer's geometry repainted in the
/// consumer's color rather than as displaced ink.
private func expectRunsRenderInIsolation(
    producer: String,
    consumer: String,
    columns: Int = 4,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    for scale in [1.0, 2.0] as [CGFloat] {
        let metrics = try #require(
            TerminalRenderMetrics(displayScale: scale),
            sourceLocation: sourceLocation
        )
        let producerInput = "\u{1B}[31m" + producer
        let consumerInput = "\u{1B}[3;1H\u{1B}[34m" + consumer
        let combined = try renderBitmap(
            plan: makePlan(input: producerInput + consumerInput, columns: columns, rows: 3),
            metrics: metrics
        )
        let producerOnly = try renderBitmap(
            plan: makePlan(input: producerInput, columns: columns, rows: 3),
            metrics: metrics
        )
        let consumerOnly = try renderBitmap(
            plan: makePlan(input: consumerInput, columns: columns, rows: 3),
            metrics: metrics
        )
        let producerRow = cellRect(row: 0, column: 0, columnCount: columns, metrics: metrics)
        let blankRow = cellRect(row: 1, column: 0, columnCount: columns, metrics: metrics)
        let consumerRow = cellRect(row: 2, column: 0, columnCount: columns, metrics: metrics)

        #expect(
            combined.inkCount(in: producerRow) > 0,
            "producer drew nothing at scale \(scale)",
            sourceLocation: sourceLocation
        )
        #expect(
            combined.inkCount(in: consumerRow) > 0,
            "consumer drew nothing at scale \(scale)",
            sourceLocation: sourceLocation
        )
        #expect(
            combined.bytes(in: producerRow) == producerOnly.bytes(in: producerRow),
            "producer row changed at scale \(scale)",
            sourceLocation: sourceLocation
        )
        #expect(
            combined.bytes(in: consumerRow) == consumerOnly.bytes(in: consumerRow),
            "consumer row changed at scale \(scale)",
            sourceLocation: sourceLocation
        )
        #expect(
            combined.inkCount(in: blankRow) == 0,
            "blank row inked at scale \(scale)",
            sourceLocation: sourceLocation
        )
    }
}
