// Public parser for the `danterm` command-line command surface.
import Foundation

public enum CLIOutputMode: Equatable {
    case none
    case json
    case text
    /// A record stream rather than a single result: the CLI writes each record as its own
    /// line as it arrives, in the named format. The format is a client-side rendering choice
    /// and is not part of the request.
    case tapeStream(PaneTapeFormat)
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
public enum CLIConnectionTarget: Equatable, Sendable {
    /// Names one local AF_UNIX control socket.
    case unixSocket(path: String)
    /// Names one remote listener without adding target data to the request.
    case tcp(host: String, port: UInt16)
}

/// Keeps process-local targeting separate from the JSON-RPC command so an
/// explicit instance choice can never leak into method parameters.
public struct CLIInvocation: Equatable {
    public let target: CLIConnectionTarget?
    public let command: CLICommand

    public init(target: CLIConnectionTarget?, command: CLICommand) {
        self.target = target
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
    var target: CLIConnectionTarget?
    var sawSocket = false
    var sawTCP = false

    while let option = remaining.first, option == "--socket" || option == "--tcp" {
        switch option {
        case "--socket":
            guard remaining.count >= 2 else {
                throw CLIParseError("usage: danterm --socket <path> <command> [args]")
            }
            guard sawSocket == false else {
                throw CLIParseError("--socket may be specified only once")
            }
            guard sawTCP == false else {
                throw CLIParseError("--socket and --tcp are mutually exclusive")
            }
            let candidate = remaining[1]
            guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIParseError("--socket requires a non-empty path")
            }
            target = .unixSocket(path: candidate)
            sawSocket = true
        case "--tcp":
            guard remaining.count >= 2 else {
                throw CLIParseError("usage: danterm --tcp <host:port> <command> [args]")
            }
            guard sawTCP == false else {
                throw CLIParseError("--tcp may be specified only once")
            }
            guard sawSocket == false else {
                throw CLIParseError("--socket and --tcp are mutually exclusive")
            }
            let candidate = remaining[1]
            guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIParseError("--tcp requires a non-empty host:port")
            }
            target = try parseTCPConnectionTarget(candidate)
            sawTCP = true
        default:
            preconditionFailure("prefix loop admitted an unknown option")
        }
        remaining.removeFirst(2)
    }

    return CLIInvocation(
        target: target,
        command: try parseCLI(remaining, currentDirectory: currentDirectory)
    )
}

/// Turns the one TCP flag value into a typed target before any connection is attempted.
private func parseTCPConnectionTarget(_ value: String) throws -> CLIConnectionTarget {
    let host: String
    let portText: String
    if value.first == "[", let closingBracket = value.firstIndex(of: "]") {
        let colon = value.index(after: closingBracket)
        guard colon < value.endIndex, value[colon] == ":" else {
            throw CLIParseError("--tcp requires host:port")
        }
        host = String(value[value.index(after: value.startIndex)..<closingBracket])
        portText = String(value[value.index(after: colon)...])
    } else {
        guard let colon = value.lastIndex(of: ":") else {
            throw CLIParseError("--tcp requires host:port")
        }
        host = String(value[..<colon])
        portText = String(value[value.index(after: colon)...])
    }
    guard host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          portText.isEmpty == false
    else { throw CLIParseError("--tcp requires host:port") }
    guard let port = UInt16(portText), port > 0 else {
        throw CLIParseError("--tcp port must be between 1 and 65535")
    }
    return .tcp(host: host, port: port)
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

    case "tailnet":
        guard args.count == 2, args[1] == "status" else {
            throw CLIParseError("usage: danterm tailnet status")
        }
        return CLICommand(request: .tailnetStatus, outputMode: .json)

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
            throw CLIParseError(
                "usage: danterm pane <focus|info|split|close|input|read|rows|zoom|resize|tape|snapshot>"
            )
        }
        switch args[1] {
        case "focus":
            return try parsePaneFocusCommand(Array(args.dropFirst(2)))
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
        case "resize":
            return try parsePaneResizeCommand(Array(args.dropFirst(2)))
        case "tape":
            return try parsePaneTapeCommand(Array(args.dropFirst(2)))
        case "snapshot":
            return try parsePaneSnapshotCommand(Array(args.dropFirst(2)))
        default:
            throw CLIParseError("unknown pane command")
        }

    case "theme":
        guard args.count >= 2, args[1] == "set" else {
            throw CLIParseError(themeSetUsage)
        }
        return try parseThemeSetCommand(Array(args.dropFirst(2)))

    case "agent":
        guard args.count >= 2 else {
            throw CLIParseError(agentSubcommandUsage)
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
            throw CLIParseError(agentSubcommandUsage)
        }

    case "todo":
        return try parseTodo(Array(args.dropFirst()))

    default:
        throw CLIParseError("unknown command: \(head)")
    }
}

