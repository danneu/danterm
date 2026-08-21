// The launch-time checkpoint load: reading both recovery tiers and merging them into
// the restore launch may offer. It is a named function over its inputs rather than a
// block of top-level code in main.swift so a test can drive it against a temporary
// instance-paths value. The skip rule lives here too -- launch calls this
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
/// A tier that fails to decode, or that carries an unsupported format version, counts
/// as absent. When both tiers survive, light is authoritative for structure and
/// enriched supplies scrollback for the panes they share.
func loadLaunchCheckpoints(
    paths: DanTermInstancePaths,
    startup: StartupPolicy,
    hasInitSnapshot: Bool
) -> ValidatedAppRestore? {
    guard !hasInitSnapshot, startup == .promptForRecovery else { return nil }

    let light = (try? Data(contentsOf: paths.lightCheckpointFile))
        .flatMap { try? loadValidatedInitFile(from: $0) }
    let enriched = (try? Data(contentsOf: paths.enrichedCheckpointFile))
        .flatMap { try? loadValidatedInitFile(from: $0) }

    switch (light, enriched) {
    case let (light?, enriched?):
        return mergeCheckpoints(light: light, enriched: enriched)
    case let (light?, nil):
        return light
    case let (nil, enriched?):
        return enriched
    case (nil, nil):
        return nil
    }
}
