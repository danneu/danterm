// Tests the pure reconnect episode: target authority, cause classification, scheduling,
// and rest.
//
// Every test drives the episode with an explicit clock, so nothing here waits on real
// time. What is deliberately absent: anything about how an attempt is performed --
// the episode decides only when one runs.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

private let schedule = MobileReconnectEpisode.Schedule.standard
private let budget = schedule.delays.count
private let target = MobileServerTarget(host: "mac.example", port: 7420)

private func lostConnection() -> MobileConnectionFailure {
    .transport(.peerClosed)
}

@Test("Every terminal failure cause carries one retry class and one remedy")
func failureClassification() {
    // Intent: the two maps a failure feeds -- scheduling and presentation -- are both
    //   total over the typed causes.
    // Why it exists: a cause that reached either map unclassified would either spin
    //   against a condition retrying cannot change or present as nothing at all. The
    //   source switches carry no default, so a new cause fails to compile instead.
    let cases: [(MobileConnectionFailure, MobileRetryClass, MobileConnectionState)] = [
        (.transport(.unresolvedHost(host: "mac")), .manual, .hostNotFound),
        (.transport(.connectFailed(reason: "refused", target: "mac:9")),
         .transient, .serverUnreachable),
        (.transport(.connectTimedOut(target: "mac:9")),
         .transient, .serverUnreachable),
        (.transport(.configureFailed), .manual, .deviceSetupFailure),
        (.transport(.configureTimeoutFailed), .manual, .deviceSetupFailure),
        (.transport(.timedOut), .transient, .connectionLost),
        (.transport(.readFailed), .transient, .connectionLost),
        (.transport(.writeFailed), .transient, .connectionLost),
        (.transport(.peerClosed), .transient, .connectionLost),
        (.conversation(.cancelled, phase: .establishing), .manual, .disconnected),
        (.conversation(.closedBeforeHello, phase: .establishing), .transient, .connectionLost),
        (.conversation(.invalidHello, phase: .establishing), .manual, .connectionLost),
        (.conversation(.notAdmitted, phase: .establishing), .manual, .refusedByMac(.notAdmitted)),
        (.conversation(.identityUnresolved, phase: .establishing),
         .manual, .refusedByMac(.identityUnresolved)),
        (.conversation(.connectionLimit(.standard), phase: .establishing),
         .capacity(after: .standard), .refusedByMac(.connectionLimit)),
        (.conversation(.auditUnavailable, phase: .establishing),
         .manual, .refusedByMac(.auditUnavailable)),
        (.conversation(.unsupportedProtocol(7), phase: .establishing), .manual, .versionMismatch(7)),
        (.conversation(.oversizedLine, phase: .established), .manual, .connectionLost),
        (.conversation(.peerSilent, phase: .established), .transient, .connectionLost),
        (.streamEnded(reason: "paneClosed"), .manual, .streamEnded("paneClosed")),
        (.requestRefused(reason: "pane not found"), .manual, .requestRefused("pane not found")),
        (.deviceSetup, .manual, .deviceSetupFailure),
        (.streamDesynchronized, .transient, .streamDesynchronized),
    ]
    for (failure, expectedClass, expectedState) in cases {
        #expect(failure.retryClass == expectedClass)
        #expect(failure.state == expectedState)
    }
}

@Test("A capacity refusal that stated no bound falls back to the contract default")
func capacityClassWithoutStatedBound() {
    #expect(
        MobileConnectionFailure.conversation(.connectionLimit(nil), phase: .establishing).retryClass
            == .capacity(after: .standard)
    )
}

@Test("Causes that present alike are still scheduled apart")
func sharedStateDifferentClass() {
    // Intent: a malformed hello and a dropped stream both present "Connection lost", and
    //   only the dropped stream is worth retrying.
    // Why it exists: this pair is the reason classification reads the typed cause instead
    //   of the collapsed user-facing state.
    let malformed = MobileConnectionFailure.conversation(.invalidHello, phase: .establishing)
    let dropped = MobileConnectionFailure.transport(.readFailed)
    #expect(malformed.state == dropped.state)
    #expect(malformed.retryClass == .manual)
    #expect(dropped.retryClass == .transient)
}

