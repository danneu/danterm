// CLI argument parser for the explicitly addressed `danterm pane tape` capture command.
import Foundation

/// Keeps pane-tape targeting independent from the broader command parser.
public struct ParsedTapePane: Equatable {
    public let pane: String
    public let follow: Bool
    public let fromNow: Bool
    /// How the CLI renders each record. It never reaches DanTerm: the app records and sends
    /// exact bytes, and a readable view is derived from those bytes on this side.
    public let format: PaneTapeFormat

    public init(
        pane: String,
        follow: Bool = false,
        fromNow: Bool = false,
        format: PaneTapeFormat = .replay
    ) {
        self.pane = pane
        self.follow = follow
        self.fromNow = fromNow
        self.format = format
    }
}

/// Distinguishes usage errors so the CLI can retain precise diagnostics.
public enum TapePaneParseError: Error, Equatable {
    case missingPane
    case missingPaneArg
    case fromNowRequiresFollow
    case missingFormatArg
    case invalidFormat(String)
    case unknownFlag(String)
    case unexpectedArgument(String)
}

/// Parses exactly one explicit pane target without consulting ambient shell context.
public func parseTapePaneArgs(_ args: [String]) throws -> ParsedTapePane {
    var pane: String?
    var follow = false
    var fromNow = false
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
            fromNow = true
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
    guard fromNow == false || follow else {
        throw TapePaneParseError.fromNowRequiresFollow
    }
    return ParsedTapePane(pane: pane, follow: follow, fromNow: fromNow, format: format)
}
