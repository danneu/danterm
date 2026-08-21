// Decides where the next attempt starts: the position the replica stored, or nothing at all.
//
// It is a separate value from `MobileReconnectEpisode` because that one answers when an
// attempt runs and owns nothing about resume state. What does not belong here: reading or
// writing the checkpoint store, and any scheduling.
import Foundation

/// Refuses a stored position that the stream itself proved the two sides disagree about.
///
/// The refusal is decided when an attempt asks where to start, not by deleting the stored
/// checkpoint. The checkpoint is written asynchronously from a snapshot taken before the
/// save runs, so a save already in flight carries the disputed cursor and lands after any
/// delete; a value that never touches the store has no such race to lose.
///
/// The refusal holds until the replica is exact again rather than until the next attempt.
/// An attempt that starts fresh and then fails before its replacement state arrives leaves
/// the disputed position still the newest one on disk, so a one-shot refusal would hand it
/// straight back.
public struct MobileResumePolicy: Equatable, Sendable {
    private var distrustsStoredPosition = false

    /// Creates a policy that trusts whatever the store holds, which is the state at launch.
    public init() {}

    /// Records how a connection ended, which is the only thing that can discredit a position.
    public mutating func connectionEnded(with failure: MobileConnectionFailure) {
        if failure.preservesResumePosition == false { distrustsStoredPosition = true }
    }

    /// Ends the refusal: the replica holds exact state again, so what it stores is placeable.
    public mutating func replicaBecameExact() {
        distrustsStoredPosition = false
    }

    /// Whether a stored position is still worth reading at all. A caller that has to open
    /// the store to produce one asks this first, so a refused position costs no read.
    public var trustsStoredPosition: Bool { distrustsStoredPosition == false }

    /// Answers with the position an attempt may resume from, given what the store holds.
    /// Nothing means start fresh, which costs a full state synchronization and no more.
    public func resumeCheckpoint(
        stored: PaneReplicaCheckpoint?
    ) -> PaneReplicaCheckpoint? {
        distrustsStoredPosition ? nil : stored
    }
}
