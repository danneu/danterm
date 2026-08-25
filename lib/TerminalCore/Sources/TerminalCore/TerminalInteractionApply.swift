// The one place a pointer decision or a link cancellation turns into terminal state. Every
// consumer -- the live PTY host, the recording replay, and the tests -- goes through here, so
// there is a single switch to read and no consumer can invent a selection unit the decision did
// not name. Effects only an owner can perform -- byte submission, flight-tape record, publishing
// a frame, relaying completed selection text, opening a link -- stay at the call site.

/// Settles the terminal-local half of a pointer decision: selection, hover, and link arm.
public func applyTerminalPointerDecision(
    _ decision: TerminalPointerDecision,
    to terminal: inout Terminal
) {
    applySelectionMutation(decision.selectionMutation, to: &terminal)
    applyHoverMutation(decision.hoverMutation, to: &terminal)
    applyArmMutation(decision.armMutation, to: &terminal)
}

/// Settles a link cancellation through the same two link arms a pointer decision uses.
public func applyTerminalLinkCancellation(
    _ cancellation: TerminalLinkCancellation,
    to terminal: inout Terminal
) {
    applyHoverMutation(cancellation.hoverMutation, to: &terminal)
    applyArmMutation(cancellation.armMutation, to: &terminal)
}

private func applySelectionMutation(
    _ mutation: TerminalSelectionMutation?,
    to terminal: inout Terminal
) {
    switch mutation {
    case .clear:
        terminal.clearSelection()
    case let .set(anchorUnit, focus, granularity):
        terminal.setSelection(anchorUnit: anchorUnit, focus: focus, granularity: granularity)
    case nil:
        break
    }
}

private func applyHoverMutation(_ mutation: TerminalHoverMutation?, to terminal: inout Terminal) {
    switch mutation {
    case .clear:
        terminal.clearHoveredLink()
    case .set(let link):
        _ = terminal.setHoveredLink(link)
    case nil:
        break
    }
}

private func applyArmMutation(_ mutation: TerminalLinkArmMutation?, to terminal: inout Terminal) {
    switch mutation {
    case .clear:
        terminal.clearArmedLink()
    case .set(let link):
        _ = terminal.setArmedLink(link)
    case nil:
        break
    }
}
