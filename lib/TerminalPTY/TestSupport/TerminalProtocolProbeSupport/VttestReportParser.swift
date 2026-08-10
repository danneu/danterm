// Parses vttest's logged judgments without treating process exit as conformance evidence.
import Foundation

/// Names the independently replayed vttest sessions in the Milestone 9 gate.
public enum VttestSession: String, CaseIterable, Equatable, Sendable {
    case vt100DeviceStatus = "vt100-dsr-cpr"
    case vt100PrimaryDeviceAttributes = "vt100-da1"
    case vt320ExtendedCursorPosition = "vt320-deccpr"

    fileprivate var choicePrefix: String {
        switch self {
        case .vt100DeviceStatus: "Note: choice 6.3:"
        case .vt100PrimaryDeviceAttributes: "Note: choice 6.4:"
        case .vt320ExtendedCursorPosition: "Note: choice 11.2.5.2.7:"
        }
    }
}

/// Captures the external session identity after all source-authored judgments pass.
public struct VttestReport: Equatable, Sendable {
    /// The replay session whose positive judgments were found.
    public let session: VttestSession
    /// True for every report returned by the parser; invalid evidence throws instead.
    public let isSuccess: Bool

    /// Emits the stable key-value artifact consumed by the outer validation harness.
    public var description: String {
        "status=passed\nsession=\(session.rawValue)\n"
    }
}

/// Validates vttest's selected menu path and session-specific positive judgments.
public enum VttestReportParser {
    /// Rejects missing, incomplete, negative, or wrong-session log output.
    public static func parse(_ text: String, session: VttestSession) throws -> VttestReport {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.contains(where: { $0.hasPrefix(session.choicePrefix) }) else {
            throw VttestReportError.invalidResult
        }

        let results = lines.filter { $0.hasPrefix("Note: result ") }
        let forbidden = ["unknown response", "failed", "failure", "not expected", "bad format"]
        guard results.isEmpty == false, results.allSatisfy({ line in
            let normalized = line.lowercased()
            return forbidden.contains(where: normalized.contains) == false
        }) else {
            throw VttestReportError.invalidResult
        }

        let isComplete: Bool
        switch session {
        case .vt100DeviceStatus:
            let terminalOK = results.filter { $0 == "Note: result  -- means \"TERMINAL OK\"" }.count
            let cursorOK = results.filter { $0 == "Note: result  -- OK" }.count
            isComplete = terminalOK == 1 && cursorOK == 2
        case .vt100PrimaryDeviceAttributes:
            isComplete = results.contains {
                $0 == "Note: result  -- means VT100 with AVO (could be a VT102)"
            }
        case .vt320ExtendedCursorPosition:
            let pattern = #"^Note: result Line [1-9][0-9]*, Column [1-9][0-9]*(?:, Page [1-9][0-9]*| \(Page\?\))$"#
            let regex = try NSRegularExpression(pattern: pattern)
            isComplete = results.contains { line in
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                return regex.firstMatch(in: line, range: range)?.range == range
            }
        }

        guard isComplete else { throw VttestReportError.invalidResult }
        return VttestReport(session: session, isSuccess: true)
    }
}

/// Marks a vttest log that cannot prove the selected replay session passed.
public enum VttestReportError: Error, Equatable, Sendable {
    case invalidResult
}
