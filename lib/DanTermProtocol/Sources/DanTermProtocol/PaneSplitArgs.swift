// Parses the tail of `danterm pane split` after the shared target step has
// consumed its pane or tab. Target-dependent direction rules stay in
// CLIParser; this file owns the direction, launch, and focus flags.
import Foundation

/// The one `pane split` usage line, shared by target and tail parsing.
let paneSplitUsage = "usage: danterm pane split (--pane <pane-id> -h|-v | --tab <tab-id>) \(newCommandFlagsUsage)"

public enum PaneSplitDirection: Equatable, Sendable {
    case horizontal
    case vertical
}

/// Carries the split tail independently of whether the shared target was a
/// pane, which requires a direction, or a tab, which forbids one.
public struct ParsedPaneSplit: Equatable {
    public let direction: PaneSplitDirection?
    public let launch: LaunchSpec?
    public let background: Bool
    /// Records that `--foreground` was typed while leaving background-default
    /// policy to the command parser.
    public let foreground: Bool

    public init(
        direction: PaneSplitDirection? = nil,
        launch: LaunchSpec? = nil,
        background: Bool = false,
        foreground: Bool = false
    ) {
        self.direction = direction
        self.launch = launch
        self.background = background
        self.foreground = foreground
    }
}

/// Parses only the flags that follow a pane-split target.
public func parsePaneSplitArgs(_ args: [String]) throws -> ParsedPaneSplit {
    var flags = NewCommandFlags(usage: paneSplitUsage)
    var direction: PaneSplitDirection?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "-v":
            guard direction == nil else {
                throw CLIParseError("unexpected argument: \(arg)")
            }
            direction = arg == "-h" ? .horizontal : .vertical
            i += 1
        default:
            i = try flags.consume(args, at: i)
        }
    }

    return ParsedPaneSplit(
        direction: direction,
        launch: flags.launch,
        background: flags.background,
        foreground: flags.foreground
    )
}
