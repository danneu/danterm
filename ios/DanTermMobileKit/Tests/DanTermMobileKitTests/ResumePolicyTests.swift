// Tests where the next attempt starts: the position the replica stored, or nothing at all.
//
// Nothing here touches the checkpoint store. The value under test never reads or writes a
// file, and proving that is half the point: the store may still hold the disputed position
// when an attempt asks, and the answer has to be the same either way.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

@Test("Only a desynchronized stream discredits the position the replica stored")
func resumeAcrossTheFailureVocabulary() throws {
    // Intent: every failure but the detected gap leaves the stored position trustworthy, so
    //   the reconnect stays exact; the detected gap alone forces a fresh start.
    // Why it exists: a detected gap can be caused by the very position the stream resumed
    //   from, so an attempt that resumes there reproduces the disagreement and the retry
    //   budget only bounds how many times it does. Every other failure has nothing to do
    //   with the position, and discarding it there would cost the user scrollback.
    let checkpoint = try storedCheckpoint()
    let vocabulary: [(MobileConnectionFailure, Bool)] = [
        (.transport(.unresolvedHost(host: "mac"), phase: .establishing), true),
        (.transport(.connectFailed(reason: "refused", target: "mac:9"), phase: .establishing), true),
        (.transport(.connectTimedOut(target: "mac:9"), phase: .establishing), true),
        (.transport(.configureFailed, phase: .establishing), true),
        (.transport(.configureTimeoutFailed, phase: .establishing), true),
        (.transport(.timedOut, phase: .established), true),
        (.transport(.readFailed, phase: .established), true),
        (.transport(.writeFailed, phase: .established), true),
        (.transport(.peerClosed, phase: .established), true),
        (.conversation(.cancelled, phase: .establishing), true),
        (.conversation(.closedBeforeHello, phase: .establishing), true),
        (.conversation(.invalidHello, phase: .establishing), true),
        (.conversation(.notAdmitted, phase: .establishing), true),
        (.conversation(.identityUnresolved, phase: .establishing), true),
        (.conversation(.connectionLimit(.standard), phase: .establishing), true),
        (.conversation(.auditUnavailable, phase: .establishing), true),
        (.conversation(.unsupportedProtocol(7), phase: .establishing), true),
        (.conversation(.oversizedLine, phase: .established), true),
        (.conversation(.peerSilent, phase: .established), true),
        (.streamEnded(reason: "paneClosed"), true),
        (.requestRefused(reason: "pane not found"), true),
        (.deviceSetup, true),
        (.streamDesynchronized, false),
    ]
    for (failure, resumes) in vocabulary {
        var policy = MobileResumePolicy()
        policy.connectionEnded(with: failure)
        #expect(policy.resumeCheckpoint(stored: checkpoint) == (resumes ? checkpoint : nil))
    }
}

@Test("A fresh policy resumes from whatever the store holds")
func freshPolicyResumes() throws {
    let checkpoint = try storedCheckpoint()
    let policy = MobileResumePolicy()
    #expect(policy.resumeCheckpoint(stored: checkpoint) == checkpoint)
    #expect(policy.resumeCheckpoint(stored: nil) == nil)
}

@Test("The disputed position is refused while the store still holds it")
func refusalSurvivesAStoreThatKeptTheCursor() throws {
    // Intent: after a detected gap the attempt starts fresh even though the checkpoint file
    //   still carries the disputed cursor.
    // Why it exists: the checkpoint is saved asynchronously from a snapshot taken before the
    //   save runs, so a save already in flight lands after the failure. Deleting the file
    //   cannot win that race; refusing the position at the moment an attempt asks has no
    //   race to lose.
    let disputed = try storedCheckpoint()
    var policy = MobileResumePolicy()
    policy.connectionEnded(with: .streamDesynchronized)
    #expect(policy.resumeCheckpoint(stored: disputed) == nil)
}

@Test("The refusal outlives the one attempt that follows it")
func refusalOutlivesOneAttempt() throws {
    // Intent: a detected gap, then an attempt that starts fresh and drops before the
    //   replacement state arrives, still leaves the next attempt starting fresh.
    // Why it exists: that failed attempt saved nothing, so the disputed cursor is still the
    //   newest position on disk. A refusal spent by the first attempt would hand it straight
    //   back, and the retry would reproduce the disagreement it was meant to escape.
    let disputed = try storedCheckpoint()
    var policy = MobileResumePolicy()
    policy.connectionEnded(with: .streamDesynchronized)
    policy.connectionEnded(with: .transport(.peerClosed, phase: .established))
    #expect(policy.resumeCheckpoint(stored: disputed) == nil)

    // Exact state is what makes a stored position trustworthy again, so it is what ends the
    // refusal -- and a later ordinary drop keeps the position it left behind.
    policy.replicaBecameExact()
    #expect(policy.resumeCheckpoint(stored: disputed) == disputed)
    policy.connectionEnded(with: .transport(.peerClosed, phase: .established))
    #expect(policy.resumeCheckpoint(stored: disputed) == disputed)
}

/// Builds one exact checkpoint so a test can hand the policy a store that still holds a
/// position, which is the only store state that can tell the invariant from its absence.
private func storedCheckpoint() throws -> PaneReplicaCheckpoint {
    var replica = PaneReplica()
    try replica.apply(.sync(PaneTapeSyncRecord(
        part: 1,
        parts: 1,
        bytes: Array("resume".utf8),
        columns: 8,
        rows: 2,
        pinned: false,
        cursor: PaneTapeCursor(
            recorderLifetimeId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            nextSequence: 12,
            feedBytesBeforeNextSequence: 40,
            writeBytesBeforeNextSequence: 0
        )
    )))
    return try #require(replica.checkpoint(
        for: PaneId(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    ))
}
