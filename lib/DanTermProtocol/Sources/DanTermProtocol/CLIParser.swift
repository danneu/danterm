// Public parser for the `danterm` command-line command surface.
import Foundation

public enum CLIOutputMode: Equatable {
    case none
    case json
    case text
}

public struct CLICommand: Equatable {
    /// Holds the only request representation the CLI is allowed to send.
    public let request: IpcRequest
    public let outputMode: CLIOutputMode

    /// Couples CLI rendering policy to a request that already satisfies the wire contract.
    public init(request: IpcRequest, outputMode: CLIOutputMode) {
        self.request = request
        self.outputMode = outputMode
    }

    /// Exposes the catalog's wire method to the transport layer.
    public var method: String { request.method.rawValue }

    /// Exposes the catalog's encoded params to the transport layer.
    public var params: [String: JSONValue] { request.params }
}

/// Keeps process-local targeting separate from the JSON-RPC command so an
/// explicit instance choice can never leak into method parameters.
public struct CLIInvocation: Equatable {
    public let socketPath: String?
    public let command: CLICommand

    public init(socketPath: String?, command: CLICommand) {
        self.socketPath = socketPath
        self.command = command
    }
}

public struct CLIParseError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Parses global process options before delegating the remaining arguments to
/// the command parser shared by the executable and protocol tests.
public func parseCLIInvocation(
    _ args: [String],
    currentDirectory: String = FileManager.default.currentDirectoryPath
) throws -> CLIInvocation {
    var remaining = args
    var socketPath: String?

    while remaining.first == "--socket" {
        guard remaining.count >= 2 else {
            throw CLIParseError("usage: danterm --socket <path> <command> [args]")
        }
        guard socketPath == nil else {
            throw CLIParseError("--socket may be specified only once")
        }
        let candidate = remaining[1]
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIParseError("--socket requires a non-empty path")
        }
        socketPath = candidate
        remaining.removeFirst(2)
    }

    return CLIInvocation(
        socketPath: socketPath,
        command: try parseCLI(remaining, currentDirectory: currentDirectory)
    )
}

public func parseCLI(
    _ args: [String],
    currentDirectory: String = FileManager.default.currentDirectoryPath
) throws -> CLICommand {
    guard let head = args.first else { throw CLIParseError("missing command") }
    switch head {
    case "ls":
        guard args.count == 1 else {
            throw CLIParseError("usage: danterm ls")
        }
        return CLICommand(request: .ls, outputMode: .json)

    case "focus":
        guard args.count == 1 else {
            throw CLIParseError("usage: danterm focus")
        }
        return CLICommand(request: .focusInfo, outputMode: .json)

    // No flags by design: the instance is named by `--socket`, and one verb has
    // one meaning. There is no --force and no --timeout to add later.
    case "quit":
        guard args.count == 1 else {
            throw CLIParseError("usage: danterm quit")
        }
        return CLICommand(request: .quit, outputMode: .none)

    case "group":
        guard args.count >= 2 else { throw CLIParseError("usage: danterm group <new|rename|close>") }
        switch args[1] {
        case "new":
            return try parseGroupNewCommand(
                Array(args.dropFirst(2)),
                currentDirectory: currentDirectory
            )
        case "rename":
            return try parseGroupRenameCommand(Array(args.dropFirst(2)))
        case "close":
            return try parseGroupCloseCommand(Array(args.dropFirst(2)))
        default:
            throw CLIParseError("unknown group command")
        }

    case "tab":
        guard args.count >= 2 else { throw CLIParseError("usage: danterm tab <new|rename|close>") }
        switch args[1] {
        case "new":
            return try parseTabNewCommand(
                Array(args.dropFirst(2)),
                currentDirectory: currentDirectory
            )
        case "rename":
            return try parseTabRenameCommand(Array(args.dropFirst(2)))
        case "close":
            return try parseTabCloseCommand(Array(args.dropFirst(2)))
        default:
            throw CLIParseError("unknown tab command")
        }

    case "pane":
        guard args.count >= 2 else {
            throw CLIParseError("usage: danterm pane <focus|info|split|close|input|read|rows|zoom|tape>")
        }
        switch args[1] {
        case "focus":
            guard args.count == 3 else { throw CLIParseError("usage: danterm pane focus <pane-id>") }
            return CLICommand(request: .paneFocus(pane: try paneId(args[2])), outputMode: .none)
        case "info":
            return try parsePaneInfoCommand(Array(args.dropFirst(2)))
        case "split":
            return try parsePaneSplitCommand(Array(args.dropFirst(2)))
        case "close":
            return try parsePaneCloseCommand(Array(args.dropFirst(2)))
        case "input":
            return try parsePaneInputCommand(Array(args.dropFirst(2)))
        case "read":
            return try parsePaneReadCommand(Array(args.dropFirst(2)))
        case "rows":
            return try parsePaneRowsCommand(Array(args.dropFirst(2)))
        case "zoom":
            return try parsePaneZoomCommand(Array(args.dropFirst(2)))
        case "tape":
            return try parsePaneTapeCommand(Array(args.dropFirst(2)))
        default:
            throw CLIParseError("unknown pane command")
        }

    case "theme":
        guard args.count >= 2, args[1] == "set" else {
            throw CLIParseError("usage: danterm theme set --pane <pane-id> <name>|--clear")
        }
        return try parseThemeSetCommand(Array(args.dropFirst(2)))

    case "agent":
        guard args.count >= 2 else {
            throw CLIParseError("usage: danterm agent <attach|activity|detach>")
        }
        switch args[1] {
        case "attach":
            return try parseAgentSessionCommand(
                Array(args.dropFirst(2)),
                action: "attach",
                attach: true
            )
        case "activity":
            return try parseAgentActivityCommand(Array(args.dropFirst(2)))
        case "detach":
            return try parseAgentSessionCommand(
                Array(args.dropFirst(2)),
                action: "detach",
                attach: false
            )
        default:
            throw CLIParseError("usage: danterm agent <attach|activity|detach>")
        }

    case "todo":
        return try parseTodo(Array(args.dropFirst()))

    default:
        throw CLIParseError("unknown command: \(head)")
    }
}

