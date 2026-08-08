// Canonical bounded logical damage shared by the terminal core and frame consumers.
//
// The representation is words end to end (research/33 T20): rows live in a
// width-bounded bitset from the accumulator through the public seam, so spans and
// row walks come out canonical from a word scan with no set, no hashing, and no
// sort anywhere on the path. Damage additionally carries at most one scroll shift
// (research/33 T9): `(region, delta)` recorded at the scroll site, meaning
// "translate the previously presented frame by `delta` within `region`, then the
// rows are damaged in post-shift coordinates". Consumers that cannot realize a
// translation fold it away with `expandingShift()`; the worst case is region-wide
// row damage, never more than the pre-shift representation published.

/// One recorded viewport translation: the previously presented frame moves by
/// `delta` rows within `region`, before row damage applies.
///
/// Producers maintain `0 < abs(delta) < region.count`; a shift that vacates its
/// whole region is recorded as region-wide row damage instead, so a carried
/// shift always describes a translation with survivors.
public struct TerminalDamageShift: Equatable, Sendable {
    public let region: Range<Int>
    public let delta: Int

    public init(region: Range<Int>, delta: Int) {
        self.region = region
        self.delta = delta
    }
}

/// Accumulates the viewport rows a consumer must redraw plus at most one scroll
/// translation, escalating to one full-frame marker when neither can express a
/// mutation safely.
public struct TerminalDamage: Equatable, Sendable {
    /// Represents a drained accumulator with no redraw work.
    public static let none = TerminalDamage(isFull: false)

    /// Represents damage that cannot be expressed safely as a shift plus rows.
    public static let full = TerminalDamage(isFull: true)

    /// True when consumers must ignore the shift and row damage and redraw the
    /// complete frame. Full damage carries no shift and no rows.
    public private(set) var isFull: Bool

    /// The translation to apply to the previously presented frame before row
    /// damage, or nil when rows alone describe the delta.
    public private(set) var shift: TerminalDamageShift?

    private var bits: TerminalDamageRowBits

    /// Creates bounded row damage; every row must lie in `0..<rowCount`.
    public init(rows: some Sequence<Int>, rowCount: Int) {
        isFull = false
        shift = nil
        bits = TerminalDamageRowBits(rowCount: rowCount)
        for row in rows {
            precondition(
                row >= 0 && row < rowCount,
                "damage row \(row) is outside 0..<\(rowCount)"
            )
            _ = bits.insert(row)
        }
    }

    /// Creates row damage sized to its own largest row, for consumers with no
    /// grid at hand (tests, fixtures). Negative rows are unrepresentable.
    public init(rows: some Sequence<Int>) {
        let bound = rows.reduce(into: 0) { partial, row in
            precondition(row >= 0, "damage row \(row) is negative")
            partial = Swift.max(partial, row + 1)
        }
        self.init(rows: rows, rowCount: bound)
    }

    private init(isFull: Bool) {
        self.isFull = isFull
        shift = nil
        bits = TerminalDamageRowBits(rowCount: 0)
    }

    init(bits: TerminalDamageRowBits, shift: TerminalDamageShift?) {
        isFull = false
        self.bits = bits
        self.shift = shift
    }

    /// True when this value carries no work at all.
    public var isEmpty: Bool {
        isFull == false && shift == nil && bits.isEmpty
    }

    /// Number of damaged rows, excluding rows only the shift describes.
    public var damagedRowCount: Int {
        bits.count
    }

    public func contains(row: Int) -> Bool {
        bits.contains(row)
    }

    /// Damaged rows in ascending order. A materializing convenience for tests
    /// and diagnostics; hot paths use `forEachRow` or `maximalContiguousSpans`.
    public var rowIndices: [Int] {
        var rows: [Int] = []
        rows.reserveCapacity(bits.count)
        bits.forEachRow { rows.append($0) }
        return rows
    }

    /// Visits every damaged row in ascending order.
    public func forEachRow(_ body: (Int) -> Void) {
        bits.forEachRow(body)
    }

    /// Coalesces adjacent damaged rows into the fewest exact vertical clip
    /// spans, in ascending order straight from the word scan.
    public func maximalContiguousSpans() -> [Range<Int>] {
        bits.maximalContiguousSpans()
    }

    /// Counts the disjoint vertical runs a renderer must represent.
    public var maximalContiguousSpanCount: Int {
        bits.maximalContiguousSpanCount
    }

