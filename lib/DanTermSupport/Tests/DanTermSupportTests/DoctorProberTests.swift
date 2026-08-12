// Tests for the `danterm doctor` support prober. Each case builds a hermetic
// temp HOME, CODEX_HOME, PATH, and CLIPathInstaller fixture so the gathered
// DoctorFacts exercise real filesystem reads without touching user config.
import Foundation
import Darwin
import Testing
import DanTermProtocol

@testable import DanTermSupport

@Suite struct DoctorProberTests {
    @Test("config font probe reports installed and missing families")
    func configFontProbeReportsInstalledAndMissingFamilies() throws {
        let fixture = try DoctorFixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig(fontFamily: "Fixture Mono")

        let installed = gatherDoctorFacts(env: fixture.env(
            resolveInstalledFontFamily: { $0 == "Fixture Mono" ? "Fixture Mono" : nil }
        ))
        let missing = gatherDoctorFacts(env: fixture.env(
            resolveInstalledFontFamily: { _ in nil }
        ))

        #expect(installed.configFont == .installed)
        #expect(missing.configFont == .notInstalled(requested: "Fixture Mono"))
    }

    @Test("config font probe reports unset when the config names no family")
    func configFontProbeReportsUnset() throws {
        let fixture = try DoctorFixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig(fontFamily: nil)

        let facts = gatherDoctorFacts(env: fixture.env())

        #expect(facts.configFont == .unset)
    }

    @Test("config font probe reports unreadable config")
    func configFontProbeReportsUnreadableConfig() throws {
        let fixture = try DoctorFixture()
        defer { fixture.cleanup() }
        try fixture.writeFile(fixture.configURL, "not JSON")

        let facts = gatherDoctorFacts(env: fixture.env())

        #expect(facts.configFont == .unreadableConfig)
    }

