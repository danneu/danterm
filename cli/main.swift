// Local utility commands and the command-line client for DanTerm's JSON-RPC transports.
//
// The conversation itself -- connecting, framing, the hello handshake, correlating a
// reply -- belongs to DanTermClient. What stays here is the part that is genuinely the
// CLI's: which target to use, and how each failure is worded for a person reading a
// terminal. Do not grow a second transport in this file.
import Foundation
import DanTermClient
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

    // Top-level help text. Kept in sync by hand with `parseCLI` and the `EnvVars`
    // constants read by `selectConnectionTarget(...)` -- there is no automated check,
    // so any change to either touches this string too.
    private static let usageText: String = """
        danterm -- control DanTerm from the shell

        Usage:
          danterm [--socket <path> | --tcp <host:port>] <command> [args]

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
          pane tape --pane <pane-id> [--follow]
                    [--from-now | --from-cursor <cursor-json>]
                    [--raw | --reconstructible] [--format replay|inspect]
                                      Print or follow the pane's flight recording.
                                      Follows and resumes reconstruct exact state;
                                      finite beginning dumps default to raw evidence.
                                      --format inspect replaces each payload with
                                      readable spans; replay (the default) keeps
                                      the exact bytes.
          pane snapshot --pane <pane-id>
                                      Print one exact pane-state sync as JSON Lines
          theme set --pane <pane-id> <name>|--clear
                                      Set or clear a pane theme
          agent attach --pane <pane-id> --kind <kind> --id <session-id>
                                      Attach the caller's root agent session
          agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>
                                      Report explicit root-agent activity
          agent detach --pane <pane-id> --kind <kind> --id <session-id>
                                      Detach the matching root agent session
          quit                        Ask the explicitly targeted instance to quit.
                                      TCP peers are refused by the server.
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
          --tcp explicitly targets one tailnet listener. It cannot be combined
          with --socket and has no environment-variable form.
          tab new opens in the background at the target group end by default.
          Position flags change placement; --foreground selects the new tab.
          group new opens in the background too; --foreground selects its tab.
          group close refuses the last group, and refuses to close the group
          holding every tab unless --move-tabs keeps those tabs.
          pane split opens in the background by default; --foreground focuses
          the new pane within its tab. App UI shortcuts are unaffected.
          quit requires --socket or --tcp: it never takes its target from
          DANTERM_SOCK or identity lookup. The app authorizes the request.

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
            let target = try selectConnectionTarget(
                explicit: invocation.target,
                environment: environment,
                fallback: controlSocketPath().path,
                method: command.request.method
            )
            // Every tape capture is a record stream, finite or followed alike, so none of them
            // go through the single-result request path below.
            if case .tapeStream(let format) = command.outputMode {
                signal(SIGPIPE, SIG_IGN)
                try requestPaneTape(command, target: target, format: format)
                exit(0)
            }
            // A nil reply means the app closed the connection and the method
            // expected that -- a quit it honored exits before it can answer.
            if let response = try request(command, target: target) {
                if let error = response.error {
                    throw CLIError(error.message)
                }
                try printResult(response.result ?? .null, mode: command.outputMode)
            }
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

    /// Sends one command and resolves its reply, or nil when the app exited
    /// under the request because that is what the request asked for.
    private static func request(
        _ command: CLICommand,
        target: CLIResolvedTarget
    ) throws -> JsonRpcResponse? {
        let session = try openSession(target: target, receiveTimeout: true)
        defer { session.close() }

        let (requestId, request) = makeRequest(command)
        let reply = try reporting {
            try session.send(request)
            return try session.awaitReply(id: .string(requestId))
        }
        return try resolveReply(reply, method: command.request.method)
    }

    /// Renders one tape capture to stdout. The connection carries no receive timeout: a
    /// followed stream is idle whenever its pane is, and a finite dump's records arrive at
    /// the app's pace, so a timeout here would cut a healthy capture short.
    private static func requestPaneTape(
        _ command: CLICommand,
        target: CLIResolvedTarget,
        format: PaneTapeFormat
    ) throws {
        let session = try openSession(target: target, receiveTimeout: false)
        defer { session.close() }

        let (requestId, request) = makeRequest(command)
        let outcome = try reporting {
            try session.send(request)
            return try renderPaneTapeStream(
                session: session,
                output: STDOUT_FILENO,
                requestId: requestId,
                transform: format == .inspect ? paneTapeInspectRecord : { $0 }
            )
        }
        if let failure = paneTapeStreamFailure(for: outcome) {
            throw failure
        }
    }

    /// Connects and completes the handshake, so no caller sends a request to a peer whose
    /// protocol version it has not agreed with.
    private static func openSession(
        target: CLIResolvedTarget,
        receiveTimeout: Bool
    ) throws -> DanTermClientSession {
        let transport: any DanTermClientTransport = try reporting {
            switch target {
            case .unixSocket(let path):
                return try UnixSocketTransport(
                    path: path,
                    receiveTimeout: receiveTimeout ? Double(socketTimeoutSeconds) : nil,
                    sendTimeout: Double(socketTimeoutSeconds)
                )
            case .tcp(let host, let port):
                return try TCPSocketTransport(
                    host: host,
                    port: port,
                    connectTimeout: Double(socketTimeoutSeconds),
                    receiveTimeout: receiveTimeout ? Double(socketTimeoutSeconds) : nil,
                    sendTimeout: Double(socketTimeoutSeconds)
                )
            }
        }
        let session = DanTermClientSession(transport: transport)
        do {
            try session.handshake()
        } catch {
            session.close()
            throw cliError(error)
        }
        return session
    }

    /// Runs one step of the conversation and words any failure the way this CLI words it.
    private static func reporting<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as UnixSocketTransportError {
            throw cliError(error)
        } catch let error as TCPSocketTransportError {
            throw cliError(error)
        } catch let error as DanTermClientError {
            throw cliError(error)
        }
    }

    /// Translates a client-module failure into the sentence a person sees.
    ///
    /// The wording lives here rather than in the module because it is this CLI's contract
    /// with its callers, and because a phone client showing "DanTerm is not running" would
    /// be saying something different from what it means.
    private static func cliError(_ error: Error) -> Error {
        switch error {
        case UnixSocketTransportError.unreachable:
            return CLIError("DanTerm is not running")
        case UnixSocketTransportError.accessDenied(let path):
            return CLIError("cannot access control socket (sandbox or permissions): \(path)")
        case UnixSocketTransportError.connectFailed(let reason, let path):
            return CLIError("cannot connect to control socket (\(reason)): \(path)")
        case UnixSocketTransportError.pathTooLong:
            return CLIError("socket path is too long")
        case UnixSocketTransportError.createFailed:
            return CLIError("failed to create socket")
        case UnixSocketTransportError.configureFailed:
            return CLIError("failed to configure socket")
        case UnixSocketTransportError.configureTimeoutFailed:
            return CLIError("failed to configure socket timeout")
        case UnixSocketTransportError.timedOut:
            return CLIError("DanTerm is not responding")
        case UnixSocketTransportError.readFailed:
            return CLIError("failed to read from DanTerm")
        case UnixSocketTransportError.writeFailed:
            return CLIError("failed to write to DanTerm")
        case UnixSocketTransportError.peerClosed,
             TCPSocketTransportError.peerClosed,
             DanTermClientError.closedBeforeHello:
            return CLIError("DanTerm closed the connection")
        case TCPSocketTransportError.unresolvedHost(let host):
            return CLIError("cannot resolve TCP target: \(host)")
        case TCPSocketTransportError.connectFailed(let reason, let target):
            return CLIError("cannot connect to DanTerm over TCP (\(reason)): \(target)")
        case TCPSocketTransportError.connectTimedOut(let target):
            return CLIError("timed out connecting to DanTerm over TCP: \(target)")
        case TCPSocketTransportError.configureFailed:
            return CLIError("failed to configure TCP connection")
        case TCPSocketTransportError.configureTimeoutFailed:
            return CLIError("failed to configure TCP timeout")
        case TCPSocketTransportError.timedOut:
            return CLIError("DanTerm is not responding")
        case TCPSocketTransportError.readFailed:
            return CLIError("failed to read from DanTerm")
        case TCPSocketTransportError.writeFailed:
            return CLIError("failed to write to DanTerm")
        case DanTermClientError.invalidHello:
            return CLIError("invalid hello from DanTerm")
        case DanTermClientError.notAdmitted:
            return CLIError("DanTerm refused this device: not admitted")
        case DanTermClientError.identityUnresolved:
            return CLIError("DanTerm could not resolve this device's tailnet identity")
        case DanTermClientError.connectionLimit:
            return CLIError("DanTerm refused the connection: connection limit reached")
        case DanTermClientError.auditUnavailable:
            return CLIError("DanTerm refused the connection: audit unavailable")
        case DanTermClientError.unsupportedProtocol(let version):
            return CLIError("unsupported DanTerm IPC protocol \(version)")
        case DanTermClientError.oversizedLine:
            return CLIError("response line too large")
        case DanTermClientError.peerSilent:
            return CLIError("DanTerm stopped responding: no data within the liveness bound")
        default:
            return error
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
        guard let target = try? selectConnectionTarget(
            explicit: nil,
            environment: environment,
            fallback: controlSocketPath().path,
            method: .doctorPermissions
        ) else { return .unavailable }
        let command = CLICommand(request: .doctorPermissions, outputMode: .none)
        let reply = try? request(command, target: target)
        guard let response = reply ?? nil,
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

/// Decides what a missing reply means for the method that asked for it.
///
/// The session reports "the app closed the stream before replying" as nil and leaves the
/// judgement here, because only the CLI knows the verb. That is a failure for an ordinary
/// method, and the expected success for a method that ends the instance: a quit that
/// worked takes the socket down with the app, so only an explicit error reply means it did
/// not happen.
func resolveReply(_ reply: JsonRpcResponse?, method: IpcRequestMethod) throws -> JsonRpcResponse? {
    if let reply { return reply }
    guard method.terminatesInstance else {
        throw CLIError("DanTerm closed the connection")
    }
    return nil
}

/// Holds the endpoint choice after ambient local-socket resolution is complete.
enum CLIResolvedTarget: Equatable {
    case unixSocket(path: String)
    case tcp(host: String, port: UInt16)
}

/// Selects the explicit network target or resolves the local control socket fallback.
func selectConnectionTarget(
    explicit: CLIConnectionTarget?,
    environment: [String: String],
    fallback: String,
    method: IpcRequestMethod
) throws -> CLIResolvedTarget {
    func nonEmptyValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    if method.terminatesInstance {
        guard let explicit else {
            throw CLIError("\(method.rawValue) requires an explicit --socket <path> or --tcp <host:port>")
        }
        return CLIResolvedTarget(explicit)
    }
    if let explicit {
        return CLIResolvedTarget(explicit)
    }
    if let explicit = nonEmptyValue(environment[EnvVars.sock]) {
        return .unixSocket(path: explicit)
    }
    if nonEmptyValue(environment[EnvVars.flag]) != nil {
        throw CLIError("DanTerm is not running")
    }
    return .unixSocket(path: fallback)
}

private extension CLIResolvedTarget {
    init(_ target: CLIConnectionTarget) {
        switch target {
        case .unixSocket(let path): self = .unixSocket(path: path)
        case .tcp(let host, let port): self = .tcp(host: host, port: port)
        }
    }
}

DanTermCLI.main()
