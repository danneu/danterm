// The memory probe's flag surface and the resolution of those flags into probe inputs, declared
// here rather than in `main.swift` so the gate can test them. Top-level code in an executable
// target cannot be imported, so a spec written there is a spec no suite can reach -- which is how
// `--columns eighty` came to measure 179 columns and print a header naming 179 as if asked for.
//
// The payload-name check lives here for the same reason it cannot live in TerminalProbeArguments:
// only `MemoryProbeMatrix` knows which names exist.
import TerminalCore
import TerminalProbeArguments

/// The one declaration of what `TerminalMemoryProbe` accepts.
public enum MemoryProbeCommandLine {
    /// The bounds come from the engine rather than from a number written here, so the flag
    /// cannot drift away from the geometry `Terminal.init` will actually build.
    public static let columns = IntegerFlag(
        "--columns", default: 179, minimum: Terminal.minimumColumns
    )
    public static let rows = IntegerFlag("--rows", default: 66, minimum: Terminal.minimumRows)
    public static let lines = IntegerFlag(
        "--lines", default: MemoryProbeMatrix.scrollbackLineCount, minimum: 1
    )
    /// Minimum zero, not one: `--chunk 0` is the documented single-shot mode. A negative value
    /// used to reach that same mode through the old parse without saying so, which silently
    /// changed the run from measuring a resident terminal to measuring one huge parse.
    public static let chunk = IntegerFlag("--chunk", default: defaultFeedChunkBytes, minimum: 0)
    public static let payload = TextFlag("--payload")
    public static let json = SwitchFlag("--json")
    public static let vmmap = SwitchFlag("--vmmap")

    public static let command = ProbeCommand(
        usage: """
            usage: TerminalMemoryProbe [--columns <n>] [--rows <n>] [--lines <n>] \
            [--chunk <bytes>] [--payload <name>] [--json] [--vmmap]

            """,
        flags: [
            .integer(columns), .integer(rows), .integer(lines), .integer(chunk),
            .text(payload), .toggle(json), .toggle(vmmap),
        ]
    )
}

/// Everything the probe run needs, with each flag already resolved against what the matrix holds.
///
/// A value of this type is the proof that the argument list named a payload the matrix can build
/// and a geometry a terminal can represent; nothing downstream re-checks either.
public struct MemoryProbeInputs: Sendable, Equatable {
    public let columns: Int
    public let rows: Int
    public let lineCount: Int
    /// `nil` restores single-shot feeding, which `--chunk 0` selects.
    public let chunkBytes: Int?
    /// `nil` runs the whole matrix, which no payload name can spell.
    public let payloadName: String?
    public let wantsJSON: Bool
    public let wantsVmmap: Bool
}

/// Turns a parsed argument list into probe inputs, or into the refusal to print before exiting.
///
/// The payload name is checked at `lineCount: 1`, so it never materializes the ~2 MB of payload
/// bytes the full matrix would build and throw away -- the process that measures one payload's
/// footprint delta should not have allocated the other five first. The known-name list is built
/// only on the failure path, where nothing is about to be measured.
public func resolveMemoryProbeInputs(
    _ arguments: ProbeArguments
) -> Result<MemoryProbeInputs, ProbeArgumentError> {
    let columns = arguments[MemoryProbeCommandLine.columns]
    let chunk = arguments[MemoryProbeCommandLine.chunk]
    let payloadName = arguments[MemoryProbeCommandLine.payload]

    if let payloadName {
        let matched = MemoryProbeMatrix.payloads(columns: columns, lineCount: 1, named: payloadName)
        guard matched.isEmpty == false else {
            let known = MemoryProbeMatrix.payloads(columns: columns, lineCount: 1).map(\.name)
            return .failure(ProbeArgumentError(
                flag: MemoryProbeCommandLine.payload.name,
                reason: .notAllowed(value: payloadName, allowed: known),
                usage: MemoryProbeCommandLine.command.usage
            ))
        }
    }

    return .success(MemoryProbeInputs(
        columns: columns,
        rows: arguments[MemoryProbeCommandLine.rows],
        lineCount: arguments[MemoryProbeCommandLine.lines],
        chunkBytes: chunk > 0 ? chunk : nil,
        payloadName: payloadName,
        wantsJSON: arguments[MemoryProbeCommandLine.json],
        wantsVmmap: arguments[MemoryProbeCommandLine.vmmap]
    ))
}
