// Behavioral coverage for the public CLI command catalog and its validation rules.
import Testing
@testable import DanTermProtocol

@Suite struct CLICommandCatalogTests {
    @Test("catalog covers every parser route exactly once")
    func coversEveryParserRoute() {
        #expect(Set(CLICommandCatalog.entries.map(\.route)) == Set(CLIParserRoute.allCases))
        #expect(CLICommandCatalog.entries.count == CLIParserRoute.allCases.count)
    }

    @Test("catalog paths and aliases resolve to one command")
    func pathsAndAliasesAreUnambiguous() throws {
        try CLICommandCatalog.validate(CLICommandCatalog.entries)

        for entry in CLICommandCatalog.entries {
            #expect(CLICommandCatalog.entry(for: entry.path) == entry)
            for alias in entry.aliases {
                #expect(CLICommandCatalog.entry(for: alias) == entry)
            }
        }
    }

    @Test("every command spelling selects its declared parser route")
    func spellingsSelectDeclaredRoutes() throws {
        for entry in CLICommandCatalog.entries {
            for spelling in [entry.path] + entry.aliases {
                let args = entry.targetPolicy == .explicitRequired
                    ? ["--socket", "/tmp/explicit.sock"] + spelling
                    : spelling
                let routed = try routeCLIInvocation(args)
                #expect(routed.descriptor.route == entry.route)
                #expect(routed.arguments.isEmpty)
            }
        }
    }

    @Test("catalog validation rejects duplicate paths and aliases")
    func rejectsAmbiguousSpellings() {
        let first = CLICommandCatalog.entries[0]
        let second = CLICommandCatalog.entries[1]

        #expect(throws: CLICommandCatalogError.duplicateSpelling(first.path)) {
            try CLICommandCatalog.validate([first, first])
        }
        #expect(throws: CLICommandCatalogError.duplicateSpelling(first.path)) {
            try CLICommandCatalog.validate([
                first,
                CLICommandDescriptor(
                    path: second.path,
                    aliases: [first.path],
                    synopsis: second.synopsis,
                    help: second.help,
                    route: second.route,
                    output: second.output
                ),
            ])
        }
    }

    @Test("every canonical synopsis starts with its command path")
    func synopsesNameTheirCommands() {
        for entry in CLICommandCatalog.entries {
            #expect(entry.synopsis.hasPrefix(entry.path.joined(separator: " ")))
        }
    }

    @Test("creation commands share the launch and focus grammar fragment")
    func creationCommandsShareGrammar() {
        let creationRoutes: [CLIParserRoute] = [.groupNew, .tabNew, .paneSplit]

        for route in creationRoutes {
            let entry = CLICommandCatalog.entries.first { $0.route == route }
            #expect(entry?.synopsis.contains(cliLaunchAndFocusFlagsSynopsis) == true)
        }
    }

    @Test("target policies project from each route's wire method")
    func targetPoliciesProjectFromWireMethods() {
        #expect(CLICommandCatalog.entry(for: ["help"])?.targetPolicy == .localOnly)
        #expect(CLICommandCatalog.entry(for: ["skill"])?.targetPolicy == .localOnly)
        #expect(CLICommandCatalog.entry(for: ["doctor"])?.targetPolicy == .implicitAllowed)
        #expect(CLICommandCatalog.entry(for: ["quit"])?.targetPolicy == .explicitRequired)
        #expect(CLICommandCatalog.entry(for: ["ls"])?.targetPolicy == .implicitAllowed)
    }

    @Test("doctor accepts an explicit target and JSON projection")
    func doctorAcceptsTargetAndJSON() throws {
        let routed = try routeCLIInvocation(["--socket", "/x.sock", "doctor", "--json"])

        #expect(routed.target == .unixSocket(path: "/x.sock"))
        #expect(routed.descriptor.route == .doctor)
        #expect(try parseRoutedCLICommand(routed).outputVariant == "json")
    }

    @Test("every wire route parses a request with its declared method")
    func wireRoutesParseTheirDeclaredMethods() throws {
        for entry in CLICommandCatalog.entries {
            guard let method = entry.route.wireMethod else { continue }

            let routed = try routeCLIInvocation(targetedIfRequired(minimalArguments(for: entry)))
            let command = try parseRoutedCLICommand(routed, currentDirectory: "/caller")

            #expect(command.request.method == method, "route: \(entry.route)")
            #expect(
                entry.output.form(named: command.outputVariant) != nil,
                "route selected an undeclared output variant: \(entry.route)"
            )
        }
    }

    @Test("every local route declares the output its handler writes")
    func localRoutesDeclareTheirOutput() {
        #expect(CLICommandCatalog.entry(for: .help).output.forms == [
            CLIOutputForm(kind: .localReport, shape: "Human-readable usage page"),
        ])
        #expect(CLICommandCatalog.entry(for: .skill).output.forms.first?.kind == .text)
        #expect(CLICommandCatalog.entry(for: .doctor).output.forms == [
            CLIOutputForm(
                kind: .localReport,
                shape: "Text health rows plus a status-count footer; the first row names the resolved instance target and whether it answered",
                selectedBy: "doctor"
            ),
            CLIOutputForm(
                variant: "json",
                kind: .json,
                shape: "JSON: `{instance: {target, answered}, checks: [{id, status, title, message?}]}`",
                selectedBy: "doctor --json"
            ),
        ])
    }

    @Test("parsing selects only a catalog output variant")
    func parserSelectsOnlyCatalogOutputVariant() throws {
        let replay = try parseCLI(["pane", "tape", "--pane", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
        let inspect = try parseCLI([
            "pane", "tape", "--pane", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "--format", "inspect",
        ])

        #expect(replay.outputVariant == "replay")
        #expect(inspect.outputVariant == "inspect")
        let doctorJSON = try parseCLI(["doctor", "--json"])
        #expect(doctorJSON.outputVariant == "json")
        #expect(CLICommandCatalog.entry(for: .paneTape).output.form(named: replay.outputVariant)?.kind == .recordStream)
        #expect(CLICommandCatalog.entry(for: .paneTape).output.form(named: inspect.outputVariant)?.kind == .recordStream)
        #expect(CLICommandCatalog.entry(for: .help).output.forms.first?.kind == .localReport)
        #expect(CLICommandCatalog.entry(for: .doctor).output.form(named: doctorJSON.outputVariant)?.kind == .json)
    }

    @Test("every target policy predicts parser acceptance")
    func targetPoliciesPredictParserAcceptance() throws {
        for entry in CLICommandCatalog.entries {
            let command = entry.path
            let explicit = ["--socket", "/tmp/explicit.sock"] + command
            switch entry.targetPolicy {
            case .implicitAllowed:
                #expect(throws: Never.self) { try routeCLIInvocation(command) }
                #expect(throws: Never.self) { try routeCLIInvocation(explicit) }
            case .explicitRequired:
                let error = #expect(throws: CLIParseError.self) {
                    try routeCLIInvocation(command)
                }
                #expect(
                    error?.message
                        == "\(entry.path.joined(separator: " ")) requires an explicit --socket <path> or --tcp <host:port>"
                )
                #expect(throws: Never.self) { try routeCLIInvocation(explicit) }
            case .localOnly:
                #expect(throws: Never.self) { try routeCLIInvocation(command) }
                let error = #expect(throws: CLIParseError.self) {
                    try routeCLIInvocation(explicit)
                }
                #expect(
                    error?.message
                        == "\(entry.path.joined(separator: " ")) does not accept --socket or --tcp"
                )
            }
        }
    }

    @Test("every leaf reports usage from its canonical synopsis")
    func leafUsageComesFromCatalog() {
        for entry in CLICommandCatalog.entries {
            #expect(entry.usage == "usage: danterm \(entry.synopsis)")
        }
    }

    @Test("help command rows retain aliases and detailed behavior")
    func helpRowsProjectCatalogContent() {
        let help = CLICommandCatalog.commandHelp

        #expect(help.contains("pane split (--pane <pane-id> -h|-v | --tab <tab-id>)"))
        #expect(help.contains(
            "Columns \(paneGridOverrideColumnRange.lowerBound)-\(paneGridOverrideColumnRange.upperBound), "
                + "rows \(paneGridOverrideRowRange.lowerBound)-\(paneGridOverrideRowRange.upperBound)"
        ))
        #expect(help.contains("default \(PaneTapeSyncPolicy.defaultHistoryBudgetBytes)"))
        #expect(help.contains("needs --reconstructible"))
        #expect(help.contains("TCP peers are refused by the server"))
        #expect(help.contains("help, --help, -h"))
    }
}