@Test("Silence words differently by phase without changing its retry class")
func silencePhaseWording() {
    let establishing = MobileConnectionFailure.conversation(.peerSilent, phase: .establishing)
    let established = MobileConnectionFailure.conversation(.peerSilent, phase: .established)
    #expect(establishing.state == .serverUnreachable)
    #expect(established.state == .connectionLost)
    #expect(establishing.retryClass == .transient)
    #expect(established.retryClass == .transient)
}

@Test("A transient failure attempts again immediately")
func transientRetriesAtOnce() {
    var episode = reconnectEpisode()
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 100) == .attemptNow(target))
}

@Test("Every manual cause schedules nothing however long the clock runs")
func manualCausesNeverSchedule() {
    let manual: [MobileConnectionFailure] = [
        .transport(.unresolvedHost(host: "mac")),
        .transport(.configureFailed),
        .transport(.configureTimeoutFailed),
        .conversation(.cancelled, phase: .establishing),
        .conversation(.invalidHello, phase: .establishing),
        .conversation(.notAdmitted, phase: .establishing),
        .conversation(.identityUnresolved, phase: .establishing),
        .conversation(.auditUnavailable, phase: .establishing),
        .conversation(.unsupportedProtocol(7), phase: .establishing),
        .conversation(.oversizedLine, phase: .established),
        .streamEnded(reason: nil),
        .requestRefused(reason: "pane not found"),
        .deviceSetup,
    ]
    for failure in manual {
        var episode = reconnectEpisode()
        #expect(episode.handle(.attemptFailed(failure), at: 100) == .rest)
        for tick in stride(from: 200.0, through: 100_000.0, by: 9_900.0) {
            #expect(episode.handle(.clockFired, at: tick) == .rest)
        }
        #expect(episode.recoveryPhase(at: 100_000) == .none)
    }
}

@Test("A capacity refusal waits at least the bound that refusal carried")
func capacityWaitsTheCarriedBound() {
    // Intent: the first automatic attempt after a connection-limit refusal comes no
    //   earlier than the refusing server's own reclamation deadline.
    // Why it exists: retrying sooner competes for exactly the resource the refusal named,
    //   and the bound is the server's to state -- a nonstandard one must be honored.
    let stated = IpcLivenessBound(seconds: 45)!
    var episode = reconnectEpisode()
    let refusal = MobileConnectionFailure.conversation(
        .connectionLimit(stated),
        phase: .establishing
    )
    #expect(episode.handle(.attemptFailed(refusal), at: 100) == .wait(until: 145))
    #expect(episode.handle(.clockFired, at: 144) == .wait(until: 145))
    #expect(episode.handle(.clockFired, at: 145) == .attemptNow(target))
}

@Test("A capacity refusal without a stated bound waits the contract default")
func capacityWaitsTheDefaultBound() {
    var episode = reconnectEpisode()
    let refusal = MobileConnectionFailure.conversation(.connectionLimit(nil), phase: .establishing)
    #expect(
        episode.handle(.attemptFailed(refusal), at: 100)
            == .wait(until: 100 + IpcLivenessBound.standard.seconds)
    )
}

@Test("No automatic signal starts a capacity attempt before its earliest allowed time")
func signalsRespectTheCapacityFloor() {
    let stated = IpcLivenessBound(seconds: 45)!
    let refusal = MobileConnectionFailure.conversation(
        .connectionLimit(stated),
        phase: .establishing
    )
    var episode = reconnectEpisode()
    #expect(episode.handle(.attemptFailed(refusal), at: 100) == .wait(until: 145))
    #expect(episode.handle(.networkPathChanged(usable: false), at: 101) == .rest)
    #expect(episode.handle(.networkPathChanged(usable: true), at: 102) == .wait(until: 145))
    #expect(episode.handle(.appForegrounded, at: 103) == .wait(until: 145))
    #expect(episode.handle(.clockFired, at: 145) == .attemptNow(target))
}

@Test("A user gesture ignores the capacity floor because it is the manual remedy")
func gestureIgnoresTheCapacityFloor() {
    let stated = IpcLivenessBound(seconds: 45)!
    var episode = reconnectEpisode()
    let refusal = MobileConnectionFailure.conversation(
        .connectionLimit(stated),
        phase: .establishing
    )
    #expect(episode.handle(.attemptFailed(refusal), at: 100) == .wait(until: 145))
    #expect(episode.handle(.targetReused, at: 101) == .attemptNow(target))
}

