// The declarative inventory of every public danterm leaf command.
//
// Parsing, help, and generated agent documentation project from this catalog. Command-
// specific argument parsers stay in CLIParser.swift and the focused argument grammar files.

/// The launch and selection flags shared by every command that creates a terminal.
public let cliLaunchAndFocusFlagsSynopsis =
    "[--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"

/// States how a command may select a DanTerm instance.
public enum CLICommandTargetPolicy: Equatable, Sendable {
    /// Allows an explicit target, DANTERM_SOCK, or identity-derived socket lookup.
    case implicitAllowed
    /// Requires --socket or --tcp and never falls back to ambient instance selection.
    case explicitRequired
    /// Runs in this process and rejects --socket and --tcp.
    case localOnly
}

/// Classifies the bytes a successful command writes to stdout.
public enum CLIOutputKind: Equatable, Sendable {
    /// Writes no stdout.
    case none
    /// Writes one compact JSON value followed by a newline.
    case json
    /// Writes raw text without adding framing.
    case text
    /// Writes one JSON record per line as records arrive.
    case recordStream
    /// Writes a human-readable report assembled by a local handler.
    case localReport
}

/// Describes one selectable form of a command's stdout contract.
public struct CLIOutputForm: Equatable, Sendable {
    /// Names the parser-selected form, or nil when the command has only one form.
    public let variant: String?
    /// Controls how the execution boundary emits the command result.
    public let kind: CLIOutputKind
    /// Documents the bytes callers receive.
    public let shape: String

    /// Creates one declared output form.
    public init(variant: String? = nil, kind: CLIOutputKind, shape: String) {
        self.variant = variant
        self.kind = kind
        self.shape = shape
    }
}

/// Owns every stdout form one command can select.
public struct CLIOutputContract: Equatable, Sendable {
    /// The complete set of forms. A silent command has one `.none` form.
    public let forms: [CLIOutputForm]

    /// Creates a contract from one or more exhaustive forms.
    public init(_ forms: [CLIOutputForm]) {
        precondition(forms.isEmpty == false)
        self.forms = forms
    }

    /// Resolves the parser's variant selection against this descriptor.
    public func form(named variant: String?) -> CLIOutputForm? {
        forms.first { $0.variant == variant }
    }
}

/// Names the one parser or local handler that implements a public leaf command.
public enum CLIParserRoute: CaseIterable, Equatable, Hashable, Sendable {
    /// Parses `ls`.
    case ls
    /// Parses `focus`.
    case focus
    /// Parses `group new`.
    case groupNew
    /// Parses `group rename`.
    case groupRename
    /// Parses `group close`.
    case groupClose
    /// Parses `tab new`.
    case tabNew
    /// Parses `tab rename`.
    case tabRename
    /// Parses `tab close`.
    case tabClose
    /// Parses `pane focus`.
    case paneFocus
    /// Parses `pane info`.
    case paneInfo
    /// Parses `pane split`.
    case paneSplit
    /// Parses `pane close`.
    case paneClose
    /// Parses `pane input`.
    case paneInput
    /// Parses `pane read`.
    case paneRead
    /// Parses `pane cells`.
    case paneCells
    /// Parses `pane zoom`.
    case paneZoom
    /// Parses `pane resize`.
    case paneResize
    /// Parses `pane rows`.
    case paneRows
    /// Parses `pane tape`.
    case paneTape
    /// Parses `pane snapshot`.
    case paneSnapshot
    /// Parses `theme set`.
    case themeSet
    /// Parses `agent attach`.
    case agentAttach
    /// Parses `agent activity`.
    case agentActivity
    /// Parses `agent detach`.
    case agentDetach
    /// Parses `tailnet status`.
    case tailnetStatus
    /// Parses `quit`.
    case quit
    /// Runs the local `skill` handler.
    case skill
    /// Runs the local `doctor` handler.
    case doctor
    /// Parses `todo list`.
    case todoList
    /// Parses `todo add`.
    case todoAdd
    /// Parses `todo edit`.
    case todoEdit
    /// Parses `todo done`.
    case todoDone
    /// Parses `todo open`.
    case todoOpen
    /// Parses `todo delete`.
    case todoDelete
    /// Parses `todo clear-completed`.
    case todoClearCompleted
    /// Runs the local help renderer.
    case help

