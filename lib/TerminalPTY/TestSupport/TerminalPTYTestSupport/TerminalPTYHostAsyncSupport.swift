// Async adapters for tests that wait on TerminalPTYHost's dispatch callback surface.
//
// These are the waits that read the host's callbacks: update signals, the reported lifecycle
// result, polled snapshots, and shutdown. Waits on the child's output read the pane's flight
// tape instead and live in `TerminalPTYOutputWait.swift`.
import Dispatch
import PaneProcessLifecycle
import Synchronization
import Testing
import TerminalPTYHost
import TerminalPTYWaitSupport

public extension TerminalPTYHost {
    /// Recreates the former conflated update stream outside production ownership code.
    nonisolated var updates: AsyncStream<Void> {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let initial = setTestUpdateHandler { _ in
            channel.continuation.yield()
        }
        if initial.hasEmittedUpdate {
            channel.continuation.yield()
        }
        whenQuiescent {
            channel.continuation.finish()
        }
        return channel.stream
    }

    /// Waits for the first reported result while keeping task cancellation test-local.
    nonisolated func waitForResult() async -> PaneProcessLifecycleResult? {
        let waiter = CallbackWaiter<PaneProcessLifecycleResult?>()
        let initial = setTestUpdateHandler { result in
            if let result {
                waiter.complete(with: result)
            }
        }
        // Evidence first, fallback second. `whenQuiescent` runs its observer on the host
        // queue -- immediately, when teardown already finished -- so arming it before
        // consulting `initial` races the fallback against the answer we were just handed
        // and can report absence for a result the host has already reported.
        if let result = initial.result {
            waiter.complete(with: result)
        }
        whenQuiescent {
            waiter.complete(with: nil)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                waiter.install($0)
            }
        } onCancel: {
            waiter.complete(with: nil)
        }
    }

    /// Polls fenced snapshots until `predicate` holds, and reports whether it did.
    ///
    /// For the questions the output waits above cannot answer -- anything about
    /// parsed terminal state rather than about bytes the child printed.
    ///
    /// Sleeps between samples instead of spinning on `Task.yield()`. A yield loop
    /// competes with the very work it waits for, so on a loaded machine it makes
    /// its own wait longer, and several such loops running at once is a suite that
    /// starves itself. Worse, a yield loop cannot be unwound: `Task.yield()` does
    /// not throw on cancellation, so a test's `.timeLimit` has nothing to interrupt
    /// and a state that never arrives becomes a process spinning at full CPU that
    /// something outside the run has to kill. Returning a Bool makes that same
    /// case an ordinary failed expectation with a name attached.
    nonisolated func waitForSnapshot(
        within limit: Duration = .seconds(30),
        where predicate: @Sendable (TerminalPTYHost) -> Bool
    ) async -> Bool {
        await pollUntil({ predicate(self) }, within: limit)
    }

    /// Requests shutdown and suspends only test code until the host reports quiescence.
    ///
    /// Names its own failure. The host arms an exit bound of its own, so a shutdown
    /// that never completes is a bug in that bound rather than an ordinary wait --
    /// and the wait that hid it reported nothing: it suspended until the test's time
    /// limit, which then blamed the limit and left the test looking merely slow.
    nonisolated func close(
        within limit: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let closed = Mutex(false)
        requestShutdown { closed.withLock { $0 = true } }
        guard await pollUntil({ closed.withLock { $0 } }, within: limit) else {
            Issue.record(
                "the host did not report quiescence within \(limit) of the shutdown request",
                sourceLocation: sourceLocation
            )
            return
        }
    }
}

/// One-shot answer shared by a callback that produces it and any number of waiters,
/// whichever arrives first. Waiters may be async continuations or blocked threads.
final class CallbackWaiter<Value: Sendable>: Sendable {
    private enum Waiter {
        case continuation(CheckedContinuation<Value, Never>)
        case semaphore(DispatchSemaphore)
    }

    private enum State {
        case pending([Waiter])
        case completed(Value)
    }

    private let state = Mutex<State>(.pending([]))

    var completedValue: Value? {
        state.withLock { state in
            guard case .completed(let value) = state else { return nil }
            return value
        }
    }

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        guard let value = enqueue(.continuation(continuation)) else { return }
        continuation.resume(returning: value)
    }

    func signal(_ semaphore: DispatchSemaphore) {
        guard enqueue(.semaphore(semaphore)) != nil else { return }
        semaphore.signal()
    }

    func complete(with value: Value) {
        let waiters: [Waiter] = state.withLock { state in
            guard case .pending(let waiters) = state else { return [] }
            state = .completed(value)
            return waiters
        }
        for waiter in waiters { resume(waiter, with: value) }
    }

    /// Returns the answer when one already exists, otherwise parks the waiter.
    private func enqueue(_ waiter: Waiter) -> Value? {
        state.withLock { state in
            switch state {
            case .pending(let waiters):
                state = .pending(waiters + [waiter])
                return nil
            case .completed(let value):
                return value
            }
        }
    }

    private func resume(_ waiter: Waiter, with value: Value) {
        switch waiter {
        case .continuation(let continuation): continuation.resume(returning: value)
        case .semaphore(let semaphore): semaphore.signal()
        }
    }
}
