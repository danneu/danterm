// Pure assembly of pane request values and injected ambient launch facts.
import PaneLifecycle

/// Initial geometry shared by host construction and launch policy for every pane.
public let terminalPaneInitialDimensions = TerminalDimensions(columns: 80, rows: 24)

/// Carries backend-neutral pane values without depending on DanTerm's root package.
public struct TerminalPaneLaunchRequest: Equatable, Sendable {
    /// Pane-requested cwd before launch policy applies accessibility fallbacks.
    public let workingDirectory: String?
    /// User-authored command submitted as interactive shell input.
    public let command: String?
    /// Explicit command that takes precedence as initial shell input.
    public let launchCommand: String?
    /// Pane-scoped environment layer with final precedence.
    public let environment: [EnvironmentEntry]

    /// Captures values already owned by one DanTerm pane request.
    public init(
        workingDirectory: String?,
        command: String?,
        launchCommand: String?,
        environment: [EnvironmentEntry]
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.launchCommand = launchCommand
        self.environment = environment
    }
}

/// Injects process and account facts whose values must be explicit at the launch seam.
public struct TerminalPaneLaunchFacts: Equatable, Sendable {
    /// Account-database shell before executable fallback policy.
    public let accountShell: String?
    /// Paths already verified executable by the app adapter.
    public let executablePaths: [String]
    /// Account home used as the second cwd candidate.
    public let homeDirectory: String?
    /// Directories already verified accessible by the app adapter.
    public let accessibleDirectories: [String]
    /// Deterministically ordered snapshot of the app process environment.
    public let inheritedEnvironment: [EnvironmentEntry]
    /// Bundle version advertised to child processes as DanTerm's version.
    public let terminalProgramVersion: String
    /// Running bundle's asset directory advertised for nested-shell discovery.
    public let shellIntegrationDirectory: String

    /// Captures ambient facts once so launch assembly remains deterministic.
    public init(
        accountShell: String?,
        executablePaths: [String],
        homeDirectory: String?,
        accessibleDirectories: [String],
        inheritedEnvironment: [EnvironmentEntry],
        terminalProgramVersion: String,
        shellIntegrationDirectory: String
    ) {
        self.accountShell = accountShell
        self.executablePaths = executablePaths
        self.homeDirectory = homeDirectory
        self.accessibleDirectories = accessibleDirectories
        self.inheritedEnvironment = inheritedEnvironment
        self.terminalProgramVersion = terminalProgramVersion
        self.shellIntegrationDirectory = shellIntegrationDirectory
    }
}

/// Carries the host/launch geometry once, so the two consumers cannot disagree about it.
public struct TerminalPaneLaunchConfiguration: Equatable, Sendable {
    /// Launch policy input, the single source of the pane's initial geometry.
    public let launchInput: LaunchPolicyInput
    /// Program version shared by the child environment and terminal query replies.
    public let terminalProgramVersion: String

    /// Geometry used to construct the terminal and PTY owner. Derived rather than stored:
    /// `TerminalPTYHost.start` rejects a launch whose input geometry differs from the host's,
    /// so a second copy could only ever be a launch failure waiting to happen.
    public var initialDimensions: TerminalDimensions { launchInput.initialDimensions }

    /// Creates the coupled boundary consumed by the session controller.
    public init(
        launchInput: LaunchPolicyInput,
        terminalProgramVersion: String
    ) {
        self.launchInput = launchInput
        self.terminalProgramVersion = terminalProgramVersion
    }
}

/// Assembles pane values, ambient facts, and the pinned terminal identity without IO.
public func assembleTerminalPaneLaunch(
    request: TerminalPaneLaunchRequest,
    facts: TerminalPaneLaunchFacts
) -> TerminalPaneLaunchConfiguration {
    let dimensions = terminalPaneInitialDimensions
    return TerminalPaneLaunchConfiguration(
        launchInput: LaunchPolicyInput(
            accountShell: facts.accountShell,
            executablePaths: facts.executablePaths,
            requestedWorkingDirectory: request.workingDirectory,
            homeDirectory: facts.homeDirectory,
            accessibleDirectories: facts.accessibleDirectories,
            inheritedEnvironment: facts.inheritedEnvironment,
            advertisedEnvironment: [
                EnvironmentEntry(name: "TERM", value: "xterm-256color"),
                EnvironmentEntry(name: "COLORTERM", value: "truecolor"),
                EnvironmentEntry(name: "TERM_PROGRAM", value: "DanTerm"),
                EnvironmentEntry(
                    name: "TERM_PROGRAM_VERSION",
                    value: facts.terminalProgramVersion
                ),
                EnvironmentEntry(
                    name: "DANTERM_SHELL_INTEGRATION_DIR",
                    value: facts.shellIntegrationDirectory
                ),
            ],
            paneEnvironment: request.environment,
            command: request.command,
            launchCommand: request.launchCommand,
            initialDimensions: dimensions
        ),
        terminalProgramVersion: facts.terminalProgramVersion
    )
}
