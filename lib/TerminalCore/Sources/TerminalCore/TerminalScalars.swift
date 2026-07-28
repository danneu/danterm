// The scalar payload of a single terminal cell, stored inline for the empty and
// one-scalar cases and spilled to an array only for real grapheme clusters.
//
// This exists because the payload is carried by value along the entire hot path -- the
// grid stores it, `Terminal.cell` hands it out, the frame planner copies it into
// `PlannedCell`, and it is retained by the public `RenderTextCell` for as long as the
// frame plan lives. A plain `[Unicode.Scalar]` costs one heap allocation per non-empty
// cell on every replanned row, which at a full viewport is roughly twelve thousand
// allocations per frame for payloads that are almost always exactly one scalar.
//
// It presents as an ordinary `RandomAccessCollection` of scalars so callers neither know
// nor care which case holds the content. That disguise is load-bearing: equality is
// defined element-wise rather than derived from the storage case, because the whole
// render plan is `Equatable` and compared as a value, and identical content reaching a
// cell by different routes must compare equal.
//
// Belongs here rather than beside `TerminalCell` because both the terminal grid and the
// render plan depend on it, and neither owns it.

/// Cell scalar content that avoids the heap for the empty and single-scalar cases the
/// grid is overwhelmingly made of, while still holding arbitrary grapheme clusters.
public struct TerminalScalars: Sendable {
    /// Mirrors the three shapes a cell payload actually takes. Private so that the case
    /// distinction can never leak into behavior callers might come to depend on.
    private enum Storage: Sendable {
        case empty
        case single(Unicode.Scalar)
        case spill([Unicode.Scalar])
    }

    private var storage: Storage

    /// An empty payload, which is what padding and never-written cells carry.
    public static let empty = TerminalScalars()

    public init() {
        storage = .empty
    }

    /// Wraps a single scalar without touching the heap.
    public init(_ scalar: Unicode.Scalar) {
        storage = .single(scalar)
    }

    public init(_ scalars: [Unicode.Scalar]) {
        switch scalars.count {
        case 0: storage = .empty
        case 1: storage = .single(scalars[0])
        default: storage = .spill(scalars)
        }
    }

    public init(_ scalars: some Sequence<Unicode.Scalar>) {
        self.init(Array(scalars))
    }

    /// Builds a single-scalar payload, spelled as a case so grid call sites that
    /// conceptually write one scalar read the same as they did against raw storage.
    public static func single(_ scalar: Unicode.Scalar) -> TerminalScalars {
        TerminalScalars(scalar)
    }

    /// Appends one scalar, promoting inline storage to a spill exactly when it overflows.
    mutating func append(_ scalar: Unicode.Scalar) {
        switch storage {
        case .empty:
            storage = .single(scalar)
        case let .single(first):
            storage = .spill([first, scalar])
        case let .spill(existing):
            // Release the enum's reference before appending so a uniquely referenced
            // spill grows in place instead of copying its buffer.
            storage = .empty
            var scalars = existing
            scalars.append(scalar)
            storage = .spill(scalars)
        }
    }
}

extension TerminalScalars: RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = Unicode.Scalar

    public var startIndex: Int { 0 }

    public var endIndex: Int {
        switch storage {
        case .empty: 0
        case .single: 1
        case let .spill(scalars): scalars.count
        }
    }

    public subscript(position: Int) -> Unicode.Scalar {
        switch storage {
        case .empty:
            preconditionFailure("empty cell scalar storage has no valid index")
        case let .single(scalar):
            precondition(position == 0, "single cell scalar storage index out of bounds")
            return scalar
        case let .spill(scalars):
            return scalars[position]
        }
    }
}

extension TerminalScalars: Equatable {
    /// Compares contents, never storage. A one-scalar payload built inline and the same
    /// scalar arriving through the array initializer are the same payload, and the
    /// render plan's own `Equatable` conformance depends on that being true.
    public static func == (lhs: TerminalScalars, rhs: TerminalScalars) -> Bool {
        lhs.elementsEqual(rhs)
    }
}

extension TerminalScalars: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Unicode.Scalar...) {
        self.init(elements)
    }
}

extension TerminalScalars: CustomStringConvertible {
    public var description: String {
        String(String.UnicodeScalarView(self))
    }
}
