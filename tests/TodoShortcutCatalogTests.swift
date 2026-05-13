// Tests for the pure todo shortcut help catalog.

func todoShortcutCatalogTests() {
    print("TodoShortcutCatalog tests:")

    test("pane shortcut catalog includes pane list compose and edit shortcuts") {
        let sections = todoShortcutSections(scope: .pane)
        let list = try shortcutSection("List", in: sections)
        let compose = try shortcutSection("Compose", in: sections)
        let edit = try shortcutSection("Edit", in: sections)

        try expect(shortcutKeys(in: list).contains("⌘N"), "list should include Cmd+N")
        try expect(shortcutKeys(in: list).contains("⌘⌫"), "list should include Cmd+Delete")
        try expect(shortcutKeys(in: list).contains("⇧J / ⇧K"), "list should include Shift+J/K")
        try expect(shortcutKeys(in: compose).contains("⇧⏎"), "compose should include Shift+Return")
        try expect(shortcutKeys(in: edit).contains("⇧⏎"), "edit should include Shift+Return")
        try expect(shortcutKeys(in: edit).contains("⌘N"), "edit should include Cmd+N")
    }

    test("pane shortcut catalog omits tab bucket movement") {
        let allKeys = shortcutKeys(in: todoShortcutSections(scope: .pane)).joined(separator: " ")
        try expect(!allKeys.contains("⇧H"), "pane help should not include Shift+H")
        try expect(!allKeys.contains("⇧L"), "pane help should not include Shift+L")
    }

    test("tab shortcut catalog includes tab-only bucket movement") {
        let sections = todoShortcutSections(scope: .tab)
        let list = try shortcutSection("List", in: sections)
        let compose = try shortcutSection("Compose", in: sections)
        let edit = try shortcutSection("Edit", in: sections)

        try expect(shortcutKeys(in: list).contains("⌘N"), "list should include Cmd+N")
        try expect(shortcutKeys(in: list).contains("⌘⌫"), "list should include Cmd+Delete")
        try expect(shortcutKeys(in: list).contains("⇧J / ⇧K"), "list should include Shift+J/K")
        try expect(shortcutKeys(in: list).contains("⇧H / ⇧L"), "list should include Shift+H/L")
        try expect(shortcutKeys(in: compose).contains("⇧⏎"), "compose should include Shift+Return")
        try expect(shortcutKeys(in: edit).contains("⇧⏎"), "edit should include Shift+Return")
        try expect(shortcutKeys(in: edit).contains("⌘N"), "edit should include Cmd+N")
    }

    test("shortcut catalog uses menu key glyphs") {
        let allKeys = shortcutKeys(in: todoShortcutSections(scope: .tab)).joined(separator: " ")
        try expect(allKeys.contains("⌘"), "catalog should use command glyph")
        try expect(allKeys.contains("⇧"), "catalog should use shift glyph")
        try expect(allKeys.contains("⏎"), "catalog should use return glyph")
        try expect(allKeys.contains("⌫"), "catalog should use delete glyph")
        try expect(!allKeys.contains("Cmd+"), "catalog should not render Cmd+ aliases")
        try expect(!allKeys.contains("Shift+Return"), "catalog should render Shift+Return as a glyph pair")
    }
}

private func shortcutSection(_ title: String, in sections: [TodoShortcutSection]) throws -> TodoShortcutSection {
    guard let section = sections.first(where: { $0.title == title }) else {
        throw TestFailure(message: "missing \(title) shortcut section")
    }
    return section
}

private func shortcutKeys(in section: TodoShortcutSection) -> [String] {
    section.items.map(\.keys)
}

private func shortcutKeys(in sections: [TodoShortcutSection]) -> [String] {
    sections.flatMap { shortcutKeys(in: $0) }
}
