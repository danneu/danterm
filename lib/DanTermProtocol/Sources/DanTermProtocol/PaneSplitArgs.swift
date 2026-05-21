// CLI argument parser for `danterm pane split`.
import Foundation

public enum PaneSplitDirection: Equatable {
    case horizontal
    case vertical
}

public struct ParsedPaneSplit: Equatable {
    public let pane: String?
    public let direction: PaneSplitDirection
    public let launch: LaunchSpec?

    public init(pane: String?, direction: PaneSplitDirection, launch: LaunchSpec? = nil) {
        self.pane = pane
        self.direction = direction
        self.launch = launch
    }
}

public enum PaneSplitParseError: Error, Equatable {
    case missingDirection
    case missingPaneArg
    case missingValue(String)
    case unknownFlag(String)
    case unexpectedArgument(String)
}

public func parsePaneSplitArgs(_ args: [String]) throws -> ParsedPaneSplit {
    var pane: String?
    var direction: PaneSplitDirection?
    var cmd: String?
    var cwd: String?
    var title: String?
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
        case "--cmd":
            guard i + 1 < args.count else {
                throw PaneSplitParseError.missingValue(arg)
            }
            cmd = args[i + 1]
            i += 2
        case "--cwd":
            guard i + 1 < args.count else {
                throw PaneSplitParseError.missingValue(arg)
            }
            cwd = args[i + 1]
            i += 2
        case "--title":
            guard i + 1 < args.count else {
                throw PaneSplitParseError.missingValue(arg)
            }
            title = args[i + 1]
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
    let spec = LaunchSpec(cmd: cmd, cwd: cwd, title: title)
    return ParsedPaneSplit(pane: pane, direction: direction, launch: spec.isEmpty ? nil : spec)
}
