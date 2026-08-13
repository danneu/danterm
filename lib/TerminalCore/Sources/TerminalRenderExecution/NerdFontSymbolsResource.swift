// Loads DanTerm's packaged symbols-only Nerd Font without process-global font lookup.
import CoreText
import Foundation

/// Owns one parsed symbols-font descriptor so every projected face shares the
/// resource bytes rather than loading them again for each terminal pane.
///
/// `@unchecked` bridges CoreText's unannotated immutable descriptor into the
/// module's `Sendable` render values. The descriptor and source URL never change
/// after initialization, and CoreText font objects are safe for concurrent reads.
///
/// The type, `packaged`, and `face(pointSize:)` are `public` rather than `package`
/// because `GlyphPreview` compares this face against the system one and now lives
/// in `TerminalHostTools`, a different package. Everything else here stays
/// `package`: a caller outside this module picks a face, it does not load one.
public final class NerdFontSymbolsResource: @unchecked Sendable {
    package static let directoryName = "NerdFontsSymbolsOnly"
    package static let fontName = "SymbolsNerdFontMono-Regular"

    /// The lazily initialized process-wide packaged resource, or nil when the
    /// application resource is absent or unreadable.
    public static let packaged = load(at: packagedURL())

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
    ///
    /// Descriptors come from the file rather than from a `Data` of its contents so
    /// CoreText maps the resource: the bytes stay clean and file-backed instead of
    /// leaving a multi-megabyte dirty buffer alive for the life of `packaged`.
    /// CoreText reports "no usable font here" as either a null array or an empty
    /// one, so both must fall through to the disabled-feature result.
    package static func load(at url: URL?) -> NerdFontSymbolsResource? {
        guard let url,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                  as? [CTFontDescriptor],
              let descriptor = descriptors.first
        else {
            return nil
        }
        return NerdFontSymbolsResource(sourceURL: url, descriptor: descriptor)
    }

    /// Projects the parsed resource to one point size without decoding it again.
    public func face(pointSize: CGFloat) -> CTFont {
        CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
    }
}