    /// Names the request this route sends, or nil when it never contacts an instance.
    public var wireMethod: IpcRequestMethod? {
        switch self {
        case .ls: .ls
        case .focus: .focusInfo
        case .groupNew: .groupNew
        case .groupRename: .groupRename
        case .groupClose: .groupClose
        case .tabNew: .tabNew
        case .tabRename: .tabRename
        case .tabClose: .tabClose
        case .paneFocus: .paneFocus
        case .paneInfo: .paneInfo
        case .paneSplit: .paneSplit
        case .paneClose: .paneClose
        case .paneInput: .paneInput
        case .paneRead: .paneRead
        case .paneCells: .paneCells
        case .paneZoom: .paneZoom
        case .paneResize: .paneResize
        case .paneRows: .paneRows
        case .paneTape: .paneTape
        case .paneSnapshot: .paneSnapshot
        case .themeSet: .themeSet
        case .agentAttach: .agentAttach
        case .agentActivity: .agentActivity
        case .agentDetach: .agentDetach
        case .tailnetStatus: .tailnetStatus
        case .quit: .quit
        case .doctor: .doctorAppFacts
        case .todoList: .todoList
        case .todoAdd: .todoAdd
        case .todoEdit: .todoEdit
        case .todoDone: .todoDone
        case .todoOpen: .todoOpen
        case .todoDelete: .todoDelete
        case .todoClearCompleted: .todoClearCompleted
        case .skill, .help: nil
        }
    }
}

/// Describes one public leaf command for all user-facing command projections.
public struct CLICommandDescriptor: Equatable, Sendable {
    /// The canonical verb path consumed before command-specific arguments.
    public let path: [String]
    /// Alternate complete verb paths that select the same route.
    public let aliases: [[String]]
    /// The canonical command line after `danterm`, including argument grammar.
    public let synopsis: String
    /// The command-specific prose rendered below its synopsis.
    public let help: String
    /// The parser or local handler selected for this command.
    public let route: CLIParserRoute
    /// The static stdout contract applied by the execution boundary.
    public let output: CLIOutputContract

    /// Creates one catalog entry from the metadata shared by every projection.
    public init(
        path: [String],
        aliases: [[String]] = [],
        synopsis: String,
        help: String,
        route: CLIParserRoute,
        output: CLIOutputContract
    ) {
        self.path = path
        self.aliases = aliases
        self.synopsis = synopsis
        self.help = help
        self.route = route
        self.output = output
    }

    /// Projects instance selection from whether and how the route contacts an instance.
    public var targetPolicy: CLICommandTargetPolicy {
        guard let method = route.wireMethod else { return .localOnly }
        return method.terminatesInstance ? .explicitRequired : .implicitAllowed
    }

    /// Supplies the sole leaf-usage spelling consumed by parser errors.
    public var usage: String { "usage: danterm \(synopsis)" }

    /// Includes aliases in projections that teach callers every accepted spelling.
    public var displaySynopsis: String {
        guard aliases.isEmpty == false else { return synopsis }
        return ([synopsis] + aliases.map { $0.joined(separator: " ") }).joined(separator: ", ")
    }
}

/// Identifies catalog shapes that would make dispatch or projection ambiguous.
public enum CLICommandCatalogError: Error, Equatable {
    /// A command or alias has no tokens.
    case emptySpelling
    /// Two commands claim the same canonical path or alias.
    case duplicateSpelling([String])
    /// Two entries claim the same parser route.
    case duplicateRoute(CLIParserRoute)
    /// No entry claims one of the exhaustive parser routes.
    case missingRoute(CLIParserRoute)
    /// A synopsis does not start with its canonical verb path.
    case synopsisPathMismatch(CLIParserRoute)
}

