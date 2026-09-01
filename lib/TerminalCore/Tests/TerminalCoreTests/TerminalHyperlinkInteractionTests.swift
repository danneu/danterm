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

    @Test("arming and disarming a link records no damage")
    func armRecordsNoDamage() throws {
        // Intent: reserving and releasing a click target never schedules presentation work.
        // Why it exists: hover and arm share link storage policy but only hover is visible, so a
        //   shared writer must not accidentally give arm mutations hover's damage behavior.
        // Scenario: the user presses and releases Cmd over a URL without changing its hover.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("https://a.co".utf8))
        _ = terminal.drainDamage()
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 3)))

        let admitted = terminal.setArmedLink(link)
        #expect(admitted)
        #expect(terminal.armedLink == link)
        #expect(terminal.drainDamage() == .none)

        terminal.clearArmedLink()
        #expect(terminal.armedLink == nil)
        #expect(terminal.drainDamage() == .none)
    }

    @Test("re-hovering the identical link still damages its rows")
    func identicalRehoverDamages() throws {
        // Intent: every accepted hover write schedules repaint, even when the value is unchanged.
        // Why it exists: the damage snapshot deliberately detects writes rather than inequality;
        //   an equality early-out in shared slot machinery would weaken that contract.
        // Scenario: pointer motion resolves the same URL run twice without an intervening clear.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("https://a.co".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 3)))
        let admitted = terminal.setHoveredLink(link)
        #expect(admitted)
        _ = terminal.drainDamage()

        let readmitted = terminal.setHoveredLink(link)
        #expect(readmitted)
        #expect(terminal.hoveredLink == link)
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

    @Test("an armed link's range and activation identity survive a width reflow")
    func armedLinkReflowsWithItsRange() throws {
        // Intent: a width change restates the armed run's two endpoints like every other held
        //   range, and the restated arm still activates the link it reserved.
        // Why it exists: the refold restates nine anchor slots, and the arm pair was the only
        //   one no test carried through a width resize, so a refold that dropped or misplaced
        //   those two would have gone unnoticed.
        // Scenario: the user holds Cmd on a URL and the window is narrowed before they release.
        var terminal = try #require(Terminal(columns: 14, rows: 3))
        terminal.feed(Array("go https://a.co".utf8))
        var state = TerminalInteractionState()
        let down = decideTerminalPointer(
            .down(.left, cell: .init(column: 6, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        applyTerminalPointerDecision(down, to: &terminal)
        #expect(terminal.armedLink != nil)

        terminal.resize(columns: 7, rows: 3)

        let reflowed = try #require(terminal.armedLink)
        #expect(reflowed.hyperlink.uri == "https://a.co")
        #expect(reflowed.range.start == .init(row: 0, column: 3))
        #expect(reflowed.range.end == .init(row: 2, column: 1))

        let release = decideTerminalPointer(
            .up(.left, cell: .init(column: 4, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(release.openLink?.uri == "https://a.co")
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
        #expect(terminal.searchReadout?.activeMatch == nil)
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

    @Test("scrollback eviction drops an armed link rather than attaching it to unrelated text")
    func evictionClearsArm() throws {
        // Intent: eviction retires an arm whose range begins before the first retained row.
        // Why it exists: hover and arm must share the eviction predicate; omitting arm leaves a
        //   stale click reservation attached to the row that inherits its old coordinate.
        // Scenario: output fills a tiny history budget while the user holds Cmd over an old URL.
        var terminal = try #require(Terminal(
            columns: 16,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lineCells: [12])
        ))
        terminal.feed(Array("https://a.co\r\nnext\r\nthird".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 2)))
        let admitted = terminal.setArmedLink(link)
        #expect(admitted)

        terminal.feed(Array("\r\nfourth".utf8))

        #expect(terminal.armedLink == nil)
        #expect(terminal.retainedHyperlinkMetadataBytes == 0)
    }

    @Test("content-identity wrap drops arm while preserving live hover")
    func contentIdentityWrapSeparatesArmFromHover() throws {
        // Intent: identity reuse cancels click validation without clearing visible hover state.
        // Why it exists: the wrap rule is intentionally arm-only; iterating every interaction
        //   slot at that site would silently discard a hover whose text remains live.
        // Scenario: the identity counter wraps on another row while one URL is hovered and armed.
        var terminal = try #require(Terminal(columns: 16, rows: 2))
        terminal.feed(Array("https://a.co".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 3)))
        let hovered = terminal.setHoveredLink(link)
        let armed = terminal.setArmedLink(link)
        #expect(hovered)
        #expect(armed)

        terminal.moveCursor(row: 1, column: 0)
        terminal.primeContentIdentityWrapForTesting()
        terminal.feed(Array("x".utf8))

        #expect(terminal.armedLink == nil)
        #expect(terminal.hoveredLink == link)
    }
}
