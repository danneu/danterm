// Pure fixtures for grid sizing and app-request launch assembly.
import PaneProcessLifecycle
import TerminalCore
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
            environment: [.init(name: "PANE", value: "pane")]
        )
        let facts = TerminalPaneLaunchFacts(
            accountShell: "/bin/zsh",
            executablePaths: ["/bin/zsh"],
            homeDirectory: "/home",
            accessibleDirectories: ["/requested", "/home", "/"],
            inheritedEnvironment: [.init(name: "BASE", value: "base")],
            localeFallback: "en_US.UTF-8",
            productIdentity: TerminalProductIdentity(name: "DanTerm", version: "1.2.3"),
            productEnvironment: [
                .init(
                    name: "DANTERM_SHELL_INTEGRATION_DIR",
                    value: "/Applications/DanTerm.app/Contents/Resources/shell-integration"
                ),
            ]
        )

        let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)
        let input = configuration.launchInput

        #expect(input.initialDimensions == .init(columns: 80, rows: 24))
        #expect(configuration.productIdentity == .init(name: "DanTerm", version: "1.2.3"))
        #expect(input.requestedWorkingDirectory == "/requested")
        #expect(input.inheritedEnvironment == [.init(name: "BASE", value: "base")])
        #expect(input.advertisedEnvironment == [
            .init(name: "TERM", value: "xterm-256color"),
            .init(name: "COLORTERM", value: "truecolor"),
            .init(name: "TERM_PROGRAM", value: "DanTerm"),
            .init(name: "TERM_PROGRAM_VERSION", value: "1.2.3"),
            .init(name: "LANG", value: "en_US.UTF-8"),
            .init(
                name: "DANTERM_SHELL_INTEGRATION_DIR",
                value: "/Applications/DanTerm.app/Contents/Resources/shell-integration"
            ),
        ])
        #expect(input.paneEnvironment == [.init(name: "PANE", value: "pane")])
        #expect(input.command == "restored")
        #expect(input.launchCommand == "launch")
    }

    @Test("a non-DanTerm identity is the only writer of the two identity names")
    func launchAssemblyAdvertisesSuppliedIdentity() {
        // Intent: both advertised identity entries come from the caller's identity, and
        //   a product environment that restates either one loses the value without
        //   moving the entry.
        // Why it exists: assembly used to spell "DanTerm" as a literal, so no embedder
        //   could advertise its own name. Identity must stay the sole writer of these
        //   two names without a key filter that could drift out of step with them.
        // Scenario: spec-first -- MiniTerm-shaped facts whose product environment tries
        //   to claim TERM_PROGRAM and TERM_PROGRAM_VERSION for itself.
        let facts = TerminalPaneLaunchFacts(
            accountShell: "/bin/zsh",
            executablePaths: ["/bin/zsh"],
            homeDirectory: "/home",
            accessibleDirectories: ["/home"],
            inheritedEnvironment: [],
            localeFallback: nil,
            productIdentity: TerminalProductIdentity(name: "MiniTerm", version: "4.5.6"),
            productEnvironment: [
                .init(name: "TERM_PROGRAM", value: "impostor"),
                .init(name: "MINITERM_ASSETS", value: "/assets"),
                .init(name: "TERM_PROGRAM_VERSION", value: "impostor"),
            ]
        )
        let request = TerminalPaneLaunchRequest(
            workingDirectory: nil,
            command: nil,
            launchCommand: nil,
            environment: []
        )

        let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)

        #expect(configuration.productIdentity == .init(name: "MiniTerm", version: "4.5.6"))
        #expect(configuration.launchInput.advertisedEnvironment == [
            .init(name: "TERM", value: "xterm-256color"),
            .init(name: "COLORTERM", value: "truecolor"),
            .init(name: "TERM_PROGRAM", value: "MiniTerm"),
            .init(name: "TERM_PROGRAM_VERSION", value: "4.5.6"),
            .init(name: "MINITERM_ASSETS", value: "/assets"),
        ])
    }

    @Test("assembly adds no product variable the embedder did not supply")
    func launchAssemblyAddsNoProductVariable() {
        // Intent: with an empty product environment, the advertised list holds only the
        //   terminal-generic entries and the caller's identity.
        // Why it exists: assembly used to append DANTERM_SHELL_INTEGRATION_DIR by name,
        //   so every embedder shipped one of DanTerm's variables to its children.
        // Scenario: spec-first -- an embedder that exports nothing of its own.
        let facts = TerminalPaneLaunchFacts(
            accountShell: "/bin/zsh",
            executablePaths: ["/bin/zsh"],
            homeDirectory: "/home",
            accessibleDirectories: ["/home"],
            inheritedEnvironment: [],
            localeFallback: nil,
            productIdentity: TerminalProductIdentity(name: "MiniTerm", version: "4.5.6"),
            productEnvironment: []
        )
        let request = TerminalPaneLaunchRequest(
            workingDirectory: nil,
            command: nil,
            launchCommand: nil,
            environment: []
        )

        let advertised = assembleTerminalPaneLaunch(request: request, facts: facts)
            .launchInput.advertisedEnvironment

        #expect(advertised.contains { $0.name.hasPrefix("DANTERM") } == false)
        #expect(advertised.map(\.name) == [
            "TERM",
            "COLORTERM",
            "TERM_PROGRAM",
            "TERM_PROGRAM_VERSION",
        ])
    }

    @Test("locale fallback yields to every non-empty inherited locale opinion", arguments: [
        "LANG",
        "LC_CTYPE",
        "LC_ALL",
    ])
    func localeFallbackYieldsToInheritedLocale(_ name: String) {
        let advertised = advertisedEnvironment(
            inheritedEnvironment: [.init(name: name, value: "C")],
            localeFallback: "en_US.UTF-8"
        )

        #expect(advertised.contains { $0.name == "LANG" } == false)
        #expect(advertised.contains { $0.name == "LC_CTYPE" } == false)
        #expect(advertised.contains { $0.name == "LC_ALL" } == false)
    }

    @Test("empty inherited locale values leave room for the LANG fallback", arguments: [
        "LANG",
        "LC_CTYPE",
        "LC_ALL",
    ])
    func emptyInheritedLocaleUsesFallback(_ name: String) {
        let advertised = advertisedEnvironment(
            inheritedEnvironment: [.init(name: name, value: "")],
            localeFallback: "en_US.UTF-8"
        )

        #expect(advertised.filter { $0.name == "LANG" } == [
            .init(name: "LANG", value: "en_US.UTF-8"),
        ])
        #expect(advertised.contains { $0.name == "LC_CTYPE" } == false)
        #expect(advertised.contains { $0.name == "LC_ALL" } == false)
    }

    @Test("missing inherited locale uses only the LANG fallback")
    func missingInheritedLocaleUsesFallback() {
        let advertised = advertisedEnvironment(
            inheritedEnvironment: [],
            localeFallback: "en_US.UTF-8"
        )

        #expect(advertised.filter { $0.name == "LANG" } == [
            .init(name: "LANG", value: "en_US.UTF-8"),
        ])
        #expect(advertised.contains { $0.name == "LC_CTYPE" } == false)
        #expect(advertised.contains { $0.name == "LC_ALL" } == false)
    }

    @Test("DanTerm launch values override hostile inherited identity and pane collisions")
    func launchAssemblyOverridesInheritedCollisions() throws {
        let request = TerminalPaneLaunchRequest(
            workingDirectory: nil,
            command: nil,
            launchCommand: nil,
            environment: [
                .init(name: "DANTERM", value: "1"),
                .init(name: "DANTERM_SOCK", value: "/owned/socket"),
                .init(name: "DANTERM_PANE", value: "owned-pane"),
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
                .init(name: "DANTERM_SHELL_INTEGRATION_DIR", value: "/hostile"),
                .init(name: "DANTERM", value: "hostile"),
                .init(name: "DANTERM_SOCK", value: "hostile"),
                .init(name: "DANTERM_PANE", value: "hostile"),
            ],
            localeFallback: nil,
            productIdentity: TerminalProductIdentity(name: "DanTerm", version: "9.8.7"),
            productEnvironment: [
                .init(name: "DANTERM_SHELL_INTEGRATION_DIR", value: "/owned/shell-integration"),
            ]
        )

        let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)
        let plan = try resolveLaunchPlan(configuration.launchInput).get()
        let environment = Dictionary(uniqueKeysWithValues: plan.attempts[0].environment.map {
            ($0.name, $0.value)
        })

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "DanTerm")
        #expect(environment["TERM_PROGRAM_VERSION"] == configuration.productIdentity.version)
        #expect(environment["DANTERM_SHELL_INTEGRATION_DIR"] == "/owned/shell-integration")
        #expect(environment["DANTERM"] == "1")
        #expect(environment["DANTERM_SOCK"] == "/owned/socket")
        #expect(environment["DANTERM_PANE"] == "owned-pane")
    }

    private func advertisedEnvironment(
        inheritedEnvironment: [EnvironmentEntry],
        localeFallback: String?
    ) -> [EnvironmentEntry] {
        let request = TerminalPaneLaunchRequest(
            workingDirectory: nil,
            command: nil,
            launchCommand: nil,
            environment: []
        )
        let facts = TerminalPaneLaunchFacts(
            accountShell: "/bin/zsh",
            executablePaths: ["/bin/zsh"],
            homeDirectory: "/home",
            accessibleDirectories: ["/home"],
            inheritedEnvironment: inheritedEnvironment,
            localeFallback: localeFallback,
            productIdentity: TerminalProductIdentity(name: "DanTerm", version: "1.2.3"),
            productEnvironment: [
                .init(name: "DANTERM_SHELL_INTEGRATION_DIR", value: "/shell-integration"),
            ]
        )
        return assembleTerminalPaneLaunch(request: request, facts: facts)
            .launchInput.advertisedEnvironment
    }
}
