// Pure decode boundary for the complete, versioned theme catalog bundled with DanTerm.
import Foundation

/// Carries one validated eight-bit sRGB value without renderer or AppKit dependencies.
struct ThemeRGBColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

/// Retains the upstream identity required to audit each redistributed theme.
struct ThemeProvenance: Equatable, Sendable {
    let collection: String
    let release: String
}

/// Represents every color required to render one theme; decode never returns a partial value.
struct DanTermTheme: Equatable, Sendable {
    let name: String
    let foreground: ThemeRGBColor
    let background: ThemeRGBColor
    let cursor: ThemeRGBColor
    let cursorText: ThemeRGBColor
    let selectionBackground: ThemeRGBColor
    let selectionForeground: ThemeRGBColor
    let ansiPalette: [ThemeRGBColor]
    let provenance: ThemeProvenance
}

/// Validates the packed resource as one unit so a malformed entry disables the whole catalog.
struct ThemeCatalogDocument: Equatable, Sendable {
    let themes: [DanTermTheme]

    var names: [String] {
        themes.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Decodes only the current complete schema, including unique non-empty theme names.
    static func decode(_ data: Data) -> Self? {
        guard let raw = try? JSONDecoder().decode(RawCatalog.self, from: data),
              raw.schemaVersion == 1,
              raw.themes.isEmpty == false
        else { return nil }

        var names: Set<String> = []
        var themes: [DanTermTheme] = []
        themes.reserveCapacity(raw.themes.count)
        for rawTheme in raw.themes {
            guard rawTheme.schemaVersion == 1,
                  rawTheme.name.isEmpty == false,
                  names.insert(rawTheme.name).inserted,
                  rawTheme.ansiPalette.count == 16,
                  rawTheme.provenance.collection.isEmpty == false,
                  rawTheme.provenance.release.isEmpty == false,
                  let foreground = decodeColor(rawTheme.foreground),
                  let background = decodeColor(rawTheme.background),
                  let cursor = decodeColor(rawTheme.cursor),
                  let cursorText = decodeColor(rawTheme.cursorText),
                  let selectionBackground = decodeColor(rawTheme.selectionBackground),
                  let selectionForeground = decodeColor(rawTheme.selectionForeground)
            else { return nil }
            let palette = rawTheme.ansiPalette.compactMap(decodeColor)
            guard palette.count == 16 else { return nil }
            themes.append(DanTermTheme(
                name: rawTheme.name,
                foreground: foreground,
                background: background,
                cursor: cursor,
                cursorText: cursorText,
                selectionBackground: selectionBackground,
                selectionForeground: selectionForeground,
                ansiPalette: palette,
                provenance: ThemeProvenance(
                    collection: rawTheme.provenance.collection,
                    release: rawTheme.provenance.release
                )
            ))
        }
        return Self(themes: themes)
    }

    private static func decodeColor(_ value: String) -> ThemeRGBColor? {
        guard value.count == 7, value.first == "#",
              value.dropFirst().allSatisfy({ $0.isHexDigit }),
              let encoded = UInt32(value.dropFirst(), radix: 16)
        else { return nil }
        return ThemeRGBColor(
            red: UInt8((encoded >> 16) & 0xFF),
            green: UInt8((encoded >> 8) & 0xFF),
            blue: UInt8(encoded & 0xFF)
        )
    }
}

/// Mirrors the catalog envelope only long enough to validate and project it.
private struct RawCatalog: Decodable {
    let schemaVersion: Int
    let themes: [RawTheme]
}

/// Keeps untrusted theme strings separate from the validated runtime value.
private struct RawTheme: Decodable {
    let schemaVersion: Int
    let name: String
    let foreground: String
    let background: String
    let cursor: String
    let cursorText: String
    let selectionBackground: String
    let selectionForeground: String
    let ansiPalette: [String]
    let provenance: RawThemeProvenance
}

/// Requires every provenance field before a theme can enter the runtime catalog.
private struct RawThemeProvenance: Decodable {
    let collection: String
    let release: String
}
