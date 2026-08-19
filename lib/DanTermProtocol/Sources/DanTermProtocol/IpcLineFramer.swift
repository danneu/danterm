// Newline-delimited JSON-RPC line framing for DanTerm IPC: the pure transport primitive that
// turns a raw socket byte stream into whole `.line` frames and rejects oversized lines. Lives in
// DanTermProtocol because framing is a transport-protocol concern any IPC consumer shares; the
// socket lifecycle that drives it (IpcConnection) stays separate (core now, DanTermSupport at
// Phase 3). This is the ONLY `public` surface in the pure-core/support split -- pinned explicitly
// because a public struct does not export its members: init/append/maxLineBytes are promoted while
// the buffer state stays private. See plans/impl/2026-05-29-pure-core-portable-support.md (API policy).
import Foundation

public enum IpcFrameEvent: Equatable {
    case line(Data)
    case oversized
}

public struct IpcLineFramer {
    public static let maxLineBytes = 16 * 1024 * 1024

    /// Bytes of the pending line contributed by earlier chunks. A line that
    /// arrives whole inside one chunk never lands here: it is emitted as a
    /// slice of that chunk, so there is no second copy to disagree with it.
    private var carry = Data()
    private var isOversized = false

    public init() {}

    public mutating func append(_ data: Data) -> [IpcFrameEvent] {
        var events: [IpcFrameEvent] = []
        var index = data.startIndex
        while index < data.endIndex {
            let newline = Self.indexOfNewline(in: data, from: index)
            if isOversized {
                // Discard through the newline that resynchronizes the stream.
                guard let newline else { break }
                isOversized = false
                index = newline + 1
                continue
            }
            let segment = data[index..<(newline ?? data.endIndex)]
            if carry.count + segment.count > Self.maxLineBytes {
                events.append(.oversized)
                carry = Data()
                // A newline in this chunk already resynchronizes the stream, so
                // only a refusal with no newline left to find stays oversized.
                isOversized = newline == nil
                index = newline.map { $0 + 1 } ?? data.endIndex
                continue
            }
            guard let newline else {
                carry.append(segment)
                break
            }
            if carry.isEmpty {
                events.append(.line(segment))
            } else {
                carry.append(segment)
                events.append(.line(carry))
                carry = Data()
            }
            index = newline + 1
        }
        return events
    }

    /// Offset of the first newline at or after `start`, found with one `memchr`
    /// scan. `Data.firstIndex(of:)` resolves to the default per-element
    /// Collection loop, which is the byte-at-a-time shape this framer avoids.
    private static func indexOfNewline(in data: Data, from start: Data.Index) -> Data.Index? {
        guard start < data.endIndex else { return nil }
        let offset = start - data.startIndex
        let length = data.endIndex - start
        return data.withUnsafeBytes { raw -> Data.Index? in
            guard let base = raw.baseAddress else { return nil }
            guard let hit = memchr(base + offset, 0x0A, length) else { return nil }
            return data.startIndex + base.distance(to: hit)
        }
    }
}