    @Test("JSON hook sources gather valid dangling and non-executable DanTerm hooks")
    func jsonHookSourcesGatherHookStatuses() throws {
        let fixture = try DoctorFixture()
        defer { fixture.cleanup() }
        let validHook = try fixture.makeExecutableHook(name: "danterm-claude-agent-session")
        let nonExecutableHook = try fixture.makeHook(name: "danterm-codex-agent-session", mode: 0o644)
        let missingHook = fixture.root.appendingPathComponent("missing/danterm-claude-agent-session").path
        try fixture.writeClaudeSettings(commands: [
            validHook.path,
            missingHook,
            "/usr/bin/true",
        ])
        try fixture.writeCodexHooksJSON(commands: [
            nonExecutableHook.path,
        ])

        let facts = gatherDoctorFacts(env: fixture.env())

        #expect(facts.claude.present == true)
        #expect(facts.claude.hooksParseError == nil)
        #expect(facts.claude.dantermHooks.count == 2)
        #expect(facts.claude.dantermHooks.contains(DoctorFacts.HookRef(command: validHook.path, exists: true, executable: true)))
        #expect(facts.claude.dantermHooks.contains(DoctorFacts.HookRef(command: missingHook, exists: false, executable: false)))
        #expect(facts.codex.present == true)
        #expect(facts.codex.dantermHooks == [
            DoctorFacts.HookRef(command: nonExecutableHook.path, exists: true, executable: false),
        ])
    }

    @Test("JSON hook walker ignores command outside hooks root")
    func jsonHookWalkerIgnoresCommandOutsideHooksRoot() throws {
        let noHooksRoot = try DoctorFixture()
        defer { noHooksRoot.cleanup() }
        let rootHook = try noHooksRoot.makeExecutableHook(name: "danterm-claude-agent-session")
        try noHooksRoot.createAgentRoots()
        try noHooksRoot.writeFile(noHooksRoot.home.appendingPathComponent(".claude/settings.json"), """
        {
          "command": "\(rootHook.path)"
        }
        """)

        var facts = gatherDoctorFacts(env: noHooksRoot.env())

        #expect(facts.claude.dantermHooks == [])

        let emptyHooksRoot = try DoctorFixture()
        defer { emptyHooksRoot.cleanup() }
        let hook = try emptyHooksRoot.makeExecutableHook(name: "danterm-claude-agent-session")
        try emptyHooksRoot.createAgentRoots()
        try emptyHooksRoot.writeFile(emptyHooksRoot.home.appendingPathComponent(".claude/settings.json"), """
        {
          "command": "\(hook.path)",
          "hooks": {}
        }
        """)

        facts = gatherDoctorFacts(env: emptyHooksRoot.env())

        #expect(facts.claude.dantermHooks == [])
    }

    @Test("malformed JSON records parse error but malformed TOML does not")
    func malformedJsonRecordsParseErrorButMalformedTomlDoesNot() throws {
        let fixture = try DoctorFixture()
        defer { fixture.cleanup() }
        try fixture.createAgentRoots()
        try fixture.writeFile(fixture.home.appendingPathComponent(".claude/settings.json"), "{")
        try fixture.writeFile(fixture.codexHome.appendingPathComponent("hooks.json"), "{")
        try fixture.writeFile(fixture.codexHome.appendingPathComponent("config.toml"), "[[hooks.SessionStart]\ncommand = ")

        let facts = gatherDoctorFacts(env: fixture.env())

        #expect(facts.claude.hooksParseError?.isEmpty == false)
        #expect(facts.codex.hooksParseError?.isEmpty == false)
    }

    @Test("Codex config TOML scanner collects inline DanTerm command")
    func codexConfigTomlScannerCollectsInlineDanTermCommand() throws {
        let fixture = try DoctorFixture()
        defer { fixture.cleanup() }
        let hook = try fixture.makeExecutableHook(name: "danterm-codex-agent-session")
        try fixture.createAgentRoots()
        try fixture.writeFile(fixture.codexHome.appendingPathComponent("config.toml"), """
        [[hooks.SessionStart]]
        command = "\(hook.path)"
        timeout = 2
        """)

        let facts = gatherDoctorFacts(env: fixture.env())

        #expect(facts.codex.hooksParseError == nil)
        #expect(facts.codex.dantermHooks == [
            DoctorFacts.HookRef(command: hook.path, exists: true, executable: true),
        ])
    }

    @Test("Codex config TOML scanner ignores command outside hook table")
    func codexConfigTomlScannerIgnoresCommandOutsideHookTable() throws {
        let fixture = try DoctorFixture()
        defer { fixture.cleanup() }
        let hook = try fixture.makeExecutableHook(name: "danterm-codex-agent-session")
        try fixture.createAgentRoots()
        try fixture.writeFile(fixture.codexHome.appendingPathComponent("config.toml"), """
        [tools]
        command = "\(hook.path)"
        """)

        let facts = gatherDoctorFacts(env: fixture.env())

        #expect(facts.codex.dantermHooks == [])
    }

    @Test("skill presence checks own root shared root and readable SKILL")
    func skillPresenceChecksOwnRootSharedRootAndReadableSkill() throws {
        let ownFixture = try DoctorFixture()
        defer { ownFixture.cleanup() }
        try ownFixture.createAgentRoots()
        try ownFixture.installSkill(at: ownFixture.home.appendingPathComponent(".claude/skills/danterm"))
        var facts = gatherDoctorFacts(env: ownFixture.env())
        #expect(facts.claude.skillInstalled == true)
        #expect(facts.claude.skillSearchPaths == [
            ownFixture.home.appendingPathComponent(".claude/skills/danterm").path,
            ownFixture.home.appendingPathComponent(".agents/skills/danterm").path,
        ])

        let sharedFixture = try DoctorFixture()
        defer { sharedFixture.cleanup() }
        try sharedFixture.createAgentRoots()
        try sharedFixture.installSkill(at: sharedFixture.home.appendingPathComponent(".agents/skills/danterm"))
        facts = gatherDoctorFacts(env: sharedFixture.env())
        #expect(facts.claude.skillInstalled == true)
        #expect(facts.codex.skillInstalled == true)

        let emptyFixture = try DoctorFixture()
        defer { emptyFixture.cleanup() }
        try emptyFixture.createAgentRoots()
        try FileManager.default.createDirectory(
            at: emptyFixture.codexHome.appendingPathComponent("skills/danterm"),
            withIntermediateDirectories: true
        )
        facts = gatherDoctorFacts(env: emptyFixture.env())
        #expect(facts.codex.skillInstalled == false)
        #expect(facts.codex.skillSearchPaths[0] == emptyFixture.codexHome.appendingPathComponent("skills/danterm").path)
    }

    @Test("manual app link and translocation facts come from injected installer deps")
    func manualAppLinkAndTranslocationFactsComeFromInjectedInstallerDeps() throws {
        let healthy = try DoctorFixture()
        defer { healthy.cleanup() }
        try FileManager.default.createSymbolicLink(at: healthy.destinationURL, withDestinationURL: healthy.sourceURL)
        var facts = gatherDoctorFacts(env: healthy.env())
        #expect(facts.symlinkEntry == .symlink(target: healthy.sourceURL.path, targetExists: true))
        #expect(facts.translocated == false)

        let dangling = try DoctorFixture()
        defer { dangling.cleanup() }
        let missing = dangling.root.appendingPathComponent("missing-danterm")
        try FileManager.default.createSymbolicLink(at: dangling.destinationURL, withDestinationURL: missing)
        facts = gatherDoctorFacts(env: dangling.env())
        #expect(facts.symlinkEntry == .symlink(target: missing.path, targetExists: false))

        let shadowed = try DoctorFixture()
        defer { shadowed.cleanup() }
        let other = try shadowed.makeHook(name: "other-danterm", mode: 0o755)
        try FileManager.default.createSymbolicLink(at: shadowed.destinationURL, withDestinationURL: other)
        facts = gatherDoctorFacts(env: shadowed.env())
        #expect(facts.symlinkEntry == .symlink(target: other.path, targetExists: true))

        let nonSymlink = try DoctorFixture()
        defer { nonSymlink.cleanup() }
        FileManager.default.createFile(atPath: nonSymlink.destinationURL.path, contents: Data("existing".utf8))
        facts = gatherDoctorFacts(env: nonSymlink.env())
        #expect(facts.symlinkEntry == .nonSymlink)

        let missingDestination = try DoctorFixture()
        defer { missingDestination.cleanup() }
        facts = gatherDoctorFacts(env: missingDestination.env())
        #expect(facts.symlinkEntry == .missing)

        let translocated = try DoctorFixture(bundlePath: "/private/var/folders/AppTranslocation/DanTerm.app")
        defer { translocated.cleanup() }
        facts = gatherDoctorFacts(env: translocated.env())
        #expect(facts.translocated == true)
    }

    @Test("danterm PATH scan records command and app-link relevance")
    func dantermPathScanRecordsCommandAndAppLinkRelevance() throws {
        let nix = try DoctorFixture()
        defer { nix.cleanup() }
        let nixStoreBinary = nix.root
            .appendingPathComponent("nix/store/abc-danterm/Applications/DanTerm.app/Contents/Helpers/danterm")
        try FileManager.default.createDirectory(at: nixStoreBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nixStoreBinary.path, contents: Data("cli".utf8))
        chmod(nixStoreBinary.path, 0o755)
        let nixProfileCommand = nix.pathDir.appendingPathComponent("danterm")
        try FileManager.default.createSymbolicLink(at: nixProfileCommand, withDestinationURL: nixStoreBinary)

        var facts = gatherDoctorFacts(env: nix.env(argv0: nixProfileCommand.path))
        #expect(facts.pathDanterm == PathCommand(path: nixProfileCommand.path, resolved: nixStoreBinary.path))
        #expect(facts.runningBinaryResolved == nixStoreBinary.path)
        #expect(facts.appInstallerLinkRelevant == false)

        let manual = try DoctorFixture()
        defer { manual.cleanup() }
        let manualAppBinary = manual.home
            .appendingPathComponent("Applications/DanTerm Dev.app/Contents/Helpers/danterm")
        try FileManager.default.createDirectory(at: manualAppBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: manualAppBinary.path, contents: Data("cli".utf8))
        chmod(manualAppBinary.path, 0o755)
        let manualPathCommand = manual.pathDir.appendingPathComponent("danterm")
        try FileManager.default.createSymbolicLink(at: manualPathCommand, withDestinationURL: manualAppBinary)

        facts = gatherDoctorFacts(env: manual.env(argv0: manualPathCommand.path))
        #expect(facts.pathDanterm == PathCommand(path: manualPathCommand.path, resolved: manualAppBinary.path))
        #expect(facts.runningBinaryResolved == manualAppBinary.path)
        #expect(facts.appInstallerLinkRelevant == true)
    }

    @Test("jq PATH scan requires executable file")
    func jqPathScanRequiresExecutableFile() throws {
        let executable = try DoctorFixture()
        defer { executable.cleanup() }
        _ = try executable.makePathCommand(name: "jq", mode: 0o755)
        #expect(gatherDoctorFacts(env: executable.env()).jqOnPath == true)

        let missing = try DoctorFixture()
        defer { missing.cleanup() }
        #expect(gatherDoctorFacts(env: missing.env()).jqOnPath == false)

        let nonExecutable = try DoctorFixture()
        defer { nonExecutable.cleanup() }
        _ = try nonExecutable.makePathCommand(name: "jq", mode: 0o644)
        #expect(gatherDoctorFacts(env: nonExecutable.env()).jqOnPath == false)
    }

    @Test("bundle hook directory resolves only from app ancestor")
    func bundleHookDirectoryResolvesOnlyFromAppAncestor() throws {
        let appFixture = try DoctorFixture()
        defer { appFixture.cleanup() }
        let appBinary = appFixture.root.appendingPathComponent("DanTerm.app/Contents/Helpers/danterm")
        try FileManager.default.createDirectory(at: appBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: appBinary.path, contents: Data("cli".utf8))

        var facts = gatherDoctorFacts(env: appFixture.env(argv0: appBinary.path))
        #expect(facts.runningBinaryResolved == appBinary.path)
        #expect(facts.bundledHookDir == appFixture.root.appendingPathComponent("DanTerm.app/Contents/Resources/danterm-hooks").path)

        let bareFixture = try DoctorFixture()
        defer { bareFixture.cleanup() }
        let bareBinary = try bareFixture.makePathCommand(name: "danterm", mode: 0o755)
        facts = gatherDoctorFacts(env: bareFixture.env(argv0: bareBinary.path))
        #expect(facts.bundledHookDir == nil)
    }
}