    /// Expands row damage so unclipped glyph ink crossing a row boundary is
    /// repainted. Shift-free values only: fold the shift first.
    public func withGlyphHalo(rowCount: Int) -> TerminalDamage {
        precondition(shift == nil, "halo a folded value; a shift is not row damage")
        guard isFull == false else { return .full }
        return TerminalDamage(bits: bits.haloed(rowCount: rowCount), shift: nil)
    }

    /// Folds the shift into region-wide row damage for consumers that cannot
    /// realize a translation. Identity on shift-free values.
    public func expandingShift() -> TerminalDamage {
        guard let shift else { return self }
        var folded = bits
        folded.fill(shift.region)
        return TerminalDamage(bits: folded, shift: nil)
    }

    /// Coalesces later damage without retaining an event-by-event queue.
    ///
    /// `later` must be the newer value: its shift translates the rows already
    /// pending here, per the composition contract in research/33 D7 -- pending
    /// rows translate within the region and drop when pushed out of it,
    /// same-region shifts sum (collapsing to region rows at the region height),
    /// a region mismatch escalates to `.full`, and `.full` absorbs everything.
    public mutating func formUnion(_ later: TerminalDamage) {
        guard isFull == false else { return }
        if later.isFull {
            self = .full
            return
        }
        if later.isEmpty { return }
        if isEmpty {
            self = later
            return
        }
        guard bits.rowCount == later.bits.rowCount else {
            // Widths differ only across a grid resize, which records `.full` on
            // its own; a mismatch here is a lineage error, so stay safe.
            self = .full
            return
        }
        if let laterShift = later.shift {
            if applyShift(region: laterShift.region, delta: laterShift.delta) == false {
                return
            }
        }
        bits.formUnion(later.bits)
    }

    /// Applies one newer shift on top of whatever is pending. Returns false
    /// after escalating to `.full`.
    private mutating func applyShift(region: Range<Int>, delta: Int) -> Bool {
        let combined: Int
        if let pending = shift {
            guard pending.region == region else {
                self = .full
                return false
            }
            combined = pending.delta + delta
        } else {
            combined = delta
        }
        bits.translate(region: region, by: delta)
        if abs(combined) >= region.count {
            shift = nil
            bits.fill(region)
        } else {
            shift = TerminalDamageShift(region: region, delta: combined)
        }
        return true
    }

    /// Records a scroll translation into this value, translating pending rows.
    /// The producer-side twin of the `formUnion` shift rules.
    public mutating func recordShift(region: Range<Int>, delta: Int) {
        guard isFull == false else { return }
        guard region.isEmpty == false, delta != 0 else { return }
        precondition(
            region.lowerBound >= 0 && region.upperBound <= bits.rowCount,
            "shift region \(region) is outside 0..<\(bits.rowCount)"
        )
        _ = applyShift(region: region, delta: delta)
    }

    public static func == (lhs: TerminalDamage, rhs: TerminalDamage) -> Bool {
        lhs.isFull == rhs.isFull
            && lhs.shift == rhs.shift
            && lhs.bits.sameRows(as: rhs.bits)
    }
}