private func parseTabNewCommand(_ args: [String], currentDirectory: String) throws -> CLICommand {
    let usage = "usage: danterm tab new (--group <group-id> | --after-tab <tab-id>) [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground] [--after-selected | --at-group-end]"
    let parsed: ParsedTabNew
    do {
        parsed = try parseTabNewArgs(args)
    } catch let error as TabNewParseError {
        switch error {
        case .missingValue(_):
            throw CLIParseError(usage)
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
        case .conflictingPositionFlags:
            throw CLIParseError("--after-selected, --at-group-end, and --after-tab are mutually exclusive\n\(usage)")
        case .conflictingFocusFlags:
            throw CLIParseError("--background and --foreground are mutually exclusive\n\(usage)")
        }
    }

    let afterTab: String?
    if case .afterTab(let id) = parsed.position { afterTab = id } else { afterTab = nil }
    guard (parsed.group == nil) != (afterTab == nil) else {
        throw CLIParseError(usage)
    }

    let launch = LaunchSpec(
        cmd: parsed.launch?.cmd,
        cwd: parsed.launch?.cwd ?? currentDirectory,
        title: parsed.launch?.title
    )
    let target: IpcTabTarget
    switch parsed.position {
    case .none:
        guard let group = parsed.group else { throw CLIParseError(usage) }
        target = .group(try groupId(group), position: .atGroupEnd)
    case .afterSelected:
        guard let group = parsed.group else { throw CLIParseError(usage) }
        target = .group(try groupId(group), position: .afterSelected)
    case .atGroupEnd:
        guard let group = parsed.group else { throw CLIParseError(usage) }
        target = .group(try groupId(group), position: .atGroupEnd)
    case .afterTab(let id):
        target = .afterTab(try tabId(id))
    }
    return CLICommand(
        request: .tabNew(target: target, launch: launch, background: parsed.foreground == false),
        outputMode: .json
    )
}

// Background by default like `tab new`, because an agent creating a group must not
// move the user's selection. `Msg.createGroup` selects the new tab on its own, so
// the CLI has to ask for the background explicitly.
private func parseGroupNewCommand(_ args: [String], currentDirectory: String) throws -> CLICommand {
    let usage = "usage: danterm group new --name <name> [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
    let parsed: ParsedGroupNew
    do {
        parsed = try parseGroupNewArgs(args)
    } catch let error as GroupNewParseError {
        switch error {
        case .missingValue:
            throw CLIParseError(usage)
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
        case .conflictingFocusFlags:
            throw CLIParseError("--background and --foreground are mutually exclusive\n\(usage)")
        }
    }

    guard let name = parsed.name, name.isEmpty == false else { throw CLIParseError(usage) }
    let launch = LaunchSpec(
        cmd: parsed.launch?.cmd,
        cwd: parsed.launch?.cwd ?? currentDirectory,
        title: parsed.launch?.title
    )
    return CLICommand(
        request: .groupNew(name: name, launch: launch, background: parsed.foreground == false),
        outputMode: .json
    )
}

