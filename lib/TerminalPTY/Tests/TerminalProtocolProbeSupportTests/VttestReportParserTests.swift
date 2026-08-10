// Behavioral tests for vttest result parsing independent of process exit status.
import Testing

@testable import TerminalProtocolProbeSupport

/// Pins each replay session to its source-defined menu choice and positive result markers.
struct VttestReportParserTests {
    @Test("VT100 DSR/CPR requires terminal status and two accepted cursor reports")
    func deviceStatus() throws {
        let report = try VttestReportParser.parse(
            """
            Note: choice 6.3: Device Status Report (DSR)                 VT100 & up
            Note: result  -- means "TERMINAL OK"
            Note: result  -- OK
            Note: result  -- OK
            """,
            session: .vt100DeviceStatus
        )

        #expect(report.isSuccess)
        #expect(report.session == .vt100DeviceStatus)
        #expect(report.description == "status=passed\nsession=vt100-dsr-cpr\n")
    }

    @Test("VT100 DA1 requires the exact DanTerm identity interpretation")
    func primaryDeviceAttributes() throws {
        let report = try VttestReportParser.parse(
            """
            Note: choice 6.4: Primary Device Attributes (DA)             VT100 & up
            Note: result  -- means VT100 with AVO (could be a VT102)
            Note: result Legend:      AVO = Advanced Video Option
            """,
            session: .vt100PrimaryDeviceAttributes
        )

        #expect(report.isSuccess)
    }

    @Test("VT320 DECCPR requires a positive decoded line and column")
    func extendedCursorPosition() throws {
        let report = try VttestReportParser.parse(
            """
            Note: choice 11.2.5.2.7: Test Extended Cursor-Position (DECXCPR)
            Note: result Line 1, Column 1 (Page?)
            """,
            session: .vt320ExtendedCursorPosition
        )

        #expect(report.isSuccess)
    }

    @Test("wrong choices, incomplete results, and negative judgments fail")
    func rejectedReports() {
        let cases: [(String, VttestSession)] = [
            ("Note: choice 6.4: Primary Device Attributes\nNote: result  -- Unknown response", .vt100PrimaryDeviceAttributes),
            ("Note: choice 6.3: Device Status Report\nNote: result  -- means \"TERMINAL OK\"\nNote: result  -- OK", .vt100DeviceStatus),
            ("Note: choice 11.2.5.2.6: Test Extended Cursor-Position\nNote: result Line 1, Column 1 (Page?)", .vt320ExtendedCursorPosition),
            ("Note: choice 11.2.5.2.7: Test Extended Cursor-Position\nNote: result failed", .vt320ExtendedCursorPosition),
        ]

        for (text, session) in cases {
            #expect(throws: VttestReportError.invalidResult) {
                try VttestReportParser.parse(text, session: session)
            }
        }
    }
}
