// The shared pane-grid override bounds used by protocol documentation and every ingress.

/// Columns a pane-grid override may hold. The floor is the engine's minimum grid width. The
/// ceiling bounds a maximal grid's cell storage in the tens of megabytes and stays far below
/// the PTY's 16-bit winsize ceiling.
public let paneGridOverrideColumnRange: ClosedRange<Int> = 2...1024

/// Rows a pane-grid override may hold, with the engine's one-row floor and the same storage
/// ceiling as `paneGridOverrideColumnRange`.
public let paneGridOverrideRowRange: ClosedRange<Int> = 1...1024
