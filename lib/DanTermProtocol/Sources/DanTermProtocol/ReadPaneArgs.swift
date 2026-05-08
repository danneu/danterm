// CLI argument parser and rendering helpers for `danterm read-pane`.
import Foundation

public struct ParsedReadPane: Equatable {
    public let pane: String
    public let lineLimit: Int?

    public init(pane: String, lineLimit: Int?) {
        self.pane = pane
        self.lineLimit = lineLimit
    }
}

public enum ReadPaneParseError: Error, Equatable {
    case missingPane
    case missingPaneArg
    case missingLinesArg
    case invalidLines(String)
    case unknownFlag(String)
    case unexpectedArgument(String)
}

public func parseReadPaneArgs(_ args: [String]) throws -> ParsedReadPane {
    var pane: String?
    var lineLimit: Int?
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--pane":
            guard i + 1 < args.count else {
                throw ReadPaneParseError.missingPaneArg
            }
            pane = args[i + 1]
            i += 2
        case "--lines":
            guard i + 1 < args.count else {
                throw ReadPaneParseError.missingLinesArg
            }
            let raw = args[i + 1]
            guard let parsed = Int(raw), parsed > 0 else {
                throw ReadPaneParseError.invalidLines(raw)
            }
            lineLimit = parsed
            i += 2
        default:
            if arg.hasPrefix("--") {
                throw ReadPaneParseError.unknownFlag(arg)
            }
            throw ReadPaneParseError.unexpectedArgument(arg)
        }
    }

    guard let pane, !pane.isEmpty else {
        throw ReadPaneParseError.missingPane
    }
    return ParsedReadPane(pane: pane, lineLimit: lineLimit)
}

public func renderReadPaneResult(_ result: JSONValue) -> String? {
    return result["text"]?.asString
}

// Return the last n logical lines while preserving whether the input ended
// with a newline. This treats a final newline as a terminator, not an extra
// empty line to count against the limit.
public func tailLines(_ text: String, n: Int) -> String {
    guard n > 0, !text.isEmpty else { return "" }

    var lineCount = 0
    for character in text where character == "\n" {
        lineCount += 1
    }
    if !text.hasSuffix("\n") {
        lineCount += 1
    }
    guard lineCount > n else { return text }

    let linesToDrop = lineCount - n
    var dropped = 0
    for index in text.indices where text[index] == "\n" {
        dropped += 1
        if dropped == linesToDrop {
            let start = text.index(after: index)
            return String(text[start...])
        }
    }
    return text
}
