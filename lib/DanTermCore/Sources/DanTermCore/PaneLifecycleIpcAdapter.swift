// Translates between the IPC activity vocabulary and core lifecycle values.

extension AgentActivity {
    /// Encodes the activity vocabulary shared by mutation and inspection IPC.
    var ipcValue: String {
        switch self {
        case .working: "working"
        case .waiting: "waiting"
        case .idle: "idle"
        }
    }
}
