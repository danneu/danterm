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

    /// Display rows retained history folds to at the current width, after budget eviction.
    ///
    /// Derived rather than stored since doc 31: history holds one record per logical line, and a
    /// display row is what a width makes of one. A narrower pane reports more of these for the
    /// same retained content, and evicts none of it (`31/I3`).
    public var scrollbackRowCount: Int

    /// Logical lines retained in history -- the unit the store actually holds, and the one that
    /// does not move when the pane is resized.
    public var scrollbackRecordCount: Int

    /// Cells physically stored across the whole grid; compact history rows may be narrower.
    ///
    /// Still a cell count after doc 28's packing, and deliberately so: a retained row stores
    /// the same *cells* it always did, in a different shape. What changed is what those cells
    /// cost, which is `cellStorageBytes` -- so a reader that wants "how much content" reads
    /// this, and one that wants "how many bytes" reads that, and packing moves only the second.
    public var cellCount: Int

    /// `MemoryLayout<GridCell>.stride` -- what a cell costs *in an array*, which is the only way
    /// *live* cells are ever stored. Not `size`: array storage is strided, and the difference is
    /// the padding doc 12's F1 measured as 65 vs 72.
    ///
    /// Applies to the live screens only since doc 28's packing. A retained row does not store
    /// `GridCell`s at all, so multiplying a retained cell count by this stride answers a question
    /// about a representation that no longer exists -- read `retainedArenaBytesInUse` instead.
    public var cellStrideBytes: Int

    /// Exact bytes of cell storage across the whole grid: live screen cells at their stride, plus
    /// what retained rows' packed blobs really hold. Excludes malloc bucket rounding and the array
    /// headers, which are counted separately below so that a caller can attribute them rather than
    /// silently absorb them.
    ///
    /// The two terms are reported separately below, because after packing they are priced by
    /// different arithmetic and a single total can no longer be decomposed by a reader.
    public var cellStorageBytes: Int

    /// Cells retained rows store, summed over history. The extent canonical trimming produces,
    /// independent of how those cells are encoded -- which is what makes it the quantity the
    /// retained-row probe reconstructs from the public row reader.
    public var retainedStoredCellCount: Int

    /// Arena bytes history's records occupy right now -- headers, cells and in-arena side tables.
    ///
    /// This is what history really holds, so it is the number a "does history fit its budget"
    /// proof reads, together with the index and out-of-arena side-table terms below.
    public var retainedArenaBytesInUse: Int

    /// The arena's allocated capacity, held below the byte budget by a fixed metadata reserve so
    /// the index and the side tables are resident *inside* the bound (`31/DD36`).
    ///
    /// Allocated once and never grown, compacted or shrunk, which is what makes doc 15's `F4`
    /// leak unrepresentable: there are no per-row allocations left for eviction to strand, and
    /// the proof is "bytes-in-use falls when records are evicted, and this does not grow"
    /// (`31/DD11`).
    public var retainedArenaCapacityBytes: Int

    /// The derived index's charge: per-record offsets plus per-block display-row totals.
    public var retainedIndexBytes: Int

    /// Side tables held outside the arena -- multi-scalar spills and trailing fill styles --
    /// charged at what their allocator gave rather than at what their live entries weigh
    /// (`31/DD37`).
    public var retainedSideTableBytes: Int

    /// Separate heap allocations backing *live* rows -- one per row with cells. Doc 15's H7 is
    /// about the per-allocation overhead this number multiplies. History contributes none: its
    /// cells all live in the one arena.
    public var rowStorageAllocationCount: Int

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

    /// Average bytes per cell across the whole grid. No longer constant at the stride, which is
    /// exactly what doc 28's packing was for: retained cells are now priced by their encoding and
    /// live cells by the struct, so this number moved the moment `C6` landed.
    public var bytesPerCell: Double {
        cellCount == 0 ? 0 : Double(cellStorageBytes) / Double(cellCount)
    }

    /// Average arena bytes per retained cell -- the headline `C6` moved, stated per cell so it can
    /// be held against `cellStrideBytes` directly.
    public var retainedBytesPerStoredCell: Double {
        retainedStoredCellCount == 0
            ? 0
            : Double(retainedArenaBytesInUse) / Double(retainedStoredCellCount)
    }

    /// Everything history charges against its byte budget: the arena in use plus the derived index
    /// plus every side table (`31/I2`).
    public var retainedChargedBytes: Int {
        retainedArenaBytesInUse + retainedIndexBytes + retainedSideTableBytes
    }

    /// True when history charges more than the capacity it was built at, which the one bound
    /// `31/I2` states makes unreachable. Replaces doc 15's per-row leak flag, whose subject --
    /// a heap allocation per retained row -- no longer exists.
    public var hasRetainedStorageOverdraft: Bool {
        retainedChargedBytes > retainedArenaCapacityBytes
    }
}
