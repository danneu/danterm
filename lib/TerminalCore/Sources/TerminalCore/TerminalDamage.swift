// Canonical bounded logical damage shared by the terminal core and frame consumers.

/// Accumulates the viewport rows a consumer must redraw, escalating to one full-frame marker.
public struct TerminalDamage: Equatable, Sendable {
    /// Represents a drained accumulator with no redraw work.
    public static let none = TerminalDamage()

    /// Represents damage that cannot be expressed safely as viewport rows.
    public static let full = TerminalDamage(isFull: true)

    /// True when consumers must ignore row damage and redraw the complete frame.
    public private(set) var isFull: Bool

    /// Canonical viewport row indexes; always empty when `isFull` is true.
    public private(set) var rows: Set<Int>

    /// Creates bounded row damage while discarding invalid viewport indexes.
    public init(rows: Set<Int>) {
        isFull = false
        self.rows = Set(rows.filter { $0 >= 0 })
    }

    private init(isFull: Bool = false) {
        self.isFull = isFull
        rows = []
    }

    /// Coalesces later mutations without retaining an event-by-event queue.
    public mutating func formUnion(_ other: TerminalDamage) {
        guard isFull == false else { return }
        if other.isFull {
            self = .full
        } else {
            rows.formUnion(other.rows)
        }
    }
}

/// Keeps hot-path row damage in reusable words until a consumer requests the public set.
struct TerminalDamageAccumulator: Equatable, Sendable {
    private var isFull: Bool
    private var words: [UInt64]

    init(rowCount: Int, isFull: Bool = false) {
        self.isFull = isFull
        words = Array(repeating: 0, count: (rowCount + 63) / 64)
    }

    var hasDamage: Bool {
        isFull || words.contains { $0 != 0 }
    }

    mutating func recordFull() {
        isFull = true
        clearWords()
    }

    mutating func record(row: Int) {
        guard isFull == false, row >= 0 else { return }
        let word = row / 64
        guard word < words.count else { return }
        words[word] |= UInt64(1) << UInt64(row % 64)
    }

    mutating func record(rows: some Sequence<Int>) {
        guard isFull == false else { return }
        for row in rows {
            record(row: row)
        }
    }

    mutating func reset(rowCount: Int, isFull: Bool) {
        self.isFull = isFull
        let wordCount = (rowCount + 63) / 64
        if words.count != wordCount {
            words = Array(repeating: 0, count: wordCount)
        } else {
            clearWords()
        }
    }

    mutating func drain() -> TerminalDamage {
        if isFull {
            isFull = false
            clearWords()
            return .full
        }
        var rows = Set<Int>()
        rows.reserveCapacity(words.reduce(0) { $0 + $1.nonzeroBitCount })
        for (wordIndex, word) in words.enumerated() {
            var remaining = word
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                rows.insert(wordIndex * 64 + bit)
                remaining &= remaining - 1
            }
        }
        clearWords()
        return TerminalDamage(rows: rows)
    }

    private mutating func clearWords() {
        for index in words.indices {
            words[index] = 0
        }
    }
}
