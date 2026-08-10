// Behavioral proofs for pure shell, cwd, environment, and geometry resolution.
import Testing
@testable import PaneLifecycle

@Suite struct LaunchPolicyTests {
    @Test("launch policy selects the account shell as a login shell")
    func selectsAccountShell() throws {
        let plan = try resolveLaunchPlan(makeInput()).get()

        #expect(plan.attempts.map(\.program) == ["/opt/homebrew/bin/fish", "/opt/homebrew/bin/fish", "/opt/homebrew/bin/fish"])
        #expect(plan.attempts.map(\.workingDirectory) == ["/work/project", "/Users/tester", "/"])
        #expect(plan.attempts.allSatisfy { $0.arguments == ["-fish"] })
        #expect(plan.attempts.allSatisfy { $0.initialDimensions == TerminalDimensions(columns: 100, rows: 40) })
    }

    @Test("launch policy falls back from the account shell through zsh and sh", arguments: [
        (["/bin/zsh"], "/bin/zsh", "-zsh"),
        (["/bin/sh"], "/bin/sh", "-sh"),
    ])
    func shellFallbacks(executablePaths: [String], expectedProgram: String, expectedArgv0: String) throws {
        var input = makeInput()
        input.executablePaths = executablePaths

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.attempts[0].program == expectedProgram)
        #expect(plan.attempts[0].arguments == [expectedArgv0])
    }

    @Test("launch policy rejects a launch with no usable shell")
    func rejectsMissingShell() {
        var input = makeInput()
        input.executablePaths = []

        #expect(resolveLaunchPlan(input) == .failure(.noUsableShell))
    }

    @Test("cwd resolution skips inaccessible and duplicate candidates before root")
    func cwdFallbacksAreAccessibleAndUnique() throws {
        var input = makeInput()
        input.requestedWorkingDirectory = "/Users/tester"
        input.accessibleDirectories = ["/Users/tester"]

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.attempts.map(\.workingDirectory) == ["/Users/tester", "/"])
    }

    @Test("environment overrides replace inherited values in deterministic order")
    func environmentOverrides() throws {
        let plan = try resolveLaunchPlan(makeInput()).get()

        #expect(plan.attempts[0].environment == [
            EnvironmentEntry(name: "PATH", value: "/usr/bin"),
            EnvironmentEntry(name: "TERM", value: "xterm-256color"),
            EnvironmentEntry(name: "DANTERM_PANE", value: "pane-1"),
            EnvironmentEntry(name: "COLORTERM", value: "truecolor"),
        ])
    }

    @Test("pane environment wins when override layers repeat a name")
    func paneEnvironmentHasFinalPrecedence() throws {
        var input = makeInput()
        input.advertisedEnvironment.append(EnvironmentEntry(name: "DANTERM_PANE", value: "advertised"))

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.attempts[0].environment.first { $0.name == "DANTERM_PANE" }?.value == "pane-1")
    }

    @Test("launch policy rejects non-positive terminal geometry", arguments: [
        TerminalDimensions(columns: 0, rows: 24),
        TerminalDimensions(columns: 80, rows: 0),
        TerminalDimensions(columns: -1, rows: 24),
    ])
    func rejectsInvalidGeometry(dimensions: TerminalDimensions) {
        var input = makeInput()
        input.initialDimensions = dimensions

        #expect(resolveLaunchPlan(input) == .failure(.invalidDimensions))
    }

    @Test("command input executes with exactly one trailing newline", arguments: [
        ("printf ok", "printf ok\n"),
        ("printf ok\n", "printf ok\n"),
    ])
    func commandInputExecutes(command: String, expected: String) throws {
        var input = makeInput()
        input.command = command

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.initialInput == Array(expected.utf8))
    }

    @Test("launch command is interactive shell input and has deterministic precedence")
    func launchCommandPrecedence() throws {
        var input = makeInput()
        input.command = "restored draft"
        input.launchCommand = "printf launched"

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.initialInput == Array("printf launched\n".utf8))
        #expect(plan.attempts.allSatisfy { $0.arguments == ["-fish"] })
    }

    @Test("empty commands produce no initial shell write")
    func emptyCommandsProduceNoInput() throws {
        var input = makeInput()
        input.command = ""
        input.launchCommand = ""

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.initialInput == nil)
    }

    @Test("restore metadata remains environment-only")
    func restoreMetadataProducesNoInput() throws {
        var input = makeInput()
        input.paneEnvironment.append(.init(
            name: "DANTERM_RESTORE_COMMAND",
            value: "printf restored"
        ))

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.initialInput == nil)
        #expect(plan.attempts.allSatisfy {
            $0.environment.contains(.init(
                name: "DANTERM_RESTORE_COMMAND",
                value: "printf restored"
            ))
        })
    }
}

private func makeInput() -> LaunchPolicyInput {
    LaunchPolicyInput(
        accountShell: "/opt/homebrew/bin/fish",
        executablePaths: ["/opt/homebrew/bin/fish", "/bin/zsh", "/bin/sh"],
        requestedWorkingDirectory: "/work/project",
        homeDirectory: "/Users/tester",
        accessibleDirectories: ["/work/project", "/Users/tester"],
        inheritedEnvironment: [
            EnvironmentEntry(name: "PATH", value: "/usr/bin"),
            EnvironmentEntry(name: "TERM", value: "inherited"),
            EnvironmentEntry(name: "DANTERM_PANE", value: "old-pane"),
        ],
        advertisedEnvironment: [
            EnvironmentEntry(name: "TERM", value: "xterm-256color"),
            EnvironmentEntry(name: "COLORTERM", value: "truecolor"),
        ],
        paneEnvironment: [
            EnvironmentEntry(name: "DANTERM_PANE", value: "pane-1"),
        ],
        command: nil,
        launchCommand: nil,
        initialDimensions: TerminalDimensions(columns: 100, rows: 40)
    )
}
