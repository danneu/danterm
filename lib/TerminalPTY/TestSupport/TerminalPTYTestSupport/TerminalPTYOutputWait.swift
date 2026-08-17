// Test-support waits on a pane's child output, read from the pane's own flight recorder.
//
// A test asks "did the child print this?", and the host retains nothing whose only purpose is
// to answer that. The one retention on the read path is the flight tape, which production
// already records for pane-tape streaming, and which already offers a cursor, an append
// notice, and an atomically rearming suffix read. Everything here is built on those: arm at
// the tape's backlog cursor, then take a fresh suffix on every notice, so a wait adds nothing
// to production at all.
//
// What does not belong in this file: any retention, delivery, or observation mechanism added
// to the host or the recorder for a test's benefit. The tape is the seam, and reading it is
// the whole mechanism.
import Dispatch
import Foundation
import Synchronization
import Testing
import TerminalCoreRecording
import TerminalPTYHost

public extension TerminalPTYHost {
    /// Arms a match on the child's output now, to be awaited whenever the test is ready.
    ///
    /// Arm this before the output that would bury the answer -- a flooding child, a long
    /// scrollback replay -- and from this call on the bytes are matched as they stream, so
    /// neither the volume in between nor a read boundary inside the marker can lose it. Output
    /// the tape still retains is matched first, so a child that printed and exited before this
    /// call is answered too.
    ///
    /// The bound to know before writing a wait: the evidence is the pane's flight tape, which
    /// is large but finite. If the answer may lie in output the tape can no longer produce --
    /// because it was evicted before the wait was armed, or because a flood outran a live wait
    /// -- this resolves at once as a recorded issue naming the loss and the remedy that fits
    /// it. It never stays silent about output it cannot see: on a live pane that never
    /// quiesces, silence means suspending until the test's time limit and then blaming the
    /// wait instead of the loss.
    nonisolated func expectOutput(
        containing bytes: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> TerminalPTYOutputExpectation {
        let wait = TapeOutputWait(host: self, needle: bytes, sourceLocation: sourceLocation)
        wait.arm()
        return TerminalPTYOutputExpectation(wait: wait)
    }

    /// Arms a match on the child's output and waits for it, keeping cancellation test-local.
    ///
    /// Correct when the wait is armed before the output it asks about, which is the ordinary
    /// case: the child prints a marker and the test waits for it. If output the tape can no
    /// longer produce may already have gone by -- anything past a flooding child on a small
    /// tape -- this fails rather than answering; arm with `expectOutput` first and await the
    /// result later. See `expectOutput` for why that case fails loudly instead of matching
    /// forward.
    nonisolated func waitForOutput(
        containing bytes: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await expectOutput(containing: bytes, sourceLocation: sourceLocation).satisfied()
    }

    /// Blocks a non-host queue on the match so a test can keep main deliberately stalled.
    ///
    /// Carries `waitForOutput`'s loss rule -- see it and `expectOutput` before waiting on a
    /// marker a busy pane may already have evicted from its tape.
    nonisolated func waitForOutputSynchronously(
        containing bytes: [UInt8],
        timeout: DispatchTimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        expectOutput(containing: bytes, sourceLocation: sourceLocation)
            .satisfied(within: timeout)
    }
}

/// A match armed on one host's output, awaited whenever the test is ready for the answer.
///
/// Arming and waiting are separate values precisely so they can happen at different times:
/// the guarantee is anchored to the moment of arming, and a test that must produce output
/// before it can wait keeps that guarantee by arming first.
public struct TerminalPTYOutputExpectation: Sendable {
    private let wait: TapeOutputWait

    init(wait: TapeOutputWait) {
        self.wait = wait
    }

    /// Names the recorder subscription this wait holds while it is live, so a test can prove
    /// the wait gave the subscription up when it reached a terminal outcome.
    public var subscriptionId: UUID { wait.subscriptionId }

    /// Waits for the match, reporting `false` on host quiescence or task cancellation.
    public func satisfied() async -> Bool {
        let matched = await withTaskCancellationHandler {
            await withCheckedContinuation { wait.install($0) }
        } onCancel: {
            wait.giveUp()
        }
        wait.reportLossIfNeeded()
        return matched
    }