// Sibling of `parseTabRenameCommand` minus `--clear`: a group always has a name,
// so there is nothing to clear it to.
private func parseGroupRenameCommand(_ args: [String]) throws -> CLICommand {
    var remaining = args
    let usage = "usage: danterm group rename --group <group-id> <name>"
    guard remaining.count >= 2, remaining.first == "--group" else { throw CLIParseError(usage) }
    let group = try groupId(remaining[1])
    remaining.removeFirst(2)
    guard remaining.isEmpty == false else { throw CLIParseError(usage) }
    if remaining[0].hasPrefix("--") {
        throw CLIParseError("unknown flag: \(remaining[0])")
    }
    let name = remaining.joined(separator: " ")
    guard name.isEmpty == false else { throw CLIParseError(usage) }
    return CLICommand(request: .groupRename(group: group, name: name), outputMode: .none)
}

/// Keeps destructive group closure explicit at parse time, like `pane close`.
private func parseGroupCloseCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm group close --group <group-id> [--move-tabs]"
    guard args.count >= 2, args[0] == "--group" else {
        if let argument = args.first, argument.hasPrefix("--"), argument != "--group" {
            throw CLIParseError("unknown flag: \(argument)")
        }
        throw CLIParseError(usage)
    }
    let group = try groupId(args[1])
    var moveTabs = false
    for argument in args.dropFirst(2) {
        guard argument == "--move-tabs" else {
            if argument.hasPrefix("--") {
                throw CLIParseError("unknown flag: \(argument)")
            }
            throw CLIParseError("unexpected argument: \(argument)")
        }
        moveTabs = true
    }
    return CLICommand(
        request: .groupClose(group: group, moveTabs: moveTabs),
        outputMode: .none
    )
}

private func parseTabRenameCommand(_ args: [String]) throws -> CLICommand {
    var remaining = args
    let usage = "usage: danterm tab rename --tab <tab-id> <name>|--clear"
    guard remaining.count >= 2, remaining.first == "--tab" else { throw CLIParseError(usage) }
    let tab = try tabId(remaining[1])
    remaining.removeFirst(2)
    guard !remaining.isEmpty else {
        throw CLIParseError(usage)
    }
    if remaining[0] == "--clear" {
        guard remaining.count == 1 else {
            throw CLIParseError(usage)
        }
        return CLICommand(request: .tabRename(tab: tab, title: nil), outputMode: .none)
    }
    if remaining[0].hasPrefix("--") {
        throw CLIParseError("unknown flag: \(remaining[0])")
    }
    let name = remaining.joined(separator: " ")
    guard !name.isEmpty else {
        throw CLIParseError(usage)
    }
    return CLICommand(request: .tabRename(tab: tab, title: name), outputMode: .none)
}

private func parseTabCloseCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm tab close --tab <tab-id>"
    guard args.count == 2, args[0] == "--tab" else { throw CLIParseError(usage) }
    return CLICommand(request: .tabClose(tab: try tabId(args[1])), outputMode: .none)
}

private func parsePaneInfoCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane info --pane <pane-id>"
    guard args.count == 2, args[0] == "--pane" else { throw CLIParseError(usage) }
    return CLICommand(request: .paneInfo(pane: try paneId(args[1])), outputMode: .json)
}

private func parsePaneSplitCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane split --pane <pane-id> -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
    let parsed: ParsedPaneSplit
    do {
        parsed = try parsePaneSplitArgs(args)
    } catch let error as PaneSplitParseError {
        switch error {
        case .missingDirection, .missingPaneArg, .missingValue(_):
            throw CLIParseError(usage)
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
        case .conflictingFocusFlags:
            throw CLIParseError("--background and --foreground are mutually exclusive\n\(usage)")
        }
    }

    guard let pane = parsed.pane else { throw CLIParseError(usage) }
    return CLICommand(
        request: .paneSplit(
            pane: try paneId(pane),
            direction: parsed.direction,
            launch: parsed.launch,
            background: parsed.foreground == false
        ),
        outputMode: .json
    )
}

