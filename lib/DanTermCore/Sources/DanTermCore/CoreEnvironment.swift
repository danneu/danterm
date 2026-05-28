// Injectable environment for DanTermCore's nondeterministic edges: fresh IDs,
// wall-clock time, and the on-disk recovery directory. Production callers use
// `.live`; tests pass deterministic closures where full-model equality matters.
import Foundation

/// Carries the pure core's ambient dependencies through explicit call-site seams.
struct CoreEnv {
    var newId: () -> UUID
    var now: () -> Date
    var recoveryDir: () -> URL

    static let live = CoreEnv(
        newId: { UUID() },
        now: { Date() },
        recoveryDir: { recoveryDirectoryURL() }
    )
}
