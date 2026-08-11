// Public parser for the `danterm` command-line command surface.
import Foundation

public enum CLIOutputMode: Equatable {
    case none
    case json
    case text
}

public struct CLICommand: Equatable {
    public let method: String
    public let params: [String: JSONValue]
    public let outputMode: CLIOutputMode

    public init(method: String, params: [String: JSONValue], outputMode: CLIOutputMode) {
        self.method = method
        self.params = params
        self.outputMode = outputMode
    }
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
public func parseCLIInvocation(_ args: [String]) throws -> CLIInvocation {
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

    return CLIInvocation(socketPath: socketPath, command: try parseCLI(remaining))
}

public func parseCLI(_ args: [String]) throws -> CLICommand {
    guard let head = args.first else { throw CLIParseError("missing command") }
    switch head {
    case "ls":
        guard args.count == 1 else {
            throw CLIParseError("usage: danterm ls")
        }
        return CLICommand(method: Methods.ls, params: [:], outputMode: .json)

    case "tab":
        guard args.count >= 2 else { throw CLIParseError("usage: danterm tab <new|rename|close>") }
        switch args[1] {
        case "new":
            return try parseTabNewCommand(Array(args.dropFirst(2)))
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
            return CLICommand(method: Methods.paneFocus, params: ["pane": .string(args[2])], outputMode: .none)
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
            throw CLIParseError("usage: danterm theme set [--pane <pane-id>] <name>|--clear")
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
                method: Methods.agentAttach
            )
        case "activity":
            return try parseAgentActivityCommand(Array(args.dropFirst(2)))
        case "detach":
            return try parseAgentSessionCommand(
                Array(args.dropFirst(2)),
                action: "detach",
                method: Methods.agentDetach
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

private func parseTabNewCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground] [--after-selected | --at-group-end | --after-tab <tab-id>]"
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

    var params: [String: JSONValue] = [:]
    if let group = parsed.group {
        params["group"] = .string(group)
    }
    if let launch = parsed.launch {
        params["launch"] = launch.jsonValue
    }
    params["background"] = .bool(parsed.foreground ? false : true)
    switch parsed.position {
    case .none:
        params["position"] = .string("atGroupEnd")
    case .afterSelected:
        params["position"] = .string("afterSelected")
    case .atGroupEnd:
        params["position"] = .string("atGroupEnd")
    case .afterTab(let id):
        params["position"] = .string("afterTab")
        params["afterTabId"] = .string(id)
    }
    return CLICommand(method: Methods.tabNew, params: params, outputMode: .json)
}

private func parseTabRenameCommand(_ args: [String]) throws -> CLICommand {
    var remaining = args
    var params: [String: JSONValue] = [:]
    if remaining.first == "--tab" {
        guard remaining.count >= 2 else {
            throw CLIParseError("usage: danterm tab rename [--tab <tab-id>] <name>|--clear")
        }
        params["tab"] = .string(remaining[1])
        remaining.removeFirst(2)
    }
    guard !remaining.isEmpty else {
        throw CLIParseError("usage: danterm tab rename [--tab <tab-id>] <name>|--clear")
    }
    if remaining[0] == "--clear" {
        guard remaining.count == 1 else {
            throw CLIParseError("usage: danterm tab rename [--tab <tab-id>] --clear")
        }
        params["title"] = .null
        return CLICommand(method: Methods.tabRename, params: params, outputMode: .none)
    }
    if remaining[0].hasPrefix("--") {
        throw CLIParseError("unknown flag: \(remaining[0])")
    }
    let name = remaining.joined(separator: " ")
    guard !name.isEmpty else {
        throw CLIParseError("usage: danterm tab rename [--tab <tab-id>] <name>|--clear")
    }
    params["title"] = .string(name)
    return CLICommand(method: Methods.tabRename, params: params, outputMode: .none)
}

private func parseTabCloseCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm tab close [--tab <tab-id>]"
    var remaining = args
    var params: [String: JSONValue] = [:]
    if remaining.first == "--tab" {
        guard remaining.count >= 2 else { throw CLIParseError(usage) }
        params["tab"] = .string(remaining[1])
        remaining.removeFirst(2)
    }
    guard remaining.isEmpty else {
        if remaining[0].hasPrefix("--") { throw CLIParseError("unknown flag: \(remaining[0])") }
        throw CLIParseError("unexpected argument: \(remaining[0])")
    }
    return CLICommand(method: Methods.tabClose, params: params, outputMode: .none)
}

private func parsePaneInfoCommand(_ args: [String]) throws -> CLICommand {
    switch args.count {
    case 0:
        return CLICommand(method: Methods.paneInfo, params: [:], outputMode: .json)
    case 2 where args[0] == "--pane":
        return CLICommand(method: Methods.paneInfo, params: ["pane": .string(args[1])], outputMode: .json)
    default:
        throw CLIParseError("usage: danterm pane info [--pane <pane-id>]")
    }
}

private func parsePaneSplitCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane split [--pane <pane-id>] -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]"
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

    var params: [String: JSONValue] = [
        "direction": .string(parsed.direction == .horizontal ? "horizontal" : "vertical")
    ]
    if let pane = parsed.pane {
        params["pane"] = .string(pane)
    }
    if let launch = parsed.launch {
        params["launch"] = launch.jsonValue
    }
    params["background"] = .bool(parsed.foreground ? false : true)
    return CLICommand(method: Methods.paneSplit, params: params, outputMode: .json)
}

