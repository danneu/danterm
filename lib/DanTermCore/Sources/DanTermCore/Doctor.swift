// Pure evaluator and renderer for `danterm doctor`. This file owns the
// integration-health decision table and text output, but no probing: filesystem,
// PATH, and app-bundle facts arrive as DoctorFacts from DanTermSupport.
import DanTermProtocol

/// Stable identifiers for doctor checks so tests and renderers can find rows
/// without depending on display order or title text.
enum DoctorCheckID: Equatable {
    case claudeHooks
    case claudeSkill
    case codexHooks
    case codexSkill
    case pathCLI
    case manualAppLink
    case translocation
    case jq
    case configFont
    case notifications
    case fullDiskAccess
    case developerTools
}

/// Severity-like result for one doctor check. Only `.error` maps to a failing
/// process exit; warnings and skipped checks are advisory.
enum DoctorStatus: Equatable {
    case ok
    case skip
    case info
    case warn
    case error
}

/// One rendered-health row before text formatting. OK rows intentionally carry
/// no message, so they print as a bare `OK <title>` line with nothing to report.
struct DoctorCheck: Equatable {
    let id: DoctorCheckID
    let title: String
    let status: DoctorStatus
    let message: String?
}

/// Applies the doctor status ladders to already-gathered facts, keeping the
/// integration-health rules testable without AppKit, sockets, or filesystem IO.
func evaluateDoctor(_ facts: DoctorFacts) -> [DoctorCheck] {
    [
        evaluateHooks(
            id: .claudeHooks,
            title: "Claude hooks valid",
            agentName: "Claude Code",
            configDescription: "~/.claude/settings.json",
            parseErrorDescription: "~/.claude/settings.json",
            bundledHookName: "danterm-claude-agent-session",
            agent: facts.claude,
            bundledHookDir: facts.bundledHookDir
        ),
        evaluateSkill(
            id: .claudeSkill,
            title: "Claude skill installed",
            agentName: "Claude Code",
            agent: facts.claude
        ),
        evaluateHooks(
            id: .codexHooks,
            title: "Codex hooks valid",
            agentName: "Codex",
            configDescription: "$CODEX_HOME/hooks.json or config.toml",
            parseErrorDescription: "$CODEX_HOME/hooks.json",
            bundledHookName: "danterm-codex-agent-session",
            agent: facts.codex,
            bundledHookDir: facts.bundledHookDir
        ),
        evaluateSkill(
            id: .codexSkill,
            title: "Codex skill installed",
            agentName: "Codex",
            agent: facts.codex
        ),
        evaluatePathCLI(facts),
        evaluateManualAppLink(facts),
        evaluateTranslocation(facts),
        evaluateJQ(facts),
        evaluateConfigFont(facts),
        evaluatePermission(
            id: .notifications,
            title: "Notifications enabled",
            deniedTitle: "Notifications disabled",
            state: facts.permissions.notifications,
            deniedMessage: "Enable DanTerm in System Settings > Notifications."
        ),
        evaluatePermission(
            id: .fullDiskAccess,
            title: "Full Disk Access permission granted",
            deniedTitle: "Full Disk Access permission not granted",
            state: facts.permissions.fullDiskAccess,
            deniedMessage: "Enable DanTerm in System Settings > Privacy & Security > Full Disk Access, then relaunch DanTerm."
        ),
        evaluatePermission(
            id: .developerTools,
            title: "Developer Tools permission granted",
            deniedTitle: "Developer Tools permission not granted",
            state: facts.permissions.developerTools,
            deniedMessage: "Enable DanTerm in System Settings > Privacy & Security > Developer Tools, then relaunch DanTerm."
        ),
    ]
}

