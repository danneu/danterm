// The stimulus half of the occupancy probe: the synthetic shell output every measured case
// runs against, and the saturated terminal built from it.
//
// Separate from the measurement so the corpus can be asserted (see
// TerminalOccupancyProbeSupportTests) while the wall-clock bracket stays untestable and thin.
// Deliberately matches `scripts/saturate-scrollback.sh` line for line -- that script is the
// live-app version of this stimulus, and doc 19 compares felt behavior there against measured
// behavior here. If one changes, both must.
import TerminalCore

/// Renders one line of the corpus: sparse needles, cycling widths, stable across runs.
///
/// The needle cadence and the width cycle are load-bearing rather than cosmetic and are
/// pinned by tests -- a corpus where every row matched, or where every row was the same
/// width, would price a different job and still report plausible milliseconds.
public func occupancyCorpusLine(_ index: Int) -> String {
    let width = 40 + (index % 7) * 20
    var body = ""
    while body.count < width { body += "abcdefghij" }
    return index % 97 == 0
        ? "\(index)  \(body) NEEDLE_\(index)\n"
        : "\(index)  \(body)\n"
}

/// Feeds `count` corpus lines starting at `from` in one call.
///
/// Batched rather than per line because feeding is not what is being measured, and a
/// per-line feed would dominate the setup time of every case.
public func feedOccupancyCorpus(into terminal: inout Terminal, from: Int, count: Int) {
    var payload = ""
    for index in from..<(from + count) { payload += occupancyCorpusLine(index) }
    terminal.feed(Array(payload.utf8))
}

/// Builds a terminal whose scrollback has been driven to the production budget
/// (`Terminal.scrollbackByteLimit`).
///
/// Uses `Terminal`'s public initializer on purpose, so the budget is the one the app ships
/// rather than a test-sized one: the whole point of this probe is the depth a real pane
/// reaches, and `research/19/F5` and `research/19/F11` are only comparable at that budget.
public func makeOccupancyTerminal(columns: Int, rows: Int, lines: Int) -> Terminal {
    guard var terminal = Terminal(columns: columns, rows: rows) else {
        preconditionFailure("occupancy probe requires a representable geometry")
    }
    feedOccupancyCorpus(into: &terminal, from: 0, count: lines)
    return terminal
}
