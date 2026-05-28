// Swift Testing migration of the legacy `tests/IpcConnectionTests.swift`
// harness suite. Pins the DanTerm IPC line-framing primitive that drives
// the protocol-frame stream: full-line emission, two-lines-in-one-read,
// split-frame reassembly, and oversized-line rejection. The two
// `guard case .line(let line) = events[0]` destructures convert to
// `Issue.record + return` (one-for-one failure-site preservation).
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct IpcConnectionTests {
    @Test("one full line emits one frame")
    func oneFullLineEmitsOneFrame() throws {
        // Intent: a full JSON-RPC line emits exactly one .line event.
        // Why it exists: pins the happy framing path.
        // Scenario: spec-first single line.
        var framer = IpcLineFramer()
        let events = framer.append(ipcLine(#"{"jsonrpc":"2.0","id":1,"method":"ls"}"#))
        #expect(events.count == 1)
        guard case .line(let line) = events[0] else {
            Issue.record("expected line event")
            return
        }
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        #expect(request.method == Methods.ls)
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
        guard case .line(let line) = events[0] else {
            Issue.record("expected line event")
            return
        }
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        #expect(request.method == Methods.ls)
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
