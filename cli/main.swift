// Local utility commands and the command-line client for DanTerm's JSON-RPC socket.
import Foundation
import DanTermProtocol
import DanTermSupport
import Darwin

struct CLIError: Error {
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
          danterm [--socket <path>] <command> [args]

        Commands:
          ls                          Print the full app snapshot as JSON
          focus                       Print the main window's live focus owner as JSON
          group new --name <name> [--cmd <s>] [--cwd <p>] [--title <s>]
                    [--background] [--foreground]
                                      Create a group and its first tab
          group rename --group <group-id> <name>
                                      Rename a group
          group close --group <group-id> [--move-tabs]
                                      Close a group, with its tabs or after
                                      moving them to the adjacent group
          tab new (--group <group-id> | --after-tab <tab-id>) [--cmd <s>] [--cwd <p>] [--title <s>]
                  [--background] [--foreground] [--after-selected | --at-group-end]
                                      Open a new tab, optionally launching a command
          tab rename --tab <tab-id> <name>|--clear
                                      Rename a tab or clear its custom title
          tab close --tab <tab-id>
                                      Close a tab
          pane focus <pane-id>        Focus a pane by id
          pane info --pane <pane-id>
                                      Print pane, tab, and group metadata as JSON
          pane split --pane <pane-id> -h|-v [--cmd <s>] [--cwd <p>] [--title <s>] [--background] [--foreground]
                                      Split a pane (horizontal/vertical)
          pane close --pane <pane-id>  Close a pane
          pane input --pane <pane-id> [--literal] -- <token>...
                                      Send keystrokes to a pane (tmux-style:
                                      "ls" Enter, C-c, Up, Escape).
          pane read --pane <pane-id> [--lines <n>]
                                      Print a pane's visible text, or the last
                                      n lines of scrollback when --lines is set.
          pane zoom --pane <pane-id> on|off|toggle
                                      Zoom a pane to fill its tab, or restore the
                                      split. Prints the tab's resulting zoom state.
          pane rows --pane <pane-id>
                                      Print each display row's line structure as
                                      JSON: wrap claim, content end, and width.
          pane tape --pane <pane-id> [--follow] [--from-now]
                    [--format replay|inspect]
                                      Print the pane's flight recording as JSON
                                      Lines: one start record, then one record per
                                      event. --follow keeps the stream open for
                                      live events; --from-now skips the backlog.
                                      --format inspect replaces each payload with
                                      readable spans; replay (the default) keeps
                                      the exact bytes.
          theme set --pane <pane-id> <name>|--clear
                                      Set or clear a pane theme
          agent attach --pane <pane-id> --kind <kind> --id <session-id>
                                      Attach the caller's root agent session
          agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>
                                      Report explicit root-agent activity
          agent detach --pane <pane-id> --kind <kind> --id <session-id>
                                      Detach the matching root agent session
          skill                       Print DanTerm's agent skill instructions
          doctor                      Check DanTerm integration health
          todo list (--pane <pane-id> | --tab <tab-id>)
                                      List todos as JSON
          todo add (--pane <pane-id> | --tab <tab-id>) <text>
                                      Add a todo
          todo edit (--pane <pane-id> | --tab <tab-id>) <id> <text>
                                      Edit a todo's text
          todo done (--pane <pane-id> | --tab <tab-id>) <id>
                                      Mark a todo done
          todo open (--pane <pane-id> | --tab <tab-id>) <id>
                                      Reopen a completed todo
          todo delete (--pane <pane-id> | --tab <tab-id>) <id>
                                      Delete a todo
          todo clear-completed (--pane <pane-id> | --tab <tab-id>)
                                      Remove all completed todos
          help, --help, -h            Print this message

        CLI defaults:
          --socket explicitly targets one DanTerm instance and overrides
          DANTERM_SOCK and identity-derived socket lookup.
          tab new opens in the background at the target group end by default.
          Position flags change placement; --foreground selects the new tab.
          group new opens in the background too; --foreground selects its tab.
          group close refuses the last group, and refuses to close the group
          holding every tab unless --move-tabs keeps those tabs.
          pane split opens in the background by default; --foreground focuses
          the new pane within its tab. App UI shortcuts are unaffected.

        Environment:
          DANTERM        Marks a process launched inside DanTerm. Without a
                         non-empty DANTERM_SOCK, socket lookup fails closed.
          DANTERM_SOCK   Path to the DanTerm control socket
          DANTERM_PANE   Pane id exported for callers to pass explicitly

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
            if rawArgs.first == "skill" {
                try runSkill(Array(rawArgs.dropFirst()))
                return
            }
            if rawArgs.first == "doctor" {
                try runDoctor(Array(rawArgs.dropFirst()))
                return
            }
            let invocation = try parseCLIInvocation(rawArgs)
            let command = invocation.command
            let environment = ProcessInfo.processInfo.environment
            let socketPath = try selectControlSocketPath(
                explicit: invocation.socketPath,
                environment: environment,
                fallback: controlSocketPath().path
            )
            // Every tape capture is a record stream, finite or followed alike, so none of them
            // go through the single-result request path below.
            if case .tapeStream(let format) = command.outputMode {
                signal(SIGPIPE, SIG_IGN)
                try requestPaneTape(command, socketPath: socketPath, format: format)
                exit(0)
            }
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
        let fd = try connectSocket(path: socketPath, receiveTimeout: true)
        defer { Darwin.close(fd) }

