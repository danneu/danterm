// Behavioral proofs for DanTerm's versioned JSON configuration document boundary.
import Foundation
import Testing

@testable import DanTermCore

struct DanTermConfigDocumentTests {
    @Test("v1 decodes every shipped setting")
    func v1DecodesEveryShippedSetting() throws {
        let document = try #require(DanTermConfigDocument.decode(data("""
        {
          "schemaVersion": 1,
          "font": { "size": 15.5 },
          "theme": { "default": "Solarized Light", "remote": "Grape" },
          "ui": { "alertClearMode": "manual" }
        }
        """)))

        #expect(document.config.defaultTheme == "Solarized Light")
        #expect(document.config.remoteTheme == "Grape")
        #expect(document.config.fontSize == 15.5)
        #expect(document.config.alertClearMode == .manual)
    }

    @Test("only an exact integer schemaVersion 1 is writable", arguments: [
        "{",
        "{}",
        #"{"schemaVersion": 1.0}"#,
        #"{"schemaVersion": "1"}"#,
        #"{"schemaVersion": 2}"#,
    ])
    func rejectsUnwritableDocuments(_ source: String) {
        #expect(DanTermConfigDocument.decode(data(source)) == nil)
    }

    @Test("an invalid font size falls back without discarding valid fields")
    func invalidFontSizeDegradesPerField() throws {
        let document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"font":{"size":0},"theme":{"default":"Dracula"}}"#)))

        #expect(document.config.fontSize == nil)
        #expect(document.config.defaultTheme == "Dracula")
    }

    @Test("an empty theme falls back without discarding valid fields")
    func invalidThemeDegradesPerField() throws {
        let document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"theme":{"default":"","remote":"Grape"}}"#)))

        #expect(document.config.defaultTheme == nil)
        #expect(document.config.remoteTheme == "Grape")
    }

    @Test("an unknown alert mode falls back without discarding valid fields")
    func invalidAlertModeDegradesPerField() throws {
        let document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"theme":{"remote":"Grape"},"ui":{"alertClearMode":"sometimes"}}"#)))

        #expect(document.config.alertClearMode == .focus)
        #expect(document.config.remoteTheme == "Grape")
    }

    @Test("one transaction preserves unknown content and exact number tokens")
    func transactionPreservesUntargetedContent() throws {
        // Intent: editing every modeled object retains unknown top-level and sibling
        //   values, including number spellings Foundation numeric trees cannot preserve.
        // Why it exists: this is the losslessness requirement that rules out decoding
        //   through Double-backed JSONValue or re-encoding JSONSerialization numbers.
        // Scenario: Preferences changes all four settings in a hand-authored document
        //   that also carries future fields and exact large-integer/fraction tokens.
        var document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"font":{"size":13,"future":9007199254740993},"theme":{"default":"Old","remote":"Old Remote","contrast":0.1},"ui":{"alertClearMode":"focus","density":"compact"},"plugin":{"enabled":true,"values":[null,"kept"]}}"#)))

        document.setDefaultTheme("New")
        document.setRemoteTheme("New Remote")
        document.setFontSize(16)
        document.setAlertClearMode(.manual)
        let output = String(decoding: document.encoded(), as: UTF8.self)

        #expect(output.contains("9007199254740993"))
        #expect(output.contains("0.1"))
        #expect(output.contains(#""future": 9007199254740993"#))
        #expect(output.contains(#""contrast": 0.1"#))
        #expect(output.contains(#""density": "compact""#))
        #expect(output.contains(#""plugin": {"#))
        let roundTrip = try #require(DanTermConfigDocument.decode(document.encoded()))
        #expect(roundTrip.config.defaultTheme == "New")
        #expect(roundTrip.config.remoteTheme == "New Remote")
        #expect(roundTrip.config.fontSize == 16)
        #expect(roundTrip.config.alertClearMode == .manual)
    }

    @Test("setting unchanged values returns the original bytes")
    func unchangedSaveIsByteIdentical() throws {
        let original = data("""
        { "theme": { "remote": "Grape" }, "schemaVersion": 1,
          "font": { "size": 13.0 } }
        """)
        var document = try #require(DanTermConfigDocument.decode(original))

        document.setRemoteTheme("Grape")
        document.setFontSize(13)

        #expect(document.encoded() == original)
    }

    @Test("clearing optional settings removes their keys and restores defaults")
    func clearingOptionalSettingsRemovesKeys() throws {
        var document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"font":{"size":15,"future":true},"theme":{"default":"Dracula","remote":"Grape"}}"#)))

        document.setDefaultTheme(nil)
        document.setFontSize(nil)
        let output = String(decoding: document.encoded(), as: UTF8.self)
        let roundTrip = try #require(DanTermConfigDocument.decode(document.encoded()))

        #expect(output.contains(#""future": true"#))
        #expect(output.contains(#""default""#) == false)
        #expect(output.contains(#""size""#) == false)
        #expect(roundTrip.config.defaultTheme == nil)
        #expect(roundTrip.config.fontSize == nil)
        #expect(roundTrip.config.resolvedDefaultTheme == "Monokai Remastered")
        #expect(roundTrip.config.resolvedFontSize == 13)
    }

    @Test("a changed document reaches a deterministic fixed point")
    func changedDocumentEncodingIsDeterministic() throws {
        var first = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"theme":{"remote":"Grape"}}"#)))
        first.setAlertClearMode(.manual)
        let firstEncoding = first.encoded()
        var second = try #require(DanTermConfigDocument.decode(firstEncoding))
        second.setAlertClearMode(.manual)

        #expect(second.encoded() == firstEncoding)
    }
}

private func data(_ string: String) -> Data {
    Data(string.utf8)
}
