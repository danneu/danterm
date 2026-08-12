// The flag grammar that `tab new`, `pane split`, and `group new` share, plus the
// one error type all three arg parsers throw. Flags unique to a single command
// -- `--group` and the position flags, `--pane` and `-h`/`-v`, `--name` -- stay
// in that command's own parser file.
import Foundation

/// The single error type for the three creation-command arg parsers. They share
/// a flag grammar, so a shared parser can only report errors through one enum;
/// keeping three would force each caller to catch and remap. `conflictingPositionFlags`
/// and `missingDirection` come from one command each and are unreachable for the
/// others, which is cheaper than the remapping shim.
public enum NewCommandParseError: Error, Equatable {
    case missingValue(String)
    case unknownFlag(String)
    case unexpectedArgument(String)
    case conflictingFocusFlags
    /// `tab new` only: two of `--after-selected`, `--at-group-end`, `--after-tab`.
    case conflictingPositionFlags
    /// `pane split` only: neither `-h` nor `-v` was given.
    case missingDirection
}

/// Accumulates the flags common to every creation command -- `--cmd`, `--cwd`,
/// `--title`, `--background`, `--foreground` -- so that grammar has one
/// definition. A command parser owns one of these, switches on its own flags
/// first, and routes every other token to `consume`, which therefore also holds
/// the one rule for rejecting a token no parser knows.
struct NewCommandFlags {
    /// Recorded so the focus conflict can be detected. `tab new` and `pane split`
    /// report it; `group new` reads only `foreground`, because the CLI derives its
    /// background from that flag's absence.
    private(set) var background = false
    private(set) var foreground = false
    private var cmd: String?
    private var cwd: String?
    private var title: String?

    /// The launch these flags describe, or nil when none of cmd, cwd, or title
    /// survived `LaunchSpec` normalization -- which drops an empty cmd but keeps
    /// an empty cwd or title.
    var launch: LaunchSpec? {
        let spec = LaunchSpec(cmd: cmd, cwd: cwd, title: title)
        return spec.isEmpty ? nil : spec
    }

    /// Reads the shared flag at `index` and returns the index of the next token,
    /// so the caller's loop advances by whatever this flag consumed. Throws
    /// `unknownFlag` for an unrecognized token that starts with `-` and
    /// `unexpectedArgument` for anything else. A repeated value flag overwrites
    /// silently; a repeated focus flag is accepted, and only the opposite one
    /// conflicts.
    mutating func consume(_ args: [String], at index: Int) throws -> Int {
        let arg = args[index]
        switch arg {
        case "--cmd":
            cmd = try newCommandFlagValue(after: arg, in: args, at: index)
            return index + 2
        case "--cwd":
            cwd = try newCommandFlagValue(after: arg, in: args, at: index)
            return index + 2
        case "--title":
            title = try newCommandFlagValue(after: arg, in: args, at: index)
            return index + 2
        case "--background":
            guard foreground == false else { throw NewCommandParseError.conflictingFocusFlags }
            background = true
            return index + 1
        case "--foreground":
            guard background == false else { throw NewCommandParseError.conflictingFocusFlags }
            foreground = true
            return index + 1
        default:
            if arg.hasPrefix("-") {
                throw NewCommandParseError.unknownFlag(arg)
            }
            throw NewCommandParseError.unexpectedArgument(arg)
        }
    }
}

/// Reads the value token after a value-taking flag. Shared so a missing value
/// names its flag the same way for the shared flags and for each command's own.
func newCommandFlagValue(after flag: String, in args: [String], at index: Int) throws -> String {
    guard index + 1 < args.count else {
        throw NewCommandParseError.missingValue(flag)
    }
    return args[index + 1]
}
