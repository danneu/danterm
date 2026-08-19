// CLI argument parser for `danterm pane split`. Holds only the flags unique to
// this command -- `--pane` and the `-h`/`-v` direction; the launch and focus
// flags come from `NewCommandFlags`. The usage line lives here too, next to the
// flags it documents.
import Foundation

/// The one `pane split` usage line, read both by this parser, which renders its
/// errors with it, and by `CLIParser`, whose post-parse guard reports it.
let paneSplitUsage = "usage: danterm pane split --pane <pane-id> -h|-v \(newCommandFlagsUsage)"

public enum PaneSplitDirection: Equatable, Sendable {
    case horizontal
    case vertical
}

public struct ParsedPaneSplit: Equatable {
    public let pane: String?
    public let direction: PaneSplitDirection
    public let launch: LaunchSpec?
    public let background: Bool
    /// Records that `--foreground` was typed while leaving background-default
    /// policy to the command parser.
    public let foreground: Bool

    public init(
        pane: String?,
        direction: PaneSplitDirection,
        launch: LaunchSpec? = nil,
        background: Bool = false,
        foreground: Bool = false
    ) {
        self.pane = pane
        self.direction = direction
        self.launch = launch
        self.background = background
        self.foreground = foreground
    }
}

public func parsePaneSplitArgs(_ args: [String]) throws -> ParsedPaneSplit {
    var flags = NewCommandFlags(usage: paneSplitUsage)
    var pane: String?
    var direction: PaneSplitDirection?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--pane":
            pane = try flags.value(in: args, at: i)
            i += 2
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

    // Checked after the loop, so every flag error in the loop outranks it.
    guard let direction else {
        throw CLIParseError(paneSplitUsage)
    }
    return ParsedPaneSplit(
        pane: pane,
        direction: direction,
        launch: flags.launch,
        background: flags.background,
        foreground: flags.foreground
    )
}
