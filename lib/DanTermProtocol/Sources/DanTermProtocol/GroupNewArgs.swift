// CLI argument parser for `danterm group new`. Holds only the grammar; the
// background default and the cwd fallback are CLI policy and live in CLIParser.
import Foundation

/// Carries the parsed flags of `group new`. Separate from `ParsedTabNew` because
/// `group new` has no target and no position: a group anchors to nothing.
public struct ParsedGroupNew: Equatable {
    public let name: String?
    public let launch: LaunchSpec?
    /// Records that `--foreground` was typed so CLI policy can invert its
    /// background default without making this arg parser infer that policy.
    public let foreground: Bool

    public init(name: String?, launch: LaunchSpec?, foreground: Bool = false) {
        self.name = name
        self.launch = launch
        self.foreground = foreground
    }
}

public enum GroupNewParseError: Error, Equatable {
    case missingValue(String)
    case unknownFlag(String)
    case unexpectedArgument(String)
    case conflictingFocusFlags
}

public func parseGroupNewArgs(_ args: [String]) throws -> ParsedGroupNew {
    var name: String?
    var cmd: String?
    var cwd: String?
    var title: String?
    var background = false
    var foreground = false
    var index = 0

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--name":
            name = try groupNewValue(after: arg, in: args, at: index)
            index += 2
        case "--cmd":
            cmd = try groupNewValue(after: arg, in: args, at: index)
            index += 2
        case "--cwd":
            cwd = try groupNewValue(after: arg, in: args, at: index)
            index += 2
        case "--title":
            title = try groupNewValue(after: arg, in: args, at: index)
            index += 2
        case "--background":
            guard foreground == false else { throw GroupNewParseError.conflictingFocusFlags }
            background = true
            index += 1
        case "--foreground":
            guard background == false else { throw GroupNewParseError.conflictingFocusFlags }
            foreground = true
            index += 1
        default:
            if arg.hasPrefix("-") {
                throw GroupNewParseError.unknownFlag(arg)
            }
            throw GroupNewParseError.unexpectedArgument(arg)
        }
    }

    let spec = LaunchSpec(cmd: cmd, cwd: cwd, title: title)
    return ParsedGroupNew(
        name: name,
        launch: spec.isEmpty ? nil : spec,
        foreground: foreground
    )
}

private func groupNewValue(after flag: String, in args: [String], at index: Int) throws -> String {
    guard index + 1 < args.count else {
        throw GroupNewParseError.missingValue(flag)
    }
    return args[index + 1]
}