/// Keeps destructive pane closure explicit at parse time before any request is sent.
private func parsePaneCloseCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane close --pane <pane-id>"
    guard args.count >= 2, args[0] == "--pane", args[1].isEmpty == false else {
        if let argument = args.first, argument.hasPrefix("--"), argument != "--pane" {
            throw CLIParseError("unknown flag: \(argument)")
        }
        throw CLIParseError(usage)
    }
    guard args.count == 2 else {
        let argument = args[2]
        if argument.hasPrefix("--") {
            throw CLIParseError("unknown flag: \(argument)")
        }
        throw CLIParseError("unexpected argument: \(argument)")
    }
    return CLICommand(
        request: .paneClose(pane: try paneId(args[1])),
        outputMode: .none
    )
}

private func parsePaneInputCommand(_ args: [String]) throws -> CLICommand {
    let parsed: ParsedSendKeys
    do {
        parsed = try parseSendKeysArgs(args)
    } catch SendKeysParseError.unknownFlag(let flag) {
        throw CLIParseError("unknown flag: \(flag)")
    } catch SendKeysParseError.missingPaneArg {
        throw CLIParseError("usage: danterm pane input --pane <pane-id> ...")
    } catch SendKeysParseError.literalRequiresSeparator {
        throw CLIParseError("--literal requires -- before the tokens")
    } catch SendKeysParseError.missingArguments {
        throw CLIParseError("usage: danterm pane input --pane <pane-id> [--literal] -- <token>...")
    } catch SendKeysParseError.keyToken(.unknownKey(let token)) {
        throw CLIParseError("unknown key: \(token)")
    }

    guard let pane = parsed.pane else {
        throw CLIParseError("usage: danterm pane input --pane <pane-id> [--literal] -- <token>...")
    }
    return CLICommand(
        request: .paneInput(pane: try paneId(pane), input: .events(parsed.events)),
        outputMode: .none
    )
}

private func parseThemeSetCommand(_ args: [String]) throws -> CLICommand {
    var remaining = args
    let usage = "usage: danterm theme set --pane <pane-id> <name>|--clear"
    guard remaining.count >= 2, remaining.first == "--pane" else { throw CLIParseError(usage) }
    let pane = try paneId(remaining[1])
    remaining.removeFirst(2)
    guard !remaining.isEmpty else {
        throw CLIParseError(usage)
    }
    if remaining[0] == "--clear" {
        guard remaining.count == 1 else {
            throw CLIParseError(usage)
        }
        return CLICommand(request: .themeSet(pane: pane, themeName: nil), outputMode: .none)
    }
    if remaining[0].hasPrefix("--") {
        throw CLIParseError("unknown flag: \(remaining[0])")
    }
    let name = remaining.joined(separator: " ")
    guard !name.isEmpty else {
        throw CLIParseError(usage)
    }
    return CLICommand(request: .themeSet(pane: pane, themeName: name), outputMode: .none)
}

private func parsePaneReadCommand(_ args: [String]) throws -> CLICommand {
    let parsed: ParsedReadPane
    do {
        parsed = try parseReadPaneArgs(args)
    } catch let error as ReadPaneParseError {
        switch error {
        case .missingPane, .missingPaneArg:
            throw CLIParseError("usage: danterm pane read --pane <uuid> [--lines <n>]")
        case .missingLinesArg, .invalidLines(_):
            throw CLIParseError("--lines must be a positive integer")
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
        }
    }

    return CLICommand(
        request: .paneRead(pane: try paneId(parsed.pane), lineLimit: parsed.lineLimit),
        outputMode: .text
    )
}

// The state is a positional word rather than a flag, and `toggle` is opt-in rather than the
// default: a script that can only toggle has to already know the current state, and the whole
// point of the command is to reach a known one.
private func parsePaneZoomCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane zoom --pane <pane-id> on|off|toggle"
    var pane: String?
    var state: String?
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--pane":
            guard index + 1 < args.count else { throw CLIParseError(usage) }
            pane = args[index + 1]
            index += 2
        case "on", "off", "toggle":
            guard state == nil else { throw CLIParseError(usage) }
            state = args[index]
            index += 1
        default:
            if args[index].hasPrefix("--") {
                throw CLIParseError("unknown flag: \(args[index])")
            }
            throw CLIParseError(usage)
        }
    }
    guard let pane, let state, let requestedState = IpcPaneZoomState(rawValue: state) else {
        throw CLIParseError(usage)
    }
    return CLICommand(
        request: .paneZoom(pane: try paneId(pane), state: requestedState),
        outputMode: .json
    )
}

