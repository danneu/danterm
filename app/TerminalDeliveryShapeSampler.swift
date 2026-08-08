// Live lines-per-publish sampler for one pane. It exists only to answer "how
// many viewport lines does one published frame carry in a running app", which
// places production on the scroll-amplification curve research/33/F13 measured
// (66x at one line per delivery, 1x at a whole screen) and which no headless
// probe can answer because the number is set by the PTY read cadence against a
// real child process.
//
// Not a general metrics facility, per the rule TerminalFrameRateSampler set:
// this instrument owns one question. It reads the absolute viewport top row the
// engine already keeps, diffs it per publish, and writes a line per elapsed
// window. A second question wants its own instrument, not a field on this one.
import Foundation

/// Appends one JSON line per sampling window carrying a scrolled-lines-per-publish
/// histogram, so an external script can read the live delivery shape off a pane.
///
/// Created only when `DANTERM_DELIVERY_SHAPE_LOG` names a file, so an ordinary
/// run pays one optional test per publish and nothing else. Owned by the view
/// whose frames it counts, and it starts and stops with that view: it holds no
/// timer, no observer, and no reference back to its owner.
@MainActor
final class TerminalDeliveryShapeSampler {
    /// Names the file to append to. Forwarded into a development slot with
    /// `./scripts/dev-slot-launcher.py --pass-env DANTERM_DELIVERY_SHAPE_LOG`.
    static let environmentVariable = "DANTERM_DELIVERY_SHAPE_LOG"

    /// Names a second file that receives one line per publish -- the same question
    /// at event grain, for when a window aggregate needs explaining. Ignored unless
    /// the window log above is also active.
    static let traceEnvironmentVariable = "DANTERM_DELIVERY_SHAPE_TRACE"

    /// Upper bounds of the lines-per-publish histogram buckets, chosen to bracket
    /// `research/33/F13`'s curve points: 1 line (66x amplification), 8 (8x), and 91 --
    /// one 16 KiB read turn at 179 columns -- where amplification reaches 1x.
    private static let bucketUpperBounds = [0, 1, 2, 8, 32, 65, 90]
    private static let bucketLabels = [
        "h0", "h1", "h2", "h3to8", "h9to32", "h33to65", "h66to90", "h91plus",
    ]

    private static let windowNanoseconds: UInt64 = 1_000_000_000
    private static var nextPaneIndex = 0

    private let handle: FileHandle
    private let traceHandle: FileHandle?
    private let paneIndex: Int
    private var windowStartNanoseconds: UInt64
    private var windowStartDeliveryCount: UInt64 = 0
    /// False until the first sample supplies a delivery count, so the first
    /// window reports deliveries measured from its own start, not from zero.
    private var isDeliveryBaselineSet = false
    /// Nil until the first publish supplies a position, so the first frame after
    /// launch contributes no delta measured against an arbitrary zero.
    private var lastAbsoluteTopRow: Int?
    private var publishes = 0
    private var fullDamagePublishes = 0
    private var scrolledLines = 0
    private var gridRows = 0
    private var bucketCounts = [Int](repeating: 0, count: 8)

    /// Returns a sampler only when the environment asked for one, so the call
    /// site stays a single `let sampler = TerminalDeliveryShapeSampler.make()`.
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalDeliveryShapeSampler? {
        guard let path = environment[environmentVariable], path.isEmpty == false else {
            return nil
        }
        return TerminalDeliveryShapeSampler(
            path: path,
            tracePath: environment[traceEnvironmentVariable]
        )
    }

    private init?(path: String, tracePath: String?) {
        if FileManager.default.fileExists(atPath: path) == false {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
        traceHandle = tracePath.flatMap { trace in
            guard trace.isEmpty == false else { return nil }
            if FileManager.default.fileExists(atPath: trace) == false {
                FileManager.default.createFile(atPath: trace, contents: nil)
            }
            let handle = FileHandle(forWritingAtPath: trace)
            handle?.seekToEndOfFile()
            return handle
        }
        paneIndex = Self.nextPaneIndex
        Self.nextPaneIndex += 1
        windowStartNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    func recordPublish(
        absoluteViewportTopRow: Int,
        isFullDamage: Bool,
        damagedRowCount: Int,
        deliveryCount: UInt64,
        gridRows: Int
    ) {
        publishes += 1
        if isFullDamage { fullDamagePublishes += 1 }
        self.gridRows = gridRows
        // A hard reset restarts the absolute counter and browsing can move it
        // backward; neither is a scroll, so negative deltas contribute zero.
        let lines = lastAbsoluteTopRow.map { max(0, absoluteViewportTopRow - $0) } ?? 0
        lastAbsoluteTopRow = absoluteViewportTopRow
        scrolledLines += lines
        let bucket = Self.bucketUpperBounds.firstIndex { lines <= $0 }
            ?? Self.bucketUpperBounds.count
        bucketCounts[bucket] += 1
        if let traceHandle {
            let line = """
            {"pane":\(paneIndex),\
            "lines":\(lines),\
            "full":\(isFullDamage),\
            "rows":\(damagedRowCount),\
            "deliveries":\(deliveryCount)}

            """
            try? traceHandle.write(contentsOf: Data(line.utf8))
        }
        emitIfWindowElapsed(deliveryCount: deliveryCount)
    }

    /// Flushes the partial window the last publish left open, so a stream that
    /// stops does not lose its final second.
    func flush(deliveryCount: UInt64) {
        emit(deliveryCount: deliveryCount)
        try? handle.close()
        try? traceHandle?.close()
    }

    private func emitIfWindowElapsed(deliveryCount: UInt64) {
        if isDeliveryBaselineSet == false {
            windowStartDeliveryCount = deliveryCount
            isDeliveryBaselineSet = true
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - windowStartNanoseconds >= Self.windowNanoseconds else { return }
        emit(deliveryCount: deliveryCount, now: now)
    }

    private func emit(
        deliveryCount: UInt64,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard publishes > 0 else { return }
        let elapsed = Double(now - windowStartNanoseconds) / 1_000_000_000
        let deliveries = deliveryCount >= windowStartDeliveryCount
            ? deliveryCount - windowStartDeliveryCount
            : 0
        let histogram = zip(Self.bucketLabels, bucketCounts)
            .map { "\"\($0)\":\($1)" }
            .joined(separator: ",")
        let line = """
        {"pane":\(paneIndex),\
        "uptimeSeconds":\(String(format: "%.3f", Double(now) / 1_000_000_000)),\
        "windowSeconds":\(String(format: "%.3f", elapsed)),\
        "deliveries":\(deliveries),\
        "publishes":\(publishes),\
        "fullDamagePublishes":\(fullDamagePublishes),\
        "scrolledLines":\(scrolledLines),\
        "gridRows":\(gridRows),\
        \(histogram)}

        """
        try? handle.write(contentsOf: Data(line.utf8))
        windowStartNanoseconds = now
        windowStartDeliveryCount = deliveryCount
        publishes = 0
        fullDamagePublishes = 0
        scrolledLines = 0
        bucketCounts = [Int](repeating: 0, count: 8)
    }
}
