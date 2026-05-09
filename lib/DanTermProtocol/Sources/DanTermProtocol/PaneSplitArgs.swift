// CLI argument parser for `danterm pane split`.
import Foundation

public enum PaneSplitDirection: Equatable {
    case horizontal
    case vertical
}

public struct ParsedPaneSplit: Equatable {
    public let pane: String?
    public let direction: PaneSplitDirection

    public init(pane: String?, direction: PaneSplitDirection) {
        self.pane = pane
        self.direction = direction
    }
}

public enum PaneSplitParseError: Error, Equatable {
    case missingDirection
    case missingPaneArg
    case unknownFlag(String)
    case unexpectedArgument(String)
}

public func parsePaneSplitArgs(_ args: [String]) throws -> ParsedPaneSplit {
    var pane: String?
    var direction: PaneSplitDirection?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--pane":
            guard i + 1 < args.count else {
                throw PaneSplitParseError.missingPaneArg
            }
            pane = args[i + 1]
            i += 2
        case "-h":
            guard direction == nil else {
                throw PaneSplitParseError.unexpectedArgument(arg)
            }
            direction = .horizontal
            i += 1
        case "-v":
            guard direction == nil else {
                throw PaneSplitParseError.unexpectedArgument(arg)
            }
            direction = .vertical
            i += 1
        default:
            if arg.hasPrefix("-") {
                throw PaneSplitParseError.unknownFlag(arg)
            }
            throw PaneSplitParseError.unexpectedArgument(arg)
        }
    }

    guard let direction else {
        throw PaneSplitParseError.missingDirection
    }
    return ParsedPaneSplit(pane: pane, direction: direction)
}
