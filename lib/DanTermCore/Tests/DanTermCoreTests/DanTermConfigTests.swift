// Swift Testing migration of the legacy `tests/DanTermConfigTests.swift`
// harness suite. Pins the DanTermConfigParser + DanTermConfigWriter wire
// format: parsing of remote-theme / alert-clear-mode (with whitespace,
// blank-line, comment, and last-wins behavior), Ghostty-key passthrough
// (the parser returns DanTermConfig defaults when only Ghostty keys
// appear), and the setKey / removeKey writer paths (replace, append,
// duplicate-replace, append-to-empty, no-match on commented-out keys,
// and the full round-trip through the parser).
import Foundation
import Testing

@testable import DanTermCore

@Suite struct DanTermConfigTests {
    @Test("parse valid remote-theme")
    func parseValidRemoteTheme() {
        // Intent: a bare `remote-theme = <value>` line parses into
        //   config.remoteTheme.
        // Why it exists: pins the bare key parse.
        // Scenario: spec-first single key.
        let config = DanTermConfigParser.parse(content: "remote-theme = Grape")
        #expect(config.remoteTheme == "Grape")
    }

    @Test("parse empty file returns defaults")
    func parseEmptyFileReturnsDefaults() {
        // Intent: an empty file parses into DanTermConfig.default.
        // Why it exists: pins the empty-input fallback.
        // Scenario: spec-first empty file.
        let config = DanTermConfigParser.parse(content: "")
        #expect(config == DanTermConfig.default)
    }

    @Test("parse file with only Ghostty keys returns defaults")
    func parseFileWithOnlyGhosttyKeysReturnsDefaults() {
        // Intent: a file containing only Ghostty keys returns
        //   DanTermConfig.default (the parser ignores foreign keys).
        // Why it exists: pins the parser's "DanTerm keys only" scope.
        // Scenario: spec-first Ghostty-only.
        let config = DanTermConfigParser.parse(content: """
        font-size = 14
        theme = Dracula
        scrollbar = never
        """)
        #expect(config == DanTermConfig.default)
    }

    @Test("comments and blank lines ignored")
    func commentsAndBlankLinesIgnored() {
        // Intent: comments and blank lines are skipped; the surviving
        //   `remote-theme` value parses.
        // Why it exists: pins the lexer's skip rules.
        // Scenario: spec-first comments + blanks.
        let config = DanTermConfigParser.parse(content: """
        # This is a comment

        # Another comment
        remote-theme = Ocean

        """)
        #expect(config.remoteTheme == "Ocean")
    }

    @Test("whitespace tolerance around =")
    func whitespaceToleranceAroundEquals() {
        // Intent: whitespace around `=` is permitted (zero, single,
        //   double).
        // Why it exists: pins the lexer's whitespace tolerance.
        // Scenario: spec-first whitespace tolerance.
        let config = DanTermConfigParser.parse(content: "remote-theme=Grape")
        #expect(config.remoteTheme == "Grape")

        let config2 = DanTermConfigParser.parse(content: "remote-theme  =  Grape")
        #expect(config2.remoteTheme == "Grape")
    }

    @Test("empty value keeps default")
    func emptyValueKeepsDefault() {
        // Intent: an empty value on a known key keeps the default.
        // Why it exists: pins the empty-value fallback.
        // Scenario: spec-first empty value.
        let config = DanTermConfigParser.parse(content: "remote-theme = ")
        #expect(config.remoteTheme == "Purplepeter")
    }

    @Test("last value wins")
    func lastValueWins() {
        // Intent: when a key appears multiple times, the last value
        //   wins.
        // Why it exists: pins the duplicate-key rule.
        // Scenario: spec-first last wins.
        let config = DanTermConfigParser.parse(content: """
        remote-theme = First
        remote-theme = Second
        """)
        #expect(config.remoteTheme == "Second")
    }

    @Test("theme name with spaces")
    func themeNameWithSpaces() {
        // Intent: theme values containing spaces parse intact (greedy
        //   to EOL).
        // Why it exists: pins the greedy-value lexer rule.
        // Scenario: spec-first spaces in value.
        let config = DanTermConfigParser.parse(content: "remote-theme = Solarized Light")
        #expect(config.remoteTheme == "Solarized Light")
    }

    @Test("parse alert-clear-mode focus")
    func parseAlertClearModeFocus() {
        // Intent: `alert-clear-mode = focus` parses to .focus.
        // Why it exists: pins the enum parse.
        // Scenario: spec-first focus enum.
        let config = DanTermConfigParser.parse(content: "alert-clear-mode = focus")
        #expect(config.alertClearMode == .focus)
    }

    @Test("parse alert-clear-mode manual")
    func parseAlertClearModeManual() {
        // Intent: `alert-clear-mode = manual` parses to .manual.
        // Why it exists: pins the other enum branch.
        // Scenario: spec-first manual enum.
        let config = DanTermConfigParser.parse(content: "alert-clear-mode = manual")
        #expect(config.alertClearMode == .manual)
    }

    @Test("parse invalid alert-clear-mode keeps default")
    func parseInvalidAlertClearModeKeepsDefault() {
        // Intent: an unknown enum value falls back to the default.
        // Why it exists: pins fail-open on unknown enum values.
        // Scenario: spec-first unknown enum.
        let config = DanTermConfigParser.parse(content: "alert-clear-mode = bogus")
        #expect(config.alertClearMode == .focus)
    }

    @Test("parse empty alert-clear-mode keeps default")
    func parseEmptyAlertClearModeKeepsDefault() {
        // Intent: an empty enum value falls back to the default.
        // Why it exists: pins the empty-enum fallback.
        // Scenario: spec-first empty enum.
        let config = DanTermConfigParser.parse(content: "alert-clear-mode = ")
        #expect(config.alertClearMode == .focus)
    }

