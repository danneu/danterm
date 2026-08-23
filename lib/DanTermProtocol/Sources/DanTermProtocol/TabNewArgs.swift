// CLI argument parser for the tail of `danterm tab new`, after the shared target
// step has taken the anchor (`--group` or `--after-tab`). Holds only the flags
// unique to this command -- the position flags; the launch and focus flags come
// from `NewCommandFlags`. The usage line lives here too, next to the flags it
// documents. Parse failures read the command catalog's canonical usage.
import Foundation

let tabNewUsage = CLICommandCatalog.entry(for: .tabNew).usage

/// Where a new tab lands inside the group that anchors it. `--after-tab` is not
/// a position: it names the anchor itself, and the shared target step reads it.
public enum ParsedTabPosition: Equatable {
    case afterSelected
    case atGroupEnd
}

/// The message every way of naming two positions at once reports. The
/// `--after-tab` half is raised by `CLIParser`, which owns the anchor.
let tabNewPositionConflict = "--after-selected, --at-group-end, and --after-tab are mutually exclusive\n\(tabNewUsage)"

public struct ParsedTabNew: Equatable {
    public let launch: LaunchSpec?
    public let background: Bool
    /// Records that `--foreground` was typed so CLI policy can invert its
    /// background default without making this arg parser infer that policy.
    public let foreground: Bool
    public let position: ParsedTabPosition?

    public init(
        launch: LaunchSpec?,
        background: Bool = false,
        foreground: Bool = false,
        position: ParsedTabPosition? = nil
    ) {
        self.launch = launch
        self.background = background
        self.foreground = foreground
        self.position = position
    }
}

public func parseTabNewArgs(_ args: [String]) throws -> ParsedTabNew {
    var flags = NewCommandFlags(usage: tabNewUsage)
    var position: ParsedTabPosition?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--after-selected":
            try setPosition(.afterSelected, into: &position)
            i += 1
        case "--at-group-end":
            try setPosition(.atGroupEnd, into: &position)
            i += 1
        default:
            i = try flags.consume(args, at: i)
        }
    }

    return ParsedTabNew(
        launch: flags.launch,
        background: flags.background,
        foreground: flags.foreground,
        position: position
    )
}

/// Fills the single position slot, rejecting a second position flag even when it
/// repeats the first. Unlike the focus flags, position tolerates no repetition.
private func setPosition(_ newPosition: ParsedTabPosition, into position: inout ParsedTabPosition?) throws {
    guard position == nil else { throw CLIParseError(tabNewPositionConflict) }
    position = newPosition
}
