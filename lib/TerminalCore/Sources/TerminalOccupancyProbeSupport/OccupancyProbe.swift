// The measured cases themselves: the jobs doc 19's `F1` found unbounded on
// `TerminalPTYHost`'s serial queue, priced at a realistic history depth.
//
// Measures `Terminal` methods directly rather than driving the host. That is legitimate here
// rather than a shortcut, and doc 19's `F5` says why: these jobs run *synchronously* on the
// owner queue, so a job's duration is its occupancy, and interposing the queue would only add
// its own overhead to the reading.
//
// What this file cannot do is reproduce a number from a revision that no longer exists. The
// 99.3 ms held-Enter baseline in `19/F11` was measured before `257bfee` and is only
// re-derivable by checking that commit out. This probe exists so the *next* change does not
// inherit the same problem.
import TerminalCore

/// The run the probe binary performs when it is given no flags -- the geometry and depth
/// every number in doc 19 was measured at.
///
/// Lives here rather than as literals in `TerminalOccupancyProbe/main.swift` so the tests can
/// assert the shipped values themselves. `lines` in particular is a calibration constant: it
/// only means anything if it is large enough to drive `Terminal`'s production budget past
/// saturation, and that is checked against these constants rather than against a copy of them.
public enum OccupancyProbeDefaults {
    public static let columns = 179
    public static let rows = 66
    public static let lines = 30_000
    public static let iterations = 40
}

/// Names each measured case so a reader can map a row back to the job it prices.
public enum OccupancyCase: String, Sendable, CaseIterable {
    case searchNewNeedle = "search: first press on a new needle"
    case searchHeldEnterQuiet = "search: held Enter, quiet pane"
    case searchHeldEnterStreaming = "search: Enter, output arriving between presses"
    case selectAll = "select-all (Cmd-A)"
    case resize = "resize / reflow (one width change)"
}

/// Runs every case against one saturated pane and returns the report.
///
/// Cases share a pane on purpose: building a saturated history is the expensive part, and
/// `19/F5`'s copy-on-write control established that mutating a uniquely-owned terminal in
/// place does not charge the job for a copy. Nothing here keeps a second live reference to
/// the terminal, which is the condition that control depended on -- do not introduce one.
public func runOccupancyProbe(
    columns: Int,
    rows: Int,
    lines: Int,
    iterations: Int
) -> OccupancyReport {
    var terminal = makeOccupancyTerminal(columns: columns, rows: rows, lines: lines)
    let census = terminal.memoryCensus
    let cellCount = census.cellCount
    let historyRowCount = terminal.scrollbackRowCount
    var nextLine = lines
    var samples: [OccupancySample] = []

    // A distinct needle per iteration, so no cache can serve the next one. This is the cost
    // that survives any memoization: something has to scan the history once.
    var newNeedle: [Double] = []
    for step in 0..<iterations {
        newNeedle.append(measureOccupancyMilliseconds {
            _ = terminal.beginSearch("NEEDLE_\(step)")
        })
    }
    samples.append(OccupancySample(name: OccupancyCase.searchNewNeedle.rawValue, milliseconds: newNeedle))

    // The reported symptom (`19/F9`): the needle is unchanged and only the selection moves.
    // Both halves of the job are measured together because `applySearch` pays both on every
    // mutation -- `searchNext` and then `searchStatus` for the overlay's counter.
    _ = terminal.beginSearch("NEEDLE_")
    var quiet: [Double] = []
    for _ in 0..<iterations {
        quiet.append(measureOccupancyMilliseconds {
            _ = terminal.searchNext()
            _ = terminal.searchStatus
        })
    }
    samples.append(OccupancySample(name: OccupancyCase.searchHeldEnterQuiet.rawValue, milliseconds: quiet))

    // The same presses with output landing in between, which is what a tailing pane does.
    // The feed is outside the bracket: this measures the search, not the parse.
    var streaming: [Double] = []
    for _ in 0..<iterations {
        feedOccupancyCorpus(into: &terminal, from: nextLine, count: 20)
        nextLine += 20
        streaming.append(measureOccupancyMilliseconds {
            _ = terminal.searchNext()
            _ = terminal.searchStatus
        })
    }
    samples.append(
        OccupancySample(name: OccupancyCase.searchHeldEnterStreaming.rawValue, milliseconds: streaming)
    )

    // Cmd-A walks the same projection search does, without needing a needle (`19/F1`).
    var selectAll: [Double] = []
    for _ in 0..<iterations {
        terminal.clearSelection()
        selectAll.append(measureOccupancyMilliseconds { terminal.selectAll() })
    }
    samples.append(OccupancySample(name: OccupancyCase.selectAll.rawValue, milliseconds: selectAll))

    // Alternating widths, because a resize to the current width is not a reflow. One step of
    // a live window or split drag looks like this; its *rate* during a drag is `19/H2` and is
    // still unmeasured.
    var resize: [Double] = []
    for step in 0..<iterations {
        let width = step % 2 == 0 ? columns - 1 : columns
        resize.append(measureOccupancyMilliseconds { terminal.resize(columns: width, rows: rows) })
    }
    samples.append(OccupancySample(name: OccupancyCase.resize.rawValue, milliseconds: resize))

    return OccupancyReport(
        columns: columns,
        rows: rows,
        cellCount: cellCount,
        historyRowCount: historyRowCount,
        samples: samples
    )
}
