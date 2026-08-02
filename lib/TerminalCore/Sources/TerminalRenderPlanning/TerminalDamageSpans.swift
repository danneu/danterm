// Pure row-damage topology helpers shared by drawing and benchmark consumers.

/// Expands partial row damage so unclipped glyph ink crossing a row boundary is repainted.
public func terminalDamageRowsWithGlyphHalo(_ rows: Set<Int>, rowCount: Int) -> Set<Int> {
    guard rowCount > 0 else { return [] }
    var expanded: Set<Int> = []
    for row in rows where row >= 0 && row < rowCount {
        expanded.insert(max(0, row - 1))
        expanded.insert(row)
        expanded.insert(min(rowCount - 1, row + 1))
    }
    return expanded
}

/// Counts the disjoint vertical runs a renderer must represent for exact row damage.
public func terminalDamageMaximalContiguousSpanCount(_ rows: Set<Int>) -> Int {
    rows.reduce(into: 0) { count, row in
        if row == Int.min || rows.contains(row - 1) == false {
            count += 1
        }
    }
}

/// Coalesces adjacent damaged rows into the fewest exact vertical clip spans.
public func terminalDamageMaximalContiguousSpans(_ rows: Set<Int>) -> [Range<Int>] {
    let sortedRows = rows.sorted()
    guard let firstRow = sortedRows.first else { return [] }
    var spans: [Range<Int>] = []
    var lowerBound = firstRow
    var upperBound = firstRow + 1
    for row in sortedRows.dropFirst() {
        if row == upperBound {
            upperBound += 1
        } else {
            spans.append(lowerBound..<upperBound)
            lowerBound = row
            upperBound = row + 1
        }
    }
    spans.append(lowerBound..<upperBound)
    return spans
}