@Test("Every manual gesture replaces an in-flight attempt with the active target")
func manualGesturesReplaceInFlightAttempts() {
    // Intent: a newly named target and a reused target both authorize complete replacement
    // attempts, while automatic signals still rest during the in-flight attempt.
    // Why it exists: the old episode treated manual and automatic triggers alike once an
    // attempt existed, so it rejected the user's remedy after target storage accepted it.
    let replacement = MobileServerTarget(host: "other.example", port: 9000)
    var episode = reconnectEpisode()

    #expect(episode.handle(.targetNamed(replacement), at: 1) == .attemptNow(replacement))
    #expect(episode.handle(.appForegrounded, at: 2) == .rest)
    #expect(episode.handle(.clockFired, at: 3) == .rest)
    #expect(episode.handle(.targetReused, at: 4) == .attemptNow(replacement))
}

@Test("Path facts observed without a target govern the first episode")
func idlePathFactsSurviveTheFirstTarget() {
    // Intent: an unusable path learned while targetless suspends recovery after the first
    //   manual attempt fails, and restoration retries the same target.
    // Why it exists: making the active episode optional must not discard facts that arrive
    //   before the user supplies the first server.
    var episode = MobileReconnectEpisode()
    #expect(episode.handle(.networkPathChanged(usable: false), at: 1) == .rest)
    #expect(episode.handle(.targetNamed(target), at: 2) == .attemptNow(target))
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 3) == .rest)
    #expect(episode.recoveryPhase(at: 3) == .waitingForNetwork)
    #expect(episode.handle(.networkPathChanged(usable: true), at: 4) == .attemptNow(target))
}

@Test("Delays grow across an episode and the budget is finite")
func boundedAutomaticPhase() {
    // Intent: repeated failure spends a finite number of automatic attempts and then rests.
    // Why it exists: an unbounded retry loop against a sleeping Mac drains the battery and
    //   makes "Reconnecting" a permanent hang-shaped state.
    var episode = reconnectEpisode()
    var now = 100.0
    for delay in schedule.delays {
        let decision = episode.handle(.attemptFailed(lostConnection()), at: now)
        if delay == 0 {
            #expect(decision == .attemptNow(target))
        } else {
            #expect(decision == .wait(until: now + delay))
            now += delay
            #expect(episode.handle(.clockFired, at: now) == .attemptNow(target))
        }
        now += 1
    }
    #expect(episode.handle(.attemptFailed(lostConnection()), at: now) == .rest)
    for tick in stride(from: now + 10, through: now + 100_000, by: 9_900) {
        #expect(episode.handle(.clockFired, at: tick) == .rest)
    }
    #expect(episode.recoveryPhase(at: now + 100_000) == .none)
}

@Test("A stream that keeps desynchronizing spends the one budget and then rests")
func desynchronizationUsesTheOneEpisodeBudget() {
    // Intent: a replica that detects a gap on every connection retries automatically, draws
    //   on the same episode budget as any other transient failure, and comes to rest with a
    //   manual remedy instead of looping.
    // Why it exists: routing the detected gap through this episode is what forbids a second,
    //   unbounded repair mechanism of its own. A desync after a connection that served long
    //   enough to prove stable is a rare incident, not accumulated evidence, so it starts a
    //   fresh episode.
    var episode = reconnectEpisode()
    var now = 100.0
    for delay in schedule.delays {
        let decision = episode.handle(.attemptFailed(.streamDesynchronized), at: now)
        if delay == 0 {
            #expect(decision == .attemptNow(target))
        } else {
            #expect(decision == .wait(until: now + delay))
            now += delay
            #expect(episode.handle(.clockFired, at: now) == .attemptNow(target))
        }
        now += 1
    }
    #expect(episode.handle(.attemptFailed(.streamDesynchronized), at: now) == .rest)
    #expect(episode.handle(.clockFired, at: now + 100_000) == .rest)
    #expect(episode.recoveryPhase(at: now + 100_000) == .none)

    var stable = reconnectEpisode()
    #expect(stable.handle(.targetReused, at: 100) == .attemptNow(target))
    #expect(stable.handle(.attemptConnected, at: 101) == .rest)
    let proven = 101 + schedule.stabilityWindow
    #expect(stable.handle(.attemptFailed(.streamDesynchronized), at: proven) == .attemptNow(target))
    #expect(stable.handle(.attemptFailed(.streamDesynchronized), at: proven + 1)
        == .wait(until: proven + 1 + schedule.delays[1]))
}

