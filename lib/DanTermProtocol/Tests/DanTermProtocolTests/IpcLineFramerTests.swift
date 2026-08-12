// Tests for IpcLineFramer, the newline-delimited JSON-RPC line-framing primitive that turns a raw
// socket byte stream into whole `.line` frames and rejects oversized lines: full-line emission,
// two-lines-in-one-read, split-frame reassembly, and oversized-line rejection. Moved here with the
// framer from DanTermCore in the pure-core/portable-support refactor (Phase 2); the IpcConnection
// socket class that drives the framer stays separate.
import Foundation
import Testing

@testable import DanTermProtocol

struct IpcLineFramerTests {
    @Test("one full line emits one frame")
    func oneFullLineEmitsOneFrame() throws {
        // Intent: a full JSON-RPC line emits exactly one .line event.
        // Why it exists: pins the happy framing path.
        // Scenario: spec-first single line.
        var framer = IpcLineFramer()
        let events = framer.append(ipcLine(#"{"jsonrpc":"2.0","id":1,"method":"ls"}"#))
        #expect(events.count == 1)
        let event = try #require(events.first)
        guard case .line(let line) = event else {
            Issue.record("expected line event")
            return
        }
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        #expect(request.method == IpcRequestMethod.ls.rawValue)
    }

    @Test("two full lines in one read emit two frames")
    func twoFullLinesInOneReadEmitTwoFrames() {
        // Intent: two full lines in one chunk emit two frames.
        // Why it exists: pins the multi-line case.
        // Scenario: spec-first two-lines.
        var framer = IpcLineFramer()
        var chunk = ipcLine(#"{"jsonrpc":"2.0","id":1,"method":"ls"}"#)
        chunk.append(ipcLine(#"{"jsonrpc":"2.0","id":2,"method":"tab.rename"}"#))
        let events = framer.append(chunk)
        #expect(events.count == 2)
    }

    @Test("split frame reassembles after second chunk")
    func splitFrameReassemblesAfterSecondChunk() throws {
        // Intent: a frame split across two chunks reassembles into one
        //   event.
        // Why it exists: pins the reassembly case.
        // Scenario: spec-first split frame.
        var framer = IpcLineFramer()
        #expect(framer.append(Data(#"{"jsonrpc":"#.utf8)).count == 0)
        let events = framer.append(ipcLine(#""2.0","id":1,"method":"ls"}"#))
        #expect(events.count == 1)
        let event = try #require(events.first)
        guard case .line(let line) = event else {
            Issue.record("expected line event")
            return
        }
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        #expect(request.method == IpcRequestMethod.ls.rawValue)
    }

    @Test("oversized line emits rejection event")
    func oversizedLineEmitsRejectionEvent() {
        // Intent: a line over IpcLineFramer.maxLineBytes emits an
        //   .oversized event.
        // Why it exists: pins the line-length cap.
        // Scenario: spec-first oversized.
        var framer = IpcLineFramer()
        let data = Data(repeating: 65, count: IpcLineFramer.maxLineBytes + 1)
        let events = framer.append(data)
        #expect(events.contains(.oversized), "expected oversized event")
    }
}

private func ipcLine(_ string: String) -> Data {
    var data = Data(string.utf8)
    data.append(0x0A)
    return data
}
