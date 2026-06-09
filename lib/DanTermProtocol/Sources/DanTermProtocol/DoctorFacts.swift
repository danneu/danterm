// Shared facts for the `danterm doctor` health check. DanTermSupport gathers
// this DTO from the filesystem and PATH; DanTermCore reads it to evaluate and
// render the report without importing any side-effecting support code.

/// Filesystem state for the manual `.app` installer's `danterm` link, separated
/// from the evaluator so each remedy can match what the installer accepts.
public enum SymlinkEntry: Equatable {
    case missing
    case symlink(target: String, targetExists: Bool)
    case nonSymlink
}

/// The first executable command found on PATH, preserving both the PATH entry
/// and its resolved target so doctor can detect stale command precedence.
public struct PathCommand: Equatable {
    public var path: String
    public var resolved: String?

    public init(path: String, resolved: String?) {
        self.path = path
        self.resolved = resolved
    }
}

/// Snapshot of integration-health facts gathered by the portable support layer.
/// It lives in DanTermProtocol because support and core can both depend on this
/// leaf module while staying independent of each other.
public struct DoctorFacts: Equatable {
    /// Facts for one coding-agent integration root: presence, hooks, and skill
    /// discovery paths.
    public struct Agent: Equatable {
        public var present: Bool
        public var hooksParseError: String?
        public var dantermHooks: [HookRef]
        public var skillInstalled: Bool
        public var skillSearchPaths: [String]

        public init(
            present: Bool,
            hooksParseError: String?,
            dantermHooks: [HookRef],
            skillInstalled: Bool,
            skillSearchPaths: [String]
        ) {
            self.present = present
            self.hooksParseError = hooksParseError
            self.dantermHooks = dantermHooks
            self.skillInstalled = skillInstalled
            self.skillSearchPaths = skillSearchPaths
        }
    }

    /// One DanTerm hook command discovered in an agent config, with executable
    /// state already resolved so the core can stay filesystem-free.
    public struct HookRef: Equatable {
        public var command: String
        public var exists: Bool
        public var executable: Bool

        public init(command: String, exists: Bool, executable: Bool) {
            self.command = command
            self.exists = exists
            self.executable = executable
        }
    }

    public var claude: Agent
    public var codex: Agent
    public var runningBinaryResolved: String?
    public var pathDanterm: PathCommand?
    public var appInstallerLinkRelevant: Bool
    public var bundledHookDir: String?
    public var symlinkEntry: SymlinkEntry
    public var translocated: Bool
    public var jqOnPath: Bool

    public init(
        claude: Agent,
        codex: Agent,
        runningBinaryResolved: String?,
        pathDanterm: PathCommand?,
        appInstallerLinkRelevant: Bool,
        bundledHookDir: String?,
        symlinkEntry: SymlinkEntry,
        translocated: Bool,
        jqOnPath: Bool
    ) {
        self.claude = claude
        self.codex = codex
        self.runningBinaryResolved = runningBinaryResolved
        self.pathDanterm = pathDanterm
        self.appInstallerLinkRelevant = appInstallerLinkRelevant
        self.bundledHookDir = bundledHookDir
        self.symlinkEntry = symlinkEntry
        self.translocated = translocated
        self.jqOnPath = jqOnPath
    }
}