/// Maps an app-owned permission probe into the common advisory doctor ladder.
private func evaluatePermission(
    id: DoctorCheckID,
    title: String,
    deniedTitle: String,
    state: DoctorFacts.PermissionState,
    deniedMessage: String
) -> DoctorCheck {
    switch state {
    case .granted:
        return DoctorCheck(id: id, title: title, status: .ok, message: nil)
    case .denied:
        return DoctorCheck(id: id, title: deniedTitle, status: .warn, message: deniedMessage)
    case .unknown:
        return DoctorCheck(
            id: id,
            title: title,
            status: .skip,
            message: "The permission state could not be checked on this Mac."
        )
    case .unavailable:
        return DoctorCheck(
            id: id,
            title: title,
            status: .skip,
            message: "DanTerm is not running, so its permissions cannot be checked."
        )
    }
}

/// Renders doctor checks in the CLI's plain text format: one line per check
/// (OK rows included), followed by the summary footer.
func renderDoctorReport(_ checks: [DoctorCheck]) -> String {
    let body = checks.map { check -> String in
        let prefix = statusPrefix(check.status)
        guard let message = check.message, !message.isEmpty else {
            return "\(prefix) \(check.title)"
        }
        return "\(prefix) \(check.title): \(message)"
    }

    return (body + [renderFooter(checks)]).joined(separator: "\n") + "\n"
}

/// Maps the evaluated doctor checks to the CLI process status. Errors fail;
/// warnings, infos, skipped checks, and OK rows remain scriptable success.
func doctorExitCode(for checks: [DoctorCheck]) -> Int32 {
    checks.contains { $0.status == .error } ? 1 : 0
}

/// Evaluates one agent's hook configuration, prioritizing unusable wired hooks
/// over malformed or missing setup so actionable failures are not hidden.
private func evaluateHooks(
    id: DoctorCheckID,
    title: String,
    agentName: String,
    configDescription: String,
    parseErrorDescription: String,
    bundledHookName: String,
    agent: DoctorFacts.Agent,
    bundledHookDir: String?
) -> DoctorCheck {
    guard agent.present else {
        return DoctorCheck(id: id, title: title, status: .info, message: "\(agentName) not installed.")
    }

    if let dangling = agent.dantermHooks.first(where: { $0.exists == false }) {
        let hookName = hookBasename(dangling.command, fallback: bundledHookName)
        let hookDir = bundledHookDir ?? "/Applications/DanTerm.app/Contents/Resources/danterm-hooks"
        return DoctorCheck(
            id: id,
            title: title,
            status: .error,
            message: "Hook in \(configDescription) points to missing \(dangling.command); repoint to \(hookDir)/\(hookName) or remove it."
        )
    }

    if let notExecutable = agent.dantermHooks.first(where: { $0.executable == false }) {
        return DoctorCheck(
            id: id,
            title: title,
            status: .error,
            message: "Hook \(notExecutable.command) exists but isn't executable, so the agent can't run it; restore it with chmod +x \(notExecutable.command) (or reinstall from the DanTerm bundle)."
        )
    }

    if let parseError = agent.hooksParseError {
        return DoctorCheck(
            id: id,
            title: title,
            status: .warn,
            message: "\(parseErrorDescription) is malformed (\(parseError)); DanTerm can't read its hooks."
        )
    }

    if agent.dantermHooks.isEmpty {
        return DoctorCheck(
            id: id,
            title: title,
            status: .warn,
            message: "\(agentName) found but DanTerm notifications aren't set up -- add hooks (see docs)."
        )
    }

    return DoctorCheck(id: id, title: title, status: .ok, message: nil)
}

/// Evaluates one agent's skill discovery result, keeping the missing-skill
/// remedy tied to the first search path the prober actually checked.
private func evaluateSkill(
    id: DoctorCheckID,
    title: String,
    agentName: String,
    agent: DoctorFacts.Agent
) -> DoctorCheck {
    guard agent.present else {
        return DoctorCheck(id: id, title: title, status: .skip, message: "\(agentName) not installed.")
    }
    guard agent.skillInstalled else {
        let destination = agent.skillSearchPaths.first ?? "<skill root>"
        return DoctorCheck(
            id: id,
            title: title,
            status: .warn,
            message: "Skill discovery is not installed at \(destination). Run `danterm skill` for on-demand instructions, or symlink the Nix danterm-agent-skill output or the repo's integrations/danterm there (see README \"Agent Skill\")."
        )
    }
    return DoctorCheck(id: id, title: title, status: .ok, message: nil)
}

