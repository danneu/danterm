// Doc 31's retained-history store: one fixed-capacity byte arena of logical-line records, a
// derived index over it, and the read-time fold that turns both back into display rows.
//
// This is the store `research/31/D1` funded and `research/31/D2` and `research/31/D3`
// specified. History holds one record per
// logical line a program printed; wrapping is derived at read from (record, width); a width
// change rewrites no retained byte and evicts nothing, because there is no width in storage to
// rewrite (`I1`, `I3`). The arena reserves a byte address space held *below* the byte budget by
// the metadata reserve, then materializes its fixed-size backing chunks as writes first reach
// them. The address space is never grown or compacted (`I2` as amended by `research/31/D4`'s
// residency remedy), and materialized backing is never shrunk.
//
// What belongs here: the arena and its ring discipline, the five mutating operations `research/31/D2`
// Decision 2 enumerates (admit, close/reopen the tail, evict at the head, truncate the tail,
// clear), the derived index (per-block display-row and content-unit totals), the side tables
// keyed by record -- spills and the trailing background-erase fill style -- and the two reads the
// fold serves: the content walk a copy takes and the painted walk a renderer takes. What does
// not: the record's byte layout and the fold's arithmetic, which are `LogicalLineRecord`; and
// every terminal-side concern -- anchors, selection, projection -- which stays in
// `Terminal.swift`. This type never sees a `TextAnchor`.
//
// **The middle is immutable** (`I5`). The head record's header and the tail record are the only
// writable bytes; everything between them is written once at admission and read forever. That is
// what makes each operation's cost bounded by the head and the tail alone, and it is the premise
// every reader in the design leans on.
//
// Its own file because it is the one data structure the whole design rests on, and because it is
// deliberately reachable without `Terminal`'s 6,000 lines of parser state -- the store's
// contracts are testable as a store.

extension Terminal {
    /// Retained history as logical-line records in one fixed-capacity arena.
    ///
    /// Owns its own width, because the derived row totals are only meaningful at one
    /// (`research/31/D3` Decision 1). Callers change it through `setWidth(_:)`, which recomputes
    /// only those totals; content totals remain width-free and are maintained at mutation sites.
    struct LogicalLineStore: Sendable, Equatable {
        // MARK: - Nested types

        /// One index block's cached display-row and width-free content-unit totals.
        ///
        /// `rowStart` is an **absolute** stream position measured from the same monotone origin
        /// `evictedRowCount` counts against, which is what lets a head eviction touch only the
        /// head block: every later block's start is unchanged by definition.
        /// `contentStart` follows the same rule against `evictedContentUnitCount`, while both
        /// counts cover only this block's records.
        private struct Block: Sendable, Equatable {
            var rowStart: Int
            var rowCount: Int
            var contentStart: Int = 0
            var contentCount: Int = 0
        }

        /// A side-table key measured from the record's cell base before any head trim.
        fileprivate struct OriginalCellOffset: Sendable, Equatable, Comparable, Strideable {
            var value: Int

            static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
            static func + (lhs: Self, rhs: Int) -> Self { Self(value: lhs.value + rhs) }
            static func - (lhs: Self, rhs: Self) -> Int { lhs.value - rhs.value }
            func distance(to other: Self) -> Int { other - self }
            func advanced(by distance: Int) -> Self { self + distance }
        }

        /// A hyperlink id stamped at one original cell offset within the record.
        private struct HyperlinkEntry: Sendable, Equatable {
            var offset: OriginalCellOffset
            var id: Terminal.HyperlinkId
        }

        /// One contiguous `contentIdentity` run, keyed by original cell offset within the record
        /// (`research/31/D3` Decision 6, `research/31/DD17`) rather than by column within a display row.
        private struct IdentityRun: Sendable, Equatable {
            var start: OriginalCellOffset
            var extent: Int
            var base: Terminal.ContentIdentity
        }

        /// What the store charges against its budget, reported so budget, capacity and
        /// bytes-in-use are separately visible (`research/31/DD11`, restating `research/15/F4`'s leak proof in
        /// arena terms).
        ///
        /// `chargedBytes` is the single quantity `31/I2` bounds, and it is bounded by
        /// `capacityBytes` rather than by `budgetBytes`: the arena's address space is reserved
        /// **below** the budget by the metadata reserve, so that the index and the side tables
        /// live inside the bound rather than resident on top of it (`research/31/D4`'s residency
        /// remedy, `research/31/DD36`).
        /// Charged is still **not** resident: once the ring's write cursor has cycled every arena
        /// page has been touched, which is the reading `31/AR6` promoted to a gate.
        struct Census: Equatable, Sendable {
            /// The byte budget the store was configured with -- what a pane's history may cost.
            var budgetBytes: Int
            /// The arena's reserved capacity, which is the budget less the metadata reserve and
            /// is the number `chargedBytes` is bounded by. Backing materializes lazily within it.
            var capacityBytes: Int
            var arenaBytesInUse: Int
            var indexBytes: Int
            var sideTableBytes: Int

            var chargedBytes: Int { arenaBytesInUse + indexBytes + sideTableBytes }
        }

        /// A record's content-level shape, for callers that reason about logical lines rather
        /// than display rows -- copy, search, and the proofs that a trim landed.
        struct RecordSummary: Equatable, Sendable {
            var cellCount: Int
            var displayRowCount: Int
            var isOpen: Bool
            var startsMidLine: Bool
            var hasWideCells: Bool
            var semanticPrompt: Terminal.SemanticPromptRow
            /// The style the line's tail is painted in past its content end, or nil when the
            /// tail is default-painted. Never part of the line's cells.
            var trailingFillStyle: Terminal.StyleId?
        }

        /// A transient display-row address with the width-derived boundary needed by its readers.
        ///
        /// The transient `research/31/D3` Decision 2 keeps out of anchors: it is produced on demand and
        /// never stored, so the public coordinate stays an absolute display row. Readers get one
        /// from `locate(displayRow:)` and carry it forward with `advance(_:)`, which is how a
        /// frame plans with at most one locate (`research/31/D3` Decision 1 rule 2).
        struct DisplayRowCursor: Sendable {
            fileprivate var recordIndex: Int
            fileprivate var rowWithinRecord: Int
            fileprivate var start: Int
            fileprivate var end: Int
            fileprivate var spacerRecordIndex: Int
            fileprivate var spacerOffset: Int
        }

        /// Names one retained record without depending on its sequence position or arena offset.
        ///
        /// One word, because a holder stores two of these per match and the index that stores
        /// them is sized by the occurrences history holds. The word is a strictly increasing
        /// number over the whole life of the store: the low bits are the ordinal packed beside
        /// the record's arena offset, and the high bits are the retirement generation that
        /// ordinal was issued in, so an identity is never reissued and a retired coordinate
        /// resolves to nothing rather than to the text that took its place. Repeating one needs
        /// 2^64 admitted records, which no output stream reaches.
        struct RecordIdentity: Equatable, Comparable, Sendable {
            fileprivate var rawValue: UInt64

            static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        /// Names a cell boundary by stable record identity and its original offset in that record.
        struct RecordTextPosition: Equatable, Comparable, Sendable {
            var record: RecordIdentity
            fileprivate var cellOffset: OriginalCellOffset

            static func < (lhs: Self, rhs: Self) -> Bool {
                lhs.record < rhs.record
                    || (lhs.record == rhs.record && lhs.cellOffset < rhs.cellOffset)
            }

            /// Moves within the same stable record by a retained-relative distance.
            func advanced(by distance: Int) -> Self {
                Self(record: record, cellOffset: cellOffset + distance)
            }
        }

        // MARK: - Stored state

        /// The arena, stored as 64-bit words over copy-on-write chunks materialized on first use.
        /// Its byte address space is fixed at `arenaCapacity`; only the consecutive backing prefix
        /// grows, one chunk at a time, and materialized chunks are never reclaimed. `research/31/D2`
        /// Decision 1 rejected geometric address-space growth (resident slack no charge model can
        /// see, the shape of `research/15/F4`'s leak) and `memmove` compaction (a 16 MiB copy on the
        /// admission path).
        ///
        /// Words rather than bytes because every offset in the store is a byte offset on an
        /// 8-byte grain -- headers, cells and both in-arena tables all are -- so a word is
        /// addressed as `offset >> 3` and read or written whole. `research/31/F8` Observation 3 priced the
        /// alternative: composing a word out of eight checked `[UInt8]` subscripts put admission
        /// at ~1.1 ns per stored cell byte, which was the whole of that finding's reject.
        ///
        /// **Chunked rather than one allocation (`research/31/D5`, amending `research/31/D2` Decision 1).** The
        /// byte address space is still one linear ring over `[0, arenaCapacity)`; only the
        /// backing is split. `TerminalPTYHost.drainedFrameState()` publishes the `Terminal`
        /// **value**, so between two published frames the arena is non-uniquely referenced and
        /// the next write copies it: with one buffer that was all 15.75 MiB, which `research/31/F13` M1
        /// measured as `memcpy` at 12.1%-16.1% of whole-process CPU under `admit`. With chunks
        /// it is each chunk the write touches. A record may cross chunk boundaries and the arena
        /// wrap; those are placement details. A display row contained in one chunk still hoists
        /// that chunk's pointer, while a straddling row uses the wrapped word accessor.
        private var chunks: ContiguousArray<ContiguousArray<UInt64>>

        /// The chunk size as a power of two, so a byte offset splits into a chunk index and an
        /// in-chunk word index with two shifts and a mask and no division (`research/31/DD53`).
        private let chunkByteShift: Int
        private let chunkByteMask: Int
        private let chunkBytes: Int

        /// Byte offset of the oldest retained record's header.
        private var head = 0

        /// Byte offset where the next bytes are written. Wraps to 0 at the physical end.
        private var writeCursor = 0

        /// Arena bytes the retained records occupy, which is the ring span `[head, writeCursor)`.
        ///
        /// Derived rather than stored, for the reason `grandDisplayRowTotal` is: every mutator
        /// already moves the two cursors, records occupy the ring without gaps, and the span is
        /// therefore the charge. A byte the cursor skips can no longer stay charged, because the
        /// charge is the cursor distance.
        ///
        /// The record count is what tells an empty ring from a full one: both hold
        /// `writeCursor == head`, and only an empty store has no records.
        private var bytesInUse: Int {
            guard offsets.count > 0 else { return 0 }
            return writeCursor > head
                ? writeCursor - head
                : arenaCapacity - head + writeCursor
        }

        /// One packed arena offset and stable identity per live record, oldest first. The pair
        /// stays one word, so the capacity charge that bounds the degenerate blank-line regime
        /// remains eight bytes per record (`research/31/D2` Decision 1).
        private var offsets: RingBuffer<Int>

        /// Bits in each existing 8-byte index entry that hold its physical arena offset.
        private let recordOffsetBits: Int

        /// Selects the physical arena offset from a packed index entry.
        private let recordOffsetMask: Int

        /// The next identity packed beside an offset without widening the per-record index.
        private var nextRecordIdentity: UInt64 = 1

        /// Advances only when the packed identity space is exhausted and history is retired.
        private var recordIdentityEpoch: UInt64 = 0

        /// Cached display-row and content-unit totals, one per `blockSize` records.
        private var blocks: RingBuffer<Block>

        private var firstRecordSequence = 0

        /// The block number the head record sits in.
        ///
        /// Derived, because a block number *is* a record sequence divided by the block size:
        /// storing it separately made the head block's retirement a second step that had to
        /// re-establish the identity by hand.
        private var firstBlockNumber: Int { firstRecordSequence / Self.blockSize }

        /// Resolves one retained record through the ring's absolute block numbering.
        private func blockIndex(containingRecordAt recordIndex: Int) -> Int? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let sequence = firstRecordSequence + recordIndex
            let blockIndex = sequence / Self.blockSize - firstBlockNumber
            guard blockIndex >= 0, blockIndex < blocks.count else { return nil }
            return blockIndex
        }

        /// Gives the retained records owned by one block, including a partially evicted head.
        private func recordIndices(inBlockAt blockIndex: Int) -> Range<Int> {
            precondition(blockIndex >= 0 && blockIndex < blocks.count)
            let blockNumber = firstBlockNumber + blockIndex
            let first = max(firstRecordSequence, blockNumber * Self.blockSize)
                - firstRecordSequence
            let end = min(
                offsets.count,
                (blockNumber + 1) * Self.blockSize - firstRecordSequence
            )
            return first..<end
        }

        /// Content units removed from the head, on the same monotone-origin rule as
        /// `evictedRowCount`.
        private var evictedContentUnitCount = 0

        /// Cells trimmed off the head record's front, which rebases its side-table keys.
        ///
        /// Store-level rather than a header field because **only the head record is ever
        /// trimmed**, and the header word is full: `research/31/D2` Decision 1 prices a blank record at
        /// eight arena bytes, so a per-record trim field would have cost the blank-history depth
        /// the whole budget derivation rests on.
        private var headTrimmedCells = OriginalCellOffset(value: 0)

        /// Cells already removed from a closed head record's flushed per-cell tables.
        private var headTableCellBase = 0

        /// Set when eviction dropped an open record whose line has no follower yet, so the next
        /// record opened continues that line rather than starting one (`research/31/D2` Decision 2).
        private var pendingStartsMidLine = false

        /// Display rows held by every retained record.
        ///
        /// Read off the last block rather than stored: a block's `rowStart` is absolute against
        /// the same monotone origin `evictedRowCount` counts from, so the last block's end is the
        /// total by construction. Stored, it was a second copy of that fact which every mutation
        /// had to move in step with the block it touched -- and moving them in the wrong order
        /// subtracted a row twice, which is the bug the two ordering comments below were written
        /// for. There is now one update, so there is nothing left to disagree.
        var grandDisplayRowTotal: Int {
            guard blocks.count > 0 else { return 0 }
            let last = blocks[blocks.count - 1]
            return last.rowStart + last.rowCount - evictedRowCount
        }

        /// Width-free projected content units retained by all records, read off the last block on
        /// the same rule `grandDisplayRowTotal` states.
        var grandContentUnitTotal: Int {
            guard blocks.count > 0 else { return 0 }
            let last = blocks[blocks.count - 1]
            return last.contentStart + last.contentCount - evictedContentUnitCount
        }

        /// Display rows dropped at the head, at the width in force when they were dropped, and
        /// only ever increasing (`research/31/D2` Decision 2's invariant, which replaces
        /// `isHistoryHeadTruncated`).
        private(set) var evictedRowCount = 0

        private(set) var width: Int

        /// The byte budget `31/I2` bounds the charge by, as configured.
        private let budget: Int

        /// The arena's reserved capacity: the budget less the metadata reserve, and the number
        /// the charge is actually tested against (`research/31/DD36`). Backing materialization
        /// does not change it.
        private let arenaCapacity: Int

        /// The open tail record's side tables, held outside the arena until it closes.
        ///
        /// A record's tables sit after its cells, so they cannot be written while admission is
        /// still appending cells over that space. Holding them here costs one flush per closed
        /// record and keeps the arena layout uniform for every record a reader will ever see
        /// except the tail.
        private var openHyperlinks: [HyperlinkEntry] = []
        private var openIdentityRuns: [IdentityRun] = []
        private var openSpills: [[Unicode.Scalar]] = []
        private var openSpillBase = 0
        private var openSpillPayloadBytes = 0
        private var openPreviousIdentity: Terminal.ContentIdentity?

        /// The blank skipped by a wide wrap on the open tail's last admitted row.
        ///
        /// Its follower decides whether it was structural or content. It stays outside the
        /// record until that decision so the stored line remains width-free.
        private var pendingMarginStyleId: Terminal.StyleId?

        /// The two sequence-keyed side tables and the bytes they cost, held by one owner.
        ///
        /// The tables and their charge used to be four independent fields moved by hand at
        /// roughly fifteen sites, and the sites had drifted into three different spellings of
        /// "is the spill table empty". Both failures are the same one: a fact kept in two places
        /// that every mutation had to move together. Nothing outside this type can reach a table,
        /// so a charge cannot go stale and an emptiness question has one answer.
        private var sideTables = SequenceKeyedSideTables()

        /// Owns the sequence-keyed side tables and prices them, so a mutation and its byte charge
        /// are one operation.
        ///
        /// Charged rather than recomputed per read for the reason `research/31/F8` Observation 3
        /// recorded: the write path tests the charge against the capacity once per admission and
        /// once per eviction step, and a from-scratch recount walks every retained payload. The
        /// maintained total is refreshed inside each mutating method, and `census` recounts it and
        /// asserts the two agree -- so a term that moves without its charge fails a test rather
        /// than silently loosening `31/I2`'s bound (`31/AR4`'s failure mode, applied to the charge).
        private struct SequenceKeyedSideTables {
            struct SpillTable: Equatable {
                var base: Int
                var payloads: [[Unicode.Scalar]]

                func payload(at key: Int) -> [Unicode.Scalar]? {
                    let modulus = CellWord.maximumSpillIndex + 1
                    let distance = key >= base ? key - base : modulus - base + key
                    guard distance < payloads.count else { return nil }
                    return payloads[distance]
                }
            }

            /// Multi-scalar payloads, keyed by absolute record sequence. Outside the arena
            /// because inlining them would make a cell variable-width -- giving up the indexed
            /// read for the rarest cell in the corpus, since 99.88% of rows have none
            /// (`research/28/F11`).
            private var spillsBySequence: [Int: SpillTable] = [:]

            /// The trailing background-erase fill style, keyed by absolute record sequence.
            ///
            /// A side table rather than a header field for the reason `research/31/D3` Decision 3
            /// rejected a header style slot: it is reachable on a minority of records, and a
            /// 32-bit slot in every header would cost the blank-history depth `research/31/D2`
            /// Decision 1 rests on. Keyed like the spill table, so the two are evicted and charged
            /// by the same rules.
            private var fillStylesBySequence: [Int: Terminal.StyleId] = [:]

            /// The retained payloads' own bytes, the one term a recount would have to walk for.
            private var payloadBytes = 0

            /// The maintained total, refreshed by every mutation here and by nothing else.
            private(set) var chargedBytes = 0

            /// Whether any record holds a spill payload.
            ///
            /// The one answer to a question the old call sites spelled three ways. Probing an
            /// empty table costs a hash of a key that cannot be there, and a store whose content
            /// carries neither spills nor fills evicts on every admitted row -- so eviction asks
            /// this before it asks the dictionary. Only a non-empty payload is ever charged, which
            /// is what makes the byte accumulator answer it.
            var holdsSpills: Bool { payloadBytes > 0 }

