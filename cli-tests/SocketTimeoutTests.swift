// Pure coverage for the socket timeout the CLI applies to every request.
//
// The value is an ordinary duration supplied from outside the process, so the whole
// contract is here: what it is when nobody supplies one, what a supplied one means, and
// what happens to a value that is not a duration.
import Testing
import DanTermProtocol
@testable import DanTermCLI

struct SocketTimeoutTests {
    @Test("an unsupplied timeout keeps the CLI's five-second default")
    func unsuppliedTimeoutKeepsTheDefault() throws {
        #expect(try selectSocketTimeout(environment: [:]) == 5)
    }

    @Test("an empty value reads as unsupplied")
    func emptyValueReadsAsUnsupplied() throws {
        // Intent: an exported but empty variable takes the default rather than failing.
        // Why it exists: every pane's shell inherits this variable, so `export
        //   DANTERM_SOCKET_TIMEOUT=` in a profile must not break every command.
        // Scenario: a shell profile clears the variable instead of unsetting it.
        #expect(try selectSocketTimeout(environment: [EnvVars.socketTimeout: "  "]) == 5)
    }

    @Test("a supplied timeout is honored", arguments: [("0.25", 0.25), ("30", 30.0)])
    func suppliedTimeoutIsHonored(_ supplied: String, _ expected: Double) throws {
        #expect(try selectSocketTimeout(environment: [EnvVars.socketTimeout: supplied]) == expected)
    }

    @Test("a value that is not a positive duration is refused", arguments: [
        "abc", "0", "-1", "5s", "inf", "nan",
    ])
    func nonPositiveDurationIsRefused(_ supplied: String) {
        // Intent: a value the CLI cannot use fails the command with a stated reason.
        // Why it exists: silently falling back to the default would hide a typo in a
        //   shell profile behind whatever timeout the caller thought they had changed.
        // Scenario: a user exports a value with a unit suffix, or a negative number.
        do {
            _ = try selectSocketTimeout(environment: [EnvVars.socketTimeout: supplied])
            Issue.record("expected \(supplied) to be refused")
        } catch let error as CLIError {
            #expect(error.message.contains(EnvVars.socketTimeout))
            #expect(error.message.contains(supplied))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
