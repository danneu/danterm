// CLI argument parser for `danterm tab new`.
import Foundation

public struct ParsedTabNew: Equatable {
    public let group: String?
    public let launch: LaunchSpec?
    public let background: Bool

    public init(group: String?, launch: LaunchSpec?, background: Bool = false) {
        self.group = group
        self.launch = launch
        self.background = background
    }
}

public enum TabNewParseError: Error, Equatable {
    case missingValue(String)
    case unknownFlag(String)
    case unexpectedArgument(String)
}

public func parseTabNewArgs(_ args: [String]) throws -> ParsedTabNew {
    var group: String?
    var cmd: String?
    var cwd: String?
    var title: String?
    var background = false
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
            background = true
            i += 1
        default:
            if arg.hasPrefix("-") {
                throw TabNewParseError.unknownFlag(arg)
            }
            throw TabNewParseError.unexpectedArgument(arg)
        }
    }

    let spec = LaunchSpec(cmd: cmd, cwd: cwd, title: title)
    return ParsedTabNew(group: group, launch: spec.isEmpty ? nil : spec, background: background)
}

private func value(after flag: String, in args: [String], at index: Int) throws -> String {
    guard index + 1 < args.count else {
        throw TabNewParseError.missingValue(flag)
    }
    return args[index + 1]
}