            /// Records holding a spill payload, which is also the number of spill tables allocated:
            /// one table per record, however many of its cells spilled into it.
            var spillTableCount: Int { spillsBySequence.count }

            func spills(at sequence: Int) -> SpillTable? {
                guard holdsSpills else { return nil }
                return spillsBySequence[sequence]
            }

            func fillStyle(at sequence: Int) -> Terminal.StyleId? {
                fillStylesBySequence[sequence]
            }

            /// Replaces a record's payloads; an empty array drops the entry rather than storing one,
            /// which is what keeps `holdsSpills` exact.
            mutating func setSpills(_ spills: SpillTable, at sequence: Int) {
                payloadBytes -= Self.spillCost(of: spillsBySequence[sequence])
                if spills.payloads.isEmpty {
                    spillsBySequence.removeValue(forKey: sequence)
                } else {
                    spillsBySequence[sequence] = spills
                    payloadBytes += Self.spillCost(of: spills)
                }
                refreshCharge()
            }

            /// Removes one closed record's spills and transfers their storage to its caller.
            mutating func takeSpills(at sequence: Int) -> SpillTable? {
                guard holdsSpills, let spills = spillsBySequence.removeValue(forKey: sequence)
                else { return nil }
                payloadBytes -= Self.spillCost(of: spills)
                refreshCharge()
                return spills
            }

            mutating func trimSpills(_ count: Int, at sequence: Int) {
                guard count > 0, var table = spillsBySequence[sequence] else { return }
                payloadBytes -= Self.spillCost(of: table)
                table.payloads.removeFirst(min(count, table.payloads.count))
                table.base = (table.base + count) % (CellWord.maximumSpillIndex + 1)
                if table.payloads.isEmpty {
                    spillsBySequence.removeValue(forKey: sequence)
                } else {
                    spillsBySequence[sequence] = table
                    payloadBytes += Self.spillCost(of: table)
                }
                refreshCharge()
            }

            mutating func setFillStyle(_ styleId: Terminal.StyleId?, at sequence: Int) {
                if let styleId {
                    fillStylesBySequence[sequence] = styleId
                } else {
                    guard fillStylesBySequence.isEmpty == false else { return }
                    fillStylesBySequence.removeValue(forKey: sequence)
                }
                refreshCharge()
            }

            /// Drops everything one record owns, which is what an eviction or a tail drop needs.
            mutating func removeEntries(at sequence: Int) {
                var moved = false
                if holdsSpills {
                    payloadBytes -= Self.spillCost(
                        of: spillsBySequence.removeValue(forKey: sequence)
                    )
                    moved = true
                }
                if fillStylesBySequence.isEmpty == false {
                    fillStylesBySequence.removeValue(forKey: sequence)
                    moved = true
                }
                if moved { refreshCharge() }
            }

            mutating func removeAll() {
                spillsBySequence.removeAll()
                fillStylesBySequence.removeAll()
                payloadBytes = 0
                refreshCharge()
            }

            /// The charge rebuilt from the tables themselves, ignoring the maintained total.
            ///
            /// The independent oracle the `census` assert is stated against: it re-walks every
            /// payload rather than trusting the accumulator, so it catches a mutation that moved a
            /// table without moving its bytes.
            var recountedChargedBytes: Int {
                var payloads = 0
                for spills in spillsBySequence.values { payloads += Self.spillCost(of: spills) }
                return payloads + tableAllocationBytes
            }

            private mutating func refreshCharge() {
                chargedBytes = payloadBytes + tableAllocationBytes
            }

            /// What the two hash tables themselves allocated, on top of the payloads they point at.
            ///
            /// The spill table's second term is what `research/31/F8` Observation 4 found missing --
            /// the census charged 1.931 MiB of side tables on `scrollback-mixed` while the arena's
            /// resident excess was 4.375 MiB, and the gap was this dictionary's own storage. A
            /// charge that describes the payloads and not the allocation is `research/15/F2`'s error
            /// class, recurring inside `31/I2`.
            private var tableAllocationBytes: Int {
                Self.hashTableBytes(
                    capacity: spillsBySequence.capacity,
                    entryStride: MemoryLayout<Int>.stride
                        + MemoryLayout<SpillTable>.stride
                )
                    + Self.hashTableBytes(
                        capacity: fillStylesBySequence.capacity,
                        entryStride: MemoryLayout<Int>.stride
                            + MemoryLayout<Terminal.StyleId>.stride
                    )
            }

            private static func spillCost(of table: SpillTable?) -> Int {
                guard let table, table.payloads.isEmpty == false else { return 0 }
                let spills = table.payloads
                var total = Terminal.arrayStorageHeaderBytes
                    + spills.capacity * MemoryLayout<[Unicode.Scalar]>.stride
                for spill in spills {
                    Instrument.openSpillChargeWork.record()
                    total += Terminal.arrayStorageHeaderBytes
                        + spill.capacity * MemoryLayout<Unicode.Scalar>.stride
                }
                return total
            }

            /// What a `Dictionary` at this capacity actually allocated, rather than what its live
            /// entries weigh.
            ///
            /// `Dictionary.capacity` is the count it holds *before* it resizes -- three quarters of
            /// the power-of-two bucket count it allocated -- so `capacity * stride` under-charges
            /// the allocation by a third plus the occupancy bitmap. Charging the buckets is
            /// `research/15/D4`'s rule, the same one the index's 8-B-per-record charge follows:
            /// charge what the allocator gave, not what the model says is in use.
            private static func hashTableBytes(capacity: Int, entryStride: Int) -> Int {
                guard capacity > 0 else { return 0 }
                var buckets = 1
                while buckets - buckets / 4 < capacity { buckets <<= 1 }
                return Terminal.arrayStorageHeaderBytes + buckets * entryStride + buckets / 8
            }
        }

        /// Records per index block.
        ///
        /// `research/31/F1` Observation 4 measured sequential browse at 677 ns (32), 697 ns (64), 801 ns
        /// (128) and 870 ns (256) per display row: small blocks read faster because the in-block
        /// scan shortens faster than the binary search lengthens. 64 keeps that while charging
        /// 0.5 B per record for both block totals, against the 8 B the offsets cost.
        static let blockSize = 64

        // MARK: - Construction

        /// Reserves the arena's byte address space at the budget less the metadata reserve.
        /// Backing starts empty and materializes in consecutive chunks as records first reach it.
        init(budgetBytes: Int = Terminal.scrollbackByteLimit, width: Int) {
            precondition(Self.acceptsBudgetBytes(budgetBytes))
            precondition(width >= 1)
            budget = budgetBytes
            arenaCapacity = budgetBytes - Self.metadataReserveBytes(forBudget: budgetBytes)
            recordOffsetBits = max(1, Int.bitWidth - (arenaCapacity - 1).leadingZeroBitCount)
            recordOffsetMask = (1 << recordOffsetBits) - 1
            let shift = Self.chunkByteShift(forCapacity: arenaCapacity)
            chunkByteShift = shift
            chunkByteMask = (1 << shift) - 1
            chunkBytes = 1 << shift
            chunks = []
            self.width = width
            offsets = RingBuffer(filler: 0)
            blocks = RingBuffer(filler: Block(rowStart: 0, rowCount: 0))
        }

        /// Whether the fixed arena derived from a budget fits every field that addresses it.
        static func acceptsBudgetBytes(_ budget: Int) -> Bool {
            guard budget >= Terminal.minimumScrollbackBudgetBytes, budget % 8 == 0 else {
                return false
            }
            let capacity = budget - Self.metadataReserveBytes(forBudget: budget)
            let cells = capacity / LogicalLineRecord.cellBytes
            return cells <= LogicalLineRecord.Header.maximumCellCount
                && cells <= CellWord.maximumSpillIndex + 1
        }

        /// The spelling `research/31/F8`'s eviction probe compiles against.
        ///
        /// That probe is a frozen instrument -- `research/31/D4`'s rule is applied to it unedited -- and it
        /// constructs the store with the production **budget** under this label, which is what the
        /// argument has always meant to a caller: how many bytes a pane's history may cost. The
        /// arena's capacity stopped being that same number when `research/31/D4`'s residency remedy landed,
        /// so new call sites say `budgetBytes:` and this stays to keep the instrument runnable.
        init(capacityBytes: Int, width: Int) {
            self.init(budgetBytes: capacityBytes, width: width)
        }

        /// How far below the byte budget the arena's capacity is held, so the index and the side
        /// tables are resident *inside* the bound rather than on top of it.
        ///
        /// `research/31/DD36` derives the 1/16: `research/31/F8` measured the metadata share at 3.23% of the budget
        /// on `plain` and 15.29% on `mixed`, and measured the arena's depth margin over today's
        /// store at 1.076x on its tightest class -- so a reserve above ~7.1% would make a content
        /// class retain *less* than today's engine, which `31/PO11` forbids. 1/16 is the largest
        /// simple fraction under that ceiling.
        static func metadataReserveBytes(forBudget budget: Int) -> Int {
            ((budget / 16) + 7) & ~7
        }

        /// 64 KiB, the smallest chunk this store will build (`research/31/DD53`).
        ///
        /// The floor keeps ordinary display rows in one copy-on-write unit. The arena, not this
        /// chunk, is the admissible unit (`research/31/DD54` as amended 2026-09-02).
        static let minimumChunkByteShift = 16

        /// 512 KiB, the largest. Bigger chunks copy more per published frame, which is the whole
        /// cost `research/31/D5` exists to bound.
        static let maximumChunkByteShift = 19

        /// `research/31/DD53`: the power of two at or above `capacity / 32`, clamped to
        /// [64 KiB, 512 KiB], with a capacity at or under the floor left as a single chunk.
        ///
        /// At the production budget the capacity is 15,728,640 B and this returns 19, dividing
        /// the arena into exactly 30 chunks of 512 KiB. Below the floor it returns the smallest
        /// shift that covers the whole capacity, so a small-budget store keeps exactly the
        /// single-region placement it had before `research/31/D5` -- which is what keeps the suite's
        /// existing expectations resting on the placement rule they were written against.
        static func chunkByteShift(forCapacity capacity: Int) -> Int {
            precondition(capacity >= 8)
            if capacity <= 1 << minimumChunkByteShift {
                var shift = 3
                while (1 << shift) < capacity { shift += 1 }
                return shift
            }
            var shift = minimumChunkByteShift
            while shift < maximumChunkByteShift, (1 << shift) * 32 < capacity { shift += 1 }
            return shift
        }

        /// Test support: the identity of each backing chunk's storage.
        ///
        /// The only way to assert `research/31/D5`'s mechanism rather than time it: after a value copy,
        /// the chunks a mutation did *not* write must still be the same buffers the copy holds.
        func chunkStorageIdentitiesForTesting() -> [UInt] {
            chunks.map { chunk in
                chunk.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
            }
        }

        /// Test support: the byte size of a full backing chunk, which is what one post-publish
        /// mutation copies at most.
        var chunkCapacityBytesForTesting: Int { min(chunkBytes, arenaCapacity) }

        /// The full backing chunk count implied by fixed capacity, whether materialized or not.
        private var fullChunkCount: Int {
            (arenaCapacity + chunkBytes - 1) / chunkBytes
        }

        // MARK: - Census

        var budgetBytes: Int { budget }

        var capacityBytes: Int { arenaCapacity }

        var recordCount: Int { offsets.count }

        /// Number of leading records whose content can no longer change.
        var closedRecordCount: Int {
            guard offsets.count > 0 else { return 0 }
            return record(at: offsets[offsets.count - 1]).isOpen
                ? offsets.count - 1
                : offsets.count
        }

        /// Number of display rows held by records whose bytes can no longer change.
        var closedPrefixDisplayRowCount: Int {
            guard offsets.count > 0 else { return 0 }
            let tail = record(at: offsets[offsets.count - 1])
            guard tail.isOpen else { return grandDisplayRowTotal }
            return grandDisplayRowTotal - displayRowCount(recordIndex: offsets.count - 1)
        }

        /// The single quantity `31/I2` bounds, in O(1).
        ///
        /// Read on the write path -- once per admission and once per eviction step -- which is why
        /// every term is either capacity arithmetic, the arena's ring span, or a total its owner
        /// maintains, rather than the walk over payloads a `Census` does.
        var chargedBytes: Int {
            bytesInUse + indexChargeBytes + openScratchBytes + sideTables.chargedBytes
        }

        var census: Census {
            // The maintained side-table charge against a full recount: a mutation that moves a
            // table without moving its bytes fails here rather than loosening the bound in
            // production. Every other term is derived -- live capacities, or the arena's ring
            // span -- so none of them can drift.
            let recountedSideTables = sideTables.recountedChargedBytes
            assert(
                sideTables.chargedBytes == recountedSideTables,
                "the maintained side-table charge drifted from a recount"
            )
            return Census(
                budgetBytes: budget,
                capacityBytes: arenaCapacity,
                arenaBytesInUse: bytesInUse,
                indexBytes: indexChargeBytes,
                sideTableBytes: recountedSideTables + openScratchBytes
            )
        }

        private var indexChargeBytes: Int {
            offsets.capacity * MemoryLayout<Int>.stride
                + blocks.capacity * MemoryLayout<Block>.stride
                + arenaBackingOverheadBytes
        }

        /// What splitting the arena's backing costs beyond the bytes it holds (`research/31/D5`).
        ///
        /// One array storage header per possible chunk plus the outer array that names them --
        /// ~1.2 KiB of a 15 MiB capacity at the production budget. This stays fixed at the full
        /// chunk count even while backing materializes lazily, preserving the metadata reserve
        /// and preventing the charge from drifting underneath live content.
        private var arenaBackingOverheadBytes: Int {
            Terminal.arrayStorageHeaderBytes * (fullChunkCount + 1)
                + fullChunkCount * MemoryLayout<ContiguousArray<UInt64>>.stride
        }

        private var openScratchBytes: Int {
            openHyperlinks.capacity * MemoryLayout<HyperlinkEntry>.stride
                + openIdentityRuns.capacity * MemoryLayout<IdentityRun>.stride
                + (openSpills.capacity == 0 ? 0 : Terminal.arrayStorageHeaderBytes)
                + openSpills.capacity * MemoryLayout<[Unicode.Scalar]>.stride
                + openSpillPayloadBytes
        }

        // MARK: - Operation 1: admit a scrolled-off display row

        /// Appends one scrolled-off display row to the open tail record, opening one first when
        /// the previous logical line ended.
        ///
        /// The row's measurement rule is `reconstructLogicalLines`': a soft-wrapped row is
        /// measured to full width and a hard-ended row to its visible extent
        /// (`GridRow.visibleExtent`, `research/31/F4` case 17 as amended 2026-08-27).
        /// "Soft-wrapped" here is `logicallyContinues`, not the raw claim: a claim whose margin
        /// an erase blanked (`GridRow.marginProvenance`) measures as a hard end, or the erased
        /// leftovers would be admitted as line content and fuse separately printed lines.
        /// and the blank a wide wrap left in the last column is dropped, because whether that
        /// blank projects as a spacer is a function of its follower. A hard-ended
        /// row whose tail past the content is painted by a background erase contributes that
        /// paint as the record's **trailing fill style**, not as cells.
        mutating func admit(_ row: Terminal.GridRow) {
            resolvePendingMargin(before: row.cells.first)
            let admission = admissionExtent(row)
            let leavesPendingMargin = row.logicallyContinues
                && row.marginProvenance == .wideWrap
            let pendingMarginCapacity = leavesPendingMargin ? 1 : 0
            // The reservation needs an upper bound on the row's table entries, not a count: a
            // cell carries at most one hyperlink and starts at most one identity run, so the
            // stored cell count bounds both. Counting instead scanned every admitted row a
            // second time, which `terminal-feed` measured at 1% of the whole feed. The bound
            // saturates `projectedTableBytes` at the per-cell table sizes, which is where an
            // exact count already landed for the identities every printed cell carries.
            let storedEnd = min(admission.contentEnd, row.cells.count)
            let addedHyperlinks = storedEnd
            let addedIdentities = storedEnd

            // A budget too small to hold one display row of this width retains nothing rather
            // than trapping. The arena's address space is reserved once and never grown
            // (`31/I2`), so there is no room to make for a row that does not fit an empty region;
            // the honest answer is that such a pane has no history, and the degenerate
            // configuration stays reachable instead of becoming a crash.
            let worstCase = LogicalLineRecord.Header.byteCount
                + max(1, admission.contentEnd + pendingMarginCapacity)
                    * LogicalLineRecord.cellBytes
                + projectedTableBytes(
                    addingCells: max(1, admission.contentEnd + pendingMarginCapacity),
                    hyperlinkEntries: addedHyperlinks,
                    identityRuns: addedIdentities
                )
            guard worstCase <= arenaCapacity else { return }

            // A hard-ended row with no content still occupies a display row when the line
            // already has cells, and a zero-cell append would fold that row away. One blank
            // cell restores it -- the same thing today's store holds for a blank row, and
            // `research/31/DD15`'s zero-cell record is untouched, because that case is an *empty*
            // record rather than an empty append. It takes the fill's style when there is one,
            // so the restored row is painted from its first column exactly as today's stored
            // row is.
            let restoresBlankRow = row.logicallyContinues == false
                && admission.contentEnd == 0
                && openRecordCellCount > 0
            let cellCount = restoresBlankRow ? 1 : admission.contentEnd

            // Reserve the one cell a non-wide follower or a close may materialize.
            makeRoom(
                forCells: cellCount + pendingMarginCapacity,
                hyperlinkEntries: addedHyperlinks,
                identityRuns: addedIdentities
            )
            openRecordIfNeeded(mark: row.semanticPrompt)
            if restoresBlankRow {
                appendCell(
                    Terminal.GridCell(
                        scalars: .empty,
                        kind: .padding,
                        styleId: admission.fillStyle ?? Terminal.defaultStyleId
                    )
                )
            } else {
                appendRowPrefix(row, cellCount: cellCount)
            }
            setTrailingFillOnTail(admission.fillStyle)

            // `research/31/DD5`: the display-row count is *counted* here, not derived -- admission knows
            // it consumed one row, so no `ceil` and no wide-cell scan runs on the write path.
            addDisplayRowsToTail(1)

            if leavesPendingMargin {
                pendingMarginStyleId = row.cell(at: width - 1).styleId
            }

            if row.logicallyContinues == false {
                closeOpenRecord()
            }
            evictToBudget()
        }

