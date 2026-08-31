// AppKit-free wheel normalization that preserves fractional motion for owner-side routing.

/// Converts native wheel units to rows without retaining cross-event routing state in the view.
public struct TerminalWheelNormalizer: Equatable, Sendable {
    private let lineRowsPerUnit: Double

    /// Pins line-wheel sensitivity while allowing deterministic policy tests to choose a scale.
    public init(lineRowsPerUnit: Double = 3) {
        self.lineRowsPerUnit = lineRowsPerUnit.isFinite && lineRowsPerUnit > 0
            ? lineRowsPerUnit
            : 3
    }

    /// Converts one wheel delta to signed rows; positive AppKit deltas move toward older rows.
    public func rows(
        delta: Double,
        isPrecise: Bool,
        cellHeight: Double
    ) -> Double {
        guard delta.isFinite else { return 0 }
        let scaledRows: Double
        if isPrecise {
            guard cellHeight.isFinite, cellHeight > 0 else { return 0 }
            scaledRows = -delta / cellHeight
        } else {
            scaledRows = -delta * lineRowsPerUnit
        }
        return scaledRows.isFinite ? scaledRows : 0
    }

    /// Converts one horizontal wheel delta to signed columns for mouse reporting.
    public func columns(
        delta: Double,
        isPrecise: Bool,
        cellWidth: Double
    ) -> Double {
        guard delta.isFinite else { return 0 }
        let scaledColumns: Double
        if isPrecise {
            guard cellWidth.isFinite, cellWidth > 0 else { return 0 }
            scaledColumns = delta / cellWidth
        } else {
            scaledColumns = delta * lineRowsPerUnit
        }
        return scaledColumns.isFinite ? scaledColumns : 0
    }
}
