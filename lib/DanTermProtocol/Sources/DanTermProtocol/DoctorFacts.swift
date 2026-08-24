// Shared facts for the `danterm doctor` health check. DanTermSupport gathers
// this DTO from the filesystem and PATH; the CLI evaluates and renders it.

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
    /// Whether the running app can use one macOS privacy-controlled capability.
    public enum PermissionState: String, Codable, Equatable, Sendable {
        case granted
        case denied
        case unknown
        case unavailable
    }

    /// App-owned permission results returned to the local doctor process over IPC.
    public struct Permissions: Codable, Equatable, Sendable {
        public var notifications: PermissionState
        public var fullDiskAccess: PermissionState
        public var developerTools: PermissionState

        public init(
            notifications: PermissionState,
            fullDiskAccess: PermissionState,
            developerTools: PermissionState
        ) {
            self.notifications = notifications
            self.fullDiskAccess = fullDiskAccess
            self.developerTools = developerTools
        }

        public static let unavailable = Permissions(
            notifications: .unavailable,
            fullDiskAccess: .unavailable,
            developerTools: .unavailable
        )
    }

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

    /// A total per-integration fact set whose order follows the shared registry.
    public struct Agents: Equatable {
        private var values: [Agent]

        /// Resolves exactly one fact value for every supported integration.
        public init(resolve: (AgentIntegration) -> Agent) {
            values = AgentIntegration.allCases.map(resolve)
        }

        /// Returns the fact for a supported integration without optional lookup.
        public subscript(integration: AgentIntegration) -> Agent {
            get { values[Self.index(of: integration)] }
            set { values[Self.index(of: integration)] = newValue }
        }

        /// Pairs facts with integrations in the registry's stable order.
        public var ordered: [(integration: AgentIntegration, facts: Agent)] {
            AgentIntegration.allCases.enumerated().map { index, integration in
                (integration, values[index])
            }
        }

        private static func index(of integration: AgentIntegration) -> Int {
            AgentIntegration.allCases.firstIndex(of: integration)!
        }
    }

    /// One DanTerm hook command discovered in an agent config, with executable
    /// state already resolved so the CLI evaluator stays probe-free.
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

    /// Verdict on the config file's `font.family`, already resolved against the
    /// installed families. DanTermSupport reads the shared config contract and
    /// resolves the name through its CoreText probe before returning these facts.
    public enum ConfigFont: Equatable {
        /// No config file, or one with no `font.family`: nothing to check.
        case unset
        /// A config file exists but is not a decodable schemaVersion 1 document.
        case unreadableConfig
        /// The requested name resolved to an installed family.
        case installed
        /// Nothing installed carries this name; the system monospace font applies.
        case notInstalled(requested: String)
    }

    public var agents: Agents
    public var runningBinaryResolved: String?
    public var pathDanterm: PathCommand?
    public var appInstallerLinkRelevant: Bool
    public var bundledHookDir: String?
    public var symlinkEntry: SymlinkEntry
    public var translocated: Bool
    public var jqOnPath: Bool
    public var configFont: ConfigFont
    public var permissions: Permissions

    public init(
        agents: Agents,
        runningBinaryResolved: String?,
        pathDanterm: PathCommand?,
        appInstallerLinkRelevant: Bool,
        bundledHookDir: String?,
        symlinkEntry: SymlinkEntry,
        translocated: Bool,
        jqOnPath: Bool,
        configFont: ConfigFont,
        permissions: Permissions = .unavailable
    ) {
        self.agents = agents
        self.runningBinaryResolved = runningBinaryResolved
        self.pathDanterm = pathDanterm
        self.appInstallerLinkRelevant = appInstallerLinkRelevant
        self.bundledHookDir = bundledHookDir
        self.symlinkEntry = symlinkEntry
        self.translocated = translocated
        self.jqOnPath = jqOnPath
        self.configFont = configFont
        self.permissions = permissions
    }
}
