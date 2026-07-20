// AppKit-free wheel normalization that converts pixel or line deltas into stable row steps.

/// Carries fractional wheel motion between events so the terminal viewport remains row-quantized.
public struct TerminalWheelAccumulator: Equatable, Sendable {
    private var remainderRows = 0.0
    private let lineRowsPerUnit: Double

    /// Pins line-wheel sensitivity while allowing deterministic policy tests to choose a scale.
    public init(lineRowsPerUnit: Double = 3) {
        self.lineRowsPerUnit = lineRowsPerUnit.isFinite && lineRowsPerUnit > 0
            ? lineRowsPerUnit
            : 3
    }

    /// Converts one wheel delta to signed rows; positive AppKit deltas move toward older rows.
    public mutating func consume(
        delta: Double,
        isPrecise: Bool,
        cellHeight: Double
    ) -> Int {
        guard delta.isFinite else { return 0 }
        let scaledRows: Double
        if isPrecise {
            guard cellHeight.isFinite, cellHeight > 0 else { return 0 }
            scaledRows = -delta / cellHeight
        } else {
            scaledRows = -delta * lineRowsPerUnit
        }
        guard scaledRows.isFinite else { return 0 }

        let accumulated = remainderRows + scaledRows
        if accumulated >= Double(Int.max) {
            remainderRows = 0
            return Int.max
        }
        if accumulated <= Double(Int.min) {
            remainderRows = 0
            return Int.min
        }
        let rows = Int(accumulated.rounded(.towardZero))
        remainderRows = accumulated - Double(rows)
        return rows
    }
}
