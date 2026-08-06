// Thin CLI over the headless owner-queue occupancy probe. All logic lives in
// TerminalOccupancyProbeSupport so it can be unit-tested; this file only parses flags, picks
// an output format, and writes.
//
// Answers one question: how long does a single job hold `TerminalPTYHost`'s serial queue, and
// therefore how long can the main thread's fence wait behind it (docs/research/19). Reports
// wall-clock, not CPU, per that file's inverted rule -- an on-CPU instrument would understate
// exactly the jobs worth finding.
//
// Two output modes, from the same report so they cannot disagree: `--json` is what a later
// run diffs against, the default table is what a human reads to decide whether a diff is
// worth taking.
import Foundation
import TerminalOccupancyProbeSupport

func flagValue(_ name: String, default fallback: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count,
          let value = Int(CommandLine.arguments[index + 1])
    else { return fallback }
    return value
}

// The defaults live in the support module so a test can assert the depth really saturates;
// see `OccupancyProbeDefaults`. At 179 columns the corpus charges ~1,563 B/line, so the
// shipped 30,000 lines charge ~46.9 MB against the 16 MiB budget's ~15.7 MB arena -- ~3.0x,
// enough to stay saturated at narrower widths too. Over-feeding costs setup time only, since
// evicted rows are gone.
let columns = flagValue("--columns", default: OccupancyProbeDefaults.columns)
let rows = flagValue("--rows", default: OccupancyProbeDefaults.rows)
let lines = flagValue("--lines", default: OccupancyProbeDefaults.lines)
let iterations = flagValue("--iterations", default: OccupancyProbeDefaults.iterations)
let wantsJSON = CommandLine.arguments.contains("--json")

let report = runOccupancyProbe(
    columns: columns,
    rows: rows,
    lines: lines,
    iterations: iterations
)

if wantsJSON {
    // Serialized rather than interpolated: a hand-built JSON string is one unescaped
    // character away from output a consumer cannot parse, and case names are free text.
    let cases: [[String: Any]] = report.samples.map { sample in
        var entry: [String: Any] = [
            "case": sample.name,
            "iterations": sample.iterations,
            "meanMilliseconds": sample.meanMilliseconds,
            "minMilliseconds": sample.minMilliseconds,
            "maxMilliseconds": sample.maxMilliseconds,
            "milliseconds": sample.milliseconds,
        ]
        entry["operationsPerSecond"] = sample.operationsPerSecond ?? NSNull()
        return entry
    }
    let payload: [String: Any] = [
        "columns": report.columns,
        "rows": report.rows,
        "cellCount": report.cellCount,
        "historyRowCount": report.historyRowCount,
        "cases": cases,
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
    )
    print(String(decoding: data, as: UTF8.self))
} else {
    print("""

        owner-queue occupancy -- \(report.columns)x\(report.rows), \
        \(report.cellCount) cells, \(report.historyRowCount) history rows
        \(String(repeating: "-", count: 78))
        """)
    // Padded in Swift rather than with `String(format:)`: the `%-46@` width specifier is
    // silently ignored for `%@` arguments, which prints an unaligned table that still looks
    // deliberate.
    func column(_ text: String, width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
    func rightColumn(_ text: String, width: Int = 9) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    print(column("case", width: 48) + rightColumn("mean ms") + rightColumn("min") + rightColumn("max"))
    for sample in report.samples {
        print(
            column(sample.name, width: 48)
                + rightColumn(String(format: "%.2f", sample.meanMilliseconds))
                + rightColumn(String(format: "%.2f", sample.minMilliseconds))
                + rightColumn(String(format: "%.2f", sample.maxMilliseconds))
        )
    }
    print("""

        A 60Hz frame is 16.667 ms; a 120Hz frame is 8.333 ms. Occupancy above a frame is what
        the main thread's drain fence can wait behind (research/19/F8, research/19/F11).
        """)
    // Printed only for the held-Enter case, because it is the only one a user can repeat
    // faster than the queue serves it. macOS key repeat is 15/s by default and 66/s at the
    // fastest setting; a sustainable rate below those is research/19/F9's queueing knee.
    if let quiet = report.samples.first(where: { $0.name == OccupancyCase.searchHeldEnterQuiet.rawValue }) {
        let rate = quiet.operationsPerSecond
            .map { String(format: "%.1f presses/second", $0) }
            ?? "faster than this probe can time"
        print("""
            Held Enter sustains \(rate), against a macOS key repeat of 15/s (default) to 66/s
            (fastest). Below that range is the knee where latency variance is felt as chop.
            """)
    }
}
