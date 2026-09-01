// The launch-time checkpoint load: reading the session file and grafting the scrollback
// sidecar onto it, to produce the restore launch may offer. It is a named function over its
// inputs rather than a block of top-level code in main.swift so a test can drive it against a
// temporary instance-paths value. The skip rule lives here too -- launch calls this
// unconditionally, so "nothing was read" is an outcome a test can assert instead of an
// `if` at the call site. Crash detection is not here: the session lock is claimed and
// observed before this runs, by `claimSessionLock`, because it must not wait on the
// `--init` file this function's skip rule depends on.
import Foundation

/// Read the previous session's checkpoints and decide what launch may offer to restore.
///
/// Returns nil unless the startup policy prompts for recovery and no `--init` snapshot
/// was loaded -- an explicitly named session wins over the previous one.
///
/// The session file decides the whole outcome: one that is missing, that fails to decode, or
/// that carries an unsupported format version means no restore at all, whatever the sidecar
/// holds. A sidecar in any of those states counts as absent instead, and the restore is
/// offered from structure alone with no scrollback.
func loadLaunchCheckpoints(
    paths: DanTermInstancePaths,
    startup: StartupPolicy,
    hasInitSnapshot: Bool
) -> ValidatedAppRestore? {
    guard !hasInitSnapshot, startup == .promptForRecovery else { return nil }

    guard let session = (try? Data(contentsOf: paths.sessionCheckpointFile))
        .flatMap({ try? loadValidatedInitFile(from: $0) })
    else { return nil }

    let scrollback = (try? Data(contentsOf: paths.scrollbackCheckpointFile))
        .flatMap { loadScrollbackSidecar(from: $0) } ?? [:]

    return graftSidecar(onto: session, scrollbackByPaneId: scrollback)
}
