// Pure assembly of pane request values and injected ambient launch facts.
import PaneLifecycle

/// Initial geometry shared by host construction and launch policy for every pane.
public let terminalPaneInitialDimensions = TerminalDimensions(columns: 80, rows: 24)

/// Carries backend-neutral pane values without depending on DanTerm's root package.
public struct TerminalPaneLaunchRequest: Equatable, Sendable {
    /// Pane-requested cwd before launch policy applies accessibility fallbacks.
    public let workingDirectory: String?
    /// Restored shell text retained as either prefill or executable input.
    public let command: String?
    /// Explicit command that takes precedence as initial shell input.
    public let launchCommand: String?
    /// Whether restored command text stays editable or is submitted.
    public let restoreCommandBehavior: RestoreCommandBehavior
    /// Pane-scoped environment layer with final precedence.
    public let environment: [EnvironmentEntry]

    /// Captures values already owned by one DanTerm pane request.
    public init(
        workingDirectory: String?,
        command: String?,
        launchCommand: String?,
        restoreCommandBehavior: RestoreCommandBehavior,
        environment: [EnvironmentEntry]
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.launchCommand = launchCommand
        self.restoreCommandBehavior = restoreCommandBehavior
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

    /// Captures ambient facts once so launch assembly remains deterministic.
    public init(
        accountShell: String?,
        executablePaths: [String],
        homeDirectory: String?,
        accessibleDirectories: [String],
        inheritedEnvironment: [EnvironmentEntry],
        terminalProgramVersion: String
    ) {
        self.accountShell = accountShell
        self.executablePaths = executablePaths
        self.homeDirectory = homeDirectory
        self.accessibleDirectories = accessibleDirectories
        self.inheritedEnvironment = inheritedEnvironment
        self.terminalProgramVersion = terminalProgramVersion
    }
}

/// Keeps the duplicated host/launch geometry visibly identical at construction.
public struct TerminalPaneLaunchConfiguration: Equatable, Sendable {
    /// Geometry used to construct the terminal and PTY owner.
    public let initialDimensions: TerminalDimensions
    /// Launch policy input carrying the same initial geometry.
    public let launchInput: LaunchPolicyInput

    /// Creates the coupled boundary consumed by the session controller.
    public init(initialDimensions: TerminalDimensions, launchInput: LaunchPolicyInput) {
        self.initialDimensions = initialDimensions
        self.launchInput = launchInput
    }
}

/// Assembles pane values, ambient facts, and the pinned terminal identity without IO.
public func assembleTerminalPaneLaunch(
    request: TerminalPaneLaunchRequest,
    facts: TerminalPaneLaunchFacts
) -> TerminalPaneLaunchConfiguration {
    let dimensions = terminalPaneInitialDimensions
    return TerminalPaneLaunchConfiguration(
        initialDimensions: dimensions,
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
            ],
            paneEnvironment: request.environment,
            command: request.command,
            launchCommand: request.launchCommand,
            restoreCommandBehavior: request.restoreCommandBehavior,
            initialDimensions: dimensions
        )
    )
}
