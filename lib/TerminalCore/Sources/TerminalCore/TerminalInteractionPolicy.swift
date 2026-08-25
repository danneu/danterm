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
/// An alternative rather than a set of fields: a press the report arm owns takes the local
/// selection away and has no unit, boundary, or granularity to name, while a selection sample
/// names all three at once. The pivot and the unit travel with the focus because all three are
/// one decision -- any two without the third would be a state no policy arm can produce and
/// every consumer would have to invent a default for.
public enum TerminalSelectionMutation: Equatable, Sendable {
    /// Settles an anchored pair. The empty one at character granularity is the caret.
    ///
    /// - Parameters:
    ///   - anchorUnit: The unit the gesture pivots on, empty at character granularity.
    ///   - focus: The boundary the pointer has reached, on either side of the anchor.
    ///   - granularity: The unit this sample and every later Shift extension measure in.
    case set(
        anchorUnit: TerminalTextRange,
        focus: TerminalTextPosition,
        granularity: TerminalSelectionGranularity
    )
    /// Removes the local selection, caret included.
    case clear
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
    /// Settles a local selection for the selection arm, or takes one away for a reported press.
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

/// What one latched button remembers about the gesture it owns.
///
/// The arm alone is not enough for the selection arm: a caret outlives its gesture only when
/// the user could aim it, and that is a fact about the press. Carrying it in the latch is what
/// keeps it from existing without a gesture, and what keeps a mode change mid-gesture from
/// rewriting an answer the press already gave.
private enum TerminalPointerGesture: Equatable, Sendable {
    case report
    /// - Parameter caretOutlivesGesture: True only for the caret a plain press placed while
    ///   the child did not own the mouse -- the one caret the user aimed.
    case selection(caretOutlivesGesture: Bool)
    case link
    case ignored

