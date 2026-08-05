// The shared row-labelling terminal fixture the editing, scroll-region, and region-scrollback
// suites build their cases on: a grid whose row N holds the single letter A, B, C, ... so a test
// can name what moved after an insert, a delete, or a scroll. Three suites had grown their own
// copy of it, two byte-identical and one a strict superset carrying a scrollback-budget knob.
// It lives in its own file rather than in TerminalGridAssertions, which is scoped to structural
// assertions about a grid; a fixture builder is not an assertion.
//
// Nothing but shared terminal fixture builders belongs here.
import Testing

@testable import TerminalCore

/// Builds a `columns`x`rows` terminal whose row N contains only the letter at `A + N`, leaving the
/// cursor at the end of the last label. File-scope on purpose: three suites call it unqualified,
/// and `sourceLocation` is threaded so a `#require` failure still points at the calling test.
func labeledTerminal(
    columns: Int,
    rows: Int,
    scrollbackBudgetBytes: Int = Terminal.productionScrollbackBudgetBytes,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Terminal {
    var terminal = try #require(
        Terminal(columns: columns, rows: rows, scrollbackBudgetBytes: scrollbackBudgetBytes),
        sourceLocation: sourceLocation
    )
    for row in 0..<rows {
        let label = Unicode.Scalar(65 + row)!
        terminal.feed(Array("\u{1B}[\(row + 1);1H".utf8))
        terminal.feed(Array(String(label).utf8))
    }
    return terminal
}
