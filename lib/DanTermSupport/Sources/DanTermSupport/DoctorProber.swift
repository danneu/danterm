// Portable filesystem and PATH probes for `danterm doctor`. This file gathers
// integration facts only; the status ladder and user-facing report stay in the
// pure core so they can be tested without side effects.
import Foundation
import DanTermProtocol

/// Injectable environment for doctor probes. Tests point every path at temp
/// fixtures; production uses live HOME, PATH, argv0, and installer dependencies.
struct DoctorProbeEnv {
    var fileManager: FileManager
    var environment: [String: String]
    var homeDirectory: URL
    var argv0: String
    var installerDeps: CLIPathInstaller.Dependencies

    static var live: DoctorProbeEnv {
        let environment = ProcessInfo.processInfo.environment
        return DoctorProbeEnv(
            fileManager: .default,
            environment: environment,
            homeDirectory: liveHomeDirectory(environment: environment),
            argv0: CommandLine.arguments.first ?? "",
            installerDeps: .default
        )
    }
}

/// Reads the local machine integration state for `danterm doctor`. It performs
/// no IPC and does not require the app to be launched.
///
/// `configFont` is passed in rather than probed here: deciding it needs the
/// core's config document type, which this module must never depend on, so the
/// CLI composes that one fact and hands it over.
func gatherDoctorFacts(
    env: DoctorProbeEnv = .live,
    configFont: DoctorFacts.ConfigFont = .unset
) -> DoctorFacts {
    let installerDiagnostics = CLIPathInstaller(env.installerDeps).installDiagnostics()
    let runningBinary = resolvedExecutablePath(env.argv0, env: env)
    let pathDanterm = pathCommand("danterm", env: env)

    return DoctorFacts(
        claude: gatherClaudeFacts(env: env),
        codex: gatherCodexFacts(env: env),
        runningBinaryResolved: runningBinary,
        pathDanterm: pathDanterm,
        appInstallerLinkRelevant: appInstallerLinkRelevant(
            pathDanterm: pathDanterm,
            runningBinaryResolved: runningBinary,
            env: env
        ),
        bundledHookDir: bundledHookDir(forResolvedExecutable: runningBinary),
        symlinkEntry: installerDiagnostics.entry,
        translocated: installerDiagnostics.translocated,
        jqOnPath: executableOnPath("jq", env: env) != nil,
        configFont: configFont
    )
}

/// Gathers Claude Code facts from `~/.claude`, plus its agent-specific and
/// shared skill discovery roots.
private func gatherClaudeFacts(env: DoctorProbeEnv) -> DoctorFacts.Agent {
    let root = env.homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    let skillPaths = [
        root.appendingPathComponent("skills/danterm", isDirectory: true).path,
        env.homeDirectory.appendingPathComponent(".agents/skills/danterm", isDirectory: true).path,
    ]
    let present = directoryExists(at: root, fileManager: env.fileManager)
    let hooksResult = present
        ? readJSONHooks(at: root.appendingPathComponent("settings.json"), env: env)
        : HookReadResult(hooks: [], parseError: nil)

    return DoctorFacts.Agent(
        present: present,
        hooksParseError: hooksResult.parseError,
        dantermHooks: hooksResult.hooks,
        skillInstalled: skillInstalled(in: skillPaths, fileManager: env.fileManager),
        skillSearchPaths: skillPaths
    )
}

/// Gathers Codex facts from `$CODEX_HOME`, combining JSON hooks with the
/// best-effort inline hook scan from `config.toml`.
private func gatherCodexFacts(env: DoctorProbeEnv) -> DoctorFacts.Agent {
    let root = codexHome(env)
    let skillPaths = [
        root.appendingPathComponent("skills/danterm", isDirectory: true).path,
        env.homeDirectory.appendingPathComponent(".agents/skills/danterm", isDirectory: true).path,
    ]
    let present = directoryExists(at: root, fileManager: env.fileManager)
    let jsonResult = present
        ? readJSONHooks(at: root.appendingPathComponent("hooks.json"), env: env)
        : HookReadResult(hooks: [], parseError: nil)
    let tomlHooks = present
        ? readCodexTOMLHooks(at: root.appendingPathComponent("config.toml"), env: env)
        : []

    return DoctorFacts.Agent(
        present: present,
        hooksParseError: jsonResult.parseError,
        dantermHooks: jsonResult.hooks + tomlHooks,
        skillInstalled: skillInstalled(in: skillPaths, fileManager: env.fileManager),
        skillSearchPaths: skillPaths
    )
}

/// Local carrier for hook reads where malformed JSON should become a doctor
/// warning fact, not a thrown error.
private struct HookReadResult {
    let hooks: [DoctorFacts.HookRef]
    let parseError: String?
}