@Test("An automatic signal after give-up buys one attempt and no more")
func signalAfterGiveUpBuysOneAttempt() {
    // Intent: a restored path or a foreground return after give-up costs exactly one
    //   attempt, whose failure returns to rest with the budget still spent.
    // Why it exists: restoring the budget on a signal turns a flapping path into an
    //   endless retry loop, which is the defect the bounded phase exists to forbid.
    var episode = exhaustedEpisode(startingAt: 100)
    #expect(episode.handle(.networkPathChanged(usable: false), at: 500) == .rest)
    #expect(episode.handle(.networkPathChanged(usable: true), at: 501) == .attemptNow(target))
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 502) == .rest)
    #expect(episode.handle(.appForegrounded, at: 503) == .attemptNow(target))
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 504) == .rest)
    #expect(episode.handle(.clockFired, at: 900) == .rest)
}

@Test("A long run of signals after give-up buys one attempt each, forever")
func signalsAfterGiveUpNeverCompound() {
    // Intent: after give-up, any number of signal-then-failure rounds authorizes exactly
    //   one attempt per signal, and the episode never rests differently for having run
    //   longer.
    // Why it exists: the spent budget is what bounds a flapping path, and an episode that
    //   accumulated anything per post-give-up attempt would either drift or stop being
    //   safe after enough rounds. A long run is the only way to see that.
    var episode = exhaustedEpisode(startingAt: 100)
    var now = 500.0
    for _ in 0..<200 {
        #expect(episode.handle(.appForegrounded, at: now) == .attemptNow(target))
        #expect(episode.handle(.attemptFailed(lostConnection()), at: now + 1) == .rest)
        #expect(episode.handle(.clockFired, at: now + 2) == .rest)
        now += 10
    }
}

@Test("A user gesture restores the whole budget from a rested state")
func gestureRestoresTheBudget() {
    var episode = exhaustedEpisode(startingAt: 100)
    #expect(episode.handle(.targetReused, at: 500) == .attemptNow(target))
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 501) == .attemptNow(target))
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 502) == .wait(until: 504))
}

@Test("A connect-then-die flap still terminates at the budget")
func flapTerminatesAtTheBudget() {
    // Intent: a connection that comes up and dies again before proving stable does not
    //   refresh the attempt budget.
    // Why it exists: rearming on connect alone makes an unstable link retry forever with
    //   no user-visible progress.
    var episode = reconnectEpisode()
    var now = 100.0
    var attempts = 0
    while attempts < budget {
        let decision = episode.handle(.attemptFailed(lostConnection()), at: now)
        if case .wait(let until) = decision {
            now = until
            #expect(episode.handle(.clockFired, at: now) == .attemptNow(target))
        }
        attempts += 1
        #expect(episode.handle(.attemptConnected, at: now) == .rest)
        now += schedule.stabilityWindow / 2
    }
    #expect(episode.handle(.attemptFailed(lostConnection()), at: now) == .rest)
}

@Test("A connection that proves stable rearms the budget")
func stableConnectionRearmsTheBudget() {
    var episode = exhaustedEpisode(startingAt: 100)
    #expect(episode.handle(.targetReused, at: 500) == .attemptNow(target))
    #expect(episode.handle(.attemptConnected, at: 501) == .rest)
    let stable = 501 + schedule.stabilityWindow
    #expect(episode.handle(.attemptFailed(lostConnection()), at: stable) == .attemptNow(target))
    #expect(episode.handle(.attemptFailed(lostConnection()), at: stable + 1)
        == .wait(until: stable + 1 + schedule.delays[1]))
}

