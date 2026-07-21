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
