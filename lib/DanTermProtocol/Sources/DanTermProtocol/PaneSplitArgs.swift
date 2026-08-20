// CLI argument parser for `danterm pane split`. Holds only the flags unique to
// this command -- its pane-or-tab target and pane direction; the launch and focus
// flags come from `NewCommandFlags`. The usage line lives here too, next to the
// flags it documents.
import Foundation

/// The one `pane split` usage line, read both by this parser, which renders its
/// errors with it, and by `CLIParser`, whose post-parse guard reports it.
let paneSplitUsage = "usage: danterm pane split (--pane <pane-id> -h|-v | --tab <tab-id>) \(newCommandFlagsUsage)"

public enum PaneSplitDirection: Equatable, Sendable {
    case horizontal
    case vertical
}

/// Keeps the two accepted CLI target forms internally consistent after parsing.
public enum ParsedPaneSplitTarget: Equatable {
    case pane(String, direction: PaneSplitDirection)
    case tab(String)
}

/// Carries a validated split target with the launch and focus flags shared by both forms.
public struct ParsedPaneSplit: Equatable {
    public let target: ParsedPaneSplitTarget
    public let launch: LaunchSpec?
    public let background: Bool
    /// Records that `--foreground` was typed while leaving background-default
    /// policy to the command parser.
    public let foreground: Bool

    public init(
        target: ParsedPaneSplitTarget,
        launch: LaunchSpec? = nil,
        background: Bool = false,
        foreground: Bool = false
    ) {
        self.target = target
        self.launch = launch
        self.background = background
        self.foreground = foreground
    }
}

public func parsePaneSplitArgs(_ args: [String]) throws -> ParsedPaneSplit {
    var flags = NewCommandFlags(usage: paneSplitUsage)
    var pane: String?
    var tab: String?
    var direction: PaneSplitDirection?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--pane":
            pane = try flags.value(in: args, at: i)
            i += 2
        case "--tab":
            tab = try flags.value(in: args, at: i)
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

    // Checked after the loop, so every flag error in the loop outranks target grammar.
    let target: ParsedPaneSplitTarget
    switch (pane, tab, direction) {
    case (.some(let pane), .none, .some(let direction)):
        target = .pane(pane, direction: direction)
    case (.none, .some(let tab), .none):
        target = .tab(tab)
    default:
        throw CLIParseError(paneSplitUsage)
    }
    return ParsedPaneSplit(
        target: target,
        launch: flags.launch,
        background: flags.background,
        foreground: flags.foreground
    )
}
