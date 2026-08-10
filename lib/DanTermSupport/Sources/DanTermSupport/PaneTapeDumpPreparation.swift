// Portable preparation of a pane-tape dump before AppRuntime schedules its encoding work.
import Foundation

/// Keeps the unsupported-backend RPC contract beside the deferred, sendable encoding job.
enum PaneTapeDumpPreparation: Sendable {
    case error(code: Int, message: String)
    case encode(@Sendable () throws -> Data)
}

/// Turns an optional backend recorder into the exact runtime action the IPC request requires.
func preparePaneTapeDump(
    encoder: (@Sendable () throws -> Data)?
) -> PaneTapeDumpPreparation {
    guard let encoder else {
        return .error(
            code: -32603,
            message: "pane tape unavailable for this terminal backend"
        )
    }
    return .encode(encoder)
}
