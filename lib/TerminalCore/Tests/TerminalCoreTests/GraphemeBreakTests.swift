// Pins TerminalCore's streaming grapheme segmenter to the Unicode 17.0.0 corpus.
import Testing

@testable import TerminalCore

/// Verifies both generated grapheme properties and the stateful pairwise break contract.
@Suite struct GraphemeBreakTests {
    @Test("generated grapheme properties match every Unicode 17.0 scalar")
    func generatedPropertiesMatchPinnedReference() {
        // Intent: compare the production folded grapheme class and emoji-VS-base
        //   lookup with an independently generated reference for every scalar.
        // Why it exists: segmentation and variation-selector width must not depend
        //   on stale, partial, or toolchain-provided Unicode properties.
        // Scenario: regenerating Unicode 17.0 data preserves both properties over
        //   the complete scalar range before terminal assembly consumes them.
        var classifiedScalarCount = 0
        var mismatchedScalarCount = 0
        var firstMismatch: String?
        for range in unicodeGraphemeReferenceRanges {
            for value in range.lowerBound...range.upperBound {
                guard let scalar = Unicode.Scalar(value) else { continue }
                classifiedScalarCount += 1
                let classification = terminalUnicodeClassification(for: scalar)
                guard classification.graphemeBreakClass.rawValue == range.breakClass,
                      classification.properties.isEmojiVariationBase == range.isEmojiVariationBase
                else {
                    mismatchedScalarCount += 1
                    if firstMismatch == nil {
                        firstMismatch =
                            "U+\(String(value, radix: 16, uppercase: true)) "
                            + "expected breakClass=\(range.breakClass), "
                            + "emojiVariationBase=\(range.isEmojiVariationBase); "
                            + "got breakClass=\(classification.graphemeBreakClass.rawValue), "
                            + "emojiVariationBase=\(classification.properties.isEmojiVariationBase)"
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

    @Test("pairwise segmenter matches every Unicode 17.0 grapheme boundary")
    func officialCorpusMatches() throws {
        // Intent: drive the streaming pairwise segmenter through every boundary in
        //   the official Unicode 17.0.0 GraphemeBreakTest corpus without filtering.
        // Why it exists: representative emoji and combining fixtures cannot prove
        //   the full UAX #29 state machine, especially RI parity and GB9c conjuncts.
        // Scenario: each official line begins a fresh stream, then carries state
        //   across adjacent scalar pairs exactly as Terminal will during printing.
        for fixture in graphemeBreakCorpus {
            #expect(fixture.boundaries.count == fixture.scalars.count + 1)
            #expect(fixture.boundaries.first == true)
            #expect(fixture.boundaries.last == true)

            var state = GraphemeBreakState()
            guard fixture.scalars.count > 1 else { continue }
            for index in 1..<fixture.scalars.count {
                let previous = try #require(Unicode.Scalar(fixture.scalars[index - 1]))
                let current = try #require(Unicode.Scalar(fixture.scalars[index]))
                #expect(
                    graphemeBreak(between: previous, and: current, state: &state)
                        == fixture.boundaries[index],
                    "corpus line \(fixture.line), boundary \(index)"
                )
            }
        }
    }
}