/// Owns the complete, validated declaration of DanTerm's public command surface.
public enum CLICommandCatalog {
    /// Every public leaf command in help display order.
    public static let entries: [CLICommandDescriptor] = [
        command("ls", "Print the full app snapshot as JSON", route: .ls),
        command("focus", "Print the main window's live focus owner as JSON", route: .focus),
        command(
            "group new --name <name> \(cliLaunchAndFocusFlagsSynopsis)",
            "Create a group and its first tab",
            path: ["group", "new"],
            route: .groupNew
        ),
        command(
            "group rename --group <group-id> <name>",
            "Rename a group",
            path: ["group", "rename"],
            route: .groupRename
        ),
        command(
            "group close --group <group-id> [--move-tabs]",
            "Close a group, with its tabs or after moving them to the adjacent group",
            path: ["group", "close"],
            route: .groupClose
        ),
        command(
            "tab new (--group <group-id> | --after-tab <tab-id>) \(cliLaunchAndFocusFlagsSynopsis) [--after-selected | --at-group-end]",
            "Open a new tab, optionally launching a command",
            path: ["tab", "new"],
            route: .tabNew
        ),
        command(
            "tab rename --tab <tab-id> <name>|--clear",
            "Rename a tab or clear its custom title",
            path: ["tab", "rename"],
            route: .tabRename
        ),
        command(
            "tab close --tab <tab-id>",
            "Close a tab",
            path: ["tab", "close"],
            route: .tabClose
        ),
        command(
            "pane focus --pane <pane-id>",
            "Focus a pane by id",
            path: ["pane", "focus"],
            route: .paneFocus
        ),
        command(
            "pane info --pane <pane-id>",
            "Print pane, tab, and group metadata as JSON",
            path: ["pane", "info"],
            route: .paneInfo
        ),
        command(
            "pane split (--pane <pane-id> -h|-v | --tab <tab-id>) \(cliLaunchAndFocusFlagsSynopsis)",
            "Split a pane horizontally or vertically, or add a pane to a tab",
            path: ["pane", "split"],
            route: .paneSplit
        ),
        command(
            "pane close --pane <pane-id>",
            "Close a pane",
            path: ["pane", "close"],
            route: .paneClose
        ),
        command(
            "pane input --pane <pane-id> [--literal] -- <token>...",
            "Send keystrokes to a pane (tmux-style: \"ls\" Enter, C-c, Up, Escape)",
            path: ["pane", "input"],
            route: .paneInput
        ),
        command(
            "pane read --pane <pane-id> [--lines <n>]",
            "Print a pane's visible text, or the last n lines of scrollback when --lines is set",
            path: ["pane", "read"],
            route: .paneRead
        ),
        command(
            "pane cells --pane <pane-id>",
            "Print the visible viewport as row and column-addressed cell spans",
            path: ["pane", "cells"],
            route: .paneCells
        ),
        command(
            "pane rows --pane <pane-id>",
            "Print each display row's wrap claim, content end, and width as JSON",
            path: ["pane", "rows"],
            route: .paneRows
        ),
        command(
            "pane zoom --pane <pane-id> on|off|toggle",
            "Zoom a pane to fill its tab, or restore the split. Prints the pane's resulting zoom state",
            path: ["pane", "zoom"],
            route: .paneZoom
        ),
        command(
            "pane resize --pane <pane-id> <columns>x<rows>|--fit",
            "Run an exact grid whatever rectangle the pane occupies, or follow the rectangle again. "
                + "Columns \(paneGridOverrideColumnRange.lowerBound)-\(paneGridOverrideColumnRange.upperBound), "
                + "rows \(paneGridOverrideRowRange.lowerBound)-\(paneGridOverrideRowRange.upperBound)",
            path: ["pane", "resize"],
            route: .paneResize
        ),
        command(
            "pane tape --pane <pane-id> [--follow] [--from-now | --from-cursor <cursor-json>] [--raw | --reconstructible] [--sync-history-bytes <n>] [--format replay|inspect]",
            """
            Print or follow the pane's flight recording. Follows and resumes reconstruct exact \
            state; finite beginning dumps default to raw evidence. --sync-history-bytes bounds \
            each sync's scrollback (default \(PaneTapeSyncPolicy.defaultHistoryBudgetBytes), 0 for the grid alone) and needs \
            --reconstructible. Inspect format renders readable spans; replay (the default) keeps exact bytes.
            """,
            path: ["pane", "tape"],
            route: .paneTape
        ),
        command(
            "pane snapshot --pane <pane-id>",
            "Print one exact pane-state sync as JSON Lines",
            path: ["pane", "snapshot"],
            route: .paneSnapshot
        ),
        command(
            "theme set --pane <pane-id> <name>|--clear",
            "Set or clear a pane theme",
            path: ["theme", "set"],
            route: .themeSet
        ),
        command(
            "agent attach --pane <pane-id> --kind <kind> --id <session-id>",
            "Attach the caller's root agent session",
            path: ["agent", "attach"],
            route: .agentAttach
        ),
        command(
            "agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>",
            "Report explicit root-agent activity",
            path: ["agent", "activity"],
            route: .agentActivity
        ),
        command(
            "agent detach --pane <pane-id> --kind <kind> --id <session-id>",
            "Detach the matching root agent session",
            path: ["agent", "detach"],
            route: .agentDetach
        ),
        command(
            "tailnet status",
            "Print this instance's tailnet listener state as JSON: disabled, waiting, or listening, with its endpoint",
            path: ["tailnet", "status"],
            route: .tailnetStatus
        ),
        command(
            "quit",
            "Ask the explicitly targeted instance to quit. TCP peers are refused by the server",
            route: .quit
        ),
        command(
            "skill",
            "Print DanTerm's agent skill instructions",
            route: .skill
        ),
        command(
            "doctor [--json]",
            "Check DanTerm integration health",
            route: .doctor
        ),
        command(
            "todo list (--pane <pane-id> | --tab <tab-id>)",
            "List todos as JSON",
            path: ["todo", "list"],
            route: .todoList
        ),
        command(
            "todo add (--pane <pane-id> | --tab <tab-id>) <text>",
            "Add a todo",
            path: ["todo", "add"],
            route: .todoAdd
        ),
        command(
            "todo edit (--pane <pane-id> | --tab <tab-id>) <todo-id> <text>",
            "Edit a todo's text",
            path: ["todo", "edit"],
            route: .todoEdit
        ),
        command(
            "todo done (--pane <pane-id> | --tab <tab-id>) <todo-id>",
            "Mark a todo done",
            path: ["todo", "done"],
            route: .todoDone
        ),
        command(
            "todo open (--pane <pane-id> | --tab <tab-id>) <todo-id>",
            "Reopen a completed todo",
            path: ["todo", "open"],
            route: .todoOpen
        ),
        command(
            "todo delete (--pane <pane-id> | --tab <tab-id>) <todo-id>",
            "Delete a todo",
            path: ["todo", "delete"],
            route: .todoDelete
        ),
        command(
            "todo clear-completed (--pane <pane-id> | --tab <tab-id>)",
            "Remove all completed todos",
            path: ["todo", "clear-completed"],
            route: .todoClearCompleted
        ),
        command(
            "help",
            "Print this message",
            aliases: [["--help"], ["-h"]],
            route: .help
        ),
    ]