private func targetedIfRequired(_ arguments: [String]) -> [String] {
    guard let entry = CLICommandCatalog.entry(prefixing: arguments),
          entry.targetPolicy == .explicitRequired
    else { return arguments }
    return ["--socket", "/tmp/explicit.sock"] + arguments
}

private func minimalArguments(for entry: CLICommandDescriptor) -> [String] {
    let pane = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let tab = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let group = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let todo = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let tail: [String]
    switch entry.route {
    case .ls, .focus, .roster, .debugSurfaces, .tailnetStatus, .quit, .doctor:
        tail = []
    case .groupNew:
        tail = ["--name", "group"]
    case .groupRename:
        tail = ["--group", group, "name"]
    case .groupClose:
        tail = ["--group", group]
    case .tabNew:
        tail = ["--group", group]
    case .tabRename:
        tail = ["--tab", tab, "name"]
    case .tabClose:
        tail = ["--tab", tab]
    case .paneFocus, .paneInfo, .paneClose, .paneCells, .paneRows, .paneSnapshot:
        tail = ["--pane", pane]
    case .paneSplit:
        tail = ["--pane", pane, "-h"]
    case .paneInput:
        tail = ["--pane", pane, "--", "Enter"]
    case .paneRead:
        tail = ["--pane", pane]
    case .paneZoom:
        tail = ["--pane", pane, "on"]
    case .paneResize:
        tail = ["--pane", pane, "80x24"]
    case .paneTape:
        tail = ["--pane", pane]
    case .themeSet:
        tail = ["--pane", pane, "--clear"]
    case .agentAttach, .agentDetach:
        tail = ["--pane", pane, "--kind", "codex", "--id", "session"]
    case .agentActivity:
        tail = [
            "--pane", pane, "--kind", "codex", "--id", "session", "--state", "working",
        ]
    case .todoList, .todoClearCompleted:
        tail = ["--pane", pane]
    case .todoAdd:
        tail = ["--pane", pane, "text"]
    case .todoEdit:
        tail = ["--pane", pane, todo, "text"]
    case .todoDone, .todoOpen, .todoDelete:
        tail = ["--pane", pane, todo]
    case .help, .skill:
        preconditionFailure("local routes have no wire method")
    }
    return entry.path + tail
}
