// Deterministic pointer ownership, local selection, and wheel routing decided against a live
// `Terminal`. The import-free values these decisions consume and produce live in
// `TerminalInteractionVocabulary.swift`.

/// Names the sole arm that consumed a normalized pointer transition.
public enum TerminalPointerConsumption: Equatable, Sendable {
    case report
    case selection
    case link
    case ignored
}

/// Describes the owner-side selection mutation computed by pointer policy.
///
/// The unit travels inside `set` because a settled range and the unit it settled with are one
/// decision: a set without a unit, or a clear carrying one, would be a state no policy arm can
/// produce and every consumer would have to invent a default for.
public enum TerminalSelectionMutation: Equatable, Sendable {
    case clear
    case set(TerminalTextRange, granularity: TerminalSelectionGranularity)
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
    /// Carries a local selection update, unit included, for the selection arm.
    public let selectionMutation: TerminalSelectionMutation?
    /// Applies hover presentation independently from the event's byte-owning arm.
    public let hoverMutation: TerminalHoverMutation?
    /// Delivers a click-time-revalidated HTTP(S) target only on a matching link release.
    public let openLink: TerminalHyperlink?
    /// Reserves or clears the exact originating run under the terminal metadata cap.
    public let armMutation: TerminalLinkArmMutation?
    /// True only on the release that ends a selection-owned gesture. The policy reports the
    /// fact and nothing more: it inspects neither configuration nor selected text, so the
    /// owner alone decides whether that completion is worth materializing text for.
    public let completedSelectionGesture: Bool
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

/// Names the unit a settled selection and any later Shift extension use together.
public enum TerminalSelectionGranularity: Equatable, Sendable {
    case character
    case terminalToken
    case line
}

private enum SelectionDragKind: Equatable, Sendable {
    case fresh(anchorsTrailingBoundary: Bool)
    case extending(fixedUsesEnd: Bool)
}

/// The end of an in-flight drag the pointer does not hold, kept as a `Terminal`-minted pin
/// rather than coordinates: it has to name the same text on the next event, and stream
/// coordinates stop meaning what they meant the moment a row is evicted.
private struct SelectionDrag: Equatable, Sendable {
    var anchor: Terminal.PinnedTextRange
    var granularity: TerminalSelectionGranularity
    var kind: SelectionDragKind
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
    fileprivate var selectionGestureCompletes = false
    fileprivate var activeWheelRoute: TerminalWheelRoute?
    fileprivate var localWheel = WheelRemainder()
    fileprivate var reportWheel = WheelRemainder()
    fileprivate var alternateWheel = WheelRemainder()

