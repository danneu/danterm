// Pure row-damage topology helpers shared by drawing and benchmark consumers.

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