    /// Blocks the calling thread for the match, for tests that must keep main stalled.
    public func satisfied(within timeout: DispatchTimeInterval) -> Bool {
        let matched = wait.blockUntilAnswered(within: timeout)
        wait.reportLossIfNeeded()
        return matched
    }
}

/// One armed output wait: its recorder subscription, its serialized suffix reads, and the
/// one-shot answer every waiter of it shares.
///
/// A class because the append notice the recorder holds is the host's only reference to the
/// wait, so giving the subscription up is exactly what releases everything the wait captured.
final class TapeOutputWait: Sendable {
    /// Which of the two losses happened, because they are different failures with different
    /// remedies: one is output that was gone before the wait existed, the other is output that
    /// outran a wait already watching for it.
    private enum Loss {
        case beforeArming(feedBytes: Int)
        case whileArmed(feedBytes: Int)
    }

    private struct State {
        /// Where the next suffix read starts. Only ever advances, which is what makes the
        /// stream gapless by construction rather than by fence discipline.
        var cursor: TerminalFlightRecordingCursor = .beginning
        var hasReadSuffix = false
        var isSubscribed = false
        var isFinished = false
        var loss: Loss?
        var hasReportedLoss = false
    }

    let subscriptionId = UUID()
    private let host: TerminalPTYHost
    private let needle: [UInt8]
    private let sourceLocation: SourceLocation
    private let matcher: OutputMatcher
    private let waiter: CallbackWaiter<Bool>
    /// Serializes every suffix read of this wait -- the arming read and each notice-driven one
    /// -- so its cursor advances monotonically and no event is read twice or skipped. Also
    /// where the wait detaches, because a notice and a quiescence report both arrive on the
    /// host queue, and fencing the host from there would deadlock the wait.
    private let reads: DispatchQueue
    private let state = Mutex(State())

    init(host: TerminalPTYHost, needle: [UInt8], sourceLocation: SourceLocation) {
        self.host = host
        self.needle = needle
        self.sourceLocation = sourceLocation
        matcher = OutputMatcher(needle: needle)
        waiter = CallbackWaiter<Bool>()
        reads = DispatchQueue(label: "com.danneu.danterm.terminal-pty-output-wait")
    }

    /// Subscribes at the tape's backlog cursor, so the output the tape still retains is simply
    /// this wait's first suffix read and the join to later chunks needs no special case.
    func arm() {
        guard needle.isEmpty == false else {
            finish(matched: true)
            return
        }
        state.withLock { $0.isSubscribed = true }
        // Fires synchronously, on the host queue, whenever the tape already holds an event, so
        // the notice may only hop -- never read.
        host.addFlightRecordingFollowNotice(id: subscriptionId, from: .beginning) { [self] in
            reads.async { self.drain() }
        }
        // The retained read is taken here rather than left to that notice so that a loss it
        // finds is recorded from the arming test's own task, where `Issue.record` has a test
        // to attach to.
        reads.sync { drain() }
        reportLossIfNeeded()
        guard state.withLock(\.isFinished) == false else { return }
        // Fallback last: a host that has already torn down answers `false` here, and it must
        // not get to do so before the retained output above has had its say.
        //
        // Weakly, because the host keeps its quiescence observers until it quiesces and the
        // subscription is what should decide how long the host holds this wait. A wait still
        // armed is held by its own notice, so the reference resolves for every wait this
        // fallback has to answer, and a finished one whose test has moved on stays collectable.
        host.whenQuiescent { [weak self] in
            guard let self else { return }
            reads.async { self.finish(matched: false) }
        }
    }

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        waiter.install(continuation)
    }

    /// Abandons the wait, for a cancelled task or a blocking waiter that ran out of time.
    func giveUp() {
        reads.async { [self] in finish(matched: false) }
    }

    func blockUntilAnswered(within timeout: DispatchTimeInterval) -> Bool {
        let wakeup = DispatchSemaphore(value: 0)
        waiter.signal(wakeup)
        _ = wakeup.wait(timeout: .now() + timeout)
        let matched = waiter.completedValue ?? false
        // Nothing will look at this wait again, whether it timed out or was answered.
        giveUp()
        return matched
    }

