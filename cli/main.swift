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

struct DanTermCLI {
    private static let socketTimeoutSeconds = 5

    // Top-level help text. Kept in sync by hand with `parseCLI` and
    // the `EnvVars` constants used in `request(...)` -- there is no
    // automated check, so any change to either touches this string too.
    private static let usageText: String = """
        danterm -- control DanTerm from the shell

        Usage:
          danterm <command> [args]

        Commands:
          ls                          Print the full app snapshot as JSON
          tab new [--group <group-id>] [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]
                  [--after-selected | --at-group-end | --after-tab <tab-id>]
                                      Open a new tab, optionally launching a command
          tab rename [--tab <tab-id>] <name>|--clear
                                      Rename a tab or clear its custom title
          tab close [--tab <tab-id>]
                                      Close a tab
          pane focus <pane-id>        Focus a pane by id
          pane info [--pane <pane-id>]
                                      Print pane, tab, and group metadata as JSON
          pane split [--pane <pane-id>] -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]
                                      Split a pane (horizontal/vertical)
          pane input [--pane <pane-id>] [--literal] -- <token>...
                                      Send keystrokes to a pane (tmux-style:
                                      "ls" Enter, C-c, Up, Escape). Use --pane
                                      to target a specific pane (default:
                                      caller's via $DANTERM_PANE).
          pane read --pane <pane-id> [--lines <n>]
                                      Print a pane's visible text, or the last
                                      n lines of scrollback when --lines is set.
          theme set [--pane <pane-id>] <name>|--clear
                                      Set or clear a pane theme
          todo list [--pane <pane-id>]
                                      List todos as JSON
          todo add [--pane <pane-id>] <text>
                                      Add a todo
          todo edit [--pane <pane-id>] <id> <text>
                                      Edit a todo's text
          todo done [--pane <pane-id>] <id>
                                      Mark a todo done
          todo open [--pane <pane-id>] <id>
                                      Reopen a completed todo
          todo delete [--pane <pane-id>] <id>
                                      Delete a todo
          todo clear-completed [--pane <pane-id>]
                                      Remove all completed todos
          help, --help, -h            Print this message

        CLI defaults:
          tab new opens in the background at the target group end by default.
          Position flags change placement; --foreground selects the new tab.
          pane split opens in the background by default; --foreground focuses
          the new pane within its tab. App UI shortcuts are unaffected.

        Environment:
          DANTERM_SOCK   Path to the DanTerm control socket
          DANTERM_PANE   Pane id for context-aware commands (set by shell integration)

        """

    static func main() {
        do {
            // Intercept help before parseCLI so we never touch the IPC
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
            let command = try parseCLI(rawArgs)
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
        } catch let error as CLIParseError {
            fputs("danterm: \(error.message)\n", stderr)
            exit(1)
        } catch {
            fputs("danterm: \(error.localizedDescription)\n", stderr)
            exit(1)
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
            paneId: nonEmpty(environment[EnvVars.pane])
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

    private static func printResult(_ result: JSONValue, mode: CLIOutputMode) throws {
        switch mode {
        case .none:
            return
        case .json:
            print(try compactJson(result))
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
