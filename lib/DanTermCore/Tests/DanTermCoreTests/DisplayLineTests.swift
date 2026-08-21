// The normalization contract of `DisplayLine`, asserted on the type itself.
// This is the one suite allowed to read `.text` directly: everywhere else the
// invariant is asserted through projection output.
import Foundation
import Testing

@testable import DanTermCore

struct DisplayLineTests {
    @Test(
        "normalization preserves the exact UTF-8 bytes of already-normal text",
        arguments: ["plain", "two words", "e\u{301}"]
    )
    func alreadyNormalTextPreservesBytes(raw: String) {
        #expect(Array(DisplayLine(raw).text.utf8) == Array(raw.utf8))
    }

    @Test(
        "non-normal spacing is rewritten to the expected UTF-8 bytes",
        arguments: [
            (" leading", "leading"),
            ("trailing ", "trailing"),
            ("two  spaces", "two spaces"),
        ]
    )
    func nonNormalSpacingIsRewritten(raw: String, expected: String) {
        #expect(Array(DisplayLine(raw).text.utf8) == Array(expected.utf8))
    }

    @Test(
        "each run of whitespace collapses to a single space",
        arguments: [
            "a\nb",
            "a\r\nb",
            "a\tb",
            "a\u{000B}b",
            "a\u{000C}b",
            "a   b",
            "a \t\n b",
            "a\u{00A0}b",
            "a\u{2028}b",
            "a\u{0085}b",
        ]
    )
    func whitespaceRunsCollapse(raw: String) {
        #expect(DisplayLine(raw).text == "a b")
    }

    // A newline is both whitespace and a C0 control. If control stripping ran
    // first there would be nothing left to split on and the words would glue
    // into "ab", which is the failure this pins down.
    @Test("a line break separates words instead of gluing them")
    func lineBreakDoesNotGlueWords() {
        #expect(DisplayLine("first\nsecond").text == "first second")
    }

    @Test(
        "C0 and C1 controls are stripped",
        arguments: ["\u{0007}", "\u{001B}", "\u{0000}", "\u{001F}", "\u{007F}", "\u{0080}", "\u{009F}"]
    )
    func controlsAreStripped(control: String) {
        #expect(DisplayLine("a\(control)b").text == "ab")
    }

    @Test(
        "bidi overrides and isolates are stripped",
        arguments: ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
    )
    func bidiControlsAreStripped(bidi: String) {
        #expect(DisplayLine("a\(bidi)b").text == "ab")
    }

    @Test("leading and trailing whitespace is dropped")
    func edgeWhitespaceIsDropped() {
        #expect(DisplayLine("  \n hello world \t ").text == "hello world")
    }

    // Stripping a control can expose whitespace that was not adjacent before,
    // so the trim has to survive the strip rather than precede it.
    @Test("whitespace exposed by stripping a control is still trimmed")
    func whitespaceExposedByStrippingIsTrimmed() {
        #expect(DisplayLine("\u{0007} hello \u{001B}").text == "hello")
    }

    @Test("spaces exposed by stripping a control collapse again")
    func spacesExposedByStrippingCollapse() {
        #expect(DisplayLine("a \u{0007} b").text == "a b")
    }

    // Intent: Pin every BMP scalar to the composed normalization rules.
    // Why it exists: The production range test replaces a Unicode property lookup.
    // Scenario: Put each scalar between two letters and compare public output to a property-driven oracle.
    @Test("every BMP scalar follows the composed whitespace and removal rules")
    func everyBMPScalarFollowsComposedRules() {
        for value in UInt32(0)...0xFFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let scalarText = String(scalar)
            let raw = "a\(scalarText)b"
            let expected: String

            if Character(scalarText).isWhitespace {
                expected = "a b"
            } else if scalar.properties.generalCategory == .control
                || (0x202A...0x202E).contains(value)
                || (0x2066...0x2069).contains(value)
            {
                expected = "ab"
            } else {
                expected = raw
            }

            #expect(DisplayLine(raw).text == expected, "Unexpected normalization for U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    @Test("an input with nothing to show normalizes to the empty line", arguments: ["", "   ", "\n\t\r\n", "\u{0007}\u{001B}"])
    func emptyishInputNormalizesToEmpty(raw: String) {
        #expect(DisplayLine(raw).text.isEmpty)
    }

    @Test(
        "normalization is idempotent",
        arguments: ["a\nb", "  spaced  out  ", "\u{0007}bell", "plain", "", "a\u{202E}b\nc"]
    )
    func normalizationIsIdempotent(raw: String) {
        let once = DisplayLine(raw)
        #expect(DisplayLine(once.text) == once)
    }

    @Test("ordinary text passes through unchanged", arguments: ["vim", "~/Code/danterm", "make -j8", "café"])
    func ordinaryTextSurvives(raw: String) {
        #expect(DisplayLine(raw).text == raw)
    }

    @Test("CJK text passes through unchanged")
    func cjkSurvives() {
        #expect(DisplayLine("端末エミュレータ").text == "端末エミュレータ")
    }

    // ZWJ is general category Format, not Control. Stripping Format wholesale
    // would break the sequence into its component emoji.
    @Test("a ZWJ emoji sequence stays one glyph")
    func zwjEmojiSurvives() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(DisplayLine(family).text == family)
        #expect(DisplayLine(family).text.count == 1)
    }

    @Test("a string literal is normalized the same way as an initialized value")
    func literalInitializationNormalizes() {
        let literal: DisplayLine = "a\nb"
        #expect(literal == DisplayLine("a\nb"))
        #expect(literal.text == "a b")
    }

    @Test("description reads out the normalized text")
    func descriptionIsTheText() {
        #expect(String(describing: DisplayLine("a\nb")) == "a b")
    }
}