/// Keeps destructive pane closure explicit at parse time, before request
/// context can supply any implicit target.
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
        method: Methods.paneClose,
        params: ["pane": .string(args[1])],
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
        throw CLIParseError("usage: danterm pane input [--pane <id>] [--literal] -- <token>...")
    } catch SendKeysParseError.keyToken(.unknownKey(let token)) {
        throw CLIParseError("unknown key: \(token)")
    }

    var params: [String: JSONValue] = [:]
    if let pane = parsed.pane {
        params["pane"] = .string(pane)
    }
    params["input"] = .array(parsed.events.map(inputEventToJSON))
    return CLICommand(method: Methods.paneInput, params: params, outputMode: .none)
}

private func parseThemeSetCommand(_ args: [String]) throws -> CLICommand {
    var remaining = args
    var params: [String: JSONValue] = [:]
    if remaining.first == "--pane" {
        guard remaining.count >= 2 else {
            throw CLIParseError("usage: danterm theme set [--pane <pane-id>] <name>|--clear")
        }
        params["pane"] = .string(remaining[1])
        remaining.removeFirst(2)
    }
    guard !remaining.isEmpty else {
        throw CLIParseError("usage: danterm theme set [--pane <pane-id>] <name>|--clear")
    }
    if remaining[0] == "--clear" {
        guard remaining.count == 1 else {
            throw CLIParseError("usage: danterm theme set [--pane <pane-id>] --clear")
        }
        params["themeName"] = .null
        return CLICommand(method: Methods.themeSet, params: params, outputMode: .none)
    }
    if remaining[0].hasPrefix("--") {
        throw CLIParseError("unknown flag: \(remaining[0])")
    }
    let name = remaining.joined(separator: " ")
    guard !name.isEmpty else {
        throw CLIParseError("usage: danterm theme set [--pane <pane-id>] <name>|--clear")
    }
    params["themeName"] = .string(name)
    return CLICommand(method: Methods.themeSet, params: params, outputMode: .none)
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

    var params: [String: JSONValue] = ["pane": .string(parsed.pane)]
    if let lineLimit = parsed.lineLimit {
        params["lines"] = .number(Double(lineLimit))
    }
    return CLICommand(method: Methods.paneRead, params: params, outputMode: .text)
}

// The state is a positional word rather than a flag, and `toggle` is opt-in rather than the
// default: a script that can only toggle has to already know the current state, and the whole
// point of the command is to reach a known one.
private func parsePaneZoomCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane zoom [--pane <pane-id>] on|off|toggle"
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
    guard let state else { throw CLIParseError(usage) }
    var params: [String: JSONValue] = ["state": .string(state)]
    if let pane, pane.isEmpty == false { params["pane"] = .string(pane) }
    return CLICommand(method: Methods.paneZoom, params: params, outputMode: .json)
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
    return CLICommand(method: Methods.paneRows, params: ["pane": .string(pane)], outputMode: .json)
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
    var params: [String: JSONValue] = ["pane": .string(parsed.pane)]
    if parsed.follow {
        params["follow"] = .bool(true)
    }
    if parsed.fromNow {
        params["fromNow"] = .bool(true)
    }
    return CLICommand(
        method: Methods.paneTape,
        params: params,
        outputMode: .json
    )
}

