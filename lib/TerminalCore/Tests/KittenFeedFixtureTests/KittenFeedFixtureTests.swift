// Behavioral tests for the kitten `__benchmark__ --render` port: the two deterministic
// payloads against the reference, the two seeded ones against the distributions kitten
// draws from, and every arm's stream against the terminal state kitten leaves behind.
//
// The expected digests and lengths below were computed from kitty v0.48.2 (2cb1d95)
// `tools/cmd/benchmark/main.go` by an independent implementation of its loops, not by
// asking this port what it produces. `scripts/kitten-benchmark-parity-lint.py` is the
// other half: it re-reads the reference and fails when a constant here drifts from it.
import CryptoKit
import Foundation
import TerminalCore
import Testing

@testable import KittenFeedFixture

@Suite("Kitten feed fixture")
struct KittenFeedFixtureTests {
    // MARK: Deterministic arms

    @Test("the unicode payload matches the reference byte for byte")
    func unicodePayloadMatchesReference() {
        let payload = KittenFeedGenerator.payload(for: .unicode)

        #expect(payload.count == 1_897_472)
        #expect(
            digest(payload)
                == "d5c85baa3324d1f35a7ac69f020494d7ec82fd281ceaf72bafa17ae871679c4a"
        )
    }

    @Test("the unique-unicode payload matches the reference byte for byte")
    func uniqueUnicodePayloadMatchesReference() {
        let payload = KittenFeedGenerator.payload(for: .uniqueUnicode)

        // 262,144 cells, each `a` plus three two-byte combining marks.
        #expect(payload.count == 262_144 * 7)
        #expect(
            digest(payload)
                == "e24ca5bf1ab1c7eca80a124b666a220bef9fd8bc6a30247f8288827b60d6f516"
        )
    }

    @Test("the unicode payload repeats one lorem-plus-misc unit at a fixed stride")
    func unicodePayloadRepeatsItsUnit() {
        // Intent: the payload is the same 1,853-byte unit 1024 times, which is the shape
        //   `strings.Repeat` gives it.
        // Why it exists: a digest match proves equality but says nothing about what broke
        //   when it fails. This names the structure a reader can debug against.
        let payload = KittenFeedGenerator.payload(for: .unicode)
        let stride = payload.count / KittenFeedGenerator.unicodeRepeatCount

        #expect(stride == 1853)
        #expect(Array(payload[0..<stride]) == Array(payload[stride..<(2 * stride)]))
        #expect(Array(payload[0..<stride]) == Array(payload[(payload.count - stride)...]))
    }

    @Test("unique-unicode cells carry the reference's base-0x70 combining marks")
    func uniqueUnicodeCellsUseBase0x70Marks() {
        // Intent: cell `i` is `a` followed by U+0300 + the base-0x70 digits of `i`.
        // Why it exists: this is the rule that makes every cell's grapheme distinct, which
        //   is the whole point of the arm; a digest failure would not say which digit slipped.
        let payload = KittenFeedGenerator.payload(for: .uniqueUnicode)
        let text = String(decoding: payload, as: UTF8.self)
        let cells = Array(text.unicodeScalars)

        #expect(cells[0] == "a")
        #expect(cells[1].value == 0x300)
        #expect(cells[2].value == 0x300)
        #expect(cells[3].value == 0x300)
        // Cell 0x71 = 1 * 0x70 + 1, so its low digit is 1 and its next digit is 1.
        let offset = 0x71 * 4
        #expect(cells[offset] == "a")
        #expect(cells[offset + 1].value == 0x300 + 1)
        #expect(cells[offset + 2].value == 0x300 + 1)
        #expect(cells[offset + 3].value == 0x300)
    }

    // MARK: Seeded arms

    @Test("the seeded arms are reproducible and change with the seed")
    func seededArmsAreReproducibleAndSeedDependent() {
        for arm in [KittenFeedArm.ascii, .csi] {
            let first = KittenFeedGenerator.payload(for: arm)
            let second = KittenFeedGenerator.payload(for: arm)
            let other = KittenFeedGenerator.payload(for: arm, seed: KittenFeedGenerator.seed + 1)

            #expect(first == second)
            #expect(first != other)
        }
    }

    @Test("the ascii payload is the reference size and draws only from the alphabet")
    func asciiPayloadSizeAndAlphabet() {
        let payload = KittenFeedGenerator.payload(for: .ascii)
        let alphabet = Set(Array(KittenFeedGenerator.asciiAlphabet.utf8))

        #expect(payload.count == 2_097_165)
        #expect(alphabet.count == 87)  // 88 entries, space twice
        #expect(payload.allSatisfy { alphabet.contains($0) })
    }

    @Test("the ascii draw is uniform over the indexed alphabet, space twice over")
    func asciiDrawIsUniformOverTheIndexedAlphabet() {
        // Intent: every one of the 88 indexed entries lands near 1/88 of the payload, so
        //   space -- which kitten lists twice -- lands near 2/88.
        // Why it exists: a deterministic generator can still be skewed. A skewed alphabet
        //   would change the parser's work per byte while the arm still looked reproducible,
        //   and the ladder would compare two terminals on a stimulus kitten never sends.
        let payload = KittenFeedGenerator.payload(for: .ascii)
        var counts: [UInt8: Int] = [:]
        for byte in payload { counts[byte, default: 0] += 1 }

        let entries = Array(KittenFeedGenerator.asciiAlphabet.utf8)
        let expectedShare = 1.0 / Double(entries.count)
        for byte in Set(entries) {
            let listings = entries.filter { $0 == byte }.count
            let share = Double(counts[byte] ?? 0) / Double(payload.count)
            #expect(abs(share - expectedShare * Double(listings)) < 0.001)
        }
        #expect(counts[UInt8(ascii: " ")] ?? 0 > counts[UInt8(ascii: "a")] ?? 0)
    }

    @Test("the csi payload is at least the reference size and ends with a reset")
    func csiPayloadSizeAndTail() {
        let payload = KittenFeedGenerator.payload(for: .csi)

        #expect(payload.count >= 1_048_593)
        #expect(Array(payload.suffix(3)) == Array("\u{1b}[m".utf8))
    }

    @Test("the csi draw splits into the reference's bands and run lengths")
    func csiDrawMatchesItsBandsAndRunLengths() {
        // Intent: over the fixed seed, each fixed chunk's share of the draws lands near its
        //   band width (10/20/10/10/10/20/20 percent), and the random ASCII runs are near
        //   uniform on 1...72.
        // Why it exists: the `csi` arm exists to measure escape-sequence parsing, so the mix
        //   of sequences is the stimulus. A generator that is deterministic but band-skewed
        //   would silently benchmark a different workload than kitten's.
        let payload = KittenFeedGenerator.payload(for: .csi)
        let draws = replayCSIDraws()

        var bandCounts = [Int](repeating: 0, count: KittenFeedGenerator.csiChunks.count)
        var runLengths: [Int] = []
        for draw in draws {
            bandCounts[draw.band] += 1
            if let runLength = draw.runLength { runLengths.append(runLength) }
        }
        let total = Double(draws.count)
        for (index, chunk) in KittenFeedGenerator.csiChunks.enumerated() {
            let expected = Double(chunk.upperBound - chunk.lowerBound) / 100.0
            #expect(abs(Double(bandCounts[index]) / total - expected) < 0.01)
        }

        var lengthCounts = [Int](repeating: 0, count: KittenFeedGenerator.csiRunLengthBound + 1)
        for length in runLengths { lengthCounts[length] += 1 }
        let expectedRunShare = 1.0 / Double(KittenFeedGenerator.csiRunLengthBound)
        for length in 1...KittenFeedGenerator.csiRunLengthBound {
            let share = Double(lengthCounts[length]) / Double(runLengths.count)
            #expect(abs(share - expectedRunShare) < 0.005)
        }
        #expect(payload.count >= runLengths.reduce(0, +))
    }

    // MARK: The stream

    @Test("every arm's stream enters the alt screen, prints its own line, and restores")
    func streamWrapsThePayloadInKittensTerminalState() {
        // Intent: one pass over each arm's three portions leaves the terminal on the alt
        //   screen with the cursor hidden after setup, renders that arm's exact `Running:`
        //   line, and ends back on the primary screen with the cursor visible.
        // Why it exists: the wrapper decides which scroll branch the payload runs down
        //   (39/F1: the whole-viewport rotation never runs on the alt screen), so it is
        //   part of the stimulus rather than framing around it. The rendered line also
        //   catches a routing error that maps one arm's name onto another arm's bytes --
        //   the four arms share one code path but get four separate frozen rules.
        for arm in KittenFeedArm.allCases {
            let payload = KittenFeedGenerator.payload(for: arm)
            let stream = KittenFeedGenerator.stream(for: arm)
            let reset = "Running: " + arm.description
            let firstRepetition =
                payload.count + KittenFeedGenerator.clearScreen.utf8.count + reset.utf8.count + 2
            var terminal = Terminal(
                columns: KittenFeedGenerator.columns, rows: KittenFeedGenerator.rows
            )!

            terminal.feed(stream.setup)
            #expect(terminal.isAlternateScreenActive)
            #expect(terminal.presentation.isCursorVisible == false)

            terminal.feed(Array(stream.timed[0..<firstRepetition]))
            #expect(firstViewportLine(of: &terminal, length: reset.count) == reset)

            terminal.feed(Array(stream.timed[firstRepetition...]))
            #expect(terminal.isAlternateScreenActive)

            terminal.feed(stream.teardown)
            #expect(terminal.isAlternateScreenActive == false)
            #expect(terminal.presentation.isCursorVisible)
        }
    }

    @Test("the timed portion repeats the payload and closes with three status reports")
    func timedPortionCarriesRepetitionsAndTheStatusReportTail() {
        for arm in KittenFeedArm.allCases {
            let payload = KittenFeedGenerator.payload(for: arm)
            let stream = KittenFeedGenerator.stream(for: arm)
            let reset = Array(
                (KittenFeedGenerator.clearScreen + "Running: " + arm.description + "\r\n").utf8
            )
            let tail = Array(
                (KittenFeedGenerator.clearScreen
                    + "Waiting for response indicating parsing finished\r\n"
                    + String(
                        repeating: KittenFeedGenerator.deviceStatusReport,
                        count: KittenFeedGenerator.deviceStatusReportCount
                    )).utf8
            )

            #expect(
                stream.timed.count
                    == (payload.count + reset.count) * KittenFeedGenerator.repetitions + tail.count
            )
            #expect(Array(stream.timed.prefix(payload.count)) == payload)
            #expect(
                Array(stream.timed[payload.count..<(payload.count + reset.count)]) == reset
            )
            #expect(Array(stream.timed.suffix(tail.count)) == tail)
            // R must keep the reset-between-repetitions path inside the measured stream.
            #expect(KittenFeedGenerator.repetitions >= 2)
        }
    }

    // MARK: Helpers

    /// A replay of `csiPayload`'s draw sequence, built from the published band table rather
    /// than from the generator's private loop, so the distribution assertions do not simply
    /// restate the code they check.
    private func replayCSIDraws() -> [(band: Int, runLength: Int?)] {
        var random = KittenFeedRandom(seed: KittenFeedGenerator.seed)
        var produced = 0
        var draws: [(band: Int, runLength: Int?)] = []
        while produced < KittenFeedGenerator.csiPayloadMinimumSize {
            let draw = random.index(below: 100)
            let band = KittenFeedGenerator.csiChunks.firstIndex {
                draw >= $0.lowerBound && draw < $0.upperBound
            }!
            if let text = KittenFeedGenerator.csiChunks[band].text {
                produced += text.utf8.count
                draws.append((band, nil))
            } else {
                let runLength = random.index(below: KittenFeedGenerator.csiRunLengthBound) + 1
                for _ in 0..<runLength {
                    _ = random.index(below: KittenFeedGenerator.asciiAlphabet.utf8.count)
                }
                produced += runLength
                draws.append((band, runLength))
            }
        }
        return draws
    }

    /// Reads the leading `length` cells of the top viewport row through the public
    /// selection API, so the assertion is about what the screen shows, not about the
    /// bytes that were fed.
    private func firstViewportLine(of terminal: inout Terminal, length: Int) -> String? {
        terminal.setSelection(
            TerminalTextRange(
                start: TerminalTextPosition(row: 0, column: 0),
                end: TerminalTextPosition(row: 0, column: length)
            )
        )
        return terminal.selectedText
    }

    private func digest(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
