// Pure conversion from explicit point-space geometry to valid terminal dimensions.
import PaneProcessLifecycle

/// Keeps width and height explicit without importing CoreGraphics into the headless target.
public struct TerminalPointSize: Equatable, Sendable {
    /// Horizontal extent in points.
    public let width: Double
    /// Vertical extent in points.
    public let height: Double

    /// Creates an unchecked geometry input that sizing policy validates as one unit.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Floors point-space geometry into a valid grid and rejects unusable sizing inputs.
public func terminalGridDimensions(
    size: TerminalPointSize,
    cellSize: TerminalPointSize
) -> TerminalDimensions? {
    guard size.width.isFinite, size.height.isFinite,
          cellSize.width.isFinite, cellSize.height.isFinite,
          size.width > 0, size.height > 0,
          cellSize.width > 0, cellSize.height > 0
    else {
        return nil
    }

    let columns = (size.width / cellSize.width).rounded(.down)
    let rows = (size.height / cellSize.height).rounded(.down)
    guard columns.isFinite, rows.isFinite,
          columns < Double(Int.max), rows < Double(Int.max)
    else {
        return nil
    }
    return TerminalDimensions(
        columns: max(2, Int(columns)),
        rows: max(1, Int(rows))
    )
}
