// Async adapters for tests that wait on TerminalPTYHost's dispatch callback surface.
//
// The output waits here are the reason this file is more than glue: a test asks "did the
// child print this?", but a host cannot retain unbounded output to answer it. The rule
// this file enforces is that every such wait is either matched incrementally from the
// moment it is armed -- which no volume of later output can defeat -- or reported as
// unanswerable at once. It never suspends on a question whose answer was discarded.
import Dispatch
import PaneLifecycle
import Synchronization
import Testing
import TerminalPTYHost

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
    nonisolated func waitForResult() async -> PaneLifecycleResult? {
        let waiter = CallbackWaiter<PaneLifecycleResult?>()
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

    // The output waits are debug-only because the evidence they read is: the host retains
    // its lookback under `#if DEBUG` so a shipping build pays nothing per PTY read. This
    // target is a plain library target, not a test target, so a release build compiles it
    // -- gating only the host side would leave `swift build -c release` unable to resolve
    // `observeTestOutput`. Test targets always build debug, so nothing is lost here.
    #if DEBUG

    /// Arms a match on the child's output now, to be awaited whenever the test is ready.
    ///
    /// Arm this before the output that would bury the answer -- a flooding child, a long
    /// scrollback replay -- and no amount of it can defeat the match: from this call on the
    /// bytes are matched as they stream, and only the partial match is kept. Everything the
    /// host still retains is matched first, so a child that printed and exited before this
    /// call is answered too.
    ///
    /// The cost of that guarantee, and the thing to know before writing a wait: if the host
    /// has discarded ANY output and the needle is not in what it still retains, this fails
    /// immediately -- even when the child is about to print the needle a moment from now and
    /// matching from here would have caught it. The check cannot tell those two cases apart,
    /// because whether the needle was in the discarded bytes is exactly what was discarded.
    /// So "flood, then wait for a new marker" fails; arm before the flood instead.
    ///
    /// That is deliberately stricter than necessary. The alternative -- match forward and
    /// stay silent -- is indistinguishable from the bug this replaced for the case that
    /// matters, a live pane that never quiesces, where staying silent means suspending until
    /// the test's time limit and then blaming the wait instead of the discard. A false
    /// failure that names its own remedy costs a test author a minute; that hang cost a
    /// green CI run an hour and pointed at the wrong line.
    nonisolated func expectOutput(
        containing bytes: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> TerminalPTYOutputExpectation {
        guard bytes.isEmpty == false else { return .init(waiter: .completed(true)) }
        let matcher = OutputMatcher(needle: bytes)
        let waiter = CallbackWaiter<Bool>()
        // Retained evidence first, then every later chunk, in one owner transaction with no
        // gap between them -- so the matcher sees the child's output as one ordered stream.
        let discardedByteCount = observeTestOutput { chunk in
            guard matcher.consume(chunk) else { return true }
            waiter.complete(with: true)
            return false
        }
        if matcher.hasMatched {
            return .init(waiter: waiter)
        }
        guard discardedByteCount == 0 else {
            // Loud and immediate, because the alternative is a wait that cannot be
            // satisfied by anything the child does next and would simply never return.
            Issue.record(
                """
                Cannot tell whether this pane printed \(matcher.renderedNeedle): the host \
                has already discarded \(discardedByteCount) bytes of output past its \
                bounded test window, so the answer may have streamed by before this wait \
                was armed. Arm the match before the output that buries it -- \
                `expectOutput(containing:)` returns an armed match to await later -- or \
                wait on evidence a bounded window cannot lose.
                """,
                sourceLocation: sourceLocation
            )
            waiter.complete(with: false)
            return .init(waiter: waiter)
        }
        // Fallback last: a host that has already torn down answers `false` here, and it must
        // not get to do so before the evidence above has had its say.
        whenQuiescent {
            waiter.complete(with: false)
        }
        return .init(waiter: waiter)
    }

    /// Arms a match on the child's output and waits for it, keeping cancellation test-local.
    ///
    /// Correct when the wait is armed before the output it asks about, which is the ordinary
    /// case: the child prints a marker and the test waits for it. If output the host cannot
    /// still retain may already have gone by -- anything past a flooding child, a big paste,
    /// a scrollback replay -- this fails rather than answering; arm with `expectOutput` first
    /// and await the result later. See `expectOutput` for why that case fails loudly instead
    /// of matching forward.
    nonisolated func waitForOutput(
        containing bytes: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await expectOutput(containing: bytes, sourceLocation: sourceLocation).satisfied()
    }

    /// Blocks a non-host queue on callback wakeups so a test can keep main deliberately stalled.
    ///
    /// Carries `waitForOutput`'s discard rule -- see it and `expectOutput` before waiting on
    /// a marker that a busy host may already have discarded.
    nonisolated func waitForOutputSynchronously(
        containing bytes: [UInt8],
        timeout: DispatchTimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        expectOutput(containing: bytes, sourceLocation: sourceLocation)
            .satisfied(within: timeout)
    }

    #endif

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

/// A match armed on one host's output, awaited whenever the test is ready for the answer.
///
/// Arming and waiting are separate values precisely so they can happen at different times:
/// the guarantee is anchored to the moment of arming, and a test that must produce output
/// before it can wait keeps that guarantee by arming first.
public struct TerminalPTYOutputExpectation: Sendable {
    private let waiter: CallbackWaiter<Bool>

    fileprivate init(waiter: CallbackWaiter<Bool>) {
        self.waiter = waiter
    }

    /// Waits for the match, reporting `false` on host quiescence or task cancellation.
    public func satisfied() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter.install($0) }
        } onCancel: {
            waiter.complete(with: false)
        }
    }

    /// Blocks the calling thread for the match, for tests that must keep main stalled.
    public func satisfied(within timeout: DispatchTimeInterval) -> Bool {
        let wakeup = DispatchSemaphore(value: 0)
        waiter.signal(wakeup)
        _ = wakeup.wait(timeout: .now() + timeout)
        return waiter.completedValue ?? false
    }
}