    /// Renders the deterministic command section shared by human-facing help.
    public static var commandHelp: String {
        entries.map { entry in
            let description = entry.help
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    \($0)" }
                .joined(separator: "\n")
            return "  \(entry.displaySynopsis)\n\(description)"
        }.joined(separator: "\n")
    }

    /// Returns the entry whose complete canonical path or alias equals `spelling`.
    public static func entry(for spelling: [String]) -> CLICommandDescriptor? {
        entries.first { $0.path == spelling || $0.aliases.contains(spelling) }
    }

    /// Returns the entry whose canonical path or alias is the longest prefix of arguments.
    public static func entry(prefixing arguments: [String]) -> CLICommandDescriptor? {
        entries
            .filter { entry in
                ([entry.path] + entry.aliases).contains { spelling in
                    arguments.starts(with: spelling)
                }
            }
            .max { lhs, rhs in
                let lhsCount = ([lhs.path] + lhs.aliases)
                    .filter { arguments.starts(with: $0) }
                    .map(\.count)
                    .max() ?? 0
                let rhsCount = ([rhs.path] + rhs.aliases)
                    .filter { arguments.starts(with: $0) }
                    .map(\.count)
                    .max() ?? 0
                return lhsCount < rhsCount
            }
    }

    /// Returns the descriptor for one exhaustive parser route.
    public static func entry(for route: CLIParserRoute) -> CLICommandDescriptor {
        guard let entry = entries.first(where: { $0.route == route }) else {
            preconditionFailure("validated command catalog is missing route \(route)")
        }
        return entry
    }