private func parseTabNewCommand(_ args: [String], currentDirectory: String) throws -> CLICommand {
    let anchor = try parseCLITarget(args, accepting: [.group, .afterTab], usage: tabNewUsage)
    let parsed = try parseTabNewArgs(anchor.rest)

    let launch = LaunchSpec(
        cmd: parsed.launch?.cmd,
        cwd: parsed.launch?.cwd ?? currentDirectory,
        title: parsed.launch?.title
    )
    let target: IpcTabTarget
    switch anchor.kind {
    case .afterTab:
        // An anchoring tab already fixes the position, so a position flag beside
        // it names a second one.
        guard parsed.position == nil else { throw CLIParseError(tabNewPositionConflict) }
        target = .afterTab(try parseTabId(anchor.rawId))
    case .group:
        target = .group(
            try parseGroupId(anchor.rawId),
            position: parsed.position == .afterSelected ? .afterSelected : .atGroupEnd
        )
    case .pane, .tab:
        preconditionFailure("tab new accepts only a group or an anchoring tab")
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
    let parsed = try parseGroupNewArgs(args)
    guard let name = parsed.name, name.isEmpty == false else { throw CLIParseError(groupNewUsage) }
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
    let usage = "usage: danterm group rename --group <group-id> <name>"
    let (group, remaining) = try parseGroupTarget(args, usage: usage)
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
    let (group, remaining) = try parseGroupTarget(args, usage: usage)
    var moveTabs = false
    for argument in remaining {
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
    let usage = "usage: danterm tab rename --tab <tab-id> <name>|--clear"
    let (tab, remaining) = try parseTabTarget(args, usage: usage)
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
    let (tab, remaining) = try parseTabTarget(args, usage: "usage: danterm tab close --tab <tab-id>")
    try rejectTrailingArguments(remaining)
    return CLICommand(request: .tabClose(tab: tab), outputMode: .none)
}

private func parsePaneFocusCommand(_ args: [String]) throws -> CLICommand {
    let (pane, remaining) = try parsePaneTarget(
        args, usage: "usage: danterm pane focus --pane <pane-id>")
    try rejectTrailingArguments(remaining)
    return CLICommand(request: .paneFocus(pane: pane), outputMode: .none)
}

private func parsePaneInfoCommand(_ args: [String]) throws -> CLICommand {
    let (pane, remaining) = try parsePaneTarget(args, usage: "usage: danterm pane info --pane <pane-id>")
    try rejectTrailingArguments(remaining)
    return CLICommand(request: .paneInfo(pane: pane), outputMode: .json)
}

private func parsePaneSplitCommand(_ args: [String]) throws -> CLICommand {
    let parsedTarget = try parseCLITarget(args, accepting: [.pane, .tab], usage: paneSplitUsage)
    let parsed = try parsePaneSplitArgs(parsedTarget.rest)
    let target: IpcPaneSplitTarget
    switch parsedTarget.kind {
    case .pane:
        guard let direction = parsed.direction else { throw CLIParseError(paneSplitUsage) }
        target = .pane(try parsePaneId(parsedTarget.rawId), direction: direction)
    case .tab:
        guard parsed.direction == nil else { throw CLIParseError(paneSplitUsage) }
        target = .tab(try parseTabId(parsedTarget.rawId))
    case .group, .afterTab:
        preconditionFailure("target parser returned a kind pane split does not accept")
    }
    return CLICommand(
        request: .paneSplit(
            target: target,
            launch: parsed.launch,
            background: parsed.foreground == false
        ),
        outputMode: .json
    )
}

/// Keeps destructive pane closure explicit at parse time before any request is sent.
private func parsePaneCloseCommand(_ args: [String]) throws -> CLICommand {
    let (pane, remaining) = try parsePaneTarget(args, usage: "usage: danterm pane close --pane <pane-id>")
    try rejectTrailingArguments(remaining)
    return CLICommand(request: .paneClose(pane: pane), outputMode: .none)
}

/// The one `pane input` usage line, reported both by the shared target step and
/// by the tail parser when no tokens ever reach the `--` separator.
let paneInputUsage = "usage: danterm pane input --pane <pane-id> [--literal] -- <token>..."

private func parsePaneInputCommand(_ args: [String]) throws -> CLICommand {
    let (pane, remaining) = try parsePaneTarget(args, usage: paneInputUsage)
    let parsed: ParsedSendKeys
    do {
        parsed = try parseSendKeysArgs(remaining)
    } catch SendKeysParseError.unknownFlag(let flag) {
        throw CLIParseError("unknown flag: \(flag)")
    } catch SendKeysParseError.literalRequiresSeparator {
        throw CLIParseError("--literal requires -- before the tokens")
    } catch SendKeysParseError.missingArguments {
        throw CLIParseError(paneInputUsage)
    } catch SendKeysParseError.keyToken(.unknownKey(let token)) {
        throw CLIParseError("unknown key: \(token)")
    }

    return CLICommand(
        request: .paneInput(pane: pane, input: .events(parsed.events)),
        outputMode: .none
    )
}

/// The one `theme set` usage line, read both by this parser and by the command
/// dispatch above, which reports it when the `set` subcommand is missing.
let themeSetUsage = "usage: danterm theme set --pane <pane-id> <name>|--clear"

private func parseThemeSetCommand(_ args: [String]) throws -> CLICommand {
    let (pane, remaining) = try parsePaneTarget(args, usage: themeSetUsage)
    guard !remaining.isEmpty else {
        throw CLIParseError(themeSetUsage)
    }
    if remaining[0] == "--clear" {
        guard remaining.count == 1 else {
            throw CLIParseError(themeSetUsage)
        }
        return CLICommand(request: .themeSet(pane: pane, themeName: nil), outputMode: .none)
    }
    if remaining[0].hasPrefix("--") {
        throw CLIParseError("unknown flag: \(remaining[0])")
    }
    let name = remaining.joined(separator: " ")
    guard !name.isEmpty else {
        throw CLIParseError(themeSetUsage)
    }
    return CLICommand(request: .themeSet(pane: pane, themeName: name), outputMode: .none)
}

/// The one `pane read` usage line, reported by the shared target step.
let paneReadUsage = "usage: danterm pane read --pane <uuid> [--lines <n>]"

private func parsePaneReadCommand(_ args: [String]) throws -> CLICommand {
    let (pane, remaining) = try parsePaneTarget(args, usage: paneReadUsage)
    let parsed: ParsedReadPane
    do {
        parsed = try parseReadPaneArgs(remaining)
    } catch let error as ReadPaneParseError {
        switch error {
        case .missingLinesArg, .invalidLines(_):
            throw CLIParseError("--lines must be a positive integer")
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
        }
    }

    return CLICommand(
        request: .paneRead(pane: pane, lineLimit: parsed.lineLimit),
        outputMode: .text
    )
}

// The state is a positional word rather than a flag, and `toggle` is opt-in rather than the
// default: a script that can only toggle has to already know the current state, and the whole
// point of the command is to reach a known one.
private func parsePaneZoomCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane zoom --pane <pane-id> on|off|toggle"
    let (pane, remaining) = try parsePaneTarget(args, usage: usage)
    guard let word = remaining.first else { throw CLIParseError(usage) }
    guard let state = IpcPaneZoomState(rawValue: word) else {
        if word.hasPrefix("--") { throw CLIParseError("unknown flag: \(word)") }
        throw CLIParseError(usage)
    }
    try rejectTrailingArguments(Array(remaining.dropFirst()))
    return CLICommand(request: .paneZoom(pane: pane, state: state), outputMode: .json)
}

// The grid is a positional `<columns>x<rows>` word and `--fit` is its only
// alternative, so the two forms are mutually exclusive by grammar rather than by
// a check. Only the shape is parsed here: the accepted range belongs to the
// daemon, which is the one place that has to agree with the model.
private func parsePaneResizeCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm pane resize --pane <pane-id> <columns>x<rows>|--fit"
    let (pane, remaining) = try parsePaneTarget(args, usage: usage)
    var grid: (columns: Int, rows: Int)?
    var fit = false
    for argument in remaining {
        if argument == "--fit" {
            guard fit == false else { throw CLIParseError(usage) }
            fit = true
            continue
        }
        if argument.hasPrefix("--") {
            throw CLIParseError("unknown flag: \(argument)")
        }
        guard grid == nil, let parsed = parsePaneGridWord(argument) else {
            throw CLIParseError(usage)
        }
        grid = parsed
    }
    let resize: IpcPaneResize
    switch (grid, fit) {
    case (let grid?, false): resize = .grid(columns: grid.columns, rows: grid.rows)
    case (nil, true): resize = .fit
    default: throw CLIParseError(usage)
    }
    return CLICommand(request: .paneResize(pane: pane, resize: resize), outputMode: .json)
}

