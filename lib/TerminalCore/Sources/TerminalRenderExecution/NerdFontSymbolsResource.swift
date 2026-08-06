// Loads DanTerm's packaged symbols-only Nerd Font without process-global font lookup.
import CoreText
import Foundation

/// Owns one parsed symbols-font descriptor so every projected face shares the
/// resource bytes rather than loading them again for each terminal pane.
///
/// `@unchecked` bridges CoreText's unannotated immutable descriptor into the
/// module's `Sendable` render values. The descriptor and source URL never change
/// after initialization, and CoreText font objects are safe for concurrent reads.
package final class NerdFontSymbolsResource: @unchecked Sendable {
    package static let directoryName = "NerdFontsSymbolsOnly"
    package static let fontName = "SymbolsNerdFontMono-Regular"

    /// The lazily initialized process-wide packaged resource, or nil when the
    /// application resource is absent or unreadable.
    package static let packaged = load(at: packagedURL())

    /// The resource location retained for diagnostics and font-set equality.
    package let sourceURL: URL

    private let descriptor: CTFontDescriptor

    private init(sourceURL: URL, descriptor: CTFontDescriptor) {
        self.sourceURL = sourceURL
        self.descriptor = descriptor
    }

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

    /// Loads and parses one resource without registering or resolving the font by
    /// its process-global name. This uncached seam preserves missing-file tests.
    package static func load(at url: URL?) -> NerdFontSymbolsResource? {
        guard let url,
              let data = try? Data(contentsOf: url) as CFData,
              let descriptor = CTFontManagerCreateFontDescriptorFromData(data)
        else {
            return nil
        }
        return NerdFontSymbolsResource(sourceURL: url, descriptor: descriptor)
    }

    /// Projects the parsed resource to one point size without decoding it again.
    package func face(pointSize: CGFloat) -> CTFont {
        CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
    }
}
