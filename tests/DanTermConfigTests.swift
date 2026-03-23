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
}
