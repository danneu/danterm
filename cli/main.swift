// Command-line client for DanTerm's JSON-RPC control socket.
import Foundation
import DanTermProtocol
import Darwin

private struct CLIError: Error {
    let message: String
    let exitCode: Int32

    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
}

private enum OutputMode {
    case none
    case json
    case tabTitle
    case text
}

private struct CLICommand {
    let method: String
    let params: [String: JSONValue]
    let outputMode: OutputMode
}

struct DanTermCLI {
    private static let socketTimeoutSeconds = 5

    // Top-level help text. Kept in sync by hand with `parseCommand` and
    // the `EnvVars` constants used in `request(...)` -- there is no
    // automated check, so any change to either touches this string too.
    private static let usageText: String = """
        danterm -- control DanTerm from the shell

        Usage:
          danterm <command> [args]

        Commands:
          ls                          Print the full app snapshot as JSON
          tab title [text]            Get or set the current tab title
          tab rename <name>           Rename the current tab
          pane focus <pane-id>        Focus a pane by id
          pane split [--pane <id>] -h|-v
                                      Split a pane (horizontal/vertical)
          new-tab [--group <name>]    Open a new tab, optionally in a named group
          send-keys [--pane <id>] [--literal] -- <token>...
                                      Send keystrokes to a pane (tmux-style:
                                      "ls" Enter, C-c, Up, Escape). Use --pane
                                      to target a specific pane (default:
                                      caller's via $DANTERM_PANE).
          read-pane --pane <id> [--lines <n>]
                                      Print a pane's visible text, or the last
                                      n lines of scrollback when --lines is set.
          theme set <name>|--clear    Set or clear the current theme
          todo list                   List todos as JSON
          todo add <text>             Add a todo
          todo edit <id> <text>       Edit a todo's text
          todo done <id>              Mark a todo done
          todo open <id>              Reopen a completed todo
          todo delete <id>            Delete a todo
          todo clear-completed        Remove all completed todos
          help, --help, -h            Print this message

        Environment:
          DANTERM_SOCK   Path to the DanTerm control socket
          DANTERM_PANE   Pane id for context-aware commands (set by shell integration)
          DANTERM_TAB    Tab id for context-aware commands (set by shell integration)

        """

