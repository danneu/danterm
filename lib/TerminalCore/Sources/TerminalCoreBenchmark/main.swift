// Headless release-mode timing harness for Terminal.feed over length-framed corpus chunks.
import Dispatch
import Foundation
import TerminalCore

/// Measures the reducer without PTY, actor, app, or rendering overhead.
func measureFeed(chunks: [[UInt8]], iterations: Int) -> [UInt64] {
    (0..<iterations).map { _ in
        guard var terminal = Terminal(columns: 80, rows: 24) else {
            fatalError("fixed benchmark geometry must be valid")
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for chunk in chunks {
            terminal.feed(chunk)
        }
        return DispatchTime.now().uptimeNanoseconds - start
    }
}

/// Decodes unsigned 64-bit big-endian lengths followed by their exact fixture bytes.
func decodeChunks(_ data: Data) throws -> [[UInt8]] {
    var offset = 0
    var chunks: [[UInt8]] = []
    while offset < data.count {
        guard data.count - offset >= 8 else {
            throw BenchmarkError.truncatedLength
        }
        var length: UInt64 = 0
        for byte in data[offset..<(offset + 8)] {
            length = (length << 8) | UInt64(byte)
        }
        offset += 8
        guard length <= UInt64(data.count - offset) else {
            throw BenchmarkError.truncatedChunk
        }
        let end = offset + Int(length)
        chunks.append(Array(data[offset..<end]))
        offset = end
    }
    return chunks
}

/// Reports malformed framing without coupling the harness to the suite process.
enum BenchmarkError: Error {
    case truncatedLength
    case truncatedChunk
}

guard CommandLine.arguments.count == 2,
      let iterations = Int(CommandLine.arguments[1]),
      iterations >= 2 else {
    FileHandle.standardError.write(Data("usage: TerminalCoreBenchmark <iterations>=2\n".utf8))
    exit(2)
}

do {
    let chunks = try decodeChunks(FileHandle.standardInput.readDataToEndOfFile())
    let values = measureFeed(chunks: chunks, iterations: iterations)
    print("[\(values.map(String.init).joined(separator: ","))]")
} catch {
    FileHandle.standardError.write(Data("invalid benchmark input: \(error)\n".utf8))
    exit(2)
}
