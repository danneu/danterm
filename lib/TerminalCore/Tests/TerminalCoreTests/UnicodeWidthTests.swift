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