/// Streaming subsequence match: sticky once matched, and between chunks it keeps only the
/// bytes that could still begin an occurrence.
///
/// Retention is `needle.count - 1` bytes, whatever the child writes. That bound is the
/// point -- it is what lets a wait outlive an unbounded flood without retaining it.
private final class OutputMatcher: Sendable {
    private struct Progress {
        var carry: [UInt8] = []
        var matched = false
    }

    private let needle: [UInt8]
    private let progress = Mutex(Progress())

    init(needle: [UInt8]) {
        self.needle = needle
    }

    var hasMatched: Bool { progress.withLock(\.matched) }

    /// Consumes the next chunk of the stream and reports whether the needle has now appeared.
    func consume(_ chunk: [UInt8]) -> Bool {
        progress.withLock { progress in
            guard progress.matched == false else { return true }
            var window = progress.carry
            window.append(contentsOf: chunk)
            if window.containsSubsequence(needle) {
                progress.matched = true
                progress.carry = []
                return true
            }
            progress.carry = window.count >= needle.count
                ? Array(window.suffix(needle.count - 1))
                : window
            return false
        }
    }

    /// Renders the needle for a failure message, since markers routinely carry control bytes.
    var renderedNeedle: String {
        var rendered = ""
        for byte in needle.prefix(32) {
            if byte >= 0x20, byte < 0x7F {
                rendered.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                rendered += "\\x\(String(byte, radix: 16))"
            }
        }
        if needle.count > 32 { rendered += "..." }
        return "\"\(rendered)\" (\(needle.count) bytes)"
    }
}

/// One-shot answer shared by a callback that produces it and any number of waiters,
/// whichever arrives first. Waiters may be async continuations or blocked threads.
private final class CallbackWaiter<Value: Sendable>: Sendable {
    private enum Waiter {
        case continuation(CheckedContinuation<Value, Never>)
        case semaphore(DispatchSemaphore)
    }

    private enum State {
        case pending([Waiter])
        case completed(Value)
    }

    private let state = Mutex<State>(.pending([]))

    /// A waiter for a value that is already known, for callers with nothing to observe.
    static func completed(_ value: Value) -> CallbackWaiter<Value> {
        let waiter = CallbackWaiter<Value>()
        waiter.complete(with: value)
        return waiter
    }

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

private extension Array where Element == UInt8 {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard needle.isEmpty == false, needle.count <= count else { return false }
        return indices.dropLast(needle.count - 1).contains { start in
            self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}
