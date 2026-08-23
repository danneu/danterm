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
                    targetPolicy: second.targetPolicy,
                    route: second.route
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

    @Test("local and explicit-only commands declare their target policy")
    func targetPoliciesAreExplicit() {
        #expect(CLICommandCatalog.entry(for: ["help"])?.targetPolicy == .localOnly)
        #expect(CLICommandCatalog.entry(for: ["skill"])?.targetPolicy == .localOnly)
        #expect(CLICommandCatalog.entry(for: ["doctor"])?.targetPolicy == .localOnly)
        #expect(CLICommandCatalog.entry(for: ["quit"])?.targetPolicy == .explicitRequired)
        #expect(CLICommandCatalog.entry(for: ["ls"])?.targetPolicy == .implicitAllowed)
    }
}
