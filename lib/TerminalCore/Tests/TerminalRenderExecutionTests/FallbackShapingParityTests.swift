// Pixel parity between the executor's fallback cells and a test-only copy of the
// pre-cache draw path, plus the containment those cells owe their neighbours.
//
// The suite exists to survive a change of mechanism: whatever the executor does with a
// cluster it cannot batch -- typeset it per cell, or shape it once and replay it -- the
// bitmap must equal what an attributed string and `CTLineDraw` produce. Drawing the same
// cluster twice, and drawing a frame twice, are separate cases because a memo can agree
// with itself and still disagree with the path it replaced.
//
// One deliberate exception, and it is the reason `FallbackMarkPlacementTests` is in this
// file: for a cluster whose runs carry a nonzero cross-stream glyph origin, `CTLineDraw`
// under the executor's y-flip puts an attached mark somewhere other than where the same
// line reports it, and the draw follows the typesetter. Those cases are pinned by where
// their mark lands. Membership in that exception is a property of the case, not a licence
// -- `keepsBitmapParity` names it, and every other case keeps the parity pin.
import CoreGraphics
import CoreText
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

/// The clusters the parity suite renders: one per kind of content the mapped-glyph batch
/// cannot carry, plus the four styled faces.
///
/// Membership is not decided by expectation. `clusterSetClaimsEveryExceptionalCondition`
/// reads back which of the four exceptional conditions each case's line actually carries
/// and fails when one of them is claimed by nobody, so a case that stops producing the
/// condition it was chosen for is replaced rather than assumed.
let fallbackClusterCases: [FallbackClusterCase] = [
    FallbackClusterCase(name: "CJK", text: "\u{6F22}"),
    FallbackClusterCase(name: "colour emoji", text: "\u{1F600}"),
    FallbackClusterCase(name: "ZWJ sequence", text: "\u{1F469}\u{200D}\u{1F4BB}"),
    FallbackClusterCase(name: "combining marks", text: "e\u{0301}\u{0304}"),
    // The two clusters whose runs carry a nonzero cross-stream origin, which is where
    // `CTLineDraw` under the flip and the line's own reported positions disagree. They
    // are pinned by where the mark lands, not by parity: `FallbackMarkPlacementTests`.
    FallbackClusterCase(
        name: "wide base with combining mark",
        text: "\u{6F22}\u{0301}",
        keepsBitmapParity: false
    ),
    FallbackClusterCase(
        name: "wide base with dot-below mark",
        text: "\u{6F22}\u{0323}",
        keepsBitmapParity: false
    ),
    // A colour glyph the terminal gives one column: the deliberately oversized case, and
    // the reason the containment proof needs a cluster whose ink leaves the cell it was
    // shaped for unless something clips it.
    FallbackClusterCase(name: "variation selector", text: "\u{2764}\u{FE0F}"),
    FallbackClusterCase(name: "gated bare scalar", text: "\u{23FA}"),
    FallbackClusterCase(name: "bold CJK", text: "\u{6F22}", bold: true),
    FallbackClusterCase(name: "italic CJK", text: "\u{6F22}", italic: true),
    FallbackClusterCase(name: "bold-italic CJK", text: "\u{6F22}", bold: true, italic: true),
    FallbackClusterCase(
        name: "CJK on an oblique base face",
        text: "\u{6F22}",
        faceSource: .obliqueBaseFont
    ),
]

/// The cases whose bitmap must equal the reference renderer's, which is every case but
/// the two the placement contract deliberately moves.
let fallbackParityCases = fallbackClusterCases.filter(\.keepsBitmapParity)

/// The two cases the placement contract moves off parity, pinned by mark placement.
let fallbackPlacementCases = fallbackClusterCases.filter { $0.keepsBitmapParity == false }

/// The three ways one cluster can reach the surface, so a parity failure names which of
/// them moved: drawn once, drawn twice inside one frame, and drawn again on a second
/// frame over the same surface.
enum FallbackParityShape: CaseIterable, Sendable, CustomStringConvertible {
    case once
    case twiceInOneFrame
    case onceOnTwoFrames

    var occurrences: Int { self == .twiceInOneFrame ? 2 : 1 }
    var frames: Int { self == .onceOnTwoFrames ? 2 : 1 }

    var description: String {
        switch self {
        case .once: "once"
        case .twiceInOneFrame: "twice in one frame"
        case .onceOnTwoFrames: "once on each of two frames"
        }
    }
}

