// Pure pane and divider geometry derived from a split tree. AppKit owns how
// these rectangles are presented; frame production and drag clamping live here.
import Foundation
import DanTermProtocol

/// Gives the pure core pane geometry without importing AppKit or CoreGraphics.
struct PaneLayoutRect: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var minX: CGFloat { x }
    var minY: CGFloat { y }
    var maxX: CGFloat { x + width }
    var maxY: CGFloat { y + height }

}

/// Keeps the pane minimum and divider thickness identical for layout and drag inversion.
struct PaneLayoutMetrics: Equatable {
    let minimumPaneExtent: CGFloat
    let dividerThickness: CGFloat

    /// Matches the minimum and thin divider used by the existing split view.
    static let standard = PaneLayoutMetrics(minimumPaneExtent: 100, dividerThickness: 1)
}

/// Describes one divider and its child boxes so gestures need no view-derived geometry.
struct PaneDividerPlacement: Equatable {
    let direction: SplitDirection
    let splitBounds: PaneLayoutRect
    let firstChildBounds: PaneLayoutRect
    let frame: PaneLayoutRect
    let secondChildBounds: PaneLayoutRect
    let ratio: SplitRatio
}

/// Makes one pane's presentation state exhaustive: it has geometry or it is hidden.
enum PanePlacement: Equatable {
    case visible(PaneLayoutRect)
    case hidden

    /// Returns geometry only when the pane participates in visible layout decisions.
    var visibleFrame: PaneLayoutRect? {
        guard case .visible(let frame) = self else { return nil }
        return frame
    }
}

/// Carries the complete pane roster and divider geometry for one tab.
struct PaneLayout: Equatable {
    let placements: [PaneId: PanePlacement]
    let dividers: [SplitId: PaneDividerPlacement]
}

/// Names the pane and axis selected from one arranged tab layout.
struct AutosplitResolution: Equatable {
    let paneId: PaneId
    let direction: SplitDirection
}

/// Chooses the largest pane that can hold two layout minima along its longer axis.
func autosplitResolution(
    in layout: PaneLayout,
    metrics: PaneLayoutMetrics = .standard
) -> AutosplitResolution? {
    let threshold = metrics.minimumPaneExtent * 2 + metrics.dividerThickness
    let candidates = layout.placements.compactMap { paneId, placement -> (PaneId, PaneLayoutRect, SplitDirection)? in
        guard let frame = placement.visibleFrame else { return nil }
        guard frame.width > 0, frame.height > 0 else { return nil }
        let direction: SplitDirection = frame.width >= frame.height ? .horizontal : .vertical
        let extent = direction == .horizontal ? frame.width : frame.height
        guard extent >= threshold else { return nil }
        return (paneId, frame, direction)
    }
    let selected = candidates.sorted { lhs, rhs in
        let lhsArea = lhs.1.width * lhs.1.height
        let rhsArea = rhs.1.width * rhs.1.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        if lhs.1.maxY != rhs.1.maxY { return lhs.1.maxY > rhs.1.maxY }
        if lhs.1.minX != rhs.1.minX { return lhs.1.minX < rhs.1.minX }
        return lhs.0.rawValue.uuidString < rhs.0.rawValue.uuidString
    }.first
    return selected.map { AutosplitResolution(paneId: $0.0, direction: $0.2) }
}

/// Derives every pane and divider rectangle from one model tree and one container rectangle.
func paneLayout(
    in bounds: PaneLayoutRect,
    tree: SplitNodeModel,
    zoomedPaneId: PaneId?,
    metrics: PaneLayoutMetrics = .standard
) -> PaneLayout {
    if let zoomedPaneId, containsPane(tree, zoomedPaneId) {
        var placements: [PaneId: PanePlacement] = [:]
        forEachPane(in: tree) { pane in
            placements[pane.id] = pane.id == zoomedPaneId ? .visible(bounds) : .hidden
        }
        return PaneLayout(
            placements: placements,
            dividers: [:]
        )
    }

    var placements: [PaneId: PanePlacement] = [:]
    var dividers: [SplitId: PaneDividerPlacement] = [:]

    func place(_ node: SplitNodeModel, in nodeBounds: PaneLayoutRect) {
        switch node {
        case .leaf(let pane):
            placements[pane.id] = .visible(nodeBounds)
        case .split(let splitId, let direction, let first, let second, let ratio):
            let geometry = splitGeometry(
                in: nodeBounds,
                direction: direction,
                ratio: ratio,
                metrics: metrics
            )
            dividers[splitId] = PaneDividerPlacement(
                direction: direction,
                splitBounds: nodeBounds,
                firstChildBounds: geometry.first,
                frame: geometry.divider,
                secondChildBounds: geometry.second,
                ratio: geometry.ratio
            )
            place(first, in: geometry.first)
            place(second, in: geometry.second)
        }
    }

    place(tree, in: bounds)
    return PaneLayout(placements: placements, dividers: dividers)
}

