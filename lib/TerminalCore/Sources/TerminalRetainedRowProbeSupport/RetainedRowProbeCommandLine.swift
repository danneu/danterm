// The retained-row probe's flag surface, declared here rather than in `main.swift` so the gate
// can test it. Top-level code in an executable target cannot be imported, so a spec written there
// is a spec no suite can reach.
import TerminalProbeArguments

/// The one declaration of what `TerminalRetainedRowProbe` accepts.
public enum RetainedRowProbeCommandLine {
    /// At least 2 columns and 1 row because that is the geometry `Terminal.init` accepts; below
    /// it `measureRetainedRowShape` returns nil two steps later, which reports a usage mistake as
    /// a measurement failure.
    public static let columns = IntegerFlag("--columns", default: 179, minimum: 2)
    public static let rows = IntegerFlag("--rows", default: 66, minimum: 1)
    /// Free text: the name is carried into the report to label whose bytes these were, and the
    /// driver picks it, so no closed set can be right here.
    public static let stimulus = TextFlag("--stimulus", default: "stdin")

    public static let command = ProbeCommand(
        usage: """
            usage: TerminalRetainedRowProbe [--columns <n>] [--rows <n>] [--stimulus <name>] \
            < framed-chunks

            """,
        flags: [.integer(columns), .integer(rows), .text(stimulus)]
    )
}
