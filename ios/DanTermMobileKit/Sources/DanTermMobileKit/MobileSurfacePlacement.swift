// Where the drawn cells sit inside the view at this moment.
//
// The content box is keyboard-absent by construction, so the keyboard reaches no grid,
// no claim request, and no frame-store allocation. What the keyboard may change is only
// where the drawn rectangle sits: this value adds that one fact -- how far the bottom
// bar has risen above its rest position -- as a presentation offset. Everything that
// must line up with the cells (the drawn layer's position, the scroll chrome's frame,
// gesture-to-cell mapping) reads this value, so none of them can disagree about where a
// row is while the keyboard is up.
import CoreGraphics

/// One content box's drawn position, lifted by the keyboard's obscured height, clamped
/// at zero and quantized to whole backing pixels.
public struct MobileSurfacePlacement: Equatable, Sendable {
    public let contentBox: MobileContentBox

    /// How far the visible bottom edge sits above the box's own, in backing pixels.
    public let obscuredPixels: Int

    /// The measurement is taken in the view's points and may be negative (a bar below
    /// its rest position) or garbage (a mid-layout frame); anything but a positive
    /// finite rise obscures nothing.
    public init(contentBox: MobileContentBox, obscuredHeight: CGFloat) {
        self.contentBox = contentBox
        let pixels = (obscuredHeight * contentBox.displayScale).rounded()
        obscuredPixels = pixels.isFinite && pixels > 0 && pixels < CGFloat(Int.max)
            ? Int(pixels)
            : 0
    }

    /// The drawn content's leading edge in point space.
    public var originX: CGFloat { contentBox.originX }

    /// The visible bottom edge in point space: the box's bottom lifted by the obscured
    /// height. The drawn content is pinned here, so its bottom row meets the bar's top
    /// at whole-pixel alignment.
    public var maxY: CGFloat {
        CGFloat(contentBox.originYPixels + contentBox.heightPixels - obscuredPixels)
            / contentBox.displayScale
    }
}
