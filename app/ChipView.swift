// The AppKit host for a pane-kind chip: the view the sidebar and the pane
// toolbar show, and the NSImage wrapper for the places AppKit wants one.
//
// The kind-to-artwork mapping and the drawing itself belong to the ChipArtwork
// package, which the phone links too. Only what AppKit needs lives here.

import AppKit
import ChipArtwork
import DanTermProtocol

extension ChipKind {
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

/// Where a chip takes its colors from.
///
/// `.brand` is a chip standing for one pane: it wears the agent's own colors.
/// `.paneStrip` is a chip standing for one pane *among the tab's others*, where
/// telling the active one apart matters more than telling Claude from Codex, so
/// the whole strip shares a palette and only the active chip is lifted out.
enum ChipStyle: Equatable {
    case brand
    case paneStrip(isActive: Bool)

    /// The colors to paint with, for a chip of `kind` at this appearance.
    func palette(for kind: ChipKind, appearance: ChipAppearance) -> ChipPalette {
        switch self {
        case .brand:
            let artwork = kind.artwork
            return appearance == .light ? artwork.light : artwork.dark
        case .paneStrip(let isActive):
            let strip = appearance == .light
                ? ChipArtwork.paneListLight
                : ChipArtwork.paneListDark
            return isActive ? strip.active : strip.inactive
        }
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

    /// Which palette this chip paints from. Defaults to the kind's own colors;
    /// a tab row's pane strip overrides it so the strip is monochrome apart
    /// from the pane the tab is focused on.
    var style: ChipStyle = .brand {
        didSet {
            guard style != oldValue else { return }
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
        let appearance: ChipAppearance = isDark ? .dark : .light
        ChipRenderer.draw(
            kind.artwork,
            in: context,
            rect: NSRect(x: 0, y: 0, width: edge, height: edge),
            palette: style.palette(for: kind, appearance: appearance),
            flipped: isFlipped
        )
    }
}
