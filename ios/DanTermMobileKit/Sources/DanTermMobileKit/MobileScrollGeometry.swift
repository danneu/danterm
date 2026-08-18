// The phone's scroll arithmetic, as pure values.
//
// The engine is the only scroll authority, so everything here is a projection of
// `TerminalScrollProjection` or a reading of a scroll view's offset back into it. The
// space is top-origin -- row zero is the oldest retained row and sits at offset zero --
// because that is the space UIScrollView works in, and because it makes the offset of a
// row independent of how much output has arrived since.
//
// What does not belong here: the interaction latch, per-row dedupe, and the recentering
// policy, which are driver state rather than arithmetic (`MobileScrollDriver`); and where
// a scroll event goes, which the session model decides from replicated state.
import CoreGraphics
import TerminalCore

/// The top-origin scroll geometry one engine projection implies, in points.
///
/// The viewport is the drawn grid's own height rather than the terminal view's. The
/// fitted grid is bottom-pinned and can be shorter than the view it is drawn in, and an
/// oversized viewport would put a scroll view's maximum offset short of the engine's
/// maximum top row -- the indicator could then never reach the bottom, and idle
/// reflection could never converge.
public struct MobileScrollGeometry: Equatable, Sendable {
    public let projection: TerminalScrollProjection

    /// The point height of one drawn row, which is the whole conversion between the two
    /// spaces this type relates.
    public let rowHeight: CGFloat

    /// Returns nil when a row has no usable height or the window holds no row, which is
    /// the one state with no geometry to describe.
    public init?(projection: TerminalScrollProjection, rowHeight: CGFloat) {
        guard rowHeight.isFinite, rowHeight > 0, projection.windowRows > 0 else { return nil }
        self.projection = projection
        self.rowHeight = rowHeight
    }

    /// The whole stream's height: what a scroll view's content must be for the indicator
    /// to be proportional to the scrollback.
    public var contentHeight: CGFloat { CGFloat(projection.totalRows) * rowHeight }

    /// The drawn grid's height, which is the scroll view's own viewport.
    public var viewportHeight: CGFloat { CGFloat(projection.windowRows) * rowHeight }

    /// The last row the engine can put at the top of a complete window.
    public var maximumTopRow: Int { max(0, projection.totalRows - projection.windowRows) }

    /// The offset that shows the engine's current window. Following puts it at the
    /// maximum, which is exactly `contentHeight - viewportHeight`.
    public var contentOffset: CGFloat { CGFloat(projection.topRow) * rowHeight }

    /// True when the whole stream already fits the window, so there is nothing to browse
    /// and an indicator would be a lie.
    public var isDegenerate: Bool { maximumTopRow == 0 }

    /// The row the engine should put at the top for one scroll-view offset, clamped to a
    /// complete window so a rubber-band bounce past either end names an end row rather
    /// than an impossible one.
    public func topRow(forOffset offset: CGFloat) -> Int {
        guard offset.isFinite else { return projection.topRow }
        let row = (offset / rowHeight).rounded()
        if row.isNaN || row <= 0 { return 0 }
        if row >= CGFloat(maximumTopRow) { return maximumTopRow }
        return Int(row)
    }
}

/// Names a scroll mode without its geometry, so a driver can tell a screen-mode flip from
/// a projection that merely moved.
public enum MobileScrollModeKind: Equatable, Sendable {
    case projected
    case delta
    case inert
}

/// How motion on the terminal becomes scroll, chosen from replicated state alone.
public enum MobileScrollMode: Equatable, Sendable {
    /// A primary screen with history behind it: the scroll view mirrors the projection,
    /// and a gesture names an absolute top row.
    case projected(MobileScrollGeometry)
    /// The alternate screen: there is no scrollback to project, so motion accumulates
    /// into whole rows the owner applies as wheel events.
    case delta(rowHeight: CGFloat)
    /// Nothing to scroll: a primary screen whose whole stream already fits the window, no
    /// replica to read, or a surface with no drawn row height.
    case inert

    /// Chooses the mode one set of replicated scroll facts implies. The alternate-screen
    /// bit is passed separately from the projection because the engine reports a
    /// degenerate projection there, which is indistinguishable from a short primary
    /// screen.
    public static func select(
        projection: TerminalScrollProjection?,
        rowHeight: CGFloat,
        isAlternateScreenActive: Bool
    ) -> MobileScrollMode {
        guard rowHeight.isFinite, rowHeight > 0 else { return .inert }
        if isAlternateScreenActive { return .delta(rowHeight: rowHeight) }
        guard let projection,
              let geometry = MobileScrollGeometry(projection: projection, rowHeight: rowHeight),
              geometry.isDegenerate == false
        else { return .inert }
        return .projected(geometry)
    }

    public var kind: MobileScrollModeKind {
        switch self {
        case .projected: .projected
        case .delta: .delta
        case .inert: .inert
        }
    }

    /// Whether a system scroll indicator would tell the truth right now: only projected
    /// mode has a real extent and a real position inside it.
    public var showsIndicator: Bool { kind == .projected }
}

/// Turns a scroll view's offset motion into whole rows without losing fractions.
///
/// The baseline carries the remainder: only whole rows move it, so motion smaller than a
/// row is never discarded and never counted twice. A recenter shifts the baseline by the
/// same amount the offset shifted, which is what makes it emit nothing while keeping the
/// pending fraction.
public struct MobileScrollDelta: Equatable, Sendable {
    private var baseline: CGFloat

    public init(baseline: CGFloat = 0) {
        self.baseline = baseline
    }

    /// The whole rows this offset has travelled since the last whole row. Negative moves
    /// toward history, matching `Terminal.scroll(byRows:)`, so a finger moving down --
    /// which lowers the offset -- moves back through output on either screen.
    public mutating func rows(atOffset offset: CGFloat, rowHeight: CGFloat) -> Int {
        guard offset.isFinite, rowHeight.isFinite, rowHeight > 0 else { return 0 }
        let travelled = ((offset - baseline) / rowHeight).rounded(.towardZero)
        guard travelled.isFinite, travelled.magnitude < CGFloat(Int.max) else { return 0 }
        let whole = Int(travelled)
        baseline += CGFloat(whole) * rowHeight
        return whole
    }

    /// Follows an offset the shell moved for its own bookkeeping. The baseline moves by
    /// the same distance, so the motion is invisible to the row count and the fraction
    /// still pending survives it.
    public mutating func recenter(from oldOffset: CGFloat, to newOffset: CGFloat) {
        guard oldOffset.isFinite, newOffset.isFinite else { return }
        baseline += newOffset - oldOffset
    }
}
