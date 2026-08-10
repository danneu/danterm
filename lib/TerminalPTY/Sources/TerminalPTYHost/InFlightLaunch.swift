// Rendezvous between a host that is quiescing and a launch not yet adopted by its
// owner queue. It spans both handoff windows: while `posix_spawn` has not reported
// a child, and after the worker resolves an outcome but before owner delivery.
//
// Its own file for the same reason ResizeCoalescer is: it is the submitting side
// of an ownership decision, held across a queue hop and read on the owner queue,
// and the one rule it encodes is what a reader has to check. Nothing else in the
// host needs it -- ordinary teardown waits for a launch through the lifecycle
// reducer -- so it stays out of the host's state machine.
import Darwin
import Dispatch
import Synchronization

/// One launch tracked across the spawn-queue hop so a quiescing host can wait for
/// a child that does not yet exist on its own queue.
///
/// One rule decides ownership, and it is what keeps a child from being both
/// adopted into a quiesced host and left running: the outcome stays here until
/// the owner consumes it. If exit wins first, the worker releases an outcome it
/// is still producing, while the host releases one already awaiting delivery.
///
/// The wait is deliberately unbounded. A bounded one would let the host report
/// quiescence while the worker was still live, which is the exact claim a
/// completion is supposed to make -- see `abandon`.
final class InFlightLaunch: Sendable {
    /// Resolution is a state machine rather than two reads, because `abandon`,
    /// worker completion, and owner delivery race. The outcome remains here until
    /// either the owner adopts it or abandonment releases it.
    private enum Phase {
        /// The worker is still launching, and nobody has given up on it.
        case launching
        /// The host gave up; the worker releases whatever it produces.
        case abandoned
        /// The worker is done, but the owner queue has not adopted the outcome.
        case available(PTYSpawnOutcome)
        /// The outcome was adopted or released; no launch ownership remains.
        case consumed
    }

    private struct State {
        var phase: Phase = .launching
        var launched: SpawnedPTY?
    }

    private let state = Mutex(State())
    /// Signalled exactly once, by `resolve`.
    private let workerFinished = DispatchSemaphore(value: 0)

    /// The child this launch produced, once it has reported one. Test-support: it
    /// is how a test names the process that must not outlive the host's completion,
    /// which a process-wide census cannot do while sibling suites launch children.
    var launchedLeader: pid_t? {
        state.withLock { $0.launched?.leader }
    }

    /// Test-support: whether the worker has produced an outcome that has not yet
    /// reached the owner queue.
    var hasPendingDelivery: Bool {
        state.withLock { state in
            if case .available = state.phase { return true }
            return false
        }
    }

    /// Called on the spawn queue the instant a child exists, before the bootstrap
    /// handshake. Returning `false` means the host has abandoned this launch, and
    /// the caller must release the child rather than keep launching it.
    ///
    /// The child is recorded either way: it is what lets an abandoning host kill a
    /// launch that only becomes visible while that host is already waiting.
    func reportLaunched(_ spawned: SpawnedPTY) -> Bool {
        state.withLock { state in
            state.launched = spawned
            switch state.phase {
            case .launching:
                return true
            case .abandoned:
                // Killed here as well as in `abandon`, which cannot have seen a
                // child that did not exist yet when it ran.
                _ = kill(spawned.leader, SIGKILL)
                return false
            case .available, .consumed:
                return false
            }
        }
    }

    /// Called on the spawn queue when the worker is done. Stores the outcome until
    /// the owner queue adopts it, unless abandonment already won and the worker
    /// must release it before signalling completion.
    ///
    /// Returns whether an owner-queue delivery should be submitted. The delivery
    /// must still call `takeOutcome`; abandonment can claim it in the meantime.
    func resolve(_ outcome: PTYSpawnOutcome) -> Bool {
        var abandonedSpawn: SpawnedPTY?
        let shouldDeliver = state.withLock { state in
            switch state.phase {
            case .launching:
                state.phase = .available(outcome)
                return true
            case .abandoned:
                state.phase = .consumed
                if case .success(let spawned) = outcome {
                    abandonedSpawn = spawned
                }
                return false
            case .available, .consumed:
                return false
            }
        }
        if let spawned = abandonedSpawn {
            PTYSpawner.discard(spawned)
        }
        workerFinished.signal()
        return shouldDeliver
    }

    /// Transfers a resolved outcome to the owner queue. Returns `nil` when exit
    /// claimed and released the outcome before its queued delivery could run.
    func takeOutcome() -> PTYSpawnOutcome? {
        state.withLock { state in
            guard case .available(let outcome) = state.phase else { return nil }
            state.phase = .consumed
            return outcome
        }
    }

    /// Called on the owner queue when the host has to quiesce before adopting this
    /// launch. Kills a child still owned by the worker and waits for that worker,
    /// or directly releases an outcome already awaiting delivery.
    ///
    /// The wait has no bound, and that is the deliberate trade. `posix_spawn` is
    /// uninterruptible, so no bound the host could set would be enforceable: a
    /// deadline here would only let quiescence be *reported* on time while a child
    /// was still arriving, which is precisely the guarantee a completion exists to
    /// make. Exit is therefore as bounded as the kernel's launch is, and no more.
    func abandon() {
        enum Action {
            case waitForWorker
            case discard(SpawnedPTY)
            case done
        }
        let action = state.withLock { state in
            switch state.phase {
            case .launching:
                state.phase = .abandoned
                if let launched = state.launched {
                    _ = kill(launched.leader, SIGKILL)
                }
                return Action.waitForWorker
            case .abandoned:
                return Action.waitForWorker
            case .available(let outcome):
                state.phase = .consumed
                if case .success(let spawned) = outcome {
                    return Action.discard(spawned)
                }
                return Action.done
            case .consumed:
                return Action.done
            }
        }
        switch action {
        case .waitForWorker:
            workerFinished.wait()
        case .discard(let spawned):
            PTYSpawner.discard(spawned)
        case .done:
            break
        }
    }
}
