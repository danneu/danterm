// Pure launch-spec resolution for the shell and cwd candidate ladders,
// environment precedence, and initial PTY geometry. The host supplies every
// ambient fact, and nothing here reads the filesystem: which candidate works is
// settled by the spawn, not by this file.

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
    /// Account-database shell, the first candidate of the shell ladder.
    public var accountShell: String?
    /// Pane-requested cwd, the first candidate of the cwd ladder.
    public var requestedWorkingDirectory: String?
    /// Account home used as the second cwd candidate.
    public var homeDirectory: String?
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
        requestedWorkingDirectory: String?,
        homeDirectory: String?,
        inheritedEnvironment: [EnvironmentEntry],
        advertisedEnvironment: [EnvironmentEntry],
        paneEnvironment: [EnvironmentEntry],
        command: String?,
        launchCommand: String?,
        initialDimensions: TerminalDimensions
    ) {
        self.accountShell = accountShell
        self.requestedWorkingDirectory = requestedWorkingDirectory
        self.homeDirectory = homeDirectory
        self.inheritedEnvironment = inheritedEnvironment
        self.advertisedEnvironment = advertisedEnvironment
        self.paneEnvironment = paneEnvironment
        self.command = command
        self.launchCommand = launchCommand
        self.initialDimensions = initialDimensions
    }
}

/// Policy failures detected before the host attempts a system spawn.
///
/// Shell and cwd viability is not among them. Both ladders always carry a
/// candidate, and the spawn itself is the only test of whether one works.
public enum LaunchPolicyError: Error, Equatable, Sendable {
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

/// Two independent ordered candidate ladders the reducer walks one spawn at a time.
///
/// The ladders stay separate because the child bootstrap reports `chdir` and
/// `execve` as distinct stages, so each failure names exactly one ladder to
/// advance and no rejected candidate is ever retried. Both ladders are non-empty
/// by construction, so a plan always has a first attempt.
public struct ResolvedLaunchPlan: Equatable, Sendable {
    /// Account shell, zsh, then sh, with nil and repeated candidates dropped.
    public let shells: [String]
    /// Requested cwd, home, then root, with nil and repeated candidates dropped.
    public let workingDirectories: [String]
    /// One byte-exact write issued after spawn readiness, or nil for no initial input.
    public let initialInput: [UInt8]?
    private let environment: [EnvironmentEntry]
    private let initialDimensions: TerminalDimensions

    init(
        shells: [String],
        workingDirectories: [String],
        initialInput: [UInt8]?,
        environment: [EnvironmentEntry],
        initialDimensions: TerminalDimensions
    ) {
        self.shells = shells
        self.workingDirectories = workingDirectories
        self.initialInput = initialInput
        self.environment = environment
        self.initialDimensions = initialDimensions
    }

    /// Builds the spawn request for one point on the two ladders. Public because the
    /// host and its tests read the spec the reducer is about to hand them; the
    /// environment and geometry it closes over are the same for every pair.
    public func spec(shell shellIndex: Int, workingDirectory cwdIndex: Int) -> PTYLaunchSpec {
        let shell = shells[shellIndex]
        return PTYLaunchSpec(
            program: shell,
            arguments: ["-" + shellName(shell)],
            workingDirectory: workingDirectories[cwdIndex],
            environment: environment,
            initialDimensions: initialDimensions
        )
    }
}

/// Resolves injected host facts into the two deterministic candidate ladders.
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

    return .success(ResolvedLaunchPlan(
        shells: ladder([absoluteShell(input.accountShell), "/bin/zsh", "/bin/sh"]),
        workingDirectories: ladder([input.requestedWorkingDirectory, input.homeDirectory, "/"]),
        initialInput: initialInput,
        environment: mergedEnvironment(
            input.inheritedEnvironment,
            overrides: input.advertisedEnvironment + input.paneEnvironment
        ),
        initialDimensions: input.initialDimensions
    ))
}

/// Drops a relative account shell instead of searching for it, so whether a shell
/// can be executed never depends on which cwd the other ladder currently offers.
private func absoluteShell(_ accountShell: String?) -> String? {
    accountShell.flatMap { $0.hasPrefix("/") ? $0 : nil }
}

/// Drops nil and repeated candidates without moving a candidate that survives.
private func ladder(_ candidates: [String?]) -> [String] {
    var result: [String] = []
    for candidate in candidates.compactMap({ $0 }) where result.contains(candidate) == false {
        result.append(candidate)
    }
    return result
}

/// Extracts the final path component needed for login-form argv[0].
private func shellName(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
}

/// Applies last-layer-wins values without losing deterministic first-seen ordering.
///
/// Public because launch assembly composes the advertised list with the same rule
/// this function gives the launch environment: a layer that restates a name it does
/// not own supplies neither the value nor the position.
public func mergedEnvironment(
    _ base: [EnvironmentEntry],
    overrides: [EnvironmentEntry]
) -> [EnvironmentEntry] {
    var result: [EnvironmentEntry] = []
    for entry in base + overrides {
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
