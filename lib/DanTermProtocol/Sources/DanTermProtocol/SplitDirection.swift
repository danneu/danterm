// The split-direction vocabulary shared by the model, persistence, and IPC.

/// Declares each pane split direction once for every layer that stores or sends it.
public enum SplitDirection: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}
