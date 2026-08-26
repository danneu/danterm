// Verifies XTGETTCAP: that every published capability is answerable, that nothing else is,
// and that xterm's prefix semantics hold across a multi-name request and a split stream.
//
// The answerable roster is read from TerminalCapabilityProjection rather than restated here,
// so a row added to docs/terminal-capabilities.md is covered the moment the generator runs.
// The projection alone cannot prove the values are right -- it would agree with itself -- so
// one test pins concrete wire bytes for each value kind.
import Testing

@testable import TerminalCore

/// Pins DanTerm's XTGETTCAP contract against the capability projection it answers from.
struct TerminalXTGETTCAPTests {
    @Test("every name the contract publishes is answerable under that name")
    func everyProjectedNameIsAnswerable() throws {
        for (name, value) in TerminalCapabilityProjection.values {
            var terminal = try #require(Terminal(columns: 8, rows: 4))
            terminal.feed(Array("\u{1B}P+q\(Self.hexadecimal(name))\u{1B}\\".utf8))
            let pair = value.isEmpty
                ? Self.hexadecimal(name)
                : "\(Self.hexadecimal(name))=\(Self.hexadecimal(value))"
            #expect(
                terminal.drainReplyBytes() == Array("\u{1B}P1+r\(pair)\u{1B}\\".utf8),
                "capability: \(name)"
            )
        }
    }

    // `pairs` and `RGB` are the two deliberate denials: the contract records `pairs` without a
    // single runtime value because its baselines disagree, and denies `RGB` because neither
    // xterm-256color baseline carries it. The rest are real xterm capabilities DanTerm has
    // never claimed, so a reply to one would be a promise the contract does not make.
    @Test(
        "a name outside the contract draws the invalid reply",
        arguments: ["pairs", "RGB", "Co2", "kf1", "Smulx", "cols", "lines", "xterm-256color"]
    )
    func namesOutsideTheContractAreInvalid(name: String) throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}P+q\(Self.hexadecimal(name))\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P0+r\u{1B}\\".utf8))
    }

    // One row per value kind, spelled out in wire bytes. Without this the projection-driven
    // test above would pass against any self-consistent table, including a wrong one.
    @Test(
        "each value kind goes on the wire in its own form",
        arguments: [
            // Boolean: the name comes back with no `=` and no value.
            ("am", "\u{1B}P1+r616D\u{1B}\\"),
            // Number: decimal digits, then hex-encoded like any other value.
            ("colors", "\u{1B}P1+r636F6C6F7273=323536\u{1B}\\"),
            // String without a parameter: escapes decoded, so `\E[K` travels as ESC `[` `K`.
            ("el", "\u{1B}P1+r656C=1B5B4B\u{1B}\\"),
            // String with a parameter: terminfo source form, so `\E` travels as two characters.
            ("cup", "\u{1B}P1+r637570=5C455B256925703125643B257032256448\u{1B}\\"),
            // Pseudo-capability: the TERM DanTerm owns.
            ("TN", "\u{1B}P1+r544E=787465726D2D323536636F6C6F72\u{1B}\\"),
        ]
    )
    func wireValuesArePinned(name: String, expected: String) throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}P+q\(Self.hexadecimal(name))\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array(expected.utf8))
    }

    // xterm's prefix semantics (references/xterm/misc.c:5180): the first name alone decides the
    // digit, then pairs stream in request order and stop at the first miss.
    @Test("a multi-name request answers its valid prefix and stops at the first miss")
    func prefixSemanticsStopAtTheFirstMiss() throws {
        let colors = "\(Self.hexadecimal("colors"))=\(Self.hexadecimal("256"))"
        let bold = "\(Self.hexadecimal("bold"))=\(Self.hexadecimal("\u{1B}[1m"))"

        #expect(
            try Self.reply(names: ["colors", "am", "bold"])
                == Array("\u{1B}P1+r\(colors);616D;\(bold)\u{1B}\\".utf8)
        )
        // First name misses: the reply carries nothing, not even the names that would match.
        #expect(try Self.reply(names: ["pairs", "colors"]) == Array("\u{1B}P0+r\u{1B}\\".utf8))
        // Nth name misses: the valid reply carries the first N-1 pairs and stops there.
        #expect(
            try Self.reply(names: ["colors", "pairs", "bold"])
                == Array("\u{1B}P1+r\(colors)\u{1B}\\".utf8)
        )
        // A trailing separator names nothing, so it is a miss like any other: the reply ends
        // after the last valid pair rather than carrying an empty one.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}P+q616D;\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P1+r616D\u{1B}\\".utf8))
    }

    // Reflecting the request back is CVE-2008-2383. xterm echoes the failing name's request
    // bytes before it stops; DanTerm ends after the last valid pair instead, so the name that
    // missed appears nowhere -- not even as the hexadecimal the sender spelled it in.
    @Test("a name that misses is never echoed back in the reply")
    func missingNameIsNotEchoed() throws {
        let intruder = "ZzYy~!"
        let reply = try Self.reply(names: ["colors", intruder])
        // Equality is the assertion: the reply is exactly the valid prefix, so there is no
        // room in it for the intruder's bytes in any spelling, whole or partial.
        #expect(reply == Array("\u{1B}P1+r636F6C6F7273=323536\u{1B}\\".utf8))
    }

    // A body that is not well-formed hexadecimal names nothing, so it cannot be decoded into a
    // capability that happens to match. An odd digit count would otherwise drop a nibble.
    @Test(
        "a malformed request body draws the invalid reply",
        arguments: ["", "6", "616", "6D6Z", "61 6D", "0x616D", ";", ";616D"]
    )
    func malformedBodiesAreInvalid(body: String) throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}P+q\(body)\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P0+r\u{1B}\\".utf8))
    }

    // The echoed name is the sender's own bytes, so a lowercase request comes back lowercase.
    // Only the value is spelled by DanTerm, and it is always uppercase.
    @Test("the reply echoes the request's own spelling of the name")
    func requestSpellingIsEchoed() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}P+q636f6c6f7273\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P1+r636f6c6f7273=323536\u{1B}\\".utf8))
    }

    @Test("an over-long body draws no reply, and the next request is answered normally")
    func overLongBodyIsIgnored() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        let oversized = Array(repeating: UInt8(0x36), count: 2 * 1_024 * 1_024 + 1)
        terminal.feed([0x1B, 0x50, 0x2B, 0x71] + oversized + [0x1B, 0x5C])
        #expect(terminal.drainReplyBytes().isEmpty)

        terminal.feed(Array("\u{1B}P+q616D\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P1+r616D\u{1B}\\".utf8))
    }

    @Test("a parameter on the header invalidates the request")
    func parametersInvalidateTheRequest() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}P1+q616D\u{1B}\\".utf8))
        #expect(terminal.drainReplyBytes() == Array("\u{1B}P0+r\u{1B}\\".utf8))
    }

    // ADR K5: the reply cannot depend on where the stream was chopped. The cases carry an
    // opaque high byte, a cancellation mid-body, and recovery through a later valid request.
    @Test("a split request answers exactly as the whole one does")
    func chunkBoundaryInvariance() throws {
        let cases: [[UInt8]] = [
            Array("\u{1B}P+q616D\u{1B}\\".utf8),
            Array("\u{1B}P+q636F6C6F7273;616D\u{1B}\\".utf8),
            Array("\u{1B}P+q7061697273;616D\u{1B}\\".utf8),
            [0x1B, 0x50, 0x2B, 0x71, 0xC2, 0x90, 0x36, 0x31, 0x6D, 0x1B, 0x5C],
            [0x1B, 0x50, 0x2B, 0x71, 0x36, 0x31, 0x6D, 0x18] + Array("\u{1B}P+q616D\u{1B}\\".utf8),
            [0x1B, 0x50, 0x2B, 0x71, 0x36, 0x31, 0x1B]
                + Array("[1\"q\u{1B}P+q626F6C64\u{1B}\\".utf8),
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

    private static func reply(names: [String]) throws -> [UInt8] {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        let body = names.map(Self.hexadecimal).joined(separator: ";")
        terminal.feed(Array("\u{1B}P+q\(body)\u{1B}\\".utf8))
        return terminal.drainReplyBytes()
    }

    private static func replies(chunks: [[UInt8]]) throws -> [UInt8] {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        for chunk in chunks {
            terminal.feed(chunk)
        }
        return terminal.drainReplyBytes()
    }

    /// TerminalCore is Foundation-free, so the test spells its own encoder rather than
    /// importing one -- and spelling it here keeps it independent of the engine's.
    private static func hexadecimal(_ value: String) -> String {
        let digits = Array("0123456789ABCDEF")
        return String(value.utf8.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] })
    }
}
