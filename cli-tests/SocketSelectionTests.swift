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
            fallback: "/tmp/fallback.sock"
        )

        #expect(selected == "/tmp/flag.sock")
    }

    @Test("environment socket remains the explicit ambient target")
    func environmentTargetWinsWithoutFlag() throws {
        let selected = try selectControlSocketPath(
            explicit: nil,
            environment: [EnvVars.flag: "1", EnvVars.sock: "/tmp/owned.sock"],
            fallback: "/tmp/fallback.sock"
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
                fallback: "/tmp/other-instance.sock"
            )
            Issue.record("expected socket selection to fail closed")
        } catch let error as CLIError {
            #expect(error.message == "DanTerm is not running")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("ordinary terminal uses identity-derived fallback")
    func externalProcessUsesFallback() throws {
        let selected = try selectControlSocketPath(
            explicit: nil,
            environment: [:],
            fallback: "/tmp/identity.sock"
        )

        #expect(selected == "/tmp/identity.sock")
    }
}
