// Portable CoreText queries for DanTerm's configurable `font.family`: which
// families this machine has installed, and whether a name the user typed into
// config.json is one of them. This is the impure half of the font setting -- the
// pure core validates `font.family` as syntax only and is handed the verdict --
// so it belongs here alongside the other OS-registry probes, not in DanTermCore.
// It knows nothing about config or the render layer: it takes a string and
// returns a family name or nil, which is all both callers (the app's
// resolve-and-apply path and `danterm doctor`) need.
import CoreText
import Foundation

/// Installed font families in a stable, presentable order: deduplicated,
/// case-insensitively alphabetical, and without CoreText's hidden dot-prefixed
/// system-internal entries. This is the list the Preferences picker offers, so
/// every entry must be a name `resolveInstalledFontFamily` accepts.
func installedFontFamilyNames() -> [String] {
    let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
    var seen: Set<String> = []
    return names
        .filter { $0.hasPrefix(".") == false && seen.insert($0).inserted }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

/// Resolves a requested font name to the canonical installed family it names, or
/// nil when nothing installed carries that name.
///
/// Canonicalizing, per the schema's one-family rule: a PostScript face name is
/// treated as an alias for its family, so `"Menlo-Bold"` yields `"Menlo"` and the
/// renderer keeps deriving bold and italic itself. Nil is a real answer -- the
/// caller falls back to the system monospace font and warns -- which is why this
/// cannot be built on `CTFontCreateWithName`, whose last-resort substitution
/// makes every typo look installed.
func resolveInstalledFontFamily(named name: String) -> String? {
    let requested = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard requested.isEmpty == false else { return nil }

    let catalog = installedFontFamilyNames()
    if let family = catalog.first(
        where: { $0.localizedCaseInsensitiveCompare(requested) == .orderedSame }
    ) {
        return family
    }

    guard let matchedFamily = familyName(ofInstalledFontNamed: requested) else { return nil }
    return catalog.first(
        where: { $0.localizedCaseInsensitiveCompare(matchedFamily) == .orderedSame }
    ) ?? matchedFamily
}

/// Looks up the family of an installed face by its PostScript name, using a
/// mandatory-attribute descriptor match so an unknown name returns nil instead of
/// a substituted fallback face.
private func familyName(ofInstalledFontNamed name: String) -> String? {
    let descriptor = CTFontDescriptorCreateWithAttributes(
        [kCTFontNameAttribute: name] as CFDictionary
    )
    let mandatory: Set<CFString> = [kCTFontNameAttribute]
    guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(
        descriptor,
        mandatory as CFSet
    ) else {
        return nil
    }
    return CTFontDescriptorCopyAttribute(matched, kCTFontFamilyNameAttribute) as? String
}
