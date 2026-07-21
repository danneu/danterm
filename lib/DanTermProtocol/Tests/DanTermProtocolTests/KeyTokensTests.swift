// Tests for the argv-token classifier used by `danterm pane input --`.
import Foundation
import XCTest
@testable import DanTermProtocol

final class KeyTokensTests: XCTestCase {
    func testEmptyTokens() throws {
        XCTAssertEqual(try parseKeyTokens([]), [])
    }

    func testPlainText() throws {
        XCTAssertEqual(try parseKeyTokens(["ls"]), [.text("ls")])
    }

    func testTextThenKey() throws {
        XCTAssertEqual(
            try parseKeyTokens(["ls", "Enter"]),
            [.text("ls"), .key(.named(.enter), [])]
        )
    }

    func testColonPrefixedTextIsLiteral() throws {
        XCTAssertEqual(try parseKeyTokens([":wq"]), [.text(":wq")])
    }

    func testUnknownKeynameFallsThroughAsText() throws {
        XCTAssertEqual(try parseKeyTokens(["Entr"]), [.text("Entr")])
    }

    func testCtrlLetter() throws {
        XCTAssertEqual(
            try parseKeyTokens(["C-c"]),
            [.key(.letter("c"), [.ctrl])]
        )
    }

    func testModifierWithUnresolvableBaseThrows() throws {
        XCTAssertThrowsError(try parseKeyTokens(["C-yz"])) { err in
            XCTAssertEqual(err as? KeyTokenError, .unknownKey("C-yz"))
        }
    }

    func testAltLetter() throws {
        XCTAssertEqual(
            try parseKeyTokens(["M-x"]),
            [.key(.letter("x"), [.alt])]
        )
    }

    func testAltNamedKey() throws {
        XCTAssertEqual(
            try parseKeyTokens(["M-Enter"]),
            [.key(.named(.enter), [.alt])]
        )
    }

    func testCtrlAltNamedKey() throws {
        XCTAssertEqual(
            try parseKeyTokens(["C-M-Up"]),
            [.key(.named(.up), [.ctrl, .alt])]
        )
    }

    func testFunctionKey() throws {
        XCTAssertEqual(
            try parseKeyTokens(["F5"]),
            [.key(.named(.f5), [])]
        )
    }

    func testFunctionKeyF12() throws {
        XCTAssertEqual(
            try parseKeyTokens(["F12"]),
            [.key(.named(.f12), [])]
        )
    }

    func testFunctionKeyOutOfRangeThrows() throws {
        XCTAssertThrowsError(try parseKeyTokens(["F30"])) { err in
            XCTAssertEqual(err as? KeyTokenError, .unknownKey("F30"))
        }
    }

    func testFunctionKeyZeroThrows() throws {
        XCTAssertThrowsError(try parseKeyTokens(["F0"])) { err in
            XCTAssertEqual(err as? KeyTokenError, .unknownKey("F0"))
        }
    }

    func testFunctionKeyLeadingZeroThrows() throws {
        XCTAssertThrowsError(try parseKeyTokens(["F01"])) { err in
            XCTAssertEqual(err as? KeyTokenError, .unknownKey("F01"))
        }
    }

    func testFunctionKeyLeadingZeroF12Throws() throws {
        XCTAssertThrowsError(try parseKeyTokens(["F012"])) { err in
            XCTAssertEqual(err as? KeyTokenError, .unknownKey("F012"))
        }
    }

    func testAlmostFnShapedFallsThroughAsText() throws {
        XCTAssertEqual(try parseKeyTokens(["F1a"]), [.text("F1a")])
    }

    func testShiftNamedKey() throws {
        XCTAssertEqual(
            try parseKeyTokens(["S-Tab"]),
            [.key(.named(.tab), [.shift])]
        )
    }

    func testShiftAnywhereInNamedKeyChain() throws {
        XCTAssertEqual(
            try parseKeyTokens(["C-S-Up"]),
            [.key(.named(.up), [.ctrl, .shift])]
        )
    }

    func testShiftLetterRemainsRejected() throws {
        XCTAssertThrowsError(try parseKeyTokens(["S-a"])) { err in
            XCTAssertEqual(err as? KeyTokenError, .unknownKey("S-a"))
        }
    }

    func testBareSpaceTokenIsLiteralSpace() throws {
        XCTAssertEqual(try parseKeyTokens(["Space"]), [.text(" ")])
    }

    func testSpaceAmidTextEvents() throws {
        XCTAssertEqual(
            try parseKeyTokens(["echo", "Space", "hi"]),
            [.text("echo"), .text(" "), .text("hi")]
        )
    }

    func testCtrlSpaceThrows() throws {
        XCTAssertThrowsError(try parseKeyTokens(["C-Space"])) { err in
            XCTAssertEqual(err as? KeyTokenError, .unknownKey("C-Space"))
        }
    }

    func testLiteralModeIsExhaustive() throws {
        XCTAssertEqual(
            try parseKeyTokens(["Enter", "C-c", "Space"], literal: true),
            [.text("Enter"), .text("C-c"), .text("Space")]
        )
    }

    // Wire-level KeyName decoder, used by direct IPC clients that bypass the
    // CLI parser.

    func testWireNameEnter() {
        XCTAssertEqual(KeyName(wireName: "Enter"), .named(.enter))
    }

    func testWireNameBackspaceAlias() {
        XCTAssertEqual(KeyName(wireName: "Backspace"), .named(.bspace))
    }

    func testWireNameEscAlias() {
        XCTAssertEqual(KeyName(wireName: "Esc"), .named(.escape))
    }

    func testWireNameF12() {
        XCTAssertEqual(KeyName(wireName: "F12"), .named(.f12))
    }

    func testEveryNamedKeyWireNameRoundTrips() {
        // Intent: every NamedKey's canonical wireName decodes back to that same key.
        // Why it exists: NamedKey.wireName (encode) and namedAliases/KeyName(wireName:)
        //   (decode) are now one derived pair; this CaseIterable sweep turns any future
        //   case that forgets to round-trip into a test failure, not a silent wire bug.
        // Scenario: spec-first invariant for the pane.input key serialization bijection.
        for k in NamedKey.allCases {
            XCTAssertEqual(
                KeyName(wireName: KeyName.named(k).wireName),
                .named(k),
                "wireName round-trip failed for \(k)"
            )
        }
    }

    func testWireNameF30Rejected() {
        XCTAssertNil(KeyName(wireName: "F30"))
    }

    func testWireNameF0Rejected() {
        XCTAssertNil(KeyName(wireName: "F0"))
    }

    func testWireNameF01Rejected() {
        XCTAssertNil(KeyName(wireName: "F01"))
    }

    func testWireNameF012Rejected() {
        XCTAssertNil(KeyName(wireName: "F012"))
    }

    func testWireNameLowercaseLetter() {
        XCTAssertEqual(KeyName(wireName: "c"), .letter("c"))
    }

    func testWireNameBogusRejected() {
        XCTAssertNil(KeyName(wireName: "Bogus"))
    }

    func testWireNameEmptyRejected() {
        XCTAssertNil(KeyName(wireName: ""))
    }

    func testWireNameUppercaseEnterRejected() {
        XCTAssertNil(KeyName(wireName: "ENTER"))
    }
}
