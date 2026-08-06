// Deterministic pointer ownership, local selection, wheel routing, and point normalization.

/// Identifies a valid zero-based cell in the displayed terminal viewport, together with the
/// sub-cell horizontal position that flooring to a column would otherwise destroy. Character
/// selection resolves a boundary from it; every other arm reads only the column and row.
public struct TerminalViewportCell: Equatable, Sendable {
    /// Horizontal grid coordinate.
    public let column: Int
    /// Vertical grid coordinate.
    public let row: Int
    /// Horizontal position inside the cell, as a `0...1` fraction of its width. Clamped with
    /// the column as one value, so an off-grid point reads as the edge it left through.
    public let offsetX: Double

    /// Creates a normalized cell value for cross-layer input forwarding.
    public init(column: Int, row: Int, offsetX: Double = 0) {
        self.column = column
        self.row = row
        self.offsetX = offsetX
    }
}

/// Keeps point-space coordinates explicit without importing CoreGraphics into TerminalCore.
public struct TerminalPoint: Equatable, Sendable {
    /// Horizontal point coordinate in a flipped terminal view.
    public let x: Double
    /// Vertical point coordinate in a flipped terminal view.
    public let y: Double

    /// Creates unchecked geometry that `terminalCell` validates as one unit.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Keeps point-space cell dimensions independent from platform geometry types.
public struct TerminalCellSize: Equatable, Sendable {
    /// Horizontal cell extent in points.
    public let width: Double
    /// Vertical cell extent in points.
    public let height: Double

    /// Creates unchecked geometry that `terminalCell` validates as one unit.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Floors a flipped-view point into the grid and clamps it to a valid viewport cell, keeping
/// the horizontal remainder. Clamping moves the remainder with the column rather than
/// independently, so a point off the left edge reads as that column's leading edge and one off
/// the right edge as the last column's trailing edge.
public func terminalCell(
    at point: TerminalPoint,
    cellSize: TerminalCellSize,
    columns: Int,
    rows: Int
) -> TerminalViewportCell? {
    guard point.x.isFinite, point.y.isFinite,
          cellSize.width.isFinite, cellSize.height.isFinite,
          cellSize.width > 0, cellSize.height > 0,
          columns > 0, rows > 0
    else { return nil }

    let scaledColumn = point.x / cellSize.width
    let column = scaledColumn.rounded(.down)
    let row = (point.y / cellSize.height).rounded(.down)
    guard column.isFinite, row.isFinite,
          column > Double(Int.min), column < Double(Int.max),
          row > Double(Int.min), row < Double(Int.max)
    else { return nil }
    let clampedColumn = min(max(Int(column), 0), columns - 1)
    let offsetX: Double = if Int(column) < clampedColumn {
        0
    } else if Int(column) > clampedColumn {
        1
    } else {
        min(max(scaledColumn - column, 0), 1)
    }
    return TerminalViewportCell(
        column: clampedColumn,
        row: min(max(Int(row), 0), rows - 1),
        offsetX: offsetX
    )
}

/// One platform-neutral pointer transition delivered to serialized interaction policy.
///
/// `offsetX` is the pointer's `0...1` position inside its own cell, carried only on the two
/// transitions that resolve a character boundary; release re-resolves nothing.
public enum TerminalPointerEvent: Equatable, Sendable {
    case down(
        TerminalMouseButton,
        column: Int,
        row: Int,
        offsetX: Double = 0,
        modifiers: TerminalKeyModifiers = [],
        clickCount: Int = 1
    )
    case up(
        TerminalMouseButton,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = []
    )
    case move(column: Int, row: Int, offsetX: Double = 0, modifiers: TerminalKeyModifiers = [])
}

/// Names the sole arm that consumed a normalized pointer transition.
public enum TerminalPointerConsumption: Equatable, Sendable {
    case report
    case selection
    case paneMenu
    case link
    case ignored
}

/// Describes the owner-side selection mutation computed by pointer policy.
public enum TerminalSelectionMutation: Equatable, Sendable {
    case clear
    case set(TerminalTextRange)
}

/// Describes presentation-only hover work for the serialized terminal owner.
public enum TerminalHoverMutation: Equatable, Sendable {
    case clear
    case set(TerminalResolvedLink)
}

/// Describes owner-side retention for the one run eligible at pointer release.
public enum TerminalLinkArmMutation: Equatable, Sendable {
    case clear
    case set(TerminalResolvedLink)
}

/// Clears both interaction states that cannot survive a pointer exit.
public struct TerminalLinkCancellation: Equatable, Sendable {
    /// Removes presentation left by the last Cmd-modified move.
    public let hoverMutation: TerminalHoverMutation
    /// Removes the click reservation independently from other button owners.
    public let armMutation: TerminalLinkArmMutation
}

/// Returns all effects of one pointer decision without performing IO or framework calls.
public struct TerminalPointerDecision: Equatable, Sendable {
    /// Identifies the one policy arm that owned the event.
    public let consumption: TerminalPointerConsumption
    /// Contains child input only for the report arm.
    public let inputBytes: [UInt8]
    /// Carries a local selection update for the selection arm.
    public let selectionMutation: TerminalSelectionMutation?
    /// Requests the pane menu only after an uncaptured right-button release.
    public let paneMenuCell: TerminalViewportCell?
    /// Applies hover presentation independently from the event's byte-owning arm.
    public let hoverMutation: TerminalHoverMutation?
    /// Delivers a click-time-revalidated HTTP(S) target only on a matching link release.
    public let openLink: TerminalHyperlink?
    /// Reserves or clears the exact originating run under the terminal metadata cap.
    public let armMutation: TerminalLinkArmMutation?
}

/// Marks normalized wheel lifecycle so direct scrolling and momentum share one route.
public enum TerminalWheelPhase: Equatable, Sendable {
    case began
    case changed
    case ended
    case momentumBegan
    case momentumChanged
    case momentumEnded
    case standalone
}

/// Carries fractional vertical wheel motion and the metadata that determines its action.
public struct TerminalWheelEvent: Equatable, Sendable {
    /// Signed rows, where negative motion navigates toward retained history.
    public let rowDelta: Double
    /// Zero-based pointed viewport column.
    public let column: Int
    /// Zero-based pointed viewport row.
    public let row: Int
    /// Modifier snapshot used at gesture routing and report encoding time.
    public let modifiers: TerminalKeyModifiers
    /// Normalized direct or momentum lifecycle boundary.
    public let phase: TerminalWheelPhase

