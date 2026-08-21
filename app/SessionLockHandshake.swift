// Launch's session-lock handshake: observe the previous launch's lock, then claim this
// launch's. It is its own file, and its own launch step, because it depends on nothing
// but the resolved paths -- not the startup policy, not the `--init` file, not the
// checkpoints. That is what lets it run first, before anything else launch does can
// fail. Deciding what to do with the two answers belongs to the delegate and the
// runtime; nothing here prompts, presents, or restores.
import Foundation

/// What the handshake learned and what it did, as one value so a caller cannot take the
/// crash answer without also seeing whether the claim it depends on succeeded.
struct SessionLockHandshake {
    /// True unless the lock file's absence was confirmed. A lookup that fails for any
    /// other reason reports a crash, because a directory we cannot inspect may hold a lock.
    let previousSessionCrashed: Bool
    /// Non-nil when this launch's lock could not be written, so crash detection is
    /// degraded for this run and the user has to be told once a surface exists.
    let claimFailure: Error?
}

/// Read the previous launch's lock and immediately claim this launch's.
///
/// Both halves are unconditional, and they run before launch does any other fallible
/// work: a crash anywhere after this point leaves the lock behind, so the next launch
/// sees it. Deferring the claim to a later launch step -- after the `--init` file, the
/// checkpoints, or the window -- would leave every step before it able to crash and
/// still read as a clean exit.
func claimSessionLock(paths: DanTermInstancePaths) -> SessionLockHandshake {
    let crashed = sessionLockIsPresent(paths: paths)
    do {
        try writeSessionLockFile(paths: paths)
        return SessionLockHandshake(previousSessionCrashed: crashed, claimFailure: nil)
    } catch {
        return SessionLockHandshake(previousSessionCrashed: crashed, claimFailure: error)
    }
}