/// Converts the model-space divider boundary from a drag into the effective stored ratio.
func paneSplitRatio(
    forDividerPosition position: CGFloat,
    in splitBounds: PaneLayoutRect,
    direction: SplitDirection,
    metrics: PaneLayoutMetrics = .standard
) -> SplitRatio {
    let extent = axisExtent(of: splitBounds, direction: direction)
    let dividerThickness = effectiveDividerThickness(
        requested: metrics.dividerThickness,
        extent: extent
    )
    let usableExtent = max(0, extent - dividerThickness)
    guard usableExtent > 0 else { return 0.5 }

    let proposedFirstExtent: CGFloat
    switch direction {
    case .horizontal:
        proposedFirstExtent = position - splitBounds.minX
    case .vertical:
        proposedFirstExtent = splitBounds.maxY - position
    }
    let firstExtent = clampedFirstExtent(
        proposedFirstExtent,
        usableExtent: usableExtent,
        minimumPaneExtent: metrics.minimumPaneExtent
    )
    return SplitRatio(firstExtent / usableExtent)!
}

/// Holds a split's one-dimensional clamp result before it is expanded into rectangles.
private struct SplitGeometry {
    let first: PaneLayoutRect
    let divider: PaneLayoutRect
    let second: PaneLayoutRect
    let ratio: SplitRatio
}

/// Partitions one box so both layout and drag inversion use the same minimum rule.
private func splitGeometry(
    in bounds: PaneLayoutRect,
    direction: SplitDirection,
    ratio: SplitRatio,
    metrics: PaneLayoutMetrics
) -> SplitGeometry {
    let extent = axisExtent(of: bounds, direction: direction)
    let dividerThickness = effectiveDividerThickness(
        requested: metrics.dividerThickness,
        extent: extent
    )
    let usableExtent = max(0, extent - dividerThickness)
    let proposedFirstExtent = usableExtent * ratio.value
    let firstExtent = clampedFirstExtent(
        proposedFirstExtent,
        usableExtent: usableExtent,
        minimumPaneExtent: metrics.minimumPaneExtent
    )
    let secondExtent = usableExtent - firstExtent

    let first: PaneLayoutRect
    let divider: PaneLayoutRect
    let second: PaneLayoutRect
    switch direction {
    case .horizontal:
        first = PaneLayoutRect(
            x: bounds.minX,
            y: bounds.minY,
            width: firstExtent,
            height: bounds.height
        )
        divider = PaneLayoutRect(
            x: first.maxX,
            y: bounds.minY,
            width: dividerThickness,
            height: bounds.height
        )
        second = PaneLayoutRect(
            x: divider.maxX,
            y: bounds.minY,
            width: secondExtent,
            height: bounds.height
        )
    case .vertical:
        second = PaneLayoutRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: secondExtent
        )
        divider = PaneLayoutRect(
            x: bounds.minX,
            y: second.maxY,
            width: bounds.width,
            height: dividerThickness
        )
        first = PaneLayoutRect(
            x: bounds.minX,
            y: divider.maxY,
            width: bounds.width,
            height: firstExtent
        )
    }

    let effectiveRatio: SplitRatio = usableExtent > 0
        ? SplitRatio(firstExtent / usableExtent)!
        : 0.5
    return SplitGeometry(first: first, divider: divider, second: second, ratio: effectiveRatio)
}

/// Returns the length a split consumes on its direction's axis.
private func axisExtent(of bounds: PaneLayoutRect, direction: SplitDirection) -> CGFloat {
    switch direction {
    case .horizontal:
        max(0, bounds.width)
    case .vertical:
        max(0, bounds.height)
    }
}

/// Makes the separator yield before it can consume a positive split box by itself.
private func effectiveDividerThickness(requested: CGFloat, extent: CGFloat) -> CGFloat {
    guard extent > 0 else { return 0 }
    let finiteRequested = requested.isFinite ? max(0, requested) : 0
    return min(finiteRequested, extent / 3)
}

/// Applies point rounding and the shared symmetric minimum without favoring either child.
private func clampedFirstExtent(
    _ proposed: CGFloat,
    usableExtent: CGFloat,
    minimumPaneExtent: CGFloat
) -> CGFloat {
    guard usableExtent > 0 else { return 0 }
    let finiteMinimum = minimumPaneExtent.isFinite ? max(0, minimumPaneExtent) : 0
    let effectiveMinimum = min(finiteMinimum, usableExtent / 2)
    let finiteProposed = proposed.isFinite ? proposed : usableExtent / 2
    let roundedProposed = finiteProposed.rounded(.toNearestOrAwayFromZero)
    return min(max(roundedProposed, effectiveMinimum), usableExtent - effectiveMinimum)
}
