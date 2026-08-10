// Read-only access to state owned by live pane sessions rather than AppModel.

/// Gives pure consumers a typed snapshot of pane-owned live state without
/// exposing session objects or creating a second mutable owner.
struct LivePaneStateView: Equatable {
    private let semanticsByPaneId: [PaneId: PaneSemanticState]

    init(semanticsByPaneId: [PaneId: PaneSemanticState] = [:]) {
        self.semanticsByPaneId = semanticsByPaneId
    }

    /// Returns complete default semantics when the model pane has no live session.
    func semantics(for paneId: PaneId) -> PaneSemanticState {
        semanticsByPaneId[paneId] ?? PaneSemanticState()
    }
}
