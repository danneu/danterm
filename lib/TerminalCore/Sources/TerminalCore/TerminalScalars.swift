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
//
// Why the accessors are inlinable. This type lives in `TerminalCore`, but its hottest
// consumers -- `TerminalRenderPlanning`, `TerminalRenderExecution` -- are separate SwiftPM
// targets, and SwiftPM does not specialize a library's generics for another module. Left
// unannotated, every `endIndex` and `subscript` from the render path is an opaque
// cross-module call and the `RandomAccessCollection` conformance is consumed through
// witness tables, which a profile measured at ~5% of main-thread on-CPU time. `@inlinable`
// on the collection surface is what lets a render-side caller see the `Storage` switch,
// and it is the only reason `Storage` is `@usableFromInline` rather than `private`. The
// encapsulation the `private` was protecting is unaffected: no other module can name
// `Storage` either way.

/// Cell scalar content that avoids the heap for the empty and single-scalar cases the
/// grid is overwhelmingly made of, while still holding arbitrary grapheme clusters.
public struct TerminalScalars: Sendable {
    /// Mirrors the three shapes a cell payload actually takes. `@usableFromInline` rather
    /// than `private` only so the accessors below can be `@inlinable`; the case
    /// distinction still cannot leak into behavior, because no other module can name this
    /// type. See the "Why the accessors are inlinable" note above.
    @usableFromInline
    enum Storage: Sendable {
        case empty
        case single(Unicode.Scalar)
        case spill([Unicode.Scalar])
    }

    @usableFromInline
    var storage: Storage

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

    /// Appends only when the resulting UTF-8 payload fits the terminal's retained-cell bound.
    @discardableResult
    mutating func append(_ scalar: Unicode.Scalar, upToUTF8ByteCount limit: Int) -> Bool {
        guard canAppend(scalar, upToUTF8ByteCount: limit) else { return false }
        append(scalar)
        return true
    }

    func canAppend(_ scalar: Unicode.Scalar, upToUTF8ByteCount limit: Int) -> Bool {
        let scalarByteCount = Self.utf8ByteCount(of: scalar)
        return scalarByteCount <= limit
            && reduce(0) { $0 + Self.utf8ByteCount(of: $1) } <= limit - scalarByteCount
    }

    static func utf8ByteCount(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0...0x7F: 1
        case 0x80...0x7FF: 2
        case 0x800...0xFFFF: 3
        default: 4
        }
    }
}

extension TerminalScalars: RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = Unicode.Scalar

    @inlinable
    public var startIndex: Int { 0 }

    @inlinable
    public var endIndex: Int {
        switch storage {
        case .empty: 0
        case .single: 1
        case let .spill(scalars): scalars.count
        }
    }

    @inlinable
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

// Index arithmetic spelled out rather than inherited. The stdlib's defaults for an `Int`
// index are already correct, but they reach this type through its conformance witnesses,
// which another module cannot inline or specialize -- `distance(from:to:)` and
// `underestimatedCount` both showed up as witness-table calls on the render path. These
// bodies are the defaults, made inlinable.
extension TerminalScalars {
    @inlinable
    public var count: Int { endIndex }

    @inlinable
    public var underestimatedCount: Int { endIndex }

    @inlinable
    public func index(after i: Int) -> Int { i + 1 }

    @inlinable
    public func index(before i: Int) -> Int { i - 1 }

    @inlinable
    public func index(_ i: Int, offsetBy distance: Int) -> Int { i + distance }

    @inlinable
    public func distance(from start: Int, to end: Int) -> Int { end - start }
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