        /// What a display row contributes to its logical line: how many of its cells are content,
        /// and the style its tail is painted in.
        ///
        /// An **extent** rather than a materialized `[GridCell]`: the caller's row already holds
        /// those cells contiguously, and `research/31/F8` Observation 3 charged the admission path one
        /// array allocation plus a full copy of every cell per admitted row for the privilege of
        /// naming them twice.
        ///
        /// A soft-wrapped row is measured to full width, less the blank a wide wrap left in its
        /// last column (whether that blank projects as a spacer is a function of its follower).
        /// A hard-ended row is measured by `GridRow.visibleExtent`, the one rule the live refold
        /// measures by too (`research/31/F4` case 17, `DD25` as amended): its content cells, then
        /// one trailing fill style re-derived at read against whatever width is in force, so
        /// no width turns a painted tail into extra display rows. There is no floor of one --
        /// a record's cell count is a content property and zero is representable
        /// (`research/31/DD15`).
        private func admissionExtent(
            _ row: Terminal.GridRow
        ) -> (contentEnd: Int, fillStyle: Terminal.StyleId?) {
            guard row.logicallyContinues else {
                let extent = row.visibleExtent(columns: width)
                return (extent.contentEnd, extent.fillStyle)
            }
            return (max(0, width - (row.marginProvenance == .wideWrap ? 1 : 0)), nil)
        }

        // MARK: - The trailing fill

        /// Records (or clears) the tail record's trailing fill style.
        ///
        /// Written after the row's cells because the fill belongs to the logical line's end.
        private mutating func setTrailingFillOnTail(_ styleId: Terminal.StyleId?) {
            guard offsets.count > 0 else { return }
            let index = offsets.count - 1
            let offset = offsets[index]
            var record = self.record(at: offset)
            guard let styleId else {
                guard record.hasTrailingFill else { return }
                record.hasTrailingFill = false
                writeHeader(record, at: offset)
                sideTables.setFillStyle(nil, at: firstRecordSequence + index)
                return
            }
            record.hasTrailingFill = true
            writeHeader(record, at: offset)
            sideTables.setFillStyle(styleId, at: firstRecordSequence + index)
        }

        /// The style painted after this record's content ends, on its last display row.
        ///
        /// Nil for every record that carries no fill, which is the overwhelming majority: the
        /// header bit answers that case without touching the side table.
        func trailingFillStyle(at recordIndex: Int) -> Terminal.StyleId? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            guard record(at: offsets[recordIndex]).hasTrailingFill else { return nil }
            return sideTables.fillStyle(at: firstRecordSequence + recordIndex)
        }

        // MARK: - Operation 2: close / reopen the tail record

        /// Ends the open logical line, flushing the tail record's side tables into the arena.
        ///
        /// This is `severScrollbackWrapClaim` under the new store, and the whole of it is one
        /// header bit plus the tables the open record had been accumulating.
        mutating func closeOpenRecord() {
            resolvePendingMarginForClose()
            guard var record = openTailRecord() else { return }
            let offset = offsets[offsets.count - 1]
            flushOpenTables(into: &record, at: offset)
            record.isOpen = false
            writeHeader(record, at: offset)
            writeCursor = arenaOffset(recordOffset(in: offset) + record.byteLength)
            clearOpenScratch()
        }

        /// Resumes appending to the last record, which is `restoreWrapClaimBeforeCursor`.
        ///
        /// Reopening drops the trailing fill: the fill describes the paint after the *end* of a
        /// line, and a reopened line has no end yet -- its last display row is about to be
        /// extended, and admission re-derives the tail of whatever row finally closes it.
        mutating func reopenTailRecord() {
            guard offsets.count > 0 else { return }
            let offset = offsets[offsets.count - 1]
            let record = self.record(at: offset)
            guard record.isOpen == false else { return }
            reopenClosedTail(record, at: offset)
        }

        /// Reopens the tail for a tail truncation.
        ///
        /// Reopening is not optional: a closed record's side tables are addressed off
        /// `offset + headerAndCells(cellCount)`, and `cutTail` rewrites `cellCount` -- leaving a
        /// closed record cut would move every later table read into the cell words.
        private mutating func reopenTailRecordForTruncation() {
            let offset = offsets[offsets.count - 1]
            let record = self.record(at: offset)
            guard record.isOpen == false else { return }
            reopenClosedTail(record, at: offset)
        }

        private mutating func reopenClosedTail(_ closed: LogicalLineRecord, at offset: Int) {
            guard ensureRecordIdentityCapacity() else { return }
            renewTailRecordIdentity()
            var record = closed
            loadOpenScratch(from: record, at: offset)
            if record.hasTrailingFill {
                record.hasTrailingFill = false
                sideTables.setFillStyle(nil, at: firstRecordSequence + offsets.count - 1)
            }
            record.isOpen = true
            record.hyperlinkCount = 0
            record.hyperlinkPerCell = false
            record.identityEntryCount = 0
            record.identityPerCell = false
            writeHeader(record, at: offset)
            writeCursor = arenaOffset(
                recordOffset(in: offset) + LogicalLineRecord.headerAndCells(record.cellCount)
            )
            headTableCellBase = 0
        }

        /// Resolves the open tail's skipped margin against the first cell of its follower.
        private mutating func resolvePendingMargin(before follower: Terminal.GridCell?) {
            guard let styleId = pendingMarginStyleId else { return }
            pendingMarginStyleId = nil
            guard follower?.kind != .wideHead else { return }
            appendCell(Terminal.GridCell(kind: .padding, styleId: styleId))
        }

        /// Resolves a pending margin when no follower will arrive because the line is closing.
        private mutating func resolvePendingMarginForClose() {
            guard let styleId = pendingMarginStyleId else { return }
            pendingMarginStyleId = nil
            guard styleId != Terminal.defaultStyleId else { return }
            appendCell(Terminal.GridCell(kind: .padding, styleId: styleId))
        }

        // MARK: - Operation 3: evict at the head

        /// Drops the oldest display row, trimming inside the head record when it holds more.
        ///
        /// Display-row granular by decision, not by convenience: `research/31/D2` Decision 2 took
        /// `research/31/DD2`'s recorded alternative so that no anchor and no scrollbar position moves
        /// further per admitted row than it does today. The termination measure is display rows
        /// rather than bytes -- a one-cell row frees eight bytes and spends eight on the
        /// rewritten header, so a step can free nothing and still make progress.
        @discardableResult
        mutating func evictOneDisplayRow() -> Bool {
            guard offsets.count > 0 else { return false }
            let offset = offsets[0]
            let record = self.record(at: offset)
            let cut = LogicalLineFold.firstRowCellEnd(
                cellCount: record.cellCount,
                width: width,
                hasWideCells: record.hasWideCells,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            )

            // The head block moves first: `dropHeadRecord` may retire it once its last record is
            // gone, and the row being dropped belongs to the block as it stands now.
            evictedRowCount += 1
            if blocks.count > 0 {
                blocks.modifyElement(at: 0) { block in
                    block.rowCount -= 1
                    block.rowStart += 1
                }
            }

            if cut >= record.cellCount {
                dropHeadRecord(record)
            } else {
                trimHeadRecord(record, at: offset, by: cut)
            }
            return true
        }

        /// Evicts until charged bytes are back inside the budget. Returns the rows dropped.
        @discardableResult
        mutating func evictToBudget() -> Int {
            var dropped = 0
            while chargedBytes > arenaCapacity, evictOneDisplayRow() {
                dropped += 1
            }
            return dropped
        }

        private mutating func trimHeadRecord(
            _ record: LogicalLineRecord,
            at offset: Int,
            by cut: Int
        ) {
            let removedContent = contentCellCount(recordIndex: 0, range: 0..<cut)
            // A record with no spill table has no spilled cell, so the common trim skips the
            // per-cell scan; the scan runs only on the record that owns spills.
            let hasSpills = record.isOpen
                ? openSpills.isEmpty == false
                : sideTables.spills(at: firstRecordSequence) != nil
            let removedSpills = hasSpills
                ? (0..<cut).count { cellWord(recordAt: offset, cell: $0).isSpilled }
                : 0
            removeContentUnitsFromHead(removedContent)
            if record.isOpen {
                let newCoordinateStart = headTrimmedCells.value + cut
                openHyperlinks.removeAll { $0.offset.value < newCoordinateStart }
                while let first = openIdentityRuns.first,
                      first.start.value + first.extent <= newCoordinateStart
                {
                    openIdentityRuns.removeFirst()
                }
                if var first = openIdentityRuns.first,
                   first.start.value < newCoordinateStart
                {
                    let removed = newCoordinateStart - first.start.value
                    first.start = OriginalCellOffset(value: newCoordinateStart)
                    first.extent -= removed
                    first.base &+= Terminal.ContentIdentity(removed)
                    openIdentityRuns[0] = first
                }
                if removedSpills > 0 {
                    openSpills.removeFirst(min(removedSpills, openSpills.count))
                    openSpillBase = (openSpillBase + removedSpills)
                        % (CellWord.maximumSpillIndex + 1)
                    openSpillPayloadBytes = openSpills.reduce(into: 0) { total, spill in
                        total += Terminal.arrayStorageHeaderBytes
                            + spill.capacity * MemoryLayout<Unicode.Scalar>.stride
                    }
                }
            } else {
                sideTables.trimSpills(removedSpills, at: firstRecordSequence)
                headTableCellBase += cut
            }
            var trimmed = record
            trimmed.cellCount -= cut
            trimmed.startsMidLine = true
            // `research/31/D2` Decision 5: the mark referred to a line start that no longer exists. What
            // survives is the continuation reading the trimmed head had as a non-head row.
            trimmed.semanticPrompt = Terminal.continuationMark(forLineHead: record.semanticPrompt)
            // The trim moves the record's start and keeps its identity, so the index word is
            // re-packed from both halves rather than added to. Adding the cut bytes to the packed
            // word happens to leave the ordinal alone today, but only because the sum never
            // carries out of the offset field; re-packing says what the write means and puts
            // `packedRecordAddress`'s bounds check on the new offset.
            let newOffset = arenaOffset(
                recordOffset(in: offset) + cut * LogicalLineRecord.cellBytes
            )
            writeHeader(trimmed, at: newOffset)
            offsets[0] = packedRecordAddress(
                offset: newOffset,
                identity: recordIdentity(in: offset)
            )
            head = newOffset
            headTrimmedCells = headTrimmedCells + cut
        }

        private mutating func dropHeadRecord(_ record: LogicalLineRecord) {
            removeContentUnitsFromHead(contentContribution(recordIndex: 0))
            // An open record's continuation has not been admitted yet, so dropping the record
            // carries its mid-line state to the next record that opens.
            let continues = record.isOpen
            if continues, offsets.count > 1 {
                let followerOffset = offsets[1]
                var follower = self.record(at: followerOffset)
                follower.startsMidLine = true
                follower.semanticPrompt = .none
                writeHeader(follower, at: followerOffset)
            } else if continues {
                pendingStartsMidLine = true
            }

            sideTables.removeEntries(at: firstRecordSequence)
            offsets.removeFirst()
            let retiredSequence = firstRecordSequence
            firstRecordSequence += 1
            // The head block holds the sequences the head record's block number covers, so it
            // retires exactly when that quotient advances -- one drop per dropped record, and the
            // ring stays in step with `firstBlockNumber` without a scan to re-establish it.
            if blocks.count > 0,
               retiredSequence / Self.blockSize != firstRecordSequence / Self.blockSize {
                blocks.removeFirst()
            }
            headTrimmedCells = OriginalCellOffset(value: 0)
            headTableCellBase = 0

            if offsets.count == 0 {
                resetToEmptyArena()
                return
            }

            // The head lands on the next record, so the dropped record leaves the charged span
            // by that move alone.
            head = recordOffset(in: offsets[0])
        }

        private mutating func retireEmptyTailBlocks() {
            guard offsets.count > 0 else { return }
            let lastBlockNumber = (firstRecordSequence + offsets.count - 1) / Self.blockSize
            while blocks.count > 0, firstBlockNumber + blocks.count - 1 > lastBlockNumber {
                blocks.removeLast()
            }
        }

        private mutating func resetToEmptyArena() {
            head = 0
            writeCursor = 0
            headTrimmedCells = OriginalCellOffset(value: 0)
            blocks.removeAll()
            sideTables.removeAll()
            pendingMarginStyleId = nil
            clearOpenScratch()
        }

        // MARK: - Operation 4: truncate the tail

        /// Hands the last `displayRows` display rows back to the live grid, rewinding the write
        /// cursor to the cut.
        ///
        /// The only operation that shrinks the arena from the back, and the only one whose rows
        /// are not lost: they keep their absolute stream positions and merely change which side
        /// of the history/live seam they sit on, which is why `evictedRowCount` does not move.
        mutating func truncateTail(
            displayRows: Int,
            follower: Terminal.GridCell? = nil
        ) -> [Terminal.GridRow] {
            let count = min(displayRows, grandDisplayRowTotal)
            guard count > 0 else { return [] }

            // Folded first, cut after -- and that order is the whole of it. A display row's
            // trailing spacer is re-derived from the wide head that *follows* it, so
            // folding a row once the row below it has already been cut away loses the column
            // the spacer occupied. Cutting from the back one row at a time and folding as it
            // went dropped exactly that cell on a height grow.
            var handedBack: [Terminal.GridRow] = []
            var cursors: [DisplayRowCursor] = []
            cursors.reserveCapacity(count)
            handedBack = paintedDisplayRows(
                in: (grandDisplayRowTotal - count)..<grandDisplayRowTotal
            ) { cursor in
                cursors.append(cursor)
            }
            if let styleId = pendingMarginStyleId, var row = handedBack.last {
                precondition(
                    row.cells.count == width - 1,
                    "a pending margin must complete the open tail's short final row"
                )
                row.cells.append(Terminal.GridCell(kind: .padding, styleId: styleId))
                if follower?.kind == .wideHead {
                    row.marginProvenance = .wideWrap
                }
                handedBack[handedBack.count - 1] = row
                pendingMarginStyleId = nil
            } else if let head = follower,
                      head.kind == .wideHead,
                      var row = handedBack.last,
                      row.isSoftWrapped,
                      row.cells.count == width - 1
            {
                row.cells.append(Terminal.GridCell(kind: .padding, styleId: head.styleId))
                row.marginProvenance = .wideWrap
                handedBack[handedBack.count - 1] = row
            }
            for cursor in cursors.reversed() {
                removeDisplayRowFromTail(at: cursor)
            }
            return handedBack
        }

        private mutating func removeDisplayRowFromTail(at cursor: DisplayRowCursor) {
            precondition(cursor.recordIndex == offsets.count - 1)
            let offset = offsets[offsets.count - 1]
            let record = self.record(at: offset)

            // The tail block moves first, for the reason `evictOneDisplayRow` gives at the other
            // end: `dropTailRecord` may retire it once its last record is gone, and the row being
            // removed belongs to the block as it stands now. Decrementing afterwards lands on the
            // block *before* the retired one, subtracting the row twice.
            if blocks.count > 0 {
                blocks[blocks.count - 1].rowCount -= 1
            }

            if cursor.rowWithinRecord == 0 {
                dropTailRecord(at: offset)
            } else {
                reopenTailRecordForTruncation()
                cutTail(to: cursor.start, from: record.cellCount, at: offset)
            }
        }

        /// The cell range and row count of a record's last display row at the current width.
        ///
        /// One derivation for the width-change pull-back. `enumerateRows` always fires at least
        /// once (`research/31/DD15`'s one-row floor), so the seeded defaults never survive.
        private func lastRowRange(
            ofRecordAt offset: Int,
            cellCount: Int
        ) -> (start: Int, end: Int, rowCount: Int) {
            var start = 0
            var end = cellCount
            var rowCount = 0
            Instrument.rowBoundaryCellWalk.record(count: cellCount)
            LogicalLineFold.enumerateRows(
                cellCount: cellCount,
                width: width,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            ) { rowIndex, rowStart, rowEnd, _ in
                start = rowStart
                end = rowEnd
                rowCount = rowIndex + 1
            }
            return (start, end, rowCount)
        }

        private mutating func dropTailRecord(at offset: Int) {
            addContentUnitsToTail(-contentContribution(recordIndex: offsets.count - 1))
            removeBoundaryBeforeTailIfNeeded()
            let sequence = firstRecordSequence + offsets.count - 1
            sideTables.removeEntries(at: sequence)
            clearOpenScratch()
            offsets.removeLast()
            writeCursor = recordOffset(in: offset)
            if offsets.count == 0 {
                resetToEmptyArena()
                return
            }
            retireEmptyTailBlocks()
        }

        /// Rewinds the open tail record to `newCellCount`, dropping the side-table entries and
        /// spills the removed cells owned.
        private mutating func cutTail(to newCellCount: Int, from oldCellCount: Int, at offset: Int) {
            let index = offsets.count - 1
            let removedContent = contentCellCount(
                recordIndex: index,
                range: newCellCount..<oldCellCount
            )
            addContentUnitsToTail(-removedContent)
            var removedSpills = 0
            for index in newCellCount..<oldCellCount
                where cellWord(recordAt: offset, cell: index).isSpilled
            {
                removedSpills += 1
            }
            if removedSpills > 0 {
                for _ in 0..<removedSpills {
                    let spill = openSpills.removeLast()
                    openSpillPayloadBytes -= Terminal.arrayStorageHeaderBytes
                        + spill.capacity * MemoryLayout<Unicode.Scalar>.stride
                }
            }

            let keyEnd = originalCellOffset(recordIndex: index, retainedOffset: newCellCount)
            openHyperlinks.removeAll { $0.offset >= keyEnd }
            while let last = openIdentityRuns.last, last.start >= keyEnd {
                openIdentityRuns.removeLast()
            }
            if var last = openIdentityRuns.last, last.start + last.extent > keyEnd {
                last.extent = keyEnd - last.start
                openIdentityRuns[openIdentityRuns.count - 1] = last
            }
            openPreviousIdentity = nil

            var record = self.record(at: offset)
            record.cellCount = newCellCount
            writeHeader(record, at: offset)
            writeCursor = arenaOffset(recordOffset(in: offset) + record.byteLength)
        }

        // MARK: - Operation 5: clear all history

