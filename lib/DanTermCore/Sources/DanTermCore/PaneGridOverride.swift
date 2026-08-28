// The grid a pane runs at when a client has claimed its size. Separate from the
// pane's rectangle, which stays a pure projection of container bounds and split
// ratios.
//
// Rendering, IPC spellings, and PTY submission live elsewhere; this file holds
// only the value that every ingress validates against the protocol's shared bounds.
import DanTermProtocol

/// A grid a client asked a pane to run at, independent of the rectangle the
/// pane occupies. Only in-range grids are representable, so no ingress -- an
/// IPC request, a persisted snapshot -- can store a size the PTY, the engine,
/// and a replica would not all reproduce identically.
struct PaneGridOverride: Equatable, Sendable {
    let columns: Int
    let rows: Int

    /// Fails rather than clamps for an out-of-range grid: a caller that asked
    /// for an impossible size gets an error, and a corrupt snapshot yields no
    /// override at all instead of a size nobody requested.
    init?(columns: Int, rows: Int) {
        guard paneGridOverrideColumnRange.contains(columns),
              paneGridOverrideRowRange.contains(rows)
        else { return nil }
        self.columns = columns
        self.rows = rows
    }
}
