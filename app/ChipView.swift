// The AppKit host for a pane-kind chip, and the one place a ChipKind is turned
// into artwork.
//
// The mapping lives here rather than in ChipRenderer.swift because that file is
// compiled standalone by icon/render-check.sh against ChipArtwork.swift alone;
// referring to a DanTermCore type there would break the check. It does not live
// in DanTermCore either, which stays free of CoreGraphics.

import AppKit

extension ChipKind {
    /// The artwork this kind is drawn with.
    var artwork: ChipDefinition {
        switch self {
        case .terminal: return ChipArtwork.terminal
        case .claude: return ChipArtwork.claude
        case .codex: return ChipArtwork.codex
        case .agent: return ChipArtwork.agent
        }
    }

    /// The chip as an image, for the places AppKit wants an `NSImage` instead of
    /// a view -- a menu item, a table column, an alert.
    ///
    /// Not a template image: a chip is its own colors, and a template would flatten
    /// the whole thing to one tint. The drawing block reads the appearance in force
    /// when it runs rather than when it was built, so one image is correct in both
    /// light and dark.
    func image(edge: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let isDark = NSAppearance.currentDrawing()
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ChipRenderer.draw(
                self.artwork, in: context, rect: rect,
                appearance: isDark ? .dark : .light, flipped: false)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A fixed-size square that draws one chip. Used by both the sidebar rows and
/// the pane toolbar, so the two cannot drift apart.
///
/// Owns no state beyond the kind and its edge length: it reads the appearance
/// from the view hierarchy at draw time and repaints itself when that changes,
/// so no caller has to push a theme in.
final class ChipView: NSView {
    var kind: ChipKind {
        didSet {
            guard kind != oldValue else { return }
            needsDisplay = true
        }
    }

    private let edge: CGFloat

    init(kind: ChipKind, edge: CGFloat) {
        self.kind = kind
        self.edge = edge
        super.init(frame: NSRect(x: 0, y: 0, width: edge, height: edge))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: edge),
            heightAnchor.constraint(equalToConstant: edge),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: edge, height: edge) }

    // NSView: AppKit calls this when the light/dark appearance changes, which is
    // why the chip needs no observer or notification token to stay in step.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ChipRenderer.draw(
            kind.artwork,
            in: context,
            rect: NSRect(x: 0, y: 0, width: edge, height: edge),
            appearance: isDark ? .dark : .light,
            flipped: isFlipped
        )
    }
}
