// Live presentation-rate sampler for one pane. It exists only to answer, in a
// running app, "how many frames per second does a real pane publish, how many
// of those actually render into the owned surface, and how often does AppKit
// ask the layer to display" -- which no benchmark artifact can report, because
// those capture totals at draw boundaries only.
//
// The three counters are deliberately independent rather than a ratio
// (research/33 T25 PO5): with the draw seam deleted, a publishes-per-draw
// ratio would read 1.0 by construction and detect nothing. Renders above
// publications, or renders tracking layer displays, are what a regression
// would look like here.
//
// Not a general metrics facility: it owns two counters the engine does not
// already keep (renders, layer displays), reads the delivery count the session
// controller already keeps, and writes a line per elapsed window. Nothing else
// belongs here -- a second question wants its own instrument, not a field on
// this one.
import Foundation

/// Appends one JSON line per sampling window so an external script can read
/// publishes/s, renders/s and layer displays/s off a live pane without
/// attaching a profiler.
///
/// Created only when `DANTERM_FRAME_RATE_LOG` names a file, so an ordinary run
/// pays one optional test per publish, render and layer display and nothing
/// else. Owned by the view whose frames it counts, and it starts and stops with
/// that view: it holds no timer, no observer, and no reference back to its
/// owner.
@MainActor
final class TerminalFrameRateSampler {
    /// Names the file to append to. Forwarded into a development slot with
    /// `./scripts/dev-slot-launcher.py --pass-env DANTERM_FRAME_RATE_LOG`.
    static let environmentVariable = "DANTERM_FRAME_RATE_LOG"

    private static let windowNanoseconds: UInt64 = 1_000_000_000
    private static var nextPaneIndex = 0

    private let handle: FileHandle
    private let paneIndex: Int
    private var windowStartNanoseconds: UInt64
    private var windowStartDeliveryCount: UInt64 = 0
    /// False until the first sample supplies a delivery count, so the first
    /// window reports deliveries measured from its own start, not from zero.
    private var isDeliveryBaselineSet = false
    private var publishes = 0
    private var renders = 0
    private var layerDisplays = 0

    /// Returns a sampler only when the environment asked for one, so the call
    /// site stays a single `let sampler = TerminalFrameRateSampler.make()`.
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalFrameRateSampler? {
        guard let path = environment[environmentVariable], path.isEmpty == false else {
            return nil
        }
        return TerminalFrameRateSampler(path: path)
    }

    private init?(path: String) {
        guard let descriptor = try? PrivateFile.openForAppending(
            at: URL(fileURLWithPath: path)
        ) else { return nil }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        paneIndex = Self.nextPaneIndex
        Self.nextPaneIndex += 1
        windowStartNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    func recordPublish(deliveryCount: UInt64) {
        publishes += 1
        emitIfWindowElapsed(deliveryCount: deliveryCount)
    }

    func recordRender(deliveryCount: UInt64) {
        renders += 1
        emitIfWindowElapsed(deliveryCount: deliveryCount)
    }

    func recordLayerDisplay(deliveryCount: UInt64) {
        layerDisplays += 1
        emitIfWindowElapsed(deliveryCount: deliveryCount)
    }

    /// Flushes the partial window the last sample left open, so a stream that
    /// stops does not lose its final second.
    func flush(deliveryCount: UInt64) {
        emit(deliveryCount: deliveryCount)
        try? handle.close()
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
        guard publishes > 0 || renders > 0 || layerDisplays > 0 else { return }
        let elapsed = Double(now - windowStartNanoseconds) / 1_000_000_000
        let deliveries = deliveryCount >= windowStartDeliveryCount
            ? deliveryCount - windowStartDeliveryCount
            : 0
        let line = """
        {"pane":\(paneIndex),\
        "uptimeSeconds":\(String(format: "%.3f", Double(now) / 1_000_000_000)),\
        "windowSeconds":\(String(format: "%.3f", elapsed)),\
        "deliveries":\(deliveries),\
        "publishes":\(publishes),\
        "renders":\(renders),\
        "layerDisplays":\(layerDisplays)}

        """
        try? handle.write(contentsOf: Data(line.utf8))
        windowStartNanoseconds = now
        windowStartDeliveryCount = deliveryCount
        publishes = 0
        renders = 0
        layerDisplays = 0
    }
}