/// Reads a Claude/Codex JSON hooks file with the shared recursive command
/// walker, preserving malformed JSON as a warning fact instead of throwing.
private func readJSONHooks(at url: URL, env: DoctorProbeEnv) -> HookReadResult {
    guard env.fileManager.fileExists(atPath: url.path) else {
        return HookReadResult(hooks: [], parseError: nil)
    }
    do {
        let data = try Data(contentsOf: url)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let hookRoot = (value as? [String: Any])?["hooks"] else {
            return HookReadResult(hooks: [], parseError: nil)
        }
        let hooks = collectHookCommands(from: hookRoot).map { hookRef(for: $0, env: env) }
        return HookReadResult(hooks: hooks, parseError: nil)
    } catch {
        return HookReadResult(hooks: [], parseError: error.localizedDescription)
    }
}

/// Reads Codex inline TOML hooks with a narrow scanner so malformed TOML never
/// blocks doctor and only `[[hooks.*]]` command lines can contribute hooks.
private func readCodexTOMLHooks(at url: URL, env: DoctorProbeEnv) -> [DoctorFacts.HookRef] {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
        return []
    }
    return extractCodexHookCommands(from: content)
        .filter(isDanTermHookCommand)
        .map { hookRef(for: $0, env: env) }
}

/// Recursively extracts DanTerm command strings from the JSON hook shape used by
/// both Claude Code and Codex.
private func collectHookCommands(from value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
        let own = (dictionary["command"] as? String).map { isDanTermHookCommand($0) ? [$0] : [] } ?? []
        return own + dictionary.values.flatMap(collectHookCommands(from:))
    }
    if let array = value as? [Any] {
        return array.flatMap(collectHookCommands(from:))
    }
    return []
}

/// Converts a configured command string into the executable existence facts the
/// pure evaluator needs.
private func hookRef(for command: String, env: DoctorProbeEnv) -> DoctorFacts.HookRef {
    let token = firstShellToken(command) ?? command
    let status = commandFileStatus(token, env: env)
    return DoctorFacts.HookRef(command: status.path, exists: status.exists, executable: status.executable)
}

/// Resolves a command to either an explicit path or PATH candidate, preserving
/// non-executable files as present-but-not-runnable facts.
private func commandFileStatus(_ command: String, env: DoctorProbeEnv) -> (path: String, exists: Bool, executable: Bool) {
    if command.contains("/") {
        let url = absoluteURL(forPath: command, fileManager: env.fileManager)
        let status = fileStatus(at: url, fileManager: env.fileManager)
        return (url.standardizedFileURL.path, status.exists, status.executable)
    }

    if let found = executableOnPath(command, env: env) {
        return (found.path, true, true)
    }

    for directory in pathDirectories(env.environment["PATH"]) {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command)
        let status = fileStatus(at: candidate, fileManager: env.fileManager)
        if status.exists {
            return (candidate.path, true, status.executable)
        }
    }

    return (command, false, false)
}

/// Finds an executable command in the injected PATH, matching hook runtime
/// behavior closely enough for doctor diagnostics.
private func executableOnPath(_ command: String, env: DoctorProbeEnv) -> URL? {
    for directory in pathDirectories(env.environment["PATH"]) {
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command)
        if fileStatus(at: candidate, fileManager: env.fileManager).executable {
            return candidate
        }
    }
    return nil
}

/// Finds an executable command on PATH and preserves its resolved target for
/// install-health comparisons.
private func pathCommand(_ command: String, env: DoctorProbeEnv) -> PathCommand? {
    guard let candidate = executableOnPath(command, env: env) else {
        return nil
    }
    return PathCommand(path: candidate.path, resolved: candidate.resolvingSymlinksInPath().path)
}

/// Decides whether the manual `.app` installer link is relevant to this install
/// shape; Nix/profile-managed commands should not warn about missing `/usr/local`.
private func appInstallerLinkRelevant(
    pathDanterm: PathCommand?,
    runningBinaryResolved: String?,
    env: DoctorProbeEnv
) -> Bool {
    let inspectedPaths = [
        pathDanterm?.path,
        pathDanterm?.resolved,
        runningBinaryResolved,
    ].compactMap { $0 }

    if inspectedPaths.contains(where: isNixOrProfilePath) {
        return false
    }

    return inspectedPaths.contains { isManualAppHelperPath($0, homeDirectory: env.homeDirectory) }
}

/// Recognizes Nix/profile-managed paths that make `/usr/local/bin/danterm`
/// optional instead of a required health signal.
private func isNixOrProfilePath(_ path: String) -> Bool {
    path.contains("/nix/store/") || path.contains("/etc/profiles/")
}

/// Recognizes helpers from manual app installs in `/Applications` or the user's
/// `~/Applications` directory.
private func isManualAppHelperPath(_ path: String, homeDirectory: URL) -> Bool {
    guard path.hasSuffix(".app/Contents/Helpers/danterm") else {
        return false
    }

    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let userApplications = homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        .standardizedFileURL.path
    return standardized.hasPrefix("/Applications/")
        || standardized.hasPrefix(userApplications + "/")
}

/// Checks whether a filesystem entry exists and is executable without counting
/// directories as runnable hook scripts.
private func fileStatus(at url: URL, fileManager: FileManager) -> (exists: Bool, executable: Bool) {
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return (
        exists: exists,
        executable: exists && isDirectory.boolValue == false && fileManager.isExecutableFile(atPath: url.path)
    )
}

