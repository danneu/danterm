// The injected boundary for blocking PTY launch and its owner-delivery handoff.
import PaneProcessLifecycle

/// Lets lifecycle tests hold the two nondeterministic spawn handoffs without
/// adding test control to the host actor.
package protocol TerminalPTYSpawning: Sendable {
    func spawn(
        _ spec: PTYLaunchSpec,
        bootstrapExecutable: String,
        didLaunch: (SpawnedPTY) -> Bool
    ) -> PTYSpawnOutcome

    func waitForDeliveryPermission()
}

/// Preserves the direct production launch and immediate delivery behavior.
package struct SystemTerminalPTYSpawner: TerminalPTYSpawning {
    package init() {}

    package func spawn(
        _ spec: PTYLaunchSpec,
        bootstrapExecutable: String,
        didLaunch: (SpawnedPTY) -> Bool
    ) -> PTYSpawnOutcome {
        PTYSpawner.spawn(
            spec,
            bootstrapExecutable: bootstrapExecutable,
            didLaunch: didLaunch
        )
    }

    package func waitForDeliveryPermission() {}
}
