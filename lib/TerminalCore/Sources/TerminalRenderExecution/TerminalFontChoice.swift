// The font a surface asks the render layer for. It is the whole rebuild input a
// caller has to keep; how that request resolves to a concrete face belongs to
// `TerminalRenderMetrics` and stays there.
import CoreGraphics

/// The requested font one surface renders with: a family the caller has already
/// verified is installed, or the system monospace face, at one point size.
///
/// It exists so an embedder holds one value instead of two loose fields. Metrics are
/// derived per surface and must be rebuilt whenever the display scale moves, so every
/// embedder needs the font inputs again after the value it built is stale -- and two
/// separately stored inputs drift. `TerminalRenderMetrics` publishes the choice it was
/// built from, which makes "the same font at a new scale" expressible without the
/// caller storing anything of its own.
///
/// This is the *request*, not the resolution: an absent family means the system
/// monospace face, and which concrete face that is stays inside the metrics.
public struct TerminalFontChoice: Equatable, Sendable {
    /// The family to render, or nil for the system monospace face. Never a raw name
    /// from user config -- the metrics layer takes the name on trust, so only a name
    /// the caller has verified is installed belongs here.
    public let family: String?

    /// The point size the face is measured and drawn at.
    public let size: CGFloat

    public init(family: String? = nil, size: CGFloat = 13) {
        self.family = family
        self.size = size
    }

    /// What a caller that states no font at all gets: the system monospace face at the
    /// render layer's own default size.
    public static let systemMonospace = TerminalFontChoice()
}
