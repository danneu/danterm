// The permanent, on-demand answer to "what is the grid holding, and in what shape".
//
// This exists because the alternative kept being: widen `Terminal`'s `private` grid types for one
// measurement, walk them, record a number, and revert. Doc 12's F1 and F3 were both taken that way,
// which is why neither can be re-run, re-checked, or refreshed after the code moved underneath
// them. A census that ships means any agent can re-derive those numbers in one call, and a memory
// claim can cite something reproducible.
//
// What belongs here is the *shape* of the census -- the value type a caller reasons about, and the
// arithmetic that is safe to do on it. What does not belong here is the walk that fills it in: that
// needs `Terminal`'s private `GridCell`/`GridRow`, so it lives in Terminal.swift beside the other
// introspection accessors. Keeping the type out here is what lets it be `public`, and therefore
// usable from the headless memory probe, without widening anything.
//
// Deliberately reports *exact* bytes from `MemoryLayout` stride rather than anything derived from
// `heap` or `footprint`. Those report malloc bucket sizes and process pages respectively; neither
// is the question this type answers, and conflating them has already produced two wrong numbers in
// doc 15 (its F1 uncertainty and its F4 inference 2).
//
// No imports: `TerminalCore` is enforced import-free by `scripts/core-purity-lint.sh`, and
// everything here (`Codable`, `MemoryLayout`) is standard library.

/// A point-in-time accounting of the cell storage one `Terminal` owns, in exact bytes.
///
/// Every count covers the whole grid -- scrollback plus the live screen plus, when the alternate
/// screen is active, the retained primary screen -- because that is the set a process actually
/// holds. Fields that exist to size a specific hypothesis say so.
public struct TerminalMemoryCensus: Equatable, Sendable, Codable {
    /// Rows in the live screen. Equals the terminal's row count except under the alternate screen,
    /// where the retained primary screen is counted too and this exceeds it.
    public var screenRowCount: Int

    /// Rows retained in history, after budget eviction.
    public var scrollbackRowCount: Int

    /// Cells physically stored across the whole grid; compact history rows may be narrower.
    public var cellCount: Int

    /// `MemoryLayout<GridCell>.stride` -- what a cell costs *in an array*, which is the only way
    /// cells are ever stored. Not `size`: array storage is strided, and the difference is the
    /// padding doc 12's F1 measured as 65 vs 72.
    public var cellStrideBytes: Int

    /// Exact bytes of cell storage: the sum over rows of `cells.count * stride`. Excludes malloc
    /// bucket rounding and the array headers, which are counted separately below so that a caller
    /// can attribute them rather than silently absorb them.
    public var cellStorageBytes: Int

    /// Separate heap allocations backing rows -- one per row with cells. Doc 15's H7 is about the
    /// per-allocation overhead this number multiplies.
    public var rowStorageAllocationCount: Int

    /// Rows for which storage is still held. Equals `scrollbackRowCount` unless eviction is
    /// retaining rows it dropped, which is the defect doc 15's F4 found and D1 fixed.
    public var retainedRowStorageRowCount: Int

    /// Cells whose style differs from the default. Sizes doc 15's H3.
    public var styledCellCount: Int

    /// Distinct styles resident across the grid -- the size a deduplicated style table would need.
    /// Sizes doc 15's H3.
    public var distinctStyleCount: Int

    /// Cells holding a multi-scalar grapheme cluster, the only case where a cell owns a
    /// reference-counted allocation of its own.
    public var multiScalarCellCount: Int

    /// Class-backed scalar storage allocations, one per multi-scalar cell.
    public var multiScalarAllocationCount: Int

    /// Cells carrying a hyperlink id. Sizes doc 15's H2: doc 12's F3 found this zero across all
    /// four fixture workloads.
    public var hyperlinkCellCount: Int

    /// Cells carrying a content identity. Sizes doc 15's H4.
    public var contentIdentityCellCount: Int

    /// Distinct content identities, which doc 12's F3 found to be near-unique per printed cell --
    /// the observation that killed narrowing the field to 16 bits.
    public var distinctContentIdentityCount: Int

    /// Average bytes per cell. Constant at the stride today; it stops being constant the moment
    /// any hypothesis in doc 15 moves a field out of the cell, which is the point of reporting it.
    public var bytesPerCell: Double {
        cellCount == 0 ? 0 : Double(cellStorageBytes) / Double(cellCount)
    }

    /// True when history holds cell storage for rows it no longer reports.
    ///
    /// A census that could not see this could report a confidently wrong number, since the waste
    /// is invisible to the byte budget -- exactly what happened before doc 15's D1.
    public var hasRetainedRowStorageLeak: Bool {
        retainedRowStorageRowCount > scrollbackRowCount
    }
}
