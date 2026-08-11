// Which pane-kind chip a sidebar row or pane toolbar identifies a pane with.
// The choice is a fact about the model's agent lifecycle, so it is decided here
// in the pure core; app/ owns the artwork and the drawing, and nothing about
// either belongs in this file.

/// The chip that identifies what a pane is running.
///
/// Closed over the artwork DanTerm ships (`icon/chips`). `.terminal` means no
/// agent at all, and `.agent` means one DanTerm has no mark for -- keeping those
/// apart is what lets the toolbar decide whether the chip already names the
/// agent or the label still has to.
/// `CaseIterable` so the tests that must cover every kind -- each one painting
/// distinct pixels, above all -- iterate the enum instead of a hand-written list
/// that a new kind would quietly fall off.
enum ChipKind: Equatable, CaseIterable {
    case terminal
    case claude
    case codex
    case agent

    init(agent: AgentLifecycle) {
        guard case .attached(let session, _) = agent else {
            self = .terminal
            return
        }
        self = KnownAgent(kind: session.kind)?.chipKind ?? .agent
    }
}