@Test("Backgrounding and cancel drop the pending attempt")
func restAfterBackgroundingAndCancel() {
    var backgrounded = reconnectEpisode()
    #expect(backgrounded.handle(.attemptFailed(lostConnection()), at: 100) == .attemptNow(target))
    #expect(backgrounded.handle(.attemptFailed(lostConnection()), at: 101) == .wait(until: 103))
    #expect(backgrounded.handle(.appBackgrounded, at: 102) == .rest)
    #expect(backgrounded.handle(.clockFired, at: 103) == .rest)
    #expect(backgrounded.recoveryPhase(at: 103) == .none)

    var cancelled = reconnectEpisode()
    #expect(cancelled.handle(.attemptFailed(lostConnection()), at: 100) == .attemptNow(target))
    #expect(cancelled.handle(.userCancelled, at: 101) == .rest)
    #expect(cancelled.handle(.clockFired, at: 500) == .rest)
    #expect(cancelled.handle(.networkPathChanged(usable: true), at: 501) == .rest)
    #expect(cancelled.handle(.targetReused, at: 502) == .attemptNow(target))
}

@Test("A connection dropped for backgrounding is owed again on return")
func backgroundingOwesTheConnectionItDropped() {
    // Intent: the app tears its own connection down on the way out, so returning to the
    //   foreground reconnects without a tap.
    // Why it exists: backgrounding is not a failure, so nothing else would leave an
    //   attempt owed, and the phone would come back to a dead pane until the user tapped.
    var connected = reconnectEpisode()
    #expect(connected.handle(.targetReused, at: 100) == .attemptNow(target))
    #expect(connected.handle(.attemptConnected, at: 101) == .rest)
    #expect(connected.handle(.appBackgrounded, at: 102) == .rest)
    #expect(connected.handle(.appForegrounded, at: 900) == .attemptNow(target))

    // An attempt still in flight is owed the same way: the shell cancelled it, so nothing
    // is going to report its outcome.
    var attempting = reconnectEpisode()
    #expect(attempting.handle(.targetReused, at: 100) == .attemptNow(target))
    #expect(attempting.handle(.appBackgrounded, at: 101) == .rest)
    #expect(attempting.handle(.appForegrounded, at: 102) == .attemptNow(target))
}

@Test("Backgrounding an idle episode leaves nothing owed")
func backgroundingWithoutAConnectionOwesNothing() {
    // Intent: the round trip through the background does not become a trigger of its own.
    // Why it exists: a manual-class rest must stay resting, and a give-up must not gain a
    //   free episode, just because the user switched apps and came back.
    var manual = reconnectEpisode()
    #expect(manual.handle(.attemptFailed(.conversation(.notAdmitted, phase: .establishing)), at: 100)
        == .rest)
    #expect(manual.handle(.appBackgrounded, at: 101) == .rest)
    #expect(manual.handle(.appForegrounded, at: 102) == .rest)

    var fresh = MobileReconnectEpisode()
    #expect(fresh.handle(.appBackgrounded, at: 100) == .rest)
    #expect(fresh.handle(.appForegrounded, at: 101) == .rest)
}

@Test("Foreground return during the automatic phase attempts at once")
func foregroundReturnAttempts() {
    var episode = reconnectEpisode()
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 100) == .attemptNow(target))
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 101) == .wait(until: 103))
    #expect(episode.handle(.appBackgrounded, at: 102) == .rest)
    #expect(episode.handle(.appForegrounded, at: 400) == .attemptNow(target))
}

@Test("The retry clock is suspended while no usable network path exists")
func clockSuspendedWithoutAPath() {
    // Intent: with no usable path, ticks spend no attempt and the phase says so; the path
    //   coming back is itself the trigger.
    // Why it exists: an attempt that cannot succeed is wasted battery, and a silent wait
    //   with no stated reason reads as a hang.
    var episode = reconnectEpisode()
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 100) == .attemptNow(target))
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 101) == .wait(until: 103))
    #expect(episode.handle(.networkPathChanged(usable: false), at: 102) == .rest)
    #expect(episode.recoveryPhase(at: 102) == .waitingForNetwork)
    for tick in stride(from: 103.0, through: 5_000.0, by: 100.0) {
        #expect(episode.handle(.clockFired, at: tick) == .rest)
    }
    #expect(episode.handle(.networkPathChanged(usable: true), at: 5_001) == .attemptNow(target))
    // The outage spent no attempt, so the episode resumes at the delay it was owed rather
    // than several steps further along a backoff the phone never actually tried.
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 5_002)
        == .wait(until: 5_002 + schedule.delays[2]))
}

