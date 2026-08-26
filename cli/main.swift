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
    // The surrounding policy stays authored here. The command section projects the
    // protocol catalog that also drives dispatch and parse-error usage.
    private static let usageText: String = """
        danterm -- control DanTerm from the shell

        Usage:
          danterm [--socket <path> | --tcp <host:port>] <command> [args]

        Commands:
        \(CLICommandCatalog.commandHelp)

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
          DANTERM_SOCKET_TIMEOUT
                         Seconds to wait on the control socket (default 5).
                         Must be a positive number; anything else is refused.

        """

    static func main() {
        do {
            let rawArgs = Array(CommandLine.arguments.dropFirst())
            if rawArgs.isEmpty {
                fputs(usageText, stderr)
                exit(1)
            }
            let routed = try routeCLIInvocation(rawArgs)
            switch routed.descriptor.route {
            case .help:
                guard routed.arguments.isEmpty else {
                    throw CLIParseError(routed.descriptor.usage)
                }
                print(usageText, terminator: "")
                exit(0)
            case .skill:
                try runSkill(routed.arguments)
                return
            case .doctor:
                try runDoctor(routed.arguments)
                return
            default:
                break
            }
            let command = try parseRoutedCLICommand(routed)
            let environment = ProcessInfo.processInfo.environment
            let socketTimeout = try selectSocketTimeout(environment: environment)
            let target = try selectConnectionTarget(
                explicit: routed.target,
                environment: environment,
                fallback: userControlSocketPath(identity: .production).path,
                method: command.request.method
            )
            // Every tape capture is a record stream, finite or followed alike, so none of them
            // go through the single-result request path below.
            if case .tapeStream(let format) = command.outputMode {
                signal(SIGPIPE, SIG_IGN)
                try requestPaneTape(
                    command,
                    target: target,
                    format: format,
                    socketTimeout: socketTimeout
                )
                exit(0)
            }
            // A nil reply means the app closed the connection and the method
            // expected that -- a quit it honored exits before it can answer.
            if let response = try request(command, target: target, socketTimeout: socketTimeout) {
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
        target: CLIConnectionTarget,
        socketTimeout: Double
    ) throws -> JsonRpcResponse? {
        let session = try openSession(
            target: target,
            receiveTimeout: true,
            socketTimeout: socketTimeout
        )
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
        target: CLIConnectionTarget,
        format: PaneTapeFormat,
        socketTimeout: Double
    ) throws {
        let session = try openSession(
            target: target,
            receiveTimeout: false,
            socketTimeout: socketTimeout
        )
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
        target: CLIConnectionTarget,
        receiveTimeout: Bool,
        socketTimeout: Double
    ) throws -> DanTermClientSession {
        let transport: any DanTermClientTransport = try reporting {
            switch target {
            case .unixSocket(let path):
                return try UnixSocketTransport(
                    path: path,
                    receiveTimeout: receiveTimeout ? socketTimeout : nil,
                    sendTimeout: socketTimeout
                )
            case .tcp(let host, let port):
                return try TCPSocketTransport(
                    host: host,
                    port: port,
                    connectTimeout: socketTimeout,
                    receiveTimeout: receiveTimeout ? socketTimeout : nil,
                    sendTimeout: socketTimeout
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

        // Resolved here, and not swallowed with the app query below, so a malformed
        // supplied timeout is reported by every command that would use one.
        let socketTimeout = try selectSocketTimeout(environment: ProcessInfo.processInfo.environment)
        // The CLI owns no launch-resolved paths, so this is where it names the ones its
        // doctor probes share: one home, and the standard config file under that home.
        // Deriving them apart is what let one run probe two homes.
        let home = danTermProcessHomeDirectory(environment: ProcessInfo.processInfo.environment)
        let checks = evaluateDoctor(gatherDoctorFacts(
            env: .live(
                home: home,
                configFilePath: DanTermConfigPaths.standardConfigFilePath(home: home.path)
            ),
            permissions: gatherDoctorPermissions(socketTimeout: socketTimeout)
        ))
        print(renderDoctorReport(checks), terminator: "")
        exit(doctorExitCode(for: checks))
    }

    /// Best-effort app query: local doctor checks remain useful when no instance is running.
    private static func gatherDoctorPermissions(socketTimeout: Double) -> DoctorFacts.Permissions {
        let environment = ProcessInfo.processInfo.environment
        guard let target = try? selectConnectionTarget(
            explicit: nil,
            environment: environment,
            fallback: userControlSocketPath(identity: .production).path,
            method: .doctorPermissions
        ) else { return .unavailable }
        let command = CLICommand(request: .doctorPermissions, outputMode: .none)
        let reply = try? request(command, target: target, socketTimeout: socketTimeout)
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

/// Resolves how long this run waits on its control socket, in seconds.
///
/// The value is an ordinary duration read from the environment, so a test's short value
/// and a user's long one are the same input: nothing downstream can tell them apart. An
/// unusable value is refused rather than replaced by the default, because a caller who
/// asked for a different timeout must not silently get this one.
///
/// The default lives in the body rather than in a top-level constant: `main.swift`'s
/// globals are initialized by running its top-level code, which the test target never
/// does, so a global here would read as zero from every test.
func selectSocketTimeout(environment: [String: String]) throws -> Double {
    let defaultSeconds = 5.0
    let raw = environment[EnvVars.socketTimeout]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if raw.isEmpty { return defaultSeconds }
    guard let seconds = Double(raw), seconds.isFinite, seconds > 0 else {
        throw CLIError("\(EnvVars.socketTimeout) must be a positive number of seconds: \(raw)")
    }
    return seconds
}

/// Selects the explicit network target or resolves the local control socket fallback.
func selectConnectionTarget(
    explicit: CLIConnectionTarget?,
    environment: [String: String],
    fallback: String,
    method: IpcRequestMethod
) throws -> CLIConnectionTarget {
    func nonEmptyValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    if method.terminatesInstance {
        guard let explicit else {
            throw CLIError("\(method.rawValue) requires an explicit --socket <path> or --tcp <host:port>")
        }
        return explicit
    }
    if let explicit {
        return explicit
    }
    if let explicit = nonEmptyValue(environment[EnvVars.sock]) {
        return .unixSocket(path: explicit)
    }
    if nonEmptyValue(environment[EnvVars.flag]) != nil {
        throw CLIError("DanTerm is not running")
    }
    return .unixSocket(path: fallback)
}

DanTermCLI.main()
