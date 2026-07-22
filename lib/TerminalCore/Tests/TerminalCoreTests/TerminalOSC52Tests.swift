// Proves bounded OSC string recognition and the write-only OSC 52 clipboard policy.
import Testing

@testable import TerminalCore

/// Locks clipboard writes to a bounded, strict, chunk-invariant semantic channel.
struct TerminalOSC52Tests {
    @Test("OSC terminators dispatch the same raw payload")
    func terminatorsDispatchPayload() {
        let payload = Array("52;c;aGVsbG8=".utf8)
        let sequences = [
            [0x1B, 0x5D] + payload + [0x07],
            [0x1B, 0x5D] + payload + [0x1B, 0x5C],
        ]

        for bytes in sequences {
            var stream = TerminalInputStream()
            #expect(stream.feed(bytes) == [.osc(payload)])
        }
    }

    @Test("OSC cancellation discards payload and later input resumes")
    func cancellationDiscardsPayload() {
        let prefixes: [[UInt8]] = [
            [0x1B, 0x5D, 0x35, 0x32, 0x3B, 0x18],
            [0x1B, 0x5D, 0x35, 0x32, 0x3B, 0x1A],
            [0x1B, 0x5D, 0x35, 0x32, 0x3B, 0x1B, 0x37],
        ]

        for prefix in prefixes {
            var stream = TerminalInputStream()
            let actions = stream.feed(prefix + [0x41])
            #expect(actions.last == .print("A"))
            #expect(actions.contains { action in
                if case .osc = action { return true }
                return false
            } == false)
        }
    }

    @Test("OSC ignores C0 and DEL payload bytes")
    func controlsDoNotJoinPayload() {
        var stream = TerminalInputStream()
        let bytes = [0x1B, 0x5D] + Array("52;c;aG".utf8)
            + [0x00, 0x0A, 0x7F]
            + Array("VsbG8=".utf8) + [0x07]

        #expect(stream.feed(bytes) == [.osc(Array("52;c;aGVsbG8=".utf8))])
    }

    @Test("OSC payload cap rejects the sequence and resumes after termination")
    func encodedPayloadCap() {
        var stream = TerminalInputStream()
        let oversized = [0x1B, 0x5D] + [UInt8](repeating: 0x41, count: 2 * 1_024 * 1_024 + 1)
        let valid = Array("\u{1B}]52;c;b2s=\u{7}".utf8)

        #expect(stream.feed(oversized).isEmpty)
        #expect(stream.feed([0x07] + valid) == [.osc(Array("52;c;b2s=".utf8))])
    }

    @Test("OSC 52 accepts valid targets and coalesces writes newest-first")
    func validWritesAndDrain() {
        var terminal = Terminal(columns: 80, rows: 24)!

        terminal.feed(Array("\u{1B}]52;;Zmlyc3Q=\u{7}\u{1B}]52;cpqs07;c2Vjb25k\u{7}".utf8))

        #expect(terminal.drainPendingClipboardWrite() == "second")
        #expect(terminal.drainPendingClipboardWrite() == nil)
    }

    @Test("OSC 52 empty payload is a distinct clearing write")
    func emptyWrite() {
        var terminal = Terminal(columns: 80, rows: 24)!

        terminal.feed(Array("\u{1B}]52;c;\u{7}".utf8))

        #expect(terminal.drainPendingClipboardWrite() == "")
        #expect(terminal.drainPendingClipboardWrite() == nil)
    }

    @Test("OSC 52 rejects malformed writes and silently denies reads")
    func rejectedWrites() {
        let sequences = [
            "\u{1B}]52;x;aGVsbG8=\u{7}",
            "\u{1B}]52;c;?\u{7}",
            "\u{1B}]52;c;aGVsbG8\u{7}",
            "\u{1B}]52;c;aGV=sbG8\u{7}",
            "\u{1B}]52;c;Zh==\u{7}",
            "\u{1B}]52;c;Zm9=\u{7}",
            "\u{1B}]52;c;/w==\u{7}",
            "\u{1B}]52;c\u{7}",
            "\u{1B}]51;c;aGVsbG8=\u{7}",
        ]

        for sequence in sequences {
            var terminal = Terminal(columns: 80, rows: 24)!
            _ = terminal.drainDamage()
            let baseline = terminal
            terminal.feed(Array(sequence.utf8))
            #expect(terminal == baseline)
            #expect(terminal.drainPendingClipboardWrite() == nil)
            #expect(terminal.drainReplyBytes().isEmpty)
        }

        var rawC1Payload = Terminal(columns: 80, rows: 24)!
        _ = rawC1Payload.drainDamage()
        let baseline = rawC1Payload
        rawC1Payload.feed([0x1B, 0x5D] + Array("52;c;".utf8) + [0x9C, 0x1B, 0x5C])
        #expect(rawC1Payload == baseline)
        #expect(rawC1Payload.drainPendingClipboardWrite() == nil)
    }

    @Test("OSC 52 decoded limit accepts 1 MiB and rejects one byte more")
    func decodedSizeLimit() {
        let accepted = String(repeating: "YWFh", count: 1_048_576 / 3) + "YQ=="
        let rejected = String(repeating: "YWFh", count: 1_048_576 / 3) + "YWE="
        var terminal = Terminal(columns: 80, rows: 24)!

        terminal.feed(Array("\u{1B}]52;c;\(accepted)\u{7}".utf8))
        #expect(terminal.drainPendingClipboardWrite()?.utf8.count == 1_048_576)
        terminal.feed(Array("\u{1B}]52;c;\(rejected)\u{7}".utf8))
        #expect(terminal.drainPendingClipboardWrite() == nil)
    }

    @Test("OSC 52 is invariant across every split point")
    func everySplitPoint() {
        let bytes = Array("\u{1B}]52;c;aGVsbG8=\u{1B}\\".utf8)
        var authored = Terminal(columns: 80, rows: 24)!
        authored.feed(bytes)

        for offset in 0...bytes.count {
            var split = Terminal(columns: 80, rows: 24)!
            split.feed(Array(bytes[..<offset]))
            split.feed(Array(bytes[offset...]))
            #expect(split == authored)
            #expect(split.drainPendingClipboardWrite() == "hello")
        }
    }
}