/// Width-bounded row bitset backing both the accumulator and the public seam.
///
/// `rowCount` is the exact grid height, not a word multiple: an insert at or
/// beyond it is refused, so an out-of-grid row cannot enter the representation.
struct TerminalDamageRowBits: Sendable {
    private(set) var words: [UInt64]
    private(set) var rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
        words = Array(repeating: 0, count: (rowCount + 63) / 64)
    }

    var isEmpty: Bool {
        words.allSatisfy { $0 == 0 }
    }

    var count: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    func contains(_ row: Int) -> Bool {
        guard row >= 0, row < rowCount else { return false }
        return words[row >> 6] & (1 << UInt64(row & 63)) != 0
    }

    /// Inserts a row, refusing anything outside `0..<rowCount`. Returns true
    /// only when the row was newly set, which is what lets the terminal's
    /// consumer-work generation stay quiet on already-damaged rows.
    mutating func insert(_ row: Int) -> Bool {
        guard row >= 0, row < rowCount else { return false }
        let mask: UInt64 = 1 << UInt64(row & 63)
        guard words[row >> 6] & mask == 0 else { return false }
        words[row >> 6] |= mask
        return true
    }

    mutating func removeAll() {
        for index in words.indices {
            words[index] = 0
        }
    }

    mutating func reset(rowCount: Int) {
        self.rowCount = rowCount
        let wordCount = (rowCount + 63) / 64
        if words.count != wordCount {
            words = Array(repeating: 0, count: wordCount)
        } else {
            removeAll()
        }
    }

    mutating func formUnion(_ other: TerminalDamageRowBits) {
        for index in other.words.indices where index < words.count {
            words[index] |= other.words[index]
        }
    }

    /// The bits of `region` that land in word `index`, so region-scoped word
    /// operations never touch a neighbouring row's bit.
    private func regionMask(_ region: Range<Int>, word index: Int) -> UInt64 {
        let wordBase = index << 6
        let low = Swift.max(region.lowerBound - wordBase, 0)
        let high = Swift.min(region.upperBound - wordBase, 64)
        guard low < high else { return 0 }
        let highMask = high == 64 ? UInt64.max : (1 << UInt64(high)) &- 1
        return highMask & ~((1 << UInt64(low)) &- 1)
    }

    mutating func fill(_ region: Range<Int>) {
        let clamped = Swift.max(region.lowerBound, 0)..<Swift.min(region.upperBound, rowCount)
        guard clamped.isEmpty == false else { return }
        for index in (clamped.lowerBound >> 6)...((clamped.upperBound - 1) >> 6) {
            words[index] |= regionMask(clamped, word: index)
        }
    }

    /// Moves every set bit inside `region` by `delta`, dropping bits the move
    /// pushes out of the region. Bits outside the region never move.
    ///
    /// A word-level barrel shift, not a per-row loop: this runs once per scroll
    /// on the drain path, and a per-row spelling paid an array mutation (with
    /// its copy-on-write uniqueness check) per viewport row per scrolled line
    /// -- measured at +19% on `scrollback-stream` before this shape replaced it.
    /// In-place is safe because each written word reads only source words the
    /// iteration order has not overwritten yet: shifting toward higher rows
    /// reads lower words while walking downward, and vice versa, with the
    /// current word read before it is written.
    mutating func translate(region: Range<Int>, by delta: Int) {
        guard delta != 0, isEmpty == false else { return }
        func source(_ index: Int) -> UInt64 {
            guard index >= 0, index < words.count else { return 0 }
            return words[index] & regionMask(region, word: index)
        }
        // The 64-bit window of region-masked source bits starting at this
        // word's base row minus `delta`, i.e. the word after translation.
        func shifted(_ index: Int) -> UInt64 {
            let position = (index << 6) - delta
            let word = position >> 6
            let bit = position & 63
            var value = source(word) >> UInt64(bit)
            if bit != 0 { value |= source(word + 1) << UInt64(64 - bit) }
            return value
        }
        func apply(_ index: Int) {
            let mask = regionMask(region, word: index)
            words[index] = (words[index] & ~mask) | (shifted(index) & mask)
        }
        let lowerWord = region.lowerBound >> 6
        let upperWord = (region.upperBound - 1) >> 6
        if delta > 0 {
            var index = upperWord
            while index >= lowerWord {
                apply(index)
                index -= 1
            }
        } else {
            for index in lowerWord...upperWord {
                apply(index)
            }
        }
    }

    /// Visits set rows in ascending order via trailing-zero scans.
    func forEachRow(_ body: (Int) -> Void) {
        for (wordIndex, word) in words.enumerated() {
            var remaining = word
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                body(wordIndex << 6 | bit)
                remaining &= remaining - 1
            }
        }
    }

    func maximalContiguousSpans() -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var openLowerBound: Int?
        var expected = Int.min
        forEachRow { row in
            if row == expected {
                expected += 1
                return
            }
            if let lowerBound = openLowerBound {
                spans.append(lowerBound..<expected)
            }
            openLowerBound = row
            expected = row + 1
        }
        if let lowerBound = openLowerBound {
            spans.append(lowerBound..<expected)
        }
        return spans
    }

    var maximalContiguousSpanCount: Int {
        var count = 0
        var expected = Int.min
        forEachRow { row in
            if row != expected { count += 1 }
            expected = row + 1
        }
        return count
    }

    /// `w | w<<1 | w>>1` across word boundaries, clamped to `rowCount` rows.
    ///
    /// Clamping is pure truncation: row 0's upward halo and the last row's
    /// downward halo land on rows already in the set, so bits shifted past
    /// either edge are simply dropped -- underflow falls off the word, and the
    /// tail mask removes overflow past `rowCount`.
    func haloed(rowCount: Int) -> TerminalDamageRowBits {
        var result = TerminalDamageRowBits(rowCount: rowCount)
        for index in result.words.indices {
            let word = index < words.count ? words[index] : 0
            let previous = index > 0 && index - 1 < words.count ? words[index - 1] : 0
            let next = index + 1 < words.count ? words[index + 1] : 0
            result.words[index] = word
                | (word << 1) | (previous >> 63)
                | (word >> 1) | (next << 63)
        }
        if let last = result.words.indices.last {
            let overhang = (result.words.count << 6) - rowCount
            if overhang > 0 {
                result.words[last] &= UInt64.max >> UInt64(overhang)
            }
        }
        return result
    }

    /// Set equality independent of storage width, for the public seam's
    /// semantic `==` where `.none` has no grid to size against.
    func sameRows(as other: TerminalDamageRowBits) -> Bool {
        let shared = Swift.min(words.count, other.words.count)
        for index in 0..<shared where words[index] != other.words[index] {
            return false
        }
        for index in shared..<words.count where words[index] != 0 {
            return false
        }
        for index in shared..<other.words.count where other.words[index] != 0 {
            return false
        }
        return true
    }
}