// `pane rows` reuses `pane read`'s argument grammar minus `--lines`: the projection is the
// whole stream by construction, so a tail limit would only hide the retained rows it exists
// to inspect.
private func parsePaneRowsCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane rows --pane <pane-id>"
    var pane: String?
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--pane":
            guard index + 1 < args.count else { throw CLIParseError(usage) }
            pane = args[index + 1]
            index += 2
        default:
            if args[index].hasPrefix("--") {
                throw CLIParseError("unknown flag: \(args[index])")
            }
            throw CLIParseError("unexpected argument: \(args[index])")
        }
    }
    guard let pane, pane.isEmpty == false else { throw CLIParseError(usage) }
    return CLICommand(request: .paneRows(pane: try paneId(pane)), outputMode: .json)
}

private func parsePaneTapeCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane tape --pane <pane-id> [--follow] [--from-now]"
    let parsed: ParsedTapePane
    do {
        parsed = try parseTapePaneArgs(args)
    } catch let error as TapePaneParseError {
        switch error {
        case .missingPane, .missingPaneArg:
            throw CLIParseError(usage)
        case .fromNowRequiresFollow:
            throw CLIParseError("--from-now requires --follow\n\(usage)")
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
        }
    }
    return CLICommand(
        request: .paneTape(
            pane: try paneId(parsed.pane),
            follow: parsed.follow,
            fromNow: parsed.fromNow
        ),
        outputMode: .json
    )
}

private func parseAgentSessionCommand(
    _ args: [String],
    action: String,
    attach: Bool
) throws -> CLICommand {
    let usage = "usage: danterm agent \(action) --pane <pane-id> --kind <kind> --id <session-id>"
    var remaining = args
    var pane: String?
    var kind: String?
    var sessionId: String?

    while !remaining.isEmpty {
        let flag = remaining.removeFirst()
        switch flag {
        case "--pane":
            guard let value = remaining.first else { throw CLIParseError(usage) }
            pane = value
            remaining.removeFirst()
        case "--kind":
            guard let value = remaining.first else { throw CLIParseError(usage) }
            kind = value
            remaining.removeFirst()
        case "--id":
            guard let value = remaining.first else { throw CLIParseError(usage) }
            sessionId = value
            remaining.removeFirst()
        default:
            if flag.hasPrefix("--") {
                throw CLIParseError("unknown flag: \(flag)")
            }
            throw CLIParseError("unexpected argument: \(flag)")
        }
    }

    guard let pane, let kind, let sessionId else {
        throw CLIParseError(usage)
    }
    let requestPane = try paneId(pane)
    let session = IpcAgentSession(kind: kind, id: sessionId)
    return CLICommand(
        request: attach
            ? .agentAttach(pane: requestPane, session: session)
            : .agentDetach(pane: requestPane, session: session),
        outputMode: .none
    )
}

private func parseAgentActivityCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>"
    var remaining = args
    var pane: String?
    var kind: String?
    var sessionId: String?
    var state: String?

    while remaining.isEmpty == false {
        let flag = remaining.removeFirst()
        guard let value = remaining.first else { throw CLIParseError(usage) }
        remaining.removeFirst()
        switch flag {
        case "--pane": pane = value
        case "--kind": kind = value
        case "--id": sessionId = value
        case "--state": state = value
        default:
            if flag.hasPrefix("--") { throw CLIParseError("unknown flag: \(flag)") }
            throw CLIParseError("unexpected argument: \(flag)")
        }
    }

    guard let pane, let kind, let sessionId, let state else { throw CLIParseError(usage) }
    guard let activity = IpcAgentActivity(rawValue: state) else {
        throw CLIParseError("agent activity state must be working, waiting, or idle")
    }
    return CLICommand(
        request: .agentActivity(
            pane: try paneId(pane),
            session: IpcAgentSession(kind: kind, id: sessionId),
            activity: activity
        ),
        outputMode: .none
    )
}

