// Projections of one pane's flight tape, for tests that used to read the host's parallel
// capture buffers. Nothing here decides anything: each read is a filter over the same log the
// pane ships in production, so a test and a live reader see one record of what the pane did.
import TerminalCoreRecording
import TerminalPTYHost

extension TerminalPTYHost {
    /// Every retained transition in the order the owner applied it.
    public nonisolated func tapeEvents() -> [NeutralTerminalRecordingEvent] {
        fencedFlightRecordingCapture().snapshot.events.map(\.event)
    }

    /// Writes whose bytes the pane itself chose: its launch line, user input, its own reports.
    /// A terminal reply looks identical on the wire, so only the recorded attribution can
    /// separate the two.
    public nonisolated func inputWrites() -> [[UInt8]] {
        tapeWrites { $0 != .reply }
    }

    /// Writes that carry what somebody did to this pane, excluding the pane's own reports.
    public nonisolated func userWrites() -> [[UInt8]] {
        tapeWrites { $0 == .user }
    }

    /// Writes the terminal generated to answer a query the child asked.
    public nonisolated func replyWrites() -> [[UInt8]] {
        tapeWrites { $0 == .reply }
    }

    /// The shared-queue order of user submissions: the writes somebody's action chose, and the
    /// resizes the owner applied. Feeds and terminal replies are the child's traffic, not
    /// submissions, so they stay out of it.
    public nonisolated func tapeSubmissions() -> [NeutralTerminalRecordingEvent] {
        fencedFlightRecordingCapture().snapshot.events.compactMap { recorded in
            switch recorded.event {
            case .write: recorded.writeAttribution == .user ? recorded.event : nil
            case .resize: recorded.event
            default: nil
            }
        }
    }

    /// Every feed byte the tape retained, concatenated into the child's output stream.
    public nonisolated func outputBytes() -> [UInt8] {
        tapeEvents().reduce(into: [UInt8]()) { bytes, event in
            guard case .feed(let chunk) = event else { return }
            bytes.append(contentsOf: chunk)
        }
    }

    private nonisolated func tapeWrites(
        where include: (TerminalFlightRecordingWriteAttribution) -> Bool
    ) -> [[UInt8]] {
        fencedFlightRecordingCapture().snapshot.events.compactMap { recorded in
            guard case .write(let bytes) = recorded.event,
                  let attribution = recorded.writeAttribution,
                  include(attribution)
            else { return nil }
            return bytes
        }
    }
}
