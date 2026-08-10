// Research doc 33, task T1: sizes the parser's intermediate `[TerminalStreamAction]`
// array in situ. Compiled by `t1-action-array-size.py` into one module together with
// the unmodified `lib/TerminalCore/Sources/TerminalCore` sources, which is what gives
// it access to the internal `TerminalInputStream` without editing the engine.
//
// It holds only measurement: corpus framing is the driver's job, and nothing here may
// change what the parser does.
import Foundation

/// Records how a real `[TerminalStreamAction]` grows, so per-call allocation cost can be
/// derived from a token count instead of guessed from Swift's documented growth policy.
/// Built once by appending to an actual array of the actual element type, and checked
/// against every observed feed result before any number is reported.
struct ActionArrayGrowth {
    /// One growth event: appending the `count`th element moved capacity to `capacity`.
    struct Step {
        let count: Int
        let capacity: Int
    }

    let steps: [Step]
    let stride: Int

    init(upTo maximumCount: Int) {
        var steps: [Step] = []
        var array: [TerminalStreamAction] = []
        var lastCapacity = array.capacity
        var index = 0
        while index < maximumCount {
            index += 1
            array.append(.execute(0))
            if array.capacity != lastCapacity {
                lastCapacity = array.capacity
                steps.append(Step(count: index, capacity: lastCapacity))
            }
        }
        self.steps = steps
        stride = MemoryLayout<TerminalStreamAction>.stride
    }

    /// Allocation count, final capacity, and total bytes handed to the allocator for a
    /// feed call that produced `count` actions.
    func cost(forCount count: Int) -> (allocations: Int, capacity: Int, bytes: Int) {
        var allocations = 0
        var capacity = 0
        var bytes = 0
        for step in steps {
            guard step.count <= count else { break }
            allocations += 1
            capacity = step.capacity
            bytes += step.capacity * stride
        }
        return (allocations, capacity, bytes)
    }
}

/// One corpus's totals. Every aggregate carries the sample count that produced it, so a
/// corpus that fed nothing reads as zero feeds rather than as zero cost.
struct CorpusReport: Encodable {
    let name: String
    let feedCalls: Int
    let byteCount: Int
    let tokenCount: Int
    let tokensPerByte: Double
    let peakTokenCount: Int
    let peakCapacity: Int
    let peakLiveBytes: Int
    let totalBytesAllocated: Int
    let allocationCount: Int
    let reallocationCount: Int
    let capacityChecks: Int
    let capacityMismatches: Int
    let printActions: Int
    let executeActions: Int
    let escapeActions: Int
    let escapeSequenceActions: Int
    let csiActions: Int
    let oscActions: Int
}

/// Reads the driver's framing: repeated 8-byte big-endian length followed by that many
/// bytes. Identical to `decodeBenchmarkChunks`, restated here because this probe compiles
/// against `TerminalCore` alone.
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

/// Splits a chunk the way the PTY host delivers one, so the peak capacity can be reported
/// against production's delivery size as well as against the corpus's own framing. A
/// negative limit joins the whole corpus into one feed, which is the single-shot shape
/// `terminal-memory-probe --chunk 0` measures.
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

func measure(name: String, chunks: [[UInt8]], growth: ActionArrayGrowth) -> CorpusReport {
    var stream = TerminalInputStream()
    var byteCount = 0
    var tokenCount = 0
    var peakTokenCount = 0
    var peakCapacity = 0
    var totalBytes = 0
    var allocations = 0
    var checks = 0
    var mismatches = 0
    var prints = 0
    var executes = 0
    var escapes = 0
    var escapeSequences = 0
    var csis = 0
    var oscs = 0

    for chunk in chunks {
        byteCount += chunk.count
        let actions = stream.feed(chunk)
        let cost = growth.cost(forCount: actions.count)
        checks += 1
        // The returned array is the buffer `feed` built, so its live capacity is a direct
        // in-situ reading. Comparing it against the replayed growth table is what licenses
        // using that table for the intermediate steps nothing can observe after the fact.
        if actions.capacity != cost.capacity {
            mismatches += 1
        }
        tokenCount += actions.count
        peakTokenCount = max(peakTokenCount, actions.count)
        peakCapacity = max(peakCapacity, actions.capacity)
        totalBytes += cost.bytes
        allocations += cost.allocations
        for action in actions {
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

    return CorpusReport(
        name: name,
        feedCalls: chunks.count,
        byteCount: byteCount,
        tokenCount: tokenCount,
        tokensPerByte: byteCount == 0 ? 0 : Double(tokenCount) / Double(byteCount),
        peakTokenCount: peakTokenCount,
        peakCapacity: peakCapacity,
        peakLiveBytes: peakCapacity * growth.stride,
        totalBytesAllocated: totalBytes,
        allocationCount: allocations,
        reallocationCount: max(0, allocations - chunks.count),
        capacityChecks: checks,
        capacityMismatches: mismatches,
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
    let growthCapacities: [Int]
    let runs: [Run]
}

// Arguments: `<limit> <name>=<framed path> ...`, where a limit of 0 means the corpus's
// own framing is used unchanged.
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

let cappedInputs = inputs.map { (name: $0.name, chunks: capped($0.chunks, at: limit)) }
let maximumChunkBytes = cappedInputs.flatMap(\.chunks).map(\.count).max() ?? 0
// A chunk can produce at most one action per byte, so the table only has to reach the
// largest chunk fed.
let growth = ActionArrayGrowth(upTo: max(1, maximumChunkBytes))

let run = Run(
    chunkLimit: limit,
    corpora: cappedInputs.map { measure(name: $0.name, chunks: $0.chunks, growth: growth) }
)
let report = Report(
    actionStride: MemoryLayout<TerminalStreamAction>.stride,
    actionSize: MemoryLayout<TerminalStreamAction>.size,
    growthCapacities: growth.steps.map(\.capacity),
    runs: [run]
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(report))
FileHandle.standardOutput.write(Data([0x0A]))
