// Async adapters for tests that wait on TerminalPTYHost's dispatch callback surface.
import Dispatch
import PaneLifecycle
import Synchronization
import TerminalPTYHost

public extension TerminalPTYHost {
    /// Recreates the former conflated update stream outside production ownership code.
    nonisolated var updates: AsyncStream<Void> {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let initial = setTestUpdateHandler { _, _ in
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
    nonisolated func waitForResult() async -> PaneLifecycleResult? {
        let waiter = CallbackWaiter<PaneLifecycleResult?>()
        let initial = setTestUpdateHandler { _, result in
            if let result {
                waiter.complete(with: result)
            }
        }
        whenQuiescent {
            waiter.complete(with: nil)
        }
        if let result = initial.result {
            waiter.complete(with: result)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                waiter.install($0)
            }
        } onCancel: {
            waiter.complete(with: nil)
        }
    }

    /// Waits on update callbacks until retained output contains the requested bytes.
    nonisolated func waitForOutput(containing bytes: [UInt8]) async -> Bool {
        guard bytes.isEmpty == false else { return true }
        let waiter = CallbackWaiter<Bool>()
        let initial = setTestOutputHandler { output in
            if output.containsSubsequence(bytes) {
                waiter.complete(with: true)
            }
        }
        whenQuiescent {
            waiter.complete(with: false)
        }
        if initial.containsSubsequence(bytes) {
            waiter.complete(with: true)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                waiter.install($0)
            }
        } onCancel: {
            waiter.complete(with: false)
        }
    }

    /// Blocks a non-host queue on callback wakeups so a test can keep main deliberately stalled.
    nonisolated func waitForOutputSynchronously(
        containing bytes: [UInt8],
        timeout: DispatchTimeInterval
    ) -> Bool {
        guard bytes.isEmpty == false else { return true }
        let wakeup = DispatchSemaphore(value: 0)
        _ = setTestOutputHandler { _ in
            wakeup.signal()
        }
        if observedOutputContains(bytes) { return true }
        let deadline = DispatchTime.now() + timeout
        while wakeup.wait(timeout: deadline) == .success {
            if observedOutputContains(bytes) { return true }
        }
        return observedOutputContains(bytes)
    }

    /// Requests shutdown and suspends only test code until the host reports quiescence.
    nonisolated func close() async {
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        requestShutdown {
            completion.continuation.yield()
            completion.continuation.finish()
        }
        for await _ in completion.stream {
            return
        }
    }
}

private final class CallbackWaiter<Value: Sendable>: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Value, Never>)
        case completed(Value)
    }

    private enum Action {
        case none
        case resume(CheckedContinuation<Value, Never>, Value)
    }

    private let state = Mutex<State>(.pending)

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        let action = state.withLock { state in
            switch state {
            case .pending:
                state = .waiting(continuation)
                return Action.none
            case .waiting:
                return Action.none
            case .completed(let value):
                return .resume(continuation, value)
            }
        }
        if case .resume(let continuation, let value) = action {
            continuation.resume(returning: value)
        }
    }

    func complete(with value: Value) {
        let action = state.withLock { state in
            switch state {
            case .pending:
                state = .completed(value)
                return Action.none
            case .waiting(let continuation):
                state = .completed(value)
                return .resume(continuation, value)
            case .completed:
                return Action.none
            }
        }
        if case .resume(let continuation, let value) = action {
            continuation.resume(returning: value)
        }
    }
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard needle.isEmpty == false, needle.count <= count else { return false }
        return indices.dropLast(needle.count - 1).contains { start in
            self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}
