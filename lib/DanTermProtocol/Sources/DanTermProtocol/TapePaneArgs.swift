// CLI argument parser for the explicitly addressed `danterm pane tape` capture command.
import Foundation

/// Keeps pane-tape targeting independent from the broader command parser.
public struct ParsedTapePane: Equatable {
    public let pane: String
    public let follow: Bool
    public let fromNow: Bool

    public init(pane: String, follow: Bool = false, fromNow: Bool = false) {
        self.pane = pane
        self.follow = follow
        self.fromNow = fromNow
    }
}

/// Distinguishes usage errors so the CLI can retain precise diagnostics.
public enum TapePaneParseError: Error, Equatable {
    case missingPane
    case missingPaneArg
    case fromNowRequiresFollow
    case unknownFlag(String)
    case unexpectedArgument(String)
}

/// Parses exactly one explicit pane target without consulting ambient shell context.
public func parseTapePaneArgs(_ args: [String]) throws -> ParsedTapePane {
    var pane: String?
    var follow = false
    var fromNow = false
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
    return ParsedTapePane(pane: pane, follow: follow, fromNow: fromNow)
}
