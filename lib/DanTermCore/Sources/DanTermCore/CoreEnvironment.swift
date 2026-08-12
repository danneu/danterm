// Injectable environment for DanTermCore's ambient edges: fresh IDs, wall-clock
// time, the home directory, and the running process's instance identity.
// Production callers use `.live`; tests pass deterministic closures where
// saved/sent/asserted output must reproduce.
//
// Identity is unlike the other three. They are nondeterministic inputs that only
// have to reproduce; identity is an AUTHORIZATION input -- IPC dispatch reads it
// to decide whether the caller may end this instance. A test that leaves it
// ambient gets the harness bundle, which holds no privilege, so the default
// fails closed.
import Foundation
import DanTermProtocol

/// Carries the pure core's ambient dependencies through explicit call-site seams.
///
/// The seams are `@Sendable` because an env is a bag of pure functions that any
/// caller may share. A generator that needs to remember what it already handed
/// out -- a test's id sequence -- owns its own synchronization rather than
/// capturing a bare `var`.
struct CoreEnv: Sendable {
    var newId: @Sendable () -> UUID
    var now: @Sendable () -> Date
    /// The user's home directory, injected so save/send/assert paths reproduce.
    ///
    /// Inject-vs-ambient rule: thread an explicit home when the result is SAVED
    /// (a snapshot/checkpoint), SENT (an IPC reply), or ASSERTED (a test) -- any
    /// value a second execution compares against. Leave it ambient (the real
    /// `NSHomeDirectory()`, via `.live` or a leaf default) when the result is only
    /// SHOWN live and discarded (tab/toolbar chrome, alert text). `update()`
    /// passes `env.homeDirectory()` into the snapshot/IPC builders for exactly this
    /// reason; render helpers read the ambient default.
    var homeDirectory: @Sendable () -> String
    /// The identity of the process this core is running inside.
    ///
    /// Authorization, not reproducibility: `quit` is admitted only for an
    /// instance holding a launcher pool slot, and this seam is how pure dispatch
    /// learns which instance it is. The live value is the app's own bundle, so a
    /// caller cannot claim an identity it does not have.
    var instanceIdentity: @Sendable () -> DanTermInstanceIdentity

    static let live = CoreEnv(
        newId: { UUID() },  // core-purity: ambient-seam
        now: { Date() },  // core-purity: ambient-seam
        homeDirectory: { NSHomeDirectory() },  // core-purity: ambient-seam
        instanceIdentity: { DanTermInstanceIdentity(bundle: .main) }  // core-purity: ambient-seam
    )
}