private struct DoctorFixture {
    let root: URL
    let home: URL
    let codexHome: URL
    let pathDir: URL
    let sourceURL: URL
    let destinationURL: URL
    let bundleURL: URL
    let configURL: URL

    init(bundlePath: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-doctor-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        pathDir = root.appendingPathComponent("path", isDirectory: true)
        sourceURL = root.appendingPathComponent("DanTerm.app/Contents/Helpers/danterm")
        destinationURL = root.appendingPathComponent("bin/danterm")
        bundleURL = URL(fileURLWithPath: bundlePath ?? root.appendingPathComponent("DanTerm.app").path)
        configURL = root.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sourceURL.path, contents: Data("cli".utf8))
        chmod(sourceURL.path, 0o755)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func env(
        argv0: String? = nil,
        resolveInstalledFontFamily: @escaping (String) -> String? = { _ in nil }
    ) -> DoctorProbeEnv {
        DoctorProbeEnv(
            fileManager: .default,
            environment: [
                "CODEX_HOME": codexHome.path,
                "PATH": pathDir.path,
            ],
            homeDirectory: home,
            argv0: argv0 ?? sourceURL.path,
            installerDeps: installerDeps,
            configFilePath: configURL.path,
            resolveInstalledFontFamily: resolveInstalledFontFamily
        )
    }