/// Reads the `<columns>x<rows>` word, rejecting every shape that is not two
/// positive decimal integers around a single `x`.
private func parsePaneGridWord(_ word: String) -> (columns: Int, rows: Int)? {
    let parts = word.split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let columns = Int(parts[0]), let rows = Int(parts[1]),
          columns > 0, rows > 0,
          parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
    else { return nil }
    return (columns, rows)
}

// `pane rows` reuses `pane read`'s argument grammar minus `--lines`: the projection is the
// whole stream by construction, so a tail limit would only hide the retained rows it exists
// to inspect.
private func parsePaneRowsCommand(_ args: [String]) throws -> CLICommand {
    let (pane, remaining) = try parsePaneTarget(args, usage: "usage: danterm pane rows --pane <pane-id>")
    try rejectTrailingArguments(remaining)
    return CLICommand(request: .paneRows(pane: pane), outputMode: .json)
}

private func parsePaneTapeCommand(_ args: [String]) throws -> CLICommand {
    let usage = """
        usage: danterm pane tape --pane <pane-id> [--follow] \
        [--from-now | --from-cursor <cursor-json>] [--raw | --reconstructible] \
        [--sync-history-bytes <n>] [--format replay|inspect]
        """
    let (pane, remaining) = try parsePaneTarget(args, usage: usage)
    let parsed: ParsedTapePane
    do {
        parsed = try parseTapePaneArgs(remaining)
    } catch let error as TapePaneParseError {
        switch error {
        case .conflictingStart:
            throw CLIParseError("choose only one tape start position\n\(usage)")
        case .missingCursorArg:
            throw CLIParseError("--from-cursor requires cursor JSON\n\(usage)")
        case .invalidCursor:
            throw CLIParseError("invalid tape cursor\n\(usage)")
        case .conflictingMode:
            throw CLIParseError("choose only one tape mode\n\(usage)")
        case .missingSyncHistoryBytesArg:
            throw CLIParseError("--sync-history-bytes requires a byte count\n\(usage)")
        case .invalidSyncHistoryBytes(let value):
            throw CLIParseError("invalid sync history bytes: \(value)\n\(usage)")
        case .syncHistoryBytesOnRawStream:
            throw CLIParseError(
                "--sync-history-bytes needs --reconstructible: a raw stream sends no sync\n\(usage)"
            )
        case .missingFormatArg:
            throw CLIParseError("--format requires replay or inspect\n\(usage)")
        case .invalidFormat(let value):
            throw CLIParseError("unknown format: \(value)\n\(usage)")
        case .unknownFlag(let flag):
            throw CLIParseError("unknown flag: \(flag)")
        case .unexpectedArgument(let argument):
            throw CLIParseError("unexpected argument: \(argument)")
        }
    }
    return CLICommand(
        request: .paneTape(
            pane: pane,
            follow: parsed.follow,
            start: parsed.start,
            policy: parsed.policy
        ),
        outputMode: .tapeStream(parsed.format)
    )
}

