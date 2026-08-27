// The measured cases themselves: the jobs `research/19/F1` found unbounded on
// `TerminalPTYHost`'s serial queue, priced at a realistic history depth.
//
// Measures `Terminal` methods directly rather than driving the host. That is legitimate here
// rather than a shortcut, and `research/19/F5` says why: these jobs run *synchronously* on the
// owner queue, so a job's duration is its occupancy, and interposing the queue would only add
// its own overhead to the reading.
//
// What this file cannot do is reproduce a number from a revision that no longer exists. The
// 99.3 ms held-Enter baseline in `research/19/F11` was measured before `257bfee` and is only
// re-derivable by checking that commit out. This probe exists so the *next* change does not
// inherit the same problem.
import TerminalCore
import TerminalProbeArguments

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
    public static let iterations = PositiveCount.declared(40)
}

/// Names each measured case so a reader can map a row back to the job it prices.
public enum OccupancyCase: String, Sendable, CaseIterable {
    case searchNewNeedle = "search: first press on a new needle"
    case searchIncrementalNeedle = "search: type one needle incrementally"
    case searchHeldEnterQuiet = "search: held Enter, quiet pane"
    case searchHeldEnterStreaming = "search: Enter, output arriving between presses"
    case selectAll = "select-all (Cmd-A)"
    case resize = "resize / reflow (one width change)"
}

/// Runs every case against one saturated pane and returns the report.
///
/// Cases share a pane on purpose: building a saturated history is the expensive part, and
/// `research/19/F5`'s copy-on-write control established that mutating a uniquely-owned terminal in
/// place does not charge the job for a copy. Nothing here keeps a second live reference to
/// the terminal, which is the condition that control depended on -- do not introduce one.
public func runOccupancyProbe(
    columns: Int,
    rows: Int,
    lines: Int,
    iterations: PositiveCount
) -> OccupancyReport {
    var terminal = makeOccupancyTerminal(columns: columns, rows: rows, lines: lines)
    let census = terminal.memoryCensus
    let cellCount = census.cellCount
    let historyRowCount = terminal.scrollbackRowCount
    var nextLine = lines
    var samples: [OccupancySample] = []

    // Every case is timed through this, so the first measurement is always taken separately and
    // the sample it builds is never empty. `iterations` being a `PositiveCount` is what makes
    // that total: there is no run with no first step to take.
    func measure(_ name: OccupancyCase, _ step: (Int) -> Double) -> OccupancySample {
        let first = step(0)
        var rest: [Double] = []
        rest.reserveCapacity(iterations.value - 1)
        for index in 1..<iterations.value {
            rest.append(step(index))
        }
        return OccupancySample(name: name.rawValue, first: first, rest: rest)
    }

    // A distinct needle per iteration, so no cache can serve the next one. This is the cost
    // that survives any memoization: something has to scan the history once.
    samples.append(
        measure(.searchNewNeedle) { step in
            measureOccupancyMilliseconds { _ = terminal.beginSearch("NEEDLE_\(step)") }
        }
    )

    // Type the corpus's shared needle as a find field does. Each sample is the summed
    // occupancy of the whole sequence: one required full scan followed by append refines.
    let incrementalNeedle = "NEEDLE_"
    samples.append(
        measure(.searchIncrementalNeedle) { _ in
            measureOccupancyMilliseconds {
                for end in incrementalNeedle.indices.dropFirst() {
                    _ = terminal.beginSearch(String(incrementalNeedle[..<end]))
                }
                _ = terminal.beginSearch(incrementalNeedle)
            }
        }
    )

    // The reported symptom (`research/19/F9`): the needle is unchanged and only the selection moves.
    // Both halves of the job are measured together because `applySearch` pays both on every
    // mutation -- `searchNext` and then `searchReadout` for the overlay's counter.
    _ = terminal.beginSearch("NEEDLE_")
    samples.append(
        measure(.searchHeldEnterQuiet) { _ in
            measureOccupancyMilliseconds {
                _ = terminal.searchNext()
                _ = terminal.searchReadout?.status
            }
        }
    )

    // The same presses with output landing in between, which is what a tailing pane does.
    // The feed is outside the bracket: this measures the search, not the parse.
    samples.append(
        measure(.searchHeldEnterStreaming) { _ in
            feedOccupancyCorpus(into: &terminal, from: nextLine, count: 20)
            nextLine += 20
            return measureOccupancyMilliseconds {
                _ = terminal.searchNext()
                _ = terminal.searchReadout?.status
            }
        }
    )

    // Cmd-A walks the same projection search does, without needing a needle (`research/19/F1`).
    samples.append(
        measure(.selectAll) { _ in
            terminal.clearSelection()
            return measureOccupancyMilliseconds { terminal.selectAll() }
        }
    )

    // Alternating widths, because a resize to the current width is not a reflow. One step of
    // a live window or split drag looks like this; its *rate* during a drag is `research/19/H2` and is
    // still unmeasured.
    samples.append(
        measure(.resize) { step in
            let width = step % 2 == 0 ? columns - 1 : columns
            return measureOccupancyMilliseconds { terminal.resize(columns: width, rows: rows) }
        }
    )

    return OccupancyReport(
        columns: columns,
        rows: rows,
        cellCount: cellCount,
        historyRowCount: historyRowCount,
        samples: samples
    )
}
