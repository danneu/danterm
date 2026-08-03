// Behavioral proofs that the memory probe's payload matrix exercises what its names claim.
//
// This is the probe's most important test and the least obvious one. Every number the probe
// produces is attributed to a payload by name, so a "styled" payload that emits no styles or a
// "unicode" payload that never spills would not fail loudly -- it would produce plausible,
// confidently wrong evidence, and doc 15's H2/H3/H4 would be sized against it. These tests assert
// the payloads' observable effect on terminal state rather than their bytes, so the payload text
// can be rewritten freely as long as it still exercises the axis it is named for.
import Testing
import TerminalCore
@testable import TerminalMemoryProbeSupport

/// Guards the matrix's premise: each payload must actually produce the state it is named for.
struct TerminalMemoryProbeSupportTests {
    private static let geometry = (columns: 40, rows: 8)

    private func census(_ payload: MemoryProbePayload) throws -> TerminalMemoryCensus {
        let report = try #require(measure(
            payload: payload,
            columns: Self.geometry.columns,
            rows: Self.geometry.rows
        ))
        return report.census
    }

    private func payload(named name: String) throws -> MemoryProbePayload {
        try #require(
            MemoryProbeMatrix.payloads(columns: Self.geometry.columns, lineCount: 200)
                .first { $0.name == name }
        )
    }

    @Test("the matrix covers exactly the axes doc 15 specifies")
    func matrixCoversSpecifiedAxes() {
        let names = MemoryProbeMatrix.payloads(columns: 40, lineCount: 10).map(\.name)
        #expect(names == [
            "empty",
            "full-screen",
            "scrollback-plain",
            "scrollback-unicode",
            "scrollback-styled",
            "scrollback-mixed",
        ])
    }

    @Test("the empty payload measures a bare screen and nothing else")
    func emptyPayloadIsBare() throws {
        let census = try census(payload(named: "empty"))
        #expect(census.scrollbackRowCount == 0)
        #expect(census.cellCount == Self.geometry.columns * Self.geometry.rows)
        #expect(census.styledCellCount == 0)
        #expect(census.multiScalarCellCount == 0)
    }

    @Test("the styled payload produces many distinct styles")
    func styledPayloadIsStyled() throws {
        // The fixture corpus doc 12's F3 censused had at most nine distinct styles, which is too
        // few to size a dedup table against. This payload exists to be harder than that, so the
        // assertion is a floor well above nine rather than a mere "greater than one".
        let census = try census(payload(named: "scrollback-styled"))
        #expect(census.styledCellCount > 0)
        #expect(census.distinctStyleCount > 20)
    }

    @Test("the unicode payload spills into multi-scalar storage")
    func unicodePayloadSpills() throws {
        // Spill cells are the only case where a cell owns a reference-counted allocation, so a
        // unicode payload that produced none would leave that cost entirely unmeasured.
        let census = try census(payload(named: "scrollback-unicode"))
        #expect(census.multiScalarCellCount > 0)
        #expect(census.multiScalarAllocationCount == census.multiScalarCellCount)
    }

    @Test("the plain payload fills history without styling or spilling")
    func plainPayloadIsPlain() throws {
        let census = try census(payload(named: "scrollback-plain"))
        #expect(census.scrollbackRowCount > 0)
        #expect(census.styledCellCount == 0)
        #expect(census.multiScalarCellCount == 0)
    }

    @Test("the mixed payload combines the other three axes at once")
    func mixedPayloadCombinesAxes() throws {
        let census = try census(payload(named: "scrollback-mixed"))
        #expect(census.scrollbackRowCount > 0)
        #expect(census.styledCellCount > 0)
        #expect(census.multiScalarCellCount > 0)
    }

    @Test("the mixed payload still combines all three axes once eviction has run")
    func mixedPayloadSurvivesEviction() throws {
        // Intent: mixed content stays mixed at the depth the probe actually reports.
        // Why it exists: this is a real regression, caught by the probe's first production run. The
        //   payload originally concatenated three blocks -- plain, then unicode, then styled -- so
        //   at the production budget only the trailing styled block survived eviction and
        //   `scrollback-mixed` measured byte-identical to `scrollback-styled`. The shallow test
        //   above passed throughout, because below the budget nothing evicts. Any payload whose
        //   composition is asserted only at shallow depth can degenerate exactly this way.
        // Scenario: a long-running session whose visible history is whatever the last N MB of
        //   heterogeneous output happened to be.
        let deep = MemoryProbeMatrix.payloads(columns: Self.geometry.columns, lineCount: 12_000)
        let mixed = try #require(deep.first { $0.name == "scrollback-mixed" })
        let styled = try #require(deep.first { $0.name == "scrollback-styled" })

        let mixedCensus = try #require(
            measure(payload: mixed, columns: Self.geometry.columns, rows: Self.geometry.rows)
        ).census
        let styledCensus = try #require(
            measure(payload: styled, columns: Self.geometry.columns, rows: Self.geometry.rows)
        ).census

        #expect(mixedCensus.styledCellCount > 0)
        #expect(mixedCensus.multiScalarCellCount > 0)
        #expect(mixedCensus != styledCensus)
    }

    @Test("cell storage is exact stride arithmetic over physical row extents")
    func cellStorageIsExact() throws {
        // Why it exists: the probe's entire advantage over `just benchmark-memory` is that its
        // bytes are exact rather than sampled or bucket-rounded (doc 15's F6). If this identity
        // ever stops holding, the probe has silently become an estimator.
        let census = try census(payload(named: "scrollback-plain"))
        let totalRows = census.screenRowCount + census.scrollbackRowCount
        #expect(census.cellCount >= census.screenRowCount * Self.geometry.columns)
        #expect(census.cellCount < totalRows * Self.geometry.columns)
        // Exactness survives doc 28's packing; the arithmetic it is exact *in* changed. Live
        // rows are still stride times extent, and retained rows are now the exact byte count
        // of their packed blobs -- neither sampled nor bucket-rounded, which is the property
        // this test exists to hold.
        #expect(census.cellStorageBytes
            == census.screenRowCount * Self.geometry.columns * census.cellStrideBytes
                + census.retainedPackedPayloadBytes)
        // The headline: a retained cell now costs a small fraction of the live-grid stride.
        #expect(census.retainedBytesPerStoredCell < Double(census.cellStrideBytes) / 4)
    }

    @Test("a run deep enough to evict retains nothing it evicted")
    func evictingRunDoesNotRetain() throws {
        // Why it exists: doc 15's F4 found eviction retaining rows it dropped. The probe must
        // report a leak rather than fold it into an otherwise plausible byte count, or it would
        // have measured that defect as a legitimate cost.
        //
        // The line count is chosen to exceed the production budget at this geometry, since the
        // probe deliberately measures the production budget only -- see `measure`.
        let deep = MemoryProbeMatrix.payloads(columns: Self.geometry.columns, lineCount: 12_000)
        let plain = try #require(deep.first { $0.name == "scrollback-plain" })
        let report = try #require(measure(
            payload: plain,
            columns: Self.geometry.columns,
            rows: Self.geometry.rows
        ))
        #expect(report.census.scrollbackRowCount > 0)
        #expect(report.census.hasRetainedRowStorageLeak == false)
    }

    @Test("the heap snapshot cannot report more bytes in use than the allocator obtained")
    func heapSnapshotIsSelfConsistent() {
        // Why it exists: the whole attribution rests on `bytesAllocated - bytesInUse` being the
        // allocator's own overhead. If that subtraction could go negative the split is meaningless,
        // so this pins the ordering the malloc zone API promises rather than assuming it.
        let snapshot = mallocHeapSnapshot()
        #expect(snapshot.blocksInUse > 0)
        #expect(snapshot.bytesInUse > 0)
        #expect(snapshot.bytesAllocated >= snapshot.bytesInUse)
    }

    // No test asserts on a heap *delta*, and that is deliberate. `mallocHeapSnapshot` reads the
    // whole process, so under the parallel test runner another suite's allocations land inside any
    // before/after window -- this file briefly had such a test and it read 76 MB of "overhead" from
    // its neighbours. Delta-based claims (bucket rounding, coverage) are made by the probe binary,
    // which owns its process. What stays testable here is the single-snapshot invariant below and
    // everything derived from the census, which is exact and process-independent.

    @Test("feeding in chunks reaches the same terminal state as feeding all at once")
    func chunkedFeedMatchesSingleShotFeed() throws {
        // Intent: chunk size changes when bytes arrive, never what the terminal ends up holding.
        // Why it exists: the probe fed each payload in one call, which made `feed` materialize an
        //   action array proportional to the whole payload -- tens of MB of transient LARGE
        //   allocations that landed in the footprint delta and were attributed to *holding* a
        //   terminal. Chunking fixes the measurement, but only if it is state-neutral; if it were
        //   not, every census in this file would become chunk-size-dependent.
        // Scenario: a real PTY delivers output in small reads, never as one 600 KB block.
        let deep = MemoryProbeMatrix.payloads(columns: Self.geometry.columns, lineCount: 3_000)
        let mixed = try #require(deep.first { $0.name == "scrollback-mixed" })

        let singleShot = try #require(measure(
            payload: mixed, columns: Self.geometry.columns, rows: Self.geometry.rows, chunkBytes: nil
        )).census
        let chunked = try #require(measure(
            payload: mixed, columns: Self.geometry.columns, rows: Self.geometry.rows, chunkBytes: 4_096
        )).census
        let tinyChunks = try #require(measure(
            payload: mixed, columns: Self.geometry.columns, rows: Self.geometry.rows, chunkBytes: 7
        )).census

        #expect(chunked == singleShot)
        // Seven bytes splits multi-byte UTF-8 and escape sequences mid-token, which is the case a
        // stream parser has to carry state across and the one most likely to diverge.
        #expect(tinyChunks == singleShot)
    }

    @Test("the matrix is deterministic across runs")
    func matrixIsDeterministic() throws {
        // Why it exists: this is the probe's reason to exist over `benchmark-memory`, whose
        // sampling made two runs of the same code incomparable (doc 15's F6). Census fields must
        // be identical run to run; footprint is excluded because process pages legitimately vary.
        let first = runMatrix(columns: 40, rows: 8, lineCount: 300)
        let second = runMatrix(columns: 40, rows: 8, lineCount: 300)
        #expect(first.payloads.map(\.census) == second.payloads.map(\.census))
    }
}
