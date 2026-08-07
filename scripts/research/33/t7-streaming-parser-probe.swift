// Research doc 33, task T7: replays each committed corpus through the *streaming* parser.
//
// Compiled by `t7-streaming-parser.py` into one module together with the patched
// `lib/TerminalCore/Sources/TerminalCore` sources, which is what gives it access to the
// internal `TerminalInputStream.nextAction(in:from:)` without editing the engine. It exists
// to answer one question the memory and CPU instruments cannot: does the streaming parser
// recognize exactly the token stream the eager one did? `F9` recorded that stream per corpus,
// so this probe reports the same counts in the same shape and the driver compares them.
//
// It never collects the actions. The token count is a running integer, and `peakLiveActions`
// is the largest number of actions alive at once -- 1 by construction once nothing accumulates,
// which is the structural claim stated as a number the probe actually measures.
import Foundation

struct CorpusReport: Encodable {
    let name: String
    let feedCalls: Int
    let byteCount: Int
    let tokenCount: Int
    let tokensPerByte: Double
    let peakLiveActions: Int
    let printActions: Int
    let executeActions: Int
    let escapeActions: Int
    let escapeSequenceActions: Int
    let csiActions: Int
    let oscActions: Int
}

/// Reads the driver's framing: repeated 8-byte big-endian length followed by that many bytes.
/// Identical to `decodeBenchmarkChunks`, restated because this probe compiles against
/// `TerminalCore` alone.
func decodeFramedChunks(_ data: Data) -> [[UInt8]] {
    var chunks: [[UInt8]] = []
    var offset = data.startIndex
    while offset < data.endIndex {
        precondition(data.distance(from: offset, to: data.endIndex) >= 8, "truncated length")
        var length = 0
        for byte in data[offset..<data.index(offset, offsetBy: 8)] {
            length = (length << 8) | Int(byte)
        }
        offset = data.index(offset, offsetBy: 8)
        precondition(data.distance(from: offset, to: data.endIndex) >= length, "truncated chunk")
        let end = data.index(offset, offsetBy: length)
        chunks.append(Array(data[offset..<end]))
        offset = end
    }
    return chunks
}

/// Splits a chunk the way the PTY host delivers one. A negative limit joins the whole corpus
/// into one feed, which is the single-shot shape `terminal-memory-probe --chunk 0` measures.
func capped(_ chunks: [[UInt8]], at limit: Int) -> [[UInt8]] {
    if limit < 0 { return [chunks.flatMap { $0 }] }
    guard limit > 0 else { return chunks }
    var result: [[UInt8]] = []
    for chunk in chunks {
        var start = 0
        while start < chunk.count {
            let end = min(start + limit, chunk.count)
            result.append(Array(chunk[start..<end]))
            start = end
        }
    }
    return result
}

func measure(name: String, chunks: [[UInt8]]) -> CorpusReport {
    var stream = TerminalInputStream()
    var byteCount = 0
    var tokenCount = 0
    var peakLive = 0
    var prints = 0, executes = 0, escapes = 0, escapeSequences = 0, csis = 0, oscs = 0

    for chunk in chunks {
        byteCount += chunk.count
        chunk.withUnsafeBufferPointer { buffer in
            var index = 0
            while let action = stream.nextAction(in: buffer, from: &index) {
                // One action is alive here and nowhere else; nothing appends it anywhere.
                peakLive = max(peakLive, 1)
                tokenCount += 1
                switch action {
                case .print: prints += 1
                case .execute: executes += 1
                case .escape: escapes += 1
                case .escapeSequence: escapeSequences += 1
                case .csi: csis += 1
                case .osc: oscs += 1
                }
            }
        }
    }

    return CorpusReport(
        name: name,
        feedCalls: chunks.count,
        byteCount: byteCount,
        tokenCount: tokenCount,
        tokensPerByte: byteCount == 0 ? 0 : Double(tokenCount) / Double(byteCount),
        peakLiveActions: peakLive,
        printActions: prints,
        executeActions: executes,
        escapeActions: escapes,
        escapeSequenceActions: escapeSequences,
        csiActions: csis,
        oscActions: oscs
    )
}

struct Run: Encodable {
    let chunkLimit: Int
    let corpora: [CorpusReport]
}

struct Report: Encodable {
    let actionStride: Int
    let actionSize: Int
    let runs: [Run]
}

// Arguments: `<limit> <name>=<framed path> ...`, where a limit of 0 means the corpus's own
// framing is used unchanged and a negative limit joins the corpus into one feed.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let limit = Int(arguments[0]) else {
    FileHandle.standardError.write(Data("usage: probe <chunk-limit> <name>=<path> ...\n".utf8))
    exit(2)
}

var inputs: [(name: String, chunks: [[UInt8]])] = []
for argument in arguments.dropFirst() {
    guard let separator = argument.firstIndex(of: "=") else {
        FileHandle.standardError.write(Data("expected <name>=<path>, got \(argument)\n".utf8))
        exit(2)
    }
    let name = String(argument[argument.startIndex..<separator])
    let path = String(argument[argument.index(after: separator)...])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    inputs.append((name, decodeFramedChunks(data)))
}

let report = Report(
    actionStride: MemoryLayout<TerminalStreamAction>.stride,
    actionSize: MemoryLayout<TerminalStreamAction>.size,
    runs: [
        Run(
            chunkLimit: limit,
            corpora: inputs.map { measure(name: $0.name, chunks: capped($0.chunks, at: limit)) }
        ),
    ]
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(report))
FileHandle.standardOutput.write(Data([0x0A]))
