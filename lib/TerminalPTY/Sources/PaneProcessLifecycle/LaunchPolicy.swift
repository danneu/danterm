// Pure launch-spec resolution for shell selection, cwd fallback, environment
// precedence, and initial PTY geometry. The host supplies every ambient fact.

/// Rows and columns kept together so launch and resize cannot mix dimensions.
public struct TerminalDimensions: Equatable, Sendable {
    /// Character columns reported to the child and terminal core.
    public let columns: Int
    /// Character rows reported to the child and terminal core.
    public let rows: Int

    /// Creates an unchecked value; launch policy and the host reject non-positive values.
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    var isValid: Bool { columns > 0 && rows > 0 }
}

/// One submitted grid together with whether that grid is pinned.
///
/// Pinned means the grid is an explicit override rather than a projection of the pane's
/// rectangle. The pair travels as one value from submission to the applied boundary, so a
/// submission superseded on the way is superseded on the whole fact, and a pinnedness change
/// at an unchanged grid is still a distinct submission. Nothing here reaches the child: the
/// PTY is told `dimensions` and nothing else.
public struct PaneGridSubmission: Equatable, Sendable {
    /// The grid reported to the child and the terminal core.
    public let dimensions: TerminalDimensions
    /// Whether that grid is an override rather than a projection of the pane's rectangle.
    public let pinned: Bool

    /// Creates one complete geometry submission.
    public init(dimensions: TerminalDimensions, pinned: Bool) {
        self.dimensions = dimensions
        self.pinned = pinned
    }

    var isValid: Bool { dimensions.isValid }
}

/// One ordered environment entry, used instead of a dictionary so spawn input is reproducible.
public struct EnvironmentEntry: Equatable, Sendable {
    /// Variable name passed to the child.
    public let name: String
    /// Variable value passed to the child.
    public let value: String

    /// Creates one explicit child-environment assignment.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Injected ambient facts and pane values from which deterministic launch attempts are built.
public struct LaunchPolicyInput: Equatable, Sendable {
    /// Account-database shell, before executable fallback policy is applied.
    public var accountShell: String?
    /// Paths the host has established are executable.
    public var executablePaths: [String]
    /// Pane-requested cwd, before accessibility fallback policy is applied.
    public var requestedWorkingDirectory: String?
    /// Account home used as the second cwd candidate.
    public var homeDirectory: String?
    /// Directories the host has established are accessible.
    public var accessibleDirectories: [String]
    /// Snapshot inherited from the app process.
    public var inheritedEnvironment: [EnvironmentEntry]
    /// Terminal identity values that override inherited entries.
    public var advertisedEnvironment: [EnvironmentEntry]
    /// Pane-scoped values that have final precedence.
    public var paneEnvironment: [EnvironmentEntry]
    /// User-authored command submitted as interactive shell input.
    public var command: String?
    /// Explicit launch command, always submitted as interactive shell input.
    public var launchCommand: String?
    /// Geometry installed before the child starts.
    public var initialDimensions: TerminalDimensions

    /// Captures all ambient launch facts at the pure policy seam.
    public init(
        accountShell: String?,
        executablePaths: [String],
        requestedWorkingDirectory: String?,
        homeDirectory: String?,
        accessibleDirectories: [String],
        inheritedEnvironment: [EnvironmentEntry],
        advertisedEnvironment: [EnvironmentEntry],
        paneEnvironment: [EnvironmentEntry],
        command: String?,
        launchCommand: String?,
        initialDimensions: TerminalDimensions
    ) {
        self.accountShell = accountShell
        self.executablePaths = executablePaths
        self.requestedWorkingDirectory = requestedWorkingDirectory
        self.homeDirectory = homeDirectory
        self.accessibleDirectories = accessibleDirectories
        self.inheritedEnvironment = inheritedEnvironment
        self.advertisedEnvironment = advertisedEnvironment
        self.paneEnvironment = paneEnvironment
        self.command = command
        self.launchCommand = launchCommand
        self.initialDimensions = initialDimensions
    }
}

/// Policy failures detected before the host attempts a system spawn.
public enum LaunchPolicyError: Error, Equatable, Sendable {
    case noUsableShell
    case invalidDimensions
    /// Initial shell input cannot fit within the pane's bounded pending-input path.
    case initialInputTooLarge
}

/// A complete, ambient-free child-spawn request interpreted by TerminalPTYHost.
public struct PTYLaunchSpec: Equatable, Sendable {
    /// Executable path selected by shell policy.
    public let program: String
    /// Login-form argv, including argv[0].
    public let arguments: [String]
    /// Cwd for this particular fallback attempt.
    public let workingDirectory: String
    /// Fully merged, deterministically ordered child environment.
    public let environment: [EnvironmentEntry]
    /// PTY geometry installed before spawn.
    public let initialDimensions: TerminalDimensions