    /// Derives a branch's accepted child list in catalog display order.
    public static func childUsage(for branch: String) -> String? {
        let children = entries.compactMap { entry -> String? in
            guard entry.path.count > 1, entry.path[0] == branch else { return nil }
            return entry.path[1]
        }
        guard children.isEmpty == false else { return nil }
        return "usage: danterm \(branch) <\(children.joined(separator: "|"))>"
    }

    /// Rejects catalog data that cannot produce exhaustive, unambiguous dispatch.
    public static func validate(_ entries: [CLICommandDescriptor]) throws {
        var spellings = Set<[String]>()
        var routes = Set<CLIParserRoute>()
        for entry in entries {
            for spelling in [entry.path] + entry.aliases {
                guard spelling.isEmpty == false else { throw CLICommandCatalogError.emptySpelling }
                guard spellings.insert(spelling).inserted else {
                    throw CLICommandCatalogError.duplicateSpelling(spelling)
                }
            }
            guard routes.insert(entry.route).inserted else {
                throw CLICommandCatalogError.duplicateRoute(entry.route)
            }
            guard entry.synopsis.hasPrefix(entry.path.joined(separator: " ")) else {
                throw CLICommandCatalogError.synopsisPathMismatch(entry.route)
            }
        }
        for route in CLIParserRoute.allCases where routes.contains(route) == false {
            throw CLICommandCatalogError.missingRoute(route)
        }
    }

    /// Builds a descriptor whose one-token path is the first word of its synopsis.
    private static func command(
        _ synopsis: String,
        _ help: String,
        path: [String]? = nil,
        aliases: [[String]] = [],
        route: CLIParserRoute
    ) -> CLICommandDescriptor {
        CLICommandDescriptor(
            path: path ?? [String(synopsis.prefix { $0 != " " })],
            aliases: aliases,
            synopsis: synopsis,
            help: help,
            route: route,
            output: outputContract(for: route)
        )
    }