/// The conditions that make a shaped cluster something other than an ordinary batched
/// entry, or that put it under the placement contract instead of bitmap parity.
enum ExceptionalClusterCondition: CaseIterable, CustomStringConvertible {
    case multipleRuns
    case nonIdentityRunMatrix
    case inkOutsideCellSpan
    /// A run whose glyphs carry a nonzero cross-stream (y) origin. This is the condition
    /// under which `CTLineDraw` and the line's own reported positions disagree once the
    /// text matrix is flipped, so it is the one the placement contract is about.
    case nonzeroCrossStreamOrigin

    var description: String {
        switch self {
        case .multipleRuns: "more than one run"
        case .nonIdentityRunMatrix: "kCTRunStatusHasNonIdentityMatrix"
        case .inkOutsideCellSpan: "ink outside the cell span"
        case .nonzeroCrossStreamOrigin: "a nonzero cross-stream glyph origin"
        }
    }
}

struct FallbackShapingParityTests {
    @Test(
        "A fallback cluster renders exactly what the pre-cache path drew",
        arguments: fallbackParityCases,
        FallbackParityShape.allCases
    )
    func fallbackClusterMatchesTheReferencePath(
        clusterCase: FallbackClusterCase,
        shape: FallbackParityShape
    ) throws {
        // Intent: for every kind of cluster the mapped-glyph batch cannot carry, the
        //   executor's surface equals the surface a per-cell attributed string and
        //   `CTLineDraw` produce -- drawn once, drawn twice in one frame, and drawn
        //   again on a later frame.
        // Why it exists: the fallback path is about to stop typesetting per cell and
        //   start replaying a shaped cluster, and "the new path agrees with itself" is
        //   not the property that matters. Both halves can agree and both be wrong, so
        //   the target is a copy of the path being replaced, held outside the executor.
        // Scenario: spec-first -- a pane showing CJK, emoji, and accented text in each
        //   of the four styled faces, repainted.
        let metrics = try #require(clusterCase.metrics())
        let plan = try fallbackParityPlan(clusterCase, occurrences: shape.occurrences)

        let actual = try renderRepeatedBitmap(
            plan: plan,
            metrics: metrics,
            frames: shape.frames
        )
        let reference = try renderFallbackReferenceBitmap(
            plan: plan,
            metrics: metrics,
            frames: shape.frames
        )

        expectBitmap(actual, matches: reference, "\(clusterCase.name), \(shape)")
    }

