// CLI argument parser for `danterm pane input`. Extracted into the protocol
// library so tests can exercise flag handling and the tmux-style
// `-- <token>...` form without going through a real subprocess.
import Foundation

/// The tail of `danterm pane input`, after the shared target step has taken the
/// pane: the `--literal` mode and the tokens behind the `--` separator.
public struct ParsedSendKeys: Equatable {
    public let events: [InputEvent]

    public init(events: [InputEvent]) {
        self.events = events
    }
}

public enum SendKeysParseError: Error, Equatable {
    case unknownFlag(String)
    case literalRequiresSeparator
    case missingArguments
    case keyToken(KeyTokenError)
}

public func parseSendKeysArgs(_ args: [String]) throws -> ParsedSendKeys {
    var literal = false
    var i = 0

    // Flag prefix. We only honour known flags before the first positional or
    // before `--`; anything else terminates flag parsing.
    while i < args.count {
        let arg = args[i]
        if arg == "--" {
            i += 1
            let tokens = Array(args[i...])
            if tokens.isEmpty { throw SendKeysParseError.missingArguments }
            do {
                let events = try parseKeyTokens(tokens, literal: literal)
                return ParsedSendKeys(events: events)
            } catch let err as KeyTokenError {
                throw SendKeysParseError.keyToken(err)
            }
        }
        if arg == "--literal" {
            literal = true
            i += 1
            continue
        }
        if arg.hasPrefix("--") {
            throw SendKeysParseError.unknownFlag(arg)
        }
        break
    }

    // No `--` separator. `--literal` only has meaning for token parsing after
    // the separator.
    if literal {
        throw SendKeysParseError.literalRequiresSeparator
    }
    throw SendKeysParseError.missingArguments
}
