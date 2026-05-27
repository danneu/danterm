// CLI argument parser for `danterm tab new`.
import Foundation

public enum ParsedTabPosition: Equatable {
    case afterSelected
    case atGroupEnd
    case afterTab(String)
}

public struct ParsedTabNew: Equatable {
    public let group: String?
    public let launch: LaunchSpec?
    public let background: Bool
    /// Records that `--foreground` was typed so CLI policy can invert its
    /// background default without making this arg parser infer that policy.
    public let foreground: Bool
    public let position: ParsedTabPosition?

    public init(
        group: String?,
        launch: LaunchSpec?,
        background: Bool = false,
        foreground: Bool = false,
        position: ParsedTabPosition? = nil
    ) {
        self.group = group
        self.launch = launch
        self.background = background
        self.foreground = foreground
        self.position = position
    }
}

public enum TabNewParseError: Error, Equatable {
    case missingValue(String)
    case unknownFlag(String)
    case unexpectedArgument(String)
    case conflictingPositionFlags
    case conflictingFocusFlags
}

public func parseTabNewArgs(_ args: [String]) throws -> ParsedTabNew {
    var group: String?
    var cmd: String?
    var cwd: String?
    var title: String?
    var background = false
    var foreground = false
    var position: ParsedTabPosition?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--group":
            group = try value(after: arg, in: args, at: i)
            i += 2
        case "--cmd":
            cmd = try value(after: arg, in: args, at: i)
            i += 2
        case "--cwd":
            cwd = try value(after: arg, in: args, at: i)
            i += 2
        case "--title":
            title = try value(after: arg, in: args, at: i)
            i += 2
        case "--background":
            guard !foreground else {
                throw TabNewParseError.conflictingFocusFlags
            }
            background = true
            i += 1
        case "--foreground":
            guard !background else {
                throw TabNewParseError.conflictingFocusFlags
            }
            foreground = true
            i += 1
        case "--after-selected":
            try setPosition(.afterSelected, into: &position)
            i += 1
        case "--at-group-end":
            try setPosition(.atGroupEnd, into: &position)
            i += 1
        case "--after-tab":
            let id = try value(after: arg, in: args, at: i)
            try setPosition(.afterTab(id), into: &position)
            i += 2
        default:
            if arg.hasPrefix("-") {
                throw TabNewParseError.unknownFlag(arg)
            }
            throw TabNewParseError.unexpectedArgument(arg)
        }
    }

    let spec = LaunchSpec(cmd: cmd, cwd: cwd, title: title)
    return ParsedTabNew(
        group: group,
        launch: spec.isEmpty ? nil : spec,
        background: background,
        foreground: foreground,
        position: position
    )
}

private func value(after flag: String, in args: [String], at index: Int) throws -> String {
    guard index + 1 < args.count else {
        throw TabNewParseError.missingValue(flag)
    }
    return args[index + 1]
}

private func setPosition(_ newPosition: ParsedTabPosition, into position: inout ParsedTabPosition?) throws {
    guard position == nil else {
        throw TabNewParseError.conflictingPositionFlags
    }
    position = newPosition
}
