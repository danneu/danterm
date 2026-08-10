// Opt-in real-program teardown proofs for ssh and tmux. The default gate skips
// these because they depend on local machine services and installed tools.
import Darwin
import Foundation
import PaneProcessLifecycle
import Testing
@testable import TerminalPTYHost
import TerminalPTYTestSupport

/// Runs machine-state-dependent teardown cases only through `just test-pty-external`.
@Suite(.serialized, .disabled(
    if: ProcessInfo.processInfo.environment["DANTERM_PTY_EXTERNAL"] != "1",
    "Run through just test-pty-external after satisfying its prerequisites."
))
struct TerminalPTYExternalTests {
    @Test("ssh disconnect tears down its local and remote terminal jobs", .timeLimit(.minutes(1)))
    func sshTeardown() async throws {
        // Intent: closing the local PTY removes the ssh client and the remote
        //   terminal job reached through passwordless localhost authentication.
        // Why it exists: ssh crosses a second process/session boundary that the
        //   controlled probes cannot model, so disconnect cleanup needs real evidence.
        // Scenario: an opt-in developer machine opens a localhost ssh PTY, waits
        //   for a remote marker, closes the pane, then verifies remote cleanup.
        let token = UUID().uuidString
        let remotePIDFile = "/tmp/danterm-pty-ssh-\(token).pid"
        let remoteCommand = "echo $$ > \(remotePIDFile); "
            + "trap 'rm -f \(remotePIDFile); exit 0' HUP TERM EXIT; "
            + "printf '__SSH_READY__\\n'; cat"
        let command = "exec /usr/bin/ssh -tt -o BatchMode=yes "
            + "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "
            + "localhost \(shellQuote(remoteCommand))"
        let host = try externalHost(captureTransitions: false)

        await host.start(externalLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__SSH_READY__".utf8)))
        await host.close()

        #expect((await host.resourceSnapshot()).isReleased)
        #expect(try processStatus(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "StrictHostKeyChecking=no",
                "localhost",
                "test ! -e \(remotePIDFile)",
            ]
        ) == 0)
    }

    @Test("tmux client loss terminates its isolated server and session", .timeLimit(.minutes(1)))
    func tmuxTeardown() async throws {
        // Intent: closing the local PTY removes the tmux client and its isolated
        //   exit-unattached server without leaving a detached session behind.
        // Why it exists: tmux deliberately introduces a server boundary, so the
        //   ordinary same-session process census is insufficient evidence.
        // Scenario: an opt-in tmux session emits a marker, loses its only client
        //   when the pane closes, and no longer answers on its private socket.
        let tmux = try #require(ProcessInfo.processInfo.environment["DANTERM_TMUX_PATH"])
        let token = "danterm-\(UUID().uuidString)"
        defer {
            _ = try? processStatus(
                executable: tmux,
                arguments: ["-L", token, "kill-server"]
            )
        }
        let command = "exec \(shellQuote(tmux)) -L \(token) -f /dev/null "
            + "new-session -s danterm 'printf \"__TMUX_READY__\\n\"; exec /bin/sh' "
            + "\\; set-option -g exit-unattached on"
        let host = try externalHost(captureTransitions: false)

        await host.start(externalLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__TMUX_READY__".utf8)))
        await host.close()

        #expect((await host.resourceSnapshot()).isReleased)
        #expect(try processStatus(
            executable: tmux,
            arguments: ["-L", token, "has-session"]
        ) != 0)
    }
}

private func externalHost(captureTransitions: Bool) throws -> TerminalPTYHost {
    try TerminalPTYHost(
        initialDimensions: .init(columns: 80, rows: 24),
        bootstrapExecutable: builtExecutable(named: "PTYSessionBootstrap"),
        captureTransitions: captureTransitions
    )
}

private func externalLaunchInput(command: String) -> LaunchPolicyInput {
    LaunchPolicyInput(
        accountShell: "/bin/sh",
        executablePaths: ["/bin/sh"],
        requestedWorkingDirectory: "/",
        homeDirectory: "/",
        accessibleDirectories: ["/"],
        inheritedEnvironment: [
            .init(name: "PATH", value: "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"),
            .init(name: "TERM", value: "xterm-256color"),
        ],
        advertisedEnvironment: [],
        paneEnvironment: [],
        command: nil,
        launchCommand: command,
        initialDimensions: .init(columns: 80, rows: 24)
    )
}

private func processStatus(executable: String, arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
