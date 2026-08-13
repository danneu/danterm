// The vocabulary of the pane-tape record stream: its version, its two payload formats, its two
// capture shapes, and the reasons a producer can state for stopping. It lives at the protocol
// boundary because the producer and every reader must agree on these spellings; the record
// values themselves are built in DanTermSupport, and derived views in the CLI.
import Foundation

/// The stream contract producers emit and readers key their expectations off. It moves whenever
/// a record's shape or vocabulary changes.
public let paneTapeStreamVersion = 2

/// Names the payload representation a stream carries.
public enum PaneTapeFormat: String, Sendable {
    /// Exact bytes, base64-encoded, suitable for replay and for fixture conversion.
    case replay
    /// Structured spans derived from the replay payload, for reading rather than replaying.
    case inspect
}

/// Distinguishes the two captures so a reader can demand the terminator a finite dump always
/// has, and accept EOF only where a follow stream can legitimately stop.
public enum PaneTapeCaptureMode: String, Sendable {
    /// One atomic fence of the retained tape, which always ends with `snapshot-complete`.
    case snapshot
    /// A live stream that ends when the pane closes, when DanTerm cannot keep it going, or at
    /// EOF if the app stops abruptly.
    case follow
}

/// Every clean reason a producer can state for a stream it stopped on purpose. A stream that
/// ends at EOF states no reason, which is why the follow capture admits that ending and the
/// snapshot capture does not.
public enum PaneTapeEndReason: String, Sendable {
    case snapshotComplete = "snapshot-complete"
    case paneClosed = "pane-closed"
    case streamFailed = "stream-failed"
}
