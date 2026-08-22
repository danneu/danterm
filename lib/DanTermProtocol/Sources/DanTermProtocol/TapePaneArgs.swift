// CLI argument parser for the explicitly addressed `danterm pane tape` capture command.
import Foundation

/// The tail of `danterm pane tape`, after the shared target step has taken the
/// pane: the streaming options that shape the record stream.
public struct ParsedTapePane: Equatable {
    /// Keeps the stream open for appended recorder events.
    public let follow: Bool
    /// Selects the first recorder position the producer must account for.
    public let start: PaneTapeStartPosition
    /// Selects exact reconstruction or raw recorder evidence, and how much history a
    /// reconstruction carries.
    public let policy: PaneTapeSyncPolicy
    /// How the CLI renders each record. It never reaches DanTerm: the app records and sends
    /// exact bytes, and a readable view is derived from those bytes on this side.
    public let format: PaneTapeFormat

    /// Creates one validated pane-tape invocation for the broader CLI parser.
    public init(
        follow: Bool = false,
        start: PaneTapeStartPosition = .beginning,
        policy: PaneTapeSyncPolicy = .raw,
        format: PaneTapeFormat = .replay
    ) {
        self.follow = follow
        self.start = start
        self.policy = policy
        self.format = format
    }
}

/// Distinguishes usage errors so the CLI can retain precise diagnostics.
public enum TapePaneParseError: Error, Equatable {
    /// More than one explicit start position was supplied.
    case conflictingStart
    /// The cursor flag had no following JSON value.
    case missingCursorArg
    /// The supplied cursor JSON was malformed or outside the supported numeric domain.
    case invalidCursor
    /// More than one explicit stream mode was supplied.
    case conflictingMode
    /// The sync history budget flag had no following value.
    case missingSyncHistoryBytesArg
    /// The sync history budget was not a whole, non-negative byte count.
    case invalidSyncHistoryBytes(String)
    /// A raw stream emits no synchronization, so a history budget would bound nothing.
    case syncHistoryBytesOnRawStream
    /// The format flag had no following value.
    case missingFormatArg
    /// The format value does not name a supported renderer.
    case invalidFormat(String)
    /// The parser does not recognize the supplied flag.
    case unknownFlag(String)
    /// A positional value appeared where this command accepts only flags.
    case unexpectedArgument(String)
}

/// Parses the streaming options a pane-tape capture takes after its target.
public func parseTapePaneArgs(_ args: [String]) throws -> ParsedTapePane {
    var follow = false
    var start = PaneTapeStartPosition.beginning
    var hasExplicitStart = false
    var explicitMode: PaneTapeStreamMode?
    var syncHistoryBytes: Int?
    var format = PaneTapeFormat.replay
    var index = 0

    while index < args.count {
        let argument = args[index]
        switch argument {
        case "--follow":
            follow = true
            index += 1
        case "--from-now":
            guard hasExplicitStart == false else { throw TapePaneParseError.conflictingStart }
            start = .now
            hasExplicitStart = true
            index += 1
        case "--from-cursor":
            guard hasExplicitStart == false else { throw TapePaneParseError.conflictingStart }
            guard index + 1 < args.count else { throw TapePaneParseError.missingCursorArg }
            guard let data = args[index + 1].data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let cursor = decodePaneTapeCursor(value)
            else { throw TapePaneParseError.invalidCursor }
            start = .cursor(cursor)
            hasExplicitStart = true
            index += 2
        case "--raw", "--reconstructible":
            guard explicitMode == nil else { throw TapePaneParseError.conflictingMode }
            explicitMode = argument == "--raw" ? .raw : .reconstructible
            index += 1
        case "--sync-history-bytes":
            guard index + 1 < args.count else {
                throw TapePaneParseError.missingSyncHistoryBytesArg
            }
            guard let bytes = Int(args[index + 1]), bytes >= 0 else {
                throw TapePaneParseError.invalidSyncHistoryBytes(args[index + 1])
            }
            syncHistoryBytes = bytes
            index += 2
        case "--format":
            guard index + 1 < args.count else {
                throw TapePaneParseError.missingFormatArg
            }
            guard let parsed = PaneTapeFormat(rawValue: args[index + 1]) else {
                throw TapePaneParseError.invalidFormat(args[index + 1])
            }
            format = parsed
            index += 2
        default:
            if argument.hasPrefix("--") {
                throw TapePaneParseError.unknownFlag(argument)
            }
            throw TapePaneParseError.unexpectedArgument(argument)
        }
    }

    let mode = explicitMode ?? ((follow || hasExplicitStart) ? .reconstructible : .raw)
    let policy: PaneTapeSyncPolicy
    do {
        policy = try paneTapeSyncPolicy(mode: mode, requestedHistoryBudgetBytes: syncHistoryBytes)
    } catch let error {
        switch error {
        case .budgetOnRawStream:
            throw TapePaneParseError.syncHistoryBytesOnRawStream
        case .budgetNotWholeBytes:
            // The flag parser above already rejects this shape. Keep the translation
            // exhaustive so a policy error added later cannot silently share a message.
            throw TapePaneParseError.invalidSyncHistoryBytes(
                syncHistoryBytes.map(String.init) ?? ""
            )
        }
    }
    return ParsedTapePane(follow: follow, start: start, policy: policy, format: format)
}
