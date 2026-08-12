// Single-read runtime access to DanTerm's packed themes.
//
// Deliberately AppKit-free: the catalog is a process-wide `static let`, so it
// must be `Sendable`, and every projection into non-`Sendable` view types
// (`NSColor` swatches in `ThemeSwatchViews`, renderer values in
// `ThemeRenderBridge`) lives with its consumer instead.
import Foundation

/// Owns the process-wide decoded catalog and resolves names without performing per-name IO.
final class ThemeCatalog: Sendable {
    static let shared = ThemeCatalog(data: ThemeCatalog.loadBundledCatalog())

    let names: [String]
    private let themesByName: [String: DanTermTheme]

    init(data: Data?) {
        guard let data, let catalog = ThemeCatalogDocument.decode(data) else {
            names = []
            themesByName = [:]
            return
        }
        names = catalog.names
        themesByName = Dictionary(uniqueKeysWithValues: catalog.themes.map { ($0.name, $0) })
    }

    /// Resolves only exact catalog keys, so untrusted names never become filesystem paths.
    func theme(named name: String) -> DanTermTheme? {
        themesByName[name]
    }

    private static func loadBundledCatalog(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(
            forResource: "catalog",
            withExtension: "json",
            subdirectory: "themes"
        ) else { return nil }
        return try? Data(contentsOf: url)
    }
}
