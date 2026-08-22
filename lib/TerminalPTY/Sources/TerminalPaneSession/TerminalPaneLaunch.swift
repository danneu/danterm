// Pure assembly of pane request values and injected ambient launch facts.
import PaneProcessLifecycle

/// Initial geometry for a pane whose request names none: host construction and
/// launch policy share it.
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
    /// Geometry to install before the child starts, or nil for the shared default.
    /// A pane restored at a size a client claimed supplies it, so the child never
    /// observes the default grid ahead of the claim.
    public let initialDimensions: TerminalDimensions?

    /// Captures values already owned by one DanTerm pane request.
    public init(
        workingDirectory: String?,
        command: String?,
        launchCommand: String?,
        environment: [EnvironmentEntry],
        initialDimensions: TerminalDimensions? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.launchCommand = launchCommand
        self.environment = environment
        self.initialDimensions = initialDimensions
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
    /// Machine-supported LANG fallback, or nil when the app should advertise none.
    public let localeFallback: String?
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
        localeFallback: String?,
        terminalProgramVersion: String,
        shellIntegrationDirectory: String
    ) {
        self.accountShell = accountShell
        self.executablePaths = executablePaths
        self.homeDirectory = homeDirectory
        self.accessibleDirectories = accessibleDirectories
        self.inheritedEnvironment = inheritedEnvironment
        self.localeFallback = localeFallback
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
    /// Whether the pane's launch geometry is an override rather than a slot-derived grid.
    /// A pane is born pinned only when its request named a grid, so the recorder's birth
    /// geometry states the same fact its first recorded resize would.
    public let initialGridPinned: Bool

    /// Creates the coupled boundary the app uses to construct the PTY host.
    public init(
        launchInput: LaunchPolicyInput,
        terminalProgramVersion: String,
        initialGridPinned: Bool = false
    ) {
        self.launchInput = launchInput
        self.terminalProgramVersion = terminalProgramVersion
        self.initialGridPinned = initialGridPinned
    }
}

/// Assembles pane values, ambient facts, and the pinned terminal identity without IO.
public func assembleTerminalPaneLaunch(
    request: TerminalPaneLaunchRequest,
    facts: TerminalPaneLaunchFacts
) -> TerminalPaneLaunchConfiguration {
    let dimensions = request.initialDimensions ?? terminalPaneInitialDimensions
    var advertisedEnvironment = [
        EnvironmentEntry(name: "TERM", value: "xterm-256color"),
        EnvironmentEntry(name: "COLORTERM", value: "truecolor"),
        EnvironmentEntry(name: "TERM_PROGRAM", value: "DanTerm"),
        EnvironmentEntry(
            name: "TERM_PROGRAM_VERSION",
            value: facts.terminalProgramVersion
        ),
    ]
    let inheritedLocaleNames = Set(["LC_ALL", "LC_CTYPE", "LANG"])
    let hasInheritedLocale = facts.inheritedEnvironment.contains {
        inheritedLocaleNames.contains($0.name) && $0.value.isEmpty == false
    }
    if let localeFallback = facts.localeFallback, hasInheritedLocale == false {
        advertisedEnvironment.append(EnvironmentEntry(name: "LANG", value: localeFallback))
    }
    advertisedEnvironment.append(EnvironmentEntry(
        name: "DANTERM_SHELL_INTEGRATION_DIR",
        value: facts.shellIntegrationDirectory
    ))
    return TerminalPaneLaunchConfiguration(
        launchInput: LaunchPolicyInput(
            accountShell: facts.accountShell,
            executablePaths: facts.executablePaths,
            requestedWorkingDirectory: request.workingDirectory,
            homeDirectory: facts.homeDirectory,
            accessibleDirectories: facts.accessibleDirectories,
            inheritedEnvironment: facts.inheritedEnvironment,
            advertisedEnvironment: advertisedEnvironment,
            paneEnvironment: request.environment,
            command: request.command,
            launchCommand: request.launchCommand,
            initialDimensions: dimensions
        ),
        terminalProgramVersion: facts.terminalProgramVersion,
        initialGridPinned: request.initialDimensions != nil
    )
}
