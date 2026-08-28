// The kitten `__benchmark__ --render` byte streams, ported to Swift so the A/B ladder
// and the profiling driver replay one definition of each arm.
//
// This file holds the stimulus only: the four payloads, the alt-screen wrapper kitten
// writes around them, and the seeded draws the two random arms need. It does not feed a
// terminal, time anything, or know about the ladder's framing -- those belong to
// TerminalCoreBenchmarkSupport and to the Python collector.
//
// Every constant below is transcribed from these two files, and
// `scripts/kitten-benchmark-parity-lint.py` re-reads both and fails when this port drifts
// from them. Do not edit a constant here without running that lint.
//
// Adapted from tools/cmd/benchmark/main.go (kitty v0.48.2 2cb1d95, body sha256:04682c7bc2c5).
// Adapted from tools/tui/loop/terminal-state.go (kitty v0.48.2 2cb1d95, body sha256:4096791a98d5).

/// One `kitten __benchmark__` arm that renders text. The four cases are exactly the arms
/// research 39 is chasing; `long_escape_codes` and `images` are out of scope there.
public enum KittenFeedArm: String, CaseIterable, Sendable {
    case ascii
    case unicode
    case uniqueUnicode = "unique-unicode"
    case csi

    /// The description string kitten prints between repetitions. It is part of the
    /// stimulus (the terminal parses it every repetition), so it is matched byte for byte.
    public var description: String {
        switch self {
        case .ascii: return "Only ASCII chars"
        case .unicode: return "Unicode chars"
        case .uniqueUnicode: return "Unique multi-codepoint Unicode cells"
        case .csi: return "CSI codes with few chars"
        }
    }
}

/// A generated arm split at the boundaries kitten's own timer uses: it starts the clock
/// after writing the terminal state and stops it before the deferred restore. Keeping the
/// three portions apart is what lets the harness time what kitten times, so a change that
/// only speeds up RIS or alt-screen teardown cannot move the arm.
public struct KittenFeedStream: Sendable, Equatable {
    public let setup: [UInt8]
    public let timed: [UInt8]
    public let teardown: [UInt8]

    public init(setup: [UInt8], timed: [UInt8], teardown: [UInt8]) {
        self.setup = setup
        self.timed = timed
        self.teardown = teardown
    }
}

/// The parameters `scripts/kitten-benchmark-parity-lint.py` compares against the pinned
/// kitty sources. It is the port's own account of what it encodes, printed as JSON by the
/// benchmark executable's `describe` command, so the lint checks behavior rather than the
/// layout of this file.
public struct KittenFeedParameters: Codable, Equatable, Sendable {
    public let alphabet: String
    public let controlCharacters: String
    public let chineseLoremIpsum: String
    public let miscUnicode: String
    public let asciiPayloadSize: Int
    public let csiPayloadMinimumSize: Int
    public let csiRunLengthBound: Int
    public let uniqueUnicodeCellCount: Int
    public let uniqueUnicodeCombiningCount: Int
    public let uniqueUnicodeMarksPerCell: Int
    public let unicodeRepeatCount: Int
    public let csiChunks: [CSIChunk]
    public let descriptions: [String: String]
    public let clearScreen: String
    public let resetSequence: String
    public let deviceStatusReport: String
    public let deviceStatusReportCount: Int
    public let setupSequence: String
    public let teardownSequence: String
    public let repetitions: Int
    public let seed: String
    public let columns: Int
    public let rows: Int

    /// One band of `ascii_with_csi`'s draw: the half-open percentage range and the string
    /// it emits. `text` is nil for the band that emits a random ASCII run instead.
    public struct CSIChunk: Codable, Equatable, Sendable {
        public let lowerBound: Int
        public let upperBound: Int
        public let text: String?

        public init(lowerBound: Int, upperBound: Int, text: String?) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
            self.text = text
        }
    }
}

/// Generates the four arms. Everything is a pure function of the arm, the repetition
/// count, and the seed, so two runs on any machine produce identical bytes -- the ladder
/// requires both physical arms to receive one immutable stimulus.
public enum KittenFeedGenerator {
    // -- Payload constants, from tools/cmd/benchmark/main.go --

