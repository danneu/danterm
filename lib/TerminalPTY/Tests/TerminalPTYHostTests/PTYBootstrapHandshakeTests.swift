// Proofs about the status-pipe handshake between PTYSpawner and the child
// bootstrap. Full-launch behavior belongs in TerminalPTYHostTests; this file
// holds only what the handshake itself decides from the bytes it reads.
import Darwin
import PaneProcessLifecycle
import Testing
@testable import TerminalPTYHost
import TerminalPTYTestSupport

struct PTYBootstrapHandshakeTests {
    @Test("a half-written bootstrap failure payload fails the launch", .timeLimit(.minutes(1)))
    func truncatedPayloadFailsTheLaunch() throws {
        // Intent: a status pipe that closes part-way through a failure payload is
        //   reported as a launch failure, not as a successful exec.
        // Why it exists: the reader once returned nil for both a clean EOF and a
        //   short read, so a bootstrap that died mid-report was adopted as a live
        //   child and surfaced to the user as an immediate exit.
        // Scenario: a stub bootstrap writes four of the eight payload bytes and
        //   exits without exec'ing anything.
        let outcome = SystemTerminalPTYSpawner().spawn(
            handshakeSpec(),
            bootstrapExecutable: try builtExecutable(named: "PTYTruncatedBootstrapStub")
        ) { _ in true }

        guard case .failure(let failure) = outcome else {
            Issue.record("the truncated handshake did not fail the launch: \(outcome)")
            return
        }
        #expect(failure == .systemError(EPROTO))
    }
}

private func handshakeSpec() -> PTYLaunchSpec {
    PTYLaunchSpec(
        program: "/bin/sh",
        arguments: ["-sh"],
        workingDirectory: "/",
        environment: [],
        initialDimensions: .init(columns: 80, rows: 24)
    )
}
