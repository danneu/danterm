// Tests whether the next attempt may read the position that the replica stored.
//
// Nothing here touches the checkpoint store. The policy decides whether a read is useful
// before the shell opens the file, so its answer cannot depend on what the store holds.
import DanTermMobileKit
import Testing

@Test("Only a desynchronized stream discredits the position the replica stored")
func resumeAcrossTheFailureVocabulary() {
    // Intent: every failure but the detected gap leaves the stored position trustworthy, so
    //   the reconnect stays exact; the detected gap alone forces a fresh start.
    // Why it exists: a detected gap can be caused by the very position the stream resumed
    //   from, so an attempt that resumes there reproduces the disagreement and the retry
    //   budget only bounds how many times it does. Every other failure has nothing to do
    //   with the position, and discarding it there would cost the user scrollback.
    let vocabulary: [(failure: MobileConnectionFailure, trustsStoredPosition: Bool)] = [
        (.transport(.unresolvedHost(host: "mac")), true),
        (.transport(.connectFailed(reason: "refused", target: "mac:9")), true),
        (.transport(.connectTimedOut(target: "mac:9")), true),
        (.transport(.configureFailed), true),
        (.transport(.configureTimeoutFailed), true),
        (.transport(.timedOut), true),
        (.transport(.readFailed), true),
        (.transport(.writeFailed), true),
        (.transport(.peerClosed), true),
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
    for (failure, trustsStoredPosition) in vocabulary {
        var policy = MobileResumePolicy()
        policy.connectionEnded(with: failure)
        #expect(policy.trustsStoredPosition == trustsStoredPosition)
    }
}

@Test("A fresh policy trusts the stored position")
func freshPolicyTrustsStoredPosition() {
    let policy = MobileResumePolicy()
    #expect(policy.trustsStoredPosition)
}

@Test("The disputed position remains untrusted without an exact replica")
func refusalSurvivesUntilTheReplicaIsExact() {
    // Intent: after a detected gap the attempt starts fresh even though the checkpoint file
    //   still carries the disputed cursor.
    // Why it exists: the checkpoint is saved asynchronously from a snapshot taken before the
    //   save runs, so a save already in flight lands after the failure. Deleting the file
    //   cannot win that race; refusing the position at the moment an attempt asks has no
    //   race to lose.
    var policy = MobileResumePolicy()
    policy.connectionEnded(with: .streamDesynchronized)
    #expect(policy.trustsStoredPosition == false)
}

@Test("The refusal outlives the one attempt that follows it")
func refusalOutlivesOneAttempt() {
    // Intent: a detected gap, then an attempt that starts fresh and drops before the
    //   replacement state arrives, still leaves the next attempt starting fresh.
    // Why it exists: that failed attempt saved nothing, so the disputed cursor is still the
    //   newest position on disk. A refusal spent by the first attempt would hand it straight
    //   back, and the retry would reproduce the disagreement it was meant to escape.
    var policy = MobileResumePolicy()
    policy.connectionEnded(with: .streamDesynchronized)
    policy.connectionEnded(with: .transport(.peerClosed))
    #expect(policy.trustsStoredPosition == false)

    // Exact state is what makes a stored position trustworthy again, so it is what ends the
    // refusal -- and a later ordinary drop keeps the position it left behind.
    policy.replicaBecameExact()
    #expect(policy.trustsStoredPosition)
    policy.connectionEnded(with: .transport(.peerClosed))
    #expect(policy.trustsStoredPosition)
}
