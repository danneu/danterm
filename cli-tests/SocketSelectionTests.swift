// Pure coverage for CLI control-socket selection inside and outside DanTerm panes.
import Testing
import DanTermProtocol
@testable import DanTermCLI

struct SocketSelectionTests {
    @Test("explicit non-empty socket target wins")
    func explicitTargetWins() throws {
        let selected = try selectControlSocketPath(
            explicit: "/tmp/flag.sock",
            environment: [EnvVars.flag: "1", EnvVars.sock: "/tmp/owned.sock"],
            fallback: "/tmp/fallback.sock",
            method: .ls
        )

        #expect(selected == "/tmp/flag.sock")
    }

    @Test("environment socket remains the explicit ambient target")
    func environmentTargetWinsWithoutFlag() throws {
        let selected = try selectControlSocketPath(
            explicit: nil,
            environment: [EnvVars.flag: "1", EnvVars.sock: "/tmp/owned.sock"],
            fallback: "/tmp/fallback.sock",
            method: .ls
        )

        #expect(selected == "/tmp/owned.sock")
    }

    @Test("DanTerm pane without a socket target fails closed")
    func paneWithoutTargetFailsClosed() {
        // Intent: an in-app CLI with no usable target reports that its instance
        //   is not running instead of deriving another instance's socket path.
        // Why it exists: a same-identity process that lost the bind race used to
        //   route commands from its panes into the winning process.
        // Scenario: a pane receives DANTERM=1 and an empty DANTERM_SOCK overlay.
        do {
            _ = try selectControlSocketPath(
                explicit: nil,
                environment: [EnvVars.flag: "1", EnvVars.sock: ""],
                fallback: "/tmp/other-instance.sock",
                method: .ls
            )
            Issue.record("expected socket selection to fail closed")
        } catch let error as CLIError {
            #expect(error.message == "DanTerm is not running")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("quit resolves no target from ambient state", arguments: [
        [EnvVars.sock: "/tmp/owned.sock"],
        [EnvVars.flag: "1", EnvVars.sock: "/tmp/owned.sock"],
        [:],
    ] as [[String: String]])
    func quitRefusesAmbientTargets(_ environment: [String: String]) {
        // Intent: quit without --socket fails before any instance is contacted,
        //   whatever DANTERM_SOCK holds and whatever the fallback would derive.
        // Why it exists: the identity-derived fallback of the shipped binary is
        //   production's socket, so a bare `danterm quit` would aim the verb at
        //   the app the whole feature exists to protect.
        // Scenario: the inherited pane socket, the in-pane pair, and a plain
        //   shell with neither.
        do {
            _ = try selectControlSocketPath(
                explicit: nil,
                environment: environment,
                fallback: "/tmp/production.sock",
                method: .quit
            )
            Issue.record("expected quit to refuse an ambient target")
        } catch let error as CLIError {
            #expect(error.message == "quit requires an explicit --socket <path>")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("quit accepts the explicitly named instance")
    func quitAcceptsExplicitTarget() throws {
        let selected = try selectControlSocketPath(
            explicit: "/tmp/slot-3.sock",
            environment: [EnvVars.sock: "/tmp/owned.sock"],
            fallback: "/tmp/production.sock",
            method: .quit
        )

        #expect(selected == "/tmp/slot-3.sock")
    }

    @Test("ordinary terminal uses identity-derived fallback")
    func externalProcessUsesFallback() throws {
        let selected = try selectControlSocketPath(
            explicit: nil,
            environment: [:],
            fallback: "/tmp/identity.sock",
            method: .ls
        )

        #expect(selected == "/tmp/identity.sock")
    }
}