private func parseTodo(_ args: [String]) throws -> CLICommand {
    guard let head = args.first else { throw CLIParseError("usage: danterm todo <command>") }
    let ownerUsage = "(--pane <pane-id> | --tab <tab-id>)"
    switch head {
    case "list":
        let usage = "usage: danterm todo list \(ownerUsage)"
        let (owner, rest) = try parseTodoOwnerPrefix(Array(args.dropFirst()), usage: usage)
        guard rest.isEmpty else { throw CLIParseError(usage) }
        return CLICommand(request: .todoList(owner: owner), outputMode: .json)
    case "add":
        let usage = "usage: danterm todo add \(ownerUsage) <text>"
        let (owner, rest) = try parseTodoOwnerPrefix(Array(args.dropFirst()), usage: usage)
        let text = rest.joined(separator: " ")
        guard !text.isEmpty else { throw CLIParseError(usage) }
        return CLICommand(request: .todoAdd(owner: owner, text: text), outputMode: .json)
    case "edit":
        let usage = "usage: danterm todo edit \(ownerUsage) <todo-id> <text>"
        let (owner, rest) = try parseTodoOwnerPrefix(Array(args.dropFirst()), usage: usage)
        guard rest.count >= 2, let todoId = UUID(uuidString: rest[0]) else { throw CLIParseError(usage) }
        let text = rest.dropFirst().joined(separator: " ")
        return CLICommand(
            request: .todoEdit(owner: owner, todoId: TodoId(rawValue: todoId), text: text),
            outputMode: .none
        )
    case "done":
        return try parseTodoIdCommand(method: .todoDone, args: Array(args.dropFirst()), usage: "usage: danterm todo done \(ownerUsage) <todo-id>")
    case "open":
        return try parseTodoIdCommand(method: .todoOpen, args: Array(args.dropFirst()), usage: "usage: danterm todo open \(ownerUsage) <todo-id>")
    case "delete":
        return try parseTodoIdCommand(method: .todoDelete, args: Array(args.dropFirst()), usage: "usage: danterm todo delete \(ownerUsage) <todo-id>")
    case "clear-completed":
        let usage = "usage: danterm todo clear-completed \(ownerUsage)"
        let (owner, rest) = try parseTodoOwnerPrefix(Array(args.dropFirst()), usage: usage)
        guard rest.isEmpty else { throw CLIParseError(usage) }
        return CLICommand(request: .todoClearCompleted(owner: owner), outputMode: .none)
    default:
        throw CLIParseError("unknown todo command")
    }
}

private func parseTodoOwnerPrefix(_ args: [String], usage: String) throws -> (TodoOwner, [String]) {
    guard args.first == "--pane" || args.first == "--tab" else { throw CLIParseError(usage) }
    guard args.count >= 2 else { throw CLIParseError(usage) }
    let owner: TodoOwner = args[0] == "--pane"
        ? .pane(try paneId(args[1]))
        : .tab(try tabId(args[1]))
    let rest = Array(args.dropFirst(2))
    guard rest.contains("--pane") == false, rest.contains("--tab") == false else {
        throw CLIParseError(usage)
    }
    return (owner, rest)
}

private func parseTodoIdCommand(method: IpcRequestMethod, args: [String], usage: String) throws -> CLICommand {
    let (owner, rest) = try parseTodoOwnerPrefix(args, usage: usage)
    guard rest.count == 1, let rawTodoId = UUID(uuidString: rest[0]) else { throw CLIParseError(usage) }
    let todoId = TodoId(rawValue: rawTodoId)
    let request: IpcRequest
    switch method {
    case .todoDone: request = .todoDone(owner: owner, todoId: todoId)
    case .todoOpen: request = .todoOpen(owner: owner, todoId: todoId)
    case .todoDelete: request = .todoDelete(owner: owner, todoId: todoId)
    default: preconditionFailure("todo id parser requires a todo mutation method")
    }
    return CLICommand(request: request, outputMode: .none)
}

private func paneId(_ raw: String) throws -> PaneId {
    guard let uuid = UUID(uuidString: raw) else { throw CLIParseError("invalid pane id: \(raw)") }
    return PaneId(rawValue: uuid)
}

private func tabId(_ raw: String) throws -> TabId {
    guard let uuid = UUID(uuidString: raw) else { throw CLIParseError("invalid tab id: \(raw)") }
    return TabId(rawValue: uuid)
}

private func groupId(_ raw: String) throws -> GroupId {
    guard let uuid = UUID(uuidString: raw) else { throw CLIParseError("invalid group id: \(raw)") }
    return GroupId(rawValue: uuid)
}