    /// Creates empty interaction history with no owned gestures or fractional motion.
    public init() {}
}

/// Chooses and advances exactly one pointer arm against authoritative terminal state.
///
/// Link work needs two independent facts, and this is where both are checked together: the
/// view measured the point inside the grid it drew, and the coordinates address this
/// terminal's geometry. A tape replayed at a smaller grid satisfies the first and fails the
/// second. When either fails the event is off-grid, and every link effect -- arming, hover,
/// opening -- is refused and any link state an earlier event left is cleared, so the caller
/// never has to follow the event with a second cancellation message.
public func decideTerminalPointer(
    _ event: TerminalPointerEvent,
    terminal: Terminal,
    state: inout TerminalInteractionState
) -> TerminalPointerDecision {
    let onGrid = isOnGrid(event.cell, terminal: terminal)
    let decision = decidePointerArm(event, onGrid: onGrid, terminal: terminal, state: &state)
    guard onGrid == false else { return decision }
    state.pointerOwners = state.pointerOwners.map { $0 == .link ? nil : $0 }
    return TerminalPointerDecision(
        consumption: decision.consumption,
        inputBytes: decision.inputBytes,
        selectionMutation: decision.selectionMutation,
        hoverMutation: .clear,
        openLink: nil,
        armMutation: .clear,
        completedSelectionGesture: decision.completedSelectionGesture
    )
}

/// Runs the arm that owns the event. Off-grid events still reach it, so selection keeps its
/// clamped-edge semantics; `onGrid` gates only the link work its caller then overrides.
private func decidePointerArm(
    _ event: TerminalPointerEvent,
    onGrid: Bool,
    terminal: Terminal,
    state: inout TerminalInteractionState
) -> TerminalPointerDecision {
    let modes = terminal.inputModes
    switch event {
    case let .down(button, cell, modifiers, clickCount):
        let (column, row, offsetX) = (cell.column, cell.row, cell.offsetX)
        if state.pointerOwners[button.rawValue] == nil,
           button == .left,
           modifiers.contains(.command),
           onGrid,
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
            modifiers: modifiers,
            clickCount: clickCount,
            terminal: terminal,
            reportBytes: reportBytes,
            state: &state
        )

    case let .up(button, cell, modifiers):
        let (column, row) = (cell.column, cell.row)
        let owner = state.pointerOwners[button.rawValue] ?? .ignored
        if owner == .link {
            state.pointerOwners[button.rawValue] = nil
            guard onGrid else {
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
                hoverMutation: .clear,
                openLink: link.hyperlink,
                armMutation: .clear,
                completedSelectionGesture: false
            )
        }
        let reportBytes = encodeTerminalMouse(
            .up(button, column: column, row: row, modifiers: modifiers),
            tracker: &state.mouseTracker,
            modes: modes
        )
        state.pointerOwners[button.rawValue] = nil
        let completesSelection = state.selectionGestureCompletes
        if button == .left {
            state.selectionDrag = nil
            state.selectionGestureCompletes = false
        }
        switch owner {
        case .report:
            return pointerDecision(.report, bytes: reportBytes)
        case .selection:
            return pointerDecision(
                .selection,
                completedSelectionGesture: completesSelection
            )
        case .link:
            return pointerDecision(.link)
        case .ignored:
            return pointerDecision(.ignored)
        }

    case let .move(cell, modifiers):
        let (column, row, offsetX) = (cell.column, cell.row, cell.offsetX)
        if state.pointerOwners.contains(where: { $0 == .link }) {
            guard onGrid else {
                return pointerDecision(
                    .link,
                    hoverMutation: .clear,
                    armMutation: .clear
                )
            }
            return pointerDecision(
                .link,
                hoverMutation: hoverMutation(cell: cell, modifiers: modifiers, terminal: terminal)
            )
        }
        let reportBytes = encodeTerminalMouse(
            .move(column: column, row: row, modifiers: modifiers),
            tracker: &state.mouseTracker,
            modes: modes
        )
        if let drag = state.selectionDrag,
           state.pointerOwners[TerminalMouseButton.left.rawValue] == .selection {
            let dragHover = hoverMutation(cell: cell, modifiers: modifiers, terminal: terminal)
            // The anchored text is no longer retained, so there is nothing to extend from.
            // The button stays selection-owned -- releasing it must still end the gesture
            // without sending bytes to the child.
            guard let anchor = terminal.resolvedRange(drag.anchor) else {
                return pointerDecision(.selection, hoverMutation: dragHover)
            }
            let position = streamPosition(column: column, row: row, terminal: terminal)
            if case let .extending(fixedUsesEnd) = drag.kind {
                return extensionDecision(
                    fixedRange: anchor,
                    fixedUsesEnd: fixedUsesEnd,
                    position: position,
                    offsetX: offsetX,
                    granularity: drag.granularity,
                    terminal: terminal,
                    hoverMutation: dragHover
                )
            }
            guard drag.granularity == .character else {
                let current = selectionUnit(
                    at: position,
                    granularity: drag.granularity,
                    terminal: terminal
                )
                return pointerDecision(
                    .selection,
                    selectionMutation: .set(union(anchor, current), granularity: drag.granularity),
                    hoverMutation: dragHover
                )
            }
            // Both ends are boundaries, so ordering them is the whole direction rule: a
            // reversed drag is the same pair swapped, and a coincident pair is not an empty
            // selection but no selection at all.
            let pressBoundary: TerminalTextPosition = switch drag.kind {
            case let .fresh(anchorsTrailingBoundary):
                terminal.canonicalBoundary(anchorsTrailingBoundary ? anchor.end : anchor.start)
            case let .extending(fixedUsesEnd):
                terminal.canonicalBoundary(fixedUsesEnd ? anchor.end : anchor.start)
            }
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
                selectionMutation: .set(
                    orderedRange(pressBoundary, currentBoundary),
                    granularity: drag.granularity
                ),
                hoverMutation: dragHover
            )
        }
        let hover = hoverMutation(cell: cell, modifiers: modifiers, terminal: terminal)
        if state.pointerOwners.contains(where: { $0 == .report }) {
            return pointerDecision(.report, bytes: reportBytes, hoverMutation: hover)
        }
        if state.pointerOwners[TerminalMouseButton.left.rawValue] == .selection {
            return pointerDecision(.selection, hoverMutation: hover)
        }
        if modes.mouseTracking == .anyMotion {
            return pointerDecision(.report, bytes: reportBytes, hoverMutation: hover)
        }
        return pointerDecision(.ignored, hoverMutation: hover)
    }
}

