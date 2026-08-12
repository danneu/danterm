// Portable preparation of a pane-tape dump before AppRuntime schedules its encoding work.
import Foundation

/// Keeps the no-terminal RPC contract beside the deferred, sendable encoding job.
enum PaneTapeDumpPreparation: Sendable {
    case error(code: Int, message: String)
    case encode(@Sendable () throws -> Data)
}

/// Turns an optional session recorder into the exact runtime action the IPC request requires.
/// Every terminal pane records, so the absent encoder means only that this session has no
/// terminal behind it, and the error says exactly that rather than blaming a backend.
func preparePaneTapeDump(
    encoder: (@Sendable () throws -> Data)?
) -> PaneTapeDumpPreparation {
    guard let encoder else {
        return .error(
            code: -32603,
            message: "pane has no terminal to read a tape from"
        )
    }
    return .encode(encoder)
}