    /// Names the arm for the decision, which reports ownership and nothing about the press.
    var consumption: TerminalPointerConsumption {
        switch self {
        case .report: .report
        case .selection: .selection
        case .link: .link
        case .ignored: .ignored
        }
    }
}

/// Owns explicit gesture latches and fractional history shared by live and replay policy.
public struct TerminalInteractionState: Equatable, Sendable {
    fileprivate var mouseTracker = TerminalMouseTracker()
    fileprivate var pointerOwners: [TerminalMouseButton: TerminalPointerGesture] = [:]
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
    state.pointerOwners = state.pointerOwners.filter { $0.value != .link }
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
        if state.pointerOwners[button] == nil,
           button == .left,
           modifiers.contains(.command),
           onGrid,
           let link = terminal.activatableLink(at: streamPosition(
               column: column, row: row, terminal: terminal
           )),
           terminal.canAdmitArmedLink(link)
        {
            state.pointerOwners[button] = .link
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
        if let existingOwner = state.pointerOwners[button] {
            return pointerDecision(
                existingOwner.consumption,
                bytes: existingOwner == .report ? reportBytes : []
            )
        }
        let owner = pointerGesture(
            button: button,
            modifiers: modifiers,
            tracking: modes.mouseTracking
        )
        state.pointerOwners[button] = owner
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
        let owner = state.pointerOwners[button] ?? .ignored
        if owner == .link {
            state.pointerOwners[button] = nil
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
        state.pointerOwners[button] = nil
        switch owner {
        case .report:
            return pointerDecision(.report, bytes: reportBytes)
        case let .selection(caretOutlivesGesture):
            // Every selection-owned press now settles an anchored pair, so every one of them
            // ends a gesture. Whether that completion is worth copying is the owner's call.
            //
            // A gesture that highlighted nothing leaves a caret behind, and only the press the
            // user could aim gets to keep it. Any other caret is invisible state that would
            // pivot the next Shift press onto a point nobody chose.
            let endsCaret = caretOutlivesGesture == false && terminal.holdsCaret
            return pointerDecision(
                .selection,
                selectionMutation: endsCaret ? .clear : nil,
                completedSelectionGesture: true
            )
        case .link:
            return pointerDecision(.link)
        case .ignored:
            return pointerDecision(.ignored)
        }

    case let .move(cell, modifiers):
        let (column, row, offsetX) = (cell.column, cell.row, cell.offsetX)
        if state.pointerOwners.values.contains(.link) {
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
        if state.pointerOwners[.left]?.consumption == .selection {
            let dragHover = hoverMutation(cell: cell, modifiers: modifiers, terminal: terminal)
            // The press settled the anchor in the terminal, so a drag sample is the same rule
            // a Shift press runs. Nothing left to extend from means the anchored text is no
            // longer retained; the button stays selection-owned, because releasing it must
            // still end the gesture without sending bytes to the child.
            guard let anchorUnit = terminal.selectionAnchorUnit,
                  let granularity = terminal.selectionGranularity
            else {
                return pointerDecision(.selection, hoverMutation: dragHover)
            }
            return selectionDecision(
                anchorUnit: anchorUnit,
                granularity: granularity,
                position: streamPosition(column: column, row: row, terminal: terminal),
                offsetX: offsetX,
                terminal: terminal,
                hoverMutation: dragHover
            )
        }
        let hover = hoverMutation(cell: cell, modifiers: modifiers, terminal: terminal)
        if state.pointerOwners.values.contains(.report) {
            return pointerDecision(.report, bytes: reportBytes, hoverMutation: hover)
        }
        if state.pointerOwners[.left]?.consumption == .selection {
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
    state.pointerOwners = state.pointerOwners.filter { $0.value != .link }
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

/// Latches a fresh press: the arm that claims it, and for the selection arm what the release
/// has to remember about it. Never returns `.link`: the Cmd-click link path latches its own
/// gesture and returns before `decideTerminalPointer` consults this.
private func pointerGesture(
    button: TerminalMouseButton,
    modifiers: TerminalKeyModifiers,
    tracking: TerminalMouseTrackingMode
) -> TerminalPointerGesture {
    let isPlainPress = modifiers.contains(.shift) == false
    let usesLocalArm = isPlainPress == false || tracking == .off
    guard usesLocalArm else { return .report }
    switch button {
    // A local right press is ignored like the middle one: AppKit owns the pane context
    // menu and consumes the gesture before it reaches here, so an unclaimed right press
    // that still arrives has no arm left to run.
    case .left:
        return .selection(caretOutlivesGesture: isPlainPress && tracking == .off)
    case .right, .middle: return .ignored
    }
}

private func pointerDownDecision(
    owner: TerminalPointerGesture,
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
        // The child owns this press, so the user has no plain press left to dismiss a local
        // selection with. The press that goes to the child is the one that takes it away.
        return pointerDecision(.report, bytes: reportBytes, selectionMutation: .clear)
    // Unreachable via `pointerOwner`, which never mints `.link`; kept for exhaustiveness.
    case .link:
        return pointerDecision(.link)
    case .ignored:
        return pointerDecision(.ignored)
    case .selection:
        guard button == .left else { return pointerDecision(.ignored) }
        let position = streamPosition(column: column, row: row, terminal: terminal)
        // A press sets the anchor, a Shift press keeps the settled one, and both move the
        // focus. There is no third arm: a Shift press with no settled selection to pivot on
        // falls through and mints its own anchor like any other press.
        //
        // While the child owns the mouse, a Shift multi-click falls through too. The anchor a
        // multi-click would extend from is one no plain click could have aimed, so extending
        // it grows the selection from wherever the last gesture happened to end; naming the
        // pointed token or line instead is the only reading the user can direct.
        let extendsRegardlessOfClickCount = terminal.inputModes.mouseTracking == .off
        if modifiers.contains(.shift),
           extendsRegardlessOfClickCount || max(clickCount, 1) == 1,
           let anchorUnit = terminal.selectionAnchorUnit,
           let granularity = terminal.selectionGranularity
        {
            return selectionDecision(
                anchorUnit: anchorUnit,
                granularity: granularity,
                position: position,
                offsetX: offsetX,
                terminal: terminal
            )
        }

        let granularity: TerminalSelectionGranularity = switch max(clickCount, 1) % 3 {
        case 1: .character
        case 2: .terminalToken
        default: .line
        }
        // A character press pivots on a boundary, not a cell, which is what makes it settle a
        // caret rather than select the character it landed on.
        let anchorUnit = granularity == .character
            ? emptyRange(at: terminal.characterBoundary(at: position, offsetX: offsetX))
            : selectionUnit(at: position, granularity: granularity, terminal: terminal)
        return selectionDecision(
            anchorUnit: anchorUnit,
            granularity: granularity,
            position: position,
            offsetX: offsetX,
            terminal: terminal
        )
    }
}

/// The one rule every selection sample follows: the anchor unit stays where the gesture that
/// made the selection put it, and the focus moves to the unit under the pointer.
///
/// A press, a drag sample, and a Shift press all run this. That is the whole of the AppKit
/// behavior being matched: extension from a caret, shrinking inside the old range, and
/// flipping across the anchor are one computation, not three cases.
private func selectionDecision(
    anchorUnit: TerminalTextRange,
    granularity: TerminalSelectionGranularity,
    position: TerminalTextPosition,
    offsetX: Double,
    terminal: Terminal,
    hoverMutation: TerminalHoverMutation? = nil
) -> TerminalPointerDecision {
    let focus: TerminalTextPosition
    if granularity == .character {
        focus = terminal.characterBoundary(at: position, offsetX: offsetX)
    } else {
        // The focus is the pointer unit's edge away from the anchor -- its near edge lies
        // between the two units and would cut the pointer's own unit in half. The pointer
        // names a whole unit at these granularities, so where inside its cells it sits does
        // not enter into it.
        let unit = selectionUnit(at: position, granularity: granularity, terminal: terminal)
        let unitStart = terminal.canonicalBoundary(unit.start)
        focus = positionLessThan(unitStart, terminal.canonicalBoundary(anchorUnit.start))
            ? unitStart
            : terminal.canonicalBoundary(unit.end)
    }
    return pointerDecision(
        .selection,
        selectionMutation: .set(
            anchorUnit: anchorUnit,
            focus: focus,
            granularity: granularity
        ),
        hoverMutation: hoverMutation
    )
}

/// Spells the degenerate unit a character gesture pivots on: one boundary, twice.
private func emptyRange(at boundary: TerminalTextPosition) -> TerminalTextRange {
    TerminalTextRange(start: boundary, end: boundary)
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
