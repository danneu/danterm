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

    @Test("re-hovering a different target over the same range still damages the run")
    func hoverTargetChangeAtIdenticalRangeDamages() throws {
        // Intent: replacing the hovered link's target damages the run even when the
        //   new link occupies the exact same range as the old one, so a renderer
        //   that draws the target (or its underline styling) repaints.
        // Why it exists: the hover comparison inside `recordDamage(from:to:)` is the
        //   only thing that notices this change, and the cheapest ways to make the
        //   damage snapshot trivially copyable all replace the compared link with a
        //   token -- `activationIdentity`, a range, or both. None of those is a
        //   function of the URI: `activationIdentity` is `max(contentIdentity)` over
        //   the range's cells, and the public `TerminalResolvedLink` initializer
        //   assigns 0. This pins the behavior any such substitution would silently
        //   drop.
        // Scenario: two links share one run of text and differ only in target -- the
        //   OSC 8 shape, where the URI is metadata rather than visible text. The
        //   pointer stays still while the target under it is replaced.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("https://a.co".utf8))
        let range = TerminalTextRange(
            start: .init(row: 0, column: 0),
            end: .init(row: 0, column: 12)
        )

        let admittedFirst = terminal.setHoveredLink(
            TerminalResolvedLink(hyperlink: .init(uri: "https://a.co"), range: range)
        )
        #expect(admittedFirst)
        _ = terminal.drainDamage()

        let admittedSecond = terminal.setHoveredLink(
            TerminalResolvedLink(hyperlink: .init(uri: "https://b.co"), range: range)
        )
        #expect(admittedSecond)
        #expect(terminal.hoveredLink?.hyperlink.uri == "https://b.co")
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

    @Test("an armed link alone is invalidated when its text is overwritten")
    func armedLinkInvalidatesWithoutOtherInspectionState() throws {
        // Intent: an armed click reservation, with no selection, search, or hover alongside
        //   it, is dropped when output overwrites the run it reserved.
        // Why it exists: `invalidateInspection` short-circuits on one cached
        //   `hasInteractionState` bit rather than re-reading its four inspection optionals,
        //   so a bit that fails to account for `armedLinkState` strands an arm over text that
        //   no longer exists. `armedLinkState` was the one field of the four with no
        //   arm-only invalidation coverage: `linkArmTracksRunIdentity` exercises an arm over
        //   an overwrite, but release there is refused by the run-identity check, so it
        //   passes whether or not the arm itself was ever invalidated.
        // Scenario: the user holds Cmd and presses on a URL, and the running program repaints
        //   that line before they release.
        var terminal = try #require(Terminal(columns: 14, rows: 3))
        terminal.feed(Array("https://a.co".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 3)))

        let armed = terminal.setArmedLink(link)
        #expect(armed)
        #expect(terminal.armedLink != nil)
        #expect(terminal.hoveredLink == nil)

        terminal.feed(Array("\u{1B}[1;4HX".utf8))
        #expect(terminal.armedLink == nil)
    }

    @Test("overwrite preserves selection while dropping every content-derived inspection channel")
    func overwriteSeparatesSelectionFromContentDerivedInspection() throws {
        var terminal = try #require(Terminal(columns: 14, rows: 2))
        terminal.feed(Array("https://a.co".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 3)))
        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 11)
        )
        let found = terminal.beginSearch("https://a.co")
        #expect(found)
        let hovered = terminal.setHoveredLink(link)
        #expect(hovered)
        let armed = terminal.setArmedLink(link)
        #expect(armed)

        terminal.feed(Array("\u{1B}[1;4HX".utf8))

        #expect(terminal.selectionRange != nil)
        #expect(terminal.activeSearchMatchRange == nil)
        #expect(terminal.hoveredLink == nil)
        #expect(terminal.armedLink == nil)
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
        for index in 0..<4 {
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
        let detected = try #require(terminal.activatableLink(at: .init(row: 0, column: 10)))

        let refused = terminal.setHoveredLink(detected)
        #expect(refused == false)
        #expect(terminal.hoveredLink == nil)
        #expect(terminal.retainedHyperlinkMetadataBytes == 4 * retainedLength)

        terminal.feed(Array("\u{1B}[1;1Hyz".utf8))
        let admitted = terminal.setHoveredLink(detected)
        #expect(admitted)
        let armed = terminal.setArmedLink(detected)
        #expect(armed)
        #expect(terminal.retainedHyperlinkMetadataBytes <= 256 * 1_024)
        #expect(terminal.armedLink == detected)
    }

    @Test("scrollback eviction drops a hover rather than attaching it to unrelated text")
    func evictionClearsHover() throws {
        var terminal = try #require(Terminal(
            columns: 16,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lineCells: [12])
        ))
        terminal.feed(Array("https://a.co\r\nnext".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 2)))
        let admitted = terminal.setHoveredLink(link)
        #expect(admitted)

        terminal.feed(Array("\r\nthird\r\nfourth".utf8))

        #expect(terminal.hoveredLink == nil)
    }
}
