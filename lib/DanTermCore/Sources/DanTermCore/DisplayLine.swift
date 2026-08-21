// The type every string that a view lays out on one line is declared as, and
// the single normalizer behind it. Nothing here knows about a particular
// surface: the projections decide what is display text, and this file decides
// what a display line may contain.
import Foundation

/// A string that cannot hold more than one line.
///
/// Terminal-reported text -- a title from OSC 0/2, a cwd, a remote identity --
/// is stored in the model exactly as reported, because it is functional data
/// that IPC targets panes by and checkpoints must reproduce. That leaves the
/// projection layer as the one boundary where the single-line invariant can
/// live, so every render-ready field is declared `DisplayLine` and the only way
/// to make one runs the normalizer.
///
/// Deliberately not `ExpressibleByStringInterpolation`: that conformance would
/// make `let title: DisplayLine = "\(rawTitle)"` compile, which launders an
/// arbitrary string through the type and defeats it. Compose on `String` and
/// wrap the result.
///
/// Deliberately not `Codable`: nothing `DisplayLine`-typed is persisted or wire
/// encoded, and the conformance would invite normalizing the values that must
/// stay verbatim.
struct DisplayLine: Equatable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    /// The normalized text. Read it out at the AppKit boundary -- `label.stringValue
    /// = line.text` -- so every readout site is greppable.
    let text: String

    init(_ raw: String) {
        text = Self.normalize(raw)
    }

    init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    var description: String { text }

    /// Collapses whitespace first and strips controls second, in that order: a
    /// newline is both, and stripping first would glue "a\nb" into "ab" instead
    /// of "a b". The final collapse re-trims, because removing a control can
    /// leave a space at an edge that was interior before.
    private static func normalize(_ raw: String) -> String {
        if isAlreadyNormalized(raw) { return raw }

        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var kept = String.UnicodeScalarView()
        for scalar in collapsed.unicodeScalars where !isRemoved(scalar) {
            kept.append(scalar)
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Identifies the common path where normalization can preserve the input
    /// storage instead of building equivalent text through three new buffers.
    private static func isAlreadyNormalized(_ raw: String) -> Bool {
        var sawNonWhitespace = false
        var previousWasWhitespace = false

        for character in raw {
            if character.isWhitespace {
                if character != " " || !sawNonWhitespace || previousWasWhitespace {
                    return false
                }
                previousWasWhitespace = true
            } else {
                sawNonWhitespace = true
                previousWasWhitespace = false
            }

            if character.unicodeScalars.contains(where: isRemoved) {
                return false
            }
        }

        return !previousWasWhitespace
    }

    /// C0 and C1 controls, which no label should ever be asked to draw, plus the
    /// bidi overrides and isolates, which reorder the text around them and can
    /// disguise one string as another. General category `Format` is otherwise
    /// left alone so ZWJ keeps an emoji sequence a single glyph.
    private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        return (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }
}