private func parseAgentSessionCommand(
    _ args: [String],
    action: String,
    method: String
) throws -> CLICommand {
    let usage = "usage: danterm agent \(action) --kind <kind> --id <session-id>"
    var remaining = args
    var kind: String?
    var sessionId: String?

    while !remaining.isEmpty {
        let flag = remaining.removeFirst()
        switch flag {
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

    guard let kind, let sessionId else {
        throw CLIParseError(usage)
    }
    return CLICommand(
        method: method,
        params: ["kind": .string(kind), "id": .string(sessionId)],
        outputMode: .none
    )
}

private func parseAgentActivityCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm agent activity --kind <kind> --id <session-id> --state <working|waiting|idle>"
    var remaining = args
    var kind: String?
    var sessionId: String?
    var state: String?

    while remaining.isEmpty == false {
        let flag = remaining.removeFirst()
        guard let value = remaining.first else { throw CLIParseError(usage) }
        remaining.removeFirst()
        switch flag {
        case "--kind": kind = value
        case "--id": sessionId = value
        case "--state": state = value
        default:
            if flag.hasPrefix("--") { throw CLIParseError("unknown flag: \(flag)") }
            throw CLIParseError("unexpected argument: \(flag)")
        }
    }

    guard let kind, let sessionId, let state else { throw CLIParseError(usage) }
    guard ["working", "waiting", "idle"].contains(state) else {
        throw CLIParseError("agent activity state must be working, waiting, or idle")
    }
    return CLICommand(
        method: Methods.agentActivity,
        params: ["kind": .string(kind), "id": .string(sessionId), "state": .string(state)],
        outputMode: .none
    )
}

private func parseTodo(_ args: [String]) throws -> CLICommand {
    guard let head = args.first else { throw CLIParseError("usage: danterm todo <command>") }
    switch head {
    case "list":
        let (pane, rest) = try parseTodoPanePrefix(Array(args.dropFirst()), usage: "usage: danterm todo list [--pane <pane-id>]")
        guard rest.isEmpty else { throw CLIParseError("usage: danterm todo list [--pane <pane-id>]") }
        return CLICommand(method: Methods.todoList, params: todoParams(pane: pane), outputMode: .json)
    case "add":
        let (pane, rest) = try parseTodoPanePrefix(Array(args.dropFirst()), usage: "usage: danterm todo add [--pane <pane-id>] <text>")
        let text = rest.joined(separator: " ")
        guard !text.isEmpty else { throw CLIParseError("usage: danterm todo add [--pane <pane-id>] <text>") }
        var params = todoParams(pane: pane)
        params["text"] = .string(text)
        return CLICommand(method: Methods.todoAdd, params: params, outputMode: .json)
    case "edit":
        let (pane, rest) = try parseTodoPanePrefix(Array(args.dropFirst()), usage: "usage: danterm todo edit [--pane <pane-id>] <todo-id> <text>")
        guard rest.count >= 2 else { throw CLIParseError("usage: danterm todo edit [--pane <pane-id>] <todo-id> <text>") }
        let text = rest.dropFirst().joined(separator: " ")
        var params = todoParams(pane: pane)
        params["todoId"] = .string(rest[0])
        params["text"] = .string(text)
        return CLICommand(method: Methods.todoEdit, params: params, outputMode: .none)
    case "done":
        return try parseTodoIdCommand(method: Methods.todoDone, args: Array(args.dropFirst()), usage: "usage: danterm todo done [--pane <pane-id>] <todo-id>")
    case "open":
        return try parseTodoIdCommand(method: Methods.todoOpen, args: Array(args.dropFirst()), usage: "usage: danterm todo open [--pane <pane-id>] <todo-id>")
    case "delete":
        return try parseTodoIdCommand(method: Methods.todoDelete, args: Array(args.dropFirst()), usage: "usage: danterm todo delete [--pane <pane-id>] <todo-id>")
    case "clear-completed":
        let (pane, rest) = try parseTodoPanePrefix(Array(args.dropFirst()), usage: "usage: danterm todo clear-completed [--pane <pane-id>]")
        guard rest.isEmpty else { throw CLIParseError("usage: danterm todo clear-completed [--pane <pane-id>]") }
        return CLICommand(method: Methods.todoClearCompleted, params: todoParams(pane: pane), outputMode: .none)
    default:
        throw CLIParseError("unknown todo command")
    }
}

private func parseTodoPanePrefix(_ args: [String], usage: String) throws -> (String?, [String]) {
    guard args.first == "--pane" else { return (nil, args) }
    guard args.count >= 2 else { throw CLIParseError(usage) }
    return (args[1], Array(args.dropFirst(2)))
}

private func parseTodoIdCommand(method: String, args: [String], usage: String) throws -> CLICommand {
    let (pane, rest) = try parseTodoPanePrefix(args, usage: usage)
    guard rest.count == 1 else { throw CLIParseError(usage) }
    var params = todoParams(pane: pane)
    params["todoId"] = .string(rest[0])
    return CLICommand(method: method, params: params, outputMode: .none)
}

private func todoParams(pane: String?) -> [String: JSONValue] {
    guard let pane else { return [:] }
    return ["pane": .string(pane)]
}

private func inputEventToJSON(_ event: InputEvent) -> JSONValue {
    switch event {
    case .text(let text):
        return .object(["text": .string(text)])
    case .key(let key, let mods):
        var object: [String: JSONValue] = ["key": .string(key.wireName)]
        if !mods.isEmpty {
            var modNames: [JSONValue] = []
            if mods.contains(.ctrl) { modNames.append(.string("ctrl")) }
            if mods.contains(.alt)  { modNames.append(.string("alt")) }
            if mods.contains(.shift) { modNames.append(.string("shift")) }
            object["mods"] = .array(modNames)
        }
        return .object(object)
    }
}
