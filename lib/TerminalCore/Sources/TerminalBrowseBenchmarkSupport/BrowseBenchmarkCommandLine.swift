// The browse benchmark's flag surface, declared here rather than in `main.swift` so the gate can
// test it. Top-level code in an executable target cannot be imported, so a spec written there is
// a spec no suite can reach.
import TerminalProbeArguments

/// The one declaration of what `TerminalBrowseBenchmark` accepts.
public enum BrowseBenchmarkCommandLine {
    /// At least one measured frame: a zero-frame block has nothing to normalize, and the
    /// collector pairs whatever number it prints.
    public static let measured = IntegerFlag("--measured", default: 2_000, minimum: 1)

    /// Which stimulus the block times; the identity it prints names the one it got.
    public static let workload = TextFlag(
        "--workload", default: "retained-browse", allowed: ["retained-browse", "search-dense"]
    )

    public static let command = ProbeCommand(
        usage: "usage: TerminalBrowseBenchmark [--measured <count>] [--workload retained-browse|search-dense]\n",
        flags: [.integer(measured), .text(workload)]
    )

    /// Maps a parsed `--workload` value to its stimulus.
    public static func stimulus(named name: String?) -> BrowseBenchmarkStimulus {
        name == "search-dense" ? .searchDense : .standard
    }
}
