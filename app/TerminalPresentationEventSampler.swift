// Per-event presentation trace for one pane. It exists only to answer "how long
// after a pane is told to show does a frame reach its layer", which no window
// aggregate can answer: TerminalFrameRateSampler sums a second of publishes,
// renders and layer displays, and the reveal this question is about happens
// once, inside one of those windows, against a frame arrival the window has
// already averaged away.
//
// Not a general metrics facility, per the rule TerminalFrameRateSampler set:
// this instrument owns one question and writes one line per event -- a
// monotonic timestamp and what happened -- so a reader pairs the events itself.
// A second question wants its own instrument, not a field on this one.
import Foundation
import PrivateFile

/// Appends one JSON line per presentation event of one pane -- the view's
/// creation, each visibility transition, and every frame that reaches the layer
/// -- so an external script can read reveal-to-first-frame latency off a live
/// app without attaching a profiler.
///
/// Created only when `DANTERM_PRESENTATION_EVENT_LOG` names a file, so an
/// ordinary run pays one optional test per event and nothing else. Owned by the
/// view whose events it records, and it starts and stops with that view: it
/// holds no timer, no observer, and no reference back to its owner.
@MainActor
final class TerminalPresentationEventSampler {
    /// The moments a reader pairs. `reveal` and `hide` are recorded only
    /// for a transition, so a redundant push of the visibility a pane already
    /// has stays distinguishable from a real reveal -- which is the difference
    /// between a switch that has presentation work to do and one that does not.
    enum Event: String {
        case create
        case reveal
        case hide
        /// The pane threw its swapchain away, so the next `attach` is a
        /// from-scratch presentation: fresh buffers and a full render, not a
        /// damage-shaped update into a rotation that already exists.
        case rebuild
        case attach
    }

    /// Names the file to append to. Forwarded into a development slot with
    /// `./scripts/dev-slot-launcher.py --pass-env DANTERM_PRESENTATION_EVENT_LOG`.
    static let environmentVariable = "DANTERM_PRESENTATION_EVENT_LOG"

    private static var nextPaneIndex = 0

    private let handle: FileHandle
    private let paneIndex: Int

    /// Returns a sampler only when the environment asked for one, so the call
    /// site stays a single `let sampler = TerminalPresentationEventSampler.make()`.
    static func make(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalPresentationEventSampler? {
        guard let path = environment[environmentVariable], path.isEmpty == false else {
            return nil
        }
        return TerminalPresentationEventSampler(path: path)
    }

    private init?(path: String) {
        guard let descriptor = try? PrivateFile.openForAppending(
            at: URL(fileURLWithPath: path)
        ) else { return nil }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        paneIndex = Self.nextPaneIndex
        Self.nextPaneIndex += 1
    }

    /// Writes one event immediately rather than buffering it: the reader is
    /// interested in the gap between two events, and a buffer would put this
    /// instrument's own flush inside that gap.
    ///
    /// The clock is `DispatchTime`'s uptime, the same monotonic source the
    /// pane's publish deadline is paced by, so a trace and a frame-rate log
    /// taken in one run share an axis.
    func record(
        _ event: Event,
        at uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let line = """
        {"pane":\(paneIndex),\
        "uptimeNanoseconds":\(uptimeNanoseconds),\
        "event":"\(event.rawValue)"}

        """
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// Releases the descriptor when the pane goes away. Nothing is buffered, so
    /// there is no last line to lose.
    func close() {
        try? handle.close()
    }
}
