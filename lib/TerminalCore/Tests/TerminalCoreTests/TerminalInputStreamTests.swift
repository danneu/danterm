// Proves byte-stream decoding and escape absorption before grid mutation consumes the actions.
import Testing

@testable import TerminalCore

/// Locks the stream boundary to chunk-invariant UTF-8 and bounded VT recognition.
struct TerminalInputStreamTests {
    @Test("ground-state bulk-safe Unicode is one scalar run")
    func bulkSafeUnicodeFormsOneRun() {
        // Intent: a complete row of bulk-safe decoded scalars produces one range action.
        // Why it exists: this is the first failing test for widening run granularity beyond ASCII.
        // Scenario: four box-drawing scalars arrive together in ground state.
        let bytes = Array("┌──┐".utf8)
        var stream = TerminalInputStream()
        var index = 0
        var actions: [TerminalStreamAction] = []

        bytes.withUnsafeBufferPointer { buffer in
            while let action = stream.nextAction(in: buffer, from: &index) {
                actions.append(action)
            }
        }

        #expect(actions == [.printScalarRun(0..<bytes.count, isWide: false, scalarCount: 4)])
        #expect(index == bytes.count)
    }

    @Test("ASCII and decoded scalar runs remain separate token kinds")
    func mixedPrintRunsAlternate() {
        // Intent: raw GL bytes and decoded scalars use distinct adjacent run actions.
        // Why it exists: combining the actions would either skip or wrongly apply charset
        //   translation.
        // Scenario: ASCII surrounds two box-drawing scalars in one chunk.
        let bytes = Array("ab─│cd".utf8)
        var stream = TerminalInputStream()
        var index = 0
        var actions: [TerminalStreamAction] = []

        bytes.withUnsafeBufferPointer { buffer in
            while let action = stream.nextAction(in: buffer, from: &index) {
                actions.append(action)
            }
        }

        #expect(actions == [
            .printASCIIRun(0..<2),
            .printScalarRun(2..<8, isWide: false, scalarCount: 2),
            .printASCIIRun(8..<10),
        ])
    }

    @Test("a scalar run is cut where the cell width changes")
    func scalarRunsCarryOneWidth() {
        // Intent: wide and narrow bulk-safe scalars in one chunk produce one run per width, each
        //   labelled with the width it holds.
        // Why it exists: the printer picks its writer from the action's width once per run, so a
        //   run that mixed widths would stamp narrow scalars as wide pairs, or the reverse, with
        //   no per-scalar check left to catch it.
        // Scenario: CJK, box drawing and CJK again arrive together in ground state.
        let bytes = Array("日本─│語".utf8)
        var stream = TerminalInputStream()
        var index = 0
        var actions: [TerminalStreamAction] = []

        bytes.withUnsafeBufferPointer { buffer in
            while let action = stream.nextAction(in: buffer, from: &index) {
                actions.append(action)
            }
        }

        #expect(actions == [
            .printScalarRun(0..<6, isWide: true, scalarCount: 2),
            .printScalarRun(6..<12, isWide: false, scalarCount: 2),
            .printScalarRun(12..<15, isWide: true, scalarCount: 1),
        ])
    }

    @Test("a scalar run counts its scalars, not its bytes")
    func scalarRunCountsScalarsOfEveryEncodedLength() {
        // Intent: the count a run carries is the number of scalars its range decodes to, whatever
        //   mix of two-, three- and four-byte encodings the range holds.
        // Why it exists: the printer sizes its segment requests from this count instead of
        //   re-scanning the bytes for lead bytes, so a count that drifted from the range would
        //   stamp the wrong number of cells with no other check left to catch it.
        // Scenario: a two-byte, a three-byte and a four-byte narrow scalar arrive together, then
        //   the same for wide ones.
        let narrow = Array("\u{00C1}\u{2500}\u{1D400}".utf8)
        var narrowStream = TerminalInputStream()
        var narrowIndex = 0
        var narrowActions: [TerminalStreamAction] = []
        narrow.withUnsafeBufferPointer { buffer in
            while let action = narrowStream.nextAction(in: buffer, from: &narrowIndex) {
                narrowActions.append(action)
            }
        }
        #expect(narrow.count == 9)
        #expect(narrowActions == [.printScalarRun(0..<9, isWide: false, scalarCount: 3)])

        let wide = Array("\u{65E5}\u{20000}".utf8)
        var wideStream = TerminalInputStream()
        var wideIndex = 0
        var wideActions: [TerminalStreamAction] = []
        wide.withUnsafeBufferPointer { buffer in
            while let action = wideStream.nextAction(in: buffer, from: &wideIndex) {
                wideActions.append(action)
            }
        }
        #expect(wide.count == 7)
        #expect(wideActions == [.printScalarRun(0..<7, isWide: true, scalarCount: 2)])
    }

    @Test("scalar runs exclude malformed replacement paths but admit encoded U+FFFD")
    func scalarRunValidityBoundary() {
        // Intent: only a real UTF-8 encoding of U+FFFD can enter a scalar run.
        // Why it exists: malformed maximal-subpart replacement must retain its incremental decoder
        //   consumption and byte re-offer behavior.
        // Scenario: box drawing surrounds one invalid byte, then encoded U+FFFD precedes a box.
        let box = Array("─".utf8)
        let side = Array("│".utf8)
        let malformed = box + [0xFF] + side
        var malformedStream = TerminalInputStream()
        var malformedIndex = 0
        var malformedActions: [TerminalStreamAction] = []
        malformed.withUnsafeBufferPointer { buffer in
            while let action = malformedStream.nextAction(in: buffer, from: &malformedIndex) {
                malformedActions.append(action)
            }
        }
        #expect(malformedActions == [
            .printScalarRun(0..<3, isWide: false, scalarCount: 1),
            .print("\u{FFFD}"),
            .printScalarRun(4..<7, isWide: false, scalarCount: 1),
        ])

        let encoded = Array("\u{FFFD}─".utf8)
        var encodedStream = TerminalInputStream()
        var encodedIndex = 0
        var encodedActions: [TerminalStreamAction] = []
        encoded.withUnsafeBufferPointer { buffer in
            while let action = encodedStream.nextAction(in: buffer, from: &encodedIndex) {
                encodedActions.append(action)
            }
        }
        #expect(encodedActions == [.printScalarRun(0..<encoded.count, isWide: false, scalarCount: 2)])
    }

    @Test("scalar runs preserve actions and pending state at every split")
    func scalarRunChunkBoundaryInvariance() {
        // Intent: scalar-level actions and retained decoder state do not depend on chunk boundaries.
        // Why it exists: the parser probes ahead with a decoder copy while the real decoder stays
        //   idle for an admitted run.
        // Scenario: valid runs, malformed lead bytes, and lone continuations are replayed whole,
        //   bytewise, and across every two-way split.
        let fixtures: [[UInt8]] = [
            Array("─│┌\u{FFFD}┐".utf8),
            Array("─".utf8) + [0xFF] + Array("│".utf8),
            Array("─".utf8) + [0x80] + Array("│".utf8),
        ]

        for bytes in fixtures {
            let expected = run(chunks: [bytes])
            #expect(run(chunks: bytes.map { [$0] }) == expected)
            for offset in 0...bytes.count {
                #expect(
                    run(chunks: [Array(bytes[..<offset]), Array(bytes[offset...])]) == expected
                )
            }
        }
    }

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
        #expect(unknown.expandedFeed(Array("\u{1B}xa".utf8)) == [.escape(0x78), .print("a")])

        var designation = TerminalInputStream()
        #expect(designation.expandedFeed(Array("\u{1B}(Ba".utf8)) == [
            .escapeSequence(EscapeSequence(intermediates: [0x28], final: 0x42)),
            .print("a"),
        ])
    }

    @Test("well-formed UTF-8 emits one print action per scalar")
    func wellFormedUTF8() {
        var stream = TerminalInputStream()

        let actions = stream.expandedFeed(Array("\u{1F604}\u{2724}\u{00C1}A".utf8))

        #expect(actions == [
            .print("\u{1F604}"),
            .print("\u{2724}"),
            .print("\u{00C1}"),
            .print("A"),
        ])
    }

    @Test("decoded ground-state C1 scalars are ignored under every feed split")
    func decodedGroundC1ScalarsAreIgnored() {
        // Intent: every decoded C1 scalar disappears without changing adjacent decoded text.
        // Why it exists: both the incremental and bulk scalar paths previously printed C1 values.
        // Scenario: the full C1 range sits between non-ASCII sentinels in authored, bytewise, and
        //   every two-way split feed.
        let bytes = Array(("é" + (0x80...0x9F).compactMap(UnicodeScalar.init).map(String.init).joined() + "界").utf8)
        let expected: [TerminalStreamAction] = [.print("é"), .print("界")]

        var authored = TerminalInputStream()
        #expect(authored.expandedFeed(bytes) == expected)

        var bytewise = TerminalInputStream()
        #expect(bytes.flatMap { bytewise.expandedFeed([$0]) } == expected)

        for offset in 0...bytes.count {
            var split = TerminalInputStream()
            #expect(
                split.expandedFeed(Array(bytes[..<offset]))
                    + split.expandedFeed(Array(bytes[offset...])) == expected,
                "split at \(offset)"
            )
        }
    }

    @Test("raw C1 bytes, decoded C1 scalars, and U+00A0 remain distinct")
    func c1DecodingBoundary() {
        var stream = TerminalInputStream()

        let actions = stream.expandedFeed([0x80] + Array("\u{0080}\u{009F}\u{00A0}".utf8))

        #expect(actions == [.print("\u{FFFD}"), .print("\u{00A0}")])
    }

    @Test("reference malformed fixture uses maximal-subpart replacement")
    func referenceMalformedFixture() {
        var stream = TerminalInputStream()
        let bytes: [UInt8] = [
            0xF0, 0x9F,
            0xF0, 0x9F, 0x98, 0x84,
            0xED, 0xA0, 0x80,
        ]

        let actions = stream.expandedFeed(bytes)

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

        let actions = stream.expandedFeed(fixture.bytes + [0x41])

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

        let first = stream.expandedFeed(prefix)
        let second = stream.expandedFeed([0x41])

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

        let actions = stream.expandedFeed(bytes)

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

        let actions = stream.expandedFeed([0x41, 0x1B, 0x5B, 0x33, byte, 0x42])

        #expect(actions == [.print("A"), .execute(byte), .print("B")])
    }

    @Test("CAN and SUB abort a DCS data string", arguments: [0x18, 0x1A] as [UInt8])
    func cancellationAbortsDCSDataString(byte: UInt8) {
        // Intent: CAN or SUB inside a DCS data string aborts the string, surfaces as an executed
        //   control, and returns the parser to ground so the bytes after it print.
        // Why it exists: a DCS discards other payload controls such as NUL and BEL, so the parser
        //   must keep CAN and SUB as the opposite case instead of swallowing them as data.
        // Scenario: adapted from windows-terminal `StateMachineTest.cpp`, case
        //   `DcsDataStringsReceivedByHandler`. `ESC P 1;2;3 |` opens a DCS, data arrives, the abort
        //   byte follows, then plain text.
        var stream = TerminalInputStream()

        let bytes = [0x1B, 0x50] + Array("1;2;3|data".utf8) + [byte] + Array("AB".utf8)
        let actions = stream.expandedFeed(bytes)

        #expect(actions == [.execute(byte), .print("A"), .print("B")])
    }

    @Test("ESC inside a sequence restarts recognition")
    func escapeRestartsSequence() {
        var stream = TerminalInputStream()

        let actions = stream.expandedFeed([
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

        let actions = stream.expandedFeed([
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

        let actions = stream.expandedFeed(bytes)

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
        #expect(authored.expandedFeed(bytes) == expected)

        var bytewise = TerminalInputStream()
        #expect(bytes.flatMap { bytewise.expandedFeed([$0]) } == expected)

        for offset in 0...bytes.count {
            var split = TerminalInputStream()
            #expect(split.expandedFeed(Array(bytes[..<offset])) + split.expandedFeed(Array(bytes[offset...])) == expected)
        }
    }

    @Test("control strings preserve C1-range UTF-8 bytes across chunk boundaries")
    func controlStringsPreserveC1RangeUTF8Bytes() {
        let payload = Array((0x80...0x9F).compactMap(UnicodeScalar.init).map(String.init).joined().utf8)
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
            #expect(authored.expandedFeed(input) == expected, "control string at index \(index)")

            var bytewise = TerminalInputStream()
            #expect(
                input.flatMap { bytewise.expandedFeed([$0]) } == expected,
                "bytewise control string at index \(index)"
            )

            for offset in 0...input.count {
                var split = TerminalInputStream()
                let actions = split.expandedFeed(Array(input[..<offset]))
                    + split.expandedFeed(Array(input[offset...]))
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
            let actions = stream.expandedFeed(prefix + [0x1B, 0x37, 0x41])
            #expect(actions == [.escape(0x37), .print("A")])
        }
    }

    @Test("bare ESC finals surface without interpreting their meaning")
    func bareEscapeFinalsSurface() {
        var stream = TerminalInputStream()

        let actions = stream.expandedFeed([
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

        let actions = stream.expandedFeed(Array("\u{1B}#8".utf8))

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

        let actions = stream.expandedFeed([0x1B, 0x5B, 0x33] + fixture.bytes + [0x41])

        #expect(actions == fixture.actions + [.print("A")])
    }

    @Test("CSI entry colon reaches the ignore state required by VT500 grammar")
    func csiEntryColonEntersIgnore() {
        var colon = TerminalInputStream()
        var establishedIgnore = TerminalInputStream()

        _ = colon.expandedFeed([0x1B, 0x5B, 0x3A])
        _ = establishedIgnore.expandedFeed([0x1B, 0x5B, 0x31, 0x3C])

        #expect(colon == establishedIgnore)
    }

    @Test("a raw ground-state C1 byte is malformed UTF-8")
    func rawGroundC1IsMalformedUTF8() {
        var stream = TerminalInputStream()

        let actions = stream.expandedFeed([0x9B, 0x41])

        #expect(actions == [.print("\u{FFFD}"), .print("A")])
    }

    @Test("ESC arriving mid-UTF-8 replaces the partial scalar then starts a sequence")
    func escapeMidUTF8() {
        var stream = TerminalInputStream()

        let actions = stream.expandedFeed([0xE2, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x41])

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
        _ = utf8A.expandedFeed([0xE2])
        _ = utf8B.expandedFeed([0xE3])
        _ = sequence.expandedFeed([0x1B, 0x5B])

        #expect(utf8A != utf8B)
        #expect(utf8A != sequence)
        #expect(sequence != TerminalInputStream())
    }

    @Test("stream values replay deterministically and copies remain independent")
    func replayAndCopyIsolation() {
        let bytes: [UInt8] = [0xE2, 0x82, 0xAC, 0x1B, 0x5B, 0x6D, 0x41]
        var first = TerminalInputStream()
        var second = TerminalInputStream()

        let firstActions = first.expandedFeed(bytes)
        let secondActions = second.expandedFeed(bytes)
        let copy = first
        _ = first.expandedFeed([0xE2])

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
            var generator = SeededByteGenerator(state: seed &+ 1)
            var bytes: [UInt8] = []
            for _ in 0..<128 {
                bytes.append(generator.nextByte())
            }

            var stream = TerminalInputStream()
            _ = stream.expandedFeed(bytes)
            let recovery = stream.expandedFeed([0x18, 0x7C])

            #expect(recovery.last == .print("|"))
        }
    }

    @Test("the cursor yields one action per call and consumes the whole chunk")
    func streamingCursorConsumesTheChunk() {
        // Intent: `nextAction(in:from:)` hands back exactly one token per call, advances the index
        //   only over the bytes that token consumed, and reports the chunk exhausted by returning
        //   nil at `bytes.count` -- including when the chunk ends inside an unfinished sequence.
        // Why it exists: this is the seam that replaced the eager `[TerminalStreamAction]`
        //   (`research/33/T7`). The grid reducer mutates the terminal between two calls, so an
        //   index that ran ahead of the token it returned, or a call that emitted two tokens'
        //   worth of parser progress, would drop or duplicate a grid mutation with nothing else
        //   in the suite positioned to see it.
        // Scenario: a chunk holding a printable ASCII run, a control, a full CSI and a truncated
        //   CSI is pulled one token at a time.
        var stream = TerminalInputStream()
        let bytes: [UInt8] = [0x41, 0x42, 0x0A, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x1B, 0x5B, 0x33]

        let csi31m = CSISequence(
            parameters: [31],
            colonSeparators: [false],
            intermediates: [],
            final: 0x6D
        )
        var index = 0
        var actions: [TerminalStreamAction] = []
        var indicesAfterEachAction: [Int] = []
        bytes.withUnsafeBufferPointer { buffer in
            while let action = stream.nextAction(in: buffer, from: &index) {
                actions.append(action)
                indicesAfterEachAction.append(index)
            }
        }

        // The run is one token covering both printables, which is what amortizes the per-token
        // boundary this seam introduces (`research/33/T8`).
        #expect(actions == [
            .printASCIIRun(0..<2),
            .execute(0x0A),
            .csi(csi31m),
        ])
        #expect(indicesAfterEachAction == [2, 3, 8])
        #expect(index == bytes.count)
        // The truncated CSI stayed in the absorber rather than being dropped or emitted.
        #expect(stream.expandedFeed([0x31, 0x6D]) == [.csi(csi31m)])
    }

    private func run(chunks: [[UInt8]]) -> (actions: [TerminalStreamAction], stream: TerminalInputStream) {
        var stream = TerminalInputStream()
        var actions: [TerminalStreamAction] = []
        for chunk in chunks {
            actions.append(contentsOf: stream.expandedFeed(chunk))
        }
        return (actions, stream)
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