    /// kitten's `ascii_printable`. Note it is an *indexed* string, not a set: space appears
    /// twice, so a uniform index draw makes space twice as likely as any other character.
    public static let asciiPrintable = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ  `~!@#$%^&*()_+-=[]{}\\|;:'\",<.>/?"

    /// kitten's `control_chars`, appended to the alphabet for the `ascii` and `csi` draws.
    public static let controlCharacters = "\n\t"

    /// The 88-entry string `random_string_of_bytes` indexes into. All entries are single
    /// ASCII bytes, so an index draw and a byte draw are the same thing here.
    public static let asciiAlphabet = asciiPrintable + controlCharacters

    public static let chineseLoremIpsum =
        "\n"
        + "旦海司有幼雞讀松鼻種比門真目怪少：扒裝虎怕您跑綠蝶黃，位香法士錯乙音造活羽詞坡村目園尺封鳥朋；法松夕點我冬停雪因科對只貓息加黃住蝶，明鴨乾春呢風乙時昔孝助？小紅女父故去。\n"
        + "飯躲裝個哥害共買去隻把氣年，己你校跟飛百拉！快石牙飽知唱想土人吹象毛吉每浪四又連見、欠耍外豆雞秋鼻。住步帶。\n"
        + "打六申幾麼：或皮又荷隻乙犬孝習秋還何氣；幾裏活打能花是入海乙山節會。種第共後陽沒喜姐三拍弟海肖，行知走亮包，他字幾，的木卜流旦乙左杯根毛。\n"
        + "您皮買身苦八手牛目地止哥彩第合麻讀午。原朋河乾種果「才波久住這香松」兄主衣快他玉坐要羽和亭但小山吉也吃耳怕，也爪斗斥可害朋許波怎祖葉卜。\n"
        + "行花兩耍許車丟學「示想百吃門高事」不耳見室九星枝買裝，枝十新央發旁品丁青給，科房火；事出出孝肉古：北裝愛升幸百東鼻到從會故北「可休笑物勿三游細斗」娘蛋占犬。我羊波雨跳風。\n"
        + "牛大燈兆新七馬，叫這牙後戶耳、荷北吃穿停植身玩間告或西丟再呢，他禾七愛干寺服石安：他次唱息它坐屋父見這衣發現來，苗會開條弓世者吃英定豆哭；跳風掃叫美神。\n"
        + "寸再了耍休壯植己，燈錯和，蝶幾欠雞定和愛，司紅後弓第樹會金拉快喝夕見往，半瓜日邊出讀雞苦歌許開；發火院爸乙；四帶亮錯鳥洋個讀。\n"

    public static let miscUnicode =
        "\n"
        + "‘’“”‹›«»‚„ 😀😛😇😈😉😍😎😮👍👎 —–§¶†‡©®™ →⇒•·°±−×÷¼½½¾\n"
        + "…µ¢£€¿¡¨´¸ˆ˜ ÀÁÂÃÄÅÆÇÈÉÊË ÌÍÎÏÐÑÒÓÔÕÖØ ŒŠÙÚÛÜÝŸÞßàá âãäåæçèéêëìí\n"
        + "îïðñòóôõöøœš ùúûüýÿþªºαΩ∞ ū̀n̂o᷵H̨a̠b̡͓̐c̡͓̐X̡͓̐\n"

    /// `simple_ascii`: `1024*2048 + 13` bytes.
    public static let asciiPayloadSize = 1024 * 2048 + 13
    /// `ascii_with_csi` appends whole chunks until it reaches `1024*1024 + 17` bytes.
    public static let csiPayloadMinimumSize = 1024 * 1024 + 17
    /// `unicode`: the lorem block, the misc block, and the control chars, 1024 times.
    public static let unicodeRepeatCount = 1024
    /// `unique_unicode`: `256*1024` cells, each `a` plus three combining marks.
    public static let uniqueUnicodeCellCount = 256 * 1024
    public static let uniqueUnicodeCombiningCount = 0x70
    public static let uniqueUnicodeMarksPerCell = 3
    /// The longest random ASCII run `ascii_with_csi` emits is `rand.IntN(72) + 1` bytes.
    public static let csiRunLengthBound = 72

    /// The seven bands of `ascii_with_csi`, in the order and with the widths `main.go`
    /// tests them. The first emits a random ASCII run; the rest emit a fixed string.
    public static let csiChunks: [KittenFeedParameters.CSIChunk] = [
        .init(lowerBound: 0, upperBound: 10, text: nil),
        .init(lowerBound: 10, upperBound: 30, text: "\u{1b}[m\u{1b}[?1h\u{1b}[H"),
        .init(lowerBound: 30, upperBound: 40, text: "\u{1b}[1;2;3;4:3;31m"),
        .init(lowerBound: 40, upperBound: 50, text: "\u{1b}[38:5:24;48:2:125:136:147m"),
        .init(lowerBound: 50, upperBound: 60, text: "\u{1b}[58;5;44;2m"),
        .init(lowerBound: 60, upperBound: 80, text: "\u{1b}[m\u{1b}[10A\u{1b}[3E\u{1b}[2K"),
        .init(lowerBound: 80, upperBound: 100, text: "\u{1b}[39m\u{1b}[10`a\u{1b}[100b\u{1b}[?1l"),
    ]

    // -- Wrapper constants --

    /// `main.go`'s `clear_screen`, written before every `Running:` line.
    public static let clearScreen = "\u{1b}[m\u{1b}[H\u{1b}[2J"
    /// `main.go`'s `reset` (OSC terminator then RIS), part of the deferred restore.
    public static let resetSequence = "\u{1b}]\u{1b}\\\u{1b}c"
    /// DSR; kitten writes three and waits for three replies. The replies are the writer's
    /// business, but the requests are bytes the terminal parses, so they stay in the stream.
    public static let deviceStatusReport = "\u{1b}[5n"
    public static let deviceStatusReportCount = 3

    /// `loop.TerminalStateOptions{Alternate_screen: true}.SetStateEscapeCodes()` followed by
    /// `loop.DECTCEM.EscapeCodeToReset()`, with every other option left at its zero value.
    /// Order is `terminal-state.go`'s: save cursor, save private modes, default region
    /// select, the reset modes, the set modes, the alt screen and its clear, the legacy
    /// keyboard flags, then the cursor hide `benchmark_data` adds.
    public static let setupSequence =
        "\u{1b}7"
        + "\u{1b}[?s"
        + "\u{1b}[*x"
        + "\u{1b}[4l\u{1b}[?1l\u{1b}[?5l\u{1b}[?2004l"
        + "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1005l\u{1b}[?1006l"
        + "\u{1b}[?8h\u{1b}[?7h\u{1b}[?25h"
        + "\u{1b}[?1049h\u{1b}[H\u{1b}[2J"
        + "\u{1b}[>u"
        + "\u{1b}[?25l"

    /// `ResetStateEscapeCodes()` then `DECTCEM.EscapeCodeToSet()` then `reset`, which is
    /// what `benchmark_data`'s deferred write sends.
    public static let teardownSequence =
        "\u{1b}[<u"
        + "\u{1b}[?1049l"
        + "\u{1b}[?r"
        + "\u{1b}8"
        + "\u{1b}[?25h"
        + resetSequence

    // -- Fixture parameters --

    /// Repetitions of the payload inside the timed portion. kitten defaults to 100; the
    /// arm needs only enough to put the reset-between-repetitions path inside the measured
    /// stream, because the harness already scales executions to its one-second floor.
    /// It is part of the fixture identity, so changing it invalidates frozen blocks.
    public static let repetitions = 2

    /// The seed both random arms draw from. Fixed so the stimulus is reproducible, and
    /// carried in the fixture identity so a change cannot reuse another stimulus's rule.
    public static let seed: UInt64 = 39

    public static let columns = 179
    public static let rows = 66

    /// The port's own account of what it encodes, for the parity lint to compare against
    /// the pinned kitty sources.
    public static func parameters() -> KittenFeedParameters {
        var descriptions: [String: String] = [:]
        for arm in KittenFeedArm.allCases {
            descriptions[arm.rawValue] = arm.description
        }
        return KittenFeedParameters(
            alphabet: asciiPrintable,
            controlCharacters: controlCharacters,
            chineseLoremIpsum: chineseLoremIpsum,
            miscUnicode: miscUnicode,
            asciiPayloadSize: asciiPayloadSize,
            csiPayloadMinimumSize: csiPayloadMinimumSize,
            csiRunLengthBound: csiRunLengthBound,
            uniqueUnicodeCellCount: uniqueUnicodeCellCount,
            uniqueUnicodeCombiningCount: uniqueUnicodeCombiningCount,
            uniqueUnicodeMarksPerCell: uniqueUnicodeMarksPerCell,
            unicodeRepeatCount: unicodeRepeatCount,
            csiChunks: csiChunks,
            descriptions: descriptions,
            clearScreen: clearScreen,
            resetSequence: resetSequence,
            deviceStatusReport: deviceStatusReport,
            deviceStatusReportCount: deviceStatusReportCount,
            setupSequence: setupSequence,
            teardownSequence: teardownSequence,
            repetitions: repetitions,
            seed: String(seed),
            columns: columns,
            rows: rows
        )
    }

    /// The arm's payload: the bytes kitten writes once per repetition.
    public static func payload(for arm: KittenFeedArm, seed: UInt64 = seed) -> [UInt8] {
        switch arm {
        case .ascii:
            var random = KittenFeedRandom(seed: seed)
            return randomBytes(count: asciiPayloadSize, using: &random)
        case .unicode:
            let unit = Array((chineseLoremIpsum + miscUnicode + controlCharacters).utf8)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(unit.count * unicodeRepeatCount)
            for _ in 0..<unicodeRepeatCount {
                bytes.append(contentsOf: unit)
            }
            return bytes
        case .uniqueUnicode:
            return uniqueUnicodePayload()
        case .csi:
            var random = KittenFeedRandom(seed: seed)
            return csiPayload(using: &random)
        }
    }

    /// The full stream, split at kitten's timer boundaries.
    public static func stream(
        for arm: KittenFeedArm,
        repetitions: Int = repetitions,
        seed: UInt64 = seed
    ) -> KittenFeedStream {
        precondition(repetitions >= 2, "R must include the reset-between-repetitions path")
        let payload = payload(for: arm, seed: seed)
        let endOfLoopReset = Array((clearScreen + "Running: " + arm.description + "\r\n").utf8)
        var timed: [UInt8] = []
        timed.reserveCapacity((payload.count + endOfLoopReset.count) * repetitions + 128)
        for _ in 0..<repetitions {
            timed.append(contentsOf: payload)
            timed.append(contentsOf: endOfLoopReset)
        }
        let finalize =
            clearScreen
            + "Waiting for response indicating parsing finished\r\n"
            + String(repeating: deviceStatusReport, count: deviceStatusReportCount)
        timed.append(contentsOf: Array(finalize.utf8))
        return KittenFeedStream(
            setup: Array(setupSequence.utf8),
            timed: timed,
            teardown: Array(teardownSequence.utf8)
        )
    }

    private static func randomBytes(count: Int, using random: inout KittenFeedRandom) -> [UInt8] {
        let alphabet = Array(asciiAlphabet.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(alphabet[random.index(below: alphabet.count)])
        }
        return bytes
    }

    private static func uniqueUnicodePayload() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(uniqueUnicodeCellCount * 10)
        for cell in 0..<uniqueUnicodeCellCount {
            var remainder = cell
            bytes.append(UInt8(ascii: "a"))
            for _ in 0..<uniqueUnicodeMarksPerCell {
                let scalar = Unicode.Scalar(0x300 + remainder % uniqueUnicodeCombiningCount)!
                bytes.append(contentsOf: Array(String(scalar).utf8))
                remainder /= uniqueUnicodeCombiningCount
            }
        }
        return bytes
    }

