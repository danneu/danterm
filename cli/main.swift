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
}

private struct CLICommand {
    let method: String
    let params: [String: JSONValue]
    let outputMode: OutputMode
}

struct DanTermCLI {
    private static let socketTimeoutSeconds = 5

    static func main() {
        do {
            let command = try parseCommand(Array(CommandLine.arguments.dropFirst()))
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
            guard args.count == 1 || args == ["ls", "--json"] else {
                throw CLIError("usage: danterm ls [--json]")
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
                guard args.count == 3 else { throw CLIError("usage: danterm pane split -h|-v") }
                let direction: String
                switch args[2] {
                case "-h": direction = "horizontal"
                case "-v": direction = "vertical"
                default: throw CLIError("usage: danterm pane split -h|-v")
                }
                return CLICommand(method: Methods.paneSplit, params: ["direction": .string(direction)], outputMode: .none)
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
            let text = args.dropFirst().joined(separator: " ")
            guard !text.isEmpty else { throw CLIError("usage: danterm send-keys <text>") }
            return CLICommand(method: Methods.sendKeys, params: ["text": .string(text)], outputMode: .none)

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
