import Foundation

func danTermConfigTests() {
    print("DanTermConfig")

    test("parse valid remote-theme") {
        let config = DanTermConfigParser.parse(content: "remote-theme = Grape")
        try expectEqual(config.remoteTheme, "Grape")
    }

    test("parse empty file returns defaults") {
        let config = DanTermConfigParser.parse(content: "")
        try expectEqual(config, DanTermConfig.default)
    }

    test("parse file with only Ghostty keys returns defaults") {
        let config = DanTermConfigParser.parse(content: """
        font-size = 14
        theme = Dracula
        scrollbar = never
        """)
        try expectEqual(config, DanTermConfig.default)
    }

    test("comments and blank lines ignored") {
        let config = DanTermConfigParser.parse(content: """
        # This is a comment

        # Another comment
        remote-theme = Ocean

        """)
        try expectEqual(config.remoteTheme, "Ocean")
    }

    test("whitespace tolerance around =") {
        let config = DanTermConfigParser.parse(content: "remote-theme=Grape")
        try expectEqual(config.remoteTheme, "Grape")

        let config2 = DanTermConfigParser.parse(content: "remote-theme  =  Grape")
        try expectEqual(config2.remoteTheme, "Grape")
    }

    test("empty value keeps default") {
        let config = DanTermConfigParser.parse(content: "remote-theme = ")
        try expectEqual(config.remoteTheme, "Purplepeter")
    }

    test("last value wins") {
        let config = DanTermConfigParser.parse(content: """
        remote-theme = First
        remote-theme = Second
        """)
        try expectEqual(config.remoteTheme, "Second")
    }

    test("theme name with spaces") {
        let config = DanTermConfigParser.parse(content: "remote-theme = Solarized Light")
        try expectEqual(config.remoteTheme, "Solarized Light")
    }

    test("parse alert-clear-mode focus") {
        let config = DanTermConfigParser.parse(content: "alert-clear-mode = focus")
        try expectEqual(config.alertClearMode, .focus)
    }

    test("parse alert-clear-mode manual") {
        let config = DanTermConfigParser.parse(content: "alert-clear-mode = manual")
        try expectEqual(config.alertClearMode, .manual)
    }

    test("parse invalid alert-clear-mode keeps default") {
        let config = DanTermConfigParser.parse(content: "alert-clear-mode = bogus")
        try expectEqual(config.alertClearMode, .focus)
    }

    test("parse empty alert-clear-mode keeps default") {
        let config = DanTermConfigParser.parse(content: "alert-clear-mode = ")
        try expectEqual(config.alertClearMode, .focus)
    }

    // MARK: - DanTermConfigWriter

    print("DanTermConfigWriter")

    test("setKey replaces existing key value") {
        let input = "remote-theme = Old\n"
        let result = DanTermConfigWriter.setKey("remote-theme", value: "New", in: input)
        try expectEqual(result, "remote-theme = New\n")
    }

    test("setKey appends when key not present") {
        let input = "font-size = 14\n"
        let result = DanTermConfigWriter.setKey("remote-theme", value: "Grape", in: input)
        try expectEqual(result, "font-size = 14\nremote-theme = Grape\n")
    }

    test("setKey preserves comments, blank lines, Ghostty keys") {
        let input = """
        # My config
        font-size = 14

        remote-theme = Old
        theme = Dracula
        """
        let result = DanTermConfigWriter.setKey("remote-theme", value: "New", in: input)
        let expected = """
        # My config
        font-size = 14

        remote-theme = New
        theme = Dracula
        """
        try expectEqual(result, expected)
    }

    test("setKey replaces last occurrence when duplicates exist") {
        let input = "remote-theme = First\nremote-theme = Second\n"
        let result = DanTermConfigWriter.setKey("remote-theme", value: "Third", in: input)
        try expectEqual(result, "remote-theme = First\nremote-theme = Third\n")
    }

    test("setKey appends to empty content") {
        let result = DanTermConfigWriter.setKey("alert-clear-mode", value: "manual", in: "")
        try expectEqual(result, "\nalert-clear-mode = manual")
    }

    test("setKey round-trip: write then parse returns expected config") {
        let input = "font-size = 14\n"
        var content = input
        content = DanTermConfigWriter.setKey("remote-theme", value: "Grape", in: content)
        content = DanTermConfigWriter.setKey("alert-clear-mode", value: "manual", in: content)
        let config = DanTermConfigParser.parse(content: content)
        try expectEqual(config.remoteTheme, "Grape")
        try expectEqual(config.alertClearMode, .manual)
    }

    test("setKey does not match commented-out keys") {
        let input = "# remote-theme = Old\n"
        let result = DanTermConfigWriter.setKey("remote-theme", value: "New", in: input)
        // Should append, not replace the comment
        try expectEqual(result, "# remote-theme = Old\nremote-theme = New\n")
    }
}
