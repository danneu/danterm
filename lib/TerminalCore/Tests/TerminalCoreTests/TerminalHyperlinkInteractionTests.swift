// Hover-state proofs for damage, reflow attachment, invalidation, and reset semantics.

import Testing
@testable import TerminalCore

/// Pins ephemeral hyperlink presentation to live terminal text without granting activation effects.
struct TerminalHyperlinkInteractionTests {
    @Test("hover set and clear retain the resolved run and damage only its rows")
    func hoverDamage() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("https://a.co".utf8))
        _ = terminal.drainDamage()
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 3)))

        let admitted = terminal.setHoveredLink(link)
        #expect(admitted)
        #expect(terminal.hoveredLink == link)
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0]))

        terminal.clearHoveredLink()
        #expect(terminal.hoveredLink == nil)
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0]))
    }

    @Test("hover anchors follow width reflow and clear when their text is overwritten")
    func hoverReflowAndOverwrite() throws {
        var terminal = try #require(Terminal(columns: 14, rows: 3))
        terminal.feed(Array("go https://a.co".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 6)))
        let admitted = terminal.setHoveredLink(link)
        #expect(admitted)

        terminal.resize(columns: 7, rows: 3)
        let reflowed = try #require(terminal.hoveredLink)
        #expect(reflowed.hyperlink.uri == "https://a.co")
        #expect(reflowed.range.start == .init(row: 0, column: 3))
        #expect(reflowed.range.end == .init(row: 2, column: 1))

        terminal.feed(Array("\u{1B}[1;4HX".utf8))
        #expect(terminal.hoveredLink == nil)
    }

    @Test("soft and hard reset clear hovered presentation")
    func resetClearsHover() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("https://a.co".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 2)))
        let admitted = terminal.setHoveredLink(link)
        #expect(admitted)

        terminal.feed(Array("\u{1B}[!p".utf8))
        #expect(terminal.hoveredLink == nil)

        let readmitted = terminal.setHoveredLink(link)
        #expect(readmitted)
        terminal.feed(Array("\u{1B}c".utf8))
        #expect(terminal.hoveredLink == nil)
    }

    @Test("hover admission shares the aggregate cap and sweeps dead table entries atomically")
    func hoverSharesMetadataBudget() throws {
        // Intent: count a retained hover against the same hard cap as OSC 8 targets.
        // Why it exists: interaction copies must not bypass the pane-wide metadata envelope.
        // Scenario: a nearly full table refuses hover, then two overwritten links make room.
        var terminal = try #require(Terminal(columns: 70_000, rows: 1))
        let retainedLength = 61_500
        for index in 0..<16 {
            let prefix = "https://\(index).test/"
            let uri = prefix + String(
                repeating: "a",
                count: retainedLength - prefix.utf8.count
            )
            terminal.feed(Array("\u{1B}]8;;\(uri)\u{7}x".utf8))
        }
        terminal.feed(Array("\u{1B}]8;;\u{7}".utf8))
        let detectedURI = "https://detected.test/"
            + String(repeating: "b", count: 65_536 - "https://detected.test/".utf8.count)
        terminal.feed(Array((" " + detectedURI).utf8))
        let detected = try #require(terminal.activatableLink(at: .init(row: 0, column: 100)))

        let refused = terminal.setHoveredLink(detected)
        #expect(refused == false)
        #expect(terminal.hoveredLink == nil)
        #expect(terminal.retainedHyperlinkMetadataBytes == 16 * retainedLength)

        terminal.feed(Array("\u{1B}[1;1Hyz".utf8))
        let admitted = terminal.setHoveredLink(detected)
        #expect(admitted)
        let armed = terminal.setArmedLink(detected)
        #expect(armed)
        #expect(terminal.retainedHyperlinkMetadataBytes <= 1_048_576)
        #expect(terminal.armedLink == detected)
    }

    @Test("scrollback eviction drops a hover rather than attaching it to unrelated text")
    func evictionClearsHover() throws {
        var terminal = try #require(Terminal(columns: 16, rows: 2, scrollbackBudgetBytes: 200))
        terminal.feed(Array("https://a.co\r\nnext".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 2)))
        let admitted = terminal.setHoveredLink(link)
        #expect(admitted)

        terminal.feed(Array("\r\nthird\r\nfourth".utf8))

        #expect(terminal.hoveredLink == nil)
    }
}
