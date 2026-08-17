// Where the logical-line cutover's ladder regression actually went: the wiring between
// `LogicalLineStore` and `Terminal`, priced against the same revision the ladder was paired to.
//
// `research/31/F11` recorded the paired ladder rejecting the cutover -- `retained-browse` +60.44%,
// `scrollback-stream` +141.42% -- and bounded where the cost is *not* (not the locate count, not
// the projection arithmetic, not `admit`/`evictOneDisplayRow` as `research/31/F10` priced them). Every
// campaign probe drove `LogicalLineStore` directly and measured it fast; the ladder drives
// `Terminal`. This file measures the two `Terminal`-level paths the ladder exercises, in the shape
// the ladder exercises them, so the regression can be attributed to named mechanisms before
// anything is fixed.
//
// Belongs here: `Terminal`-level stimuli that reproduce a ladder workload's inner loop, and the
// statistics that split it. Does not belong here: a threshold or a verdict -- the ladder is the
// only thing that issues one, and this probe never re-runs it. Nothing under
// `lib/TerminalCore/Sources/` is touched by it.
//
// **The probe is written to run unchanged at `28c54e1`**, the pre-cutover parent the ladder is
// paired against, so every ratio it reports has a same-session control the change cannot reach
// (`agent-docs/measurement-discipline.md`). It uses only API both revisions expose: `Terminal.init`,
// `feed`, `scroll(toTopRow:)`, `geometry`, `forEachViewportCell(row:_:)` and `scrollbackRowCount`.
// Copy the file into a checkout of the baseline and run the same command there. It needs
// `settleAllocator()` and `residentFootprintBytes()`, which `28c54e1` already defines in its own
// probe files; copy `ProbeHostMeasurements.swift` alongside it only for a revision that does not.
//
// Three readings, each answering one question `research/31/F11` left open:
//
//   * `drain` -- what a sustained feed costs per byte, and *how much of that cost is created by a
//     consumer holding one value copy of the terminal*. `TerminalPTYHost.publish` puts the whole
//     `Terminal` value into a `TerminalFrame` and hands it to the frame consumer, which holds it
//     until the next publish. Under a value-type history that makes the next mutation non-unique,
//     so the arm the probe calls `published` is the shape the app actually runs and `unshared` is
//     the shape every campaign microbenchmark ran. Their ratio is the term no store-level probe
//     could see. `scrollback-stream`'s own stimulus and geometry.
//   * `browse` -- what one frame's two viewport traversals cost over retained history, split into
//     the geometry pass (`geometry`, kinds only) and the cell pass (`forEachViewportCell`, scalars
//     and styles). `retained-browse`'s own stimulus, geometry and parking. Both passes are spelled
//     per row, which is the one spelling both revisions have; the cutover's own frame path uses a
//     plural spelling that pays one fewer locate per row, so this arm reads the *decode* cost and
//     slightly over-charges the cutover for addressing.
//   * `footprint` -- the settled `phys_footprint` delta each `drain` arm leaves behind, which is
//     what `research/31/DD49`'s 8.62x pane reading has to be explained by.
//
// Not part of the `just test` gate. Every measurement is skipped unless
// `DANTERM_WIRED_ATTRIBUTION_PROBE` is set. Run it as:
//
//     DANTERM_WIRED_ATTRIBUTION_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalWiredHistoryAttributionProbe
import Foundation
import Testing

@testable import TerminalCore

@Suite("Doc 31 wired-engine attribution probe", .serialized)
struct TerminalWiredHistoryAttributionProbe {
    static let probeIsEnabled =
        ProcessInfo.processInfo.environment["DANTERM_WIRED_ATTRIBUTION_PROBE"] != nil

    static let columns = 179
    static let rows = 66
    static let chunkBytes = 4096

    // MARK: Stimuli

    /// `scrollback-stream`'s committed stimulus, transcribed from
    /// `benchmarks/fixtures/terminal-app.json`: 25,000 numbered ASCII lines.
    static func streamBytes(lines: Int = 25_000) -> [UInt8] {
        var text = ""
        text.reserveCapacity(lines * 64)
        for index in 0..<lines {
            text += "DANTERM-SCROLLBACK-\(String(format: "%05d", index)) "
            text += "sustained plain-text output payload\n"
        }
        return Array(text.utf8)
    }

    /// `retained-browse`'s committed stimulus: 10,000 short hard-terminated lines.
    static func browseBytes(lines: Int = 10_000) -> [UInt8] {
        var text = ""
        text.reserveCapacity(lines * 64)
        for index in 0..<lines {
            text += "DANTERM-BROWSE-\(String(format: "%05d", index)) plain ascii retained row\r\n"
        }
        return Array(text.utf8)
    }

    // MARK: Drain

