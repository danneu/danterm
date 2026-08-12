// Shared streaming matcher for search producers in the terminal core.

/// Keeps search comparison allocation-free for the common one-scalar key while retaining
/// full folded expansions for Unicode graphemes that need them.
enum SearchGraphemeKey: Equatable, Sendable {
    case scalar(UInt32)
    case scalars([Unicode.Scalar])
}

/// Matches one fixed needle over position-bearing units from any search coordinate system.
struct NeedleWindow<Position: Equatable & Sendable>: Equatable, Sendable {
    /// Couples a folded key to the half-open source boundaries that select it.
    struct Unit: Equatable, Sendable {
        var key: SearchGraphemeKey
        var start: Position
        var end: Position
    }

    /// Carries a completed match without choosing its caller's range representation.
    struct Match: Equatable, Sendable {
        var start: Position
        var end: Position
    }

    private let needleKeys: [SearchGraphemeKey]
    private var window: [Unit?]
    private var unitCount = 0

    init(needleKeys: [SearchGraphemeKey]) {
        precondition(needleKeys.isEmpty == false)
        self.needleKeys = needleKeys
        window = [Unit?](repeating: nil, count: needleKeys.count)
    }

    mutating func join(_ unit: Unit) {
        _ = consume(unit, recordsMatch: false)
    }

    mutating func record(_ unit: Unit) -> Match? {
        consume(unit, recordsMatch: true)
    }

    var trailingUnits: [Unit] {
        let trailingCount = min(max(0, needleKeys.count - 1), unitCount)
        let trailingStart = unitCount - trailingCount
        return (trailingStart..<unitCount).compactMap { window[$0 % needleKeys.count] }
    }

    private mutating func consume(_ unit: Unit, recordsMatch: Bool) -> Match? {
        let slot = unitCount % needleKeys.count
        window[slot] = unit
        unitCount += 1
        guard recordsMatch, unitCount >= needleKeys.count else { return nil }
        let startIndex = unitCount - needleKeys.count
        for offset in needleKeys.indices {
            guard window[(startIndex + offset) % needleKeys.count]?.key == needleKeys[offset]
            else { return nil }
        }
        guard let start = window[startIndex % needleKeys.count]?.start else { return nil }
        return Match(start: start, end: unit.end)
    }
}
