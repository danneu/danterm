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

    @Test("CSI parameter capacity truncates past 24 values without dropping the dispatch")
    func parameterCapacity() {
        // Intent: an over-long CSI dispatches with exactly its first 24 parameters, and that
        //   value is the one the same sequence cut after its 24th parameter dispatches.
        // Why it exists: dropping the whole sequence turned one extra parameter into a silent
        //   no-op for a whole SGR or mode set, which is a cliff rather than a degradation.
        // Scenario: a 25-parameter CUP arrives with digits still pending at the final byte,
        //   ending on a separator, and with a colon-bearing tail.
        let head = Array(repeating: "1", count: 23).joined(separator: ";")
        let truncated = [
            CSISequence(
                parameters: Array(repeating: 1, count: 23) + [2],
                colonSeparators: Array(repeating: false, count: 24),
                intermediates: [],
                final: 0x48
            ),
        ]

        #expect(dispatches("\u{1B}[\(head);2H") == truncated)
        #expect(dispatches("\u{1B}[\(head);2;9H") == truncated)
        #expect(dispatches("\u{1B}[\(head);2;9;H") == truncated)
        #expect(dispatches("\u{1B}[\(head);2:9:8H") == truncated)
    }

    @Test("CSI numeric accumulation saturates at UInt16.max")
    func parameterSaturation() {
        let parameters = dispatches("\u{1B}[999999999999999999999C").first.map {
            Array($0.parameters)
        }
        #expect(parameters == [UInt16.max])
    }

    @Test("a fifth intermediate is discarded without dropping the dispatch")
    func intermediateCapacity() {
        let four: [UInt8] = [0x1B, 0x5B, 0x20, 0x21, 0x22, 0x23, 0x71]
        let five: [UInt8] = [0x1B, 0x5B, 0x20, 0x21, 0x22, 0x23, 0x24, 0x71]

        let intermediates = dispatches(four).first.map { Array($0.intermediates) }
        #expect(intermediates == [0x20, 0x21, 0x22, 0x23])
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
            _ = one.expandedFeed(prefix + [0x78])
            _ = many.expandedFeed(prefix + Array(repeating: 0x78, count: 4096))
            #expect((one == many) == (index != 0))
        }
    }

    @Test("DCS parameter overflow is discarded without trapping and recovery resumes")
    func dcsParameterOverflowRecovery() {
        var stream = TerminalInputStream()
        let overflow = [0x1B, 0x50, 0x36] as [UInt8]
            + Array(repeating: [0x3B] as [UInt8], count: 24).flatMap { $0 }
            + [0x37, 0x70, 0x1B, 0x5C]

        let actions = stream.expandedFeed(overflow + Array("\u{1B}[H|".utf8))

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

    /// One CSI final with the widest parameter list its handler accepts.
    ///
    /// `refused` carries one parameter more than that width; `accepted` carries exactly that
    /// width. `setup` runs after the shared fixture so the accepted form has something to change
    /// (a pushed keyboard stack for `<u`, a saved cursor for `u`, a set mode for `!p`).
    struct ArityCase: Sendable, CustomTestStringConvertible {
        let refused: String
        let accepted: String?
        let setup: String

        init(_ refused: String, _ accepted: String?, setup: String = "") {
            self.refused = refused
            self.accepted = accepted
            self.setup = setup
        }

        var testDescription: String {
            refused.replacingOccurrences(of: "\u{1B}", with: "ESC")
        }
    }

    /// Every strict-arity CSI handler, stated once. Variadic finals (`m`, `h`, `l`, `?h`, `?l`)
    /// take any count and are not listed.
    static let arityRoster: [ArityCase] = [
        // Counts: at most one parameter.
        .init("\u{1B}[1;2A", "\u{1B}[2A"), .init("\u{1B}[1;2k", "\u{1B}[2k"),
        .init("\u{1B}[1;2B", "\u{1B}[2B"), .init("\u{1B}[1;2e", "\u{1B}[2e"),
        .init("\u{1B}[1;2C", "\u{1B}[2C"), .init("\u{1B}[1;2a", "\u{1B}[2a"),
        .init("\u{1B}[1;2D", "\u{1B}[2D"), .init("\u{1B}[1;2j", "\u{1B}[2j"),
        .init("\u{1B}[1;2E", "\u{1B}[2E"), .init("\u{1B}[1;2F", "\u{1B}[2F"),
        .init("\u{1B}[1;2I", "\u{1B}[2I"), .init("\u{1B}[1;2Z", "\u{1B}[2Z"),
        .init("\u{1B}[1;2X", "\u{1B}[2X"), .init("\u{1B}[1;2@", "\u{1B}[2@"),
        .init("\u{1B}[1;2P", "\u{1B}[2P"), .init("\u{1B}[1;2L", "\u{1B}[2L"),
        .init("\u{1B}[1;2M", "\u{1B}[2M"), .init("\u{1B}[1;2S", "\u{1B}[2S"),
        .init("\u{1B}[1;2T", "\u{1B}[2T"), .init("\u{1B}[1;2b", "\u{1B}[2b"),
        // Positions: one for a column or row, two for both.
        .init("\u{1B}[1;2G", "\u{1B}[2G"), .init("\u{1B}[1;2`", "\u{1B}[2`"),
        .init("\u{1B}[1;2d", "\u{1B}[2d"),
        .init("\u{1B}[1;2;3H", "\u{1B}[1;2H"), .init("\u{1B}[1;2;3f", "\u{1B}[1;2f"),
        .init("\u{1B}[1;2;3r", "\u{1B}[2;5r"),
        // Selectors: at most one parameter, then a domain check the handler owns.
        .init("\u{1B}[1;2J", "\u{1B}[1J"), .init("\u{1B}[1;2K", "\u{1B}[1K"),
        .init("\u{1B}[?1;2J", "\u{1B}[?1J"), .init("\u{1B}[?1;2K", "\u{1B}[?1K"),
        .init("\u{1B}[1;2g", "\u{1B}[3g"),
        .init("\u{1B}[1;2 q", "\u{1B}[5 q"), .init("\u{1B}[1;2\"q", "\u{1B}[1\"q"),
        .init("\u{1B}[>1;2u", "\u{1B}[>1u"),
        .init("\u{1B}[<1;2u", "\u{1B}[<1u", setup: "\u{1B}[>1u"),
        .init("\u{1B}[=1;2;3u", "\u{1B}[=1;1u"),
        // Exactly one parameter.
        .init("\u{1B}[1;2n", "\u{1B}[6n"), .init("\u{1B}[n", nil),
        .init("\u{1B}[1;2$p", "\u{1B}[1$p"), .init("\u{1B}[?1;2$p", "\u{1B}[?1$p"),
        // No parameters.
        .init("\u{1B}[1s", "\u{1B}[s"),
        .init("\u{1B}[1u", "\u{1B}[u", setup: "\u{1B}[s\u{1B}[H"),
        .init("\u{1B}[1!p", "\u{1B}[!p", setup: "\u{1B}[4h"),
        .init("\u{1B}[?1u", "\u{1B}[?u"),
        // No parameters or a single zero. XTVERSION has no identity in this fixture, so its
        // accepted form is silent too and only the refusal is pinned.
        .init("\u{1B}[1c", "\u{1B}[0c"), .init("\u{1B}[>1q", nil),
    ]

    // Intent: every strict-arity CSI handler refuses one parameter past its width and accepts
    //   its full width, judged only by the whole terminal value and its reply queue.
    // Why it exists: each handler's width is stated beside the handler, so a handler that grows a
    //   parameter and keeps a narrow guard, or a guard widened past its handler, would otherwise
    //   go unnoticed. This roster is the one place the widths are written down.
    // Scenario: a filled 20x6 grid with the cursor mid-screen and a printed cluster behind it, so
    //   every accepted form has something to move, erase, save, or answer.
    @Test("strict-arity CSI handlers refuse one extra parameter and accept their full width",
          arguments: arityRoster)
    func strictArityRoster(_ arity: ArityCase) throws {
        let fixture = "ABCDE\r\nABCDE\r\nABCDE\r\nABCDE\r\nABCDE\u{1B}[3;3H" + arity.setup
        var refused = try #require(Terminal(columns: 20, rows: 6))
        refused.feed(Array(fixture.utf8))
        _ = refused.drainReplyBytes()
        let expected = refused

        refused.feed(Array(arity.refused.utf8))

        #expect(refused == expected)
        #expect(refused.pendingReplyBytes.isEmpty)

        guard let acceptedSequence = arity.accepted else { return }
        var accepted = expected
        accepted.feed(Array(acceptedSequence.utf8))

        #expect(accepted != expected || accepted.pendingReplyBytes.isEmpty == false)
    }

    private func dispatches(_ input: String) -> [CSISequence] {
        dispatches(Array(input.utf8))
    }

    private func dispatches(_ bytes: [UInt8]) -> [CSISequence] {
        var stream = TerminalInputStream()
        return stream.expandedFeed(bytes).compactMap { action in
            guard case let .csi(sequence) = action else { return nil }
            return sequence
        }
    }

    private func run(chunks: [[UInt8]]) -> (actions: [TerminalStreamAction], stream: TerminalInputStream) {
        var stream = TerminalInputStream()
        var actions: [TerminalStreamAction] = []
        for chunk in chunks {
            actions.append(contentsOf: stream.expandedFeed(chunk))
        }
        return (actions, stream)
    }
}
