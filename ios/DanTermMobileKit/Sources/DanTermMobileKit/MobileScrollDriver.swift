// The state a scroll view needs to be chrome over an engine that owns the scroll.
//
// Two things have to be kept apart and this type is where they meet: the engine's
// projection, which moves whenever output arrives or a remote viewport record replays,
// and the user's finger, which moves the scroll view. Reflection is one-directional and
// latched -- nothing programmatic moves the scroll view while the user is interacting,
// and on the way back to idle exactly one reflection reconciles the chrome with the
// engine. Every rule here is decided on plain values, so it is testable with no view.
//
// What does not belong here: UIKit itself (the shell translates callbacks into these
// three inputs and performs the actions), and the routing of a scroll to the replica or
// to the owner, which the session model decides.
import CoreGraphics
import TerminalCore

/// Which of a scroll view's interactions are in progress.
///
/// The three are kept apart rather than collapsed into one flag because they are three
/// distinct ways for the latch to be held, and a shell reports them from three different
/// callbacks.
public struct MobileScrollInteraction: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let tracking = MobileScrollInteraction(rawValue: 1 << 0)
    public static let dragging = MobileScrollInteraction(rawValue: 1 << 1)
    public static let decelerating = MobileScrollInteraction(rawValue: 1 << 2)

    /// Whether the latch is held, which is the only question the driver asks.
    public var isActive: Bool { isEmpty == false }
}

/// One thing the shell must do after giving the driver an input.
public enum MobileScrollDriverAction: Equatable, Sendable {
    /// Make the scroll view describe the engine: this content height, this offset, and
    /// this indicator. Produced only while the latch is open.
    case reflect(contentHeight: CGFloat, offset: CGFloat, showsIndicator: Bool)
    /// Ask the session to put this absolute row at the top of the window.
    case scrollToTopRow(Int)
    /// Ask the session to move the window by whole rows; negative moves toward history.
    case scrollByRows(Int)
    /// Move the scroll view's offset without treating the move as gesture motion. This is
    /// delta mode's bookkeeping, so it is exempt from the latch and may land mid-gesture.
    case recenter(offset: CGFloat)
}

/// Holds the scroll chrome's whole decision: which mode a gesture is routed under, whether
/// the latch is held, which row was last named, and where delta mode's baseline sits.
public struct MobileScrollDriver: Equatable, Sendable {
    /// Delta mode has no extent to project, so it gives the scroll view a large content
    /// height and parks the offset in the middle of it. The user can then flick in either
    /// direction for as long as they like, and the driver recenters before an end is
    /// reachable.
    private static let deltaContentHeight: CGFloat = 100_000
    private static let deltaCenter: CGFloat = deltaContentHeight / 2
    private static let deltaRecenterDistance: CGFloat = deltaContentHeight / 5

    public private(set) var mode = MobileScrollMode.inert

    private var interaction: MobileScrollInteraction = []
    private var delta = MobileScrollDelta()

    /// The row this driver last named, so an offset stream that stays inside one row emits
    /// one fact rather than one per callback.
    private var lastNamedTopRow: Int?

    /// Whether the replica left the screen mode this gesture was routed under. The rest of
    /// the gesture then produces nothing: re-routing residual flick momentum would inject
    /// it into an application that only just appeared.
    private var gestureModeIsStale = false

    public init() {}

    /// Takes the replica's current scroll facts. While the latch is held this only
    /// re-routes future gestures; when it is open it reflects the new truth into the
    /// chrome, which is the whole answer to a remote viewport record moving the window.
    public mutating func replicaChanged(
        projection: TerminalScrollProjection?,
        rowHeight: CGFloat,
        isAlternateScreenActive: Bool
    ) -> [MobileScrollDriverAction] {
        let next = MobileScrollMode.select(
            projection: projection,
            rowHeight: rowHeight,
            isAlternateScreenActive: isAlternateScreenActive
        )
        let flipped = next.kind != mode.kind
        mode = next
        if flipped, interaction.isActive { gestureModeIsStale = true }
        guard interaction.isActive == false else { return [] }
        return [reflection()]
    }

    /// Takes the scroll view's interaction state. Only the return to idle produces
    /// anything, and it produces exactly one reflection.
    public mutating func interactionChanged(
        _ interaction: MobileScrollInteraction
    ) -> [MobileScrollDriverAction] {
        let wasActive = self.interaction.isActive
        self.interaction = interaction
        guard wasActive != interaction.isActive else { return [] }
        gestureModeIsStale = false
        guard interaction.isActive == false else { return [] }
        return [reflection()]
    }

    /// Takes one scroll-view offset. An offset the driver did not ask the user for -- the
    /// echo of its own reflection -- carries no gesture, so the latch decides whether this
    /// is motion at all.
    public mutating func offsetChanged(_ offset: CGFloat) -> [MobileScrollDriverAction] {
        guard interaction.isActive, gestureModeIsStale == false, offset.isFinite else {
            return []
        }
        switch mode {
        case .projected(let geometry):
            let row = geometry.topRow(forOffset: offset)
            guard row != lastNamedTopRow else { return [] }
            lastNamedTopRow = row
            return [.scrollToTopRow(row)]

        case .delta(let rowHeight):
            let rows = delta.rows(atOffset: offset, rowHeight: rowHeight)
            var actions: [MobileScrollDriverAction] = rows == 0 ? [] : [.scrollByRows(rows)]
            guard (offset - Self.deltaCenter).magnitude > Self.deltaRecenterDistance else {
                return actions
            }
            delta.recenter(from: offset, to: Self.deltaCenter)
            actions.append(.recenter(offset: Self.deltaCenter))
            return actions

        case .inert:
            return []
        }
    }

    /// Describes the chrome the current mode calls for, and re-seeds the state that is
    /// only meaningful against it: the row the engine is showing, and delta mode's
    /// baseline at the offset this reflection parks at.
    private mutating func reflection() -> MobileScrollDriverAction {
        // Whether the indicator tells the truth is the mode's own rule, asked here rather
        // than restated per case, so I6 has one statement.
        let showsIndicator = mode.showsIndicator
        switch mode {
        case .projected(let geometry):
            lastNamedTopRow = geometry.projection.topRow
            return .reflect(
                contentHeight: geometry.contentHeight,
                offset: geometry.contentOffset,
                showsIndicator: showsIndicator
            )
        case .delta:
            lastNamedTopRow = nil
            delta = MobileScrollDelta(baseline: Self.deltaCenter)
            return .reflect(
                contentHeight: Self.deltaContentHeight,
                offset: Self.deltaCenter,
                showsIndicator: showsIndicator
            )
        case .inert:
            lastNamedTopRow = nil
            delta = MobileScrollDelta()
            return .reflect(contentHeight: 0, offset: 0, showsIndicator: showsIndicator)
        }
    }
}
