// CLI argument parser for `danterm tab new`. Holds only the flags unique to this
// command -- `--group` and the position flags; the launch and focus flags come
// from `NewCommandFlags`.
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

public func parseTabNewArgs(_ args: [String]) throws -> ParsedTabNew {
    var flags = NewCommandFlags()
    var group: String?
    var position: ParsedTabPosition?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--group":
            group = try newCommandFlagValue(after: arg, in: args, at: i)
            i += 2
        case "--after-selected":
            try setPosition(.afterSelected, into: &position)
            i += 1
        case "--at-group-end":
            try setPosition(.atGroupEnd, into: &position)
            i += 1
        case "--after-tab":
            // Read the id before the conflict check, so a bare trailing
            // `--after-tab` names the value it is missing.
            let id = try newCommandFlagValue(after: arg, in: args, at: i)
            try setPosition(.afterTab(id), into: &position)
            i += 2
        default:
            i = try flags.consume(args, at: i)
        }
    }

    return ParsedTabNew(
        group: group,
        launch: flags.launch,
        background: flags.background,
        foreground: flags.foreground,
        position: position
    )
}

/// Fills the single position slot, rejecting a second position flag even when it
/// repeats the first. Unlike the focus flags, position tolerates no repetition.
private func setPosition(_ newPosition: ParsedTabPosition, into position: inout ParsedTabPosition?) throws {
    guard position == nil else {
        throw NewCommandParseError.conflictingPositionFlags
    }
    position = newPosition
}
