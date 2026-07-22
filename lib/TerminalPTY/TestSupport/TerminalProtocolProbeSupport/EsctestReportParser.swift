// Parses esctest2's textual completion record without trusting its process exit status.
import Foundation

/// Captures the selected-case counts used to decide whether external evidence passed.
public struct EsctestReport: Equatable, Sendable {
    /// Total cases esctest2 says matched the allowlist.
    public let selected: Int
    /// Cases whose assertions completed successfully.
    public let passed: Int
    /// Cases esctest2 suppressed for the selected terminal identity.
    public let knownBugs: Int
    /// Cases whose assertions failed.
    public let failed: Int
    /// True only when every expected case ran and passed without suppression.
    public let isSuccess: Bool

    /// Emits the stable key-value artifact consumed by the outer validation harness.
    public var description: String {
        "status=\(isSuccess ? "passed" : "failed")\nselected=\(selected)\npassed=\(passed)\nknown_bugs=\(knownBugs)\nfailed=\(failed)\n"
    }
}

/// Rejects malformed, incomplete, or unexpectedly selected esctest2 summaries.
public enum EsctestReportParser {
    /// Reads the final completion line and validates its selection count against the allowlist.
    public static func parse(_ text: String, expectedCount: Int) throws -> EsctestReport {
        let pattern = #"\*\*\* ([0-9]+) tests? passed, ([0-9]+) known bugs?, ([0-9]+) tests? failed \*\*\*"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let passedRange = Range(match.range(at: 1), in: text),
              let bugsRange = Range(match.range(at: 2), in: text),
              let failedRange = Range(match.range(at: 3), in: text),
              let passed = Int(text[passedRange]),
              let knownBugs = Int(text[bugsRange]),
              let failed = Int(text[failedRange])
        else { throw EsctestReportError.malformed }
        let selected = passed + knownBugs + failed
        return EsctestReport(
            selected: selected,
            passed: passed,
            knownBugs: knownBugs,
            failed: failed,
            isSuccess: selected == expectedCount && knownBugs == 0 && failed == 0
        )
    }
}

/// Distinguishes an unusable external report from a valid report containing failures.
public enum EsctestReportError: Error, Equatable, Sendable {
    case malformed
}