    /// Creates the value boundary consumed by the system host.
    public init(
        program: String,
        arguments: [String],
        workingDirectory: String,
        environment: [EnvironmentEntry],
        initialDimensions: TerminalDimensions
    ) {
        self.program = program
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.initialDimensions = initialDimensions
    }
}

/// Ordered spawn attempts that differ only by cwd and may be retried on cwd failure.
public struct ResolvedLaunchPlan: Equatable, Sendable {
    /// Requested, home, and root attempts remaining after accessibility and deduplication.
    public let attempts: [PTYLaunchSpec]
    /// One byte-exact write issued after spawn readiness, or nil for no initial input.
    public let initialInput: [UInt8]?

    init(attempts: [PTYLaunchSpec], initialInput: [UInt8]?) {
        self.attempts = attempts
        self.initialInput = initialInput
    }
}

/// Resolves injected host facts into a deterministic, ordered spawn-attempt chain.
public func resolveLaunchPlan(
    _ input: LaunchPolicyInput
) -> Result<ResolvedLaunchPlan, LaunchPolicyError> {
    guard input.initialDimensions.isValid else { return .failure(.invalidDimensions) }
    let initialInput = resolvedInitialInput(
        command: input.command,
        launchCommand: input.launchCommand
    )
    guard initialInput.map({ $0.count <= PaneProcessLifecycleReducer.pendingInputByteLimit }) ?? true
    else { return .failure(.initialInputTooLarge) }
    guard let shell = selectedShell(
        accountShell: input.accountShell,
        executablePaths: input.executablePaths
    ) else {
        return .failure(.noUsableShell)
    }

    let environment = mergedEnvironment(
        input.inheritedEnvironment,
        overrides: input.advertisedEnvironment + input.paneEnvironment
    )
    let argv0 = "-" + shellName(shell)
    let directories = workingDirectories(
        requested: input.requestedWorkingDirectory,
        home: input.homeDirectory,
        accessibleDirectories: input.accessibleDirectories
    )
    return .success(ResolvedLaunchPlan(
        attempts: directories.map {
            PTYLaunchSpec(
                program: shell,
                arguments: [argv0],
                workingDirectory: $0,
                environment: environment,
                initialDimensions: input.initialDimensions
            )
        },
        initialInput: initialInput
    ))
}

/// Applies the account, zsh, then sh executable fallback contract.
private func selectedShell(accountShell: String?, executablePaths: [String]) -> String? {
    for candidate in [accountShell, "/bin/zsh", "/bin/sh"] {
        guard let candidate else { continue }
        if executablePaths.contains(candidate) { return candidate }
    }
    return nil
}

/// Extracts the final path component needed for login-form argv[0].
private func shellName(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
}

/// Builds the accessible, deduplicated cwd retry chain with root as the final fallback.
private func workingDirectories(
    requested: String?,
    home: String?,
    accessibleDirectories: [String]
) -> [String] {
    var result: [String] = []
    for candidate in [requested, home] {
        guard let candidate, accessibleDirectories.contains(candidate) else { continue }
        if !result.contains(candidate) { result.append(candidate) }
    }
    if !result.contains("/") { result.append("/") }
    return result
}

/// Applies last-layer-wins values without losing deterministic first-seen ordering.
private func mergedEnvironment(
    _ inherited: [EnvironmentEntry],
    overrides: [EnvironmentEntry]
) -> [EnvironmentEntry] {
    var result: [EnvironmentEntry] = []
    for entry in inherited + overrides {
        if let index = result.firstIndex(where: { $0.name == entry.name }) {
            result[index] = entry
        } else {
            result.append(entry)
        }
    }
    return result
}

/// Resolves user-authored command input into exactly one ordinary login-shell write.
private func resolvedInitialInput(
    command: String?,
    launchCommand: String?
) -> [UInt8]? {
    if let launchCommand, !launchCommand.isEmpty {
        return Array(terminatedForExecution(launchCommand).utf8)
    }
    guard let command, !command.isEmpty else { return nil }
    return Array(terminatedForExecution(command).utf8)
}

/// Adds a newline only when shell input does not already end in one.
private func terminatedForExecution(_ command: String) -> String {
    command.hasSuffix("\n") ? command : command + "\n"
}
