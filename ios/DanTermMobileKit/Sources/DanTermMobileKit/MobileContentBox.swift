// The one pixel box the phone's terminal claims and draws inside.
//
// The surface paints to the physical edges of its view, but the cells may only occupy
// the part of it the system leaves usable. Reading that region twice -- once to decide
// what grid to claim and once to decide what pixels to draw -- is how the two answers
// drift apart, so both readings, and the position of the layer that shows the result,
// come from one value of this type.
import CoreGraphics

/// The usable region of one phone terminal view, quantized to whole backing pixels.
///
/// Edges round inward: the origin rounds up and the far edge rounds down, so every
/// pixel the box describes is outside the insets it was given whatever fractions the
/// extent, the insets, and the display scale carry.
public struct MobileContentBox: Equatable, Sendable {
    /// The point-to-backing-pixel scale the box was quantized at, and the scale the
    /// cells inside it are drawn at.
    public let displayScale: CGFloat

    /// The box's near edges, in backing pixels from the view's own origin.
    public let originXPixels: Int
    public let originYPixels: Int

    /// The pixels available for cells.
    public let widthPixels: Int
    public let heightPixels: Int

    /// Returns nil when the scale is unusable or the insets leave no whole pixel to
    /// draw in, which is the one state with no box to describe.
    public init?(
        width: CGFloat,
        height: CGFloat,
        insetTop: CGFloat,
        insetLeading: CGFloat,
        insetTrailing: CGFloat,
        insetBottom: CGFloat,
        displayScale: CGFloat
    ) {
        guard displayScale.isFinite, displayScale > 0,
              width.isFinite, height.isFinite,
              insetTop.isFinite, insetLeading.isFinite,
              insetTrailing.isFinite, insetBottom.isFinite
        else { return nil }
        let left = (max(0, insetLeading) * displayScale).rounded(.up)
        let right = ((width - max(0, insetTrailing)) * displayScale).rounded(.down)
        let top = (max(0, insetTop) * displayScale).rounded(.up)
        let bottom = ((height - max(0, insetBottom)) * displayScale).rounded(.down)
        guard left.isFinite, right.isFinite, top.isFinite, bottom.isFinite,
              right > left, bottom > top,
              right < CGFloat(Int.max), bottom < CGFloat(Int.max)
        else { return nil }
        self.displayScale = displayScale
        originXPixels = Int(left)
        originYPixels = Int(top)
        widthPixels = Int(right) - Int(left)
        heightPixels = Int(bottom) - Int(top)
    }

    /// The box's leading edge in point space, for positioning the layer that shows the
    /// drawn pixels.
    public var originX: CGFloat { CGFloat(originXPixels) / displayScale }

    /// The box's bottom edge in point space. The replica draws from the bottom, so this
    /// is the edge the drawn pixels are pinned to.
    public var maxY: CGFloat { CGFloat(originYPixels + heightPixels) / displayScale }
}
