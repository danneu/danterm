// The light checkpoint tier's write decision: which projection is already covered on disk, and
// what a reported write outcome does to that coverage. It is the light sibling of
// `RecoveryCheckpointPolicy`, and it exists for the same reason -- so the runtime holds no
// recovery rule of its own. Timing belongs to the runtime: this value never learns that a
// window was armed or fired, only that a capture was asked for.
//
// What does *not* belong here: the projection itself (`CheckpointCapture.swift` owns it), and
// any notion of how often a window opens.

/// Decides what the light checkpoint tier writes, and keeps a failed write retryable.
///
/// Coverage advances when a capture is handed to the writer, not when the writer reports back,
/// so a projection that changes and reverts while a write is in flight is still detected and
/// still ends the writer's serial order at the current projection. The price of advancing early
/// is that a failed write leaves a covered projection that never reached disk, which is what
/// `writeCompleted` withdraws.
struct LightCheckpointPolicy {
    /// Names one handoff so an outcome can say which write it describes. Two light writes can
    /// be in flight at once, and an older one's failure says nothing about the projection the
    /// newer one is already carrying to disk.
    struct Handoff: Hashable, Sendable {
        fileprivate let sequence: UInt64
    }

    /// One capture handed to the writer, paired with the handoff its outcome will name.
    struct Write {
        let handoff: Handoff
        let capture: CheckpointCapture
    }

    private var covered: LightCheckpointProjection?
    private var latestHandoff = Handoff(sequence: 0)

    /// Starts with the launch projection covered, because the checkpoint on disk either already
    /// carries it or is about to be superseded by the first real change.
    init(covering projection: LightCheckpointProjection) {
        covered = projection
    }

    /// Return work for the current projection unless it is already covered, and take coverage
    /// of it in the same step.
    mutating func capture(_ current: LightCheckpointProjection) -> Write? {
        guard current != covered else { return nil }
        covered = current
        latestHandoff = Handoff(sequence: latestHandoff.sequence &+ 1)
        return Write(
            handoff: latestHandoff,
            capture: CheckpointCapture(lightProjection: current)
        )
    }

    /// Withdraw coverage when the newest handoff failed, so the next capture yields work again.
    /// An outcome for a superseded handoff decides nothing: whatever it reports, the projection
    /// on its way to disk is newer than the one it carried.
    mutating func writeCompleted(handoff: Handoff, succeeded: Bool) {
        guard succeeded == false, handoff == latestHandoff else { return }
        covered = nil
    }
}