    func writeConfig(fontFamily: String?) throws {
        let font = fontFamily.map { #", "font": {"family": "\#($0)"}"# } ?? ""
        try writeFile(configURL, #"{"schemaVersion": 1\#(font)}"#)
    }

    var installerDeps: CLIPathInstaller.Dependencies {
        CLIPathInstaller.Dependencies(
            destinationURL: destinationURL,
            sourceURL: { sourceURL },
            bundleURL: { bundleURL },
            fileManager: .default,
            privilegedRunner: { _ in }
        )
    }

    func createAgentRoots() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    }

    func writeClaudeSettings(commands: [String]) throws {
        try createAgentRoots()
        try writeFile(home.appendingPathComponent(".claude/settings.json"), hooksJSON(commands: commands))
    }

    func writeCodexHooksJSON(commands: [String]) throws {
        try createAgentRoots()
        try writeFile(codexHome.appendingPathComponent("hooks.json"), hooksJSON(commands: commands))
    }

    func writeFile(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: url)
    }

    func makeExecutableHook(name: String) throws -> URL {
        try makeHook(name: name, mode: 0o755)
    }

    func makeHook(name: String, mode: mode_t) throws -> URL {
        let url = root.appendingPathComponent("hooks/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("hook".utf8))
        chmod(url.path, mode)
        return url
    }

    func makePathCommand(name: String, mode: mode_t) throws -> URL {
        let url = pathDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("command".utf8))
        chmod(url.path, mode)
        return url
    }

    func installSkill(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.appendingPathComponent("SKILL.md").path, contents: Data("# danterm\n".utf8))
    }

    private func hooksJSON(commands: [String]) -> String {
        let encodedCommands = commands.map { command in
            #"""
            {
              "type": "command",
              "command": "\#(command)",
              "timeout": 2
            }
            """#
        }.joined(separator: ",")
        return #"""
        {
          "hooks": {
            "SessionStart": [
              {
                "hooks": [
                  \#(encodedCommands)
                ]
              }
            ]
          }
        }
        """#
    }
}
