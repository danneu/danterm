// Behavioral proofs that the memory probe's payload matrix exercises what its names claim.
//
// This is the probe's most important test and the least obvious one. Every number the probe
// produces is attributed to a payload by name, so a "styled" payload that emits no styles or a
// "unicode" payload that never spills would not fail loudly -- it would produce plausible,
// confidently wrong evidence, and `research/15/H2`, `research/15/H3`, and `research/15/H4` would
// be sized against it. These tests assert
// the payloads' observable effect on terminal state rather than their bytes, so the payload text
// can be rewritten freely as long as it still exercises the axis it is named for.
import Foundation
import Testing
import TerminalCore
@testable import TerminalMemoryProbeSupport

/// Guards the matrix's premise: each payload must actually produce the state it is named for.
struct TerminalMemoryProbeSupportTests {
    private static let geometry = (columns: 40, rows: 8)

    private func census(_ payload: MemoryProbePayload) throws -> TerminalMemoryCensus {
        try measure(
            payload: payload,
            columns: Self.geometry.columns,
            rows: Self.geometry.rows
        ).census
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

    @Test("selecting a payload by name yields exactly that payload, byte-for-byte")
    func namedSelectionYieldsOnlyThatPayload() {
        // Intent: `payloads(columns:lineCount:named:)` selects by name before materializing bytes,
        //   and the payload it returns is identical to the one the full matrix would have held.
        // Why it exists: `--payload NAME` is the probe's only attributable-footprint mode, and it
        //   is attributable only if the other five payloads' byte arrays were never allocated in
        //   the measured process. Selection has to happen at the builder, not by filtering a fully
        //   built matrix, and this pins that the shortcut still agrees with the long way round.
        let selected = MemoryProbeMatrix.payloads(columns: 40, lineCount: 10, named: "scrollback-styled")
        let fromFullMatrix = MemoryProbeMatrix.payloads(columns: 40, lineCount: 10)
            .first { $0.name == "scrollback-styled" }
        #expect(selected.map(\.name) == ["scrollback-styled"])
        #expect(selected.first?.bytes == fromFullMatrix?.bytes)
    }

    @Test("an unknown payload name selects nothing")
    func unknownNameSelectsNothing() {
        #expect(MemoryProbeMatrix.payloads(columns: 40, lineCount: 10, named: "nope").isEmpty)
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
        // The fixture corpus had at most nine distinct styles (`research/12/F3`), which is too few
        // to size a dedup table against. This payload exists to be harder than that, so the
        // assertion is a floor well above nine rather than a mere "greater than one".
        let census = try census(payload(named: "scrollback-styled"))
        #expect(census.styledCellCount > 0)
        #expect(census.distinctStyleCount > 20)
    }

    @Test("the unicode payload spills into multi-scalar storage")
    func unicodePayloadSpills() throws {
        // Live rows own spill allocations, so the count can be lower than the spill-cell count.
        let census = try census(payload(named: "scrollback-unicode"))
        #expect(census.multiScalarCellCount > 0)
        #expect(census.multiScalarAllocationCount > 0)
        #expect(census.multiScalarAllocationCount <= census.multiScalarCellCount)
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

        let mixedCensus = try measure(
            payload: mixed, columns: Self.geometry.columns, rows: Self.geometry.rows
        ).census
        let styledCensus = try measure(
            payload: styled, columns: Self.geometry.columns, rows: Self.geometry.rows
        ).census

        #expect(mixedCensus.styledCellCount > 0)
        #expect(mixedCensus.multiScalarCellCount > 0)
        #expect(mixedCensus != styledCensus)
    }

    @Test("cell storage is exact stride arithmetic over physical row extents")
    func cellStorageIsExact() throws {
        // Why it exists: the probe's entire advantage over `just benchmark-memory` is that its
        // bytes are exact rather than sampled or bucket-rounded (`research/15/F6`). If this identity
        // ever stops holding, the probe has silently become an estimator.
        let census = try census(payload(named: "scrollback-plain"))
        let totalRows = census.screenRowCount + census.scrollbackRowCount
        #expect(census.cellCount >= census.screenRowCount * Self.geometry.columns)
        #expect(census.cellCount < totalRows * Self.geometry.columns)
        // Exactness survives doc 31's record arena; the arithmetic it is exact *in* changed
        // again. Live rows are still stride times extent, and retained content is now the
        // arena's exact bytes in use -- neither sampled nor bucket-rounded, which is the
        // property this test exists to hold.
        #expect(census.cellStorageBytes
            == census.screenRowCount * Self.geometry.columns * census.cellStrideBytes
                + census.retainedArenaBytesInUse)
        // The headline: a retained cell costs a fraction of the live-grid stride. Bounded on
        // both sides deliberately. `C1` stores an 8-byte cell (`D9`), so the floor is what
        // says the cell really is packed and not a struct in disguise, and the ceiling is
        // what says the per-row header and side tables have not grown into a second cell's
        // worth. `C6` cleared `stride / 4`; `C1` sits just above it at ~8.6 B per stored
        // cell, which is the memory this pivot deliberately gave back for the read path.
        #expect(census.retainedBytesPerStoredCell > 8)
        #expect(census.retainedBytesPerStoredCell < Double(census.cellStrideBytes))
    }