/// Evaluates the first `danterm` command found on PATH against the binary that
/// is running this doctor command.
private func evaluatePathCLI(_ facts: DoctorFacts) -> DoctorCheck {
    guard let pathDanterm = facts.pathDanterm else {
        return DoctorCheck(
            id: .pathCLI,
            title: "danterm on PATH resolves to this running CLI",
            status: .warn,
            message: "No danterm executable found on PATH; add the installed CLI to PATH (Nix profile, Home Manager profile, or DanTerm menu > \"Install danterm Command in PATH\")."
        )
    }

    if pathDanterm.resolved == facts.runningBinaryResolved {
        return DoctorCheck(id: .pathCLI, title: "danterm on PATH resolves to this running CLI", status: .ok, message: nil)
    }

    let resolved = pathDanterm.resolved ?? pathDanterm.path
    let running = facts.runningBinaryResolved ?? "<unknown>"
    return DoctorCheck(
        id: .pathCLI,
        title: "danterm on PATH resolves to this running CLI",
        status: .warn,
        message: "danterm on PATH resolves to \(resolved), but this doctor command is running from \(running); move the intended install earlier in PATH or run that binary's doctor."
    )
}

/// Evaluates the manual `.app` `/usr/local/bin/danterm` installer link only
/// when the running install shape makes that link relevant.
private func evaluateManualAppLink(_ facts: DoctorFacts) -> DoctorCheck {
    guard facts.appInstallerLinkRelevant else {
        return DoctorCheck(id: .manualAppLink, title: "Manual app CLI link healthy", status: .ok, message: nil)
    }

    switch facts.symlinkEntry {
    case .missing:
        return staleManualAppLinkCheck()
    case .symlink(_, targetExists: false):
        return staleManualAppLinkCheck()
    case .symlink(let target, targetExists: true):
        if target == facts.runningBinaryResolved {
            return DoctorCheck(id: .manualAppLink, title: "Manual app CLI link healthy", status: .ok, message: nil)
        }
        return DoctorCheck(
            id: .manualAppLink,
            title: "Manual app CLI link healthy",
            status: .warn,
            message: "/usr/local/bin/danterm points to \(target), but this doctor command is running from \(facts.runningBinaryResolved ?? "<unknown>"); reinstall the DanTerm command or run the intended binary's doctor."
        )
    case .nonSymlink:
        return DoctorCheck(
            id: .manualAppLink,
            title: "Manual app CLI link healthy",
            status: .warn,
            message: "/usr/local/bin/danterm exists but is a regular file/directory, not a symlink, so \"Install danterm Command in PATH\" can't replace it; remove or rename it first, then reinstall."
        )
    }
}

/// Emits the standalone AppTranslocation warning without gating any other
/// checks, since hook and CLI-link facts remain independently inspectable.
private func evaluateTranslocation(_ facts: DoctorFacts) -> DoctorCheck {
    guard facts.translocated else {
        return DoctorCheck(id: .translocation, title: "App not translocated", status: .ok, message: nil)
    }
    return DoctorCheck(
        id: .translocation,
        title: "App not translocated",
        status: .warn,
        message: "DanTerm is running from a quarantined/translocated copy, so the CLI link and hook paths are ephemeral. Move DanTerm.app to /Applications in Finder (or: xattr -dr com.apple.quarantine /Applications/DanTerm.app), relaunch."
    )
}

