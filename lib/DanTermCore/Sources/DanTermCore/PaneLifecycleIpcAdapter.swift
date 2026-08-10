// Translates between the IPC activity vocabulary and core lifecycle values.

extension AgentActivity {
    /// Admits only activity states exposed by the bundled root-agent hook contract.
    init?(rawIpcValue: String) {
        switch rawIpcValue {
        case "working": self = .working
        case "waiting": self = .waiting
        case "idle": self = .idle
        default: return nil
        }
    }

    /// Encodes the activity vocabulary shared by mutation and inspection IPC.
    var ipcValue: String {
        switch self {
        case .working: "working"
        case .waiting: "waiting"
        case .idle: "idle"
        }
    }
}
