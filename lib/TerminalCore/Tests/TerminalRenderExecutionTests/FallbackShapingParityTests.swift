// Pixel parity between the executor's fallback cells and a test-only copy of the
// pre-cache draw path, plus the containment those cells owe their neighbours.
//
// The suite exists to survive a change of mechanism: whatever the executor does with a
// cluster it cannot batch -- typeset it per cell, or shape it once and replay it -- the
// bitmap must equal what an attributed string and `CTLineDraw` produce. Drawing the same
// cluster twice, and drawing a frame twice, are separate cases because a memo can agree
// with itself and still disagree with the path it replaced.
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
/// reads back which of the three exceptional conditions each case's line actually carries
/// and fails when one of them is claimed by nobody, so a case that stops producing the
/// condition it was chosen for is replaced rather than assumed.
let fallbackClusterCases: [FallbackClusterCase] = [
    FallbackClusterCase(name: "CJK", text: "\u{6F22}"),
    FallbackClusterCase(name: "colour emoji", text: "\u{1F600}"),
    FallbackClusterCase(name: "ZWJ sequence", text: "\u{1F469}\u{200D}\u{1F4BB}"),
    FallbackClusterCase(name: "combining marks", text: "e\u{0301}\u{0304}"),
    FallbackClusterCase(name: "wide base with combining mark", text: "\u{6F22}\u{0301}"),
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

/// The three conditions that stop a shaped cluster from being an ordinary batched entry.
enum ExceptionalClusterCondition: CaseIterable, CustomStringConvertible {
    case multipleRuns
    case nonIdentityRunMatrix
    case inkOutsideCellSpan

    var description: String {
        switch self {
        case .multipleRuns: "more than one run"
        case .nonIdentityRunMatrix: "kCTRunStatusHasNonIdentityMatrix"
        case .inkOutsideCellSpan: "ink outside the cell span"
        }
    }
}

struct FallbackShapingParityTests {
    @Test(
        "A fallback cluster renders exactly what the pre-cache path drew",
        arguments: fallbackClusterCases,
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
        // Intent: across the parity set, each of the three conditions that keep a shaped
        //   cluster out of an ordinary batch -- more than one run, a run matrix, ink
        //   outside the cell span -- is carried by at least one case's typeset line.
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

    /// The plan the parity cases render: the cluster, in the case's style, at the start
    /// of the row and again far enough along that the two cannot share a cell.
    private func fallbackParityPlan(
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
    private func firstTextCell(of plan: RenderFramePlan) -> RenderTextCell? {
        for run in plan.textRuns {
            for cell in run.cells where cell.scalars.isEmpty == false { return cell }
        }
        return nil
    }

    /// Which of the three exceptional conditions this cell's typeset line carries.
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
