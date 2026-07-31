// Loads DanTerm's packaged symbols-only Nerd Font without process-global font lookup.
import CoreText
import Foundation

/// Resolves and constructs the bundled symbols face from its bytes so an installed
/// font with the same name can never mask a missing application resource.
package enum NerdFontSymbolsResource {
    package static let directoryName = "NerdFontsSymbolsOnly"
    package static let fontName = "SymbolsNerdFontMono-Regular"

    /// Finds the app-assembled resource first and the SwiftPM resource bundle only
    /// where that generated accessor is guaranteed to exist.
    package static func packagedURL() -> URL? {
        if let applicationResource = Bundle.main.url(
            forResource: fontName,
            withExtension: "ttf",
            subdirectory: directoryName
        ) {
            return applicationResource
        }

        // The assembled app deliberately copies this resource into Bundle.main.
        // Do not touch SwiftPM's generated Bundle.module accessor there: its
        // missing-bundle behavior is fatal, while a missing font must disable the
        // feature. Package executables and tests do carry the generated bundle.
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return nil
        }
        return Bundle.module.url(
            forResource: fontName,
            withExtension: "ttf",
            subdirectory: directoryName
        )
    }

    /// Builds a face from the resource's bytes without registering or resolving
    /// the font by its process-global name.
    package static func face(at url: URL?, pointSize: CGFloat) -> CTFont? {
        guard let url,
              let data = try? Data(contentsOf: url) as CFData,
              let descriptor = CTFontManagerCreateFontDescriptorFromData(data)
        else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
    }
}