        guard let helloLine = try readLine(from: fd) else {
            throw CLIError("DanTerm closed the connection")
        }
        try validateHello(helloLine)

        let (requestId, request) = makeRequest(command)
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

    /// Renders one tape capture to stdout. The socket carries no receive timeout: a followed
    /// stream is idle whenever its pane is, and a finite dump's records arrive at the app's
    /// pace, so a timeout here would cut a healthy capture short.
    private static func requestPaneTape(
        _ command: CLICommand,
        socketPath: String,
        format: PaneTapeFormat
    ) throws {
        let fd = try connectSocket(path: socketPath, receiveTimeout: false)
        defer { Darwin.close(fd) }

        guard let helloLine = try readLine(from: fd) else {
            throw CLIError("DanTerm closed the connection")
        }
        try validateHello(helloLine)

        let (requestId, request) = makeRequest(command)
        try writeJSON(request, to: fd)
        let outcome = try renderPaneTapeStream(
            socket: fd,
            output: STDOUT_FILENO,
            requestId: requestId,
            transform: format == .inspect ? paneTapeInspectRecord : { $0 }
        )
        if let failure = paneTapeStreamFailure(for: outcome) {
            throw failure
        }
    }

    private static func makeRequest(_ command: CLICommand) -> (id: String, request: JsonRpcRequest) {
        let requestId = UUID().uuidString
        return (
            requestId,
            makeCLIRequest(command, id: .string(requestId))
        )
    }

    private static func runDoctor(_ args: [String]) throws {
        for arg in args {
            if arg.hasPrefix("-") {
                throw CLIParseError("unknown flag: \(arg)")
            }
            throw CLIParseError("unexpected argument: \(arg)")
        }

        let checks = evaluateDoctor(gatherDoctorFacts(
            permissions: gatherDoctorPermissions()
        ))
        print(renderDoctorReport(checks), terminator: "")
        exit(doctorExitCode(for: checks))
    }

    /// Best-effort app query: local doctor checks remain useful when no instance is running.
    private static func gatherDoctorPermissions() -> DoctorFacts.Permissions {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = try? selectControlSocketPath(
            explicit: nil,
            environment: environment,
            fallback: controlSocketPath().path
        ) else { return .unavailable }
        let command = CLICommand(request: .doctorPermissions, outputMode: .none)
        guard let response = try? request(command, socketPath: socketPath, environment: environment),
              response.error == nil,
              let result = response.result,
              let permissions = DoctorFacts.Permissions(jsonValue: result)
        else { return .unavailable }
        return permissions
    }

    private static func runSkill(_ args: [String]) throws {
        for arg in args {
            if arg.hasPrefix("-") {
                throw CLIParseError("unknown flag: \(arg)")
            }
            throw CLIParseError("unexpected argument: \(arg)")
        }

        do {
            let data = try loadBundledSkill(
                argv0: CommandLine.arguments.first ?? "",
                environment: ProcessInfo.processInfo.environment,
                fileManager: .default
            )
            try FileHandle.standardOutput.write(contentsOf: data)
            exit(0)
        } catch is SkillCommandError {
            throw CLIError("bundled skill is missing or unreadable")
        }
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

    private static func connectSocket(path: String, receiveTimeout: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("failed to create socket") }
        do {
            try configureSocket(fd, receiveTimeout: receiveTimeout)
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
        if result != 0 {
            let connectErrno = errno
            Darwin.close(fd)
            throw connectError(errorNumber: connectErrno, path: path)
        }
        return fd
    }

    private static func connectError(errorNumber: Int32, path: String) -> CLIError {
        switch errorNumber {
        case ENOENT, ECONNREFUSED:
            return CLIError("DanTerm is not running")
        case EACCES, EPERM:
            return CLIError("cannot access control socket (sandbox or permissions): \(path)")
        default:
            let reason = String(cString: strerror(errorNumber))
            return CLIError("cannot connect to control socket (\(reason)): \(path)")
        }
    }

    private static func configureSocket(_ fd: Int32, receiveTimeout: Bool) throws {
        try setNoSigPipe(fd)
        if receiveTimeout {
            try setSocketTimeout(fd, option: SO_RCVTIMEO)
        }
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
        case .tapeStream:
            // A stream is rendered record by record before any single result exists, so
            // `main` routes it away from here. Stated rather than defaulted, so adding a
            // mode is a compile error instead of a silent no-op.
            throw CLIError("pane tape is rendered as a record stream, not a single result")
        }
    }

    private static func compactJson(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "null"
    }

}

/// Selects an explicit owner or the external-process fallback without crossing instances.
func selectControlSocketPath(
    explicit: String?,
    environment: [String: String],
    fallback: String
) throws -> String {
    func nonEmptyValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    if let explicit = nonEmptyValue(explicit) {
        return explicit
    }
    if let explicit = nonEmptyValue(environment[EnvVars.sock]) {
        return explicit
    }
    if nonEmptyValue(environment[EnvVars.flag]) != nil {
        throw CLIError("DanTerm is not running")
    }
    return fallback
}

DanTermCLI.main()