    /// Declares stdout once for parsing, execution, and generated documentation.
    private static func outputContract(for route: CLIParserRoute) -> CLIOutputContract {
        func one(_ kind: CLIOutputKind, _ shape: String = "") -> CLIOutputContract {
            CLIOutputContract([CLIOutputForm(kind: kind, shape: shape)])
        }
        switch route {
        case .ls:
            return one(
                .json,
                "JSON: `{groups, selectedTabId}` (each pane is embedded at its `rootNode` leaf under `.pane`, with current `isZoomed`, `processPhase`, `command`, `connection`, `agent`, and `integration` values in the same encoding as `pane info`)"
            )
        case .focus:
            return one(
                .json,
                "JSON: `{focus: {type: \"terminal\"|\"searchField\", paneId: \"...\"}}` or `{focus: {type: \"nonPane\"|\"none\"}}`"
            )
        case .groupNew:
            return one(.json, "Same JSON shape as `tab new`, naming the new group and its first tab")
        case .tabNew:
            return one(.json, "JSON: `{tab: {...}, panes: [{id}], group?: {id, name}}`")
        case .paneInfo:
            return one(
                .json,
                "JSON: `{pane: {id, title, isZoomed, cwd, processPhase, command, connection, agent, integration, gridOverride?}, tab: {id, title, groupId, isZoomed}, group: {id, name}}`"
            )
        case .paneSplit:
            return one(.json, "JSON: `{pane: {id}}`")
        case .paneRead:
            return one(.text, "Raw text from the requested pane, not JSON")
        case .paneCells:
            return one(
                .json,
                "JSON: `{columns, rowCount, paneRowsOrigin, rows: [{index, spans: [{kind, column, cellWidth, text?, utf8Offsets?}]}]}`"
            )
        case .paneRows:
            return one(.json, "JSON: per-display-row line structure")
        case .paneZoom:
            return one(
                .json,
                "Same JSON shape as `pane info`, with the resulting `pane.isZoomed` and current session-reported fields"
            )
        case .paneResize:
            return one(
                .json,
                "Same JSON shape as `pane info`, with the resulting `pane.gridOverride` (absent when the pane follows its rectangle)"
            )
        case .paneTape:
            return CLIOutputContract([
                CLIOutputForm(
                    variant: PaneTapeFormat.replay.rawValue,
                    kind: .recordStream,
                    shape: "JSON Lines: finite dumps contain `start`, retained events or loss, then `dump-complete`; followed or resumed streams stay open for live events. Carries exact replayable `base64` payloads"
                ),
                CLIOutputForm(
                    variant: PaneTapeFormat.inspect.rawValue,
                    kind: .recordStream,
                    shape: "JSON Lines: finite dumps contain `start`, retained events or loss, then `dump-complete`; followed or resumed streams stay open for live events. Carries readable `spans` and is neither replayable nor fixture evidence"
                ),
            ])
        case .paneSnapshot:
            return one(
                .recordStream,
                "JSON Lines: `start`, one or more atomic `sync` parts, then `snapshot-complete`"
            )
        case .tailnetStatus:
            return one(
                .json,
                "JSON: `{state: \"disabled\", reason}`, `{state: \"waiting\", base, offset, endpoint, reason}`, or `{state: \"listening\", base, offset, endpoint}`"
            )
        case .skill:
            return one(.text, "Raw Markdown bytes from the version-matched bundled `SKILL.md`")
        case .doctor:
            return CLIOutputContract([
                CLIOutputForm(
                    kind: .localReport,
                    shape: "Text health rows plus a status-count footer; the first row names the resolved instance target and whether it answered"
                ),
                CLIOutputForm(
                    variant: "json",
                    kind: .json,
                    shape: "JSON: `{instance: {target, answered}, checks: [{id, status, title, message?}]}`"
                ),
            ])
        case .todoList:
            return one(.json, "JSON: `{todos: [{id, text, isDone}, ...]}`")
        case .todoAdd:
            return one(.json, "JSON: `{todo: {id, text, isDone}}`")
        case .help:
            return one(.localReport, "Human-readable usage page")
        case .groupRename, .groupClose, .tabRename, .tabClose, .paneFocus, .paneClose,
             .paneInput, .themeSet, .agentAttach, .agentActivity, .agentDetach, .quit,
             .todoEdit, .todoDone, .todoOpen, .todoDelete, .todoClearCompleted:
            return one(.none)
        }
    }
}
