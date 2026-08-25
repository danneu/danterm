// Where each pane's floating arrow pad sits, and whether it is showing.
//
// The pad is chrome the user parks away from a particular pane's TUI content, so what it
// remembers is a fact about that pane and not about the screen it happened to be parked
// on. This file owns that memory and the pure arithmetic that turns it back into a place
// inside whatever region the phone currently has.
//
// What does not belong here: the drag in progress, which is UIKit's alone until the
// finger lifts, and anything about how the pad is drawn.
import CoreGraphics
import DanTermProtocol

/// One pad's remembered place, as its share of the free space the region leaves around it.
///
/// Fractions rather than points, because the region changes under the pad constantly --
/// rotation, a keyboard rising, a bar appearing -- and a point that was inside one region
/// is outside the next. A fraction resolves to a legal place in every region, so a
/// re-layout is a re-resolve and never a write back into what the user chose.
public struct MobileArrowPadPosition: Equatable, Sendable {
    /// The share of the free width between the region's leading edge and the pad's.
    public let leadingFraction: Double
    /// The share of the free height between the region's top edge and the pad's.
    public let topFraction: Double

    /// Clamps both fractions into the unit range. A value that is not a finite number is
    /// not a place at all, so it falls back to the default corner's fraction on that axis
    /// rather than storing a NaN that would poison every later resolve.
    public init(leadingFraction: Double, topFraction: Double) {
        self.leadingFraction = Self.unit(leadingFraction, fallback: 1)
        self.topFraction = Self.unit(topFraction, fallback: 1)
    }

    /// Answers where this pad would sit after a drag ended at these insets.
    ///
    /// An axis with no free space keeps its stored fraction: the region is too small for
    /// the drag to have expressed a preference on it, and overwriting the user's choice
    /// with the only place that fits would lose it the moment the keyboard came up.
    public func moved(
        toLeadingInset leadingInset: CGFloat,
        topInset: CGFloat,
        padSize: CGSize,
        regionSize: CGSize
    ) -> MobileArrowPadPosition {
        MobileArrowPadPosition(
            leadingFraction: Self.fraction(
                of: leadingInset,
                inFreeSpace: MobileArrowPadPlacement.freeSpace(regionSize.width, padSize.width),
                keeping: leadingFraction
            ),
            topFraction: Self.fraction(
                of: topInset,
                inFreeSpace: MobileArrowPadPlacement.freeSpace(regionSize.height, padSize.height),
                keeping: topFraction
            )
        )
    }

    private static func fraction(
        of inset: CGFloat,
        inFreeSpace free: CGFloat,
        keeping stored: Double
    ) -> Double {
        guard free > 0, inset.isFinite else { return stored }
        return Double(inset / free)
    }

    private static func unit(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }
}

/// The four places the pad can be sent to without a drag.
///
/// They name the default and give assistive technology a way to move the pad that does
/// not require the touch gesture.
public enum MobileArrowPadCorner: CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    /// The stored position this corner means.
    public var position: MobileArrowPadPosition {
        switch self {
        case .topLeading: MobileArrowPadPosition(leadingFraction: 0, topFraction: 0)
        case .topTrailing: MobileArrowPadPosition(leadingFraction: 1, topFraction: 0)
        case .bottomLeading: MobileArrowPadPosition(leadingFraction: 0, topFraction: 1)
        case .bottomTrailing: MobileArrowPadPosition(leadingFraction: 1, topFraction: 1)
        }
    }
}

/// Turns a remembered position into the two insets that place the pad in a given region.
///
/// Insets from the leading and top edges rather than a rectangle, so the layout that
/// consumes them stays a leading/top constraint pair and mirrors itself for a
/// right-to-left interface without this type knowing about interface direction.
public struct MobileArrowPadPlacement: Equatable, Sendable {
    /// Distance from the region's leading edge to the pad's leading edge.
    public let leadingInset: CGFloat
    /// Distance from the region's top edge to the pad's top edge.
    public let topInset: CGFloat

    /// Resolves the position against this region. A region with no room on an axis pins
    /// the pad to that edge, which is the clamp that keeps the pad reachable while the
    /// keyboard is up.
    public init(position: MobileArrowPadPosition, padSize: CGSize, regionSize: CGSize) {
        leadingInset = Self.freeSpace(regionSize.width, padSize.width)
            * CGFloat(position.leadingFraction)
        topInset = Self.freeSpace(regionSize.height, padSize.height)
            * CGFloat(position.topFraction)
    }

    /// The room the region leaves the pad to move in on one axis, never negative and
    /// never a value arithmetic on a mid-layout frame could make meaningless.
    static func freeSpace(_ region: CGFloat, _ pad: CGFloat) -> CGFloat {
        let free = region - pad
        guard free.isFinite, free > 0 else { return 0 }
        return free
    }
}

/// Remembers each pane's pad independently, so parking the pad is a decision about the
/// pane the user made it for.
///
/// Entries are never pruned. A `PaneId` is a UUID and is never reused, only the selected
/// pane's entry is ever read, and an entry is two numbers and a flag -- so an entry for a
/// pane that is gone is unobservable, and pruning would only add a rule about rosters and
/// reconnects that nothing observable depends on.
public struct MobileArrowPadState: Equatable, Sendable {
    private var pads: [PaneId: Pad] = [:]

    private struct Pad: Equatable, Sendable {
        var isVisible = false
        var position = MobileArrowPadCorner.bottomTrailing.position
    }

    /// Creates the state every pane starts from: hidden, at the bottom-trailing corner.
    public init() {}

    /// Whether this pane is showing its pad. A pane with no entry has never opened one.
    public func isVisible(_ pane: PaneId) -> Bool {
        pads[pane]?.isVisible ?? false
    }

    /// Where this pane keeps its pad, defaulting to the bottom-trailing corner.
    public func position(_ pane: PaneId) -> MobileArrowPadPosition {
        pads[pane]?.position ?? Pad().position
    }

    /// Shows or hides this pane's pad, leaving every other pane as it was.
    public mutating func toggle(_ pane: PaneId) {
        pads[pane, default: Pad()].isVisible.toggle()
    }

    /// Hides this pane's pad. A pane that never opened one gets no entry -- optional
    /// chaining writes nothing through a missing key -- because every terminal tap
    /// arrives here and the map is never pruned, so a tap must not be able to grow it.
    public mutating func hide(_ pane: PaneId) {
        pads[pane]?.isVisible = false
    }

    /// Commits a new place for this pane. The caller names the pane the drag began on, so
    /// a selection change while the finger was down cannot move the wrong pane's pad.
    public mutating func move(_ pane: PaneId, to position: MobileArrowPadPosition) {
        pads[pane, default: Pad()].position = position
    }
}
