// Release-mode JSON entry point for the retained-row shape probe.
//
// Takes its stimulus as length-framed chunks on stdin -- the same framing
// `TerminalCoreBenchmark` reads -- rather than owning a corpus of its own. That is
// deliberate: `research/28/F9` asks how often *real* retained rows are blank, and a probe
// that generated its own content could be accused of shaping that content. The driver
// supplies committed, recorded bytes; this binary only reports what they produced.
//
// Kept to a thin argument parse so the derivation and the size-class arithmetic stay in
// the support target, where they are tested headlessly.
import Foundation
import TerminalCoreBenchmarkSupport
import TerminalProbeArguments
import TerminalRetainedRowProbeSupport

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(code)
}

// The flag surface is `RetainedRowProbeCommandLine`, in the support module, so the gate tests it.
let arguments: ProbeArguments
switch RetainedRowProbeCommandLine.command.parse(CommandLine.arguments.dropFirst()) {
case .success(let parsed):
    arguments = parsed
case .failure(let error):
    fail(error.report, code: 2)
}

let columns = arguments[RetainedRowProbeCommandLine.columns]
let rows = arguments[RetainedRowProbeCommandLine.rows]
let stimulus = arguments[RetainedRowProbeCommandLine.stimulus] ?? "stdin"

let chunks: [[UInt8]]
do {
    chunks = try decodeBenchmarkChunks(FileHandle.standardInput.readDataToEndOfFile())
} catch {
    fail("retained-row probe could not decode framed stdin: \(error)\n", code: 1)
}

guard
    let report = measureRetainedRowShape(
        stimulus: stimulus, chunks: chunks, columns: columns, rows: rows
    )
else {
    fail("retained-row probe rejected geometry \(columns)x\(rows)\n", code: 1)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
do {
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("retained-row probe failed to encode: \(error)\n", code: 1)
}
