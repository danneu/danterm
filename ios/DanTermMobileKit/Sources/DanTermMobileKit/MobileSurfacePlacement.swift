// Where the drawn cells sit inside the view at this moment.
//
// The content box is keyboard-absent by construction, so the keyboard reaches no grid,
// no claim request, and no frame-store allocation. What the keyboard may change is only
// where the drawn rectangle sits: this value adds that one fact -- how far the drawn
// content has risen above its rest position -- as a presentation offset. Everything that
// must line up with the cells (the drawn layer's position, the scroll chrome's frame,
// gesture-to-cell mapping) reads this value, so none of them can disagree about where a
// row is while the keyboard is up.
import CoreGraphics

/// One content box's drawn position, lifted by the keyboard only as far as its cursor
/// anchor needs, clamped between zero and the obscured height and quantized to whole
/// backing pixels.
public struct MobileSurfacePlacement: Equatable, Sendable {
    public let contentBox: MobileContentBox

    /// How far the drawn bottom edge sits above the box's own, in backing pixels: the
    /// obscured height less the anchor's slack, clamped so the content never moves down
    /// and never rises past the bar's top.
    public let liftPixels: Int

    /// The obscured measurement is taken in the view's points and may be negative (a bar
    /// below its rest position) or garbage (a mid-layout frame); anything but a positive
    /// finite rise obscures nothing. The anchor slack is the drawn content below the
    /// cursor row's bottom edge, in backing pixels; nil means no anchor is trustworthy
    /// and the lift is the full obscured height, which keeps the cursorless behavior of
    /// pinning the drawn bottom at the bar's top.
    public init(contentBox: MobileContentBox, obscuredHeight: CGFloat, anchorSlackPixels: Int? = nil) {
        self.contentBox = contentBox
        let pixels = (obscuredHeight * contentBox.displayScale).rounded()
        let obscuredPixels = pixels.isFinite && pixels > 0 && pixels < CGFloat(Int.max)
            ? Int(pixels)
            : 0
        if let slack = anchorSlackPixels {
            liftPixels = min(max(obscuredPixels - max(slack, 0), 0), obscuredPixels)
        } else {
            liftPixels = obscuredPixels
        }
    }

    /// The drawn content's leading edge in point space.
    public var originX: CGFloat { contentBox.originX }

    /// The drawn bottom edge in point space: the box's bottom lifted by the anchored
    /// lift. The drawn content is pinned here at whole-pixel alignment, so at the full
    /// lift its bottom row meets the bar's top, and at a partial lift the anchored
    /// cursor row's bottom edge does.
    public var maxY: CGFloat {
        CGFloat(contentBox.originYPixels + contentBox.heightPixels - liftPixels)
            / contentBox.displayScale
    }
}
