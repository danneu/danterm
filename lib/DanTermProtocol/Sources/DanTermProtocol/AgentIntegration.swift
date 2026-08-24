// The ordered coding-agent registry shared by session presentation and doctor.
// Filesystem policy is declarative here; DanTermSupport interprets it.

/// One coding-agent integration DanTerm supports across presentation and doctor.
public enum AgentIntegration: String, CaseIterable, Equatable, Hashable, Sendable {
    case claude
    case codex

    /// A declarative rule for finding one integration's configuration root.
    public enum HomePolicy: Equatable, Sendable {
        case homeSubdirectory(name: String, displayRoot: String)
        case environmentOverride(variable: String, fallbackSubdirectory: String, displayRoot: String)

        /// The stable form doctor uses in configuration diagnostics.
        public var displayRoot: String {
            switch self {
            case .homeSubdirectory(_, let displayRoot),
                 .environmentOverride(_, _, let displayRoot):
                return displayRoot
            }
        }
    }

    /// A declarative hook configuration source interpreted by DanTermSupport.
    public enum HookSource: Equatable, Sendable {
        case json(relativePath: String)
        case codexTOML(relativePath: String)

        /// The path relative to the integration home.
        public var relativePath: String {
            switch self {
            case .json(let relativePath), .codexTOML(let relativePath):
                return relativePath
            }
        }

        /// Whether malformed input becomes a doctor parse-error fact.
        public var reportsParseErrors: Bool {
            if case .json = self { return true }
            return false
        }
    }

    /// The user-facing name used for sessions and pane chrome.
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// The product name used in doctor installation messages.
    public var doctorName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The non-generic pane chip shipped for this integration.
    public var chipKind: ChipKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// The policy DanTermSupport uses to resolve this integration's home.
    public var homePolicy: HomePolicy {
        switch self {
        case .claude:
            return .homeSubdirectory(name: ".claude", displayRoot: "~/.claude")
        case .codex:
            return .environmentOverride(
                variable: "CODEX_HOME",
                fallbackSubdirectory: ".codex",
                displayRoot: "$CODEX_HOME"
            )
        }
    }

    /// Hook sources in the order their discovered commands are combined.
    public var hookSources: [HookSource] {
        switch self {
        case .claude:
            return [.json(relativePath: "settings.json")]
        case .codex:
            return [
                .json(relativePath: "hooks.json"),
                .codexTOML(relativePath: "config.toml"),
            ]
        }
    }

    /// The stable doctor label for all hook sources of this integration.
    public var hookConfigDescription: String {
        describedHookPaths(hookSources)
    }

    /// The stable doctor label for hook sources that report parse errors.
    public var hookParseErrorDescription: String {
        describedHookPaths(hookSources.filter(\.reportsParseErrors))
    }

    /// The script name shipped in DanTerm's explicit per-agent bundle entries.
    public var bundledSessionHookName: String {
        switch self {
        case .claude: return "danterm-claude-agent-session"
        case .codex: return "danterm-codex-agent-session"
        }
    }

    /// Builds the shell-safe resume command for a validated session id.
    public func resumeCommand(sessionId: String) -> String {
        switch self {
        case .claude: return "claude --resume \(sessionId)"
        case .codex: return "codex resume \(sessionId)"
        }
    }

    private func describedHookPaths(_ sources: [HookSource]) -> String {
        guard let first = sources.first else { return homePolicy.displayRoot }
        return (["\(homePolicy.displayRoot)/\(first.relativePath)"] + sources.dropFirst().map(\.relativePath))
            .joined(separator: " or ")
    }
}