    static func main() {
        do {
            // Intercept help before parseCommand so we never touch the IPC
            // socket for pure local arg handling.
            let rawArgs = Array(CommandLine.arguments.dropFirst())
            if rawArgs.isEmpty {
                fputs(usageText, stderr)
                exit(1)
            }
            if rawArgs == ["help"] || rawArgs == ["--help"] || rawArgs == ["-h"] {
                print(usageText, terminator: "")
                exit(0)
            }
            let command = try parseCommand(rawArgs)
            let environment = ProcessInfo.processInfo.environment
            let socketPath = nonEmpty(environment[EnvVars.sock]) ?? controlSocketPath().path
            let response = try request(command, socketPath: socketPath, environment: environment)
            if let error = response.error {
                throw CLIError(error.message)
            }
            try printResult(response.result ?? .null, mode: command.outputMode)
            exit(0)
        } catch let error as CLIError {
            fputs("danterm: \(error.message)\n", stderr)
            exit(error.exitCode)
        } catch {
            fputs("danterm: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func parseCommand(_ args: [String]) throws -> CLICommand {
        guard let head = args.first else { throw CLIError("missing command") }
        switch head {
        case "ls":
            guard args.count == 1 else {
                throw CLIError("usage: danterm ls")
            }
            return CLICommand(method: Methods.ls, params: [:], outputMode: .json)

        case "tab":
            guard args.count >= 2 else { throw CLIError("usage: danterm tab title [text]") }
            switch args[1] {
            case "title":
                let text = args.dropFirst(2).joined(separator: " ")
                let params: [String: JSONValue] = text.isEmpty ? [:] : ["title": .string(text)]
                return CLICommand(method: Methods.tabTitle, params: params, outputMode: text.isEmpty ? .tabTitle : .none)
            case "rename":
                let name = args.dropFirst(2).joined(separator: " ")
                guard !name.isEmpty else { throw CLIError("usage: danterm tab rename <name>") }
                return CLICommand(method: Methods.tabTitle, params: ["title": .string(name)], outputMode: .none)
            default:
                throw CLIError("unknown tab command")
            }

        case "pane":
            guard args.count >= 2 else { throw CLIError("usage: danterm pane <focus|split>") }
            switch args[1] {
            case "focus":
                guard args.count == 3 else { throw CLIError("usage: danterm pane focus <pane-id>") }
                return CLICommand(method: Methods.paneFocus, params: ["paneId": .string(args[2])], outputMode: .none)
            case "split":
                return try parsePaneSplitCommand(Array(args.dropFirst(2)))
            default:
                throw CLIError("unknown pane command")
            }

        case "new-tab":
            if args.count == 1 {
                return CLICommand(method: Methods.newTab, params: [:], outputMode: .none)
            }
            guard args.count >= 3, args[1] == "--group" else {
                throw CLIError("usage: danterm new-tab [--group <name>]")
            }
            let name = args.dropFirst(2).joined(separator: " ")
            guard !name.isEmpty else { throw CLIError("usage: danterm new-tab [--group <name>]") }
            return CLICommand(method: Methods.newTab, params: ["group": .string(name)], outputMode: .none)

        case "send-keys":
            return try parseSendKeysCommand(Array(args.dropFirst()))

        case "read-pane":
            return try parseReadPaneCommand(Array(args.dropFirst()))

        case "theme":
            guard args.count >= 3, args[1] == "set" else {
                throw CLIError("usage: danterm theme set <name>|--clear")
            }
            if args[2] == "--clear" {
                guard args.count == 3 else { throw CLIError("usage: danterm theme set --clear") }
                return CLICommand(method: Methods.themeSet, params: ["themeName": .null], outputMode: .none)
            }
            let name = args.dropFirst(2).joined(separator: " ")
            guard !name.isEmpty else { throw CLIError("usage: danterm theme set <name>|--clear") }
            return CLICommand(method: Methods.themeSet, params: ["themeName": .string(name)], outputMode: .none)

        case "todo":
            return try parseTodo(Array(args.dropFirst()))

        default:
            throw CLIError("unknown command: \(head)")
        }
    }

    private static func parseTodo(_ args: [String]) throws -> CLICommand {
        guard let head = args.first else { throw CLIError("usage: danterm todo <command>") }
        switch head {
        case "list":
            guard args.count == 1 else { throw CLIError("usage: danterm todo list") }
            return CLICommand(method: Methods.todoList, params: [:], outputMode: .json)
        case "add":
            let text = args.dropFirst().joined(separator: " ")
            guard !text.isEmpty else { throw CLIError("usage: danterm todo add <text>") }
            return CLICommand(method: Methods.todoAdd, params: ["text": .string(text)], outputMode: .json)
        case "edit":
            guard args.count >= 3 else { throw CLIError("usage: danterm todo edit <todo-id> <text>") }
            let text = args.dropFirst(2).joined(separator: " ")
            return CLICommand(method: Methods.todoEdit, params: ["todoId": .string(args[1]), "text": .string(text)], outputMode: .none)
        case "done":
            guard args.count == 2 else { throw CLIError("usage: danterm todo done <todo-id>") }
            return CLICommand(method: Methods.todoDone, params: ["todoId": .string(args[1])], outputMode: .none)
        case "open":
            guard args.count == 2 else { throw CLIError("usage: danterm todo open <todo-id>") }
            return CLICommand(method: Methods.todoOpen, params: ["todoId": .string(args[1])], outputMode: .none)
        case "delete":
            guard args.count == 2 else { throw CLIError("usage: danterm todo delete <todo-id>") }
            return CLICommand(method: Methods.todoDelete, params: ["todoId": .string(args[1])], outputMode: .none)
        case "clear-completed":
            guard args.count == 1 else { throw CLIError("usage: danterm todo clear-completed") }
            return CLICommand(method: Methods.todoClearCompleted, params: [:], outputMode: .none)
        default:
            throw CLIError("unknown todo command")
        }
    }

    private static func parsePaneSplitCommand(_ args: [String]) throws -> CLICommand {
        let parsed: ParsedPaneSplit
        do {
            parsed = try parsePaneSplitArgs(args)
        } catch let error as PaneSplitParseError {
            switch error {
            case .missingDirection, .missingPaneArg:
                throw CLIError("usage: danterm pane split [--pane <id>] -h|-v")
            case .unknownFlag(let flag):
                throw CLIError("unknown flag: \(flag)")
            case .unexpectedArgument(let argument):
                throw CLIError("unexpected argument: \(argument)")
            }
        }

        var params: [String: JSONValue] = [
            "direction": .string(parsed.direction == .horizontal ? "horizontal" : "vertical")
        ]
        if let pane = parsed.pane {
            params["pane"] = .string(pane)
        }
        return CLICommand(method: Methods.paneSplit, params: params, outputMode: .json)
    }

    private static func parseSendKeysCommand(_ args: [String]) throws -> CLICommand {
        let parsed: ParsedSendKeys
        do {
            parsed = try parseSendKeysArgs(args)
        } catch SendKeysParseError.unknownFlag(let flag) {
            throw CLIError("unknown flag: \(flag)")
        } catch SendKeysParseError.missingPaneArg {
            throw CLIError("usage: danterm send-keys --pane <id> ...")
        } catch SendKeysParseError.literalRequiresSeparator {
            throw CLIError("--literal requires -- before the tokens")
        } catch SendKeysParseError.missingArguments {
            throw CLIError("usage: danterm send-keys [--pane <id>] [--literal] -- <token>...")
        } catch SendKeysParseError.keyToken(.unknownKey(let token)) {
            throw CLIError("unknown key: \(token)")
        }

        var params: [String: JSONValue] = [:]
        if let pane = parsed.pane {
            params["pane"] = .string(pane)
        }
        params["input"] = .array(parsed.events.map(inputEventToJSON))
        return CLICommand(method: Methods.sendKeys, params: params, outputMode: .none)
    }

    private static func parseReadPaneCommand(_ args: [String]) throws -> CLICommand {
        let parsed: ParsedReadPane
        do {
            parsed = try parseReadPaneArgs(args)
        } catch let error as ReadPaneParseError {
            switch error {
            case .missingPane, .missingPaneArg:
                throw CLIError("usage: danterm read-pane --pane <uuid> [--lines <n>]")
            case .missingLinesArg, .invalidLines(_):
                throw CLIError("--lines must be a positive integer")
            case .unknownFlag(let flag):
                throw CLIError("unknown flag: \(flag)")
            case .unexpectedArgument(let argument):
                throw CLIError("unexpected argument: \(argument)")
            }
        }

        var params: [String: JSONValue] = ["pane": .string(parsed.pane)]
        if let lineLimit = parsed.lineLimit {
            params["lines"] = .number(Double(lineLimit))
        }
        return CLICommand(method: Methods.readPane, params: params, outputMode: .text)
    }

    // Map a single InputEvent to its JSON-RPC wire form. Inverse of
    // Update.swift's parseInputEvent — keep them in sync.
    private static func inputEventToJSON(_ event: InputEvent) -> JSONValue {
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

    // Canonical wire name for a KeyName. Aliases (Backspace -> BSpace, Esc ->
    // Escape) collapse to one canonical form on the way out.
    private static func wireName(for key: KeyName) -> String {
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

    private static func request(
        _ command: CLICommand,
        socketPath: String,
        environment: [String: String]
    ) throws -> JsonRpcResponse {
        let fd = try connectSocket(path: socketPath)
        defer { Darwin.close(fd) }

        guard let helloLine = try readLine(from: fd) else {
            throw CLIError("DanTerm closed the connection")
        }
        try validateHello(helloLine)

        let requestId = UUID().uuidString
        var params = command.params
        let context = IpcRequestContext(
            paneId: nonEmpty(environment[EnvVars.pane]),
            tabId: nonEmpty(environment[EnvVars.tab])
        )
        params[IpcRequestContext.paramsKey] = context.jsonValue
        let request = JsonRpcRequest(
            id: .string(requestId),
            method: command.method,
            params: .object(params)
        )
        try writeJSON(request, to: fd)

        while let line = try readLine(from: fd) {
            let data = Data(line.utf8)
            let response = try JSONDecoder().decode(JsonRpcResponse.self, from: data)
            if response.id == .string(requestId) {
                return response
            }
        }
        throw CLIError("DanTerm closed the connection")
    }

    private static func validateHello(_ line: String) throws {
        let hello = try JSONDecoder().decode(JsonRpcRequest.self, from: Data(line.utf8))
        guard hello.method == Methods.hello,
              let version = hello.params?["protocol"]?.asNumber
        else {
            throw CLIError("invalid hello from DanTerm")
        }
        guard Int(version) == 1 else {
            throw CLIError("unsupported DanTerm IPC protocol \(Int(version))")
        }
    }

    private static func connectSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("failed to create socket") }
        do {
            try configureSocketTimeouts(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(fd)
            throw CLIError("socket path is too long")
        }
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buffer = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw CLIError("DanTerm is not running")
        }
        return fd
    }

    private static func configureSocketTimeouts(_ fd: Int32) throws {
        try setNoSigPipe(fd)
        try setSocketTimeout(fd, option: SO_RCVTIMEO)
        try setSocketTimeout(fd, option: SO_SNDTIMEO)
    }

    private static func setNoSigPipe(_ fd: Int32) throws {
        var value: Int32 = 1
        let result = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
        guard result == 0 else {
            throw CLIError("failed to configure socket")
        }
    }

    private static func setSocketTimeout(_ fd: Int32, option: Int32) throws {
        var timeout = timeval(tv_sec: socketTimeoutSeconds, tv_usec: 0)
        let result = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, option, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        guard result == 0 else {
            throw CLIError("failed to configure socket timeout")
        }
    }

    private static func readLine(from fd: Int32) throws -> String? {
        var data = Data()
        var byte = UInt8(0)
        while true {
            let count = withUnsafeMutableBytes(of: &byte) { buffer in
                Darwin.read(fd, buffer.baseAddress, 1)
            }
            if count == 0 { return data.isEmpty ? nil : String(data: data, encoding: .utf8) }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError("DanTerm is not responding")
                }
                throw CLIError("failed to read from DanTerm")
            }
            if byte == 0x0A {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
            if data.count > 16 * 1024 * 1024 {
                throw CLIError("response line too large")
            }
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw CLIError("DanTerm is not responding")
                    }
                    throw CLIError("failed to write to DanTerm")
                }
                if written == 0 {
                    throw CLIError("DanTerm closed the connection")
                }
                offset += written
            }
        }
    }

    private static func printResult(_ result: JSONValue, mode: OutputMode) throws {
        switch mode {
        case .none:
            return
        case .json:
            print(try compactJson(result))
        case .tabTitle:
            print(result["title"]?.asString ?? "")
        case .text:
            guard let text = renderReadPaneResult(result) else {
                throw CLIError("malformed response")
            }
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    private static func compactJson(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

DanTermCLI.main()
