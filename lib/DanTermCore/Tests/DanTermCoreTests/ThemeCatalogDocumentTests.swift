// Runtime catalog decode tests for complete, versioned DanTerm theme values.
import Foundation
import Testing

@testable import DanTermCore

struct ThemeCatalogDocumentTests {
    @Test("packed catalog decodes every complete theme field")
    func completeCatalogDecode() throws {
        let catalog = try #require(ThemeCatalogDocument.decode(validCatalogData()))
        let theme = try #require(catalog.themes.first)

        #expect(catalog.names == ["Fixture"])
        #expect(theme.name == "Fixture")
        #expect(theme.foreground == .init(red: 1, green: 2, blue: 3))
        #expect(theme.background == .init(red: 4, green: 5, blue: 6))
        #expect(theme.cursor == .init(red: 7, green: 8, blue: 9))
        #expect(theme.cursorText == .init(red: 10, green: 11, blue: 12))
        #expect(theme.selectionBackground == .init(red: 13, green: 14, blue: 15))
        #expect(theme.selectionForeground == .init(red: 16, green: 17, blue: 18))
        #expect(theme.ansiPalette.count == 16)
        #expect(theme.provenance.collection == "iTerm2-Color-Schemes")
        #expect(theme.provenance.release == "release-20260720-153658-97e244c")
    }

    @Test(
        "decode rejects a missing field instead of producing a partial theme",
        arguments: [
            "schemaVersion", "name", "foreground", "background", "cursor", "cursorText",
            "selectionBackground", "selectionForeground", "ansiPalette", "provenance",
        ]
    )
    func missingThemeField(field: String) throws {
        var object = try catalogObject()
        var theme = try #require((object["themes"] as? [[String: Any]])?.first)
        theme.removeValue(forKey: field)
        object["themes"] = [theme]

        #expect(ThemeCatalogDocument.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
    }

    @Test(
        "decode rejects every missing provenance field",
        arguments: ["collection", "release"]
    )
    func missingProvenanceField(field: String) throws {
        var object = try catalogObject()
        var theme = try #require((object["themes"] as? [[String: Any]])?.first)
        var provenance = try #require(theme["provenance"] as? [String: Any])
        provenance.removeValue(forKey: field)
        theme["provenance"] = provenance
        object["themes"] = [theme]

        #expect(ThemeCatalogDocument.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
    }

    @Test(
        "decode rejects corruption in every named color",
        arguments: [
            "foreground", "background", "cursor", "cursorText",
            "selectionBackground", "selectionForeground",
        ]
    )
    func invalidNamedColor(field: String) throws {
        var object = try catalogObject()
        var theme = try #require((object["themes"] as? [[String: Any]])?.first)
        theme[field] = "#nothex"
        object["themes"] = [theme]

        #expect(ThemeCatalogDocument.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
    }

    @Test("decode rejects missing catalog fields")
    func missingCatalogFields() throws {
        for field in ["schemaVersion", "themes"] {
            var object = try catalogObject()
            object.removeValue(forKey: field)
            #expect(
                ThemeCatalogDocument.decode(try JSONSerialization.data(withJSONObject: object)) == nil,
                "field: \(field)"
            )
        }
    }

    @Test("decode rejects invalid colors, palette arity, and schema versions")
    func invalidCatalogValues() throws {
        for mutation in ["palette", "catalogVersion", "themeVersion", "emptyName"] {
            var object = try catalogObject()
            var theme = try #require((object["themes"] as? [[String: Any]])?.first)
            switch mutation {
            case "palette": theme["ansiPalette"] = Array(repeating: "#000000", count: 15)
            case "catalogVersion": object["schemaVersion"] = 2
            case "themeVersion": theme["schemaVersion"] = 2
            case "emptyName": theme["name"] = ""
            default: Issue.record("unknown mutation")
            }
            object["themes"] = [theme]
            #expect(
                ThemeCatalogDocument.decode(try JSONSerialization.data(withJSONObject: object)) == nil,
                "mutation: \(mutation)"
            )
        }
    }

    private func catalogObject() throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: validCatalogData()) as? [String: Any]
        )
    }

    private func validCatalogData() -> Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "themes": [{
                "schemaVersion": 1,
                "name": "Fixture",
                "foreground": "#010203",
                "background": "#040506",
                "cursor": "#070809",
                "cursorText": "#0a0b0c",
                "selectionBackground": "#0d0e0f",
                "selectionForeground": "#101112",
                "ansiPalette": [
                  "#000000", "#000001", "#000002", "#000003",
                  "#000004", "#000005", "#000006", "#000007",
                  "#000008", "#000009", "#00000a", "#00000b",
                  "#00000c", "#00000d", "#00000e", "#00000f"
                ],
                "provenance": {
                  "collection": "iTerm2-Color-Schemes",
                  "release": "release-20260720-153658-97e244c"
                }
              }]
            }
            """.utf8
        )
    }
}
