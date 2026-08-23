// Black-box coverage of the `danterm` usage and help text: the no-argument case, the
// three explicit help forms, and the tokens every one of them prints.
//
// None of this touches the control socket -- help is local argument handling -- so it
// belongs in the gate rather than in `scripts/tests/danterm-cli_test.sh`, which claims a
// development slot before its first assertion and therefore only runs when someone asks
// for it. Help text checked only by an opt-in script goes stale silently: this file
// exists because the script's copy of the invocation line sat wrong for the whole life
// of the `--tcp` flag without any run noticing.
//
// Assert stable tokens, not the whole page. A test that pinned every line would fail on
// every reworded description and teach the reader to update it without reading it.
import Foundation
import Testing

/// The one invocation line, spelled as the CLI prints it.
private let invocationLine = "danterm [--socket <path> | --tcp <host:port>] <command> [args]"

/// Usage lines whose exact spelling is the contract a caller reads before typing a
/// command. Every one of them names its target with the flag that carries it.
private let requiredUsageLines = [
    invocationLine,
    "pane focus --pane <pane-id>",
    "pane info --pane <pane-id>",
    "pane split (--pane <pane-id> -h|-v | --tab <tab-id>)",
    "pane close --pane <pane-id>",
    "group new --name <name>",
    "group rename --group <group-id> <name>",
    "group close --group <group-id> [--move-tabs]",
    "tab new (--group <group-id> | --after-tab <tab-id>)",
    "tab close --tab <tab-id>",
    "agent attach --pane <pane-id> --kind <kind> --id <session-id>",
    "agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>",
    "agent detach --pane <pane-id> --kind <kind> --id <session-id>",
    "todo clear-completed (--pane <pane-id> | --tab <tab-id>)",
    "todo edit (--pane <pane-id> | --tab <tab-id>) <todo-id> <text>",
    "Columns 2-1024, rows 1-1024",
    "default 262144",
    "needs --reconstructible",
    "TCP peers are refused by the server",
    "Print the main window's live focus owner as JSON",
    "Check DanTerm integration health",
    "Print DanTerm's agent skill instructions",
    "tab new opens in the background at the target group end",
    "DANTERM_SOCK",
    "DANTERM_PANE",
]

/// Command rows matched by shape, so the row is proven to be a command entry rather than
/// the word appearing somewhere in a description.
private let requiredCommandRows = [
    "^  focus$",
    "^  doctor$",
    "^  skill$",
    "^  help, --help, -h$",
]

/// Spellings a superseded surface would reintroduce: the positional `pane focus` form
/// that `--pane` replaced, `doctor`'s dropped flags, and the pane id's retired
/// tab-scoped sibling.
private let forbiddenSpellings = [
    "pane focus <pane-id>",
    "doctor [--all|-v]",
    "DANTERM_TAB",
]

@Suite(.timeLimit(.minutes(1)))
struct UsageTextTests {
    // Intent: a bare `danterm` explains itself on stderr and fails.
    // Why it exists: the usage block is the whole error message here, so a regression
    //   that prepends a `danterm: missing command` line ahead of it would turn a
    //   readable page into an error the caller has to look past.
    // Scenario: someone types `danterm` with no command.
    @Test("running with no arguments prints usage to stderr and fails")
    func noArgumentsPrintsUsage() throws {
        let run = try runCLI([], environment: [:])

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(!run.stderr.isEmpty)
        #expect(!matchesLine(run.stderr, "^danterm:"))
        expectUsagePage(run.stderr)
    }

    @Test("every help form prints the usage page to stdout and exits 0",
          arguments: ["help", "--help", "-h"])
    func helpFormsPrintUsage(argument: String) throws {
        let run = try runCLI([argument], environment: [:])

        #expect(run.status == 0)
        #expect(run.stderr == "")
        expectUsagePage(run.stdout)
    }

    @Test("help rejects trailing arguments without touching IPC",
          arguments: ["help", "--help", "-h"])
    func helpRejectsTrailingArguments(argument: String) throws {
        let run = try runCLI([argument, "extra"], socketPath: "/definitely/absent/danterm.sock")

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: usage: danterm help\n")
    }

    @Test("local commands reject explicit connection targets",
          arguments: ["help", "skill", "doctor"])
    func localCommandsRejectExplicitTargets(command: String) throws {
        for target in [
            ["--socket", "/definitely/absent/danterm.sock"],
            ["--tcp", "127.0.0.1:65535"],
        ] {
            let run = try runCLI(target + [command], environment: [:])

            #expect(run.status == 1)
            #expect(run.stdout == "")
            #expect(run.stderr == "danterm: \(command) does not accept --socket or --tcp\n")
        }
    }

    @Test("pane split help-shaped direction reaches the split route")
    func paneSplitHorizontalFlagIsNotTopLevelHelp() throws {
        let paneId = "00000000-0000-0000-0000-000000000001"
        let run = try runCLI(
            ["--socket", "/definitely/absent/danterm.sock", "pane", "split", "--pane", paneId, "-h"],
            environment: [:]
        )

        #expect(run.status == 1)
        #expect(run.stdout == "")
        #expect(run.stderr == "danterm: DanTerm is not running\n")
    }
}

/// Holds the one definition of "this text is the usage page", so the bare-invocation and
/// help-flag cases cannot drift apart in what they accept.
private func expectUsagePage(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(text.contains("Usage:"), sourceLocation: sourceLocation)
    for line in requiredUsageLines {
        #expect(text.contains(line), "missing usage line: \(line)", sourceLocation: sourceLocation)
    }
    for row in requiredCommandRows {
        #expect(matchesLine(text, row), "missing command row: \(row)", sourceLocation: sourceLocation)
    }
    for spelling in forbiddenSpellings {
        #expect(!text.contains(spelling), "superseded spelling: \(spelling)", sourceLocation: sourceLocation)
    }
}

/// Reports whether any single line of `text` matches `pattern`, which is anchored with
/// `^` the way the shell script's `grep -E` was.
private func matchesLine(_ text: String, _ pattern: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
        line.range(of: pattern, options: .regularExpression) != nil
    }
}
