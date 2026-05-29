// Injectable environment for DanTermCore's nondeterministic edges: fresh IDs,
// wall-clock time, and the home directory. Production callers use `.live`; tests
// pass deterministic closures where saved/sent/asserted output must reproduce.
import Foundation

/// Carries the pure core's ambient dependencies through explicit call-site seams.
struct CoreEnv {
    var newId: () -> UUID
    var now: () -> Date
    /// The user's home directory, injected so save/send/assert paths reproduce.
    ///
    /// Inject-vs-ambient rule: thread an explicit home when the result is SAVED
    /// (a snapshot/checkpoint), SENT (an IPC reply), or ASSERTED (a test) -- any
    /// value a second execution compares against. Leave it ambient (the real
    /// `NSHomeDirectory()`, via `.live` or a leaf default) when the result is only
    /// SHOWN live and discarded (tab/toolbar chrome, alert text). `update()`
    /// passes `env.homeDirectory()` into the snapshot/IPC builders for exactly this
    /// reason; render helpers read the ambient default.
    var homeDirectory: () -> String

    static let live = CoreEnv(
        newId: { UUID() },  // core-purity: ambient-seam
        now: { Date() },  // core-purity: ambient-seam
        homeDirectory: { NSHomeDirectory() }  // core-purity: ambient-seam
    )
}
