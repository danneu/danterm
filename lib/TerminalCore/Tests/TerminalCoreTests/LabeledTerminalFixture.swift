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
    scrollbackBudgetBytes: Int = Terminal.scrollbackByteLimit,
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

/// Builds a terminal holding `lines` full-width plain-text history lines -- the corpus the two
/// history-projection cost tests (`primaryHistoryTextStaysLinear`,
/// `tailReadCostTracksTheBudgetNotTheCapacity`) compare a small history against a large one on.
/// Both want the same thing from it: retained character count proportional to `lines` and nothing
/// else varying between the two sizes, so it must stay a plain unstyled corpus. `rows` is small by
/// default because a viewport wider than a handful of rows only adds scroll shuffling to the build,
/// which neither test measures.
func historyProjectionTerminal(
    lines: Int,
    columns: Int = 200,
    rows: Int = 4,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Terminal {
    var terminal = try #require(
        Terminal(columns: columns, rows: rows),
        sourceLocation: sourceLocation
    )
    let line = Array((String(repeating: "abcdefghij", count: 19) + " end\r\n").utf8)
    for _ in 0..<lines { terminal.feed(line) }
    return terminal
}