    @Test("A fallback cluster leaves its neighbours' cells untouched", arguments: fallbackClusterCases)
    func fallbackClusterInkStaysInsideItsCells(clusterCase: FallbackClusterCase) throws {
        // Intent: a cluster drawn with a blank cell on each side leaves both of those
        //   cells holding nothing but the default background.
        // Why it exists: containment is why the fallback path clips at all. A shaped
        //   cluster whose glyphs are submitted without that clip -- an emoji square in a
        //   one-column cell is the case that shows it -- bleeds over the cell beside it,
        //   which is the defect the clip was added to prevent.
        // Scenario: spec-first -- a line of prose with one emoji between two spaces.
        let metrics = try #require(clusterCase.metrics())
        let column = 2
        let plan = try makePlan(
            input: clusterCase.stylePrefix + "\u{1B}[\(column + 1)G" + clusterCase.text,
            columns: 10,
            rows: 1
        )
        let cell = try #require(firstTextCell(of: plan))
        let bitmap = try renderBitmap(plan: plan, metrics: metrics)

        #expect(
            bitmap.inkCount(in: cellRect(row: 0, column: 0, columnCount: column, metrics: metrics)) == 0,
            "\(clusterCase.name) inked a cell before its own"
        )
        let after = column + cell.columnWidth
        #expect(
            bitmap.inkCount(in: cellRect(
                row: 0,
                column: after,
                columnCount: 10 - after,
                metrics: metrics
            )) == 0,
            "\(clusterCase.name) inked a cell after its own"
        )
    }

    @Test("The cluster set exercises every exceptional shaping condition")
    func clusterSetClaimsEveryExceptionalCondition() throws {
        // Intent: across the set, each of the four conditions that make a cluster
        //   exceptional -- more than one run, a run matrix, ink outside the cell span,
        //   a nonzero cross-stream glyph origin -- is carried by at least one case's
        //   typeset line.
        // Why it exists: the parity suite is only as good as its set. A case picked
        //   because it "should" produce a run matrix, and that quietly stopped, would
        //   leave the replay path unproved while the suite still passed. This reads the
        //   conditions back off CoreText rather than trusting the choice.
        var claims: [ExceptionalClusterCondition: [String]] = [:]
        var report: [String] = []

        for clusterCase in fallbackClusterCases {
            let metrics = try #require(clusterCase.metrics())
            let plan = try fallbackParityPlan(clusterCase, occurrences: 1)
            let cell = try #require(firstTextCell(of: plan))
            let face = metrics.fonts.face(bold: clusterCase.bold, italic: clusterCase.italic)
            let conditions = try exceptionalConditions(
                of: cell,
                face: face,
                metrics: metrics
            )
            for condition in conditions { claims[condition, default: []].append(clusterCase.name) }
            let carried = conditions.isEmpty
                ? "ordinary"
                : conditions.map(\.description).joined(separator: ", ")
            report.append("\(clusterCase.name): \(carried)")
        }

        for condition in ExceptionalClusterCondition.allCases {
            #expect(
                claims[condition]?.isEmpty == false,
                "no case carries \(condition); the set reads: \(report.joined(separator: "; "))"
            )
        }
    }

    /// Which of the four exceptional conditions this cell's typeset line carries.
    private func exceptionalConditions(
        of cell: RenderTextCell,
        face: TerminalFace,
        metrics: TerminalRenderMetrics
    ) throws -> Set<ExceptionalClusterCondition> {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let line = referenceLine(
            for: cell,
            font: face.font,
            foreground: referenceColor(RenderTheme.dark.defaultForeground, in: colorSpace)
        )
        var conditions: Set<ExceptionalClusterCondition> = []

        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        if runs.count > 1 { conditions.insert(.multipleRuns) }
        for run in runs where CTRunGetStatus(run).contains(.hasNonIdentityMatrix) {
            conditions.insert(.nonIdentityRunMatrix)
        }
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var origins = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetBaseAdvancesAndOrigins(run, CFRange(location: 0, length: 0), nil, &origins)
            if origins.contains(where: { $0.y != 0 }) {
                conditions.insert(.nonzeroCrossStreamOrigin)
            }
        }

        // Image bounds come back in text space -- x from the line origin, y up from the
        // baseline -- so the cell span is the cell's width, its baseline offset above and
        // the rest of its height below.
        let bounds = CTLineGetImageBounds(line, nil)
        let width = CGFloat(cell.columnWidth) * metrics.cellSize.width
        let above = metrics.baselineOffset
        let below = metrics.cellSize.height - metrics.baselineOffset
        if bounds.isNull == false,
           bounds.minX < 0 || bounds.maxX > width || bounds.maxY > above || bounds.minY < -below
        {
            conditions.insert(.inkOutsideCellSpan)
        }
        return conditions
    }
}

/// The plan the parity cases render: the cluster, in the case's style, at the start
/// of the row and again far enough along that the two cannot share a cell.
func fallbackParityPlan(
    _ clusterCase: FallbackClusterCase,
    occurrences: Int
) throws -> RenderFramePlan {
    var input = clusterCase.stylePrefix + clusterCase.text
    if occurrences > 1 {
        input += "\u{1B}[7G" + clusterCase.text
    }
    return try makePlan(input: input, columns: 12, rows: 1)
}

/// The first cell of the plan that carries scalars, which is the cluster under test.
func firstTextCell(of plan: RenderFramePlan) -> RenderTextCell? {
    for run in plan.textRuns {
        for cell in run.cells where cell.scalars.isEmpty == false { return cell }
    }
    return nil
}

