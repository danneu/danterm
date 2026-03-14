// Runtime theme discovery: scans the app bundle's ghostty/themes/ directory
// and provides an alphabetized list of all available theme names.
import Foundation

class ThemeCatalog {
    static let shared = ThemeCatalog()
    let names: [String]  // all theme names, sorted alphabetically

    private init() {
        guard let themesURL = Bundle.main.url(
            forResource: "ghostty/themes", withExtension: nil
        ) else {
            names = []
            return
        }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: themesURL.path)) ?? []
        names = contents
            .filter { !$0.hasPrefix(".") }
            .sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}