    @Test("a run deep enough to evict retains nothing it evicted")
    func evictingRunDoesNotRetain() throws {
        // Why it exists: `research/15/F4` found eviction retaining rows it dropped. The probe must
        // report a leak rather than fold it into an otherwise plausible byte count, or it would
        // have measured that defect as a legitimate cost.
        //
        // The line count is chosen to exceed the production budget at this geometry, since the
        // probe deliberately measures the production budget only -- see `measure`.
        let deep = MemoryProbeMatrix.payloads(columns: Self.geometry.columns, lineCount: 12_000)
        let plain = try #require(deep.first { $0.name == "scrollback-plain" })
        let report = try measure(
            payload: plain,
            columns: Self.geometry.columns,
            rows: Self.geometry.rows
        )
        #expect(report.census.scrollbackRowCount > 0)
        #expect(report.census.hasRetainedStorageOverdraft == false)
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

    @Test("both footprint samples carry a released-byte reading")
    func footprintSamplesCarryReleasedByteReadings() throws {
        // Intent: every footprint sample in a report is accompanied by the bytes the allocator said
        //   it released just before that sample was taken, and both readings are required fields of
        //   the encoded report.
        // Why it exists: the footprint delta is only interpretable if the reader can see how much
        //   allocator hysteresis was cleared before each end of the window. `malloc_zone_pressure_relief`
        //   promises only best effort, so a reading of zero -- the allocator released nothing -- is a
        //   real and different outcome from the reading never having been taken. Making both fields
        //   required in the encoding is what keeps those two cases apart for anyone decoding a report.
        let report = try measure(
            payload: payload(named: "scrollback-plain"),
            columns: Self.geometry.columns,
            rows: Self.geometry.rows
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        let fields = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(fields["releasedBeforeFootprintBytes"] != nil)
        #expect(fields["releasedAfterFootprintBytes"] != nil)
        // The readings belong to this report's own window, so they must survive a round trip
        // alongside the samples they qualify.
        let decoded = try JSONDecoder().decode(MemoryProbePayloadReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("a report from before the readings existed no longer decodes")
    func reportWithoutReleasedReadingsIsRejected() throws {
        // Intent: a report that carries no released-byte readings is not silently read as one whose
        //   allocator released nothing.
        // Why it exists: this is the other half of the distinction above, and the half a decoder
        //   could quietly erase. If the fields were optional or defaulted, every archived report from
        //   before this instrument existed would decode as "released 0 bytes" and its footprint
        //   deltas would be over-trusted.
        let report = try measure(
            payload: payload(named: "empty"),
            columns: Self.geometry.columns,
            rows: Self.geometry.rows
        )
        var fields = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        fields.removeValue(forKey: "releasedBeforeFootprintBytes")
        fields.removeValue(forKey: "releasedAfterFootprintBytes")
        let stripped = try JSONSerialization.data(withJSONObject: fields)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MemoryProbePayloadReport.self, from: stripped)
        }
    }

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

        let singleShot = try measure(
            payload: mixed, columns: Self.geometry.columns, rows: Self.geometry.rows, chunkBytes: nil
        ).census
        let chunked = try measure(
            payload: mixed, columns: Self.geometry.columns, rows: Self.geometry.rows, chunkBytes: 4_096
        ).census
        let tinyChunks = try measure(
            payload: mixed, columns: Self.geometry.columns, rows: Self.geometry.rows, chunkBytes: 7
        ).census

        #expect(chunked == singleShot)
        // Seven bytes splits multi-byte UTF-8 and escape sequences mid-token, which is the case a
        // stream parser has to carry state across and the one most likely to diverge.
        #expect(tinyChunks == singleShot)
    }

    @Test("the matrix is deterministic across runs")
    func matrixIsDeterministic() throws {
        // Why it exists: this is the probe's reason to exist over `benchmark-memory`, whose
        // sampling made two runs of the same code incomparable (`research/15/F6`). Census fields must
        // be identical run to run; footprint is excluded because process pages legitimately vary.
        let first = try runMatrix(columns: 40, rows: 8, lineCount: 300)
        let second = try runMatrix(columns: 40, rows: 8, lineCount: 300)
        #expect(first.payloads.map(\.census) == second.payloads.map(\.census))
    }
}

/// Guards the report type's own invariant: a memory probe report describes at least one
/// measured payload, or it does not exist.
///
/// Separate from the matrix tests above because these assert on the shape of the artifact
/// rather than on what any payload does to a terminal.
struct MemoryProbeReportRefusalTests {
    @Test("the matrix refuses a geometry the engine will not build, before any payload is built")
    func matrixRefusesRejectedGeometry() {
        // Intent: `runMatrix` throws a named refusal for a geometry `Terminal.init` rejects,
        //   instead of returning a report describing nothing.
        // Why it exists: it used to drop the failed measurement with `compactMap` and return a
        //   well-formed report carrying `payloads: []` and a stride of 0. Printed, that is an
        //   obviously empty run; written to `--json`, it is an artifact a later reader can diff
        //   against a real one and read the zero as a measurement.
        #expect(throws: MemoryProbeFailure.geometryRejected(columns: 1, rows: 66)) {
            try runMatrix(columns: 1, rows: 66, lineCount: 10)
        }
        #expect(throws: MemoryProbeFailure.geometryRejected(columns: 40, rows: 0)) {
            try runMatrix(columns: 40, rows: 0, lineCount: 10)
        }
    }

    @Test("the matrix refuses a payload name it cannot build")
    func matrixRefusesUnknownPayloadName() {
        #expect(throws: MemoryProbeFailure.noPayloadMatched(name: "scrollback-imaginary")) {
            try runMatrix(columns: 40, rows: 8, lineCount: 10, only: "scrollback-imaginary")
        }
    }

    @Test("the stride the report heads with is the measured payload's own")
    func strideIsTheMeasuredPayloadsOwn() throws {
        // Why it exists: the field used to be stored and filled with `reports.first?...  ?? 0`,
        // so a report could carry a stride no payload in it had. Deriving it is what keeps the
        // header and the tables under it from disagreeing.
        let report = try runMatrix(columns: 40, rows: 8, lineCount: 100)
        #expect(report.cellStrideBytes == report.payloads[0].census.cellStrideBytes)
    }

    @Test("a report carrying no payloads does not decode")
    func reportWithoutPayloadsIsRejected() throws {
        // Intent: the non-empty invariant survives the wire, not just the constructor.
        // Why it exists: `--json` is the artifact the invariant exists for. A decoder that
        //   accepted `"payloads": []` would hand a reader a report whose every derived quantity
        //   is absent, in a schema that says it is complete.
        let report = try runMatrix(columns: 40, rows: 8, lineCount: 100)
        var fields = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        fields["payloads"] = []
        let emptied = try JSONSerialization.data(withJSONObject: fields)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MemoryProbeReport.self, from: emptied)
        }
    }

    @Test("coverage is absent rather than zero when the footprint did not move")
    func coverageIsAbsentForAnUnmovedFootprint() throws {
        // Intent: "the ratio is undefined" and "the grid explains none of the delta" stay apart.
        // Why it exists: the ratio divided by the delta and returned 0 for a zero denominator,
        //   which prints in the coverage column as `0.00` -- the same text a genuinely uncovered
        //   payload prints. This is the "a missing measurement is not a zero" rule in the one
        //   derived quantity of this report that still broke it.
        let measured = try runMatrix(columns: 40, rows: 8, lineCount: 100).payloads[0]
        var unmoved = measured
        unmoved.footprintAfterBytes = unmoved.footprintBeforeBytes
        #expect(unmoved.footprintCoverageOfCellStorage == nil)
        #expect(measured.footprintDeltaBytes != 0
            ? measured.footprintCoverageOfCellStorage != nil
            : measured.footprintCoverageOfCellStorage == nil)
    }
}