    private static func csiPayload(using random: inout KittenFeedRandom) -> [UInt8] {
        let alphabet = Array(asciiAlphabet.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(csiPayloadMinimumSize + 48)
        while bytes.count < csiPayloadMinimumSize {
            let draw = random.index(below: 100)
            guard let band = csiChunks.first(where: { draw >= $0.lowerBound && draw < $0.upperBound })
            else {
                preconditionFailure("csi bands must cover 0..<100")
            }
            if let text = band.text {
                bytes.append(contentsOf: Array(text.utf8))
            } else {
                let runLength = random.index(below: csiRunLengthBound) + 1
                for _ in 0..<runLength {
                    bytes.append(alphabet[random.index(below: alphabet.count)])
                }
            }
        }
        bytes.append(contentsOf: Array("\u{1b}[m".utf8))
        return bytes
    }
}

/// A fixed-seed, platform-independent replacement for kitten's unseeded `math/rand/v2`.
/// SplitMix64 with Lemire's rejection bound, so the draws are uniform over the same ranges
/// `rand.IntN` covers -- the arm is the same stimulus statistically, and reproducible,
/// which an unseeded generator can never be.
public struct KittenFeedRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// SplitMix64's next output. Spelled out rather than taken from a library so the byte
    /// stream cannot change under a dependency bump.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform draw over `0..<bound`, rejecting the biased tail the way `rand.IntN` does.
    public mutating func index(below bound: Int) -> Int {
        precondition(bound > 0)
        let range = UInt64(bound)
        var product = next().multipliedFullWidth(by: range)
        if product.low < range {
            let threshold = (0 &- range) % range
            while product.low < threshold {
                product = next().multipliedFullWidth(by: range)
            }
        }
        return Int(product.high)
    }
}
