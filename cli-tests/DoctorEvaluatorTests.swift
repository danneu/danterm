// Tests for the pure `danterm doctor` evaluator and renderer. They pin the
// integration-health status ladders without touching the filesystem: all agent,
// PATH CLI, manual app-link, translocation, and PATH facts are injected through
// DoctorFacts.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCLI

@Suite struct DoctorEvaluatorTests {
    @Test("agent rows derive from every registry case in registry order")
    func agentRowsDeriveFromRegistryInOrder() {
        let checks = evaluateDoctor(makeFacts())
        let expected = AgentIntegration.allCases.flatMap { integration in
            [
                DoctorCheckID.agent(integration, .hooks),
                DoctorCheckID.agent(integration, .skill),
            ]
        }

        #expect(Array(checks.prefix(expected.count)).map(\.id) == expected)
    }

    @Test("current full doctor report and advisory exit behavior stay exact")
    func currentFullReportAndExitBehaviorStayExact() {
        let checks = evaluateDoctor(makeFacts())

        #expect(renderDoctorReport(checks) == """
        OK Instance: /fixture.sock answered.
        WARN Claude hooks valid: Claude Code found but DanTerm notifications aren't set up -- add hooks (see docs).
        OK Claude skill installed
        WARN Codex hooks valid: Codex found but DanTerm notifications aren't set up -- add hooks (see docs).
        OK Codex skill installed
        OK danterm on PATH resolves to this running CLI
        OK Manual app CLI link healthy
        OK App not translocated
        SKIP jq on PATH: No DanTerm agent hooks configured.
        SKIP Configured font installed: No font.family set in /home/.config/danterm/config.json.
        SKIP Notifications: This permission cannot be checked on this Mac.
        SKIP Full Disk Access: This permission cannot be checked on this Mac.
        SKIP Developer Tools: This permission cannot be checked on this Mac.
        0 errors, 2 warnings, 0 info, 5 ok, 5 skipped

        """)
        #expect(doctorExitCode(for: checks) == 0)
    }

    @Test("Claude hooks status ladder")
    func claudeHooksStatusLadder() throws {
        let valid = check(.agent(.claude, .hooks), in: evaluateDoctor(makeFacts(claude: agent(hooks: [hook()]))))
        #expect(valid.status == .ok)
        #expect(valid.message == nil)

        let danglingCommand = "/old/danterm-hooks/danterm-claude-agent-session"
        let dangling = check(.agent(.claude, .hooks), in: evaluateDoctor(makeFacts(
            claude: agent(hooks: [hook(command: danglingCommand, exists: false)])
        )))
        #expect(dangling.status == .error)
        #expect(dangling.message == "Hook in ~/.claude/settings.json points to missing /old/danterm-hooks/danterm-claude-agent-session; repoint to /bundle/danterm-hooks/danterm-claude-agent-session or remove it.")

        let fallback = check(.agent(.claude, .hooks), in: evaluateDoctor(makeFacts(
            claude: agent(hooks: [hook(command: danglingCommand, exists: false)]),
            bundledHookDir: nil
        )))
        #expect(fallback.status == .error)
        #expect(fallback.message?.contains("/Applications/DanTerm.app/Contents/Resources/danterm-hooks/danterm-claude-agent-session") == true)

        let notExecutable = check(.agent(.claude, .hooks), in: evaluateDoctor(makeFacts(
            claude: agent(hooks: [hook(command: "/hook", executable: false)])
        )))
        #expect(notExecutable.status == .error)
        #expect(notExecutable.message == "Hook /hook exists but isn't executable, so the agent can't run it; restore it with chmod +x /hook (or reinstall from the DanTerm bundle).")

        let malformed = check(.agent(.claude, .hooks), in: evaluateDoctor(makeFacts(
            claude: agent(hooksParseError: "bad JSON")
        )))
        #expect(malformed.status == .warn)
        #expect(malformed.message == "~/.claude/settings.json is malformed (bad JSON); DanTerm can't read its hooks.")

        let unwired = check(.agent(.claude, .hooks), in: evaluateDoctor(makeFacts(claude: agent())))
        #expect(unwired.status == .warn)
        #expect(unwired.message == "Claude Code found but DanTerm notifications aren't set up -- add hooks (see docs).")

        let absent = check(.agent(.claude, .hooks), in: evaluateDoctor(makeFacts(claude: agent(present: false))))
        #expect(absent.status == .info)
        #expect(absent.message == "Claude Code not installed.")
    }

    @Test("Codex hooks status ladder")
    func codexHooksStatusLadder() {
        let valid = check(.agent(.codex, .hooks), in: evaluateDoctor(makeFacts(codex: agent(hooks: [
            hook(command: "/bundle/danterm-hooks/danterm-codex-agent-session")
        ]))))
        #expect(valid.status == .ok)

        let dangling = check(.agent(.codex, .hooks), in: evaluateDoctor(makeFacts(codex: agent(hooks: [
            hook(command: "/old/danterm-hooks/danterm-codex-agent-session", exists: false)
        ]))))
        #expect(dangling.status == .error)
        #expect(dangling.message == "Hook in $CODEX_HOME/hooks.json or config.toml points to missing /old/danterm-hooks/danterm-codex-agent-session; repoint to /bundle/danterm-hooks/danterm-codex-agent-session or remove it.")

        let notExecutable = check(.agent(.codex, .hooks), in: evaluateDoctor(makeFacts(codex: agent(hooks: [
            hook(command: "/hook", executable: false)
        ]))))
        #expect(notExecutable.status == .error)

        let malformed = check(.agent(.codex, .hooks), in: evaluateDoctor(makeFacts(codex: agent(hooksParseError: "invalid"))))
        #expect(malformed.status == .warn)
        #expect(malformed.message == "$CODEX_HOME/hooks.json is malformed (invalid); DanTerm can't read its hooks.")

        let unwired = check(.agent(.codex, .hooks), in: evaluateDoctor(makeFacts(codex: agent())))
        #expect(unwired.status == .warn)
        #expect(unwired.message == "Codex found but DanTerm notifications aren't set up -- add hooks (see docs).")

        let absent = check(.agent(.codex, .hooks), in: evaluateDoctor(makeFacts(codex: agent(present: false))))
        #expect(absent.status == .info)
        #expect(absent.message == "Codex not installed.")
    }

    @Test("agent skill status ladder")
    func agentSkillStatusLadder() {
        let claudeOK = check(.agent(.claude, .skill), in: evaluateDoctor(makeFacts(claude: agent(present: true, skillInstalled: true))))
        #expect(claudeOK.status == .ok)

        let claudeMissing = check(.agent(.claude, .skill), in: evaluateDoctor(makeFacts(claude: agent(present: true, skillInstalled: false))))
        #expect(claudeMissing.status == .warn)
        #expect(claudeMissing.message == "Skill discovery is not installed at /home/.claude/skills/danterm. Run `danterm skill` for on-demand instructions, or symlink the Nix danterm-agent-skill output or the repo's integrations/danterm there (see README \"Agent Skill\").")

        let claudeAbsent = check(.agent(.claude, .skill), in: evaluateDoctor(makeFacts(claude: agent(present: false))))
        #expect(claudeAbsent.status == .skip)
        #expect(claudeAbsent.message == "Claude Code not installed.")

        let codexMissing = check(.agent(.codex, .skill), in: evaluateDoctor(makeFacts(codex: agent(
            present: true,
            skillInstalled: false,
            skillSearchPaths: ["/custom/codex/skills/danterm", "/home/.agents/skills/danterm"]
        ))))
        #expect(codexMissing.status == .warn)
        #expect(codexMissing.message?.contains("/custom/codex/skills/danterm") == true)

        let codexAbsent = check(.agent(.codex, .skill), in: evaluateDoctor(makeFacts(codex: agent(present: false))))
        #expect(codexAbsent.status == .skip)
        #expect(codexAbsent.message == "Codex not installed.")
    }

    @Test("translocation is standalone and does not suppress other checks")
    func translocationIsStandaloneAndDoesNotSuppressOtherChecks() {
        let checks = evaluateDoctor(makeFacts(
            claude: agent(hooks: [hook(command: "/missing/danterm-claude-agent-session", exists: false)]),
            appInstallerLinkRelevant: true,
            symlinkEntry: .missing,
            translocated: true
        ))

        let translocation = check(.translocation, in: checks)
        #expect(translocation.status == .warn)
        #expect(translocation.message == "DanTerm is running from a quarantined/translocated copy, so the CLI link and hook paths are ephemeral. Move DanTerm.app to /Applications in Finder (or: xattr -dr com.apple.quarantine /Applications/DanTerm.app), relaunch.")
        #expect(check(.agent(.claude, .hooks), in: checks).status == .error)
        #expect(check(.manualAppLink, in: checks).status == .warn)
    }

    @Test("jq gate follows whether DanTerm hooks are wired")
    func jqGateFollowsWhetherHooksAreWired() {
        let noHooks = check(.jq, in: evaluateDoctor(makeFacts(jqOnPath: false)))
        #expect(noHooks.status == .skip)
        #expect(noHooks.message == "No DanTerm agent hooks configured.")

        let missing = check(.jq, in: evaluateDoctor(makeFacts(
            claude: agent(hooks: [hook()]),
            jqOnPath: false
        )))
        #expect(missing.status == .warn)
        #expect(missing.message == "jq not found; agent hooks need it. brew install jq -- ensure it lands in /usr/local/bin or /opt/homebrew/bin so GUI-launched agents see it.")

        let present = check(.jq, in: evaluateDoctor(makeFacts(
            codex: agent(hooks: [hook(command: "/bundle/danterm-hooks/danterm-codex-agent-session")]),
            jqOnPath: true
        )))
        #expect(present.status == .ok)
    }

    @Test("configured font family status ladder stays advisory")
    func configuredFontFamilyStatusLadderStaysAdvisory() {
        // Intent: doctor reports whether the config's `font.family` names an
        //   installed family, and never fails the process over it.
        // Why it exists: `CTFontCreateWithName` substitutes a last-resort face for
        //   an unknown name, so a typo'd family silently renders wrong. Doctor is
        //   the app-independent place a user can see that; pins the four ladder
        //   outcomes and the advisory exit code together, since a font fallback is
        //   fully recovered and must not break scripted `danterm doctor` calls.
        let unset = check(.configFont, in: evaluatedReport(makeFacts(), configFont: .unset).checks)
        #expect(unset.status == .skip)
        #expect(unset.message == "No font.family set in /home/.config/danterm/config.json.")

        let unreadable = check(.configFont, in: evaluatedReport(makeFacts(), configFont: .unreadableConfig).checks)
        #expect(unreadable.status == .warn)
        #expect(unreadable.message == "/home/.config/danterm/config.json can't be read as a schemaVersion 1 JSON document, so font.family is ignored; defaults are active.")

        // The reported file is the one probed, so a slot's config never reads as the
        // user's -- doctor is the only place a reader learns which file it was.
        let slotConfig = check(.configFont, in: evaluatedReport(
            makeFacts(),
            configFont: .unset,
            configFilePath: "/slot-3/config/slot-3.json"
        ).checks)
        #expect(slotConfig.message == "No font.family set in /slot-3/config/slot-3.json.")

        let installed = check(.configFont, in: evaluatedReport(makeFacts(), configFont: .installed).checks)
        #expect(installed.status == .ok)
        #expect(installed.message == nil)

        let missing = check(.configFont, in: evaluatedReport(
            makeFacts(),
            configFont: .notInstalled(requested: "Fira Codee")
        ).checks)
        #expect(missing.status == .warn)
        #expect(missing.message == "Font \"Fira Codee\" is not installed -- using the system monospace font. Install it, or pick an installed family in Settings > Font Family.")

        for facts in [DoctorFacts.ConfigFont.unset, .unreadableConfig, .installed, .notInstalled(requested: "Fira Codee")] {
            #expect(doctorExitCode(for: evaluatedReport(makeFacts(), configFont: facts)) == 0)
        }
    }

    @Test("app permission status ladders stay advisory")
    func appPermissionStatusLaddersStayAdvisory() {
        let granted = evaluatedReport(makeFacts(), permissions: DoctorFacts.Permissions(
            notifications: .granted,
            fullDiskAccess: .granted,
            developerTools: .granted
        )).checks
        #expect(check(.notifications, in: granted).status == .ok)
        #expect(check(.fullDiskAccess, in: granted).status == .ok)
        #expect(check(.developerTools, in: granted).status == .ok)

        let denied = evaluatedReport(makeFacts(), permissions: DoctorFacts.Permissions(
            notifications: .denied,
            fullDiskAccess: .denied,
            developerTools: .denied
        )).checks
        #expect(check(.notifications, in: denied).title == "Notifications")
        #expect(check(.fullDiskAccess, in: denied).title == "Full Disk Access")
        #expect(check(.developerTools, in: denied).title == "Developer Tools")
        #expect(check(.notifications, in: denied).message == "Enable DanTerm in System Settings > Notifications.")
        #expect(check(.fullDiskAccess, in: denied).message == "Enable DanTerm in System Settings > Privacy & Security > Full Disk Access, then relaunch DanTerm.")
        #expect(check(.developerTools, in: denied).message == "Enable DanTerm in System Settings > Privacy & Security > Developer Tools, then relaunch DanTerm.")

        let unavailable = evaluatedReport(makeFacts(), permissions: .unavailable).checks
        #expect(check(.notifications, in: unavailable).status == .skip)
        #expect(check(.fullDiskAccess, in: unavailable).status == .skip)
        #expect(check(.developerTools, in: unavailable).status == .skip)
        #expect(check(.notifications, in: unavailable).message == "This permission cannot be checked on this Mac.")

        let unknown = check(.developerTools, in: evaluatedReport(
            makeFacts(),
            permissions: DoctorFacts.Permissions(
                notifications: .granted,
                fullDiskAccess: .granted,
                developerTools: .unknown
            )
        ).checks)
        #expect(unknown.status == .skip)
        #expect(unknown.message == "The permission state could not be checked on this Mac.")

        #expect(doctorExitCode(for: denied) == 0)
    }

    @Test("PATH CLI status ladder")
    func pathCLIStatusLadder() {
        let missing = check(.pathCLI, in: evaluateDoctor(makeFacts(pathDanterm: nil)))
        #expect(missing.status == .warn)
        #expect(missing.message == "No danterm executable found on PATH; add the installed CLI to PATH (Nix profile, Home Manager profile, or DanTerm menu > \"Install danterm Command in PATH\").")

        let mismatch = check(.pathCLI, in: evaluateDoctor(makeFacts(
            runningBinaryResolved: "/Applications/DanTerm.app/Contents/Helpers/danterm",
            pathDanterm: PathCommand(
                path: "/usr/local/bin/danterm",
                resolved: "/Applications/Old DanTerm.app/Contents/Helpers/danterm"
            )
        )))
        #expect(mismatch.status == .warn)
        #expect(mismatch.message == "danterm on PATH resolves to /Applications/Old DanTerm.app/Contents/Helpers/danterm, but this doctor command is running from /Applications/DanTerm.app/Contents/Helpers/danterm; move the intended install earlier in PATH or run that binary's doctor.")

        let healthy = check(.pathCLI, in: evaluateDoctor(makeFacts(
            runningBinaryResolved: "/nix/store/abc-danterm/Applications/DanTerm.app/Contents/Helpers/danterm",
            pathDanterm: PathCommand(
                path: "/etc/profiles/per-user/dan/bin/danterm",
                resolved: "/nix/store/abc-danterm/Applications/DanTerm.app/Contents/Helpers/danterm"
            ),
            appInstallerLinkRelevant: false,
            symlinkEntry: .missing
        )))
        #expect(healthy.status == .ok)
        #expect(check(.manualAppLink, in: evaluateDoctor(makeFacts(
            runningBinaryResolved: "/nix/store/abc-danterm/Applications/DanTerm.app/Contents/Helpers/danterm",
            pathDanterm: PathCommand(
                path: "/etc/profiles/per-user/dan/bin/danterm",
                resolved: "/nix/store/abc-danterm/Applications/DanTerm.app/Contents/Helpers/danterm"
            ),
            appInstallerLinkRelevant: false,
            symlinkEntry: .missing
        ))).status == .ok)
    }

    @Test("manual app link status ladder")
    func manualAppLinkStatusLadder() {
        let irrelevant = check(.manualAppLink, in: evaluateDoctor(makeFacts(
            appInstallerLinkRelevant: false,
            symlinkEntry: .missing
        )))
        #expect(irrelevant.status == .ok)

        let missing = check(.manualAppLink, in: evaluateDoctor(makeFacts(
            appInstallerLinkRelevant: true,
            symlinkEntry: .missing
        )))
        #expect(missing.status == .warn)
        #expect(missing.message == "/usr/local/bin/danterm is missing or stale -> DanTerm menu > \"Install danterm Command in PATH\".")

        let dangling = check(.manualAppLink, in: evaluateDoctor(makeFacts(
            appInstallerLinkRelevant: true,
            symlinkEntry: .symlink(target: "/gone/danterm", targetExists: false)
        )))
        #expect(dangling.status == .warn)
        #expect(dangling.message == "/usr/local/bin/danterm is missing or stale -> DanTerm menu > \"Install danterm Command in PATH\".")

        let stale = check(.manualAppLink, in: evaluateDoctor(makeFacts(
            runningBinaryResolved: "/bundle/Contents/Helpers/danterm",
            appInstallerLinkRelevant: true,
            symlinkEntry: .symlink(target: "/other/danterm", targetExists: true)
        )))
        #expect(stale.status == .warn)
        #expect(stale.message == "/usr/local/bin/danterm points to /other/danterm, but this doctor command is running from /bundle/Contents/Helpers/danterm; reinstall the DanTerm command or run the intended binary's doctor.")

        let nonSymlink = check(.manualAppLink, in: evaluateDoctor(makeFacts(
            appInstallerLinkRelevant: true,
            symlinkEntry: .nonSymlink
        )))
        #expect(nonSymlink.status == .warn)
        #expect(nonSymlink.message == "/usr/local/bin/danterm exists but is a regular file/directory, not a symlink, so \"Install danterm Command in PATH\" can't replace it; remove or rename it first, then reinstall.")

        let healthy = check(.manualAppLink, in: evaluateDoctor(makeFacts(
            runningBinaryResolved: "/bundle/Contents/Helpers/danterm",
            appInstallerLinkRelevant: true,
            symlinkEntry: .symlink(target: "/bundle/Contents/Helpers/danterm", targetExists: true)
        )))
        #expect(healthy.status == .ok)
    }

    @Test("exit code mapping treats only errors as failing")
    func exitCodeMappingTreatsOnlyErrorsAsFailing() {
        #expect(doctorExitCode(for: [
            DoctorCheck(id: .agent(.claude, .hooks), title: "Claude hooks valid", status: .error, message: "bad"),
        ]) == 1)

        #expect(doctorExitCode(for: [
            DoctorCheck(id: .agent(.claude, .hooks), title: "Claude hooks valid", status: .warn, message: "warn"),
            DoctorCheck(id: .agent(.codex, .hooks), title: "Codex hooks valid", status: .info, message: "info"),
            DoctorCheck(id: .jq, title: "jq on PATH", status: .skip, message: "skip"),
        ]) == 0)
    }

    @Test("renderer prints all rows including OK and counts footer statuses")
    func rendererPrintsAllRowsIncludingOKAndCountsFooterStatuses() {
        let checks = [
            DoctorCheck(id: .agent(.claude, .hooks), title: "Claude hooks valid", status: .ok, message: nil),
            DoctorCheck(id: .agent(.codex, .hooks), title: "Codex hooks valid", status: .warn, message: "Codex warn"),
            DoctorCheck(id: .jq, title: "jq on PATH", status: .skip, message: "No hooks"),
            DoctorCheck(id: .manualAppLink, title: "Manual app CLI link healthy", status: .error, message: "Link error"),
            DoctorCheck(id: .translocation, title: "App not translocated", status: .info, message: "Info"),
        ]

        let report = renderDoctorReport(checks)
        #expect(report.contains("OK Claude hooks valid"))
        #expect(report.contains("WARN Codex hooks valid: Codex warn"))
        #expect(report.contains("SKIP jq on PATH: No hooks"))
        #expect(report.contains("ERROR Manual app CLI link healthy: Link error"))
        #expect(report.contains("INFO App not translocated: Info"))
        #expect(report.hasSuffix("1 error, 1 warning, 1 info, 1 ok, 1 skipped\n"))
    }

    @Test("an unanswered target skips every instance-owned row and stays successful")
    func unansweredTargetSkipsInstanceOwnedRows() {
        let report = evaluateDoctorReport(
            makeFacts(),
            instance: DoctorInstance(target: "/missing.sock", appFacts: nil)
        )

        #expect(report.instance.answered == false)
        #expect(check(.configFont, in: report.checks).status == .skip)
        #expect(check(.notifications, in: report.checks).status == .skip)
        #expect(check(.fullDiskAccess, in: report.checks).status == .skip)
        #expect(check(.developerTools, in: report.checks).status == .skip)
        #expect(check(.notifications, in: report.checks).message == "The instance did not answer, so this check is unavailable.")
        #expect(renderDoctorReport(report).hasPrefix("SKIP Instance: /missing.sock did not answer.\n"))
        #expect(doctorExitCode(for: report) == 0)
    }

    @Test("JSON and text render the same stable check identities")
    func jsonAndTextShareStableChecks() {
        let report = evaluatedReport(makeFacts())
        let ids = report.checks.map(\.id.rawValue)

        #expect(ids == DoctorCheckID.allCases.map(\.rawValue))
        #expect(Set(ids).count == ids.count)
        #expect(renderDoctorReport(report).split(separator: "\n").count == report.checks.count + 2)
        guard case .object(let root) = renderDoctorJSON(report),
              case .array(let rows)? = root["checks"]
        else {
            Issue.record("expected doctor JSON object with checks")
            return
        }
        #expect(rows.compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"]
            else { return nil }
            return id
        } == ids)
    }

    @Test("target descriptions round-trip through matching target flags")
    func targetDescriptionsAreReusable() {
        #expect(doctorTargetDescription(.unixSocket(path: "/slot.sock")) == "/slot.sock")
        #expect(doctorTargetDescription(.tcp(host: "host", port: 24863)) == "host:24863")
        #expect(doctorTargetDescription(.tcp(host: "fd7a:115c:a1e0::1", port: 24863)) == "[fd7a:115c:a1e0::1]:24863")
    }

    @Test("every check id keeps one title across fact states")
    func checkTitlesStayFixedAcrossFactStates() {
        let baseline = Dictionary(uniqueKeysWithValues: evaluatedReport(makeFacts()).checks.map {
            ($0.id.rawValue, $0.title)
        })
        let localVariants = [
            makeFacts(
                claude: agent(present: false),
                codex: agent(hooksParseError: "bad")
            ),
            makeFacts(
                claude: agent(hooks: [hook(exists: false)]),
                codex: agent(hooks: [hook(executable: false)]),
                pathDanterm: nil,
                appInstallerLinkRelevant: true,
                symlinkEntry: .missing,
                translocated: true,
                jqOnPath: false
            ),
        ]
        let reports = localVariants.map { evaluatedReport($0) } + [
            evaluatedReport(
                makeFacts(),
                configFont: .unreadableConfig,
                permissions: DoctorFacts.Permissions(
                    notifications: .denied,
                    fullDiskAccess: .unknown,
                    developerTools: .granted
                )
            ),
            evaluatedReport(makeFacts(), configFont: .installed),
            evaluatedReport(makeFacts(), configFont: .notInstalled(requested: "Missing")),
            evaluateDoctorReport(
                makeFacts(),
                instance: DoctorInstance(target: "/missing.sock", appFacts: nil)
            ),
        ]

        for report in reports {
            #expect(Dictionary(uniqueKeysWithValues: report.checks.map {
                ($0.id.rawValue, $0.title)
            }) == baseline)
        }
    }
}

private func evaluatedReport(
    _ facts: DoctorFacts,
    configFont: DoctorFacts.ConfigFont = .unset,
    configFilePath: String = "/home/.config/danterm/config.json",
    permissions: DoctorFacts.Permissions = .unavailable
) -> DoctorReport {
    let appFacts = DoctorFacts.AppFacts(
        permissions: permissions,
        configFilePath: configFilePath,
        configFont: configFont
    )
    return evaluateDoctorReport(
        facts,
        instance: DoctorInstance(target: "/fixture.sock", appFacts: appFacts)
    )
}

private func evaluateDoctor(_ facts: DoctorFacts) -> [DoctorCheck] {
    evaluatedReport(facts).checks
}

private func renderDoctorReport(_ checks: [DoctorCheck]) -> String {
    renderDoctorReport(DoctorReport(
        instance: DoctorInstance(
            target: "/fixture.sock",
            appFacts: DoctorFacts.AppFacts(
                permissions: .unavailable,
                configFilePath: "",
                configFont: .unset
            )
        ),
        checks: checks
    ))
}

private func doctorExitCode(for checks: [DoctorCheck]) -> Int32 {
    doctorExitCode(for: DoctorReport(
        instance: DoctorInstance(target: "/fixture.sock", appFacts: nil),
        checks: checks
    ))
}

private func check(_ id: DoctorCheckID, in checks: [DoctorCheck]) -> DoctorCheck {
    checks.first { $0.id == id } ?? DoctorCheck(id: id, title: "missing", status: .error, message: "missing")
}

private func makeFacts(
    claude: DoctorFacts.Agent = agent(skillInstalled: true),
    codex: DoctorFacts.Agent = agent(skillInstalled: true),
    runningBinaryResolved: String? = "/bundle/Contents/Helpers/danterm",
    pathDanterm: PathCommand? = PathCommand(path: "/bundle/Contents/Helpers/danterm", resolved: "/bundle/Contents/Helpers/danterm"),
    appInstallerLinkRelevant: Bool = false,
    bundledHookDir: String? = "/bundle/danterm-hooks",
    symlinkEntry: SymlinkEntry = .symlink(target: "/bundle/Contents/Helpers/danterm", targetExists: true),
    translocated: Bool = false,
    jqOnPath: Bool = true
) -> DoctorFacts {
    DoctorFacts(
        agents: DoctorFacts.Agents { integration in
            switch integration {
            case .claude: return claude
            case .codex: return codex
            }
        },
        runningBinaryResolved: runningBinaryResolved,
        pathDanterm: pathDanterm,
        appInstallerLinkRelevant: appInstallerLinkRelevant,
        bundledHookDir: bundledHookDir,
        symlinkEntry: symlinkEntry,
        translocated: translocated,
        jqOnPath: jqOnPath
    )
}

private func agent(
    present: Bool = true,
    hooksParseError: String? = nil,
    hooks: [DoctorFacts.HookRef] = [],
    skillInstalled: Bool = false,
    skillSearchPaths: [String] = ["/home/.claude/skills/danterm", "/home/.agents/skills/danterm"]
) -> DoctorFacts.Agent {
    DoctorFacts.Agent(
        present: present,
        hooksParseError: hooksParseError,
        dantermHooks: hooks,
        skillInstalled: skillInstalled,
        skillSearchPaths: skillSearchPaths
    )
}

private func hook(
    command: String = "/bundle/danterm-hooks/danterm-claude-agent-session",
    exists: Bool = true,
    executable: Bool = true
) -> DoctorFacts.HookRef {
    DoctorFacts.HookRef(command: command, exists: exists, executable: executable)
}
