// Proves byte-stream decoding and escape absorption before grid mutation consumes the actions.
import Testing

@testable import TerminalCore

/// Locks the stream boundary to chunk-invariant UTF-8 and bounded VT recognition.
struct TerminalInputStreamTests {
    @Test("unknown ESC and unsupported charset designation swallow only their own bytes")
    func escapeRecoveryAndCharsetDesignationBoundaries() {
        // Intent: unknown single-byte ESC dispatch and unsupported SCS designation consume their
        //   complete sequences while allowing the next printable byte to reach the grid.
        // Why it exists: without an SCS boundary case, `ESC ( B` could leak `B` into nearly every
        //   ncurses application's initial screen or swallow the printable byte after it.
        // Scenario: an application emits an unknown escape or selects ASCII into G0, then prints `a`.
        // Adapted from kitty_tests/parser.py#test_esc_codes
        //   (kitty v0.48.2 2cb1d95, body sha256:d642630555b3).
        //   Divergence: uses the common `ESC ( B` SCS sequence and asserts parser actions; kitty
        //   probes `ESC . ESC` and diagnostic callbacks that DanTerm deliberately does not expose.
        var unknown = TerminalInputStream()
        #expect(unknown.feed(Array("\u{1B}xa".utf8)) == [.escape(0x78), .print("a")])

        var designation = TerminalInputStream()
        #expect(designation.feed(Array("\u{1B}(Ba".utf8)) == [
            .escapeSequence(EscapeSequence(intermediates: [0x28], final: 0x42)),
            .print("a"),
        ])
    }

    @Test("well-formed UTF-8 emits one print action per scalar")
    func wellFormedUTF8() {
        var stream = TerminalInputStream()

        let actions = stream.feed(Array("\u{1F604}\u{2724}\u{00C1}A".utf8))

        #expect(actions == [
            .print("\u{1F604}"),
            .print("\u{2724}"),
            .print("\u{00C1}"),
            .print("A"),
        ])
    }

    @Test("reference malformed fixture uses maximal-subpart replacement")
    func referenceMalformedFixture() {
        var stream = TerminalInputStream()
        let bytes: [UInt8] = [
            0xF0, 0x9F,
            0xF0, 0x9F, 0x98, 0x84,
            0xED, 0xA0, 0x80,
        ]

        let actions = stream.feed(bytes)

        #expect(actions == [
            .print("\u{FFFD}"),
            .print("\u{1F604}"),
            .print("\u{FFFD}"),
            .print("\u{FFFD}"),
            .print("\u{FFFD}"),
        ])
    }

    @Test(
        "malformed UTF-8 recovers without desynchronizing valid text",
        arguments: [
            MalformedFixture(bytes: [0x80], replacementCount: 1),
            MalformedFixture(bytes: [0xC0, 0xAF], replacementCount: 2),
            MalformedFixture(bytes: [0xED, 0xA0, 0x80], replacementCount: 3),
            MalformedFixture(bytes: [0xF4, 0x90, 0x80, 0x80], replacementCount: 4),
            MalformedFixture(bytes: [0xF5, 0x80, 0x80, 0x80], replacementCount: 4),
        ]
    )
    func malformedUTF8Recovers(fixture: MalformedFixture) {
        var stream = TerminalInputStream()

        let actions = stream.feed(fixture.bytes + [0x41])

        #expect(actions.last == .print("A"))
        #expect(actions.dropLast().count == fixture.replacementCount)
        #expect(actions.dropLast().allSatisfy { $0 == .print("\u{FFFD}") })
    }

    @Test(
        "truncated UTF-8 stays pending until a later byte proves it malformed",
        arguments: [[0xE2], [0xE2, 0x82]] as [[UInt8]]
    )
    func truncatedUTF8AcrossChunks(prefix: [UInt8]) {
        var stream = TerminalInputStream()

        let first = stream.feed(prefix)
        let second = stream.feed([0x41])

        #expect(first.isEmpty)
        #expect(second == [.print("\u{FFFD}"), .print("A")])
    }

    @Test(
        "7-bit VT sequence families are consumed and printable text resumes",
        arguments: [
            [0x41, 0x1B, 0x37, 0x42],
            [0x41, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x42],
            [0x41, 0x1B, 0x5D, 0x30, 0x3B, 0x78, 0x07, 0x42],
            [0x41, 0x1B, 0x5D, 0x30, 0x3B, 0x78, 0x1B, 0x5C, 0x42],
            [0x41, 0x1B, 0x50, 0x71, 0x78, 0x1B, 0x5C, 0x42],
            [0x41, 0x1B, 0x58, 0x78, 0x1B, 0x5C, 0x42],
            [0x41, 0x1B, 0x5E, 0x78, 0x1B, 0x5C, 0x42],
            [0x41, 0x1B, 0x5F, 0x78, 0x1B, 0x5C, 0x42],
        ] as [[UInt8]]
    )
    func sevenBitFamiliesAreAbsorbed(bytes: [UInt8]) {
        var stream = TerminalInputStream()

        let actions = stream.feed(bytes)

        let csi = TerminalStreamAction.csi(CSISequence(
            parameters: [31],
            colonSeparators: [false],
            intermediates: [],
            final: 0x6D
        ))
        var expected: [TerminalStreamAction] = [.print("A")]
        if bytes[1...].starts(with: [0x1B, 0x5B]) {
            expected.append(csi)
        } else if bytes[1...].starts(with: [0x1B, 0x37]) {
            expected.append(.escape(0x37))
        } else if bytes[1...].starts(with: [0x1B, 0x5D]) {
            expected.append(.osc(Array("0;x".utf8)))
        } else if bytes.contains(0x5C) {
            expected.append(.escape(0x5C))
        }
        expected.append(.print("B"))
        #expect(actions == expected)
    }

    @Test("CAN and SUB abort sequences and execute as controls", arguments: [0x18, 0x1A] as [UInt8])
    func cancellationAbortsSequence(byte: UInt8) {
        var stream = TerminalInputStream()

        let actions = stream.feed([0x41, 0x1B, 0x5B, 0x33, byte, 0x42])

        #expect(actions == [.print("A"), .execute(byte), .print("B")])
    }

    @Test("ESC inside a sequence restarts recognition")
    func escapeRestartsSequence() {
        var stream = TerminalInputStream()

        let actions = stream.feed([
            0x41,
            0x1B, 0x5B, 0x33, 0x31,
            0x1B, 0x5D, 0x30, 0x3B, 0x78, 0x07,
            0x42,
        ])

        #expect(actions == [.print("A"), .osc(Array("0;x".utf8)), .print("B")])
    }

    @Test("C0 controls execute inside ESC and CSI sequences")
    func controlsExecuteInsideSequences() {
        var stream = TerminalInputStream()

        let actions = stream.feed([
            0x1B, 0x00, 0x37,
            0x1B, 0x5B, 0x33, 0x07, 0x31, 0x6D,
            0x41,
        ])

        #expect(actions == [
            .execute(0x00),
            .escape(0x37),
            .execute(0x07),
            .csi(CSISequence(
                parameters: [31],
                colonSeparators: [false],
                intermediates: [],
                final: 0x6D
            )),
            .print("A"),
        ])
    }

    @Test(
        "payload controls are discarded while the ST final is surfaced",
        arguments: [
            [0x1B, 0x50, 0x71, 0x00, 0x07, 0x1B, 0x5C, 0x41],
            [0x1B, 0x5D, 0x78, 0x00, 0x1B, 0x5C, 0x41],
            [0x1B, 0x58, 0x00, 0x07, 0x1B, 0x5C, 0x41],
        ] as [[UInt8]]
    )
    func payloadControlsAreDiscarded(bytes: [UInt8]) {
        var stream = TerminalInputStream()

        let actions = stream.feed(bytes)

        if bytes[1] == 0x5D {
            #expect(actions == [.osc([0x78]), .print("A")])
        } else {
            #expect(actions == [.escape(0x5C), .print("A")])
        }
    }

    @Test("OSC preserves U+2733 bytes without leaking payload text")
    func oscPreservesU2733Payload() {
        let payload = Array("0;printf '✳'".utf8)
        let bytes = [0x1B, 0x5D] + payload + [0x07]
        let expected = [TerminalStreamAction.osc(payload)]

        var authored = TerminalInputStream()
        #expect(authored.feed(bytes) == expected)

        var bytewise = TerminalInputStream()
        #expect(bytes.flatMap { bytewise.feed([$0]) } == expected)

        for offset in 0...bytes.count {
            var split = TerminalInputStream()
            #expect(split.feed(Array(bytes[..<offset])) + split.feed(Array(bytes[offset...])) == expected)
        }
    }

    @Test("control strings absorb C1-range UTF-8 continuation bytes across chunk boundaries")
    func controlStringsAbsorbUTF8ContinuationBytes() {
        let payload = Array((0x0400...0x041F).compactMap(UnicodeScalar.init).map(String.init).joined().utf8)
        let strings: [[UInt8]] = [
            [0x1B, 0x5D] + payload + [0x07],
            [0x1B, 0x5D] + payload + [0x1B, 0x5C],
            [0x1B, 0x50, 0x71] + payload + [0x1B, 0x5C],
            [0x1B, 0x5F] + payload + [0x1B, 0x5C],
            [0x1B, 0x5E] + payload + [0x1B, 0x5C],
            [0x1B, 0x58] + payload + [0x1B, 0x5C],
        ]

        for (index, bytes) in strings.enumerated() {
            let input = bytes + [0x41]
            let expected: [TerminalStreamAction] = index < 2
                ? [.osc(payload), .print("A")]
                : [.escape(0x5C), .print("A")]

            var authored = TerminalInputStream()
            #expect(authored.feed(input) == expected, "control string at index \(index)")

            var bytewise = TerminalInputStream()
            #expect(
                input.flatMap { bytewise.feed([$0]) } == expected,
                "bytewise control string at index \(index)"
            )

            for offset in 0...input.count {
                var split = TerminalInputStream()
                let actions = split.feed(Array(input[..<offset]))
                    + split.feed(Array(input[offset...]))
                #expect(
                    actions == expected,
                    "control string at index \(index), split at \(offset)"
                )
            }
        }
    }

    @Test("ESC restart cancels every control string without OSC dispatch")
    func escapeRestartCancelsControlStrings() {
        let prefixes: [[UInt8]] = [
            [0x1B, 0x5D, 0x39, 0x3B, 0x78],
            [0x1B, 0x50, 0x71, 0x78],
            [0x1B, 0x5F, 0x78],
            [0x1B, 0x5E, 0x78],
            [0x1B, 0x58, 0x78],
        ]

        for prefix in prefixes {
            var stream = TerminalInputStream()
            let actions = stream.feed(prefix + [0x1B, 0x37, 0x41])
            #expect(actions == [.escape(0x37), .print("A")])
        }
    }

    @Test("bare ESC finals surface without interpreting their meaning")
    func bareEscapeFinalsSurface() {
        var stream = TerminalInputStream()

        let actions = stream.feed([
            0x1B, 0x44,
            0x1B, 0x45,
            0x1B, 0x4D,
            0x1B, 0x37,
        ])

        #expect(actions == [
            .escape(0x44),
            .escape(0x45),
            .escape(0x4D),
            .escape(0x37),
        ])
    }

    @Test("ESC intermediates remain available to terminal dispatch")
    func escapeIntermediatesSurface() {
        var stream = TerminalInputStream()

        let actions = stream.feed(Array("\u{1B}#8".utf8))

        #expect(actions == [
            .escapeSequence(EscapeSequence(intermediates: [0x23], final: 0x38)),
        ])
    }

    @Test(
        "raw C1 anywhere transitions apply only while absorbing a sequence",
        arguments: [
            C1Fixture(bytes: [0x90, 0x71, 0x78, 0x9C, 0x1B, 0x5C], actions: [.escape(0x5C)]),
            C1Fixture(bytes: [0x98, 0x78, 0x9C, 0x1B, 0x5C], actions: [.escape(0x5C)]),
            C1Fixture(bytes: [0x9E, 0x78, 0x9C, 0x1B, 0x5C], actions: [.escape(0x5C)]),
            C1Fixture(bytes: [0x9F, 0x78, 0x9C, 0x1B, 0x5C], actions: [.escape(0x5C)]),
            C1Fixture(
                bytes: [0x9B, 0x6D],
                actions: [.csi(CSISequence(
                    parameters: [],
                    colonSeparators: [],
                    intermediates: [],
                    final: 0x6D
                ))]
            ),
            C1Fixture(bytes: [0x9D, 0x78, 0x07], actions: [.osc([0x78])]),
            C1Fixture(bytes: [0x80], actions: [.execute(0x80)]),
            C1Fixture(bytes: [0x91], actions: [.execute(0x91)]),
            C1Fixture(bytes: [0x99], actions: [.execute(0x99)]),
            C1Fixture(bytes: [0x9A], actions: [.execute(0x9A)]),
        ]
    )
    func rawC1TransitionsInsideSequence(fixture: C1Fixture) {
        var stream = TerminalInputStream()

        let actions = stream.feed([0x1B, 0x5B, 0x33] + fixture.bytes + [0x41])

        #expect(actions == fixture.actions + [.print("A")])
    }

    @Test("CSI entry colon reaches the ignore state required by VT500 grammar")
    func csiEntryColonEntersIgnore() {
        var colon = TerminalInputStream()
        var establishedIgnore = TerminalInputStream()

        _ = colon.feed([0x1B, 0x5B, 0x3A])
        _ = establishedIgnore.feed([0x1B, 0x5B, 0x31, 0x3C])

        #expect(colon == establishedIgnore)
    }

    @Test("a raw ground-state C1 byte is malformed UTF-8")
    func rawGroundC1IsMalformedUTF8() {
        var stream = TerminalInputStream()

        let actions = stream.feed([0x9B, 0x41])

        #expect(actions == [.print("\u{FFFD}"), .print("A")])
    }

    @Test("ESC arriving mid-UTF-8 replaces the partial scalar then starts a sequence")
    func escapeMidUTF8() {
        var stream = TerminalInputStream()

        let actions = stream.feed([0xE2, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x41])

        #expect(actions == [
            .print("\u{FFFD}"),
            .csi(CSISequence(
                parameters: [31],
                colonSeparators: [false],
                intermediates: [],
                final: 0x6D
            )),
            .print("A"),
        ])
    }

    @Test("all 2-way and 3-way chunk splits preserve actions and pending state")
    func chunkBoundaryInvariance() {
        // Intent: prove chunking cannot alter decoded actions or unfinished
        //   decoder and absorber state across representative stream content.
        // Why it exists: callers feed PTY reads at arbitrary boundaries, often
        //   splitting UTF-8 and control sequences at their most fragile points.
        // Scenario: Spanish, Chinese, emoji, controls, malformed bytes, and VT
        //   sequences arrive in every possible two- and three-chunk partition.
        let fixtures: [[UInt8]] = [
            Array("ma\u{00F1}ana".utf8),
            Array("man\u{0303}ana".utf8),
            Array("\u{754C}\u{1F618}".utf8),
            [0x41, 0x0D, 0x0A, 0x42],
            [0xF0, 0x9F, 0x41, 0x80, 0x42],
            [0x41, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x42],
            [0x41, 0x1B, 0x5D, 0x30, 0x3B, 0x78, 0x1B, 0x5C, 0x42],
            [0xE2, 0x82],
            [0x1B, 0x5B, 0x33],
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

    @Test("stream equality includes pending decoder and absorber state")
    func pendingStateParticipatesInEquality() {
        var utf8A = TerminalInputStream()
        var utf8B = TerminalInputStream()
        var sequence = TerminalInputStream()
        _ = utf8A.feed([0xE2])
        _ = utf8B.feed([0xE3])
        _ = sequence.feed([0x1B, 0x5B])

        #expect(utf8A != utf8B)
        #expect(utf8A != sequence)
        #expect(sequence != TerminalInputStream())
    }

    @Test("stream values replay deterministically and copies remain independent")
    func replayAndCopyIsolation() {
        let bytes: [UInt8] = [0xE2, 0x82, 0xAC, 0x1B, 0x5B, 0x6D, 0x41]
        var first = TerminalInputStream()
        var second = TerminalInputStream()

        let firstActions = first.feed(bytes)
        let secondActions = second.feed(bytes)
        let copy = first
        _ = first.feed([0xE2])

        #expect(firstActions == secondActions)
        #expect(copy == second)
        #expect(copy != first)
    }

    @Test("seeded arbitrary bytes recover after CAN and print a sentinel")
    func deterministicFuzzRecovery() {
        // Intent: exercise arbitrary decoder and absorber transitions while
        //   proving a forced cancellation always restores useful processing.
        // Why it exists: terminal input is untrusted and must neither trap nor
        //   remain poisoned after malformed UTF-8 or an unfinished VT string.
        // Scenario: deterministic pseudo-random PTY blobs are followed by CAN
        //   and an ASCII sentinel that the next terminal layer must receive.
        for seed in UInt64(0)..<256 {
            var generator = Generator(state: seed &+ 1)
            var bytes: [UInt8] = []
            for _ in 0..<128 {
                bytes.append(generator.next())
            }

            var stream = TerminalInputStream()
            _ = stream.feed(bytes)
            let recovery = stream.feed([0x18, 0x7C])

            #expect(recovery.last == .print("|"))
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

    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        }
    }

    struct MalformedFixture: Sendable {
        let bytes: [UInt8]
        let replacementCount: Int
    }

    struct C1Fixture: Sendable {
        let bytes: [UInt8]
        let actions: [TerminalStreamAction]
    }
}
