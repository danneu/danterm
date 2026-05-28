// Swift Testing migration of the legacy `tests/TodoShortcutCatalogTests.swift`
// harness suite. Pins the pure todo shortcut help catalog: per-scope (pane vs
// tab) inclusion of the list / compose / edit shortcuts, exclusion of
// tab-only movement in the pane scope, and the menu-key glyph rendering
// rules. The `shortcutSection` helper's `throw TestFailure` on missing
// section converts to `try #require(...)` -- it's a single-value optional
// unwrap, so #require expresses it exactly.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct TodoShortcutCatalogTests {
    @Test("pane shortcut catalog includes pane list compose and edit shortcuts")
    func paneShortcutCatalogIncludesListComposeAndEdit() throws {
        // Intent: in the pane scope, the catalog has List/Compose/Edit
        //   sections with the expected key glyphs.
        // Why it exists: pins the pane-scope catalog contents.
        // Scenario: spec-first pane catalog.
        let sections = todoShortcutSections(scope: .pane)
        let list = try shortcutSection("List", in: sections)
        let compose = try shortcutSection("Compose", in: sections)
        let edit = try shortcutSection("Edit", in: sections)

        #expect(shortcutKeys(in: list).contains("⌘N"), "list should include Cmd+N")
        #expect(shortcutKeys(in: list).contains("⌘⌫"), "list should include Cmd+Delete")
        #expect(shortcutKeys(in: list).contains("⇧J / ⇧K"), "list should include Shift+J/K")
        #expect(shortcutKeys(in: compose).contains("⇧⏎"), "compose should include Shift+Return")
        #expect(shortcutKeys(in: edit).contains("⇧⏎"), "edit should include Shift+Return")
        #expect(shortcutKeys(in: edit).contains("⌘N"), "edit should include Cmd+N")
    }

    @Test("pane shortcut catalog omits tab bucket movement")
    func paneShortcutCatalogOmitsTabBucketMovement() {
        // Intent: the pane scope omits Shift+H / Shift+L (tab-only
        //   bucket movement).
        // Why it exists: pins the per-scope subtraction.
        // Scenario: spec-first pane catalog omissions.
        let allKeys = shortcutKeys(in: todoShortcutSections(scope: .pane)).joined(separator: " ")
        #expect(!allKeys.contains("⇧H"), "pane help should not include Shift+H")
        #expect(!allKeys.contains("⇧L"), "pane help should not include Shift+L")
    }

    @Test("tab shortcut catalog includes tab-only bucket movement")
    func tabShortcutCatalogIncludesTabBucketMovement() throws {
        // Intent: in the tab scope, the catalog has List/Compose/Edit
        //   sections including Shift+H/L bucket movement.
        // Why it exists: pins the tab-scope catalog contents.
        // Scenario: spec-first tab catalog.
        let sections = todoShortcutSections(scope: .tab)
        let list = try shortcutSection("List", in: sections)
        let compose = try shortcutSection("Compose", in: sections)
        let edit = try shortcutSection("Edit", in: sections)

        #expect(shortcutKeys(in: list).contains("⌘N"), "list should include Cmd+N")
        #expect(shortcutKeys(in: list).contains("⌘⌫"), "list should include Cmd+Delete")
        #expect(shortcutKeys(in: list).contains("⇧J / ⇧K"), "list should include Shift+J/K")
        #expect(shortcutKeys(in: list).contains("⇧H / ⇧L"), "list should include Shift+H/L")
        #expect(shortcutKeys(in: compose).contains("⇧⏎"), "compose should include Shift+Return")
        #expect(shortcutKeys(in: edit).contains("⇧⏎"), "edit should include Shift+Return")
        #expect(shortcutKeys(in: edit).contains("⌘N"), "edit should include Cmd+N")
    }

    @Test("shortcut catalog uses menu key glyphs")
    func shortcutCatalogUsesMenuKeyGlyphs() {
        // Intent: shortcut keys render as menu glyphs (no `Cmd+` /
        //   `Shift+Return` aliases).
        // Why it exists: pins the glyph rendering contract.
        // Scenario: spec-first glyphs only.
        let allKeys = shortcutKeys(in: todoShortcutSections(scope: .tab)).joined(separator: " ")
        #expect(allKeys.contains("⌘"), "catalog should use command glyph")
        #expect(allKeys.contains("⇧"), "catalog should use shift glyph")
        #expect(allKeys.contains("⏎"), "catalog should use return glyph")
        #expect(allKeys.contains("⌫"), "catalog should use delete glyph")
        #expect(!allKeys.contains("Cmd+"), "catalog should not render Cmd+ aliases")
        #expect(!allKeys.contains("Shift+Return"), "catalog should render Shift+Return as a glyph pair")
    }
}

private func shortcutSection(_ title: String, in sections: [TodoShortcutSection]) throws -> TodoShortcutSection {
    try #require(sections.first(where: { $0.title == title }), "missing \(title) shortcut section")
}

private func shortcutKeys(in section: TodoShortcutSection) -> [String] {
    section.items.map(\.keys)
}

private func shortcutKeys(in sections: [TodoShortcutSection]) -> [String] {
    sections.flatMap { shortcutKeys(in: $0) }
}
