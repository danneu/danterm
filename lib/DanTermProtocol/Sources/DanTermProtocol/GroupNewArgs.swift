// CLI argument parser for `danterm group new`. Holds only the flag unique to this
// command -- `--name`; the launch and focus flags come from `NewCommandFlags`.
// The background default and the cwd fallback are CLI policy and live in CLIParser.
// The usage line lives here too, next to the flags it documents.
import Foundation

/// The one `group new` usage line, read both by this parser, which renders its
/// errors with it, and by `CLIParser`, whose post-parse guards report it.
let groupNewUsage = "usage: danterm group new --name <name> \(newCommandFlagsUsage)"

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

public func parseGroupNewArgs(_ args: [String]) throws -> ParsedGroupNew {
    var flags = NewCommandFlags(usage: groupNewUsage)
    var name: String?
    var index = 0

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--name":
            name = try flags.value(in: args, at: index)
            index += 2
        default:
            index = try flags.consume(args, at: index)
        }
    }

    // `--background` is parsed but dropped: it only feeds the focus conflict
    // guard, and the CLI derives the background from `foreground == false`.
    return ParsedGroupNew(
        name: name,
        launch: flags.launch,
        foreground: flags.foreground
    )
}
