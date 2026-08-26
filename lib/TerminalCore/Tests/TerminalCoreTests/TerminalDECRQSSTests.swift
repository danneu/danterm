// Verifies DECRQSS readback: the reported roster, round-trip fidelity, and the DCS seam's bounds.
//
// Reply shape lives here rather than in TerminalQueryTests because DECRQSS is the first reply
// whose *request* carries a body, so its proofs are about the body -- what is matched, what is
// never echoed, and what a split or an over-long one does.
import Testing

@testable import TerminalCore

/// Pins DanTerm's DECRQSS contract and the routed-DCS collection the reply depends on.
struct TerminalDECRQSSTests {
    private static let reportedSettings = ["m", "r", " q", "\"q"]

    @Test(
        "each reported setting round-trips through its status string",
        arguments: [
            // A distinct non-default value per setting, so a reply that reported the default
            // would fail rather than pass by coincidence.
            "\u{1B}[1;3;4:3;38;5;9;48;2;1;2;3m",
            "\u{1B}[2;3r",
            "\u{1B}[5 q",
            "\u{1B}[1\"q",
        ]
    )
    func reportedSettingsRoundTrip(setting: String) throws {
        var terminal = try #require(Terminal(columns: 8, rows: 6))
        terminal.feed(Array(setting.utf8))
        _ = terminal.drainReplyBytes()

        for request in Self.reportedSettings {
            terminal.feed(Array("\u{1B}P$q\(request)\u{1B}\\".utf8))
            let status = try #require(Self.status(in: terminal.drainReplyBytes()))

            var replayed = try #require(Terminal(columns: 8, rows: 6))
            replayed.feed(Array("\u{1B}[".utf8) + status)
            _ = replayed.drainReplyBytes()

            // Round-trip, not string equality: what the reply has to preserve is the setting,
            // not one spelling of it.
            replayed.feed(Array("\u{1B}P$q\(request)\u{1B}\\".utf8))
            #expect(Self.status(in: replayed.drainReplyBytes()) == status, "request: \(request)")
        }
    }

