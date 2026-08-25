// Pins TerminalCore's generated Unicode width and emoji properties to the selected standard.
import Testing

@testable import TerminalCore

/// Exercises the externally meaningful width policy separately from later grid mutation tests.
@Suite struct UnicodeWidthTests {
    @Test("Unicode tables are pinned to version 17.0.0")
    func unicodeVersionIsPinned() {
        #expect(terminalUnicodeVersion == "17.0.0")
    }

    @Test("width policy handles narrow, wide, zero-width, and property overlaps")
    func representativeWidthPolicy() {
        #expect(terminalUnicodeProperties(for: "A").cellWidth == .narrow)
        #expect(terminalUnicodeProperties(for: "\u{754C}").cellWidth == .wide)
        #expect(terminalUnicodeProperties(for: "\u{1F618}").cellWidth == .wide)
        #expect(terminalUnicodeProperties(for: "\u{0301}").cellWidth == .zero)
        #expect(terminalUnicodeProperties(for: "\u{200D}").cellWidth == .zero)
        #expect(terminalUnicodeProperties(for: "\u{3099}").cellWidth == .zero)
        #expect(terminalUnicodeProperties(for: "\u{00A1}").cellWidth == .narrow)
        #expect(terminalUnicodeProperties(for: "\u{1F1E6}").cellWidth == .wide)
        #expect(terminalUnicodeProperties(for: "\u{1F3FD}").isEmojiModifier)
    }

    @Test("Emoji_Presentation separates the two kinds of variation base")
    func emojiPresentationProperty() {
        // Intent: the generated bit reports Unicode's default presentation, which
        //   splits emoji variation bases into the ones a bare scalar shows as emoji
        //   and the ones it shows as text.
        // Why it exists: `isEmojiVariationBase` says only that both forms exist, so a
        //   caller that wants "would a bare scalar draw as text?" has no other source
        //   for the answer. An all-false bit would satisfy the exhaustive width
        //   implication below without carrying any data.
        #expect(terminalUnicodeProperties(for: "\u{23FA}").isEmojiVariationBase)
        #expect(!terminalUnicodeProperties(for: "\u{23FA}").hasEmojiPresentation)
        #expect(terminalUnicodeProperties(for: "\u{2764}").isEmojiVariationBase)
        #expect(!terminalUnicodeProperties(for: "\u{2764}").hasEmojiPresentation)
        #expect(terminalUnicodeProperties(for: "\u{231A}").isEmojiVariationBase)
        #expect(terminalUnicodeProperties(for: "\u{231A}").hasEmojiPresentation)
        #expect(terminalUnicodeProperties(for: "\u{1F618}").hasEmojiPresentation)
        #expect(!terminalUnicodeProperties(for: "A").hasEmojiPresentation)
    }

    @Test("Every default-emoji scalar was given a wide cell")
    func emojiPresentationImpliesWideCell() {
        // Intent: across the whole codespace, `Emoji_Presentation=Yes` implies a wide
        //   cell. Stated one way only -- a default-text scalar may be either width.
        // Why it exists: width and presentation come from independent Unicode
        //   properties, and a rule that leaves default-emoji scalars alone relies on
        //   the wide cells allocated on emoji grounds belonging exactly to them. A
        //   future Unicode pin that breaks the agreement must fail here rather than
        //   quietly put a color glyph in a narrow cell.
        var narrowDefaultEmojiCount = 0
        var firstNarrow: String?
        for value in 0...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let properties = terminalUnicodeProperties(for: scalar)
            guard properties.hasEmojiPresentation, properties.cellWidth != .wide else {
                continue
            }
            narrowDefaultEmojiCount += 1
            if firstNarrow == nil {
                firstNarrow = "U+\(String(value, radix: 16, uppercase: true))"
                    + " width=\(properties.cellWidth)"
            }
        }
        let detail = firstNarrow ?? "none"
        #expect(
            narrowDefaultEmojiCount == 0,
            "\(narrowDefaultEmojiCount) default-emoji scalars are not wide; first: \(detail)"
        )
    }

    @Test("Extended_Pictographic is independent from scalar width")
    func extendedPictographicProperty() {
        #expect(terminalUnicodeProperties(for: "\u{1F618}").isExtendedPictographic)
        #expect(!terminalUnicodeProperties(for: "A").isExtendedPictographic)
    }

    @Test("generated policy matches every Unicode 17.0 scalar")
    func generatedPolicyMatchesPinnedReference() {
        // Intent: compare the checked-in production table with the independently
        //   combined reference properties for every valid Unicode scalar.
        // Why it exists: pins the complete generated-data contract so a stale or
        //   partial table cannot pass through representative fixtures alone.
        // Scenario: spec-first regeneration of Unicode 17.0 data must preserve
        //   terminal width and Extended_Pictographic classification everywhere.
        var classifiedScalarCount = 0
        var mismatchedScalarCount = 0
        var firstMismatch: String?
        for range in unicodeReferenceRanges {
            for value in range.lowerBound...range.upperBound {
                guard let scalar = Unicode.Scalar(value) else { continue }
                classifiedScalarCount += 1
                let properties = terminalUnicodeClassification(for: scalar).properties
                guard properties.cellWidth.rawValue == range.cellWidth,
                      properties.isExtendedPictographic == range.isExtendedPictographic,
                      properties.isEmojiModifier == range.isEmojiModifier
                else {
                    mismatchedScalarCount += 1
                    if firstMismatch == nil {
                        firstMismatch =
                            "U+\(String(value, radix: 16, uppercase: true)) "
                            + "expected width=\(range.cellWidth), "
                            + "extendedPictographic=\(range.isExtendedPictographic), "
                            + "emojiModifier=\(range.isEmojiModifier); "
                            + "got width=\(properties.cellWidth.rawValue), "
                            + "extendedPictographic=\(properties.isExtendedPictographic), "
                            + "emojiModifier=\(properties.isEmojiModifier)"
                    }
                    continue
                }
            }
        }
        #expect(classifiedScalarCount == 1_112_064)
        #expect(
            mismatchedScalarCount == 0,
            "\(mismatchedScalarCount) mismatched scalars; first: \(firstMismatch ?? "none")"
        )
    }
}