    /// One sustained feed, optionally with a consumer holding the published value.
    ///
    /// `publishEvery` is the number of fed chunks between publishes; `nil` never publishes. A
    /// publish stores the terminal *value* in a held slot and releases the previous one, which is
    /// exactly `TerminalPTYHost.publish`'s lifetime: the frame consumer holds one frame until the
    /// next arrives.
    static func drain(
        bytes: [UInt8],
        publishEvery: Int?
    ) -> (nanoseconds: UInt64, footprintDelta: Int64, retainedRows: Int) {
        // Sampled before the terminal exists so the delta charges the arena's reservation to the
        // revision that makes it, which is what makes the two revisions' numbers comparable.
        settleAllocator()
        let footprintBefore = residentFootprintBytes()

        var terminal = Terminal(columns: columns, rows: rows)!
        var published: Terminal?
        var chunkIndex = 0

        let started = DispatchTime.now().uptimeNanoseconds
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkBytes, bytes.count)
            terminal.feed(Array(bytes[offset..<end]))
            offset = end
            chunkIndex += 1
            if let publishEvery, chunkIndex % publishEvery == 0 {
                published = terminal
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        // Free pages are returned before the sample on purpose: `just terminal-memory-probe` does
        // not do this, so its delta charges pages the allocator merely *has not returned* to the
        // pane that dirtied them. This arm reads what history costs once that hysteresis is gone.
        settleAllocator()
        let footprintAfter = residentFootprintBytes()

        // Read the held copy so the optimizer cannot delete the publish it exists to model.
        let heldRows = published?.scrollbackRowCount ?? 0
        precondition(heldRows >= 0)
        return (elapsed, Int64(footprintAfter) - Int64(footprintBefore), terminal.scrollbackRowCount)
    }

    @Test(
        "drain: what a sustained feed costs, with and without a published value copy",
        .enabled(if: probeIsEnabled)
    )
    func drainAttribution() {
        let bytes = Self.streamBytes()

        var lines: [String] = []
        lines.append("== drain (scrollback-stream stimulus, \(bytes.count) bytes, 179x66) ==")
        var unsharedNanoseconds = 1.0
        for cadence in [nil, 16, 1] as [Int?] {
            let result = Self.drain(bytes: bytes, publishEvery: cadence)
            let nanoseconds = Double(result.nanoseconds)
            if cadence == nil { unsharedNanoseconds = nanoseconds }
            let seconds = nanoseconds / 1e9
            let megabytes = Double(bytes.count) / (1024 * 1024)
            let name = cadence.map { "published every \($0)" } ?? "unshared"
            lines.append(
                "  " + name.padding(toLength: 22, withPad: " ", startingAt: 0)
                    + String(format: "%8.3f s  %8.3f MB/s  %7.2f ns/byte  %6.3fx  ",
                             seconds,
                             megabytes / seconds,
                             nanoseconds / Double(bytes.count),
                             nanoseconds / unsharedNanoseconds)
                    + String(format: "settled footprint %+8.2f MiB",
                             Double(result.footprintDelta) / (1024 * 1024))
                    + "  retained rows \(result.retainedRows)"
            )
        }
        print(lines.joined(separator: "\n"))
    }

    // MARK: Browse

    @Test(
        "browse: what one frame's two viewport traversals cost over retained history",
        .enabled(if: probeIsEnabled)
    )
    func browseAttribution() {
        var terminal = Terminal(columns: Self.columns, rows: Self.rows)!
        let bytes = Self.browseBytes()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + Self.chunkBytes, bytes.count)
            terminal.feed(Array(bytes[offset..<end]))
            offset = end
        }
        terminal.scroll(toTopRow: 0)

        let frames = 500
        var kindChecksum: UInt64 = 0
        var cellChecksum: UInt64 = 0

        for _ in 0..<20 {
            kindChecksum &+= Self.geometryPass(terminal)
            cellChecksum &+= Self.cellPass(terminal)
        }
        kindChecksum = 0
        cellChecksum = 0

        let geometryStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<frames { kindChecksum &+= Self.geometryPass(terminal) }
        let geometryElapsed = DispatchTime.now().uptimeNanoseconds - geometryStarted

        let cellStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<frames { cellChecksum &+= Self.cellPass(terminal) }
        let cellElapsed = DispatchTime.now().uptimeNanoseconds - cellStarted

        print(
            """
            == browse (retained-browse stimulus, \(terminal.scrollbackRowCount) retained rows) ==
              geometry pass  \(geometryElapsed / UInt64(frames)) ns/frame  checksum \(kindChecksum)
              cell pass      \(cellElapsed / UInt64(frames)) ns/frame  checksum \(cellChecksum)
            """
        )
    }

    /// The kinds-only traversal `RenderFramePlanner` takes once per frame.
    static func geometryPass(_ terminal: Terminal) -> UInt64 {
        var total: UInt64 = 0
        for row in terminal.geometry.rows {
            total &+= UInt64(row.cells.count)
        }
        return total
    }

    /// The scalars-and-styles traversal the planner takes once per frame, spelled per row because
    /// that is the one spelling both compared revisions have.
    static func cellPass(_ terminal: Terminal) -> UInt64 {
        var total: UInt64 = 0
        for row in 0..<Self.rows {
            terminal.forEachViewportCell(row: row) { _, _, _ in total &+= 1 }
        }
        return total
    }
}