        mutating func removeAll() {
            // Read before anything moves: both totals are derived from the block ring and the
            // evicted counts, and `resetToEmptyArena` empties the ring below.
            let retainedRows = grandDisplayRowTotal
            let retainedContentUnits = grandContentUnitTotal
            evictedRowCount += retainedRows
            evictedContentUnitCount += retainedContentUnits
            firstRecordSequence += offsets.count
            offsets.removeAll()
            resetToEmptyArena()
        }

        // MARK: - The width change

        /// Adopts a new width, pulling the open tail's partial display row back into the live
        /// refold and recomputing the whole index.
        ///
        /// Returns the cells the live grid must take as its continued line's prefix (`research/31/D3`
        /// Decision 4, `research/31/DD16`): without the pull-back a resize leaves a short display row in
        /// the *middle* of a logical line, which today's `reconstructLogicalLines` makes
        /// impossible and inherited condition 10 forbids diverging on.
        ///
        /// No retained byte outside the open tail is written. That is `31/I3` in one sentence:
        /// a width change evicts nothing, at any width down to the engine minimum.
        @discardableResult
        mutating func setWidth(
            _ newWidth: Int,
            follower: Terminal.GridCell? = nil
        ) -> Terminal.GridRow {
            precondition(newWidth >= 1)
            resolvePendingMargin(before: follower)
            width = newWidth
            let pulled = pullBackOpenTailRemainder()
            recomputeIndex()
            return pulled
        }

        private mutating func pullBackOpenTailRemainder() -> Terminal.GridRow {
            guard let record = openTailRecord(), record.cellCount > 0 else {
                return Terminal.GridRow(cells: [])
            }
            let offset = offsets[offsets.count - 1]
            let last = lastRowRange(ofRecordAt: offset, cellCount: record.cellCount)
            guard last.end - last.start < width else { return Terminal.GridRow(cells: []) }

            let index = offsets.count - 1
            var row = Terminal.GridRow(cells: [])
            row.cells.reserveCapacity(last.end - last.start)
            for cellOffset in last.start..<last.end {
                let cell = cell(recordIndex: index, recordOffset: offset, record: record, cellOffset: cellOffset)
                row.append(cell, scalars: scalars(of: cell, recordIndex: index, record: record))
            }
            if last.start == 0 {
                dropTailRecord(at: offset)
            } else {
                cutTail(to: last.start, from: last.end, at: offset)
            }
            return row
        }

        /// Rebuilds the width-dependent row totals without touching width-free content totals.
        ///
        /// Eager rather than lazy by measurement: `research/31/F2` read 0.016 ms at trial depth, `research/31/F7`
        /// 0.76 ms at the record count the budget admits, and `research/31/F9` 5.6 ms on the deepest wide
        /// history at the two-column minimum -- all inside one 60 Hz frame, so neither of
        /// `research/31/D3` Decision 7's mitigations ships.
        private mutating func recomputeIndex() {
            var rowStart = evictedRowCount
            for blockIndex in 0..<blocks.count {
                var rows = 0
                for recordIndex in recordIndices(inBlockAt: blockIndex) {
                    rows += displayRowCount(recordIndex: recordIndex)
                }
                blocks.modifyElement(at: blockIndex) { block in
                    block.rowStart = rowStart
                    block.rowCount = rows
                }
                rowStart += rows
            }
        }

        /// Counts the retained display rows straight off the arena, ignoring every cached total.
        ///
        /// The independent oracle `31/I9` is stated against, and the only thing that catches a
        /// missed invalidation among the six trigger points (`31/AR4`).
        func independentDisplayRowRecount() -> Int {
            var total = 0
            for index in 0..<offsets.count {
                total += displayRowCount(recordIndex: index)
            }
            return total
        }

        /// Counts retained search-projection units straight from record cells and boundaries.
        func independentContentUnitRecount() -> Int {
            var total = 0
            for index in 0..<offsets.count {
                total += independentlyRecountedContentContribution(recordIndex: index)
            }
            return total
        }

        /// Test oracle for each block's maintained content-unit total.
        var contentBlockTotalsForTesting: [Int] {
            (0..<blocks.count).map { blocks[$0].contentCount }
        }

        /// Recounts each current block independently of its cached content total.
        var independentContentBlockTotalsForTesting: [Int] {
            (0..<blocks.count).map { blockIndex in
                // Keep this arithmetic separate from `recordIndices(inBlockAt:)`, so the oracle
                // checks the maintained totals against an independent block mapping.
                let blockNumber = firstBlockNumber + blockIndex
                let first = max(firstRecordSequence, blockNumber * Self.blockSize)
                    - firstRecordSequence
                let end = min(
                    offsets.count,
                    (blockNumber + 1) * Self.blockSize - firstRecordSequence
                )
                return (first..<end).reduce(into: 0) {
                    $0 += independentlyRecountedContentContribution(recordIndex: $1)
                }
            }
        }

        /// Resolves a retained coordinate to its maintained width-free content rank.
        func contentRank(of coordinate: RecordTextPosition) -> Int? {
            guard let index = recordIndex(of: coordinate.record) else { return nil }
            guard let relativeOffset = retainedCellOffset(
                recordIndex: index,
                originalOffset: coordinate.cellOffset
            ) else { return nil }
            let record = self.record(at: offsets[index])
            guard relativeOffset <= record.cellCount else { return nil }
            guard let blockIndex = blockIndex(containingRecordAt: index) else { return nil }
            var rank = blocks[blockIndex].contentStart - evictedContentUnitCount
            let blockFirst = recordIndices(inBlockAt: blockIndex).lowerBound
            for earlier in blockFirst..<index {
                Instrument.searchDistanceWork.record()
                rank += contentContribution(recordIndex: earlier, recordingWork: true)
            }
            rank += contentCellCount(
                recordIndex: index,
                range: 0..<relativeOffset,
                recordingWork: true
            )
            return rank
        }

        /// Width-free content units through the closed prefix, including its trailing hard
        /// boundary when one exists.
        func closedContentUnitTotal(includingTrailingBoundary: Bool) -> Int {
            let count = closedRecordCount
            guard count > 0 else { return 0 }
            let index = count - 1
            let address = offsets[index]
            let record = self.record(at: address)
            let coordinate = RecordTextPosition(
                record: recordIdentity(in: address),
                cellOffset: originalCellOffset(
                    recordIndex: index,
                    retainedOffset: record.cellCount
                )
            )
            guard let rank = contentRank(of: coordinate) else { return 0 }
            let boundary = includingTrailingBoundary ? 1 : 0
            return rank + boundary
        }

        /// Full-walk oracle for `contentRank(of:)`.
        func independentContentRank(of coordinate: RecordTextPosition) -> Int? {
            guard let index = recordIndex(of: coordinate.record) else { return nil }
            guard let relativeOffset = retainedCellOffset(
                recordIndex: index,
                originalOffset: coordinate.cellOffset
            ) else { return nil }
            let record = self.record(at: offsets[index])
            guard relativeOffset <= record.cellCount else { return nil }
            var rank = 0
            for earlier in 0..<index {
                rank += independentlyRecountedContentContribution(recordIndex: earlier)
            }
            rank += independentlyRecountedContentCells(
                recordIndex: index,
                range: 0..<relativeOffset
            )
            return rank
        }

        private func contentContribution(
            recordIndex: Int,
            recordingWork: Bool = false
        ) -> Int {
            let record = self.record(at: offsets[recordIndex])
            let hasFollowingRecord = recordIndex + 1 < offsets.count
            return contentCellCount(
                recordIndex: recordIndex,
                range: 0..<record.cellCount,
                recordingWork: recordingWork
            ) + (
                hasFollowingRecord && record.isOpen == false
                    ? 1 : 0
            )
        }

        private func contentCellCount(
            recordIndex: Int,
            range: Range<Int>,
            recordingWork: Bool = false
        ) -> Int {
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            // Without wide cells every stored cell is one content unit, so the header proves
            // the result without inspecting the range (`research/31/DD4`).
            if record.hasWideCells == false { return range.count }
            var total = 0
            for cellOffset in range {
                if recordingWork { Instrument.searchDistanceWork.record() }
                switch cellKind(recordAt: offset, cell: cellOffset) {
                case .narrow, .wideHead, .padding:
                    total += 1
                case .wideTail, .spacerHead:
                    break
                }
            }
            return total
        }

        /// Full-materialization oracle kept separate from the packed-word counter ranks use.
        private func independentlyRecountedContentContribution(recordIndex: Int) -> Int {
            guard let cells = recordCells(at: recordIndex),
                  let summary = recordSummary(at: recordIndex)
            else { return 0 }
            let content = cells.reduce(into: 0) { total, cell in
                switch cell.kind {
                case .narrow, .wideHead, .padding:
                    total += 1
                case .wideTail, .spacerHead:
                    break
                }
            }
            let hasFollowingRecord = recordIndex + 1 < offsets.count
            return content + (
                hasFollowingRecord && summary.isOpen == false
                    ? 1 : 0
            )
        }

        /// Full-materialization coordinate oracle for the endpoint record.
        private func independentlyRecountedContentCells(
            recordIndex: Int,
            range: Range<Int>
        ) -> Int {
            guard let cells = recordCells(at: recordIndex) else { return 0 }
            return cells[range].reduce(into: 0) { total, cell in
                switch cell.kind {
                case .narrow, .wideHead, .padding:
                    total += 1
                case .wideTail, .spacerHead:
                    break
                }
            }
        }

        // MARK: - Reads

        /// Converts an absolute-from-the-head display row into a record address.
        ///
        /// One binary search over the block totals, then a scan inside the block. A reader plans
        /// a frame with **one** of these and `advance(_:)` for the rest (`research/31/D3` Decision 1).
        func locate(displayRow: Int) -> DisplayRowCursor? {
            Instrument.displayRowLocate.record()
            guard displayRow >= 0, displayRow < grandDisplayRowTotal else { return nil }
            let target = evictedRowCount + displayRow

            var low = 0
            var high = blocks.count - 1
            var found: Int?
            while low <= high {
                let mid = (low + high) / 2
                let block = blocks[mid]
                if target < block.rowStart {
                    high = mid - 1
                } else if target >= block.rowStart + block.rowCount {
                    low = mid + 1
                } else {
                    found = mid
                    break
                }
            }
            // No block claims a row the grand total says exists: that is a stale index rather
            // than a row somewhere else, so say nothing instead of scanning from the head.
            guard let blockIndex = found else { return nil }

            var recordIndex = recordIndices(inBlockAt: blockIndex).lowerBound
            var remaining = target - blocks[blockIndex].rowStart
            while recordIndex < offsets.count {
                let resolved = cursorAndRowCount(
                    recordIndex: recordIndex,
                    requestedRow: remaining
                )
                if let cursor = resolved.cursor { return cursor }
                let rows = resolved.count
                remaining -= rows
                recordIndex += 1
            }
            return nil
        }

        /// The next display row after `cursor`, or nil at the end of history.
        func advance(_ cursor: DisplayRowCursor) -> DisplayRowCursor? {
            guard cursor.recordIndex < offsets.count else { return nil }
            let record = self.record(at: offsets[cursor.recordIndex])
            if cursor.end < record.cellCount {
                return cursorFromBoundary(
                    recordIndex: cursor.recordIndex,
                    rowWithinRecord: cursor.rowWithinRecord + 1,
                    start: cursor.end
                )
            }
            let next = cursor.recordIndex + 1
            guard next < offsets.count else { return nil }
            return cursorFromBoundary(recordIndex: next, rowWithinRecord: 0, start: 0)
        }

        func displayRow(at index: Int) -> Terminal.GridRow? {
            guard let cursor = locate(displayRow: index) else { return nil }
            return gridRow(at: cursor)
        }

        /// Folds one display row out of its record. This is `31/I6`: the cells, kinds, styles,
        /// spacer placement, continuation stamping and soft-wrap marking today's stored rows
        /// carry, derived rather than stored.
        ///
        /// The **content walk**: it stops at the line's cells and never emits a trailing fill,
        /// which is what makes it the right read for copy, selection and search -- the fill is
        /// paint, not text. Renderers want `paintedRow(at:)`.
        func gridRow(at cursor: DisplayRowCursor) -> Terminal.GridRow {
            materializedRow(at: cursor, includeFill: false)
        }

        /// The same display row as the renderer must paint it: content, then the trailing fill
        /// out to the right margin when this is the line's last display row and it carries one.
        ///
        /// The **painted walk**. At the width the row was admitted at this reproduces today's
        /// stored row column for column, including the background-erase paint today keeps as
        /// cells; at any other width the paint follows the content's new end, which is what a
        /// terminal of that width running the same bytes would show. A line with a fill and no
        /// content paints its whole single row, which is the ED-with-background case.
        func paintedRow(at cursor: DisplayRowCursor) -> Terminal.GridRow {
            materializedRow(at: cursor, includeFill: true)
        }

        func paintedDisplayRow(at index: Int) -> Terminal.GridRow? {
            guard let cursor = locate(displayRow: index) else { return nil }
            return paintedRow(at: cursor)
        }

