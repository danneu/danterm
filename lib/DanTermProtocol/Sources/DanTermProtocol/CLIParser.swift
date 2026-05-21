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
        guard args.count >= 2 else { throw CLIParseError("usage: danterm tab <new|rename>") }
        switch args[1] {
        case "new":
            return try parseTabNewCommand(Array(args.dropFirst(2)))
        case "rename":
            return try parseTabRenameCommand(Array(args.dropFirst(2)))
        default:
            throw CLIParseError("unknown tab command")
        }

    case "pane":
        guard args.count >= 2 else { throw CLIParseError("usage: danterm pane <focus|split|input|read>") }
        switch args[1] {
        case "focus":
            guard args.count == 3 else { throw CLIParseError("usage: danterm pane focus <pane-id>") }
            return CLICommand(method: Methods.paneFocus, params: ["paneId": .string(args[2])], outputMode: .none)
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
        guard args.count >= 3, args[1] == "set" else {
            throw CLIParseError("usage: danterm theme set <name>|--clear")
        }
        if args[2] == "--clear" {
            guard args.count == 3 else { throw CLIParseError("usage: danterm theme set --clear") }
            return CLICommand(method: Methods.themeSet, params: ["themeName": .null], outputMode: .none)
        }
        let name = args.dropFirst(2).joined(separator: " ")
        guard !name.isEmpty else { throw CLIParseError("usage: danterm theme set <name>|--clear") }
        return CLICommand(method: Methods.themeSet, params: ["themeName": .string(name)], outputMode: .none)

    case "todo":
        return try parseTodo(Array(args.dropFirst()))

    default:
        throw CLIParseError("unknown command: \(head)")
    }
}

private func parseTabNewCommand(_ args: [String]) throws -> CLICommand {
    let parsed: ParsedTabNew
    do {
        parsed = try parseTabNewArgs(args)
    } catch let error as TabNewParseError {
        switch error {
        case .missingValue(_):
            throw CLIParseError("usage: danterm tab new [--group <name>] [--cmd <s>] [--cwd <p>] [--title <s>]")
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
        }
    }

    var params: [String: JSONValue] = [:]
    if let group = parsed.group {
        params["group"] = .string(group)
    }
    if let launch = parsed.launch {
        params["launch"] = launch.jsonValue
    }
    return CLICommand(method: Methods.tabNew, params: params, outputMode: .json)
}

private func parseTabRenameCommand(_ args: [String]) throws -> CLICommand {
    guard !args.isEmpty else { throw CLIParseError("usage: danterm tab rename <name>|--clear") }
    if args[0] == "--clear" {
        guard args.count == 1 else { throw CLIParseError("usage: danterm tab rename --clear") }
        return CLICommand(method: Methods.tabRename, params: ["title": .null], outputMode: .none)
    }
    let name = args.joined(separator: " ")
    guard !name.isEmpty else { throw CLIParseError("usage: danterm tab rename <name>|--clear") }
    return CLICommand(method: Methods.tabRename, params: ["title": .string(name)], outputMode: .none)
}

private func parsePaneSplitCommand(_ args: [String]) throws -> CLICommand {
    let parsed: ParsedPaneSplit
    do {
        parsed = try parsePaneSplitArgs(args)
    } catch let error as PaneSplitParseError {
        switch error {
        case .missingDirection, .missingPaneArg, .missingValue(_):
            throw CLIParseError("usage: danterm pane split [--pane <id>] -h|-v [--cmd <s>] [--cwd <p>] [--title <s>]")
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
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
    return CLICommand(method: Methods.paneSplit, params: params, outputMode: .json)
}

private func parsePaneInputCommand(_ args: [String]) throws -> CLICommand {
    let parsed: ParsedSendKeys
    do {
        parsed = try parseSendKeysArgs(args)
    } catch SendKeysParseError.unknownFlag(let flag) {
        throw CLIParseError("unknown flag: \(flag)")
    } catch SendKeysParseError.missingPaneArg {
        throw CLIParseError("usage: danterm pane input --pane <id> ...")
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
        guard args.count == 1 else { throw CLIParseError("usage: danterm todo list") }
        return CLICommand(method: Methods.todoList, params: [:], outputMode: .json)
    case "add":
        let text = args.dropFirst().joined(separator: " ")
        guard !text.isEmpty else { throw CLIParseError("usage: danterm todo add <text>") }
        return CLICommand(method: Methods.todoAdd, params: ["text": .string(text)], outputMode: .json)
    case "edit":
        guard args.count >= 3 else { throw CLIParseError("usage: danterm todo edit <todo-id> <text>") }
        let text = args.dropFirst(2).joined(separator: " ")
        return CLICommand(method: Methods.todoEdit, params: ["todoId": .string(args[1]), "text": .string(text)], outputMode: .none)
    case "done":
        guard args.count == 2 else { throw CLIParseError("usage: danterm todo done <todo-id>") }
        return CLICommand(method: Methods.todoDone, params: ["todoId": .string(args[1])], outputMode: .none)
    case "open":
        guard args.count == 2 else { throw CLIParseError("usage: danterm todo open <todo-id>") }
        return CLICommand(method: Methods.todoOpen, params: ["todoId": .string(args[1])], outputMode: .none)
    case "delete":
        guard args.count == 2 else { throw CLIParseError("usage: danterm todo delete <todo-id>") }
        return CLICommand(method: Methods.todoDelete, params: ["todoId": .string(args[1])], outputMode: .none)
    case "clear-completed":
        guard args.count == 1 else { throw CLIParseError("usage: danterm todo clear-completed") }
        return CLICommand(method: Methods.todoClearCompleted, params: [:], outputMode: .none)
    default:
        throw CLIParseError("unknown todo command")
    }
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