    /// Creates one normalized wheel sample; phase-less ticks are standalone gestures.
    public init(
        rowDelta: Double,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = [],
        phase: TerminalWheelPhase = .standalone
    ) {
        self.rowDelta = rowDelta
        self.column = column
        self.row = row
        self.modifiers = modifiers
        self.phase = phase
    }
}

/// Names the latched destination chosen for one wheel gesture.
public enum TerminalWheelRoute: Equatable, Sendable {
    case localViewport
    case mouseReport
    case alternateScreen
}

/// Returns deterministic wheel bytes or local navigation after route-specific quantization.
public struct TerminalWheelDecision: Equatable, Sendable {
    /// Route selected at gesture start or independently for a standalone tick.
    public let route: TerminalWheelRoute
    /// Contains mouse reports or alternate-screen arrow input, never local scroll bytes.
    public let inputBytes: [UInt8]
    /// Contains primary-screen local navigation, with zero for either input route.
    public let localRowDelta: Int
}

private enum SelectionGranularity: Equatable, Sendable {
    case character
    case terminalToken
    case line
}

/// The end of an in-flight drag the pointer does not hold, kept as a `Terminal`-minted pin
/// rather than coordinates: it has to name the same text on the next event, and stream
/// coordinates stop meaning what they meant the moment a row is evicted.
private struct SelectionDrag: Equatable, Sendable {
    var anchor: Terminal.PinnedTextRange
    var granularity: SelectionGranularity
    /// Which of the pressed character's two boundaries the gesture is anchored to. A character
    /// drag needs a boundary, but pins the whole character range so eviction clamping and
    /// epoch retirement reach it, then re-derives this end from the resolved range every move.
    var anchorsTrailingBoundary = false
}

private enum WheelMetadata: Equatable, Sendable {
    case localViewport(isAlternateScreenActive: Bool)
    case mouseReport(
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers,
        trackingEnabled: Bool,
        sgr: Bool
    )
    case alternateScreen(applicationCursorKeys: Bool)
}

private struct WheelRemainder: Equatable, Sendable {
    var rows = 0.0
    var metadata: WheelMetadata?
}

/// Owns explicit gesture latches and fractional history shared by live and replay policy.
public struct TerminalInteractionState: Equatable, Sendable {
    fileprivate var mouseTracker = TerminalMouseTracker()
    fileprivate var pointerOwners: [TerminalPointerConsumption?] = [nil, nil, nil]
    fileprivate var selectionDrag: SelectionDrag?
    fileprivate var activeWheelRoute: TerminalWheelRoute?
    fileprivate var localWheel = WheelRemainder()
    fileprivate var reportWheel = WheelRemainder()
    fileprivate var alternateWheel = WheelRemainder()