    /// Records a loss exactly once, and from a test's own task rather than from the queue that
    /// discovered it -- `Issue.record` needs a current test, and a notice-driven read has none.
    func reportLossIfNeeded() {
        let loss: Loss? = state.withLock { state in
            guard let loss = state.loss, state.hasReportedLoss == false else { return nil }
            state.hasReportedLoss = true
            return loss
        }
        guard let loss else { return }
        switch loss {
        case .beforeArming(let feedBytes):
            Issue.record(
                """
                Cannot tell whether this pane printed \(matcher.renderedNeedle): \(feedBytes) \
                bytes of its output are already off the pane's flight tape, so the answer may \
                have streamed by before this wait was armed. Arm the match before the output \
                that buries it -- `expectOutput(containing:)` returns an armed match to await \
                later -- or wait on evidence a bounded tape cannot lose, such as \
                `waitForSnapshot`.
                """,
                sourceLocation: sourceLocation
            )
        case .whileArmed(let feedBytes):
            Issue.record(
                """
                Cannot tell whether this pane printed \(matcher.renderedNeedle): this wait was \
                armed in time, but the pane outran it and the flight tape evicted \(feedBytes) \
                bytes of output before the wait could read them. Build the host with a \
                `flightTapeConfiguration` whose retention covers the output this wait has to \
                read through.
                """,
                sourceLocation: sourceLocation
            )
        }
    }

    /// Reads the next tape suffix and matches the child output in it against the needle.
    ///
    /// Runs only on `reads`, so reading the cursor, fencing the host, and advancing the cursor
    /// are one transaction against every other read this wait makes.
    private func drain() {
        let position: (cursor: TerminalFlightRecordingCursor, isFirstRead: Bool)? = state
            .withLock { state in
                guard state.isFinished == false else { return nil }
                let isFirstRead = state.hasReadSuffix == false
                state.hasReadSuffix = true
                return (state.cursor, isFirstRead)
            }
        guard let position else { return }
        guard let snapshot = host.fencedFlightRecordingFollowSnapshot(
            subscriptionId: subscriptionId,
            from: position.cursor
        ) else { return }
        // A gap is a hard boundary. Matching progress from before it can never be joined to
        // bytes after it, so a needle whose halves straddle the gap must not match -- the wait
        // reports the loss instead of continuing through it.
        guard snapshot.droppedFeedBytes == 0 else {
            state.withLock { state in
                state.loss = position.isFirstRead
                    ? .beforeArming(feedBytes: snapshot.droppedFeedBytes)
                    : .whileArmed(feedBytes: snapshot.droppedFeedBytes)
            }
            finish(matched: false)
            return
        }
        // Child output only: the tape carries what the host wrote toward the child and how the
        // pane was resized on the same stream, and neither is output.
        for event in snapshot.events {
            guard case .feed(let bytes) = event.event else { continue }
            guard matcher.consume(bytes) else { continue }
            finish(matched: true)
            return
        }
        state.withLock { $0.cursor = snapshot.nextCursor }
    }

    /// Gives up the subscription and then answers the wait, which is what releases the matcher,
    /// the needle, and this host reference. Runs on `reads`, so it never fences the host queue
    /// from the host queue.
    ///
    /// Detaching before answering, not after, so that whoever sees the answer also sees the
    /// subscription gone; the reverse order leaves a live subscription visible after a
    /// satisfied wait for as long as the host queue is busy.
    private func finish(matched: Bool) {
        let wasSubscribed: Bool? = state.withLock { state in
            guard state.isFinished == false else { return nil }
            state.isFinished = true
            let wasSubscribed = state.isSubscribed
            state.isSubscribed = false
            return wasSubscribed
        }
        guard let wasSubscribed else { return }
        if wasSubscribed { host.removeFlightRecordingFollowNotice(id: subscriptionId) }
        waiter.complete(with: matched)
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

private extension Array where Element == UInt8 {
    /// Plain forward search over unsafe buffers rather than over slices: the lookback a wait
    /// matches against is the whole retained flight tape, megabytes where the superseded window
    /// was 64 KiB, and every byte of it crosses this loop once for each armed wait.
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard needle.isEmpty == false, needle.count <= count else { return false }
        return withUnsafeBufferPointer { haystack in
            needle.withUnsafeBufferPointer { needle in
                let last = haystack.count - needle.count
                var start = 0
                while start <= last {
                    if haystack[start] == needle[0] {
                        var offset = 1
                        while offset < needle.count, haystack[start + offset] == needle[offset] {
                            offset += 1
                        }
                        if offset == needle.count { return true }
                    }
                    start += 1
                }
                return false
            }
        }
    }
}
