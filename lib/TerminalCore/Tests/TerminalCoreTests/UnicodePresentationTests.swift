// Pins the presentation gate the render fallback reads: which cells get an explicit
// text presentation selector, and which are handed on exactly as the stream wrote them.
import Testing

@testable import TerminalCore

/// Keeps the presentation decision provable on macOS, separate from any draw path.
@Suite struct UnicodePresentationTests {
    @Test("Default presentation comes from the table, not from the cell's width")
    func defaultPresentationReadsTheTable() {
        // Intent: the classifier reports Unicode's default presentation for a scalar
        //   that has both forms, and declines a scalar that has only one.
        // Why it exists: a default-text base may be wide (U+3030 is), so a rule that
        //   read width instead of presentation would refuse to fix it. Pinning the
        //   wide-and-text case here keeps that proxy from creeping back in.
        #expect(terminalDefaultPresentation(for: "\u{23FA}") == .text)
        #expect(terminalDefaultPresentation(for: "\u{3030}") == .text)
        #expect(terminalUnicodeProperties(for: "\u{3030}").cellWidth == .wide)
        #expect(terminalDefaultPresentation(for: "\u{231A}") == .emoji)
        #expect(terminalDefaultPresentation(for: "A") == nil)
    }

    @Test("A bare default-text base is the one cell that states its presentation")
    func gateAppendsTextSelectorToBareDefaultTextBase() {
        let textSelector = Unicode.Scalar(0xFE0E)
        #expect(terminalPresentationSelectorToAppend(for: ["\u{23FA}"]) == textSelector)
        #expect(terminalPresentationSelectorToAppend(for: ["\u{3030}"]) == textSelector)
    }

    @Test("The gate declines every shape the rule excludes")
    func gateDeclinesExcludedCells() {
        // Intent: only a single bare default-text variation base is transformed.
        // Why it exists: each excluded shape fails for its own reason -- a cluster the
        //   terminal already assembled, a presentation the stream stated itself, a
        //   scalar with no second form, and a scalar Unicode presents as emoji. A
        //   blanket rule would pass the included case above and quietly break these.
        #expect(terminalPresentationSelectorToAppend(for: ["\u{23FA}", "\u{FE0F}"]) == nil)
        #expect(terminalPresentationSelectorToAppend(for: ["\u{23FA}", "\u{FE0E}"]) == nil)
        #expect(
            terminalPresentationSelectorToAppend(
                for: ["\u{1F468}", "\u{200D}", "\u{1F4BB}"]
            ) == nil
        )
        #expect(terminalPresentationSelectorToAppend(for: ["A"]) == nil)
        #expect(terminalPresentationSelectorToAppend(for: ["\u{231A}"]) == nil)
        #expect(terminalPresentationSelectorToAppend(for: []) == nil)
    }
}