/// Invalidates only link-owned pointer state for the one caller that has no pointer event to
/// decide from: the view's `mouseExited`, where the pointer left the surface and nothing else
/// will arrive to say so. Every off-grid pointer that does arrive is decided by
/// `decideTerminalPointer` instead, so this must not be used to follow up an event.
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
    // A local right press is ignored like the middle one: AppKit owns the pane context
    // menu and consumes the gesture before it reaches here, so an unclaimed right press
    // that still arrives has no arm left to run.
    case .left: return .selection
    case .right, .middle: return .ignored
    }
}

private func pointerDownDecision(
    owner: TerminalPointerConsumption,
    button: TerminalMouseButton,
    column: Int,
    row: Int,
    offsetX: Double,
    modifiers: TerminalKeyModifiers,
    clickCount: Int,
    terminal: Terminal,
    reportBytes: [UInt8],
    state: inout TerminalInteractionState
) -> TerminalPointerDecision {
    switch owner {
    case .report:
        return pointerDecision(.report, bytes: reportBytes)
    // Unreachable via `pointerOwner`, which never mints `.link`; kept for exhaustiveness.
    case .link:
        return pointerDecision(.link)
    case .ignored:
        return pointerDecision(.ignored)
    case .selection:
        guard button == .left else { return pointerDecision(.ignored) }
        let position = streamPosition(column: column, row: row, terminal: terminal)
        if modifiers.contains(.shift),
           let settledRange = terminal.selectionRange,
           let settledGranularity = terminal.selectionGranularity
        {
            let boundary = terminal.characterBoundary(at: position, offsetX: offsetX)
            let start = terminal.canonicalBoundary(settledRange.start)
            let end = terminal.canonicalBoundary(settledRange.end)
            if positionLessThan(start, boundary) == false {
                state.selectionDrag = SelectionDrag(
                    anchor: terminal.pinnedRange(settledRange),
                    granularity: settledGranularity,
                    kind: .extending(fixedUsesEnd: true)
                )
                state.selectionGestureCompletes = true
                return extensionDecision(
                    fixedRange: settledRange,
                    fixedUsesEnd: true,
                    position: position,
                    offsetX: offsetX,
                    granularity: settledGranularity,
                    terminal: terminal
                )
            }
            if positionLessThan(end, boundary) {
                state.selectionDrag = SelectionDrag(
                    anchor: terminal.pinnedRange(settledRange),
                    granularity: settledGranularity,
                    kind: .extending(fixedUsesEnd: false)
                )
                state.selectionGestureCompletes = true
                return extensionDecision(
                    fixedRange: settledRange,
                    fixedUsesEnd: false,
                    position: position,
                    offsetX: offsetX,
                    granularity: settledGranularity,
                    terminal: terminal
                )
            }
            state.selectionDrag = nil
            state.selectionGestureCompletes = false
            return pointerDecision(.selection)
        }

        let granularity: TerminalSelectionGranularity = switch max(clickCount, 1) % 3 {
        case 1: .character
        case 2: .terminalToken
        default: .line
        }
        let anchor = selectionUnit(
            at: position,
            granularity: granularity,
            terminal: terminal
        )
        state.selectionDrag = SelectionDrag(
            anchor: terminal.pinnedRange(anchor),
            granularity: granularity,
            kind: .fresh(
                anchorsTrailingBoundary: granularity == .character
                    && terminal.characterBoundary(at: position, offsetX: offsetX)
                        == terminal.canonicalBoundary(anchor.end)
            )
        )
        state.selectionGestureCompletes = true
        return pointerDecision(
            .selection,
            selectionMutation: granularity == .character
                ? .clear
                : .set(anchor, granularity: granularity)
        )
    }
}

