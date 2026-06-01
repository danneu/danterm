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

public struct CLIParseError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
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
        guard args.count >= 2 else { throw CLIParseError("usage: danterm pane <focus|info|split|input|read>") }
        switch args[1] {
        case "focus":
            guard args.count == 3 else { throw CLIParseError("usage: danterm pane focus <pane-id>") }
            return CLICommand(method: Methods.paneFocus, params: ["paneId": .string(args[2])], outputMode: .none)
        case "info":
            return try parsePaneInfoCommand(Array(args.dropFirst(2)))
        case "split":
            return try parsePaneSplitCommand(Array(args.dropFirst(2)))
        case "input":
            return try parsePaneInputCommand(Array(args.dropFirst(2)))
        case "read":
            return try parsePaneReadCommand(Array(args.dropFirst(2)))
        default:
            throw CLIParseError("unknown pane command")
        }

    case "theme":
        guard args.count >= 2, args[1] == "set" else {
            throw CLIParseError("usage: danterm theme set [--pane <pane-id>] <name>|--clear")
        }
        return try parseThemeSetCommand(Array(args.dropFirst(2)))

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
        var object: [String: JSONValue] = ["key": .string(wireName(for: key))]
        if !mods.isEmpty {
            var modNames: [JSONValue] = []
            if mods.contains(.ctrl) { modNames.append(.string("ctrl")) }
            if mods.contains(.alt)  { modNames.append(.string("alt")) }
            object["mods"] = .array(modNames)
        }
        return .object(object)
    }
}

private func wireName(for key: KeyName) -> String {
    switch key {
    case .letter(let c):
        return String(c)
    case .named(let n):
        switch n {
        case .enter:  return "Enter"
        case .tab:    return "Tab"
        case .bspace: return "BSpace"
        case .escape: return "Escape"
        case .up:     return "Up"
        case .down:   return "Down"
        case .left:   return "Left"
        case .right:  return "Right"
        case .home:   return "Home"
        case .end:    return "End"
        case .pgUp:   return "PgUp"
        case .pgDn:   return "PgDn"
        case .delete: return "Delete"
        case .f1:  return "F1"
        case .f2:  return "F2"
        case .f3:  return "F3"
        case .f4:  return "F4"
        case .f5:  return "F5"
        case .f6:  return "F6"
        case .f7:  return "F7"
        case .f8:  return "F8"
        case .f9:  return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }
}
