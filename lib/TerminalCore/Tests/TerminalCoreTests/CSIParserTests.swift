// Proves bounded CSI collection, dispatch fidelity, recovery, and chunk invariance.
import Testing

@testable import TerminalCore

/// Locks the reference parser's CSI payload and drop rules at the stream boundary.
struct CSIParserTests {
    @Test("CSI dispatch preserves empty and positional parameters")
    func basicParameters() {
        #expect(dispatches("\u{1B}[H") == [
            CSISequence(parameters: [], colonSeparators: [], intermediates: [], final: 0x48),
        ])
        #expect(dispatches("\u{1B}[1;4H") == [
            CSISequence(
                parameters: [1, 4],
                colonSeparators: [false, false],
                intermediates: [],
                final: 0x48
            ),
        ])
        #expect(dispatches("\u{1B}[31;m") == [
            CSISequence(
                parameters: [31, 0],
                colonSeparators: [false, false],
                intermediates: [],
                final: 0x6D
            ),
        ])
        #expect(dispatches("\u{1B}[2;J") == [
            CSISequence(
                parameters: [2, 0],
                colonSeparators: [false, false],
                intermediates: [],
                final: 0x4A
            ),
        ])
    }

    @Test("CSI dispatch preserves colon and mixed SGR separators")
    func colonSeparators() {
        #expect(dispatches("\u{1B}[38:2m") == [
            CSISequence(
                parameters: [38, 2],
                colonSeparators: [true, false],
                intermediates: [],
                final: 0x6D
            ),
        ])
        #expect(dispatches("\u{1B}[;4:3;38;2;175;175;215;58:2::190:80:70m") == [
            CSISequence(
                parameters: [0, 4, 3, 38, 2, 175, 175, 215, 58, 2, 0, 190, 80, 70],
                colonSeparators: [
                    false, true, false, false, false, false, false,
                    false, true, true, true, true, true, false,
                ],
                intermediates: [],
                final: 0x6D
            ),
        ])
        #expect(dispatches("\u{1B}[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136m") == [
            CSISequence(
                parameters: [4, 3, 38, 2, 51, 51, 51, 48, 2, 170, 170, 170, 58, 2, 255, 97, 136],
                colonSeparators: [
                    true, false, false, false, false, false, false, false, false,
                    false, false, false, false, false, false, false, false,
                ],
                intermediates: [],
                final: 0x6D
            ),
        ])
    }

    @Test("colon parameters dispatch only for SGR and do not poison later CSI")
    func colonDropRule() {
        #expect(dispatches("\u{1B}[38:2h\u{1B}[H") == [
            CSISequence(parameters: [], colonSeparators: [], intermediates: [], final: 0x48),
        ])
        #expect(dispatches("\u{1B}[:m\u{1B}[2J") == [
            CSISequence(
                parameters: [2],
                colonSeparators: [false],
                intermediates: [],
                final: 0x4A
            ),
        ])
    }

    @Test("private markers and intermediates retain arrival order")
    func intermediateCollection() {
        #expect(dispatches("\u{1B}[?2026$p") == [
            CSISequence(
                parameters: [2026],
                colonSeparators: [false],
                intermediates: [0x3F, 0x24],
                final: 0x70
            ),
        ])
        #expect(dispatches("\u{1B}[3 q") == [
            CSISequence(
                parameters: [3],
                colonSeparators: [false],
                intermediates: [0x20],
                final: 0x71
            ),
        ])
    }

    @Test("a parameter byte after a CSI intermediate is ignored through the final")
    func malformedParameterAfterIntermediateRecovery() {
        // Intent: a malformed CSI that returns to parameter bytes after an intermediate is
        //   ignored through its final byte, and printable input immediately afterward survives.
        // Why it exists: no prior case put `-` in parameter position, so recovery could either
        //   leak the CSI final onto the grid or swallow printable bytes after the sequence.
        // Scenario: a broken application emits `CSI 2-3 @` followed by `y`; only `y` is text.
        // Adapted from kitty_tests/parser.py#test_csi_codes
        //   (kitty v0.48.2 2cb1d95, body sha256:0751bdf41479).
        //   Divergence: follows VTE/foot CSI-ignore recovery by swallowing `@`; kitty prints `@y`.
        let bytes = Array("\u{1B}[2-3@y".utf8)
        let expected: [TerminalStreamAction] = [.print("y")]

        #expect(run(chunks: [bytes]).actions == expected)
        for offset in 0...bytes.count {
            #expect(
                run(chunks: [Array(bytes[..<offset]), Array(bytes[offset...])]).actions
                    == expected
            )
        }
    }

    @Test("CSI parameter capacity dispatches 24 values and drops 25")
    func parameterCapacity() {
        let twentyFour = "\u{1B}[" + Array(repeating: "1", count: 23).joined(separator: ";") + ";2H"
        let twentyFive = "\u{1B}[" + Array(repeating: "1", count: 24).joined(separator: ";") + ";2H"

        #expect(dispatches(twentyFour) == [
            CSISequence(
                parameters: Array(repeating: 1, count: 23) + [2],
                colonSeparators: Array(repeating: false, count: 24),
                intermediates: [],
                final: 0x48
            ),
        ])
        #expect(dispatches(twentyFive).isEmpty)
    }

    @Test("CSI numeric accumulation saturates at UInt16.max")
    func parameterSaturation() {
        #expect(dispatches("\u{1B}[999999999999999999999C").first?.parameters == [UInt16.max])
    }

    @Test("a fifth intermediate is discarded without dropping the dispatch")
    func intermediateCapacity() {
        let four: [UInt8] = [0x1B, 0x5B, 0x20, 0x21, 0x22, 0x23, 0x71]
        let five: [UInt8] = [0x1B, 0x5B, 0x20, 0x21, 0x22, 0x23, 0x24, 0x71]

        #expect(dispatches(four).first?.intermediates == [0x20, 0x21, 0x22, 0x23])
        #expect(dispatches(five) == dispatches(four))
    }

    @Test("CAN and ESC restart clear partial CSI collection")
    func abortedCollectionDoesNotLeak() {
        #expect(dispatches("\u{1B}[123\u{18}\u{1B}[4H") == [
            CSISequence(
                parameters: [4],
                colonSeparators: [false],
                intermediates: [],
                final: 0x48
            ),
        ])
        #expect(dispatches("\u{1B}[123\u{1B}[5H") == [
            CSISequence(
                parameters: [5],
                colonSeparators: [false],
                intermediates: [],
                final: 0x48
            ),
        ])
    }

    @Test("CSI dispatch and pending state are invariant across every chunk split")
    func chunkBoundaryInvariance() {
        // Intent: prove parameters, separators, intermediates, drops, and
        //   aborted collection do not depend on PTY read boundaries.
        // Why it exists: dispatch values and parser equality extend the slice-1
        //   chunk contract beyond silent recognition for the first time.
        // Scenario: representative complete, dropped, and restarted CSI input
        //   arrives at every two-way and three-way split and byte at a time.
        let fixtures = [
            Array("\u{1B}[123;45H".utf8),
            Array("\u{1B}[4:3m".utf8),
            Array("\u{1B}[?2026$p".utf8),
            Array("\u{1B}[".utf8) + Array(repeating: [0x31, 0x3B], count: 25).flatMap { $0 } + [0x48],
            Array("\u{1B}[123\u{18}\u{1B}[4H".utf8),
        ]

        for bytes in fixtures {
            let expected = run(chunks: [bytes])
            for first in 0...bytes.count {
                #expect(run(chunks: [Array(bytes[..<first]), Array(bytes[first...])]) == expected)
                for second in first...bytes.count {
                    #expect(run(chunks: [
                        Array(bytes[..<first]),
                        Array(bytes[first..<second]),
                        Array(bytes[second...]),
                    ]) == expected)
                }
            }
            #expect(run(chunks: bytes.map { [$0] }) == expected)
        }
    }

    @Test("only OSC string payload length participates in parser state")
    func onlyOSCPayloadsAreRetained() {
        let prefixes: [[UInt8]] = [
            [0x1B, 0x5D],
            [0x1B, 0x50, 0x71],
            [0x1B, 0x58],
            [0x1B, 0x5E],
            [0x1B, 0x5F],
        ]

        for (index, prefix) in prefixes.enumerated() {
            var one = TerminalInputStream()
            var many = TerminalInputStream()
            _ = one.feed(prefix + [0x78])
            _ = many.feed(prefix + Array(repeating: 0x78, count: 4096))
            #expect((one == many) == (index != 0))
        }
    }

    @Test("DCS parameter overflow is discarded without trapping and recovery resumes")
    func dcsParameterOverflowRecovery() {
        var stream = TerminalInputStream()
        let overflow = [0x1B, 0x50, 0x36] as [UInt8]
            + Array(repeating: [0x3B] as [UInt8], count: 24).flatMap { $0 }
            + [0x37, 0x70, 0x1B, 0x5C]

        let actions = stream.feed(overflow + Array("\u{1B}[H|".utf8))

        #expect(Array(actions.suffix(2)) == [
            .csi(CSISequence(parameters: [], colonSeparators: [], intermediates: [], final: 0x48)),
            .print("|"),
        ])
    }

    @Test("surfaced but uninterpreted CSI leaves terminal state bit-identical")
    func uninterpretedDispatchIsNoOp() throws {
        for sequence in ["\u{1B}[?2026;25$p", "\u{1B}[9z"] {
            var terminal = try #require(Terminal(columns: 2, rows: 2))
            terminal.feed(Array("AB".utf8))
            let expected = terminal

            terminal.feed(Array(sequence.utf8))

            #expect(terminal == expected)
        }
    }

    @Test("trailing separators make strict-arity non-SGR dispatches no-ops")
    func trailingSeparatorStrictArity() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("AB".utf8))
        let expected = terminal

        terminal.feed(Array("\u{1B}[2;J".utf8))

        #expect(terminal == expected)
    }

    private func dispatches(_ input: String) -> [CSISequence] {
        dispatches(Array(input.utf8))
    }

    private func dispatches(_ bytes: [UInt8]) -> [CSISequence] {
        var stream = TerminalInputStream()
        return stream.feed(bytes).compactMap { action in
            guard case let .csi(sequence) = action else { return nil }
            return sequence
        }
    }

    private func run(chunks: [[UInt8]]) -> (actions: [TerminalStreamAction], stream: TerminalInputStream) {
        var stream = TerminalInputStream()
        var actions: [TerminalStreamAction] = []
        for chunk in chunks {
            actions.append(contentsOf: stream.feed(chunk))
        }
        return (actions, stream)
    }
}
