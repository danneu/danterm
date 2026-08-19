// The one target grammar every `danterm` subcommand names its entity through:
// which flag a subcommand accepts, where the flag may appear, and how each way
// of getting it wrong reads. A subcommand's own arguments -- its flags, its
// positional values, its `--` separator -- belong in CLIParser.swift, because
// this step consumes the target before any of that is looked at.
import Foundation

/// Names the entity a subcommand targets. One case carries both halves of the
/// grammar -- the flag a caller types and the noun a malformed id is reported
/// against -- so a target kind is one declaration rather than parallel strings
/// that can drift apart.
enum CLITargetKind: CaseIterable {
    case pane
    case tab
    case group

    var flag: String {
        switch self {
        case .pane: return "--pane"
        case .tab: return "--tab"
        case .group: return "--group"
        }
    }

    var entity: String {
        switch self {
        case .pane: return "pane"
        case .tab: return "tab"
        case .group: return "group"
        }
    }
}

/// What the shared step hands a command parser: which target flag the caller
/// chose, the raw id behind it, and the arguments that follow. The kind matters
/// to a subcommand that accepts more than one, and is ignored by the rest.
struct CLITargetParse {
    let kind: CLITargetKind
    let rawId: String
    let rest: [String]
}

/// Reads the target that leads a subcommand's arguments, before the subcommand's
/// own parser sees anything. Every way a target can be wrong is worded here, so
/// the same mistake reads the same way in every subcommand and differs only in
/// the usage line it quotes.
func parseCLITarget(
    _ args: [String],
    accepting kinds: [CLITargetKind],
    usage: String
) throws -> CLITargetParse {
    if let head = args.first, let kind = kinds.first(where: { $0.flag == head }) {
        guard args.count >= 2, args[1].isEmpty == false else { throw CLIParseError(usage) }
        return CLITargetParse(kind: kind, rawId: args[1], rest: Array(args.dropFirst(2)))
    }
    if let head = args.first, let stray = CLITargetKind.allCases.first(where: { $0.flag == head }) {
        throw CLIParseError("\(stray.flag) is not a target of this command\n\(usage)")
    }
    // A `--` separator ends the arguments this command owns, so a target flag
    // written after it is one of the caller's own tokens, not a misplaced target.
    let owned = args.prefix(while: { $0 != "--" })
    if let kind = kinds.first(where: { kind in owned.contains(kind.flag) }) {
        throw CLIParseError("\(kind.flag) must come first\n\(usage)")
    }
    throw CLIParseError(usage)
}

/// Reads the one pane a subcommand targets. The wrappers exist so a command
/// parser receives an id of the type it needs and never sees the raw word.
func parsePaneTarget(_ args: [String], usage: String) throws -> (pane: PaneId, rest: [String]) {
    let parsed = try parseCLITarget(args, accepting: [.pane], usage: usage)
    return (try parsePaneId(parsed.rawId), parsed.rest)
}

/// Reads the one tab a subcommand targets.
func parseTabTarget(_ args: [String], usage: String) throws -> (tab: TabId, rest: [String]) {
    let parsed = try parseCLITarget(args, accepting: [.tab], usage: usage)
    return (try parseTabId(parsed.rawId), parsed.rest)
}

/// Reads the one group a subcommand targets.
func parseGroupTarget(_ args: [String], usage: String) throws -> (group: GroupId, rest: [String]) {
    let parsed = try parseCLITarget(args, accepting: [.group], usage: usage)
    return (try parseGroupId(parsed.rawId), parsed.rest)
}

/// Rejects anything left after the target of a subcommand whose grammar ends
/// there, keeping a flag nobody knows distinct from a word with no place here.
func rejectTrailingArguments(_ args: [String]) throws {
    guard let argument = args.first else { return }
    if argument.hasPrefix("--") {
        throw CLIParseError("unknown flag: \(argument)")
    }
    throw CLIParseError("unexpected argument: \(argument)")
}

/// Turns a typed word into a pane id. The wording of the refusal is the CLI's
/// one answer for a malformed pane, wherever the word came from.
func parsePaneId(_ raw: String) throws -> PaneId {
    guard let uuid = UUID(uuidString: raw) else { throw CLIParseError("invalid pane id: \(raw)") }
    return PaneId(rawValue: uuid)
}

/// Turns a typed word into a tab id, refusing anything that is not a UUID.
func parseTabId(_ raw: String) throws -> TabId {
    guard let uuid = UUID(uuidString: raw) else { throw CLIParseError("invalid tab id: \(raw)") }
    return TabId(rawValue: uuid)
}

/// Turns a typed word into a group id, refusing anything that is not a UUID.
func parseGroupId(_ raw: String) throws -> GroupId {
    guard let uuid = UUID(uuidString: raw) else { throw CLIParseError("invalid group id: \(raw)") }
    return GroupId(rawValue: uuid)
}
