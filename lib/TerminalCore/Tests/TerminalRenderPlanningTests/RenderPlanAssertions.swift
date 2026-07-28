// Shared canonical-form assertions for focused planner cases and the corpus sweep.
import Testing

@testable import TerminalRenderPlanning

func assertCanonical(
    _ plan: RenderFramePlan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(plan.columns >= 2, sourceLocation: sourceLocation)
    #expect(plan.rows >= 1, sourceLocation: sourceLocation)

    var previousBackground: RenderBackgroundRun?
    for run in plan.backgroundRuns {
        #expect(run.row >= 0 && run.row < plan.rows, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, sourceLocation: sourceLocation)
        #expect(run.columnCount > 0, sourceLocation: sourceLocation)
        #expect(run.color != plan.defaultBackground, sourceLocation: sourceLocation)
        #expect(run.startColumn + run.columnCount <= plan.columns, sourceLocation: sourceLocation)
        if let previousBackground {
            #expect(
                run.row > previousBackground.row
                    || (run.row == previousBackground.row
                        && run.startColumn >= previousBackground.startColumn
                            + previousBackground.columnCount),
                sourceLocation: sourceLocation
            )
            #expect(
                run.row != previousBackground.row
                    || run.startColumn != previousBackground.startColumn
                        + previousBackground.columnCount
                    || run.color != previousBackground.color,
                sourceLocation: sourceLocation
            )
        }
        previousBackground = run
    }

    var previousSelection: RenderSelectionRun?
    for run in plan.selectionRuns {
        #expect(run.row >= 0 && run.row < plan.rows, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, sourceLocation: sourceLocation)
        #expect(run.columnCount > 0, sourceLocation: sourceLocation)
        #expect(run.startColumn + run.columnCount <= plan.columns, sourceLocation: sourceLocation)
        if let previousSelection {
            #expect(
                run.row > previousSelection.row
                    || (run.row == previousSelection.row
                        && run.startColumn >= previousSelection.startColumn
                            + previousSelection.columnCount),
                sourceLocation: sourceLocation
            )
        }
        previousSelection = run
    }

    var previousMatch: RenderSelectionRun?
    for run in plan.searchMatchRuns {
        #expect(run.row >= 0 && run.row < plan.rows, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, sourceLocation: sourceLocation)
        #expect(run.columnCount > 0, sourceLocation: sourceLocation)
        #expect(run.startColumn + run.columnCount <= plan.columns, sourceLocation: sourceLocation)
        if let previousMatch {
            #expect(
                run.row > previousMatch.row
                    || (run.row == previousMatch.row
                        && run.startColumn >= previousMatch.startColumn
                            + previousMatch.columnCount),
                sourceLocation: sourceLocation
            )
        }
        previousMatch = run
    }

    var previousText: RenderTextRun?
    for run in plan.textRuns {
        let width = run.cells.reduce(0) { $0 + $1.columnWidth }
        #expect(run.row >= 0 && run.row < plan.rows, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, sourceLocation: sourceLocation)
        #expect(run.cells.isEmpty == false, sourceLocation: sourceLocation)
        // A text run exists to carry glyphs, so a payload-free cell in one would draw
        // nothing while still consuming grid columns. The planner filters empty cells
        // out; this holds that filter to the whole corpus rather than one test's runs.
        #expect(
            run.cells.allSatisfy { $0.scalars.isEmpty == false },
            sourceLocation: sourceLocation
        )
        #expect(run.cells.allSatisfy { $0.columnWidth == 1 || $0.columnWidth == 2 }, sourceLocation: sourceLocation)
        #expect(run.startColumn + width <= plan.columns, sourceLocation: sourceLocation)
        if let previousText {
            let previousWidth = previousText.cells.reduce(0) { $0 + $1.columnWidth }
            #expect(
                run.row > previousText.row
                    || (run.row == previousText.row
                        && run.startColumn >= previousText.startColumn + previousWidth),
                sourceLocation: sourceLocation
            )
            #expect(
                run.row != previousText.row
                    || run.startColumn != previousText.startColumn + previousWidth
                    || run.foreground != previousText.foreground
                    || run.bold != previousText.bold
                    || run.italic != previousText.italic,
                sourceLocation: sourceLocation
            )
        }
        previousText = run
    }

    var previousDecoration: RenderDecorationRun?
    for run in plan.decorationRuns {
        #expect(run.row >= 0 && run.row < plan.rows, sourceLocation: sourceLocation)
        #expect(run.startColumn >= 0, sourceLocation: sourceLocation)
        #expect(run.columnCount > 0, sourceLocation: sourceLocation)
        #expect(run.kinds.isEmpty == false, sourceLocation: sourceLocation)
        #expect(run.startColumn + run.columnCount <= plan.columns, sourceLocation: sourceLocation)
        if let previousDecoration {
            #expect(
                run.row > previousDecoration.row
                    || (run.row == previousDecoration.row
                        && run.startColumn >= previousDecoration.startColumn
                            + previousDecoration.columnCount),
                sourceLocation: sourceLocation
            )
            #expect(
                run.row != previousDecoration.row
                    || run.startColumn != previousDecoration.startColumn
                        + previousDecoration.columnCount
                    || run.kinds != previousDecoration.kinds
                    || run.color != previousDecoration.color
                    || run.strikethroughColor != previousDecoration.strikethroughColor,
                sourceLocation: sourceLocation
            )
        }
        previousDecoration = run
    }

    if let cursor = plan.cursor {
        #expect(cursor.row >= 0 && cursor.row < plan.rows, sourceLocation: sourceLocation)
        #expect(cursor.column >= 0, sourceLocation: sourceLocation)
        #expect(cursor.columnWidth == 1 || cursor.columnWidth == 2, sourceLocation: sourceLocation)
        #expect(cursor.column + cursor.columnWidth <= plan.columns, sourceLocation: sourceLocation)
    }
}