private func extensionDecision(
    fixedRange: TerminalTextRange,
    fixedUsesEnd: Bool,
    position: TerminalTextPosition,
    offsetX: Double,
    granularity: TerminalSelectionGranularity,
    terminal: Terminal,
    hoverMutation: TerminalHoverMutation? = nil
) -> TerminalPointerDecision {
    let fixed = terminal.canonicalBoundary(fixedUsesEnd ? fixedRange.end : fixedRange.start)
    let pointerBoundary = terminal.characterBoundary(at: position, offsetX: offsetX)
    let moving: TerminalTextPosition
    if granularity == .character || pointerBoundary == fixed {
        moving = pointerBoundary
    } else {
        let unit = selectionUnit(at: position, granularity: granularity, terminal: terminal)
        if positionLessThan(pointerBoundary, fixed) {
            moving = pointerBoundary == terminal.canonicalBoundary(unit.end)
                ? terminal.canonicalBoundary(unit.end)
                : terminal.canonicalBoundary(unit.start)
        } else {
            moving = pointerBoundary == terminal.canonicalBoundary(unit.start)
                ? terminal.canonicalBoundary(unit.start)
                : terminal.canonicalBoundary(unit.end)
        }
    }
    return pointerDecision(
        .selection,
        selectionMutation: fixed == moving
            ? .clear
            : .set(orderedRange(fixed, moving), granularity: granularity),
        hoverMutation: hoverMutation
    )
}

private func pointerDecision(
    _ consumption: TerminalPointerConsumption,
    bytes: [UInt8] = [],
    selectionMutation: TerminalSelectionMutation? = nil,
    hoverMutation: TerminalHoverMutation? = nil,
    armMutation: TerminalLinkArmMutation? = nil,
    completedSelectionGesture: Bool = false
) -> TerminalPointerDecision {
    TerminalPointerDecision(
        consumption: consumption,
        inputBytes: bytes,
        selectionMutation: selectionMutation,
        hoverMutation: hoverMutation,
        openLink: nil,
        armMutation: armMutation,
        completedSelectionGesture: completedSelectionGesture
    )
}

/// Resolves presentation independently so hover can coexist with any byte-owning arm.
private func hoverMutation(
    cell: TerminalViewportCell,
    modifiers: TerminalKeyModifiers,
    terminal: Terminal
) -> TerminalHoverMutation {
    guard modifiers.contains(.command),
          isOnGrid(cell, terminal: terminal),
          let link = terminal.activatableLink(at: streamPosition(
              column: cell.column, row: cell.row, terminal: terminal
          ))
    else { return .clear }
    return .set(link)
}

/// Answers whether an event may touch a link at all: the view measured its point inside the
/// grid, and its clamped coordinates still address this terminal. A selection drag reaches
/// this with off-grid coordinates, so it also keeps link resolution from indexing out of range.
private func isOnGrid(_ cell: TerminalViewportCell, terminal: Terminal) -> Bool {
    cell.isInsideGrid
        && (0..<terminal.geometry.columns).contains(cell.column)
        && terminal.geometry.rows.indices.contains(cell.row)
}

private func streamPosition(column: Int, row: Int, terminal: Terminal) -> TerminalTextPosition {
    TerminalTextPosition(
        row: terminal.scrollProjection.topRow + row,
        column: column
    )
}

private func selectionUnit(
    at position: TerminalTextPosition,
    granularity: TerminalSelectionGranularity,
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
