// CLI argument parser for `danterm send-keys`. Extracted into the protocol
// library so tests can exercise flag handling and the tmux-style
// `-- <token>...` form without going through a real subprocess.
import Foundation

public struct ParsedSendKeys: Equatable {
    public let pane: String?
    public let events: [InputEvent]

    public init(pane: String?, events: [InputEvent]) {
        self.pane = pane
        self.events = events
    }
}

public enum SendKeysParseError: Error, Equatable {
    case unknownFlag(String)
    case missingPaneArg
    case literalRequiresSeparator
    case missingArguments
    case keyToken(KeyTokenError)
}

public func parseSendKeysArgs(_ args: [String]) throws -> ParsedSendKeys {
    var pane: String? = nil
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
                return ParsedSendKeys(pane: pane, events: events)
            } catch let err as KeyTokenError {
                throw SendKeysParseError.keyToken(err)
            }
        }
        if arg == "--pane" {
            guard i + 1 < args.count else {
                throw SendKeysParseError.missingPaneArg
            }
            pane = args[i + 1]
            i += 2
            continue
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
