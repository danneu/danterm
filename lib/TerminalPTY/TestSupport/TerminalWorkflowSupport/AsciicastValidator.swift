// Validates the externally defined asciicast v2 evidence emitted by the opt-in workflow gate.
import Foundation

/// Summarizes the required evidence so the live gate can publish an inspectable validation report.
public struct AsciicastValidationReport: Equatable, Sendable {
    public let outputEventCount: Int
    public let inputEventCount: Int
    public let resizeEventCount: Int

    public var description: String {
        "status=passed\nversion=2\ninitial_geometry=80x24\nshell=/bin/zsh\nterm=xterm-256color\noutput_events=\(outputEventCount)\ninput_events=\(inputEventCount)\nresize_events=\(resizeEventCount)\nmarker=present\ncolor_sgr=36\nresize=53x17\n"
    }
}

/// Distinguishes malformed streams from streams that omit required nested-PTY evidence.
public enum AsciicastValidationError: Error, CustomStringConvertible {
    case malformed(String)
    case missing(String)

    public var description: String {
        switch self {
        case .malformed(let detail): "malformed asciicast: \(detail)"
        case .missing(let detail): "missing asciicast evidence: \(detail)"
        }
    }
}

/// Enforces the Slice 3b asciicast v2 contract without making asciicast a product format.
public enum AsciicastValidator {
    public static func validate(_ data: Data) throws -> AsciicastValidationReport {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AsciicastValidationError.malformed("stream is not UTF-8")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.contains(where: \.isEmpty) == false else {
            throw AsciicastValidationError.malformed("blank line")
        }
        guard let first = lines.first else { throw AsciicastValidationError.malformed("empty stream") }
        let header = try object(first, line: 1)
        guard let dictionary = header as? [String: Any],
              exactInteger(dictionary["version"], equals: 2),
              exactInteger(dictionary["width"], equals: 80),
              exactInteger(dictionary["height"], equals: 24),
              let environment = dictionary["env"] as? [String: Any],
              environment["SHELL"] as? String == "/bin/zsh",
              environment["TERM"] as? String == "xterm-256color"
        else { throw AsciicastValidationError.malformed("header contract") }

        var output = ""
        var input = ""
        var outputCount = 0
        var inputCount = 0
        var resizeCount = 0
        var foundResize = false
        for (offset, line) in lines.dropFirst().enumerated() {
            guard let event = try object(line, line: offset + 2) as? [Any],
                  event.count == 3,
                  event[0] is NSNumber,
                  let type = event[1] as? String,
                  let payload = event[2] as? String
            else { throw AsciicastValidationError.malformed("event on line \(offset + 2)") }
            switch type {
            case "o": outputCount += 1; output += payload
            case "i": inputCount += 1; input += payload
            case "r":
                resizeCount += 1
                if payload == "53x17" { foundResize = true }
            default: throw AsciicastValidationError.malformed("unsupported event type \(type)")
            }
        }
        guard output.contains("__ASCIINEMA_UTF8__=café-λ") else {
            throw AsciicastValidationError.missing("output marker")
        }
        guard output.contains("\u{1B}[36m__ASCIINEMA_UTF8__=café-λ\u{1B}[0m") else {
            throw AsciicastValidationError.missing("cyan marker SGR")
        }
        guard inputCount > 0 else { throw AsciicastValidationError.missing("input events") }
        guard input.contains("__ASCIINEMA_UTF8__=café-λ") else {
            throw AsciicastValidationError.missing("controlled-session input")
        }
        guard foundResize else { throw AsciicastValidationError.missing("53x17 resize event") }
        return AsciicastValidationReport(
            outputEventCount: outputCount,
            inputEventCount: inputCount,
            resizeEventCount: resizeCount
        )
    }

    private static func object(_ line: Substring, line number: Int) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        catch { throw AsciicastValidationError.malformed("JSON on line \(number)") }
    }

    private static func exactInteger(_ value: Any?, equals expected: Int) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return number.doubleValue == Double(expected)
    }
}
