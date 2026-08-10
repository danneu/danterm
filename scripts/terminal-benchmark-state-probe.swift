// Reports ProcessInfo state for terminal-feed blocks measured outside the app.
import Foundation

/// Gives benchmark evidence stable names independent of Foundation's enum spelling.
func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

let processInfo = ProcessInfo.processInfo
let state: [String: Any] = [
    "thermalState": thermalStateName(processInfo.thermalState),
    "lowPowerMode": processInfo.isLowPowerModeEnabled,
]
let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