    // MARK: - DanTermConfigWriter

    @Test("setKey replaces existing key value")
    func setKeyReplacesExistingKeyValue() {
        // Intent: setKey replaces an existing line in place.
        // Why it exists: pins the in-place replacement path.
        // Scenario: spec-first in-place replace.
        let input = "remote-theme = Old\n"
        let result = DanTermConfigWriter.setKey("remote-theme", value: "New", in: input)
        #expect(result == "remote-theme = New\n")
    }

    @Test("setKey appends when key not present")
    func setKeyAppendsWhenKeyNotPresent() {
        // Intent: setKey appends a new line when the key isn't present.
        // Why it exists: pins the append path.
        // Scenario: spec-first append.
        let input = "font-size = 14\n"
        let result = DanTermConfigWriter.setKey("remote-theme", value: "Grape", in: input)
        #expect(result == "font-size = 14\nremote-theme = Grape\n")
    }

    @Test("setKey preserves comments, blank lines, Ghostty keys")
    func setKeyPreservesCommentsBlankLinesGhosttyKeys() {
        // Intent: setKey keeps surrounding comments, blank lines, and
        //   Ghostty keys intact while replacing the targeted line.
        // Why it exists: pins the preserve-everything-else rule.
        // Scenario: spec-first preserve siblings.
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
        #expect(result == expected)
    }

    @Test("setKey replaces last occurrence when duplicates exist")
    func setKeyReplacesLastOccurrenceWhenDuplicatesExist() {
        // Intent: setKey replaces the last occurrence when duplicates
        //   exist.
        // Why it exists: pins the last-wins write semantics (matching
        //   the parser).
        // Scenario: spec-first duplicate-replace.
        let input = "remote-theme = First\nremote-theme = Second\n"
        let result = DanTermConfigWriter.setKey("remote-theme", value: "Third", in: input)
        #expect(result == "remote-theme = First\nremote-theme = Third\n")
    }

    @Test("setKey appends to empty content")
    func setKeyAppendsToEmptyContent() {
        // Intent: setKey on empty content yields a leading-blank-line +
        //   new key.
        // Why it exists: pins the empty-input append shape.
        // Scenario: spec-first empty append.
        let result = DanTermConfigWriter.setKey("alert-clear-mode", value: "manual", in: "")
        #expect(result == "\nalert-clear-mode = manual")
    }

    @Test("setKey round-trip: write then parse returns expected config")
    func setKeyRoundTripWriteThenParseReturnsExpected() {
        // Intent: writing multiple keys and parsing back yields the
        //   expected config.
        // Why it exists: pins the writer/parser round-trip.
        // Scenario: spec-first round-trip.
        let input = "font-size = 14\n"
        var content = input
        content = DanTermConfigWriter.setKey("remote-theme", value: "Grape", in: content)
        content = DanTermConfigWriter.setKey("alert-clear-mode", value: "manual", in: content)
        let config = DanTermConfigParser.parse(content: content)
        #expect(config.remoteTheme == "Grape")
        #expect(config.alertClearMode == .manual)
    }

    @Test("setKey does not match commented-out keys")
    func setKeyDoesNotMatchCommentedOutKeys() {
        // Intent: setKey skips commented-out lines and appends instead.
        // Why it exists: pins the comment-skip rule.
        // Scenario: spec-first comment skip.
        let input = "# remote-theme = Old\n"
        let result = DanTermConfigWriter.setKey("remote-theme", value: "New", in: input)
        #expect(result == "# remote-theme = Old\nremote-theme = New\n")
    }

    // MARK: - DanTermConfigWriter.removeKey

    @Test("removeKey removes all occurrences of a key")
    func removeKeyRemovesAllOccurrencesOfAKey() {
        // Intent: removeKey strips every occurrence of the key.
        // Why it exists: pins the remove-all rule.
        // Scenario: spec-first remove all.
        let input = "theme = Dracula\nfont-size = 14\ntheme = Solarized\n"
        let result = DanTermConfigWriter.removeKey("theme", from: input)
        #expect(result == "font-size = 14\n")
    }

    @Test("removeKey preserves comments, blank lines, other keys")
    func removeKeyPreservesCommentsBlankLinesOtherKeys() {
        // Intent: removeKey leaves comments, blank lines, and other
        //   keys intact.
        // Why it exists: pins the preserve-everything-else rule for
        //   remove.
        // Scenario: spec-first preserve siblings on remove.
        let input = """
        # My config
        font-size = 14

        theme = Dracula
        remote-theme = Grape
        """
        let result = DanTermConfigWriter.removeKey("theme", from: input)
        let expected = """
        # My config
        font-size = 14

        remote-theme = Grape
        """
        #expect(result == expected)
    }

    @Test("removeKey on absent key returns content unchanged")
    func removeKeyOnAbsentKeyReturnsContentUnchanged() {
        // Intent: removeKey on an absent key is a no-op.
        // Why it exists: pins the no-op-on-absence rule.
        // Scenario: spec-first absent remove.
        let input = "font-size = 14\nremote-theme = Grape\n"
        let result = DanTermConfigWriter.removeKey("theme", from: input)
        #expect(result == input)
    }

    @Test("removeKey does not remove commented-out keys")
    func removeKeyDoesNotRemoveCommentedOutKeys() {
        // Intent: removeKey skips commented-out lines.
        // Why it exists: pins the comment-skip rule for remove.
        // Scenario: spec-first comment skip on remove.
        let input = "# theme = Old\nfont-size = 14\n"
        let result = DanTermConfigWriter.removeKey("theme", from: input)
        #expect(result == input, "commented key should not be removed")
    }
}
