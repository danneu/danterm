// The occupancy probe's flag surface, declared here rather than in `main.swift` so the gate can
// test it. Top-level code in an executable target cannot be imported, so a spec written there is
// a spec no suite can reach -- which is how `--iterations 0` came to exit 0 over a table of
// 0.00 ms readings and `--columns 1` came to trap with no output at all.
//
// Only the names, defaults, and ranges live here. Resolving them into a terminal is
// `makeOccupancyTerminal`'s job, and printing a refusal is `main.swift`'s.
import TerminalProbeArguments

/// The one declaration of what `TerminalOccupancyProbe` accepts.
public enum OccupancyProbeCommandLine {
    /// At least 2 columns and 1 row because that is the geometry `Terminal.init` accepts; below
    /// it `makeOccupancyTerminal` traps, which reports the mistake as a crash.
    public static let columns = IntegerFlag(
        "--columns", default: OccupancyProbeDefaults.columns, minimum: 2
    )
    public static let rows = IntegerFlag(
        "--rows", default: OccupancyProbeDefaults.rows, minimum: 1
    )
    public static let lines = IntegerFlag(
        "--lines", default: OccupancyProbeDefaults.lines, minimum: 1
    )
    /// At least one iteration: a zero-iteration run has no measurement to report, and the table
    /// it prints is indistinguishable from a terminal that answered instantly.
    public static let iterations = IntegerFlag(
        "--iterations", default: OccupancyProbeDefaults.iterations, minimum: 1
    )
    public static let json = SwitchFlag("--json")

    public static let command = ProbeCommand(
        usage: """
            usage: TerminalOccupancyProbe [--columns <n>] [--rows <n>] [--lines <n>] \
            [--iterations <n>] [--json]

            """,
        flags: [
            .integer(columns), .integer(rows), .integer(lines), .integer(iterations),
            .toggle(json),
        ]
    )
}
