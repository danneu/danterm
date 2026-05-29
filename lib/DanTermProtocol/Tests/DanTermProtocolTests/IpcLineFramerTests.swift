// Tests for IpcLineFramer, the newline-delimited JSON-RPC line-framing primitive that turns a raw
// socket byte stream into whole `.line` frames and rejects oversized lines: full-line emission,
// two-lines-in-one-read, split-frame reassembly, and oversized-line rejection. Moved here with the
// framer from DanTermCore in the pure-core/portable-support refactor (Phase 2); the IpcConnection
// socket class that drives the framer stays separate. XCTest to match this package's convention.
import Foundation
import XCTest

@testable import DanTermProtocol

final class IpcLineFramerTests: XCTestCase {
    func testOneFullLineEmitsOneFrame() throws {
        // Intent: a full JSON-RPC line emits exactly one .line event.
        // Why it exists: pins the happy framing path.
        // Scenario: spec-first single line.
        var framer = IpcLineFramer()
        let events = framer.append(ipcLine(#"{"jsonrpc":"2.0","id":1,"method":"ls"}"#))
        XCTAssertEqual(events.count, 1)
        guard case .line(let line) = events[0] else {
            XCTFail("expected line event")
            return
        }
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        XCTAssertEqual(request.method, Methods.ls)
    }

    func testTwoFullLinesInOneReadEmitTwoFrames() {
        // Intent: two full lines in one chunk emit two frames.
        // Why it exists: pins the multi-line case.
        // Scenario: spec-first two-lines.
        var framer = IpcLineFramer()
        var chunk = ipcLine(#"{"jsonrpc":"2.0","id":1,"method":"ls"}"#)
        chunk.append(ipcLine(#"{"jsonrpc":"2.0","id":2,"method":"tab.rename"}"#))
        let events = framer.append(chunk)
        XCTAssertEqual(events.count, 2)
    }

    func testSplitFrameReassemblesAfterSecondChunk() throws {
        // Intent: a frame split across two chunks reassembles into one
        //   event.
        // Why it exists: pins the reassembly case.
        // Scenario: spec-first split frame.
        var framer = IpcLineFramer()
        XCTAssertEqual(framer.append(Data(#"{"jsonrpc":"#.utf8)).count, 0)
        let events = framer.append(ipcLine(#""2.0","id":1,"method":"ls"}"#))
        XCTAssertEqual(events.count, 1)
        guard case .line(let line) = events[0] else {
            XCTFail("expected line event")
            return
        }
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        XCTAssertEqual(request.method, Methods.ls)
    }

    func testOversizedLineEmitsRejectionEvent() {
        // Intent: a line over IpcLineFramer.maxLineBytes emits an
        //   .oversized event.
        // Why it exists: pins the line-length cap.
        // Scenario: spec-first oversized.
        var framer = IpcLineFramer()
        let data = Data(repeating: 65, count: IpcLineFramer.maxLineBytes + 1)
        let events = framer.append(data)
        XCTAssertTrue(events.contains(.oversized), "expected oversized event")
    }
}

private func ipcLine(_ string: String) -> Data {
    var data = Data(string.utf8)
    data.append(0x0A)
    return data
}