/// Where a base-plus-mark cluster's mark lands, for the two cases the placement contract
/// moves off bitmap parity.
///
/// `CTLineDraw` under the executor's y-flip moves an attached mark away from the position
/// the same line reports for it, by an offset that does not generalize; the draw follows
/// the typesetter instead. That is a rendering change, so parity with the old path cannot
/// pin these clusters. What can be pinned is the property the change exists to restore: a
/// mark goes on the side of the base its name says, and the base itself does not move.
struct FallbackMarkPlacementTests {
    @Test("A marked cluster draws the same on a miss, a repeat, and a later frame")
    func markedClusterIsStableAcrossItsThreeShapes() throws {
        // Intent: for each cluster the placement contract moves off parity, the surface
        //   from one draw, from two draws in one frame, and from a second frame over a
        //   warm cache are pixel-identical to each other.
        // Why it exists: these two cases give up their reference-renderer pin, so
        //   nothing else would catch a cache whose hit path draws a mark somewhere the
        //   miss path did not. Self-agreement is a weak property, which is exactly why
        //   it is stated only where the strong one cannot apply.
        // Scenario: spec-first -- a pane repainting a line of marked CJK.
        for clusterCase in fallbackPlacementCases {
            let metrics = try #require(clusterCase.metrics())
            let plan = try fallbackParityPlan(clusterCase, occurrences: 1)
            let once = try renderRepeatedBitmap(plan: plan, metrics: metrics, frames: 1)
            let laterFrame = try renderRepeatedBitmap(plan: plan, metrics: metrics, frames: 2)
            let twice = try renderRepeatedBitmap(
                plan: try fallbackParityPlan(clusterCase, occurrences: 2),
                metrics: metrics,
                frames: 1
            )
            let cluster = try #require(firstTextCell(of: plan))
            let span = cellRect(
                row: 0,
                column: 0,
                columnCount: cluster.columnWidth,
                metrics: metrics
            )

            expectBitmap(laterFrame, matches: once, "\(clusterCase.name), on a later frame")
            #expect(
                twice.bytes(in: span) == once.bytes(in: span),
                "\(clusterCase.name) drew its first cell differently when repeated"
            )
        }
    }

    @Test("A combining mark lands on the side of the base its name says")
    func markLandsOnItsOwnSideOfTheBase() throws {
        // Intent: with a wide base, an above-mark's ink is entirely above the base
        //   glyph's topmost ink row, a below-mark's ink is entirely below the baseline,
        //   and neither moves the base glyph off the pixels a base-only render puts it on.
        // Why it exists: this is the half of the placement change a user can see. Before
        //   it, `CTLineDraw` under the flip drew U+0323 -- combining dot BELOW -- above
        //   the baseline, on the wrong side of its base, and pushed U+0301 so close to
        //   the base that it read as noise. Following the typeset positions puts both
        //   back, and this test fails against the pre-change placement.
        // Scenario: spec-first -- transliterated text where a dot-below distinguishes
        //   one letter from another.
        for clusterCase in fallbackPlacementCases {
            let metrics = try #require(clusterCase.metrics())
            let plan = try fallbackParityPlan(clusterCase, occurrences: 1)
            let cluster = try #require(firstTextCell(of: plan))
            let base = try #require(cluster.scalars.first)
            let basePlan = try makePlan(
                input: clusterCase.stylePrefix + String(base),
                columns: 12,
                rows: 1
            )

            let marked = try renderRepeatedBitmap(plan: plan, metrics: metrics, frames: 1)
            let baseOnly = try renderFallbackReferenceBitmap(plan: basePlan, metrics: metrics)
            let span = cellRect(
                row: 0,
                column: 0,
                columnCount: cluster.columnWidth,
                metrics: metrics
            )
            let baseInk = try #require(baseOnly.inkBounds(in: span))
            let markRows = span.y.filter { row in
                span.x.contains { column in
                    marked.pixel(x: column, yFromTop: row)
                        != baseOnly.pixel(x: column, yFromTop: row)
                }
            }

            #expect(
                markRows.isEmpty == false,
                "\(clusterCase.name) drew no mark beside its base"
            )
            // Everything the marked render puts outside the mark's own rows is the base
            // glyph, and it must be exactly where a base-only render puts it: the
            // contract moves the mark, not the base.
            let baseRows = span.y.filter { markRows.contains($0) == false }
            for row in baseRows {
                let rowRect = PixelRect(x: span.x, y: row..<(row + 1))
                #expect(
                    marked.bytes(in: rowRect) == baseOnly.bytes(in: rowRect),
                    "\(clusterCase.name) moved its base glyph on row \(row)"
                )
            }

            let where_ = "rows \(markRows.min() ?? -1)...\(markRows.max() ?? -1)"
            if clusterCase.name.contains("dot-below") {
                let baselineRow = Int(
                    (metrics.baselineOffset * metrics.displayScale).rounded()
                )
                let message = "\(clusterCase.name) put its below-mark at or above the "
                    + "baseline (\(where_), baseline row \(baselineRow))"
                #expect((markRows.min() ?? 0) > baselineRow, "\(message)")
            } else {
                let message = "\(clusterCase.name) put its above-mark at or below the "
                    + "base's topmost ink row (\(where_), base ink from "
                    + "\(baseInk.y.lowerBound))"
                #expect((markRows.max() ?? Int.max) < baseInk.y.lowerBound, "\(message)")
            }
        }
    }
}
