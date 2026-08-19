// Tests for IpcLineFramer, the newline-delimited JSON-RPC line-framing primitive that turns a raw
// socket byte stream into whole `.line` frames and rejects oversized lines: full-line emission,
// two-lines-in-one-read, split-frame reassembly, oversized-line rejection, chunk invariance, empty
// lines, the cap boundary, and resync after a refusal. Moved here with the framer from DanTermCore
// in the pure-core/portable-support refactor (Phase 2); the IpcConnection socket class that drives
// the framer stays separate.
//
// These cases characterize the framer's behavior independently of how it scans, so they hold across
// a rewrite of the scan. Do not assert the internal buffer shape here.
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

    // The framer must see a byte stream, not the chunks it arrived in. This
    // sweeps every one- and two-cut split of a stream that carries the shapes
    // most likely to break slice arithmetic: a cut mid-line, a chunk holding
    // only the newline, a cut immediately after a newline, an empty chunk mid
    // stream, and an empty line.
    @Test("framing is independent of how the stream is split into chunks")
    func framingIsIndependentOfChunkSplits() {
        let stream = Data("a\nbb\n\nc\n".utf8)
        let whole = frame([stream])
        #expect(
            whole == [
                .line(Data("a".utf8)),
                .line(Data("bb".utf8)),
                .line(Data()),
                .line(Data("c".utf8)),
            ])
        for first in 0...stream.count {
            for second in first...stream.count {
                let chunks = [
                    stream[..<(stream.startIndex + first)],
                    stream[(stream.startIndex + first)..<(stream.startIndex + second)],
                    stream[(stream.startIndex + second)...],
                ].map { Data($0) }
                #expect(frame(chunks) == whole, "split at \(first), \(second)")
            }
        }
    }

    @Test("an empty line emits a zero-length frame in sequence")
    func emptyLineEmitsZeroLengthFrame() {
        // Intent: an empty line between two full lines is its own event.
        // Why it exists: consumers skip empty lines themselves, so the framer
        //   must pass one through rather than swallow it and shift the order.
        // Scenario: spec-first empty line.
        var framer = IpcLineFramer()
        let events = framer.append(Data("first\n\nsecond\n".utf8))
        #expect(
            events == [
                .line(Data("first".utf8)),
                .line(Data()),
                .line(Data("second".utf8)),
            ])
    }

    @Test("a line of exactly maxLineBytes is accepted")
    func exactlyMaxLineBytesIsAccepted() {
        // Intent: maxLineBytes is the largest accepted line, not the first
        //   refused one.
        // Why it exists: pins the off-by-one at the cap boundary.
        // Scenario: spec-first boundary.
        var framer = IpcLineFramer()
        var chunk = Data(repeating: 65, count: IpcLineFramer.maxLineBytes)
        chunk.append(0x0A)
        let events = framer.append(chunk)
        #expect(events == [.line(Data(repeating: 65, count: IpcLineFramer.maxLineBytes))])
    }

    @Test("the cap boundary holds across append calls")
    func capBoundaryHoldsAcrossAppendCalls() {
        // Intent: the pending length that decides accept-or-refuse carries
        //   between append calls.
        // Why it exists: the cap is only correct if it counts the whole
        //   pending line, not the bytes of the current chunk.
        // Scenario: spec-first boundary delivered in two chunks.
        var accepting = IpcLineFramer()
        #expect(accepting.append(Data(repeating: 65, count: IpcLineFramer.maxLineBytes)).isEmpty)
        #expect(
            accepting.append(Data([0x0A]))
                == [.line(Data(repeating: 65, count: IpcLineFramer.maxLineBytes))])

        var refusing = IpcLineFramer()
        #expect(refusing.append(Data(repeating: 65, count: IpcLineFramer.maxLineBytes)).isEmpty)
        #expect(refusing.append(Data([65])) == [.oversized])
    }

    @Test("a refusal is followed by resync at the next newline")
    func refusalResyncsAtNextNewline() {
        // Intent: after an oversized refusal the framer drops bytes up to the
        //   next newline, emits nothing for them, and frames the line after it.
        // Why it exists: without resync one oversized line would corrupt every
        //   later frame on the connection.
        // Scenario: spec-first resync, proven both across calls and within one.
        var acrossCalls = IpcLineFramer()
        #expect(
            acrossCalls.append(Data(repeating: 65, count: IpcLineFramer.maxLineBytes + 1))
                == [.oversized])
        #expect(acrossCalls.append(Data("still discarded".utf8)).isEmpty)
        #expect(acrossCalls.append(Data("\ngood\n".utf8)) == [.line(Data("good".utf8))])

        var oneCall = IpcLineFramer()
        var chunk = Data(repeating: 65, count: IpcLineFramer.maxLineBytes + 1)
        chunk.append(Data("tail\ngood\n".utf8))
        #expect(oneCall.append(chunk) == [.oversized, .line(Data("good".utf8))])
    }
}

/// Frames a stream delivered as an explicit chunk sequence, so a test can state
/// the split positions it cares about and compare against another split.
private func frame(_ chunks: [Data]) -> [IpcFrameEvent] {
    var framer = IpcLineFramer()
    return chunks.flatMap { framer.append($0) }
}

private func ipcLine(_ string: String) -> Data {
    var data = Data(string.utf8)
    data.append(0x0A)
    return data
}
