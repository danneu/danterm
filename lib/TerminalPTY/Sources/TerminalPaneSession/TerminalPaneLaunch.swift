// Pure assembly of pane request values and injected ambient launch facts.
import PaneProcessLifecycle
import TerminalCore

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
    /// The embedder's own name and version, the only source of the product identity
    /// this launch advertises.
    public let productIdentity: TerminalProductIdentity
    /// Product-specific variables the embedder wants the child to inherit. Assembly
    /// carries them without knowing any of their names, so no product variable is
    /// spelled in the engine.
    public let productEnvironment: [EnvironmentEntry]

    /// Captures ambient facts once so launch assembly remains deterministic.
    public init(
        accountShell: String?,
        executablePaths: [String],
        homeDirectory: String?,
        accessibleDirectories: [String],
        inheritedEnvironment: [EnvironmentEntry],
        localeFallback: String?,
        productIdentity: TerminalProductIdentity,
        productEnvironment: [EnvironmentEntry]
    ) {
        self.accountShell = accountShell
        self.executablePaths = executablePaths
        self.homeDirectory = homeDirectory
        self.accessibleDirectories = accessibleDirectories
        self.inheritedEnvironment = inheritedEnvironment
        self.localeFallback = localeFallback
        self.productIdentity = productIdentity
        self.productEnvironment = productEnvironment
    }
}

/// Carries the host/launch geometry once, so the two consumers cannot disagree about it.
public struct TerminalPaneLaunchConfiguration: Equatable, Sendable {
    /// Launch policy input, the single source of the pane's initial geometry.
    public let launchInput: LaunchPolicyInput
    /// Product identity shared by the child environment and terminal query replies.
    public let productIdentity: TerminalProductIdentity
    /// Whether the pane's launch geometry is an override rather than a slot-derived grid.
    /// A pane is born pinned only when its request named a grid, so the recorder's birth
    /// geometry states the same fact its first recorded resize would.
    public let initialGridPinned: Bool

    /// Creates the coupled boundary the app uses to construct the PTY host.
    public init(
        launchInput: LaunchPolicyInput,
        productIdentity: TerminalProductIdentity,
        initialGridPinned: Bool = false
    ) {
        self.launchInput = launchInput
        self.productIdentity = productIdentity
        self.initialGridPinned = initialGridPinned
    }
}

/// Assembles pane values, ambient facts, and the pinned terminal identity without IO.
public func assembleTerminalPaneLaunch(
    request: TerminalPaneLaunchRequest,
    facts: TerminalPaneLaunchFacts
) -> TerminalPaneLaunchConfiguration {
    let dimensions = request.initialDimensions ?? terminalPaneInitialDimensions
    let identityEntries = [
        EnvironmentEntry(name: "TERM_PROGRAM", value: facts.productIdentity.name),
        EnvironmentEntry(name: "TERM_PROGRAM_VERSION", value: facts.productIdentity.version),
    ]
    var advertisedEnvironment = [
        EnvironmentEntry(name: "TERM", value: "xterm-256color"),
        EnvironmentEntry(name: "COLORTERM", value: "truecolor"),
    ] + identityEntries
    let inheritedLocaleNames = Set(["LC_ALL", "LC_CTYPE", "LANG"])
    let hasInheritedLocale = facts.inheritedEnvironment.contains {
        inheritedLocaleNames.contains($0.name) && $0.value.isEmpty == false
    }
    if let localeFallback = facts.localeFallback, hasInheritedLocale == false {
        advertisedEnvironment.append(EnvironmentEntry(name: "LANG", value: localeFallback))
    }
    advertisedEnvironment += facts.productEnvironment
    // Identity is the sole writer of the two identity names, by construction rather
    // than by filtering the product's entries: applying it last overwrites a restated
    // name in place, so the product environment can neither supply the value nor move
    // where the entry sits.
    advertisedEnvironment = mergedEnvironment(advertisedEnvironment, overrides: identityEntries)
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
        productIdentity: facts.productIdentity,
        initialGridPinned: request.initialDimensions != nil
    )
}
