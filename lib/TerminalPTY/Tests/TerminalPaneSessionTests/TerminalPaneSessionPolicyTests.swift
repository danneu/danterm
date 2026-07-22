// Pure fixtures for grid sizing and app-request launch assembly.
import PaneLifecycle
import Testing
@testable import TerminalPaneSession

/// Pins the pure policies the AppKit adapter will call without platform state.
struct TerminalPaneSessionPolicyTests {
    @Test("precise wheel deltas preserve fractional rows for owner-side quantization")
    func preciseWheelNormalization() {
        let normalizer = TerminalWheelNormalizer()

        #expect(normalizer.rows(delta: 4, isPrecise: true, cellHeight: 10) == -0.4)
        #expect(normalizer.rows(delta: -7, isPrecise: true, cellHeight: 10) == 0.7)
    }

    @Test("line wheel deltas use the pinned scale without retaining view-side remainder")
    func lineWheelScaling() {
        let normalizer = TerminalWheelNormalizer(lineRowsPerUnit: 3)

        #expect(normalizer.rows(delta: 0.5, isPrecise: false, cellHeight: 0) == -1.5)
        #expect(normalizer.rows(delta: -1, isPrecise: false, cellHeight: 0) == 3)
    }

    @Test("wheel normalization rejects invalid geometry and non-finite deltas")
    func wheelNormalizationGuards() {
        let normalizer = TerminalWheelNormalizer()

        #expect(normalizer.rows(delta: 15, isPrecise: true, cellHeight: 10) == -1.5)
        #expect(normalizer.rows(delta: 1, isPrecise: true, cellHeight: 0) == 0)
        #expect(normalizer.rows(delta: .infinity, isPrecise: false, cellHeight: 10) == 0)
    }

    @Test("grid sizing floors each axis and clamps to terminal minima")
    func gridSizingFloorsAndClamps() {
        #expect(terminalGridDimensions(
            size: .init(width: 101, height: 55),
            cellSize: .init(width: 10, height: 12)
        ) == .init(columns: 10, rows: 4))
        #expect(terminalGridDimensions(
            size: .init(width: 1, height: 1),
            cellSize: .init(width: 10, height: 12)
        ) == .init(columns: 2, rows: 1))
    }

    @Test("grid sizing rejects degenerate and non-finite inputs", arguments: [
        (TerminalPointSize(width: 0, height: 10), TerminalPointSize(width: 1, height: 1)),
        (TerminalPointSize(width: 10, height: -1), TerminalPointSize(width: 1, height: 1)),
        (TerminalPointSize(width: 10, height: 10), TerminalPointSize(width: 0, height: 1)),
        (TerminalPointSize(width: .infinity, height: 10), TerminalPointSize(width: 1, height: 1)),
        (TerminalPointSize(width: 10, height: 10), TerminalPointSize(width: .nan, height: 1)),
    ])
    func gridSizingRejectsDegenerate(
        size: TerminalPointSize,
        cellSize: TerminalPointSize
    ) {
        #expect(terminalGridDimensions(size: size, cellSize: cellSize) == nil)
    }

    @Test("launch assembly preserves request layers and pins terminal identity")
    func launchAssembly() {
        let request = TerminalPaneLaunchRequest(
            workingDirectory: "/requested",
            command: "restored",
            launchCommand: "launch",
            restoreCommandBehavior: .execute,
            environment: [.init(name: "PANE", value: "pane")]
        )
        let facts = TerminalPaneLaunchFacts(
            accountShell: "/bin/zsh",
            executablePaths: ["/bin/zsh"],
            homeDirectory: "/home",
            accessibleDirectories: ["/requested", "/home", "/"],
            inheritedEnvironment: [.init(name: "BASE", value: "base")],
            terminalProgramVersion: "1.2.3"
        )

        let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)
        let input = configuration.launchInput

        #expect(configuration.initialDimensions == .init(columns: 80, rows: 24))
        #expect(configuration.terminalProgramVersion == "1.2.3")
        #expect(input.initialDimensions == configuration.initialDimensions)
        #expect(input.requestedWorkingDirectory == "/requested")
        #expect(input.inheritedEnvironment == [.init(name: "BASE", value: "base")])
        #expect(input.advertisedEnvironment == [
            .init(name: "TERM", value: "xterm-256color"),
            .init(name: "COLORTERM", value: "truecolor"),
            .init(name: "TERM_PROGRAM", value: "DanTerm"),
            .init(name: "TERM_PROGRAM_VERSION", value: "1.2.3"),
        ])
        #expect(input.paneEnvironment == [.init(name: "PANE", value: "pane")])
        #expect(input.command == "restored")
        #expect(input.launchCommand == "launch")
        #expect(input.restoreCommandBehavior == .execute)
    }

    @Test("DanTerm launch values override hostile inherited identity and pane collisions")
    func launchAssemblyOverridesInheritedCollisions() throws {
        let request = TerminalPaneLaunchRequest(
            workingDirectory: nil,
            command: nil,
            launchCommand: nil,
            restoreCommandBehavior: .prefill,
            environment: [
                .init(name: "DANTERM", value: "1"),
                .init(name: "DANTERM_SOCK", value: "/owned/socket"),
                .init(name: "DANTERM_PANE", value: "owned-pane"),
                .init(name: "DANTERM_TOKEN", value: "owned-token"),
                .init(name: "LC_DANTERM_TOKEN", value: "owned-token"),
            ]
        )
        let facts = TerminalPaneLaunchFacts(
            accountShell: "/bin/zsh",
            executablePaths: ["/bin/zsh"],
            homeDirectory: "/home",
            accessibleDirectories: ["/home"],
            inheritedEnvironment: [
                .init(name: "TERM", value: "hostile"),
                .init(name: "COLORTERM", value: "hostile"),
                .init(name: "TERM_PROGRAM", value: "hostile"),
                .init(name: "TERM_PROGRAM_VERSION", value: "hostile"),
                .init(name: "DANTERM", value: "hostile"),
                .init(name: "DANTERM_SOCK", value: "hostile"),
                .init(name: "DANTERM_PANE", value: "hostile"),
                .init(name: "DANTERM_TOKEN", value: "hostile"),
                .init(name: "LC_DANTERM_TOKEN", value: "hostile"),
            ],
            terminalProgramVersion: "9.8.7"
        )

        let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)
        let plan = try resolveLaunchPlan(configuration.launchInput).get()
        let environment = Dictionary(uniqueKeysWithValues: plan.attempts[0].environment.map {
            ($0.name, $0.value)
        })

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "DanTerm")
        #expect(environment["TERM_PROGRAM_VERSION"] == configuration.terminalProgramVersion)
        #expect(environment["DANTERM"] == "1")
        #expect(environment["DANTERM_SOCK"] == "/owned/socket")
        #expect(environment["DANTERM_PANE"] == "owned-pane")
        #expect(environment["DANTERM_TOKEN"] == "owned-token")
        #expect(environment["LC_DANTERM_TOKEN"] == "owned-token")
    }
}
