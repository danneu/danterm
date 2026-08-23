// The flag grammar that `tab new`, `pane split`, and `group new` share: the flags
// themselves, the text documenting them inside every creation command's usage
// line, and the rendering of the four errors the shared scan can raise. Flags
// unique to a single command -- `--group` and the position flags, `--pane` and
// `-h`/`-v`, `--name` -- stay in that command's own parser file, together with
// that command's composed usage line.
import Foundation

/// The shared flags exactly as they read inside a creation command's usage line.
/// One definition, so adding a shared flag cannot describe it in two usage lines
/// and leave one of them behind.
let newCommandFlagsUsage = cliLaunchAndFocusFlagsSynopsis

/// Accumulates the flags common to every creation command -- `--cmd`, `--cwd`,
/// `--title`, `--background`, `--foreground` -- so that grammar has one
/// definition. A command parser owns one of these, switches on its own flags
/// first, and routes every other token to `consume`, which therefore also holds
/// the one rule for rejecting a token no parser knows. It renders its errors as
/// the CLI reports them, so no caller has a parse error left to translate.
struct NewCommandFlags {
    /// The whole usage line of the command being parsed, quoted by the errors
    /// this grammar renders.
    private let usage: String

    /// Recorded so the focus conflict can be detected. `tab new` and `pane split`
    /// report it; `group new` reads only `foreground`, because the CLI derives its
    /// background from that flag's absence.
    private(set) var background = false
    private(set) var foreground = false
    private var cmd: String?
    private var cwd: String?
    private var title: String?

    init(usage: String) {
        self.usage = usage
    }

    /// The launch these flags describe, or nil when none of cmd, cwd, or title
    /// survived `LaunchSpec` normalization -- which drops an empty cmd but keeps
    /// an empty cwd or title.
    var launch: LaunchSpec? {
        let spec = LaunchSpec(cmd: cmd, cwd: cwd, title: title)
        return spec.isEmpty ? nil : spec
    }

    /// Reads the shared flag at `index` and returns the index of the next token,
    /// so the caller's loop advances by whatever this flag consumed. Reports
    /// `unknown flag` for an unrecognized token that starts with `-` and
    /// `unexpected argument` for anything else. A repeated value flag overwrites
    /// silently; a repeated focus flag is accepted, and only the opposite one
    /// conflicts.
    mutating func consume(_ args: [String], at index: Int) throws -> Int {
        let arg = args[index]
        switch arg {
        case "--cmd":
            cmd = try value(in: args, at: index)
            return index + 2
        case "--cwd":
            cwd = try value(in: args, at: index)
            return index + 2
        case "--title":
            title = try value(in: args, at: index)
            return index + 2
        case "--background":
            guard foreground == false else { throw focusConflict() }
            background = true
            return index + 1
        case "--foreground":
            guard background == false else { throw focusConflict() }
            foreground = true
            return index + 1
        default:
            if arg.hasPrefix("-") {
                throw CLIParseError("unknown flag: \(arg)")
            }
            throw CLIParseError("unexpected argument: \(arg)")
        }
    }

    /// Reads the value token after the value-taking flag at `index`. Command
    /// parsers call it for their own value flags too, so a missing value reports
    /// the same bare usage line wherever the flag is defined.
    func value(in args: [String], at index: Int) throws -> String {
        guard index + 1 < args.count else {
            throw CLIParseError(usage)
        }
        return args[index + 1]
    }

    private func focusConflict() -> CLIParseError {
        CLIParseError("--background and --foreground are mutually exclusive\n\(usage)")
    }
}
