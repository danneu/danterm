// Guards the sampling loop every bounded wait in TerminalPTYTestSupport is built on.
import Testing

@testable import TerminalPTYTestSupport

@Suite("Bounded polling")
struct PollUntilTests {
    @Test("a cancelled poll stops instead of spinning out its deadline", .timeLimit(.minutes(1)))
    func cancelledPollStopsPromptly() async {
        // Intent: cancelling a poll whose condition never holds ends it, and ends it
        //   without burning the remaining deadline at full CPU.
        // Why it exists: the loop only stays cheap while its sleep runs. A cancelled
        //   sleep throws immediately, so a loop that swallows the error keeps sampling
        //   with nothing left to slow it down -- a hot spin for the rest of the limit,
        //   started by the very cancellation meant to stop the wait. That is the shape
        //   that wedged the TerminalPTY lane, rebuilt inside its own remedy.
        // Scenario: a test's time limit fires while a wait sits on a condition that
        //   will never hold.
        let started = ContinuousClock().now
        let poll = Task { await pollUntil({ false }, within: .seconds(600)) }
        try? await Task.sleep(for: .milliseconds(50))
        poll.cancel()

        #expect(await poll.value == false)
        let elapsed = ContinuousClock().now - started
        #expect(elapsed < .seconds(5), "the cancelled poll took \(elapsed)")
    }

    @Test("a condition that holds late is still reported", .timeLimit(.minutes(1)))
    func lateConditionIsReported() async {
        // Intent: sampling keeps running until the condition holds.
        // Why it exists: a cheap way to stop a spin is to stop sampling, which would
        //   trade a wedged wait for a wait that answers wrongly.
        // Scenario: the state a test waits for arrives a few samples in.
        let deadline = ContinuousClock().now + .milliseconds(100)
        #expect(await pollUntil({ ContinuousClock().now >= deadline }, within: .seconds(30)))
    }
}