    @Test(
        "settings DanTerm does not model draw the invalid reply",
        arguments: ["s", "*x", "|", "$}", "", "q", "M"]
    )
    func unmodelledSettingsAreInvalid(request: String) throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}P$q\(request)\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P0$r\u{1B}\\".utf8))
    }

    // Reflecting the request back into the stream is CVE-2008-2383. The bytes below are chosen so
    // that any echo -- whole, partial, or re-encoded -- shows up as a byte the reply cannot
    // otherwise contain.
    @Test("an invalid request is never echoed back in the reply")
    func invalidRequestIsNotEchoed() throws {
        let distinctive = Array("ZzYy~!".utf8)
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed([0x1B, 0x50, 0x24, 0x71] + distinctive + [0x1B, 0x5C])

        let reply = terminal.drainReplyBytes()
        #expect(reply == Array("\u{1B}P0$r\u{1B}\\".utf8))
        for byte in distinctive {
            #expect(reply.contains(byte) == false)
        }
    }

    @Test("replies are 7-bit framed and carry no C1 byte")
    func repliesAreSevenBitFramed() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        for request in Self.reportedSettings + ["s"] {
            terminal.feed(Array("\u{1B}P$q\(request)\u{1B}\\".utf8))
            let reply = terminal.drainReplyBytes()
            #expect(reply.starts(with: [0x1B, 0x50]), "request: \(request)")
            #expect(reply.suffix(2) == [0x1B, 0x5C], "request: \(request)")
            #expect(reply.contains { (0x80...0x9F).contains($0) } == false, "request: \(request)")
        }
    }

    // A body outside the request's alphabet has to reach the handler intact: the parser used to
    // drop bytes >= 0x80 inside a DCS, which would turn `\u{90}m` into a valid `m` request.
    @Test("a high or control byte in the body invalidates the request rather than being dropped")
    func bodyIsMatchedVerbatim() throws {
        for intruder in [0x90, 0x9C, 0x80, 0xFF, 0x00, 0x07, 0x7F] as [UInt8] {
            var terminal = try #require(Terminal(columns: 8, rows: 4))
            terminal.feed([0x1B, 0x50, 0x24, 0x71, intruder, 0x6D, 0x1B, 0x5C])
            #expect(
                terminal.drainReplyBytes() == Array("\u{1B}P0$r\u{1B}\\".utf8),
                "intruder: \(intruder)"
            )
        }
    }

    @Test("an over-long request body is ignored whole and the next request still answers")
    func overLongBodyIsIgnored() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        let oversized = Array(repeating: UInt8(0x6D), count: 2 * 1_024 * 1_024 + 1)
        terminal.feed([0x1B, 0x50, 0x24, 0x71] + oversized + [0x1B, 0x5C])
        #expect(terminal.drainReplyBytes().isEmpty)

        terminal.feed(Array("\u{1B}P$q\"q\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P1$r0\"q\u{1B}\\".utf8))
    }

    @Test("a parameterized DECRQSS header is not a setting request")
    func parametersInvalidateTheRequest() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}P1$qm\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P0$r\u{1B}\\".utf8))
    }

    // Every DCS family but the routed ones keeps the behavior it had before the seam existed:
    // absorbed, silent, and retaining nothing. The near-misses matter most -- one intermediate
    // away from DECRQSS is where a route selected from the wrong facts would leak.
    @Test(
        "an unrouted DCS emits nothing and changes nothing",
        arguments: [
            "\u{1B}P$rm\u{1B}\\", "\u{1B}P#qm\u{1B}\\", "\u{1B}P*qm\u{1B}\\",
            "\u{1B}P$$qm\u{1B}\\", "\u{1B}Pqm\u{1B}\\", "\u{1B}P$pm\u{1B}\\",
            "\u{1B}P1000p tmux\u{1B}\\",
        ]
    )
    func unroutedDCSIsSilent(sequence: String) throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        let before = terminal
        terminal.feed(Array(sequence.utf8))
        #expect(terminal == before, "sequence bytes: \(Array(sequence.utf8))")
    }

    // The seam must not turn a sequence the engine ignores into a way to make it allocate: the
    // synchronization prefix is exactly what the parser retains, so a constant prefix under a
    // megabyte of body is the statement that nothing was collected.
    @Test("an unrouted DCS body is not retained, and a routed one is")
    func onlyRoutedBodiesAreRetained() {
        let body = Array(repeating: UInt8(0x41), count: 1 << 20)

        var unrouted = TerminalInputStream()
        _ = unrouted.feed([0x1B, 0x50, 0x71] + body)
        #expect(unrouted.synchronizationPrefix == [0x1B, 0x50, 0x71])

        var routed = TerminalInputStream()
        _ = routed.feed([0x1B, 0x50, 0x24, 0x71] + body)
        #expect(routed.synchronizationPrefix == [0x1B, 0x50, 0x24, 0x71] + body)
    }

    @Test("DECRQSS replies are invariant across every chunk split")
    func chunkBoundaryInvariance() throws {
        let cases: [[UInt8]] = [
            Array("\u{1B}P$qm\u{1B}\\".utf8),
            Array("\u{1B}P$q\"q\u{1B}\\".utf8),
            Array("\u{1B}P$q q\u{1B}\\".utf8),
            Array("\u{1B}P$qs\u{1B}\\".utf8),
            // An opaque high byte inside the body, which the seam must carry across a split.
            [0x1B, 0x50, 0x24, 0x71, 0xC2, 0x90, 0x6D, 0x1B, 0x5C],
            // Cancelled mid-body, then restarted and completed.
            [0x1B, 0x50, 0x24, 0x71, 0x6D, 0x18] + Array("\u{1B}P$qr\u{1B}\\".utf8),
            // Abandoned by a fresh ESC, then recovered by a later valid request.
            [0x1B, 0x50, 0x24, 0x71, 0x6D, 0x1B] + Array("[1\"q\u{1B}P$q\"q\u{1B}\\".utf8),
        ]
        for bytes in cases {
            let whole = try Self.replies(chunks: [bytes])
            #expect(try Self.replies(chunks: bytes.map { [$0] }) == whole, "bytes: \(bytes)")
            for split in 1..<bytes.count {
                #expect(
                    try Self.replies(chunks: [Array(bytes[..<split]), Array(bytes[split...])])
                        == whole,
                    "split \(split) of \(bytes)"
                )
            }
        }
    }

    private static func replies(chunks: [[UInt8]]) throws -> [UInt8] {
        var terminal = try #require(Terminal(columns: 8, rows: 6))
        for chunk in chunks {
            terminal.feed(chunk)
        }
        return terminal.drainReplyBytes()
    }

    /// Extracts the status string a valid `DCS 1 $ r <status> ST` reply carries.
    private static func status(in reply: [UInt8]) -> [UInt8]? {
        let opening = Array("\u{1B}P1$r".utf8)
        guard reply.starts(with: opening), reply.suffix(2) == [0x1B, 0x5C] else { return nil }
        return Array(reply.dropFirst(opening.count).dropLast(2))
    }
}
