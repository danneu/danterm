// Behavioral tests for esctest2 result parsing independent of the external process status.
import Testing

@testable import TerminalProtocolProbeSupport

/// Pins the external completion record to exact selection and failure semantics.
struct EsctestReportParserTests {
    @Test("matching all-pass summary succeeds")
    func success() throws {
        let report = try EsctestReportParser.parse(
            "*** 11 tests passed, 0 known bugs, 0 tests failed ***",
            expectedCount: 11
        )

        #expect(report.isSuccess)
        #expect(report.selected == 11)
        #expect(report.description.hasPrefix("status=passed\n"))
    }

    @Test("a failed case or selection-count drift fails")
    func failures() throws {
        let failed = try EsctestReportParser.parse(
            "*** 10 tests passed, 0 known bugs, 1 TEST FAILED ***",
            expectedCount: 11
        )
        let drifted = try EsctestReportParser.parse(
            "*** 10 tests passed, 0 known bugs, 0 tests failed ***",
            expectedCount: 11
        )

        #expect(failed.isSuccess == false)
        #expect(drifted.isSuccess == false)
    }

    @Test("missing completion summary is malformed")
    func malformed() {
        #expect(throws: EsctestReportError.malformed) {
            try EsctestReportParser.parse("traceback only", expectedCount: 11)
        }
    }
}
