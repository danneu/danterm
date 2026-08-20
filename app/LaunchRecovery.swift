// The launch-time read of the previous session: crash detection from the session lock,
// plus the checkpoint load and merge. It is a named function over its inputs rather
// than a block of top-level code in main.swift so a test can drive it against a
// temporary instance-paths value. The skip rule lives here too -- launch calls this
// unconditionally, so "nothing was read" is an outcome a test can assert instead of an
// `if` at the call site. Writing the lock, and prompting the user about what comes
// back, belong to the runtime and stay out of this file.
import Foundation

/// What launch learned about the previous session, as one value so the two answers
/// travel together. They are independent: a session can crash before its first
/// checkpoint, and a clean exit still leaves checkpoints to restore.
struct LaunchRecovery {
    let previousSessionCrashed: Bool
    let restore: ValidatedAppRestore?

    /// The answer when the read is skipped, and when nothing is on disk.
    static var none: LaunchRecovery {
        LaunchRecovery(previousSessionCrashed: false, restore: nil)
    }
}

/// Read the previous session's recovery files and decide what launch may offer.
///
/// Returns `.none` unless the startup policy prompts for recovery and no `--init`
/// snapshot was loaded -- an explicitly named session wins over the previous one.
/// The session lock is read, never deleted: the runtime overwrites it atomically when
/// it starts, so removing it here would leave a window in which a crash during startup
/// reads as a clean exit on the next launch.
///
/// A tier that fails to decode, or that carries an unsupported format version, counts
/// as absent. When both tiers survive, light is authoritative for structure and
/// enriched supplies scrollback for the panes they share.
func readLaunchRecovery(
    paths: DanTermInstancePaths,
    startup: StartupPolicy,
    hasInitSnapshot: Bool
) -> LaunchRecovery {
    guard !hasInitSnapshot, startup == .promptForRecovery else { return .none }

    let crashed = readSessionLockFile(paths: paths) != nil
    let light = (try? Data(contentsOf: paths.lightCheckpointFile))
        .flatMap { try? loadValidatedInitFile(from: $0) }
    let enriched = (try? Data(contentsOf: paths.enrichedCheckpointFile))
        .flatMap { try? loadValidatedInitFile(from: $0) }

    let restore: ValidatedAppRestore?
    switch (light, enriched) {
    case let (light?, enriched?):
        restore = mergeCheckpoints(light: light, enriched: enriched)
    case let (light?, nil):
        restore = light
    case let (nil, enriched?):
        restore = enriched
    case (nil, nil):
        restore = nil
    }

    return LaunchRecovery(previousSessionCrashed: crashed, restore: restore)
}
