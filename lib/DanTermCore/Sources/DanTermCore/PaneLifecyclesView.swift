// Read-only access to state owned by live pane sessions rather than AppModel.

/// Gives pure consumers a typed snapshot of pane-owned live state without
/// exposing session objects or creating a second mutable owner.
struct PaneLifecyclesView: Equatable {
    private let lifecyclesByPaneId: [PaneId: PaneLifecycles]

    init(lifecyclesByPaneId: [PaneId: PaneLifecycles] = [:]) {
        self.lifecyclesByPaneId = lifecyclesByPaneId
    }

    /// Returns complete default lifecycles when the model pane has no live session.
    func lifecycles(for paneId: PaneId) -> PaneLifecycles {
        lifecyclesByPaneId[paneId] ?? PaneLifecycles()
    }
}
