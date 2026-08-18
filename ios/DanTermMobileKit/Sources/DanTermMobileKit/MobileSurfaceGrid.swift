// The grid the phone can show at native cell metrics, and the one request its claim
// gesture sends. Typing and scrolling never reach this file: D6's claim is a deliberate
// gesture, so no other phone action may produce a resize.
import DanTermProtocol

/// Carries the whole-cell grid one phone surface runs at, so the claim gesture has a
/// single value to compute and to send. It is constructed from backing pixels rather
/// than points because the cell box is quantized to whole pixels, and a point-derived
/// count can name a cell column the surface cannot draw.
public struct MobileSurfaceGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    /// Returns nil when the surface has no room for a whole cell on either axis, which
    /// is the one state with no honest claim to make.
    public init?(widthPixels: Int, heightPixels: Int, cellWidthPixels: Int, cellHeightPixels: Int) {
        guard cellWidthPixels > 0, cellHeightPixels > 0 else { return nil }
        let columns = widthPixels / cellWidthPixels
        let rows = heightPixels / cellHeightPixels
        guard columns > 0, rows > 0 else { return nil }
        self.columns = columns
        self.rows = rows
    }

    /// The claim gesture's entire wire effect: one ordinary last-writer-wins resize. It
    /// carries no client identity and takes no lock, so a second claimer simply replaces
    /// this grid.
    public func claimRequest(for pane: PaneId) -> IpcRequest {
        .paneResize(pane: pane, resize: .grid(columns: columns, rows: rows))
    }
}
