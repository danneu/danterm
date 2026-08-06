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
import TerminalRetainedRowProbeSupport

var columns = 179
var rows = 66
var stimulus = "stdin"
var arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: TerminalRetainedRowProbe [--columns <n>] [--rows <n>] [--stimulus <name>] < framed-chunks\n"

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(code)
}

while arguments.isEmpty == false {
    guard arguments.count >= 2 else { fail(usage, code: 2) }
    switch arguments[0] {
    case "--columns":
        guard let value = Int(arguments[1]), value >= 1 else { fail(usage, code: 2) }
        columns = value
    case "--rows":
        guard let value = Int(arguments[1]), value >= 1 else { fail(usage, code: 2) }
        rows = value
    case "--stimulus":
        stimulus = arguments[1]
    default:
        fail(usage, code: 2)
    }
    arguments.removeFirst(2)
}

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
