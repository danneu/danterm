// Tests for the argv-token classifier used by `danterm pane input --`.
import Foundation
import Testing
@testable import DanTermProtocol

struct KeyTokensTests {
    @Test("empty tokens")
    func emptyTokens() throws {
        #expect(try parseKeyTokens([]) == [])
    }

    @Test("plain text")
    func plainText() throws {
        #expect(try parseKeyTokens(["ls"]) == [.text("ls")])
    }

    @Test("text then key")
    func textThenKey() throws {
        #expect(try parseKeyTokens(["ls", "Enter"]) == [.text("ls"), .key(.named(.enter), [])])
    }

    @Test("colon prefixed text is literal")
    func colonPrefixedTextIsLiteral() throws {
        #expect(try parseKeyTokens([":wq"]) == [.text(":wq")])
    }

    @Test("unknown keyname falls through as text")
    func unknownKeynameFallsThroughAsText() throws {
        #expect(try parseKeyTokens(["Entr"]) == [.text("Entr")])
    }

    @Test("ctrl letter")
    func ctrlLetter() throws {
        #expect(try parseKeyTokens(["C-c"]) == [.key(.character("c"), [.ctrl])])
    }

    @Test("modifier with unresolvable base throws")
    func modifierWithUnresolvableBaseThrows() throws {
        #expect(throws: KeyTokenError.unknownKey("C-yz")) {
            try parseKeyTokens(["C-yz"])
        }
    }

    @Test("alt letter")
    func altLetter() throws {
        #expect(try parseKeyTokens(["M-x"]) == [.key(.character("x"), [.alt])])
    }

    @Test("alt named key")
    func altNamedKey() throws {
        #expect(try parseKeyTokens(["M-Enter"]) == [.key(.named(.enter), [.alt])])
    }

    @Test("ctrl alt named key")
    func ctrlAltNamedKey() throws {
        #expect(try parseKeyTokens(["C-M-Up"]) == [.key(.named(.up), [.ctrl, .alt])])
    }

    @Test("function key")
    func functionKey() throws {
        #expect(try parseKeyTokens(["F5"]) == [.key(.named(.f5), [])])
    }

    @Test("function key F12")
    func functionKeyF12() throws {
        #expect(try parseKeyTokens(["F12"]) == [.key(.named(.f12), [])])
    }

    @Test("function key out of range throws")
    func functionKeyOutOfRangeThrows() throws {
        #expect(throws: KeyTokenError.unknownKey("F30")) {
            try parseKeyTokens(["F30"])
        }
    }

    @Test("function key zero throws")
    func functionKeyZeroThrows() throws {
        #expect(throws: KeyTokenError.unknownKey("F0")) {
            try parseKeyTokens(["F0"])
        }
    }

    @Test("function key leading zero throws")
    func functionKeyLeadingZeroThrows() throws {
        #expect(throws: KeyTokenError.unknownKey("F01")) {
            try parseKeyTokens(["F01"])
        }
    }

    @Test("function key leading zero F12 throws")
    func functionKeyLeadingZeroF12Throws() throws {
        #expect(throws: KeyTokenError.unknownKey("F012")) {
            try parseKeyTokens(["F012"])
        }
    }

    @Test("almost fn shaped falls through as text")
    func almostFnShapedFallsThroughAsText() throws {
        #expect(try parseKeyTokens(["F1a"]) == [.text("F1a")])
    }

    @Test("shift named key")
    func shiftNamedKey() throws {
        #expect(try parseKeyTokens(["S-Tab"]) == [.key(.named(.tab), [.shift])])
    }

    @Test("shift anywhere in named key chain")
    func shiftAnywhereInNamedKeyChain() throws {
        #expect(try parseKeyTokens(["C-S-Up"]) == [.key(.named(.up), [.ctrl, .shift])])
    }

    @Test("shift letter remains rejected")
    func shiftLetterRemainsRejected() throws {
        #expect(throws: KeyTokenError.unknownKey("S-a")) {
            try parseKeyTokens(["S-a"])
        }
    }

    @Test("bare space token is literal space")
    func bareSpaceTokenIsLiteralSpace() throws {
        #expect(try parseKeyTokens(["Space"]) == [.text(" ")])
    }

    @Test("space amid text events")
    func spaceAmidTextEvents() throws {
        #expect(try parseKeyTokens(["echo", "Space", "hi"]) == [.text("echo"), .text(" "), .text("hi")])
    }

    @Test("ctrl character gap tokens", arguments: [
        ("C-Space", Character(" ")),
        ("C-\\", Character("\\")),
        ("C-[", Character("[")),
        ("C-]", Character("]")),
        ("C-^", Character("^")),
        ("C-_", Character("_")),
    ])
    func ctrlCharacterGapTokens(_ token: String, _ character: Character) throws {
        #expect(try parseKeyTokens([token]) == [.key(.character(character), [.ctrl])])
    }

    @Test("insert is a named key")
    func insertIsNamedKey() throws {
        #expect(try parseKeyTokens(["Insert"]) == [.key(.named(.insert), [])])
    }

    @Test("literal mode is exhaustive")
    func literalModeIsExhaustive() throws {
        #expect(try parseKeyTokens(["Enter", "C-c", "Space"], literal: true) == [.text("Enter"), .text("C-c"), .text("Space")])
    }

    // Wire-level KeyName decoder, used by direct IPC clients that bypass the
    // CLI parser.

    @Test("wire name enter")
    func wireNameEnter() {
        #expect(KeyName(wireName: "Enter") == .named(.enter))
    }

    @Test("wire name backspace alias")
    func wireNameBackspaceAlias() {
        #expect(KeyName(wireName: "Backspace") == .named(.bspace))
    }

    @Test("wire name esc alias")
    func wireNameEscAlias() {
        #expect(KeyName(wireName: "Esc") == .named(.escape))
    }

    @Test("wire name F12")
    func wireNameF12() {
        #expect(KeyName(wireName: "F12") == .named(.f12))
    }

    @Test("every named key wire name round trips", arguments: NamedKey.allCases)
    func everyNamedKeyWireNameRoundTrips(_ key: NamedKey) {
        // Intent: every NamedKey's canonical wireName decodes back to that same key.
        // Why it exists: NamedKey.wireName (encode) and namedAliases/KeyName(wireName:)
        //   (decode) are now one derived pair; this CaseIterable sweep turns any future
        //   case that forgets to round-trip into a test failure, not a silent wire bug.
        // Scenario: spec-first invariant for the pane.input key serialization bijection.
        #expect(
            KeyName(wireName: KeyName.named(key).wireName) == .named(key),
            "wireName round-trip failed for \(key)"
        )
    }

    @Test("wire name F30 rejected")
    func wireNameF30Rejected() {
        #expect(KeyName(wireName: "F30") == nil)
    }

    @Test("wire name F0 rejected")
    func wireNameF0Rejected() {
        #expect(KeyName(wireName: "F0") == nil)
    }

    @Test("wire name F01 rejected")
    func wireNameF01Rejected() {
        #expect(KeyName(wireName: "F01") == nil)
    }

    @Test("wire name F012 rejected")
    func wireNameF012Rejected() {
        #expect(KeyName(wireName: "F012") == nil)
    }

    @Test("wire name lowercase letter")
    func wireNameLowercaseLetter() {
        #expect(KeyName(wireName: "c") == .character("c"))
    }

    @Test("wire name printable ASCII character")
    func wireNamePrintableASCIICharacter() {
        #expect(KeyName(wireName: "\\") == .character("\\"))
        #expect(KeyName(wireName: " ") == .character(" "))
    }

    @Test("wire name bogus rejected")
    func wireNameBogusRejected() {
        #expect(KeyName(wireName: "Bogus") == nil)
    }

    @Test("wire name empty rejected")
    func wireNameEmptyRejected() {
        #expect(KeyName(wireName: "") == nil)
    }

    @Test("wire name uppercase enter rejected")
    func wireNameUppercaseEnterRejected() {
        #expect(KeyName(wireName: "ENTER") == nil)
    }
}
