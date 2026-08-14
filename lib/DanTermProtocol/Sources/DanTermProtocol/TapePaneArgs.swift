// CLI argument parser for the explicitly addressed `danterm pane tape` capture command.
import Foundation

/// Keeps pane-tape targeting independent from the broader command parser.
public struct ParsedTapePane: Equatable {
    /// Names the required pane target exactly as the caller supplied it.
    public let pane: String
    /// Keeps the stream open for appended recorder events.
    public let follow: Bool
    /// Selects the first recorder position the producer must account for.
    public let start: PaneTapeStartPosition
    /// Selects exact reconstruction or raw recorder evidence.
    public let mode: PaneTapeStreamMode
    /// How the CLI renders each record. It never reaches DanTerm: the app records and sends
    /// exact bytes, and a readable view is derived from those bytes on this side.
    public let format: PaneTapeFormat

    /// Creates one validated pane-tape invocation for the broader CLI parser.
    public init(
        pane: String,
        follow: Bool = false,
        start: PaneTapeStartPosition = .beginning,
        mode: PaneTapeStreamMode = .raw,
        format: PaneTapeFormat = .replay
    ) {
        self.pane = pane
        self.follow = follow
        self.start = start
        self.mode = mode
        self.format = format
    }
}

/// Distinguishes usage errors so the CLI can retain precise diagnostics.
public enum TapePaneParseError: Error, Equatable {
    /// The required pane flag was not present.
    case missingPane
    /// The pane flag had no following value.
    case missingPaneArg
    /// More than one explicit start position was supplied.
    case conflictingStart
    /// The cursor flag had no following JSON value.
    case missingCursorArg
    /// The supplied cursor JSON was malformed or outside the supported numeric domain.
    case invalidCursor
    /// More than one explicit stream mode was supplied.
    case conflictingMode
    /// The format flag had no following value.
    case missingFormatArg
    /// The format value does not name a supported renderer.
    case invalidFormat(String)
    /// The parser does not recognize the supplied flag.
    case unknownFlag(String)
    /// A positional value appeared where this command accepts only flags.
    case unexpectedArgument(String)
}

/// Parses exactly one explicit pane target without consulting ambient shell context.
public func parseTapePaneArgs(_ args: [String]) throws -> ParsedTapePane {
    var pane: String?
    var follow = false
    var start = PaneTapeStartPosition.beginning
    var hasExplicitStart = false
    var explicitMode: PaneTapeStreamMode?
    var format = PaneTapeFormat.replay
    var index = 0

    while index < args.count {
        let argument = args[index]
        switch argument {
        case "--pane":
            guard index + 1 < args.count else {
                throw TapePaneParseError.missingPaneArg
            }
            pane = args[index + 1]
            index += 2
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

    guard let pane, pane.isEmpty == false else {
        throw TapePaneParseError.missingPane
    }
    let mode = explicitMode ?? ((follow || hasExplicitStart) ? .reconstructible : .raw)
    return ParsedTapePane(pane: pane, follow: follow, start: start, mode: mode, format: format)
}
