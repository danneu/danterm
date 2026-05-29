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

    private var buffer = Data()
    private var isOversized = false

    public init() {}

    public mutating func append(_ data: Data) -> [IpcFrameEvent] {
        var events: [IpcFrameEvent] = []
        for byte in data {
            if isOversized {
                if byte == 0x0A { isOversized = false }
                continue
            }
            if byte == 0x0A {
                events.append(.line(buffer))
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            if buffer.count == Self.maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                isOversized = true
                events.append(.oversized)
                continue
            }
            buffer.append(byte)
        }
        return events
    }
}
