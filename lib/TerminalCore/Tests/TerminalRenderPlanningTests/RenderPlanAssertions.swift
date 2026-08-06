// Shared canonical-form assertions for focused planner cases and the corpus sweep.
import Testing

@testable import TerminalRenderPlanning

// `comment` exists for the corpus sweep: it calls this once per fixture event, so a
// bare failure would point at the loop rather than at which fixture and event index
// produced the non-canonical plan. Focused tests leave it nil.
func assertCanonical(
    _ plan: RenderFramePlan,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(plan.columns >= 2, comment, sourceLocation: sourceLocation)
    #expect(plan.rows >= 1, comment, sourceLocation: sourceLocation)

    var previousBackground: RenderBackgroundRun?
    for run in plan.backgroundRuns {
        #expect(run.row >= 0 && run.row < plan.rows, comment, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, comment, sourceLocation: sourceLocation)
        #expect(run.columnCount > 0, comment, sourceLocation: sourceLocation)
        #expect(run.color != plan.defaultBackground, comment, sourceLocation: sourceLocation)
        #expect(run.startColumn + run.columnCount <= plan.columns, comment, sourceLocation: sourceLocation)
        if let previousBackground {
            #expect(
                run.row > previousBackground.row
                    || (run.row == previousBackground.row
                        && run.startColumn >= previousBackground.startColumn
                            + previousBackground.columnCount),
                comment,
                sourceLocation: sourceLocation
            )
            #expect(
                run.row != previousBackground.row
                    || run.startColumn != previousBackground.startColumn
                        + previousBackground.columnCount
                    || run.color != previousBackground.color,
                comment,
                sourceLocation: sourceLocation
            )
        }
        previousBackground = run
    }

    var previousOverlay: RenderOverlayRun?
    for run in plan.overlayRuns {
        #expect(run.row >= 0 && run.row < plan.rows, comment, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, comment, sourceLocation: sourceLocation)
        #expect(run.columnCount > 0, comment, sourceLocation: sourceLocation)
        #expect(run.startColumn + run.columnCount <= plan.columns, comment, sourceLocation: sourceLocation)
        if let previousOverlay {
            #expect(
                run.row > previousOverlay.row
                    || (run.row == previousOverlay.row
                        && run.startColumn >= previousOverlay.startColumn
                            + previousOverlay.columnCount),
                comment,
                sourceLocation: sourceLocation
            )
            #expect(
                run.row != previousOverlay.row
                    || run.startColumn != previousOverlay.startColumn
                        + previousOverlay.columnCount
                    || run.state != previousOverlay.state
                    || run.color != previousOverlay.color,
                comment,
                sourceLocation: sourceLocation
            )
        }
        previousOverlay = run
    }

    var previousText: RenderTextRun?
    for run in plan.textRuns {
        let width = run.cells.reduce(0) { $0 + $1.columnWidth }
        #expect(run.row >= 0 && run.row < plan.rows, comment, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, comment, sourceLocation: sourceLocation)
        #expect(run.cells.isEmpty == false, comment, sourceLocation: sourceLocation)
        // A text run exists to carry glyphs, so a payload-free cell in one would draw
        // nothing while still consuming grid columns. The planner filters empty cells
        // out; this holds that filter to the whole corpus rather than one test's runs.
        #expect(
            run.cells.allSatisfy { $0.scalars.isEmpty == false },
            comment,
            sourceLocation: sourceLocation
        )
        #expect(
            run.cells.allSatisfy { $0.columnWidth == 1 || $0.columnWidth == 2 },
            comment,
            sourceLocation: sourceLocation
        )
        #expect(run.startColumn + width <= plan.columns, comment, sourceLocation: sourceLocation)
        if let previousText {
            let previousWidth = previousText.cells.reduce(0) { $0 + $1.columnWidth }
            #expect(
                run.row > previousText.row
                    || (run.row == previousText.row
                        && run.startColumn >= previousText.startColumn + previousWidth),
                comment,
                sourceLocation: sourceLocation
            )
            #expect(
                run.row != previousText.row
                    || run.startColumn != previousText.startColumn + previousWidth
                    || run.foreground != previousText.foreground
                    || run.bold != previousText.bold
                    || run.italic != previousText.italic,
                comment,
                sourceLocation: sourceLocation
            )
        }
        previousText = run
    }

    var previousDecoration: RenderDecorationRun?
    for run in plan.decorationRuns {
        #expect(run.row >= 0 && run.row < plan.rows, comment, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, comment, sourceLocation: sourceLocation)
        #expect(run.columnCount > 0, comment, sourceLocation: sourceLocation)
        #expect(run.kinds.isEmpty == false, comment, sourceLocation: sourceLocation)
        #expect(run.startColumn + run.columnCount <= plan.columns, comment, sourceLocation: sourceLocation)
        if let previousDecoration {
            #expect(
                run.row > previousDecoration.row
                    || (run.row == previousDecoration.row
                        && run.startColumn >= previousDecoration.startColumn
                            + previousDecoration.columnCount),
                comment,
                sourceLocation: sourceLocation
            )
            #expect(
                run.row != previousDecoration.row
                    || run.startColumn != previousDecoration.startColumn
                        + previousDecoration.columnCount
                    || run.kinds != previousDecoration.kinds
                    || run.color != previousDecoration.color
                    || run.strikethroughColor != previousDecoration.strikethroughColor,
                comment,
                sourceLocation: sourceLocation
            )
        }
        previousDecoration = run
    }

    if let cursor = plan.cursor {
        #expect(cursor.row >= 0 && cursor.row < plan.rows, comment, sourceLocation: sourceLocation)
        #expect(cursor.column >= 0, comment, sourceLocation: sourceLocation)
        #expect(cursor.columnWidth == 1 || cursor.columnWidth == 2, comment, sourceLocation: sourceLocation)
        #expect(cursor.column + cursor.columnWidth <= plan.columns, comment, sourceLocation: sourceLocation)
    }
}
