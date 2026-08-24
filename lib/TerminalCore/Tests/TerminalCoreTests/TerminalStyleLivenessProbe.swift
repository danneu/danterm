// The env-gated ROW-3 reading of retained style-liveness work at production scrollback depth.
//
// This probe counts arena cell-word visits through the engine's exact task-local instrument. It
// reports no wall clock and makes no performance verdict. The gate-resident style-table suite
// owns the counter's fidelity proof; this file only supplies the production-depth reading.
//
// Not part of the `just test` gate. Run it as:
//
//     DANTERM_STYLE_LIVENESS_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalStyleLivenessProbe

import Foundation
import Testing

@testable import TerminalCore

/// Reports the retained-cell work charged by one style sweep after deterministic style churn.
@Suite("ROW-3 retained style-liveness probe", .serialized)
struct TerminalStyleLivenessProbe {
    static let probeIsEnabled =
        ProcessInfo.processInfo.environment["DANTERM_STYLE_LIVENESS_PROBE"] != nil

    static let columns = 179
    static let rows = 66
    static let retainedLine = [UInt8](repeating: 0x61, count: columns - 1) + [0x0D, 0x0A]
    static let retainedLineCount = 20_000
    static let mintedStyleCount = Terminal.baseStyleSweepThreshold

    static func trueColor(_ index: Int) -> [UInt8] {
        let red = UInt8((index >> 16) & 0xFF)
        let green = UInt8((index >> 8) & 0xFF)
        let blue = UInt8(index & 0xFF)
        return Array("\u{1B}[38;2;\(red);\(green);\(blue)m".utf8)
    }

    @Test(
        "production-depth retained style-liveness work",
        .enabled(if: probeIsEnabled)
    )
    func productionDepthReading() throws {
        var terminal = try #require(Terminal(columns: Self.columns, rows: Self.rows))
        for _ in 0..<Self.retainedLineCount {
            terminal.feed(Self.retainedLine)
        }

        let census = terminal.memoryCensus
        #expect(terminal.scrollbackBudgetBytes == Terminal.scrollbackByteLimit)
        #expect(census.retainedArenaBytesInUse * 10 > census.retainedArenaCapacityBytes * 9)
        #expect(census.distinctStyleCount == 1)

        let visits = Instrument.retainedStyleLivenessCellVisit.measure {
            for index in 1...Self.mintedStyleCount {
                terminal.moveCursor(row: 0, column: 0)
                terminal.feed(Self.trueColor(0x800000 + index))
                terminal.feed([0x78])
            }
        }

        #expect(visits == census.retainedStoredCellCount)
        print(
            """
            [ROW-3] retained style-liveness work
              columns=\(Self.columns) rows=\(Self.rows) \
            scrollbackBudgetBytes=\(terminal.scrollbackBudgetBytes)
              retainedArenaBytesInUse=\(census.retainedArenaBytesInUse) \
            retainedArenaCapacityBytes=\(census.retainedArenaCapacityBytes)
              retainedStoredCellCount=\(census.retainedStoredCellCount) \
            newlyMintedStyles=\(Self.mintedStyleCount)
              retainedCellWordVisits=\(visits) \
            visitsPerNewStyle=\(visits)/\(Self.mintedStyleCount)
            """
        )
    }
}