    /// Creates empty interaction history with no owned gestures or fractional motion.
    public init() {}
}

/// Chooses and advances exactly one pointer arm against authoritative terminal state.
public func decideTerminalPointer(
    _ event: TerminalPointerEvent,
    terminal: Terminal,
    state: inout TerminalInteractionState
) -> TerminalPointerDecision {
    let modes = terminal.inputModes
    switch event {
    case let .down(button, column, row, offsetX, modifiers, clickCount):
        if state.pointerOwners[button.rawValue] == nil,
           button == .left,
           modifiers.contains(.command),
           isViewportPosition(column: column, row: row, terminal: terminal),
           let link = terminal.activatableLink(at: streamPosition(
               column: column, row: row, terminal: terminal
           )),
           terminal.canAdmitArmedLink(link)
        {
            state.pointerOwners[button.rawValue] = .link
            return pointerDecision(
                .link,
                armMutation: .set(link)
            )
        }
        let reportBytes = encodeTerminalMouse(
            .down(button, column: column, row: row, modifiers: modifiers),
            tracker: &state.mouseTracker,
            modes: modes
        )
        if let existingOwner = state.pointerOwners[button.rawValue] {
            return pointerDecision(
                existingOwner,
                bytes: existingOwner == .report ? reportBytes : []
            )
        }
        let owner = pointerOwner(
            button: button,
            modifiers: modifiers,
            tracking: modes.mouseTracking
        )
        state.pointerOwners[button.rawValue] = owner
        return pointerDownDecision(
            owner: owner,
            button: button,
            column: column,
            row: row,
            offsetX: offsetX,
            clickCount: clickCount,
            terminal: terminal,
            reportBytes: reportBytes,
            state: &state
        )

    case let .up(button, column, row, modifiers):
        let owner = state.pointerOwners[button.rawValue] ?? .ignored
        if owner == .link {
            state.pointerOwners[button.rawValue] = nil
            guard isViewportPosition(column: column, row: row, terminal: terminal) else {
                return pointerDecision(
                    .link,
                    hoverMutation: .clear,
                    armMutation: .clear
                )
            }
            guard let link = terminal.activatableLink(at: streamPosition(
                column: column, row: row, terminal: terminal
            )), let armedLink = terminal.armedLink, link.matchesActivation(armedLink)
            else {
                return pointerDecision(
                    .link,
                    hoverMutation: .clear,
                    armMutation: .clear
                )
            }
            return TerminalPointerDecision(
                consumption: .link,
                inputBytes: [],
                selectionMutation: nil,
                paneMenuCell: nil,
                hoverMutation: .clear,
                openLink: link.hyperlink,
                armMutation: .clear
            )
        }
        let reportBytes = encodeTerminalMouse(
            .up(button, column: column, row: row, modifiers: modifiers),
            tracker: &state.mouseTracker,
            modes: modes
        )
        state.pointerOwners[button.rawValue] = nil
        if button == .left { state.selectionDrag = nil }
        switch owner {
        case .report:
            return pointerDecision(.report, bytes: reportBytes)
        case .selection:
            return pointerDecision(.selection)
        case .paneMenu:
            return TerminalPointerDecision(
                consumption: .paneMenu,
                inputBytes: [],
                selectionMutation: nil,
                paneMenuCell: .init(column: column, row: row),
                hoverMutation: nil,
                openLink: nil,
                armMutation: nil
            )
        case .link:
            return pointerDecision(.link)
        case .ignored:
            return pointerDecision(.ignored)
        }

    case let .move(column, row, offsetX, modifiers):
        if state.pointerOwners.contains(where: { $0 == .link }) {
            guard isViewportPosition(column: column, row: row, terminal: terminal) else {
                return pointerDecision(
                    .link,
                    hoverMutation: .clear,
                    armMutation: .clear
                )
            }
            return pointerDecision(
                .link,
                hoverMutation: hoverMutation(
                    column: column, row: row, modifiers: modifiers, terminal: terminal
                )
            )
        }
        let reportBytes = encodeTerminalMouse(
            .move(column: column, row: row, modifiers: modifiers),
            tracker: &state.mouseTracker,
            modes: modes
        )
        if let drag = state.selectionDrag,
           state.pointerOwners[TerminalMouseButton.left.rawValue] == .selection {
            let dragHover = hoverMutation(
                column: column, row: row, modifiers: modifiers, terminal: terminal
            )
            // The anchored text is no longer retained, so there is nothing to extend from.
            // The button stays selection-owned -- releasing it must still end the gesture
            // without sending bytes to the child.
            guard let anchor = terminal.resolvedRange(drag.anchor) else {
                return pointerDecision(.selection, hoverMutation: dragHover)
            }
            let position = streamPosition(column: column, row: row, terminal: terminal)
            guard drag.granularity == .character else {
                let current = selectionUnit(
                    at: position,
                    granularity: drag.granularity,
                    terminal: terminal
                )
                return pointerDecision(
                    .selection,
                    selectionMutation: .set(union(anchor, current)),
                    hoverMutation: dragHover
                )
            }
            // Both ends are boundaries, so ordering them is the whole direction rule: a
            // reversed drag is the same pair swapped, and a coincident pair is not an empty
            // selection but no selection at all.
            let pressBoundary = terminal.canonicalBoundary(
                drag.anchorsTrailingBoundary ? anchor.end : anchor.start
            )
            let currentBoundary = terminal.characterBoundary(at: position, offsetX: offsetX)
            guard pressBoundary != currentBoundary else {
                return pointerDecision(
                    .selection,
                    selectionMutation: .clear,
                    hoverMutation: dragHover
                )
            }
            return pointerDecision(
                .selection,
                selectionMutation: .set(orderedRange(pressBoundary, currentBoundary)),
                hoverMutation: dragHover
            )
        }
        let hover = hoverMutation(
            column: column, row: row, modifiers: modifiers, terminal: terminal
        )
        if state.pointerOwners.contains(where: { $0 == .report }) {
            return pointerDecision(.report, bytes: reportBytes, hoverMutation: hover)
        }
        if state.pointerOwners.contains(where: { $0 == .paneMenu }) {
            return pointerDecision(.paneMenu, hoverMutation: hover)
        }
        if modes.mouseTracking == .anyMotion {
            return pointerDecision(.report, bytes: reportBytes, hoverMutation: hover)
        }
        return pointerDecision(.ignored, hoverMutation: hover)
    }
}

/// Invalidates only link-owned pointer state when the pointer leaves the terminal surface.
public func cancelTerminalLinkInteraction(
    state: inout TerminalInteractionState
) -> TerminalLinkCancellation {
    state.pointerOwners = state.pointerOwners.map { $0 == .link ? nil : $0 }
    return TerminalLinkCancellation(hoverMutation: .clear, armMutation: .clear)
}

/// Routes and quantizes one wheel sample while preserving gesture ownership through momentum.
public func decideTerminalWheel(
    _ event: TerminalWheelEvent,
    terminal: Terminal,
    state: inout TerminalInteractionState
) -> TerminalWheelDecision {
    let freshRoute = wheelRoute(for: event, terminal: terminal)
    let route: TerminalWheelRoute
    switch event.phase {
    case .began:
        route = freshRoute
        state.activeWheelRoute = route
        resetWheelRemainder(for: route, state: &state)
    case .changed, .ended, .momentumBegan, .momentumChanged, .momentumEnded:
        route = state.activeWheelRoute ?? freshRoute
    case .standalone:
        route = freshRoute
    }

    let metadata = wheelMetadata(for: route, event: event, terminal: terminal)
    let rows = consumeWheelRows(
        event.rowDelta,
        metadata: metadata,
        route: route,
        state: &state
    )
    let decision = wheelDecision(
        route: route,
        rows: rows,
        event: event,
        terminal: terminal,
        state: &state
    )
    if event.phase == .momentumEnded {
        state.activeWheelRoute = nil
        resetWheelRemainder(for: route, state: &state)
    }
    return decision
}

/// Encodes a discrete protocol wheel button against the interaction state's shared tracker.
public func decideTerminalMouseWheelReport(
    _ direction: TerminalMouseWheelDirection,
    column: Int,
    row: Int,
    modifiers: TerminalKeyModifiers = [],
    terminal: Terminal,
    state: inout TerminalInteractionState
) -> [UInt8] {
    encodeTerminalMouse(
        .wheel(direction, column: column, row: row, modifiers: modifiers),
        tracker: &state.mouseTracker,
        modes: terminal.inputModes
    )
}

/// Picks the arm that claims a fresh press. Never returns `.link`: the Cmd-click link path
/// latches its own owner and returns before `decideTerminalPointer` consults this.
private func pointerOwner(
    button: TerminalMouseButton,
    modifiers: TerminalKeyModifiers,
    tracking: TerminalMouseTrackingMode
) -> TerminalPointerConsumption {
    let usesLocalArm = modifiers.contains(.shift) || tracking == .off
    guard usesLocalArm else { return .report }
    switch button {
    case .left: return .selection
    case .right: return .paneMenu
    case .middle: return .ignored
    }
}

private func pointerDownDecision(
    owner: TerminalPointerConsumption,
    button: TerminalMouseButton,
    column: Int,
    row: Int,
    offsetX: Double,
    clickCount: Int,
    terminal: Terminal,
    reportBytes: [UInt8],
    state: inout TerminalInteractionState
) -> TerminalPointerDecision {
    switch owner {
    case .report:
        return pointerDecision(.report, bytes: reportBytes)
    case .paneMenu:
        return pointerDecision(.paneMenu)
    // Unreachable via `pointerOwner`, which never mints `.link`; kept for exhaustiveness.
    case .link:
        return pointerDecision(.link)
    case .ignored:
        return pointerDecision(.ignored)
    case .selection:
        guard button == .left else { return pointerDecision(.ignored) }
        let granularity: SelectionGranularity = switch max(clickCount, 1) % 3 {
        case 1: .character
        case 2: .terminalToken
        default: .line
        }
        let position = streamPosition(column: column, row: row, terminal: terminal)
        let anchor = selectionUnit(
            at: position,
            granularity: granularity,
            terminal: terminal
        )
        state.selectionDrag = SelectionDrag(
            anchor: terminal.pinnedRange(anchor),
            granularity: granularity,
            anchorsTrailingBoundary: granularity == .character
                && terminal.characterBoundary(at: position, offsetX: offsetX)
                    == terminal.canonicalBoundary(anchor.end)
        )
        return pointerDecision(
            .selection,
            selectionMutation: granularity == .character ? .clear : .set(anchor)
        )
    }
}

private func pointerDecision(
    _ consumption: TerminalPointerConsumption,
    bytes: [UInt8] = [],
    selectionMutation: TerminalSelectionMutation? = nil,
    hoverMutation: TerminalHoverMutation? = nil,
    armMutation: TerminalLinkArmMutation? = nil
) -> TerminalPointerDecision {
    TerminalPointerDecision(
        consumption: consumption,
        inputBytes: bytes,
        selectionMutation: selectionMutation,
        paneMenuCell: nil,
        hoverMutation: hoverMutation,
        openLink: nil,
        armMutation: armMutation
    )
}

/// Resolves presentation independently so hover can coexist with any byte-owning arm.
private func hoverMutation(
    column: Int,
    row: Int,
    modifiers: TerminalKeyModifiers,
    terminal: Terminal
) -> TerminalHoverMutation {
    guard modifiers.contains(.command),
          isViewportPosition(column: column, row: row, terminal: terminal),
          let link = terminal.activatableLink(at: streamPosition(
              column: column, row: row, terminal: terminal
          ))
    else { return .clear }
    return .set(link)
}

/// Rejects owner inputs that did not normalize to the terminal's current viewport.
private func isViewportPosition(column: Int, row: Int, terminal: Terminal) -> Bool {
    (0..<terminal.geometry.columns).contains(column)
        && terminal.geometry.rows.indices.contains(row)
}

private func streamPosition(column: Int, row: Int, terminal: Terminal) -> TerminalTextPosition {
    TerminalTextPosition(
        row: terminal.scrollProjection.topRow + row,
        column: column
    )
}

private func selectionUnit(
    at position: TerminalTextPosition,
    granularity: SelectionGranularity,
    terminal: Terminal
) -> TerminalTextRange {
    switch granularity {
    case .character: terminal.characterRange(at: position)
    case .terminalToken: terminal.terminalTokenRange(at: position)
    case .line: terminal.trimmedLogicalLineRange(at: position)
    }
}

private func orderedRange(
    _ lhs: TerminalTextPosition,
    _ rhs: TerminalTextPosition
) -> TerminalTextRange {
    positionLessThan(rhs, lhs)
        ? TerminalTextRange(start: rhs, end: lhs)
        : TerminalTextRange(start: lhs, end: rhs)
}

private func union(_ lhs: TerminalTextRange, _ rhs: TerminalTextRange) -> TerminalTextRange {
    TerminalTextRange(
        start: positionLessThan(rhs.start, lhs.start) ? rhs.start : lhs.start,
        end: positionLessThan(lhs.end, rhs.end) ? rhs.end : lhs.end
    )
}

private func positionLessThan(_ lhs: TerminalTextPosition, _ rhs: TerminalTextPosition) -> Bool {
    lhs.row < rhs.row || (lhs.row == rhs.row && lhs.column < rhs.column)
}

private func wheelRoute(for event: TerminalWheelEvent, terminal: Terminal) -> TerminalWheelRoute {
    if event.modifiers.contains(.shift) { return .localViewport }
    if terminal.inputModes.mouseTracking != .off { return .mouseReport }
    return terminal.isAlternateScreenActive ? .alternateScreen : .localViewport
}

private func wheelMetadata(
    for route: TerminalWheelRoute,
    event: TerminalWheelEvent,
    terminal: Terminal
) -> WheelMetadata {
    switch route {
    case .localViewport:
        return .localViewport(isAlternateScreenActive: terminal.isAlternateScreenActive)
    case .mouseReport:
        return .mouseReport(
            column: event.column,
            row: event.row,
            modifiers: event.modifiers,
            trackingEnabled: terminal.inputModes.mouseTracking != .off,
            sgr: terminal.inputModes.sgrMouseEncoding
        )
    case .alternateScreen:
        return .alternateScreen(
            applicationCursorKeys: terminal.inputModes.applicationCursorKeys
        )
    }
}

private func consumeWheelRows(
    _ delta: Double,
    metadata: WheelMetadata,
    route: TerminalWheelRoute,
    state: inout TerminalInteractionState
) -> Int {
    guard delta.isFinite else { return 0 }
    var remainder = wheelRemainder(for: route, state: state)
    if remainder.metadata != metadata {
        remainder.rows = 0
        remainder.metadata = metadata
    }
    let total = remainder.rows + delta
    guard total > Double(Int.min), total < Double(Int.max) else {
        remainder.rows = 0
        setWheelRemainder(remainder, for: route, state: &state)
        return 0
    }
    let rows = Int(total.rounded(.towardZero))
    remainder.rows = total - Double(rows)
    setWheelRemainder(remainder, for: route, state: &state)
    return rows
}

private func wheelDecision(
    route: TerminalWheelRoute,
    rows: Int,
    event: TerminalWheelEvent,
    terminal: Terminal,
    state: inout TerminalInteractionState
) -> TerminalWheelDecision {
    guard rows != 0 else {
        return TerminalWheelDecision(route: route, inputBytes: [], localRowDelta: 0)
    }
    switch route {
    case .localViewport:
        return TerminalWheelDecision(
            route: route,
            inputBytes: [],
            localRowDelta: terminal.isAlternateScreenActive ? 0 : rows
        )
    case .mouseReport:
        let direction = rows < 0 ? TerminalMouseWheelDirection.up : .down
        var bytes: [UInt8] = []
        for _ in 0..<rows.magnitude {
            bytes.append(contentsOf: encodeTerminalMouse(
                .wheel(
                    direction,
                    column: event.column,
                    row: event.row,
                    modifiers: event.modifiers
                ),
                tracker: &state.mouseTracker,
                modes: terminal.inputModes
            ))
        }
        return TerminalWheelDecision(route: route, inputBytes: bytes, localRowDelta: 0)
    case .alternateScreen:
        let key = rows < 0 ? TerminalInputKey.up : .down
        let step = encodeTerminalKey(key, modifiers: [], modes: terminal.inputModes)
        var bytes: [UInt8] = []
        for _ in 0..<rows.magnitude { bytes.append(contentsOf: step) }
        return TerminalWheelDecision(route: route, inputBytes: bytes, localRowDelta: 0)
    }
}

private func wheelRemainder(
    for route: TerminalWheelRoute,
    state: TerminalInteractionState
) -> WheelRemainder {
    switch route {
    case .localViewport: state.localWheel
    case .mouseReport: state.reportWheel
    case .alternateScreen: state.alternateWheel
    }
}

private func setWheelRemainder(
    _ remainder: WheelRemainder,
    for route: TerminalWheelRoute,
    state: inout TerminalInteractionState
) {
    switch route {
    case .localViewport: state.localWheel = remainder
    case .mouseReport: state.reportWheel = remainder
    case .alternateScreen: state.alternateWheel = remainder
    }
}

private func resetWheelRemainder(
    for route: TerminalWheelRoute,
    state: inout TerminalInteractionState
) {
    setWheelRemainder(WheelRemainder(), for: route, state: &state)
}