@Test("A user gesture attempts even with no usable path")
func gestureAttemptsWithoutAPath() {
    var episode = reconnectEpisode()
    #expect(episode.handle(.networkPathChanged(usable: false), at: 100) == .rest)
    #expect(episode.handle(.targetReused, at: 101) == .attemptNow(target))
}

@Test("A manual-class rest answers only a user gesture")
func manualRestIgnoresAutomaticSignals() {
    var episode = reconnectEpisode()
    #expect(episode.handle(.attemptFailed(.conversation(.notAdmitted, phase: .establishing)), at: 100)
        == .rest)
    #expect(episode.handle(.networkPathChanged(usable: false), at: 101) == .rest)
    #expect(episode.handle(.networkPathChanged(usable: true), at: 102) == .rest)
    #expect(episode.handle(.appForegrounded, at: 103) == .rest)
    #expect(episode.handle(.clockFired, at: 104) == .rest)
    #expect(episode.recoveryPhase(at: 104) == .none)
    #expect(episode.handle(.targetReused, at: 105) == .attemptNow(target))
}

@Test("Automatic signals never overlap an attempt, while a manual gesture replaces it")
func onlyManualGesturesReplaceAnAttempt() {
    // Intent: no automatic trigger starts a second attempt while one is still in flight,
    //   but the user's gesture replaces that attempt immediately.
    // Why it exists: two concurrent attempts would race over the same stored resume
    //   cursor, which is the one thing the episode must not be able to disturb.
    var episode = reconnectEpisode()
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 100) == .attemptNow(target))
    #expect(episode.handle(.appForegrounded, at: 101) == .rest)
    #expect(episode.handle(.networkPathChanged(usable: true), at: 102) == .rest)
    #expect(episode.handle(.clockFired, at: 103) == .rest)
    #expect(episode.handle(.targetReused, at: 104) == .attemptNow(target))
    #expect(episode.recoveryPhase(at: 104) == .attempting)
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 105) == .attemptNow(target))
}

@Test("Every phase the episode occupies presents something other than a hang")
func recoveryPhaseIsAlwaysPresentable() {
    // Intent: over a full episode -- attempt, wait, outage, give-up -- the recovery phase
    //   always names what the app is doing, and give-up returns to the plain terminal rest.
    // Why it exists: the causal failure state stays visible throughout, so recovery has to
    //   decorate it rather than replace it with a state that never resolves.
    var episode = reconnectEpisode()
    #expect(episode.handle(.attemptConnected, at: 1) == .rest)
    #expect(episode.recoveryPhase(at: 99) == .none)
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 100) == .attemptNow(target))
    #expect(episode.recoveryPhase(at: 100) == .attempting)
    #expect(episode.handle(.attemptFailed(lostConnection()), at: 101) == .wait(until: 103))
    #expect(episode.recoveryPhase(at: 101) == .waiting(until: 103))
    #expect(episode.handle(.networkPathChanged(usable: false), at: 102) == .rest)
    #expect(episode.recoveryPhase(at: 102) == .waitingForNetwork)
    #expect(episode.handle(.networkPathChanged(usable: true), at: 103) == .attemptNow(target))
    #expect(episode.recoveryPhase(at: 103) == .attempting)
    #expect(episode.handle(.attemptConnected, at: 104) == .rest)
    #expect(episode.recoveryPhase(at: 104) == .none)
}

@Test("Give-up rests in the plain terminal state with no pending recovery")
func giveUpPresentsPlainRest() {
    let episode = exhaustedEpisode(startingAt: 100)
    #expect(episode.recoveryPhase(at: 1_000) == .none)
}

/// Drives the episode through its whole automatic budget so a test can start from rest.
private func exhaustedEpisode(startingAt start: TimeInterval) -> MobileReconnectEpisode {
    var episode = reconnectEpisode()
    var now = start
    for _ in 0..<budget {
        if case .wait(let until) = episode.handle(.attemptFailed(lostConnection()), at: now) {
            now = until
            _ = episode.handle(.clockFired, at: now)
        }
        now += 1
    }
    #expect(episode.handle(.attemptFailed(lostConnection()), at: now) == .rest)
    return episode
}

/// Starts an episode through the same target-bearing manual authorization production uses.
private func reconnectEpisode() -> MobileReconnectEpisode {
    var episode = MobileReconnectEpisode()
    #expect(episode.handle(.targetNamed(target), at: 0) == .attemptNow(target))
    return episode
}