/// Keeps hot-path damage in reusable words plus one pending shift until a
/// consumer requests the public value.
struct TerminalDamageAccumulator: Equatable, Sendable {
    private var isFull: Bool
    private var shift: TerminalDamageShift?
    private var bits: TerminalDamageRowBits

    init(rowCount: Int, isFull: Bool = false) {
        self.isFull = isFull
        shift = nil
        bits = TerminalDamageRowBits(rowCount: rowCount)
    }

    var hasDamage: Bool {
        isFull || shift != nil || bits.isEmpty == false
    }

    /// True once the accumulator already tells a consumer to redraw everything.
    ///
    /// The scroll site uses this to stop paying per-scroll shift bookkeeping in
    /// the flood regime: with every viewport row pending, a further translation
    /// carries no information any consumer can act on, and `.full` is the same
    /// value spelled in one bit.
    func coversViewport(rowCount: Int) -> Bool {
        if isFull { return true }
        guard rowCount > 0, bits.rowCount >= rowCount else { return false }
        let fullWords = rowCount >> 6
        for index in 0..<fullWords where bits.words[index] != .max {
            return false
        }
        let remainder = rowCount & 63
        if remainder != 0 {
            let mask: UInt64 = (1 << UInt64(remainder)) &- 1
            if bits.words[fullWords] & mask != mask { return false }
        }
        return true
    }

    mutating func recordFull() -> Bool {
        guard isFull == false else { return false }
        isFull = true
        shift = nil
        bits.removeAll()
        return true
    }

    mutating func record(row: Int) -> Bool {
        guard isFull == false else { return false }
        return bits.insert(row)
    }

    mutating func record(rows: some Sequence<Int>) -> Bool {
        guard isFull == false else { return false }
        var changed = false
        for row in rows {
            changed = bits.insert(row) || changed
        }
        return changed
    }

    /// Records a scroll translation, composing with whatever is pending per the
    /// contract on `TerminalDamage.formUnion`. The caller guarantees
    /// `0 < abs(delta) < region.count` and `region` within the grid.
    mutating func recordShift(region: Range<Int>, delta: Int) -> Bool {
        guard isFull == false else { return false }
        guard region.isEmpty == false, delta != 0 else { return false }
        if let pending = shift {
            guard pending.region == region else { return recordFull() }
            let combined = pending.delta + delta
            bits.translate(region: region, by: delta)
            if abs(combined) >= region.count {
                shift = nil
                bits.fill(region)
            } else {
                shift = TerminalDamageShift(region: region, delta: combined)
            }
        } else {
            bits.translate(region: region, by: delta)
            if abs(delta) >= region.count {
                bits.fill(region)
            } else {
                shift = TerminalDamageShift(region: region, delta: delta)
            }
        }
        return true
    }

    mutating func reset(rowCount: Int, isFull: Bool) {
        self.isFull = isFull
        shift = nil
        bits.reset(rowCount: rowCount)
    }

    mutating func drain() -> TerminalDamage {
        if isFull {
            isFull = false
            return .full
        }
        if shift == nil, bits.isEmpty {
            return .none
        }
        let drained = TerminalDamage(bits: bits, shift: shift)
        shift = nil
        bits.removeAll()
        return drained
    }

    static func == (lhs: TerminalDamageAccumulator, rhs: TerminalDamageAccumulator) -> Bool {
        lhs.isFull == rhs.isFull
            && lhs.shift == rhs.shift
            && lhs.bits.sameRows(as: rhs.bits)
    }
}