/// Evaluates `jq` only when at least one agent has a wired DanTerm hook that
/// would need it at runtime.
private func evaluateJQ(_ facts: DoctorFacts) -> DoctorCheck {
    let hooksConfigured = facts.claude.dantermHooks.isEmpty == false || facts.codex.dantermHooks.isEmpty == false
    guard hooksConfigured else {
        return DoctorCheck(id: .jq, title: "jq on PATH", status: .skip, message: "No DanTerm agent hooks configured.")
    }
    guard facts.jqOnPath else {
        return DoctorCheck(
            id: .jq,
            title: "jq on PATH",
            status: .warn,
            message: "jq not found; agent hooks need it. brew install jq -- ensure it lands in /usr/local/bin or /opt/homebrew/bin so GUI-launched agents see it."
        )
    }
    return DoctorCheck(id: .jq, title: "jq on PATH", status: .ok, message: nil)
}

/// Reports whether the config file's `font.family` names an installed family.
/// Every outcome is advisory: an unavailable font falls back to the system
/// monospace face, so it must never fail a scripted `danterm doctor`.
private func evaluateConfigFont(_ facts: DoctorFacts) -> DoctorCheck {
    let title = "Configured font installed"
    switch facts.configFont {
    case .unset:
        return DoctorCheck(
            id: .configFont,
            title: title,
            status: .skip,
            message: "No font.family set in ~/.config/danterm/config.json."
        )
    case .unreadableConfig:
        return DoctorCheck(
            id: .configFont,
            title: title,
            status: .warn,
            message: "~/.config/danterm/config.json can't be read as a schemaVersion 1 JSON document, so font.family is ignored; defaults are active."
        )
    case .installed:
        return DoctorCheck(id: .configFont, title: title, status: .ok, message: nil)
    case .notInstalled(let requested):
        return DoctorCheck(
            id: .configFont,
            title: title,
            status: .warn,
            message: "Font \"\(requested)\" is not installed -- using the system monospace font. Install it, or pick an installed family in Settings > Font Family."
        )
    }
}

/// Builds the shared missing-or-dangling manual app-link warning so both failure
/// modes use the same install-menu remedy.
private func staleManualAppLinkCheck() -> DoctorCheck {
    DoctorCheck(
        id: .manualAppLink,
        title: "Manual app CLI link healthy",
        status: .warn,
        message: "/usr/local/bin/danterm is missing or stale -> DanTerm menu > \"Install danterm Command in PATH\"."
    )
}

/// Extracts the hook basename used for repoint guidance, falling back to the
/// bundled script name when a command is too shell-shaped to trust.
private func hookBasename(_ command: String, fallback: String) -> String {
    guard let last = command.split(separator: "/").last, last.hasPrefix("danterm-") else {
        return fallback
    }
    return String(last)
}

/// Maps a check status to the stable text prefix used by the CLI report.
private func statusPrefix(_ status: DoctorStatus) -> String {
    switch status {
    case .ok: "OK"
    case .skip: "SKIP"
    case .info: "INFO"
    case .warn: "WARN"
    case .error: "ERROR"
    }
}

/// Counts every status class into the report footer, including OK rows.
private func renderFooter(_ checks: [DoctorCheck]) -> String {
    let errors = checks.count { $0.status == .error }
    let warnings = checks.count { $0.status == .warn }
    let infos = checks.count { $0.status == .info }
    let oks = checks.count { $0.status == .ok }
    let skipped = checks.count { $0.status == .skip }
    return [
        countPhrase(errors, singular: "error", plural: "errors"),
        countPhrase(warnings, singular: "warning", plural: "warnings"),
        countPhrase(infos, singular: "info", plural: "info"),
        countPhrase(oks, singular: "ok", plural: "ok"),
        countPhrase(skipped, singular: "skipped", plural: "skipped"),
    ].joined(separator: ", ")
}

/// Chooses singular or plural footer wording for a count.
private func countPhrase(_ count: Int, singular: String, plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
}