        func recordSummary(at recordIndex: Int) -> RecordSummary? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let record = self.record(at: offsets[recordIndex])
            return RecordSummary(
                cellCount: record.cellCount,
                displayRowCount: displayRowCount(recordIndex: recordIndex),
                isOpen: record.isOpen,
                startsMidLine: record.startsMidLine,
                hasWideCells: record.hasWideCells,
                semanticPrompt: record.semanticPrompt,
                trailingFillStyle: trailingFillStyle(at: recordIndex)
            )
        }

        func recordScalars(at recordIndex: Int) -> [TerminalScalars]? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let record = self.record(at: offsets[recordIndex])
            return (0..<record.cellCount).map {
                scalars(recordIndex: recordIndex, record: record, cellOffset: $0)
            }
        }

        /// One logical line's stored cells, in order. Width-free by construction, which is what
        /// makes `scrollbackRecordContentIdentityShape`'s contract literally true
        /// (`research/31/D3` Decision 6).
        ///
        /// Content only: a trailing fill is never among these cells, so a caller that copies a
        /// logical line copies what the program printed and not what the erase painted.
        func recordCells(at recordIndex: Int) -> [Terminal.GridCell]? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let record = self.record(at: offsets[recordIndex])
            Instrument.recordCellMaterialization.record(count: record.cellCount)
            return (0..<record.cellCount).map { cell(recordIndex: recordIndex, cellOffset: $0) }
        }

        /// Everything a width-free scan of one closed record needs before it reads a cell: its
        /// stable starting position and how many cells it holds.
        ///
        /// Read once per record so a scan states coordinates arithmetically instead of deriving
        /// identity and trim base again for every cell it keys.
        struct ClosedRecordScan: Equatable, Sendable {
            var start: RecordTextPosition
            var cellCount: Int
        }

        /// One closed record's scan facts, without touching a cell.
        func closedRecordScan(at recordIndex: Int) -> ClosedRecordScan? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let address = offsets[recordIndex]
            let record = self.record(at: address)
            guard record.isOpen == false else { return nil }
            return ClosedRecordScan(
                start: RecordTextPosition(
                    record: recordIdentity(in: address),
                    cellOffset: originalCellOffset(recordIndex: recordIndex, retainedOffset: 0)
                ),
                cellCount: record.cellCount
            )
        }

        /// Streams one closed record's stored cells as the kind and scalars a content key reads.
        ///
        /// The width-free counterpart of `withPaintedCells`, and it borrows the arena the same
        /// way and for the same reason: the header, the identity and the backing chunk are
        /// resolved once per record and every cell is one word load through a pointer into the
        /// **local** chunk. Nothing here reads a style, a hyperlink or a content identity, which
        /// is the whole difference from `recordCells(at:)` -- that read decodes a `GridCell` and
        /// binary searches both side tables for every cell, and an index build over closed
        /// history keeps none of it.
        @discardableResult
        func forEachClosedRecordCell(
            at recordIndex: Int,
            _ body: (
                _ cellOffset: Int,
                _ kind: TerminalCellKind,
                _ scalars: TerminalScalars
            ) -> Void
        ) -> ClosedRecordScan? {
            guard let scan = closedRecordScan(at: recordIndex) else { return nil }
            let address = offsets[recordIndex]
            let spills = sideTables.spills(at: firstRecordSequence + recordIndex)
            for cellOffset in 0..<scan.cellCount {
                let word = cellWord(recordAt: address, cell: cellOffset)
                let kind = word.kind
                if word.isSpilled {
                    body(cellOffset, kind, TerminalScalars(spills?.payload(at: word.spillIndex) ?? []))
                } else if let scalar = word.inlineScalar {
                    body(cellOffset, kind, TerminalScalars(scalar))
                } else {
                    body(cellOffset, kind, .empty)
                }
            }
            return scan
        }

        /// Whether the last logical line is still being printed, which is the store's spelling of
        /// "the last retained display row soft-wraps into the live grid".
        var hasOpenTailRecord: Bool { openTailRecord() != nil }

        /// The remembered blank a seam reader shows when the live follower is not a wide head.
        var openTailPendingMarginCell: Terminal.GridCell? {
            pendingMarginStyleId.map { Terminal.GridCell(kind: .padding, styleId: $0) }
        }

        /// A copy of this store at a different byte budget, retaining the newest rows that fit.
        ///
        /// The arena fixes its whole address-space capacity at construction (`31/I2`), so a
        /// store cannot be re-bounded in place. Replay uses the source fold's exact cell ranges
        /// instead of re-admitting materialized rows, which would expand an open tail's short
        /// final row to the full width.
        func rebased(toBudgetBytes newBudget: Int) -> LogicalLineStore {
            var copy = LogicalLineStore(budgetBytes: newBudget, width: width)
            for index in 0..<offsets.count {
                let record = self.record(at: offsets[index])
                let cells = (0..<record.cellCount).map {
                    cell(recordIndex: index, cellOffset: $0)
                }
                let payloads = (0..<record.cellCount).map {
                    scalars(recordIndex: index, record: record, cellOffset: $0)
                }
                var copiedRows = 0
                LogicalLineFold.enumerateRows(
                    cellCount: record.cellCount,
                    width: width,
                    isWideHead: { cells[$0].kind == .wideHead }
                ) { row, start, end, _ in
                    let cellCount = end - start
                    let hyperlinkEntries = cells[start..<end].count { $0.hyperlinkId != nil }
                    let identityEntries = cells[start..<end].count { $0.contentIdentity != nil }
                    let retainedCells = max(1, cellCount)
                    let hyperlinkBytes = hyperlinkEntries == 0 ? 0 : min(
                        hyperlinkEntries * LogicalLineRecord.hyperlinkEntryBytes,
                        LogicalLineRecord.hyperlinkCellTableBytes(forCells: retainedCells)
                    )
                    let identityBytes = identityEntries == 0 ? 0 : min(
                        identityEntries * LogicalLineRecord.identityRunEntryBytes,
                        retainedCells * LogicalLineRecord.identityCellBytes
                    )
                    let emptyRecordBytes = LogicalLineRecord.Header.byteCount
                        + cellCount * LogicalLineRecord.cellBytes
                        + hyperlinkBytes + identityBytes + LogicalLineRecord.cellBytes
                    guard emptyRecordBytes <= copy.arenaCapacity else { return }

                    copy.makeRoom(
                        forCells: cellCount,
                        hyperlinkEntries: hyperlinkEntries,
                        identityRuns: identityEntries
                    )
                    copy.openRecordIfNeeded(mark: row == 0 ? record.semanticPrompt : .none)
                    if record.startsMidLine || row > 0 { copy.markTailStartsMidLine() }
                    if cellCount > 0 {
                        cells.withUnsafeBufferPointer { source in
                            let slice = UnsafeBufferPointer(rebasing: source[start..<end])
                            copy.appendCells(slice) { payloads[start + $0] }
                        }
                    }
                    copy.addDisplayRowsToTail(1)
                    copiedRows += 1
                }
                guard copiedRows > 0 else { continue }
                copy.setTrailingFillOnTail(trailingFillStyle(at: index))
                if record.isOpen == false {
                    copy.closeOpenRecord()
                }
            }
            if copy.hasOpenTailRecord {
                copy.pendingMarginStyleId = pendingMarginStyleId
            }
            return copy
        }

        private mutating func markTailStartsMidLine() {
            guard offsets.count > 0 else { return }
            let offset = offsets[offsets.count - 1]
            var record = self.record(at: offset)
            record.startsMidLine = true
            writeHeader(record, at: offset)
        }

        /// Compares what history *holds*, not where it holds it.
        ///
        /// Two panes fed the same bytes *at the same budget* are the same history however the
        /// ring cursor got there --
        /// the arena's byte offsets and unwritten tail are placement, not content.
        /// So this compares the retained logical lines and the counters a reader can observe, on
        /// the same principle `Terminal`'s own `Equatable` states about equal screen state.
        /// Nothing is decoded and nothing is allocated, which is the whole of the difference
        /// from what this used to do: comparing `recordCells(at:)` per record built a fresh
        /// `[Terminal.GridCell]` for every retained logical line and decoded every cell in it,
        /// with both side-table probes, on both sides. Before owner publication switched to the
        /// damage accumulator, `Terminal` equality reached this comparison on every pointer move;
        /// `research/31/F13` measured the decoded form at 9.3% of whole-process CPU under ambient
        /// mouse motion. Equality remains a value-semantics oracle for tests.
        static func == (lhs: Self, rhs: Self) -> Bool {
            Instrument.wholeStoreEquality.record()
            guard lhs.budget == rhs.budget,
                  lhs.width == rhs.width,
                  lhs.evictedRowCount == rhs.evictedRowCount,
                  lhs.grandDisplayRowTotal == rhs.grandDisplayRowTotal,
                  lhs.pendingMarginStyleId == rhs.pendingMarginStyleId,
                  lhs.offsets.count == rhs.offsets.count
            else { return false }
            for index in 0..<lhs.offsets.count {
                guard recordsHoldTheSameContent(lhs, rhs, at: index) else { return false }
            }
            return true
        }

        /// Whether both stores' record at `index` holds the same content, compared as stored
        /// bytes rather than as decoded cells.
        ///
        /// Sound because a record's bytes are a function of its content alone (`31/I1`): equal
        /// header, equal cell words and equal side-table entries mean every reader sees the same
        /// cells. The one thing the bytes do not carry is the key base the head record's tables
        /// are read against, which a head trim moves (`research/31/D2` Decision 2 step 3) -- so a trimmed
        /// head carrying a table falls back to comparing what a reader would actually see.
        ///
        /// The header word subsumes what `recordSummary` would compare and is why `==` no longer
        /// builds one per record per side: the cell count, both table counts and every flag are
        /// in it, and the display-row count is derived from those and the width. An open record's
        /// scratch tables are compared directly because its zero header counts do not name them.
        private static func recordsHoldTheSameContent(
            _ lhs: Self,
            _ rhs: Self,
            at index: Int
        ) -> Bool {
            let leftOffset = lhs.offsets[index]
            let rightOffset = rhs.offsets[index]
            let left = lhs.record(at: leftOffset)
            let right = rhs.record(at: rightOffset)
            guard left.word == right.word else { return false }

            let leftSpills = lhs.spills(recordIndex: index, record: left)
            let rightSpills = rhs.spills(recordIndex: index, record: right)
            if leftSpills?.base != rightSpills?.base
                || (index == 0 && (
                    lhs.headTrimmedCells != rhs.headTrimmedCells
                        || lhs.headTableCellBase != rhs.headTableCellBase
                ))
            {
                return decodedRecordsHoldTheSameContent(lhs, rhs, at: index, record: left)
            }

            // Compare the stored words directly when both records use the same bases. The
            // wrapped accessor crosses chunk boundaries and the arena end without making either
            // boundary part of the logical record.
            for cell in 0..<left.cellCount {
                guard lhs.cellWord(recordAt: leftOffset, cell: cell).raw
                    == rhs.cellWord(recordAt: rightOffset, cell: cell).raw
                else { return false }
            }

            if left.isOpen {
                return lhs.openHyperlinks == rhs.openHyperlinks
                    && lhs.openIdentityRuns == rhs.openIdentityRuns
                    && leftSpills == rightSpills
                    && lhs.trailingFillStyle(at: index) == rhs.trailingFillStyle(at: index)
            }

            let leftBase = lhs.recordByteOffset(
                leftOffset,
                LogicalLineRecord.headerAndCells(left.cellCount)
            )
            let rightBase = rhs.recordByteOffset(
                rightOffset,
                LogicalLineRecord.headerAndCells(left.cellCount)
            )
            let tableBytes = lhs.storedByteLength(
                of: left,
                headTableBase: index == 0 ? lhs.headTableCellBase : 0
            ) - LogicalLineRecord.headerAndCells(left.cellCount)
            for field in stride(from: 0, to: tableBytes, by: 4) {
                guard lhs.u32(leftBase + field) == rhs.u32(rightBase + field) else { return false }
            }

            if left.hasTrailingFill,
               lhs.sideTables.fillStyle(at: lhs.firstRecordSequence + index)
                   != rhs.sideTables.fillStyle(at: rhs.firstRecordSequence + index)
            {
                return false
            }

            return leftSpills == rightSpills
        }

        private static func decodedRecordsHoldTheSameContent(
            _ lhs: Self,
            _ rhs: Self,
            at index: Int,
            record: LogicalLineRecord
        ) -> Bool {
            for cell in 0..<record.cellCount {
                guard lhs.cell(recordIndex: index, cellOffset: cell)
                    == rhs.cell(recordIndex: index, cellOffset: cell),
                      lhs.scalars(recordIndex: index, record: record, cellOffset: cell)
                    == rhs.scalars(recordIndex: index, record: record, cellOffset: cell)
                else { return false }
            }
            return lhs.trailingFillStyle(at: index) == rhs.trailingFillStyle(at: index)
        }

        /// Every painted retained display row in `range`, oldest first.
        ///
        /// Contiguous readers locate the first row once, then carry its cursor through the rest
        /// of the range. The optional callback lets tail truncation retain those same cursors for
        /// its cut pass instead of deriving the boundaries again. Every returned row contributes
        /// once to `retainedRowMaterialization`, including partial ranges.
        func paintedDisplayRows(
            in range: Range<Int>,
            onCursor: ((DisplayRowCursor) -> Void)? = nil
        ) -> [Terminal.GridRow] {
            let lowerBound = max(0, range.lowerBound)
            let upperBound = min(grandDisplayRowTotal, range.upperBound)
            guard lowerBound < upperBound else { return [] }

            Instrument.retainedRowMaterialization.record(count: upperBound - lowerBound)
            var result: [Terminal.GridRow] = []
            result.reserveCapacity(upperBound - lowerBound)
            var cursor = locate(displayRow: lowerBound)
            while let current = cursor, result.count < upperBound - lowerBound {
                onCursor?(current)
                result.append(paintedRow(at: current))
                if result.count < upperBound - lowerBound {
                    cursor = advance(current)
                }
            }
            return result
        }

        /// Every retained display row, oldest first, as the renderer must paint it.
        func allPaintedDisplayRows() -> [Terminal.GridRow] {
            paintedDisplayRows(in: 0..<grandDisplayRowTotal)
        }

        /// Visits every style id retained by the arena without constructing display rows or cells.
        ///
        /// Cell words own ordinary and spacer-head styles. A trailing background-erase fill and
        /// the open tail's pending margin are metadata rather than cells, so the walk includes
        /// both explicitly.
        func forEachStyleId(_ body: (Terminal.StyleId) -> Void) {
            var visitedCellCount = 0
            for index in 0..<offsets.count {
                let offset = offsets[index]
                let record = self.record(at: offset)
                visitedCellCount += record.cellCount
                for cell in 0..<record.cellCount {
                    body(cellWord(recordAt: offset, cell: cell).styleId)
                }
                if let fill = trailingFillStyle(at: index) { body(fill) }
            }
            if let pendingMarginStyleId { body(pendingMarginStyleId) }
            Instrument.retainedStyleLivenessCellVisit.record(count: visitedCellCount)
        }

        /// Spill tables the store holds -- one per retained record whose cells spilled, plus the
        /// open tail's own table, which lives outside the side tables until the record closes.
        ///
        /// The unit a storage census counts, because a table is the allocation: a record with ten
        /// spilled cells still costs one.
        var spillTableCount: Int {
            sideTables.spillTableCount + (openSpills.isEmpty ? 0 : 1)
        }

        /// Visits every stored cell word retained by the arena without folding display rows.
        ///
        /// The callback receives only representation-level fields needed by storage accounting;
        /// synthesized trailing fill and spacer cells do not occupy words and never enter it.
        func forEachStoredCell(
            _ body: (_ styleId: Terminal.StyleId, _ isSpilled: Bool) -> Void
        ) {
            for index in 0..<offsets.count {
                let offset = offsets[index]
                let record = self.record(at: offset)
                for cell in 0..<record.cellCount {
                    let word = cellWord(recordAt: offset, cell: cell)
                    body(word.styleId, word.isSpilled)
                }
            }
        }

        /// Visits every hyperlink id retained by the arena's compact per-record tables.
        ///
        /// A trimmed head keeps its table in place and advances the cells beneath its header, so
        /// entries for the evicted prefix must be skipped just as cell decoding skips them.
        func forEachHyperlinkId(_ body: (Terminal.HyperlinkId) -> Void) {
            for index in 0..<offsets.count {
                guard let cells = recordCells(at: index) else { continue }
                for cell in cells {
                    if let id = cell.hyperlinkId { body(id) }
                }
            }
        }

        /// Visits every content identity attached to a retained stored cell.
        ///
        /// Identity table coordinates predate a head trim, so the retained window is applied to
        /// both the open-tail runs and the closed record's run or per-cell encoding.
        func forEachContentIdentity(_ body: (Terminal.ContentIdentity) -> Void) {
            for index in 0..<offsets.count {
                guard let cells = recordCells(at: index) else { continue }
                for cell in cells {
                    if let identity = cell.contentIdentity { body(identity) }
                }
            }
        }

        /// Borrows one display row's painted cells without materializing a `GridRow`.
        ///
        /// The frame path's read, and the reason milestone 1 lands the arena on exactly the path
        /// `research/31/F1` measured (`research/31/D3` Decision 5): `research/28/F17` found the per-row `GridRow` allocation
        /// to be the dominant term of the browsing regression, and a facade that materialized here
        /// would put it straight back. Columns ascend from zero and stop at the row's painted
        /// extent; the caller pads the rest, exactly as the packed-row reader's contract did.
        func withPaintedCells(
            at cursor: DisplayRowCursor,
            _ body: (
                _ count: Int,
                _ styleIdAt: (_ column: Int) -> Terminal.StyleId,
                _ cellAt: (_ column: Int) -> (
                    kind: TerminalCellKind,
                    scalars: TerminalScalars
                )
            ) -> Void
        ) {
            let shape = foldedRow(at: cursor, includeFill: true)
            let spills = spills(recordIndex: cursor.recordIndex, record: shape.record)

            let storedCount = shape.end - shape.start
            let spacerWord = shape.spacerRecordIndex >= 0
                ? cellWord(
                    recordAt: offsets[shape.spacerRecordIndex],
                    cell: shape.spacerOffset
                )
                : nil
            let paintedCount = storedCount + (spacerWord == nil ? 0 : 1)
            let count = shape.fillStyle == nil ? paintedCount : width

            // The two column classifications, shared by both storage paths below. Each takes
            // the stored word by value so neither path pays a closure call per cell.
            @inline(__always) func styleId(column: Int, stored: () -> CellWord) -> Terminal.StyleId {
                if column < storedCount { return stored().styleId }
                if column == storedCount, let spacerWord { return spacerWord.styleId }
                return shape.fillStyle ?? Terminal.defaultStyleId
            }
            @inline(__always) func cell(
                column: Int,
                stored: () -> CellWord
            ) -> (kind: TerminalCellKind, scalars: TerminalScalars) {
                if column == storedCount, spacerWord != nil { return (.spacerHead, .empty) }
                guard column < storedCount else { return (.padding, .empty) }
                let word = stored()
                let kind = word.kind
                if word.isSpilled {
                    return (kind, TerminalScalars(spills?.payload(at: word.spillIndex) ?? []))
                }
                // The explicit branch rather than `.map(...) ?? .empty`: the optional form builds
                // and consumes a temporary `TerminalScalars` per cell, which the browse profile
                // shows as a second `outlined consume` on every painted cell.
                if let scalar = word.inlineScalar {
                    return (kind, TerminalScalars(scalar))
                }
                return (kind, .empty)
            }

            // A row that fits one chunk keeps D5's single pointer hoist: the chunk is resolved
            // once per display row and read through a raw pointer per cell, with no closure
            // between the caller and the word. The pointer rather than the array subscript
            // because the subscript is the one place this loop pays for something it can prove:
            // a bounds check per cell, plus the `immutableCount` load that feeds it. The buffer
            // is borrowed from the **local** `chunk`, not from `self.chunks`, so `body` -- an
            // arbitrary caller closure -- cannot conflict with the access and no dynamic
            // exclusivity check replaces the static one; a nested-closure shape here measured
            // that enforcement at about 210 us per frame, and an `@escaping` word accessor
            // measured a 2% frame regression on `retained-browse`. Only a row that straddles a
            // chunk or the arena wrap uses the segmented accessor.
            if let range = singleChunkCellRange(
                recordAt: shape.recordOffset,
                start: shape.start,
                count: storedCount
            ) {
                let chunk = chunks[range.chunk]
                chunk.withUnsafeBufferPointer { words in
                    // One pointer to the row's first cell, so the per-cell closures capture a
                    // single word rather than a buffer plus an offset: the extra capture pushed
                    // an argument onto the stack on every cell call.
                    let cells = words.baseAddress! + range.word
                    body(
                        count,
                        { column in styleId(column: column) { CellWord(raw: cells[column]) } },
                        { column in cell(column: column) { CellWord(raw: cells[column]) } }
                    )
                }
            } else {
                body(
                    count,
                    { column in
                        styleId(column: column) {
                            cellWord(recordAt: shape.recordOffset, cell: shape.start + column)
                        }
                    },
                    { column in
                        cell(column: column) {
                            cellWord(recordAt: shape.recordOffset, cell: shape.start + column)
                        }
                    }
                )
            }
        }

        /// Visits painted cells for representation tests that compare the packed walk directly.
        func forEachPaintedCell(
            at cursor: DisplayRowCursor,
            _ body: (
                _ column: Int,
                _ kind: TerminalCellKind,
                _ scalars: TerminalScalars,
                _ styleId: Terminal.StyleId
            ) -> Void
        ) {
            withPaintedCells(at: cursor) { count, styleIdAt, cellAt in
                for column in 0..<count {
                    let cell = cellAt(column)
                    body(column, cell.kind, cell.scalars, styleIdAt(column))
                }
            }
        }

        /// Visits one display row's cell kinds, which is all a geometry projection carries.
        func forEachKind(
            at cursor: DisplayRowCursor,
            _ body: (_ column: Int, _ kind: TerminalCellKind) -> Void
        ) {
            let shape = foldedRow(at: cursor, includeFill: true)
            var column = 0
            let storedCount = shape.end - shape.start
            if let range = singleChunkCellRange(
                recordAt: shape.recordOffset,
                start: shape.start,
                count: storedCount
            ) {
                let chunk = chunks[range.chunk]
                chunk.withUnsafeBufferPointer { words in
                    for index in 0..<storedCount {
                        body(column, CellWord(raw: words[range.word + index]).kind)
                        column += 1
                    }
                }
            } else {
                for cellOffset in shape.start..<shape.end {
                    body(column, cellWord(recordAt: shape.recordOffset, cell: cellOffset).kind)
                    column += 1
                }
            }
            if shape.spacerRecordIndex >= 0 {
                body(column, .spacerHead)
                column += 1
            }
            guard shape.fillStyle != nil else { return }
            for filled in fillColumns(shape) {
                body(filled, .padding)
            }
        }

        /// The record address a display row's column names, under the fold in force now.
        ///
        /// One half of `research/31/D3` Decision 2's function pair: an anchor is captured through this
        /// before a width change and restated through `position(ofRecord:cellOffset:)` after, which
        /// is the whole of what replaces the reflow attachment machinery on the history side. The
        /// address is a transient -- it is never stored in an anchor and never leaves this module.
        func address(ofDisplayRow row: Int, column: Int) -> (recordIndex: Int, cellOffset: Int)? {
            guard let cursor = locate(displayRow: row) else { return nil }
            return (cursor.recordIndex, min(cursor.start + max(0, column), cursor.end))
        }

        /// Captures a cell boundary in a closed record without storing its display geometry.
        func recordTextPosition(
            recordIndex: Int,
            cellOffset: Int
        ) -> RecordTextPosition? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let address = offsets[recordIndex]
            let record = self.record(at: address)
            guard record.isOpen == false, cellOffset >= 0, cellOffset <= record.cellCount else {
                return nil
            }
            return RecordTextPosition(
                record: recordIdentity(in: address),
                cellOffset: originalCellOffset(
                    recordIndex: recordIndex,
                    retainedOffset: cellOffset
                )
            )
        }

        /// Returns a retained record's stable identity for index maintenance.
        func recordIdentity(at recordIndex: Int) -> RecordIdentity? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            return recordIdentity(in: offsets[recordIndex])
        }

        /// Resolves a stable identity to its current retained sequence position.
        func recordIndex(of identity: RecordIdentity) -> Int? {
            var low = 0
            var high = offsets.count
            while low < high {
                let middle = low + (high - low) / 2
                if recordIdentity(in: offsets[middle]) < identity {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low < offsets.count, recordIdentity(in: offsets[low]) == identity else {
                return nil
            }
            return low
        }

        /// Resolves a retained record coordinate under the current width, or nil once retired.
        func position(of coordinate: RecordTextPosition) -> (displayRow: Int, column: Int)? {
            var low = 0
            var high = offsets.count
            while low < high {
                let middle = low + (high - low) / 2
                if recordIdentity(in: offsets[middle]) < coordinate.record {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low < offsets.count, recordIdentity(in: offsets[low]) == coordinate.record else {
                return nil
            }
            guard let relativeOffset = retainedCellOffset(
                recordIndex: low,
                originalOffset: coordinate.cellOffset
            ) else { return nil }
            return position(ofRecord: low, cellOffset: relativeOffset)
        }

        /// Where a record's cell offset folds to, under the fold in force now.
        ///
        /// Nil when the offset is no longer in the record, which a width change can produce for
        /// exactly one region: the open tail's partial last display row, whose cells `setWidth`
        /// hands back to the live grid.
        func position(
            ofRecord recordIndex: Int,
            cellOffset: Int
        ) -> (displayRow: Int, column: Int)? {
            guard recordIndex >= 0, recordIndex < offsets.count else { return nil }
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            guard cellOffset >= 0, cellOffset <= record.cellCount else { return nil }
            Instrument.recordPositionResolution.record()
            // The fold collapses to arithmetic whenever no wide cell can meet a row boundary --
            // the same fast path, and the same `hasWideCells` reasoning, as `rowCount`'s. It is
            // worth taking here because resolving a coordinate is per-visible-match frame work
            // (`31/AR3`) and the walk below has no early exit.
            if record.hasWideCells == false || width < 2 {
                // The record's end boundary belongs to its last row rather than opening a new
                // one, which is the only case the division gets wrong.
                if cellOffset == record.cellCount, cellOffset > 0, cellOffset % width == 0 {
                    return (firstDisplayRow(ofRecord: recordIndex) + cellOffset / width - 1, width)
                }
                return (
                    firstDisplayRow(ofRecord: recordIndex) + cellOffset / width,
                    cellOffset % width
                )
            }
            var localRow = 0
            var column = 0
            var resolved = false
            LogicalLineFold.enumerateRows(
                cellCount: record.cellCount,
                width: width,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            ) { rowIndex, start, end, _ in
                guard resolved == false else { return }
                // The last row claims the record's end boundary, which is the one offset that is
                // past every row's content and still names a position.
                if cellOffset < end || end == record.cellCount {
                    localRow = rowIndex
                    column = cellOffset - start
                    resolved = cellOffset < end
                }
            }
            return (firstDisplayRow(ofRecord: recordIndex) + localRow, max(0, column))
        }

        /// The record's first display row, counted from the oldest retained one.
        private func firstDisplayRow(ofRecord recordIndex: Int) -> Int {
            guard let blockIndex = blockIndex(containingRecordAt: recordIndex) else { return 0 }
            var total = blocks[blockIndex].rowStart - evictedRowCount
            let blockFirst = recordIndices(inBlockAt: blockIndex).lowerBound
            for index in blockFirst..<recordIndex {
                total += displayRowCount(recordIndex: index)
            }
            return total
        }

        /// Whether this display row wraps into the next one, without folding its cells.
        func isSoftWrapped(at cursor: DisplayRowCursor) -> Bool {
            let record = self.record(at: offsets[cursor.recordIndex])
            return cursor.end < record.cellCount || record.isOpen
        }

        // MARK: - Fold

        private func displayRowCount(recordIndex: Int) -> Int {
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            if record.hasWideCells, width >= 2 {
                Instrument.rowBoundaryCellWalk.record(count: record.cellCount)
            }
            return LogicalLineFold.rowCount(
                cellCount: record.cellCount,
                width: width,
                hasWideCells: record.hasWideCells,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            )
        }

        /// Resolves one indexed row while performing the selected record's required count walk.
        private func cursorAndRowCount(
            recordIndex: Int,
            requestedRow: Int
        ) -> (cursor: DisplayRowCursor?, count: Int) {
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            guard record.hasWideCells, width >= 2 else {
                let count = max(1, (record.cellCount + width - 1) / width)
                guard requestedRow < count else { return (nil, count) }
                return (
                    cursorFromBoundary(
                        recordIndex: recordIndex,
                        rowWithinRecord: requestedRow,
                        start: min(requestedRow * width, record.cellCount)
                    ),
                    count
                )
            }

            var selected: DisplayRowCursor?
            Instrument.rowBoundaryCellWalk.record(count: record.cellCount)
            let count = LogicalLineFold.enumerateRows(
                cellCount: record.cellCount,
                width: width,
                isWideHead: { self.isWideHead(recordAt: offset, cell: $0) }
            ) { row, start, end, spacer in
                guard row == requestedRow else { return }
                selected = makeCursor(
                    recordIndex: recordIndex,
                    rowWithinRecord: row,
                    start: start,
                    end: end,
                    spacerAtEnd: spacer
                )
            }
            return (selected, count)
        }

        /// Resolves the row that begins at a known boundary without revisiting earlier cells.
        private func cursorFromBoundary(
            recordIndex: Int,
            rowWithinRecord: Int,
            start: Int
        ) -> DisplayRowCursor {
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            guard record.hasWideCells, width >= 2 else {
                return makeCursor(
                    recordIndex: recordIndex,
                    rowWithinRecord: rowWithinRecord,
                    start: start,
                    end: min(start + width, record.cellCount),
                    spacerAtEnd: false
                )
            }

            var index = start
            var column = 0
            var spacer = false
            while index < record.cellCount {
                if column == width - 1, isWideHead(recordAt: offset, cell: index) {
                    spacer = true
                    break
                }
                column += 1
                index += 1
                if column == width { break }
            }
            if start == 0 {
                let traversed = index - start + (spacer ? 1 : 0)
                Instrument.rowBoundaryCellWalk.record(count: traversed)
            }
            return makeCursor(
                recordIndex: recordIndex,
                rowWithinRecord: rowWithinRecord,
                start: start,
                end: index,
                spacerAtEnd: spacer
            )
        }

        /// Attaches the in-record spacer source to a resolved cell range.
        private func makeCursor(
            recordIndex: Int,
            rowWithinRecord: Int,
            start: Int,
            end: Int,
            spacerAtEnd: Bool
        ) -> DisplayRowCursor {
            let record = self.record(at: offsets[recordIndex])
            var spacerRecordIndex = -1
            var spacerOffset = 0
            if spacerAtEnd, end < record.cellCount {
                spacerRecordIndex = recordIndex
                spacerOffset = end
            }
            return DisplayRowCursor(
                recordIndex: recordIndex,
                rowWithinRecord: rowWithinRecord,
                start: start,
                end: end,
                spacerRecordIndex: spacerRecordIndex,
                spacerOffset: spacerOffset
            )
        }

        /// The one materializer behind `gridRow(at:)` and `paintedRow(at:)`: the folded walk
        /// appends each cell with its scalars in a single pass, so the content and painted
        /// reads differ only in `includeFill` and cannot drift apart on kinds, spills, wrap
        /// marking or the prompt stamp.
        private func materializedRow(at cursor: DisplayRowCursor, includeFill: Bool) -> Terminal.GridRow {
            let record = self.record(at: offsets[cursor.recordIndex])
            var row = Terminal.GridRow(cells: [])
            row.cells.reserveCapacity(width)
            forEachFoldedCell(at: cursor, includeFill: includeFill) { _, cell in
                row.append(cell, scalars: scalars(of: cell, recordIndex: cursor.recordIndex, record: record))
            }
            row.isSoftWrapped = isSoftWrapped(at: cursor)
            if cursor.rowWithinRecord == 0 {
                row.semanticPrompt = record.semanticPrompt
            } else {
                row.semanticPrompt = Terminal.continuationMark(forLineHead: record.semanticPrompt)
            }
            return row
        }

        /// What columns one display row occupies: the record's cell range, the derived
        /// `.spacerHead` that may follow it, and the trailing fill that may follow that.
        ///
        /// The **one** definition of a display row's shape, so the materializing read and the two
        /// borrowing ones cannot drift apart on a spacer or a fill. What each read
        /// then does with a column is its own -- and is the whole point of having three
        /// (`research/31/F13`: the frame path was materializing a `GridCell` per cell, plus both side-table
        /// probes, for readers that keep two fields or three bits).
        private struct FoldedRow {
            var recordOffset = 0
            var record = LogicalLineRecord()
            /// Half-open cell range this display row draws from the record.
            var start = 0
            var end = 0
            /// The record and cell offset of the wide head a derived spacer defers, or -1 for
            /// none.
            var spacerRecordIndex = -1
            var spacerOffset = 0
            /// The style this row's tail is painted in past `end`, when it carries one and the
            /// caller asked for the painted walk.
            var fillStyle: Terminal.StyleId?
        }

        /// Resolves one display row's shape.
        ///
        /// `includeFill` selects the content/painted split: the content walk stops at the
        /// line's cells because the fill is paint rather than text, and the painted
        /// walk runs it out to the right margin on the line's last display row.
        private func foldedRow(at cursor: DisplayRowCursor, includeFill: Bool) -> FoldedRow {
            let recordIndex = cursor.recordIndex
            let offset = offsets[recordIndex]
            let record = self.record(at: offset)
            var shape = FoldedRow(recordOffset: offset, record: record)
            let validRange = cursor.start >= 0 && cursor.start <= cursor.end
                && cursor.end <= record.cellCount
            shape.start = validRange ? cursor.start : 0
            shape.end = validRange ? cursor.end : 0

            if cursor.spacerRecordIndex >= 0,
               cursor.spacerRecordIndex < offsets.count
            {
                let spacerRecord = self.record(at: offsets[cursor.spacerRecordIndex])
                if cursor.spacerOffset >= 0, cursor.spacerOffset < spacerRecord.cellCount {
                    shape.spacerRecordIndex = cursor.spacerRecordIndex
                    shape.spacerOffset = cursor.spacerOffset
                }
            }

            // `research/31/DD15`'s floor: a zero-cell record folds to one display row, and the
            // enumeration emits nothing for it -- so the record's last row is row 0, not row -1.
            // Missing this drops the fill on exactly the ED-with-background case it exists for.
            if includeFill, shape.end == record.cellCount {
                shape.fillStyle = trailingFillStyle(at: recordIndex)
            }
            return shape
        }

        /// The columns past a row's content that its trailing fill paints, or an empty range.
        private func fillColumns(_ shape: FoldedRow) -> Range<Int> {
            guard shape.fillStyle != nil else { return 0..<0 }
            let painted = shape.end - shape.start + (shape.spacerRecordIndex >= 0 ? 1 : 0)
            return painted < width ? painted..<width : 0..<0
        }

        /// The materializing walk: one whole `GridCell` per column, for the readers that build a
        /// `GridRow`. `withPaintedCells` and `forEachKind` deliberately do not come through here.
        private func forEachFoldedCell(
            at cursor: DisplayRowCursor,
            includeFill: Bool,
            _ body: (_ column: Int, _ cell: Terminal.GridCell) -> Void
        ) {
            let shape = foldedRow(at: cursor, includeFill: includeFill)
            var column = 0
            for cellOffset in shape.start..<shape.end {
                body(
                    column,
                    cell(
                        recordIndex: cursor.recordIndex,
                        recordOffset: shape.recordOffset,
                        record: shape.record,
                        cellOffset: cellOffset
                    )
                )
                column += 1
            }
            if shape.spacerRecordIndex >= 0 {
                body(
                    column,
                    spacerDeferring(
                        cell(recordIndex: shape.spacerRecordIndex, cellOffset: shape.spacerOffset)
                    )
                )
                column += 1
            }
            guard let fill = shape.fillStyle else { return }
            let painted = Terminal.GridCell(scalars: .empty, kind: .padding, styleId: fill)
            for filled in fillColumns(shape) {
                body(filled, painted)
            }
        }

        /// The `.spacerHead` a wide head defers, carrying the head's attributes exactly as
        /// `Terminal.pack(line:columns:)` gives them to it.
        private func spacerDeferring(_ head: Terminal.GridCell) -> Terminal.GridCell {
            Terminal.GridCell(
                scalars: .empty,
                kind: .spacerHead,
                styleId: head.styleId,
                hyperlinkId: head.hyperlinkId,
                contentIdentity: head.contentIdentity
            )
        }

        // MARK: - Cell decoding

        /// Converts a retained-relative offset into the original key used by every side table.
        private func originalCellOffset(
            recordIndex: Int,
            retainedOffset: Int
        ) -> OriginalCellOffset {
            let retainedStart = recordIndex == 0
                ? headTrimmedCells
                : OriginalCellOffset(value: 0)
            return retainedStart + retainedOffset
        }

        /// Converts an original side-table key into a retained-relative cell offset.
        private func retainedCellOffset(
            recordIndex: Int,
            originalOffset: OriginalCellOffset
        ) -> Int? {
            let retainedStart = originalCellOffset(recordIndex: recordIndex, retainedOffset: 0)
            guard originalOffset >= retainedStart else { return nil }
            return originalOffset - retainedStart
        }

        private func cell(recordIndex: Int, cellOffset: Int) -> Terminal.GridCell {
            let offset = offsets[recordIndex]
            return cell(
                recordIndex: recordIndex,
                recordOffset: offset,
                record: record(at: offset),
                cellOffset: cellOffset
            )
        }

        /// The same decode with the record's address and header supplied by the caller, so a walk
        /// over a row does not re-read the ring's offset slot and re-decode eleven header fields
        /// once per column (`research/31/F13`).
        private func cell(
            recordIndex: Int,
            recordOffset offset: Int,
            record: LogicalLineRecord,
            cellOffset: Int
        ) -> Terminal.GridCell {
            let word = cellWord(recordAt: offset, cell: cellOffset)
            let keyOffset = originalCellOffset(
                recordIndex: recordIndex,
                retainedOffset: cellOffset
            )

            return Terminal.GridCell(
                word: word,
                hyperlinkId: hyperlinkId(record: record, at: offset, keyOffset: keyOffset),
                contentIdentity: contentIdentity(record: record, at: offset, keyOffset: keyOffset)
            )
        }

        private func scalars(
            recordIndex: Int,
            record: LogicalLineRecord,
            cellOffset: Int
        ) -> TerminalScalars {
            let word = cellWord(recordAt: offsets[recordIndex], cell: cellOffset)
            if word.isSpilled {
                return TerminalScalars(
                    spills(recordIndex: recordIndex, record: record)?.payload(at: word.spillIndex) ?? []
                )
            }
            return word.inlineScalar.map(TerminalScalars.init) ?? .empty
        }

        private func scalars(
            of cell: Terminal.GridCell,
            recordIndex: Int,
            record: LogicalLineRecord
        ) -> TerminalScalars {
            if cell.word.isSpilled {
                return TerminalScalars(
                    spills(recordIndex: recordIndex, record: record)?.payload(at: cell.word.spillIndex) ?? []
                )
            }
            return cell.word.inlineScalar.map(TerminalScalars.init) ?? .empty
        }

        /// Resolves a spill payload from the open scratch or the closed-record table according
        /// to the record's current owner.
        private func spills(
            recordIndex: Int,
            record: LogicalLineRecord
        ) -> SequenceKeyedSideTables.SpillTable? {
            if record.isOpen {
                return openSpills.isEmpty
                    ? nil
                    : SequenceKeyedSideTables.SpillTable(
                        base: openSpillBase,
                        payloads: openSpills
                    )
            }
            return sideTables.spills(at: firstRecordSequence + recordIndex)
        }

        private func hyperlinkId(
            record: LogicalLineRecord,
            at offset: Int,
            keyOffset: OriginalCellOffset
        ) -> Terminal.HyperlinkId? {
            if record.isOpen {
                var low = 0
                var high = openHyperlinks.count - 1
                while low <= high {
                    let mid = (low + high) / 2
                    let entry = openHyperlinks[mid]
                    if entry.offset == keyOffset { return entry.id }
                    if entry.offset < keyOffset { low = mid + 1 } else { high = mid - 1 }
                }
                return nil
            }
            let base = recordByteOffset(
                offset,
                LogicalLineRecord.headerAndCells(record.cellCount)
            )
            let isHead = recordOffset(in: offset) == head
            let coordinateStart = isHead ? headTrimmedCells.value : 0
            let tableBase = isHead ? headTableCellBase : 0
            let tableKey = tableBase + keyOffset.value - coordinateStart
            if record.hyperlinkPerCell {
                let value = u16(base + tableKey * LogicalLineRecord.hyperlinkCellBytes)
                return value == 0 ? nil : Terminal.HyperlinkId(value)
            }
            var low = 0
            var high = record.hyperlinkCount - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = base + mid * LogicalLineRecord.hyperlinkEntryBytes
                let column = Int(u32(entry))
                if column == tableKey { return Terminal.HyperlinkId(u16(entry + 4)) }
                if column < tableKey { low = mid + 1 } else { high = mid - 1 }
            }
            return nil
        }

        private func contentIdentity(
            record: LogicalLineRecord,
            at offset: Int,
            keyOffset: OriginalCellOffset
        ) -> Terminal.ContentIdentity? {
            if record.isOpen {
                var low = 0
                var high = openIdentityRuns.count - 1
                while low <= high {
                    let mid = (low + high) / 2
                    let run = openIdentityRuns[mid]
                    if keyOffset < run.start {
                        high = mid - 1
                    } else if keyOffset >= run.start + run.extent {
                        low = mid + 1
                    } else {
                        return run.base &+ Terminal.ContentIdentity(keyOffset - run.start)
                    }
                }
                return nil
            }
            let isHead = recordOffset(in: offset) == head
            let coordinateStart = isHead ? headTrimmedCells.value : 0
            let tableBase = isHead ? headTableCellBase : 0
            let tableKey = tableBase + keyOffset.value - coordinateStart
            let base = recordByteOffset(
                offset,
                LogicalLineRecord.headerAndCells(record.cellCount) + (
                    record.hyperlinkPerCell
                        ? LogicalLineRecord.hyperlinkCellTableBytes(
                            forCells: record.cellCount + tableBase
                        )
                        : record.hyperlinkCount * LogicalLineRecord.hyperlinkEntryBytes
                )
            )
            if record.identityPerCell {
                let value = u32(base + tableKey * LogicalLineRecord.identityCellBytes)
                return value == 0 ? nil : value
            }
            var low = 0
            var high = record.identityEntryCount - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = base + mid * LogicalLineRecord.identityRunEntryBytes
                let start = Int(u32(entry))
                if tableKey < start {
                    high = mid - 1
                    continue
                }
                let extent = Int(u32(entry + 4))
                if tableKey >= start + extent {
                    low = mid + 1
                    continue
                }
                return u32(entry + 8) &+ Terminal.ContentIdentity(tableKey - start)
            }
            return nil
        }

        // MARK: - Arena writing

        private mutating func openRecordIfNeeded(mark: Terminal.SemanticPromptRow) {
            if openTailRecord() != nil { return }
            _ = ensureRecordIdentityCapacity()
            materializeChunk(at: writeCursor)
            if offsets.count > 0 {
                addContentUnitsToTail(1)
            }
            let inherited = pendingStartsMidLine
            pendingStartsMidLine = false
            var record = LogicalLineRecord(semanticPrompt: mark, isOpen: true)
            if inherited {
                record.startsMidLine = true
                record.semanticPrompt = .none
            }
            // The cursor moves past the header before the index names the record, so the ring
            // span never reads a store with one record and a cursor still at `head` -- which is
            // the full-arena reading `bytesInUse` gives that pair.
            let openedAt = writeCursor
            writeHeader(record, at: openedAt)
            writeCursor = arenaOffset(writeCursor + LogicalLineRecord.Header.byteCount)
            appendRecordOffset(openedAt)
            clearOpenScratch()
        }

        /// Appends the first `cellCount` cells of an admitted display row, borrowing them from the
        /// caller's own storage rather than copying them into an array first.
        ///
        /// A row may be logically wider than it is stored -- `GridRow.cell(at:)` reads a default
        /// cell past the end -- so a soft-wrapped short row is appended as its stored prefix plus
        /// the blanks the columns past it read as.
        private mutating func appendRowPrefix(_ row: Terminal.GridRow, cellCount: Int) {
            guard cellCount > 0 else { return }
            let stored = min(cellCount, row.cells.count)
            if stored > 0 {
                row.cells.withUnsafeBufferPointer { cells in
                    appendCells(UnsafeBufferPointer(rebasing: cells[0..<stored])) {
                        row.scalars(of: cells[$0])
                    }
                }
            }
            if cellCount > stored { appendBlankCells(cellCount - stored) }
        }

        /// Appends one cell the store synthesized rather than read off a row.
        private mutating func appendCell(_ cell: Terminal.GridCell) {
            withUnsafePointer(to: cell) { pointer in
                appendCells(UnsafeBufferPointer(start: pointer, count: 1)) { _ in
                    preconditionFailure("a synthesized arena cell cannot hold a spill index")
                }
            }
        }

        /// Appends `count` default cells: what a row's columns past its stored extent read as, and
        /// the one shape that needs no per-cell decoding at all.
        private mutating func appendBlankCells(_ count: Int) {
            guard count > 0 else { return }
            let offset = offsets[offsets.count - 1]
            var record = self.record(at: offset)
            let blank = CellWord(kind: .padding, styleId: Terminal.defaultStyleId).raw
            let base = recordByteOffset(
                offset,
                LogicalLineRecord.headerAndCells(record.cellCount)
            )
            // Segmented like `appendCells`: one chunk swap per chunk the run touches.
            var index = 0
            while index < count {
                let byte = arenaOffset(base + index * LogicalLineRecord.cellBytes)
                materializeChunk(at: byte)
                let chunkAt = byte >> chunkByteShift
                let chunkEnd = min((chunkAt + 1) << chunkByteShift, arenaCapacity)
                let segment = min(count - index, (chunkEnd - byte) >> 3)
                let wordAt = (byte & chunkByteMask) >> 3
                var chunk = ContiguousArray<UInt64>()
                swap(&chunk, &chunks[chunkAt])
                for word in wordAt..<(wordAt + segment) {
                    chunk[word] = blank
                }
                swap(&chunk, &chunks[chunkAt])
                index += segment
            }
            openPreviousIdentity = nil
            record.cellCount += count
            writeHeader(record, at: offset)
            writeCursor = arenaOffset(writeCursor + count * LogicalLineRecord.cellBytes)
            addContentUnitsToTail(count)
        }

        /// Takes the cells through a buffer pointer so admission can hand it a slice of the
        /// caller's own row, and so the loop below reads a cell's fields in place.
        ///
        /// Both halves of that are `research/31/F8` Observation 3's: materializing a `[GridCell]` per
        /// admitted row cost an allocation and a copy of every cell, and *binding* each element
        /// costs a copy and a release of a `TerminalScalars` on every one.
        private mutating func appendCells(
            _ cells: UnsafeBufferPointer<Terminal.GridCell>,
            resolveSpill: (Int) -> TerminalScalars
        ) {
            guard cells.isEmpty == false else { return }
            let offset = offsets[offsets.count - 1]
            var record = self.record(at: offset)
            var contentUnits = 0

            let cellsBase = recordByteOffset(
                offset,
                LogicalLineRecord.headerAndCells(record.cellCount)
            )

            // The cells are written through a chunk moved into a local, one chunk segment at a
            // time (`research/31/D5`): a record may straddle a chunk seam or the arena wrap, so
            // a segment ends where its chunk does, and the next iteration swaps in the next chunk.
            // Inside a segment the per-cell write is the single uniqueness check and single
            // bounds check it was when the arena was one buffer; routing every cell through
            // `setWord` instead re-derived the chunk and checked both arrays per cell, which
            // `terminal-feed` measured as most of an 11% regression. The first write after a
            // publish pays copy-on-write of this chunk, not of the arena (`research/31/F13` M1).
            // Nothing between the two swaps may read the arena: the chunk is out of `chunks`
            // until the second one, and a stray read would trap on bounds rather than lie.
            var index = 0
            while index < cells.count {
                let byte = arenaOffset(cellsBase + index * LogicalLineRecord.cellBytes)
                materializeChunk(at: byte)
                let chunkAt = byte >> chunkByteShift
                let chunkEnd = min((chunkAt + 1) << chunkByteShift, arenaCapacity)
                let segment = min(cells.count - index, (chunkEnd - byte) >> 3)
                let wordBase = ((byte & chunkByteMask) >> 3) - index
                var chunk = ContiguousArray<UInt64>()
                swap(&chunk, &chunks[chunkAt])

                for index in index..<(index + segment) {
                    let cellOffset = originalCellOffset(
                        recordIndex: offsets.count - 1,
                        retainedOffset: record.cellCount + index
                    )
                    let kind = cells[index].kind
                    assert(
                        kind != .wideTail && kind != .spacerHead || record.hasWideCells,
                        "a stored wide tail or spacer head requires an earlier wide head"
                    )
                    switch kind {
                    case .narrow, .wideHead, .padding:
                        contentUnits += 1
                    case .wideTail, .spacerHead:
                        break
                    }
                    let sourceWord = cells[index].word
                    let word: CellWord
                    if sourceWord.isSpilled {
                        let payload = resolveSpill(index)
                        precondition(payload.count > 1, "a live spill word requires a cluster payload")
                        word = CellWord(
                            kind: sourceWord.kind,
                            styleId: sourceWord.styleId,
                            spillIndex: (openSpillBase + openSpills.count)
                                % (CellWord.maximumSpillIndex + 1)
                        )
                        let spill = Array(payload)
                        Instrument.openSpillChargeWork.record()
                        openSpillPayloadBytes += Terminal.arrayStorageHeaderBytes
                            + spill.capacity * MemoryLayout<Unicode.Scalar>.stride
                        openSpills.append(spill)
                    } else {
                        word = sourceWord
                    }
                    chunk[wordBase + index] = word.raw

                    if let id = cells[index].hyperlinkId {
                        openHyperlinks.append(HyperlinkEntry(offset: cellOffset, id: id))
                    }
                    if let identity = cells[index].contentIdentity {
                        // A run is a strict step of one: the only shape a (base, start, extent)
                        // triple reconstructs exactly. A repeat -- a wide cell's two columns share
                        // one identity -- breaks the run like a gap does.
                        if let previous = openPreviousIdentity, identity == previous &+ 1,
                           let open = openIdentityRuns.last, open.start + open.extent == cellOffset
                        {
                            openIdentityRuns[openIdentityRuns.count - 1].extent += 1
                        } else {
                            openIdentityRuns.append(
                                IdentityRun(start: cellOffset, extent: 1, base: identity)
                            )
                        }
                        openPreviousIdentity = identity
                    } else {
                        openPreviousIdentity = nil
                    }
                    if kind == .wideHead { record.hasWideCells = true }
                }
                swap(&chunk, &chunks[chunkAt])
                index += segment
            }

            record.cellCount += cells.count
            writeHeader(record, at: offset)
            writeCursor = arenaOffset(writeCursor + cells.count * LogicalLineRecord.cellBytes)
            addContentUnitsToTail(contentUnits)
        }

        /// Writes the open record's side tables after its cells and stamps their counts into the
        /// header. The tables' position is `header + cellCount * 8`, which a later head trim
        /// leaves invariant: the trim moves the header forward by exactly the bytes it drops.
        private mutating func flushOpenTables(into record: inout LogicalLineRecord, at offset: Int) {
            let recordIndex = offsets.count - 1
            let retainedStart = originalCellOffset(
                recordIndex: recordIndex,
                retainedOffset: 0
            ).value
            let retainedEnd = retainedStart + record.cellCount

            // The open tables are clipped to the retained range as they are read, twice -- once
            // to count, once to write -- rather than copied into clipped arrays: every close
            // runs this, and the two allocations it took were a visible share of
            // `terminal-feed`'s admission cost.
            @inline(__always) func retained(_ entry: HyperlinkEntry) -> Bool {
                entry.offset.value >= retainedStart && entry.offset.value < retainedEnd
            }
            @inline(__always) func clipped(_ run: IdentityRun) -> IdentityRun? {
                let start = max(run.start.value, retainedStart)
                let end = min(run.start.value + run.extent, retainedEnd)
                guard start < end else { return nil }
                return IdentityRun(
                    start: OriginalCellOffset(value: start),
                    extent: end - start,
                    base: run.base &+ Terminal.ContentIdentity(start - run.start.value)
                )
            }
            var hyperlinkCount = 0
            for entry in openHyperlinks where retained(entry) { hyperlinkCount += 1 }
            var identityRunCount = 0
            for run in openIdentityRuns where clipped(run) != nil { identityRunCount += 1 }

            let hyperlinkPerCell = hyperlinkCount > LogicalLineRecord.Header.maximumTableCount
                || hyperlinkCount * LogicalLineRecord.hyperlinkEntryBytes
                    > LogicalLineRecord.hyperlinkCellTableBytes(forCells: record.cellCount)
            let identityPerCell = identityRunCount > LogicalLineRecord.Header.maximumTableCount
                || identityRunCount * LogicalLineRecord.identityRunEntryBytes
                    > record.cellCount * LogicalLineRecord.identityCellBytes
            record.hyperlinkPerCell = hyperlinkPerCell
            record.hyperlinkCount = hyperlinkPerCell ? 0 : hyperlinkCount
            record.identityPerCell = identityPerCell
            record.identityEntryCount = identityPerCell ? 0 : identityRunCount

            if openSpills.isEmpty == false {
                let sequence = firstRecordSequence + recordIndex
                var spills: [[Unicode.Scalar]] = []
                swap(&spills, &openSpills)
                openSpillPayloadBytes = 0
                sideTables.setSpills(
                    SequenceKeyedSideTables.SpillTable(
                        base: openSpillBase,
                        payloads: spills
                    ),
                    at: sequence
                )
            }

            var at = recordByteOffset(
                offset,
                LogicalLineRecord.headerAndCells(record.cellCount)
            )
            let tableBytes = record.byteLength
                - LogicalLineRecord.headerAndCells(record.cellCount)
            for byte in stride(from: 0, to: tableBytes, by: LogicalLineRecord.cellBytes) {
                setWord(0, at: at + byte)
            }
            if hyperlinkPerCell {
                for entry in openHyperlinks where retained(entry) {
                    setU16(
                        Int(entry.id),
                        at: at + (entry.offset.value - retainedStart)
                            * LogicalLineRecord.hyperlinkCellBytes
                    )
                }
                at += LogicalLineRecord.hyperlinkCellTableBytes(forCells: record.cellCount)
            } else {
                for entry in openHyperlinks where retained(entry) {
                    setU32(UInt32(entry.offset.value - retainedStart), at: at)
                    setU16(Int(entry.id), at: at + 4)
                    at += LogicalLineRecord.hyperlinkEntryBytes
                }
            }
            if identityPerCell {
                for run in openIdentityRuns {
                    guard let run = clipped(run) else { continue }
                    for step in 0..<run.extent {
                        setU32(
                            run.base &+ Terminal.ContentIdentity(step),
                            at: at + (run.start.value - retainedStart + step)
                                * LogicalLineRecord.identityCellBytes
                        )
                    }
                }
            } else {
                for run in openIdentityRuns {
                    guard let run = clipped(run) else { continue }
                    setU32(UInt32(run.start.value - retainedStart), at: at)
                    setU32(UInt32(run.extent), at: at + 4)
                    setU32(run.base, at: at + 8)
                    at += LogicalLineRecord.identityRunEntryBytes
                }
            }
        }

        /// Reads a closed record's side tables back into the open-tail scratch, so appending can
        /// resume. Reads the tables themselves rather than probing each cell, which keeps
        /// reopening linear in the table rather than quadratic in the record.
        private mutating func loadOpenScratch(from record: LogicalLineRecord, at offset: Int) {
            clearOpenScratch()
            let sequence = firstRecordSequence + offsets.count - 1
            let spillTable = sideTables.takeSpills(at: sequence)
            openSpillBase = spillTable?.base ?? 0
            openSpills = spillTable?.payloads ?? []
            openSpillPayloadBytes = openSpills.reduce(into: 0) { total, spill in
                total += Terminal.arrayStorageHeaderBytes
                    + spill.capacity * MemoryLayout<Unicode.Scalar>.stride
            }
            let linkBase = recordByteOffset(
                offset,
                LogicalLineRecord.headerAndCells(record.cellCount)
            )
            let tableBase = offsets.count == 1 ? headTableCellBase : 0
            let coordinateBase = offsets.count == 1 ? headTrimmedCells.value : 0
            if record.hyperlinkPerCell {
                for retained in 0..<record.cellCount {
                    let id = u16(
                        linkBase + (tableBase + retained)
                            * LogicalLineRecord.hyperlinkCellBytes
                    )
                    if id != 0 {
                        openHyperlinks.append(HyperlinkEntry(
                            offset: OriginalCellOffset(value: coordinateBase + retained),
                            id: Terminal.HyperlinkId(id)
                        ))
                    }
                }
            } else {
                for index in 0..<record.hyperlinkCount {
                    let entry = linkBase + index * LogicalLineRecord.hyperlinkEntryBytes
                    let key = Int(u32(entry))
                    guard key >= tableBase else { continue }
                    openHyperlinks.append(
                        HyperlinkEntry(
                            offset: OriginalCellOffset(
                                value: coordinateBase + key - tableBase
                            ),
                            id: Terminal.HyperlinkId(u16(entry + 4))
                        )
                    )
                }
            }

            let identityBase = linkBase + (
                record.hyperlinkPerCell
                    ? LogicalLineRecord.hyperlinkCellTableBytes(
                        forCells: record.cellCount + tableBase
                    )
                    : record.hyperlinkCount * LogicalLineRecord.hyperlinkEntryBytes
            )
            guard record.identityPerCell else {
                for index in 0..<record.identityEntryCount {
                    let entry = identityBase + index * LogicalLineRecord.identityRunEntryBytes
                    let key = Int(u32(entry))
                    let extent = Int(u32(entry + 4))
                    let start = max(key, tableBase)
                    guard start < key + extent else { continue }
                    openIdentityRuns.append(
                        IdentityRun(
                            start: OriginalCellOffset(
                                value: coordinateBase + start - tableBase
                            ),
                            extent: key + extent - start,
                            base: u32(entry + 8) &+ Terminal.ContentIdentity(start - key)
                        )
                    )
                }
                openPreviousIdentity = openIdentityRuns.last.map {
                    $0.base &+ Terminal.ContentIdentity($0.extent - 1)
                }
                return
            }
            for retained in 0..<record.cellCount {
                let value = u32(
                    identityBase + (tableBase + retained)
                        * LogicalLineRecord.identityCellBytes
                )
                guard value != 0 else {
                    openPreviousIdentity = nil
                    continue
                }
                if let previous = openPreviousIdentity, value == previous &+ 1,
                   let open = openIdentityRuns.last, open.start + open.extent
                       == OriginalCellOffset(value: coordinateBase + retained)
                {
                    openIdentityRuns[openIdentityRuns.count - 1].extent += 1
                } else {
                    openIdentityRuns.append(
                        IdentityRun(
                            start: OriginalCellOffset(value: coordinateBase + retained),
                            extent: 1,
                            base: value
                        )
                    )
                }
                openPreviousIdentity = value
            }
        }

        private mutating func clearOpenScratch() {
            openHyperlinks.removeAll(keepingCapacity: true)
            openIdentityRuns.removeAll(keepingCapacity: true)
            openSpills = []
            openSpillBase = 0
            openSpillPayloadBytes = 0
            openPreviousIdentity = nil
        }

        // MARK: - Ring discipline

        /// Makes room for appended cells and the open record's eventual side tables.
        private mutating func makeRoom(
            forCells cells: Int,
            hyperlinkEntries: Int = 0,
            identityRuns: Int = 0
        ) {
            while true {
                let openNow = openTailRecord() != nil
                let need = (openNow ? 0 : LogicalLineRecord.Header.byteCount)
                    + cells * LogicalLineRecord.cellBytes
                    + projectedTableBytes(
                        addingCells: cells,
                        hyperlinkEntries: hyperlinkEntries,
                        identityRuns: identityRuns
                    )
                let charged = need + (openNow ? 0 : indexGrowthBytes)
                if bytesInUse + need <= arenaCapacity,
                   chargedBytes + charged <= arenaCapacity
                {
                    return
                }
                if offsets.count == 0 {
                    resetToEmptyArena()
                    precondition(need <= arenaCapacity, "a record cannot exceed the arena")
                    return
                }
                guard evictOneDisplayRow() else { return }
            }
        }

        /// What opening one more record would add to the index's charge, counting the doubling
        /// an append at capacity triggers (`research/31/DD56`).
        ///
        /// Charged **before** the append rather than discovered after it, because a ring never
        /// shrinks: a doubling taken while the charge was already near the capacity would leave
        /// metadata permanently over the bound, and eviction -- which drops records, not
        /// capacity -- could not get back under it, so the pane would retain nothing for the rest
        /// of its life. Evicting first instead leaves `count` below `capacity`, so the append
        /// needs no doubling at all.
        ///
        /// Whether it is reachable is a property of the budget rather than of the design: it
        /// fires when a ring capacity that is a power of two lands between `capacity / 24.25` and
        /// `capacity / 16.25` in the blank-line regime, which the production budget's 15,728,640
        /// happens to miss and other budgets hit. That is exactly why the charge is stated by
        /// construction instead of being checked against the one budget that ships.
        private var indexGrowthBytes: Int {
            var growth = 0
            if offsets.count == offsets.capacity {
                growth += offsets.capacity * MemoryLayout<Int>.stride
            }
            // The block ring grows only when the record about to be opened starts a new block,
            // which is `appendRecordOffset`'s own test: charging it on every admission once the
            // ring happened to be full would evict for a doubling 63 records out of 64 never
            // take.
            let nextBlock = (firstRecordSequence + offsets.count) / Self.blockSize
            if blocks.count == blocks.capacity, nextBlock >= firstBlockNumber + blocks.count {
                growth += blocks.capacity * MemoryLayout<Block>.stride
            }
            return growth
        }

        /// Appends the backing chunk containing `offset` before its first write.
        ///
        /// First visits are consecutive by the ring placement invariant. A backward cursor move
        /// can therefore only name an existing chunk, so a sparse chunk table is unnecessary.
        private mutating func materializeChunk(at offset: Int) {
            let index = chunkIndex(of: offset)
            precondition(index <= chunks.count, "arena chunks must materialize consecutively")
            guard index == chunks.count else { return }
            precondition(chunks.count < fullChunkCount)
            let start = index * chunkBytes
            let size = min(chunkBytes, arenaCapacity - start)
            chunks.append(ContiguousArray(repeating: 0, count: size / 8))
        }

        /// An upper bound on the bytes the open record's side tables will need when it closes.
        ///
        /// Reserved before every append so closing the open record can flush them without first
        /// evicting content from the line being closed.
        private func projectedTableBytes(
            addingCells cells: Int,
            hyperlinkEntries: Int,
            identityRuns: Int
        ) -> Int {
            let openCells = openRecordCellCount + cells
            let hyperlinkRuns = openHyperlinks.count + hyperlinkEntries
            let hyperlinkRunBytes = hyperlinkRuns * LogicalLineRecord.hyperlinkEntryBytes
            let hyperlinkCellBytes = LogicalLineRecord.hyperlinkCellTableBytes(
                forCells: openCells
            )
            let identityRunBytes = (openIdentityRuns.count + identityRuns)
                * LogicalLineRecord.identityRunEntryBytes
            let identityCellBytes = openCells * LogicalLineRecord.identityCellBytes
            let hyperlinks = hyperlinkRuns == 0
                ? 0
                : min(hyperlinkRunBytes, hyperlinkCellBytes)
            let identities = openIdentityRuns.isEmpty && identityRuns == 0
                ? 0
                : min(identityRunBytes, identityCellBytes)
            return hyperlinks + identities
                + LogicalLineRecord.cellBytes  // the record's own 8-byte alignment slack
        }

        // MARK: - Index maintenance

        private mutating func appendRecordOffset(_ offset: Int) {
            let sequence = firstRecordSequence + offsets.count
            let identity = allocateRecordIdentity()
            offsets.append(packedRecordAddress(offset: offset, identity: identity))
            if offsets.count == 1 {
                blocks.removeAll()
                blocks.append(Block(
                    rowStart: evictedRowCount,
                    rowCount: 0,
                    contentStart: evictedContentUnitCount,
                    contentCount: 0
                ))
                return
            }
            let number = sequence / Self.blockSize
            if number >= firstBlockNumber + blocks.count {
                let previous = blocks[blocks.count - 1]
                blocks.append(Block(
                    rowStart: previous.rowStart + previous.rowCount,
                    rowCount: 0,
                    contentStart: previous.contentStart + previous.contentCount,
                    contentCount: 0
                ))
            }
        }

        /// Test support: stable identity shares the existing index word with the arena offset.
        var recordIndexEntryBytesForTesting: Int { MemoryLayout<Int>.stride }

        /// Test support: each block charges both row and content cumulative totals.
        static var blockMetadataBytesForTesting: Int { MemoryLayout<Block>.stride }

        /// Drives the packed ordinal past its range so the retirement seam is reachable in tests.
        mutating func exhaustRecordIdentitySpaceForTesting() {
            nextRecordIdentity = maximumRecordIdentity + 1
        }

        /// The largest ordinal the bits left over beside an arena offset can hold.
        private var maximumRecordIdentity: UInt64 {
            UInt64.max >> UInt64(recordOffsetBits)
        }

        private mutating func allocateRecordIdentity() -> RecordIdentity {
            precondition(nextRecordIdentity <= maximumRecordIdentity)
            defer { nextRecordIdentity += 1 }
            return composedRecordIdentity(ordinal: nextRecordIdentity)
        }

        /// Lifts a packed ordinal into the whole-life identity by stamping the current generation
        /// above it, which is what keeps a reissued ordinal from reissuing an identity.
        @inline(__always)
        private func composedRecordIdentity(ordinal: UInt64) -> RecordIdentity {
            RecordIdentity(
                rawValue: recordIdentityEpoch << UInt64(64 - recordOffsetBits) | ordinal
            )
        }

        /// Retires all coordinates before the packed ordinal could repeat.
        @discardableResult
        private mutating func ensureRecordIdentityCapacity() -> Bool {
            guard nextRecordIdentity > maximumRecordIdentity else { return true }
            removeAll()
            recordIdentityEpoch &+= 1
            nextRecordIdentity = 1
            return false
        }

        private func packedRecordAddress(offset: Int, identity: RecordIdentity) -> Int {
            precondition(offset >= 0 && offset <= recordOffsetMask)
            let ordinal = identity.rawValue & maximumRecordIdentity
            let raw = ordinal << UInt64(recordOffsetBits) | UInt64(offset)
            return Int(bitPattern: UInt(raw))
        }

        @inline(__always) private func recordOffset(in address: Int) -> Int {
            address & recordOffsetMask
        }

        /// Adds a record-relative byte count without letting it carry into the packed identity.
        @inline(__always) private func recordByteOffset(_ address: Int, _ relative: Int) -> Int {
            recordOffset(in: address) + relative
        }

        @inline(__always) private func recordIdentity(in address: Int) -> RecordIdentity {
            composedRecordIdentity(
                ordinal: UInt64(UInt(bitPattern: address)) >> UInt64(recordOffsetBits)
            )
        }

        private mutating func renewTailRecordIdentity() {
            let index = offsets.count - 1
            offsets[index] = packedRecordAddress(
                offset: recordOffset(in: offsets[index]),
                identity: allocateRecordIdentity()
            )
        }

        private mutating func addDisplayRowsToTail(_ rows: Int) {
            if blocks.count > 0 {
                blocks.modifyElement(at: blocks.count - 1) { $0.rowCount += rows }
            }
        }

        /// Applies a content delta to the only mutable record and its block.
        private mutating func addContentUnitsToTail(_ units: Int) {
            if blocks.count > 0 {
                blocks.modifyElement(at: blocks.count - 1) { $0.contentCount += units }
            }
        }

        /// Applies a tail-side delta to the block that owns a specific retained record.
        private mutating func addContentUnits(_ units: Int, toBlockContaining recordIndex: Int) {
            guard let blockIndex = blockIndex(containingRecordAt: recordIndex) else {
                preconditionFailure("record has no retained index block")
            }
            blocks.modifyElement(at: blockIndex) { $0.contentCount += units }
        }

        /// Removes the hard boundary whose successor is the tail record about to disappear.
        private mutating func removeBoundaryBeforeTailIfNeeded() {
            guard offsets.count > 1 else { return }
            let predecessorIndex = offsets.count - 2
            let predecessor = record(at: offsets[predecessorIndex])
            guard predecessor.isOpen == false else { return }
            addContentUnits(-1, toBlockContaining: predecessorIndex)
        }

        /// Removes content from the head while leaving every later block's absolute start fixed.
        private mutating func removeContentUnitsFromHead(_ units: Int) {
            evictedContentUnitCount += units
            if blocks.count > 0 {
                blocks.modifyElement(at: 0) { block in
                    block.contentStart += units
                    block.contentCount -= units
                }
            }
        }

        // MARK: - Header and byte access

        /// Wraps one record-relative arena address with one compare and subtract.
        @inline(__always) private func arenaOffset(_ offset: Int) -> Int {
            offset >= arenaCapacity ? offset - arenaCapacity : offset
        }

        private func record(at offset: Int) -> LogicalLineRecord {
            LogicalLineRecord(word: word(at: recordOffset(in: offset)))
        }

        private func storedByteLength(
            of record: LogicalLineRecord,
            headTableBase: Int
        ) -> Int {
            let hyperlinkBytes = record.hyperlinkPerCell
                ? LogicalLineRecord.hyperlinkCellTableBytes(
                    forCells: record.cellCount + headTableBase
                )
                : record.hyperlinkCount * LogicalLineRecord.hyperlinkEntryBytes
            let identityBytes = record.identityPerCell
                ? (record.cellCount + headTableBase) * LogicalLineRecord.identityCellBytes
                : record.identityEntryCount * LogicalLineRecord.identityRunEntryBytes
            return (LogicalLineRecord.headerAndCells(record.cellCount)
                + hyperlinkBytes + identityBytes + 7) & ~7
        }

        private func openTailRecord() -> LogicalLineRecord? {
            guard offsets.count > 0 else { return nil }
            let record = self.record(at: offsets[offsets.count - 1])
            return record.isOpen ? record : nil
        }

        private var openRecordCellCount: Int {
            openTailRecord()?.cellCount ?? 0
        }

        private mutating func writeHeader(_ record: LogicalLineRecord, at offset: Int) {
            setWord(record.word, at: recordOffset(in: offset))
        }

        private func isWideHead(recordAt offset: Int, cell index: Int) -> Bool {
            cellKind(recordAt: offset, cell: index) == .wideHead
        }

        private func cellKind(recordAt offset: Int, cell index: Int) -> TerminalCellKind {
            cellWord(recordAt: offset, cell: index).kind
        }

        private func cellWord(recordAt offset: Int, cell index: Int) -> CellWord {
            CellWord(raw: word(at: recordByteOffset(
                offset,
                LogicalLineRecord.headerAndCells(index)
            )))
        }

        /// Returns the one chunk range for a row that does not cross a storage boundary.
        @inline(__always)
        private func singleChunkCellRange(
            recordAt offset: Int,
            start: Int,
            count: Int
        ) -> (chunk: Int, word: Int)? {
            let byte = arenaOffset(
                recordOffset(in: offset) + LogicalLineRecord.headerAndCells(start)
            )
            let chunkEnd = min(((byte >> chunkByteShift) + 1) << chunkByteShift, arenaCapacity)
            guard byte + count * LogicalLineRecord.cellBytes <= chunkEnd else { return nil }
            return (byte >> chunkByteShift, (byte & chunkByteMask) >> 3)
        }

        // The arena is words, and every access below is one word-sized load or store plus a shift.
        //
        // The alignment that makes that legal is a property of the layout rather than a hope: a
        // record starts on an 8-byte boundary and its header and cells are whole words, so its
        // two in-arena tables start 4-byte aligned; hyperlink entries are 8 bytes and identity
        // entries 12 or 4, so every `u16` field is 2-byte aligned and every `u32` field 4-byte
        // aligned. A naturally aligned field never straddles a word boundary, which is why none
        // of these has a carry path. The assertions state it where a future layout change would
        // break it.

        /// Which backing chunk a byte offset lives in, and where in it (`research/31/D5`).
        ///
        /// A row that fits one chunk can call these once and index that chunk directly.
        @inline(__always) private func chunkIndex(of offset: Int) -> Int {
            let offset = arenaOffset(offset)
            return offset >> chunkByteShift
        }

        private func word(at offset: Int) -> UInt64 {
            let offset = arenaOffset(offset)
            assert(offset & 7 == 0, "a record word must be 8-byte aligned")
            return chunks[offset >> chunkByteShift][(offset & chunkByteMask) >> 3]
        }

        private mutating func setWord(_ value: UInt64, at offset: Int) {
            let offset = arenaOffset(offset)
            assert(offset & 7 == 0, "a record word must be 8-byte aligned")
            materializeChunk(at: offset)
            chunks[offset >> chunkByteShift][(offset & chunkByteMask) >> 3] = value
        }

        private func u16(_ offset: Int) -> Int {
            let offset = arenaOffset(offset)
            assert(offset & 1 == 0, "a 16-bit table field must be 2-byte aligned")
            let word = chunks[offset >> chunkByteShift][(offset & chunkByteMask) >> 3]
            return Int((word >> UInt64((offset & 7) << 3)) & 0xFFFF)
        }

        private func u32(_ offset: Int) -> UInt32 {
            let offset = arenaOffset(offset)
            assert(offset & 3 == 0, "a 32-bit table field must be 4-byte aligned")
            let word = chunks[offset >> chunkByteShift][(offset & chunkByteMask) >> 3]
            return UInt32(truncatingIfNeeded: word >> UInt64((offset & 7) << 3))
        }

        private mutating func setU16(_ value: Int, at offset: Int) {
            let offset = arenaOffset(offset)
            assert(offset & 1 == 0, "a 16-bit table field must be 2-byte aligned")
            materializeChunk(at: offset)
            let shift = UInt64((offset & 7) << 3)
            let chunk = offset >> chunkByteShift
            let index = (offset & chunkByteMask) >> 3
            chunks[chunk][index] = chunks[chunk][index] & ~(0xFFFF << shift)
                | (UInt64(UInt16(truncatingIfNeeded: value)) << shift)
        }

        private mutating func setU32(_ value: UInt32, at offset: Int) {
            let offset = arenaOffset(offset)
            assert(offset & 3 == 0, "a 32-bit table field must be 4-byte aligned")
            materializeChunk(at: offset)
            let shift = UInt64((offset & 7) << 3)
            let chunk = offset >> chunkByteShift
            let index = (offset & chunkByteMask) >> 3
            chunks[chunk][index] = chunks[chunk][index] & ~(0xFFFF_FFFF << shift)
                | (UInt64(value) << shift)
        }
    }

    /// A fixed-element ring the index deques are built on.
    ///
    /// Written out rather than reached for because the index's charge is
    /// `research/31/D2` Decision 1's "8 B per record, at the deque's *capacity*": a structure that
    /// charges what the allocator gave needs a capacity it can report, and one that never
    /// shrinks keeps `research/31/DD11`'s "capacity does not grow" checkable in one comparison.
    /// Its capacity is a power of two, so an index wraps by masking rather than by dividing.
    ///
    /// Not an implementation detail of the type so much as of the write path: every eviction step
    /// and every admission reads and writes several of these positions, and an integer division
    /// per access was a measurable share of a step that is otherwise pointer arithmetic. The
    /// capacity was already a power of two -- it starts at 16 and doubles -- so this only stops
    /// paying for a general modulus the structure never needed.
    struct RingBuffer<Element: Sendable>: Sendable {
        private var storage: ContiguousArray<Element>
        private var mask: Int
        private var start = 0
        private(set) var count = 0
        private let filler: Element

        /// The floor is small on purpose: the index is charged at the rings' allocated bucket
        /// count rather than their live entry count, so an empty store's charge is a fixed
        /// cost every budget pays, and a generous floor would make a small history
        /// unrepresentable rather than merely shallow. Production depth grows both rings far
        /// past this within one screenful.
        init(filler: Element, minimumCapacity: Int = 4) {
            precondition(minimumCapacity > 0)
            var capacity = 1
            while capacity < minimumCapacity { capacity <<= 1 }
            self.filler = filler
            storage = ContiguousArray(repeating: filler, count: capacity)
            mask = capacity - 1
        }

        var capacity: Int { storage.count }

        subscript(index: Int) -> Element {
            get {
                precondition(index >= 0 && index < count)
                return storage[(start + index) & mask]
            }
            set {
                precondition(index >= 0 && index < count)
                storage[(start + index) & mask] = newValue
            }
        }

        /// Updates one element in place, so a caller that adjusts two of its fields pays one
        /// addressed access rather than a read and a write per field.
        mutating func modifyElement(at index: Int, _ body: (inout Element) -> Void) {
            precondition(index >= 0 && index < count)
            body(&storage[(start + index) & mask])
        }

        mutating func append(_ element: Element) {
            if count == storage.count { grow() }
            storage[(start + count) & mask] = element
            count += 1
        }

        mutating func removeFirst() {
            precondition(count > 0)
            storage[start] = filler
            start = (start + 1) & mask
            count -= 1
        }

        mutating func removeLast() {
            precondition(count > 0)
            count -= 1
            storage[(start + count) & mask] = filler
        }

        mutating func removeAll() {
            for index in 0..<storage.count { storage[index] = filler }
            start = 0
            count = 0
        }

        private mutating func grow() {
            var next = ContiguousArray(repeating: filler, count: storage.count * 2)
            for index in 0..<count {
                next[index] = storage[(start + index) & mask]
            }
            storage = next
            mask = next.count - 1
            start = 0
        }
    }
}