/// Recognizes DanTerm hook commands by bundled hook directory or script
/// basename, matching the documented v1 hook identification rule.
private func isDanTermHookCommand(_ command: String) -> Bool {
    if command.contains("/danterm-hooks/") {
        return true
    }
    guard let token = firstShellToken(command),
          let basename = token.split(separator: "/").last
    else {
        return false
    }
    return basename.hasPrefix("danterm-")
}

/// Pulls out the executable token from simple hook command strings, enough for
/// quoted absolute paths and bare commands without becoming a shell parser.
private func firstShellToken(_ command: String) -> String? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else {
        return nil
    }
    if first == "\"" || first == "'" {
        let body = trimmed.dropFirst()
        guard let end = body.firstIndex(of: first) else {
            return String(body)
        }
        return String(body[..<end])
    }
    return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
}

/// Extracts a TOML `command = ...` value from one already-selected hook-table
/// line.
private func extractTOMLCommand(from line: String) -> String? {
    let trimmed = stripTOMLComment(from: line).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let equals = trimmed.firstIndex(of: "=") else {
        return nil
    }
    let key = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
    guard key == "command" else {
        return nil
    }
    let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = value.first else {
        return nil
    }
    if first == "\"" || first == "'" {
        let body = value.dropFirst()
        guard let end = body.firstIndex(of: first) else {
            return nil
        }
        return String(body[..<end])
    }
    return value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
}

/// Walks Codex config text and returns only command lines inside `[[hooks.*]]`
/// array-of-table blocks.
private func extractCodexHookCommands(from content: String) -> [String] {
    var inHookTable = false
    var commands: [String] = []
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = stripTOMLComment(from: String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("[[") && line.hasSuffix("]]") {
            inHookTable = line.hasPrefix("[[hooks.")
            continue
        }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            inHookTable = false
            continue
        }
        if inHookTable, let command = extractTOMLCommand(from: line) {
            commands.append(command)
        }
    }
    return commands
}

/// Removes unquoted TOML comments so scanner decisions do not treat commented
/// command examples as active hooks.
private func stripTOMLComment(from line: String) -> String {
    var result = ""
    var quote: Character?
    for character in line {
        if character == "\"" || character == "'" {
            if quote == character {
                quote = nil
            } else if quote == nil {
                quote = character
            }
        }
        if character == "#", quote == nil {
            break
        }
        result.append(character)
    }
    return result
}

/// Checks the agent-specific and shared skill roots for a readable SKILL.md,
/// which prevents empty directories or broken symlinks from false-OKing.
private func skillInstalled(in paths: [String], fileManager: FileManager) -> Bool {
    paths.contains { path in
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }
        return fileManager.isReadableFile(atPath: root.appendingPathComponent("SKILL.md").path)
    }
}

/// Tests directory presence without following doctor into any content reads.
private func directoryExists(at url: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

/// Resolves Codex's discovery root from `$CODEX_HOME`, falling back to
/// `~/.codex` under the injected home directory.
private func codexHome(_ env: DoctorProbeEnv) -> URL {
    if let raw = env.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       raw.isEmpty == false
    {
        return URL(fileURLWithPath: raw)
    }
    return env.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
}

/// Resolves the running CLI path from argv0, including PATH lookup for bare
/// command names.
private func resolvedExecutablePath(_ argv0: String, env: DoctorProbeEnv) -> String? {
    guard argv0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return nil
    }
    let token = firstShellToken(argv0) ?? argv0
    if token.contains("/") {
        return absoluteURL(forPath: token, fileManager: env.fileManager).resolvingSymlinksInPath().path
    }
    if let found = executableOnPath(token, env: env) {
        return found.resolvingSymlinksInPath().path
    }
    return nil
}

/// Finds the app bundle's bundled hook directory from a resolved helper path, if
/// the helper lives under a `.app` ancestor.
private func bundledHookDir(forResolvedExecutable path: String?) -> String? {
    guard let path else {
        return nil
    }
    var url = URL(fileURLWithPath: path)
    while url.path != "/" {
        if url.pathExtension == "app" {
            return url.appendingPathComponent("Contents/Resources/danterm-hooks").path
        }
        url.deleteLastPathComponent()
    }
    return nil
}

/// Makes a relative command path absolute against the current working directory
/// while leaving absolute paths intact.
private func absoluteURL(forPath path: String, fileManager: FileManager) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(path)
}

/// Splits PATH into usable directories, dropping empty components.
private func pathDirectories(_ path: String?) -> [String] {
    (path ?? "").split(separator: ":", omittingEmptySubsequences: false).compactMap { component in
        let directory = String(component)
        return directory.isEmpty ? nil : directory
    }
}

/// Honors a CLI-provided HOME first so local doctor runs and smoke tests probe
/// the same home directory the process environment exposes.
private func liveHomeDirectory(environment: [String: String]) -> URL {
    if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       home.isEmpty == false
    {
        return URL(fileURLWithPath: home, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}
