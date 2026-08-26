// Behavioral proofs for pure shell, cwd, environment, and geometry resolution.
import Testing
@testable import PaneProcessLifecycle

@Suite struct LaunchPolicyTests {
    @Test("launch policy names both ladders and starts at the account shell")
    func buildsBothLadders() throws {
        let plan = try resolveLaunchPlan(makeInput()).get()

        #expect(plan.shells == ["/opt/homebrew/bin/fish", "/bin/zsh", "/bin/sh"])
        #expect(plan.workingDirectories == ["/work/project", "/Users/tester", "/"])
        let first = plan.spec(shell: 0, workingDirectory: 0)
        #expect(first.program == "/opt/homebrew/bin/fish")
        #expect(first.workingDirectory == "/work/project")
        #expect(first.arguments == ["-fish"])
        #expect(first.initialDimensions == TerminalDimensions(columns: 100, rows: 40))
    }

    @Test("every shell candidate spawns as a login shell of its own name")
    func everyShellCandidateIsALoginShell() throws {
        let plan = try resolveLaunchPlan(makeInput()).get()

        let specs = plan.shells.indices.map { plan.spec(shell: $0, workingDirectory: 0) }
        #expect(specs.map(\.program) == ["/opt/homebrew/bin/fish", "/bin/zsh", "/bin/sh"])
        #expect(specs.map(\.arguments) == [["-fish"], ["-zsh"], ["-sh"]])
    }

    @Test("a ladder drops a missing or repeated candidate without reordering the rest", arguments: [
        (accountShell: String?.none, cwd: String?.none, shells: ["/bin/zsh", "/bin/sh"], cwds: ["/Users/tester", "/"]),
        (accountShell: "/bin/zsh", cwd: "/Users/tester", shells: ["/bin/zsh", "/bin/sh"], cwds: ["/Users/tester", "/"]),
        (accountShell: "/bin/sh", cwd: "/", shells: ["/bin/sh", "/bin/zsh"], cwds: ["/", "/Users/tester"]),
    ])
    func laddersDropNilAndRepeatedCandidates(
        accountShell: String?,
        cwd: String?,
        shells: [String],
        cwds: [String]
    ) throws {
        var input = makeInput()
        input.accountShell = accountShell
        input.requestedWorkingDirectory = cwd

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.shells == shells)
        #expect(plan.workingDirectories == cwds)
    }

    @Test("a relative account shell never enters the shell ladder")
    func relativeAccountShellIsDropped() throws {
        // Intent: only absolute shell candidates are offered to exec.
        // Why it exists: a relative path would make exec viability depend on which
        //   cwd the other ladder is currently offering, coupling the two walks.
        // Scenario: spec-first -- an account database records a bare "fish".
        var input = makeInput()
        input.accountShell = "fish"

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.shells == ["/bin/zsh", "/bin/sh"])
    }

    @Test("both ladders keep their guaranteed final candidate when every fact is nil")
    func laddersAreNeverEmpty() throws {
        var input = makeInput()
        input.accountShell = nil
        input.requestedWorkingDirectory = nil
        input.homeDirectory = nil

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.shells == ["/bin/zsh", "/bin/sh"])
        #expect(plan.workingDirectories == ["/"])
    }

    @Test("environment overrides replace inherited values in deterministic order")
    func environmentOverrides() throws {
        let plan = try resolveLaunchPlan(makeInput()).get()

        #expect(plan.spec(shell: 0, workingDirectory: 0).environment == [
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

        #expect(plan.spec(shell: 0, workingDirectory: 0).environment.first { $0.name == "DANTERM_PANE" }?.value == "pane-1")
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
        #expect(plan.spec(shell: 0, workingDirectory: 0).arguments == ["-fish"])
    }

    @Test("empty commands produce no initial shell write")
    func emptyCommandsProduceNoInput() throws {
        var input = makeInput()
        input.command = ""
        input.launchCommand = ""

        let plan = try resolveLaunchPlan(input).get()

        #expect(plan.initialInput == nil)
    }

    @Test("launch policy rejects initial input above the pane input bound")
    func rejectsOversizedInitialInput() {
        var input = makeInput()
        input.launchCommand = String(
            repeating: "x",
            count: PaneProcessLifecycleReducer.pendingInputByteLimit
        )

        #expect(resolveLaunchPlan(input) == .failure(.initialInputTooLarge))
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
        #expect(plan.spec(shell: 0, workingDirectory: 0).environment.contains(.init(
            name: "DANTERM_RESTORE_COMMAND",
            value: "printf restored"
        )))
    }
}

private func makeInput() -> LaunchPolicyInput {
    LaunchPolicyInput(
        accountShell: "/opt/homebrew/bin/fish",
        requestedWorkingDirectory: "/work/project",
        homeDirectory: "/Users/tester",
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