private func parsePaneSnapshotCommand(_ args: [String]) throws -> CLICommand {
    let (pane, remaining) = try parsePaneTarget(
        args, usage: "usage: danterm pane snapshot --pane <pane-id>")
    try rejectTrailingArguments(remaining)
    return CLICommand(request: .paneSnapshot(pane: pane), outputMode: .tapeStream(.replay))
}

/// The one `agent` subcommand usage line, reported both when the subcommand is
/// missing and when it is not one of the three this parser knows.
let agentSubcommandUsage = "usage: danterm agent <attach|activity|detach>"

private func parseAgentSessionCommand(
    _ args: [String],
    action: String,
    attach: Bool
) throws -> CLICommand {
    let usage = "usage: danterm agent \(action) --pane <pane-id> --kind <kind> --id <session-id>"
    let (pane, tail) = try parsePaneTarget(args, usage: usage)
    var remaining = tail
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
    let session = IpcAgentSession(kind: kind, id: sessionId)
    return CLICommand(
        request: attach
            ? .agentAttach(pane: pane, session: session)
            : .agentDetach(pane: pane, session: session),
        outputMode: .none
    )
}

private func parseAgentActivityCommand(_ args: [String]) throws -> CLICommand {
    let usage = "usage: danterm agent activity --pane <pane-id> --kind <kind> --id <session-id> --state <working|waiting|idle>"
    let (pane, tail) = try parsePaneTarget(args, usage: usage)
    var remaining = tail
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
    guard let activity = IpcAgentActivity(rawValue: state) else {
        throw CLIParseError("agent activity state must be working, waiting, or idle")
    }
    return CLICommand(
        request: .agentActivity(
            pane: pane,
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
        return try parseTodoIdCommand(
            { .todoSetDone(owner: $0, todoId: $1, isDone: true) },
            args: Array(args.dropFirst()),
            usage: "usage: danterm todo done \(ownerUsage) <todo-id>"
        )
    case "open":
        return try parseTodoIdCommand(
            { .todoSetDone(owner: $0, todoId: $1, isDone: false) },
            args: Array(args.dropFirst()),
            usage: "usage: danterm todo open \(ownerUsage) <todo-id>"
        )
    case "delete":
        return try parseTodoIdCommand(
            { .todoDelete(owner: $0, todoId: $1) },
            args: Array(args.dropFirst()),
            usage: "usage: danterm todo delete \(ownerUsage) <todo-id>"
        )
    case "clear-completed":
        let usage = "usage: danterm todo clear-completed \(ownerUsage)"
        let (owner, rest) = try parseTodoOwnerPrefix(Array(args.dropFirst()), usage: usage)
        guard rest.isEmpty else { throw CLIParseError(usage) }
        return CLICommand(request: .todoClearCompleted(owner: owner), outputMode: .none)
    default:
        throw CLIParseError("unknown todo command")
    }
}

/// Reads the todo owner, which is a pane or a tab. The shared target step picks
/// between the two forms, so this only turns the choice it made into a
/// `TodoOwner`.
private func parseTodoOwnerPrefix(_ args: [String], usage: String) throws -> (TodoOwner, [String]) {
    let parsed = try parseCLITarget(args, accepting: [.pane, .tab], usage: usage)
    let owner: TodoOwner
    switch parsed.kind {
    case .pane: owner = .pane(try parsePaneId(parsed.rawId))
    case .tab: owner = .tab(try parseTabId(parsed.rawId))
    case .group, .afterTab: preconditionFailure("a todo belongs to a pane or a tab")
    }
    return (owner, parsed.rest)
}

/// Parses the argument grammar shared by every todo verb that names one todo. The
/// caller supplies the constructor, so the request it wants is a value here rather
/// than a tag this function has to switch back into a case.
private func parseTodoIdCommand(
    _ makeRequest: (TodoOwner, TodoId) -> IpcRequest,
    args: [String],
    usage: String
) throws -> CLICommand {
    let (owner, rest) = try parseTodoOwnerPrefix(args, usage: usage)
    guard rest.count == 1, let rawTodoId = UUID(uuidString: rest[0]) else { throw CLIParseError(usage) }
    return CLICommand(request: makeRequest(owner, TodoId(rawValue: rawTodoId)), outputMode: .none)
}
