// Search state, retained-index maintenance, projection scanning, and match resolution.
// Terminal owns viewport changes, damage, alternate-screen gating, and the live grid context.

import DequeModule

/// Exposes stable closed-history match endpoints to behavioral tests without display geometry.
struct IndexedSearchRecordRange: Equatable, Sendable {
    var start: Terminal.LogicalLineStore.RecordTextPosition
    var end: Terminal.LogicalLineStore.RecordTextPosition
}

extension Terminal {
    /// Owns one search query and its retained-history index without retaining live grid data.
    struct Search: Equatable, Sendable {
        var query: String
        var position: TextAnchor
        private var index: SearchMatchIndex

        /// Supplies the live grid inputs needed for one search read without retaining them.
        struct Context {
            let history: LogicalLineStore
            let projection: ProjectionRows
            let evictedRowCount: Int
            let columnCount: Int

            var projectionRowCount: Int { projection.count }

            func projectedCellEnd(in row: GridRow) -> Int {
                Terminal.projectedCellEnd(in: row, columns: columnCount)
            }

            func rowContainsContent(_ row: GridRow) -> Bool {
                Terminal.rowContainsContent(row)
            }
        }

        /// Stores matches over immutable closed history and leaves only the bounded mutable suffix
        /// for each read to rescan.
        private struct SearchMatchIndex: Equatable, Sendable {
            var needleKeys: [SearchGraphemeKey]
            var indexedThroughRecord: LogicalLineStore.RecordIdentity?
            var retainedStart: LogicalLineStore.RecordTextPosition?
            var boundaryWindow: [NeedleWindow<LogicalLineStore.RecordTextPosition>.Unit]
            var prefixMatches: Deque<RecordSearchRange>
        }

        /// Keeps an indexed occurrence independent of the width used to display its records.
        private struct RecordSearchRange: Equatable, Sendable {
            var start: LogicalLineStore.RecordTextPosition
            var end: LogicalLineStore.RecordTextPosition
        }

        /// Couples a retained seed unit to the content rank where that unit starts.
        private struct RankedSearchUnit: Equatable, Sendable {
            var unit: NeedleWindow<TextAnchor>.Unit
            var startRank: Int
        }

        /// Keeps a mutable-suffix match with the rank of the unit where it starts.
        private struct RankedSearchRange: Equatable, Sendable {
            var range: TextAnchorRange
            var startRank: Int
        }

        /// Presents record-keyed closed matches and a freshly scanned suffix as one ordered
        /// collection, in the two coordinate systems the two halves are keyed in.
        ///
        /// Holds no store and offers no subscript on purpose. Resolving a record coordinate folds
        /// its record, so the reads that only *order* matches -- which is every ordered read but the
        /// few endpoints they end up returning -- must be able to leave that cost unspent
        /// (`31/I7`); and carrying a second live reference to the store would make the arena
        /// non-uniquely referenced on every read, which is the copy `research/31/F13` measured.
        private struct SearchMatchSnapshot {
            var prefix: Deque<RecordSearchRange>
            var suffix: [RankedSearchRange]
            var positionRank: Int?

            var count: Int { prefix.count + suffix.count }
            var isEmpty: Bool { count == 0 }
        }

        /// Starts a query at one absolute stream boundary and indexes current closed history.
        init(query: String, position: TextAnchor, history: LogicalLineStore) {
            let needleKeys = Self.searchGraphemeKeys(for: query)
            self.query = query
            self.position = position
            index = SearchMatchIndex(
                needleKeys: needleKeys,
                indexedThroughRecord: nil,
                retainedStart: nil,
                boundaryWindow: [],
                prefixMatches: []
            )
            index = builtSearchMatchIndex(needleKeys: needleKeys, history: history)
        }

        /// Derives a longer needle's closed-history index from the starts already known to match
        /// its strict key prefix, or returns nil when the query requires a from-scratch build.
        func refined(
            query: String,
            position: TextAnchor,
            history: LogicalLineStore
        ) -> Search? {
            let needleKeys = Self.searchGraphemeKeys(for: query)
            let oldKeys = index.needleKeys
            guard needleKeys.count > oldKeys.count,
                  Array(needleKeys.prefix(oldKeys.count)) == oldKeys,
                  let refinedIndex = refinedSearchMatchIndex(
                    needleKeys: needleKeys,
                    appendedKeyCount: needleKeys.count - oldKeys.count,
                    history: history
                  )
            else { return nil }
            var result = self
            result.query = query
            result.position = position
            result.index = refinedIndex
            return result
        }

        /// Bounds the rows whose presentation can change when nearby text changes.
        var damageRowRadius: Int { max(1, index.needleKeys.count - 1) }

        /// The matched readout before public projection: the counter's numbers, the
        /// selected occurrence, and the occurrences intersecting the asked rows.
        struct Readout {
            let selected: Int
            let total: Int
            let activeMatch: TextAnchorRange
            let viewportMatches: [TextAnchorRange]
        }

        /// Derives the counter and highlights from one current-match snapshot, or nil when
        /// the needle matches nothing.
        func readout(
            intersecting absoluteRows: Range<Int>,
            context: Context
        ) -> Readout? {
            let matches = currentMatches(in: context)
            guard let resolved = resolvedSearchMatch(in: matches, context: context) else {
                return nil
            }
            let firstPossibleStart = absoluteRows.lowerBound - damageRowRadius
            var matchIndex = searchMatchLowerBound(
                in: matches,
                notBefore: TextAnchor(row: firstPossibleStart, column: 0),
                context: context
            )
            var result: [TextAnchorRange] = []
            while matchIndex < matches.count {
                let match = resolvedSearchMatchRange(
                    matchIndex,
                    in: matches,
                    context: context
                )
                guard match.start.row < absoluteRows.upperBound else { break }
                if Self.range(match, intersects: absoluteRows) { result.append(match) }
                matchIndex += 1
            }
            return Readout(
                selected: matches.count - 1 - resolved.index,
                total: matches.count,
                activeMatch: resolved.match,
                viewportMatches: result
            )
        }

        /// Bypasses the retained index and scans the requested rows directly.
        func scannedMatchRanges(
            intersecting absoluteRows: Range<Int>,
            context: Context
        ) -> [TextAnchorRange] {
            searchMatches(
                needleKeys: index.needleKeys,
                intersecting: absoluteRows,
                context: context
            )
        }

        /// Selects the newest current match and returns it, if any.
        mutating func selectNewest(in context: Context) -> TextAnchorRange? {
            let matches = currentMatches(in: context)
            guard matches.isEmpty == false else { return nil }
            let match = resolvedSearchMatchRange(matches.count - 1, in: matches, context: context)
            position = match.start
            return match
        }

        /// Moves to the next older match, wrapping to the newest.
        mutating func moveOlder(in context: Context) -> TextAnchorRange? {
            let matches = currentMatches(in: context)
            guard let current = resolvedSearchMatch(in: matches, context: context)?.index else {
                return nil
            }
            let target = resolvedSearchMatchRange(
                current > 0 ? current - 1 : matches.count - 1,
                in: matches,
                context: context
            )
            position = target.start
            return target
        }

        /// Moves to the next newer match, wrapping to the oldest.
        mutating func moveNewer(in context: Context) -> TextAnchorRange? {
            let matches = currentMatches(in: context)
            guard let current = resolvedSearchMatch(in: matches, context: context)?.index else {
                return nil
            }
            let target = resolvedSearchMatchRange(
                current + 1 < matches.count ? current + 1 : 0,
                in: matches,
                context: context
            )
            position = target.start
            return target
        }

        /// Exposes retained record endpoints to the search index behavioral tests.
        var indexedRecordRanges: [IndexedSearchRecordRange] {
            index.prefixMatches.map {
                IndexedSearchRecordRange(start: $0.start, end: $0.end)
            }
        }

        /// Resolves record-keyed closed matches together with the bounded mutable suffix.
        private func currentMatches(in context: Context) -> SearchMatchSnapshot {
            let retainedPositionRank = recordPosition(of: position, context: context).flatMap {
                context.history.contentRank(of: $0)
            }
            let prefixEndRow = context.evictedRowCount
                + context.history.closedPrefixDisplayRowCount
            let streamEndRow = context.evictedRowCount + context.projectionRowCount
            guard prefixEndRow < streamEndRow else {
                return SearchMatchSnapshot(
                    prefix: index.prefixMatches,
                    suffix: [],
                    positionRank: retainedPositionRank
                )
            }
            let suffixRows = prefixEndRow..<streamEndRow
            let suffixLastContentRow = lastProjectedContentRow(in: suffixRows, context: context)
            guard let suffixLastContentRow else {
                return SearchMatchSnapshot(
                    prefix: index.prefixMatches,
                    suffix: [],
                    positionRank: retainedPositionRank
                )
            }
            // The seed's own endpoints are resolved eagerly rather than on demand: there are at most
            // needle-length-minus-one of them, which is the bound the mutable suffix's rescan already
            // carries (`31/AR4`), and a match that starts inside the seed needs them.
            var seed = index.boundaryWindow.compactMap {
                unit -> RankedSearchUnit? in
                guard let start = context.history.position(of: unit.start),
                      let end = context.history.position(of: unit.end),
                      let startRank = context.history.contentRank(of: unit.start)
                else { return nil }
                return RankedSearchUnit(
                    unit: NeedleWindow.Unit(
                        key: unit.key,
                        start: TextAnchor(
                            row: context.evictedRowCount + start.displayRow,
                            column: start.column
                        ),
                        end: TextAnchor(
                            row: context.evictedRowCount + end.displayRow,
                            column: end.column
                        )
                    ),
                    startRank: startRank
                )
            }
            var matchingSeedSuffixCount = 0
            if context.history.closedRecordCount > 0 {
                if let scan = context.history.closedRecordScan(
                    at: context.history.closedRecordCount - 1
                ),
                   let start = context.history.position(of: recordPosition(endingRecord: scan)),
                   let startRank = context.history.contentRank(
                    of: recordPosition(endingRecord: scan)
                   )
                {
                    seed.append(RankedSearchUnit(
                        unit: NeedleWindow.Unit(
                            key: .scalar(0x0A),
                            start: TextAnchor(
                                row: context.evictedRowCount + start.displayRow,
                                column: start.column
                            ),
                            end: TextAnchor(row: prefixEndRow, column: 0)
                        ),
                        startRank: startRank
                    ))
                    matchingSeedSuffixCount = 1
                }
            }
            let scan = scanSearchUnits(
                needleKeys: index.needleKeys,
                seededBy: seed,
                absoluteRows: suffixRows.lowerBound..<(suffixLastContentRow + 1),
                lastContentRow: suffixLastContentRow,
                matching: matchingSeedSuffixCount > 0
                    ? max(context.evictedRowCount, prefixEndRow - 1)..<suffixRows.upperBound
                    : suffixRows,
                matchingSeedSuffixCount: matchingSeedSuffixCount,
                rankBase: context.history.closedContentUnitTotal(
                    includingTrailingBoundary: true
                ),
                capturing: retainedPositionRank == nil && position.row >= suffixRows.lowerBound
                    ? position
                    : nil,
                context: context
            )
            return SearchMatchSnapshot(
                prefix: index.prefixMatches,
                suffix: scan.matches,
                positionRank: retainedPositionRank ?? scan.positionRank
            )
        }

        /// Resolves one ordered match into the geometry the current width gives it.
        ///
        /// The only place a stored record coordinate becomes display rows, so the count of these a
        /// read makes is the count `31/AR3` bounds by the viewport.
        private func resolvedSearchMatchRange(
            _ index: Int,
            in matches: SearchMatchSnapshot,
            context: Context
        ) -> TextAnchorRange {
            if index >= matches.prefix.count {
                return matches.suffix[index - matches.prefix.count].range
            }
            let match = matches.prefix[index]
            guard let start = context.history.position(of: match.start),
                  let end = context.history.position(of: match.end)
            else {
                preconditionFailure("the search index retained a retired record coordinate")
            }
            return TextAnchorRange(
                start: TextAnchor(
                    row: context.evictedRowCount + start.displayRow,
                    column: start.column
                ),
                end: TextAnchor(
                    row: context.evictedRowCount + end.displayRow,
                    column: end.column
                )
            )
        }

        /// The record coordinate a stream anchor names, or nil when the anchor is not in a closed
        /// record -- the open tail, the live grid, or past the stream.
        private func recordPosition(
            of anchor: TextAnchor,
            context: Context
        ) -> LogicalLineStore.RecordTextPosition? {
            guard let address = context.history.address(
                ofDisplayRow: anchor.row - context.evictedRowCount,
                column: anchor.column
            ) else { return nil }
            return context.history.recordTextPosition(
                recordIndex: address.recordIndex,
                cellOffset: address.cellOffset
            )
        }

        /// The first ordered match starting at or after `anchor`.
        ///
        /// Closed matches are ordered by their record coordinates, so the query point is addressed
        /// once and every probe after that compares two record coordinates. Ordering the
        /// history-sized half therefore folds nothing, which is what keeps an ordered read's cost on
        /// the matches it returns rather than on the matches history holds (`31/I7`).
        private func searchMatchLowerBound(
            in matches: SearchMatchSnapshot,
            notBefore anchor: TextAnchor,
            context: Context
        ) -> Int {
            guard anchor.row >= context.evictedRowCount else { return 0 }
            if let position = recordPosition(of: anchor, context: context) {
                var low = 0
                var high = matches.prefix.count
                while low < high {
                    let middle = low + (high - low) / 2
                    if matches.prefix[middle].start < position {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                if low < matches.prefix.count { return low }
            }
            // Either the anchor lies past every closed record, or no closed match starts at or after
            // it; the mutable suffix is keyed in display anchors, so it answers in its own terms.
            var low = 0
            var high = matches.suffix.count
            while low < high {
                let middle = low + (high - low) / 2
                if matches.suffix[middle].range.start < anchor {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return matches.prefix.count + low
        }

        /// Advances or trims the closed-record index after the store changes record ownership.
        mutating func synchronizeIndex(with history: LogicalLineStore) {
            var search = self
            let closedCount = history.closedRecordCount
            let retainedStart = closedCount > 0
                ? history.recordTextPosition(recordIndex: 0, cellOffset: 0)
                : nil
            let indexedThrough = closedCount > 0
                ? history.recordIdentity(at: closedCount - 1)
                : nil
            guard retainedStart != search.index.retainedStart
                || indexedThrough != search.index.indexedThroughRecord
            else { return }
            Instrument.searchIndexMaintenance.record()

            if let retainedStart {
                while let first = search.index.prefixMatches.first,
                      first.start < retainedStart
                {
                    search.index.prefixMatches.removeFirst()
                }
            } else {
                search.index.prefixMatches.removeAll()
            }

            let previousThrough = search.index.indexedThroughRecord
            let tailRegressed = previousThrough.map { previous in
                indexedThrough == nil || indexedThrough! < previous
            } ?? false
            if tailRegressed {
                if let last = closedRecordEndPosition(in: history) {
                    var low = 0
                    var high = search.index.prefixMatches.count
                    while low < high {
                        let middle = low + (high - low) / 2
                        Instrument.searchIndexMaintenance.record()
                        if search.index.prefixMatches[middle].end <= last {
                            low = middle + 1
                        } else {
                            high = middle
                        }
                    }
                    search.index.prefixMatches.removeLast(search.index.prefixMatches.count - low)
                } else {
                    search.index.prefixMatches.removeAll()
                }
                let boundaryWindow = recordSearchBoundaryWindow(
                    needleKeys: search.index.needleKeys,
                    endingAt: closedCount,
                    history: history
                )
                assert(boundaryWindow.count <= max(0, search.index.needleKeys.count - 1))
                search.index.boundaryWindow = boundaryWindow
            } else {
                let appendStart: Int
                if let previousThrough,
                   let previousIndex = history.recordIndex(of: previousThrough),
                   previousIndex < closedCount
                {
                    appendStart = previousIndex + 1
                } else if previousThrough == nil {
                    appendStart = 0
                } else {
                    appendStart = 0
                    search.index.prefixMatches.removeAll()
                    search.index.boundaryWindow.removeAll()
                }
                if appendStart < closedCount {
                    let advanced = scanClosedRecordSearchUnits(
                        needleKeys: search.index.needleKeys,
                        seededBy: search.index.boundaryWindow,
                        records: appendStart..<closedCount,
                        includesLeadingBoundary: appendStart > 0,
                        history: history
                    )
                    search.index.prefixMatches.append(contentsOf: advanced.matches)
                    assert(
                        advanced.trailingUnits.count <= max(0, search.index.needleKeys.count - 1)
                    )
                    search.index.boundaryWindow = advanced.trailingUnits
                } else if search.index.boundaryWindow.contains(where: {
                    history.position(of: $0.start) == nil || history.position(of: $0.end) == nil
                }) {
                    let boundaryWindow = recordSearchBoundaryWindow(
                        needleKeys: search.index.needleKeys,
                        endingAt: closedCount,
                        history: history
                    )
                    assert(boundaryWindow.count <= max(0, search.index.needleKeys.count - 1))
                    search.index.boundaryWindow = boundaryWindow
                }
            }
            search.index.retainedStart = retainedStart
            search.index.indexedThroughRecord = indexedThrough
            self = search
        }

        private func builtSearchMatchIndex(
            needleKeys: [SearchGraphemeKey],
            history: LogicalLineStore
        ) -> SearchMatchIndex {
            let closedCount = history.closedRecordCount
            let prefixScan = scanClosedRecordSearchUnits(
                needleKeys: needleKeys,
                seededBy: [],
                records: 0..<closedCount,
                includesLeadingBoundary: false,
                history: history
            )
            assert(prefixScan.trailingUnits.count <= max(0, needleKeys.count - 1))
            return SearchMatchIndex(
                needleKeys: needleKeys,
                indexedThroughRecord: closedCount > 0
                    ? history.recordIdentity(at: closedCount - 1)
                    : nil,
                retainedStart: closedCount > 0
                    ? history.recordTextPosition(recordIndex: 0, cellOffset: 0)
                    : nil,
                boundaryWindow: prefixScan.trailingUnits,
                prefixMatches: Deque(prefixScan.matches)
            )
        }

        /// Rechecks only merged record neighborhoods around starts that matched the old needle.
        private func refinedSearchMatchIndex(
            needleKeys: [SearchGraphemeKey],
            appendedKeyCount: Int,
            history: LogicalLineStore
        ) -> SearchMatchIndex? {
            let closedCount = history.closedRecordCount
            var neighborhoods: [Range<Int>] = []
            for match in index.prefixMatches {
                guard let start = history.recordIndex(of: match.start.record),
                      let end = history.recordIndex(of: match.end.record)
                else { return nil }
                let neighborhood = Range(
                    uncheckedBounds: (
                        max(0, start - appendedKeyCount),
                        min(closedCount, end + 1 + appendedKeyCount)
                    )
                )
                if let last = neighborhoods.last, last.upperBound >= neighborhood.lowerBound {
                    neighborhoods[neighborhoods.count - 1] = Range(
                        uncheckedBounds: (
                            last.lowerBound,
                            max(last.upperBound, neighborhood.upperBound)
                        )
                    )
                } else {
                    neighborhoods.append(neighborhood)
                }
            }

            let oldStarts = index.prefixMatches.map(\.start)
            var matches: [RecordSearchRange] = []
            for records in neighborhoods {
                let scanned = scanClosedRecordSearchUnits(
                    needleKeys: needleKeys,
                    seededBy: [],
                    records: records,
                    includesLeadingBoundary: false,
                    history: history
                )
                matches.append(contentsOf: scanned.matches.filter { candidate in
                    var low = 0
                    var high = oldStarts.count
                    while low < high {
                        let middle = low + (high - low) / 2
                        if oldStarts[middle] < candidate.start {
                            low = middle + 1
                        } else {
                            high = middle
                        }
                    }
                    return low < oldStarts.count && oldStarts[low] == candidate.start
                })
            }

            let boundaryWindow = recordSearchBoundaryWindow(
                needleKeys: needleKeys,
                endingAt: closedCount,
                history: history
            )
            assert(boundaryWindow.count <= max(0, needleKeys.count - 1))
            return SearchMatchIndex(
                needleKeys: needleKeys,
                indexedThroughRecord: closedCount > 0
                    ? history.recordIdentity(at: closedCount - 1)
                    : nil,
                retainedStart: closedCount > 0
                    ? history.recordTextPosition(recordIndex: 0, cellOffset: 0)
                    : nil,
                boundaryWindow: boundaryWindow,
                prefixMatches: Deque(matches)
            )
        }

        private func closedRecordEndPosition(
            in history: LogicalLineStore
        ) -> LogicalLineStore.RecordTextPosition? {
            let count = history.closedRecordCount
            guard count > 0, let scan = history.closedRecordScan(at: count - 1) else { return nil }
            return recordPosition(endingRecord: scan)
        }

        /// Where one closed record's text ends, in the coordinates the index stores.
        private func recordPosition(
            endingRecord scan: LogicalLineStore.ClosedRecordScan
        ) -> LogicalLineStore.RecordTextPosition {
            scan.start.advanced(by: scan.cellCount)
        }

        /// `firstRecordCellStart` drops the cells before it in `records.lowerBound`, which is how
        /// the boundary window reads only the tail of a record that may hold the whole arena.
        /// Every other caller wants the record whole and leaves it at zero.
        private func scanClosedRecordSearchUnits(
            needleKeys: [SearchGraphemeKey],
            seededBy seed: [NeedleWindow<LogicalLineStore.RecordTextPosition>.Unit],
            records: Range<Int>,
            firstRecordCellStart: Int = 0,
            includesLeadingBoundary: Bool,
            history: LogicalLineStore
        ) -> (
            matches: [RecordSearchRange],
            trailingUnits: [NeedleWindow<LogicalLineStore.RecordTextPosition>.Unit]
        ) {
            guard needleKeys.isEmpty == false else { return ([], []) }
            var matches: [RecordSearchRange] = []
            var matcher = NeedleWindow<LogicalLineStore.RecordTextPosition>(
                needleKeys: needleKeys
            )

            for unit in seed.suffix(max(0, needleKeys.count - 1)) {
                matcher.join(unit)
            }
            // The record before the one being scanned, which the hard boundary between two records
            // needs and the previous turn of the loop already read.
            var previous = includesLeadingBoundary
                ? history.closedRecordScan(at: records.lowerBound - 1)
                : nil
            for recordIndex in records {
                Instrument.closedRecordSearchScan.record()
                guard let scan = history.closedRecordScan(at: recordIndex) else {
                    previous = nil
                    continue
                }
                if let previous {
                    if let match = matcher.record(
                        NeedleWindow.Unit(
                            key: .scalar(0x0A),
                            start: recordPosition(endingRecord: previous),
                            end: scan.start
                        )
                    ) {
                        matches.append(RecordSearchRange(start: match.start, end: match.end))
                    }
                }
                // The stable start is constant across the record and the cell offsets are the
                // loop's own arithmetic, so the scan advances that position instead of asking the
                // store to derive it twice per cell.
                let cellStart = recordIndex == records.lowerBound
                    ? min(max(0, firstRecordCellStart), scan.cellCount)
                    : 0
                history.forEachClosedRecordCell(
                    at: recordIndex,
                    cells: cellStart..<scan.cellCount
                ) { cellOffset, kind, scalars in
                    guard let key = Self.searchUnitKey(for: kind, scalars: scalars) else { return }
                    let width = kind == .wideHead ? 2 : 1
                    if let match = matcher.record(
                        NeedleWindow.Unit(
                            key: key,
                            start: scan.start.advanced(by: cellOffset),
                            end: scan.start.advanced(
                                by: min(scan.cellCount, cellOffset + width)
                            )
                        )
                    ) {
                        matches.append(RecordSearchRange(start: match.start, end: match.end))
                    }
                }
                previous = scan
            }

            return (matches, matcher.trailingUnits)
        }

        /// Rebuilds only the record units that can join a future mutable-suffix match.
        private func recordSearchBoundaryWindow(
            needleKeys: [SearchGraphemeKey],
            endingAt recordEnd: Int,
            history: LogicalLineStore
        ) -> [NeedleWindow<LogicalLineStore.RecordTextPosition>.Unit] {
            let targetCount = max(0, needleKeys.count - 1)
            guard targetCount > 0, recordEnd > 0 else { return [] }
            var start = recordEnd
            var firstCellStart = 0
            var available = 0
            while start > 0, available < targetCount {
                guard let scan = history.closedRecordScan(at: start - 1) else { break }
                start -= 1
                // Counted from the record's end, in blocks of what the window still needs: a
                // needle of n keys joins at most n-1 units across the seam, and a record is now
                // a whole logical line that may hold the arena. A cell yields at most one unit,
                // and the hard boundary a record contributes is added after its cells are
                // counted, so the last block may leave the window one unit long -- the matcher
                // keeps only the last n-1 in `trailingUnits`, so the extra is dropped there. A
                // block that yields no unit at all (a wide tail, a spacer) is followed by
                // another rather than by a walk of the record.
                var cellStart = scan.cellCount
                while cellStart > 0, available < targetCount {
                    let block = max(0, cellStart - (targetCount - available))
                    history.forEachClosedRecordCell(
                        at: start,
                        cells: block..<cellStart
                    ) { _, kind, _ in
                        switch kind {
                        case .narrow, .wideHead, .padding:
                            available += 1
                        case .wideTail, .spacerHead:
                            break
                        }
                    }
                    cellStart = block
                }
                firstCellStart = cellStart
                if start + 1 < recordEnd {
                    available += 1
                }
            }
            return scanClosedRecordSearchUnits(
                needleKeys: needleKeys,
                seededBy: [],
                records: start..<recordEnd,
                firstRecordCellStart: firstCellStart,
                includesLeadingBoundary: false,
                history: history
            ).trailingUnits
        }

        /// Scans only enough surrounding rows to decide which matches intersect `absoluteRows`.
        private func searchMatches(
            needleKeys: [SearchGraphemeKey],
            intersecting absoluteRows: Range<Int>,
            lastContentRow suppliedLastContentRow: Int? = nil,
            context: Context
        ) -> [TextAnchorRange] {
            guard needleKeys.isEmpty == false, absoluteRows.isEmpty == false else { return [] }
            let stream = context.projection
            let streamStart = context.evictedRowCount
            let streamEnd = context.evictedRowCount + stream.count
            let lastContentRow = suppliedLastContentRow
                ?? lastProjectedContentRow(in: streamStart..<streamEnd, context: context)
            guard let lastContentRow else { return [] }
            let contextRows = max(1, needleKeys.count - 1)
            let scanStart = max(streamStart, absoluteRows.lowerBound - contextRows)
            let scanEnd = min(lastContentRow + 1, absoluteRows.upperBound + contextRows)
            guard scanStart < scanEnd else { return [] }

            return scanSearchUnits(
                needleKeys: needleKeys,
                seededBy: [],
                absoluteRows: scanStart..<scanEnd,
                lastContentRow: lastContentRow,
                matching: absoluteRows,
                rankBase: 0,
                capturing: nil,
                stream: stream,
                context: context
            ).matches.map(\.range)
        }

        private func scanSearchUnits(
            needleKeys: [SearchGraphemeKey],
            seededBy seed: [RankedSearchUnit],
            absoluteRows: Range<Int>,
            lastContentRow: Int,
            matching matchRows: Range<Int>,
            matchingSeedSuffixCount: Int = 0,
            rankBase: Int,
            capturing position: TextAnchor?,
            stream suppliedStream: ProjectionRows? = nil,
            context: Context
        ) -> (matches: [RankedSearchRange], positionRank: Int?) {
            let stream = suppliedStream ?? context.projection
            Instrument.projectionRow.record(count: absoluteRows.count)
            var matches: [RankedSearchRange] = []
            var matcher = NeedleWindow<TextAnchor>(needleKeys: needleKeys)
            var nextRank = rankBase
            var positionRank = position.map { _ in rankBase }

            let retainedSeed = Array(seed.suffix(needleKeys.count - 1 + matchingSeedSuffixCount))
            for (index, unit) in retainedSeed.enumerated() {
                if index >= retainedSeed.count - matchingSeedSuffixCount {
                    if let match = matcher.record(unit.unit) {
                        let range = TextAnchorRange(start: match.start, end: match.end)
                        if Self.range(range, intersects: matchRows) {
                            matches.append(RankedSearchRange(
                                range: range,
                                startRank: unit.startRank - (needleKeys.count - 1)
                            ))
                        }
                    }
                } else {
                    matcher.join(unit.unit)
                }
            }
            forEachSearchUnit(
                in: stream,
                absoluteRows: absoluteRows,
                lastContentRow: lastContentRow,
                context: context
            ) { key, start, end in
                let unitRank = nextRank
                nextRank += 1
                if let position, end <= position { positionRank = nextRank }
                if let match = matcher.record(NeedleWindow.Unit(
                    key: key,
                    start: start,
                    end: end
                )) {
                    let range = TextAnchorRange(start: match.start, end: match.end)
                    if Self.range(range, intersects: matchRows) {
                        matches.append(RankedSearchRange(
                            range: range,
                            startRank: unitRank - (needleKeys.count - 1)
                        ))
                    }
                }
            }

            return (matches, positionRank)
        }

        /// Streams the painted projection as match keys and anchors without constructing selection
        /// units or allocating an array for the common single-scalar cell.
        private func forEachSearchUnit(
            in stream: ProjectionRows,
            absoluteRows: Range<Int>,
            lastContentRow: Int,
            context: Context,
            _ body: (SearchGraphemeKey, TextAnchor, TextAnchor) -> Void
        ) {
            let streamStart = context.evictedRowCount
            let relativeRows = (absoluteRows.lowerBound - streamStart)..<(
                absoluteRows.upperBound - streamStart
            )
            stream.forEachRow(in: relativeRows) { relativeRow, row in
                let absoluteRow = context.evictedRowCount + relativeRow
                let end = context.projectedCellEnd(in: row)
                var column = 0
                while column < end {
                    let cell = row.cell(at: column)
                    let width = cell.kind == .wideHead ? 2 : 1
                    if let key = Self.searchUnitKey(for: cell.kind, scalars: row.scalars(of: cell)) {
                        body(
                            key,
                            TextAnchor(row: absoluteRow, column: column),
                            TextAnchor(row: absoluteRow, column: column + width)
                        )
                    }
                    column += width
                }
                if absoluteRow < lastContentRow, row.isSoftWrapped == false {
                    body(
                        .scalar(0x0A),
                        TextAnchor(row: absoluteRow, column: end),
                        TextAnchor(row: absoluteRow + 1, column: 0)
                    )
                }
            }
        }

        private func lastProjectedContentRow(
            in absoluteRows: Range<Int>,
            context: Context
        ) -> Int? {
            let stream = context.projection
            let lower = max(context.evictedRowCount, absoluteRows.lowerBound)
            let upper = min(context.evictedRowCount + stream.count, absoluteRows.upperBound)
            guard lower < upper else { return nil }
            for absoluteRow in (lower..<upper).reversed()
            where context.rowContainsContent(stream[absoluteRow - context.evictedRowCount])
            {
                return absoluteRow
            }
            return nil
        }

        /// Picks the nearest occurrence to the durable position, resolving equal distance later.
        private func resolvedSearchMatch(
            in matches: SearchMatchSnapshot,
            context: Context
        ) -> (index: Int, match: TextAnchorRange)? {
            guard matches.isEmpty == false else { return nil }
            let low = searchMatchLowerBound(
                in: matches,
                notBefore: position,
                context: context
            )
            if low == 0 { return (0, resolvedSearchMatchRange(0, in: matches, context: context)) }
            if low == matches.count {
                return (
                    matches.count - 1,
                    resolvedSearchMatchRange(matches.count - 1, in: matches, context: context)
                )
            }
            let later = resolvedSearchMatchRange(low, in: matches, context: context)
            // Every navigation leaves the position on an occurrence, so the tie that resolves toward
            // the later one is settled before anything measures a distance.
            if later.start == position { return (low, later) }
            let earlier = resolvedSearchMatchRange(low - 1, in: matches, context: context)
            guard let positionRank = matches.positionRank,
                  let earlierRank = searchMatchStartRank(
                    low - 1,
                    in: matches,
                    context: context
                  ),
                  let laterRank = searchMatchStartRank(low, in: matches, context: context)
            else {
                preconditionFailure("the current search snapshot has inconsistent content ranks")
            }
            let earlierDistance = abs(positionRank - earlierRank)
            let laterDistance = abs(laterRank - positionRank)
            return laterDistance <= earlierDistance ? (low, later) : (low - 1, earlier)
        }

        /// Gets one match's width-free start rank from the coordinate system that owns it.
        private func searchMatchStartRank(
            _ index: Int,
            in matches: SearchMatchSnapshot,
            context: Context
        ) -> Int? {
            if index >= matches.prefix.count {
                return matches.suffix[index - matches.prefix.count].startRank
            }
            return context.history.contentRank(of: matches.prefix[index].start)
        }

        private static func searchGraphemeKeys(for query: String) -> [SearchGraphemeKey] {
            let scalars = Array(query.unicodeScalars)
            guard let first = scalars.first else { return [] }
            var keys: [SearchGraphemeKey] = []
            var cluster = [first]
            var previous = first
            var breakState = GraphemeBreakState()

            for current in scalars.dropFirst() {
                if graphemeBreak(between: previous, and: current, state: &breakState) {
                    keys.append(searchGraphemeKey(for: cluster))
                    cluster = [current]
                    breakState = GraphemeBreakState()
                } else {
                    cluster.append(current)
                }
                previous = current
            }
            keys.append(searchGraphemeKey(for: cluster))
            return keys
        }

        private static func searchUnitKey(
            for kind: TerminalCellKind,
            scalars: some Collection<Unicode.Scalar>
        ) -> SearchGraphemeKey? {
            switch kind {
            case .narrow, .wideHead:
                searchGraphemeKey(for: scalars)
            case .padding:
                .scalar(0x20)
            case .wideTail, .spacerHead:
                nil
            }
        }

        /// Takes the cell's scalars borrowed, so scanning a painted cell never copies
        /// its inline `TerminalScalars` storage into an array just to ask for a key.
        private static func searchGraphemeKey(
            for scalars: some Collection<Unicode.Scalar>
        ) -> SearchGraphemeKey {
            if scalars.count == 1, let scalar = scalars.first {
                if let key = singleScalarSearchGraphemeKey(for: scalar) {
                    return key
                }
            }
            let key = canonicalCaselessKey(for: scalars)
            if key.count == 1, let scalar = key.first {
                return .scalar(scalar.value)
            }
            return .scalars(key)
        }

        /// Answers the one-scalar cell without building a key, or reports that the
        /// scalar needs the full D145 pipeline.
        ///
        /// Search scans a whole screen of these, so the two cases that cover almost
        /// every cell -- ASCII, and any scalar that is already its own canonical
        /// caseless key -- must not reach an allocation.
        private static func singleScalarSearchGraphemeKey(
            for scalar: Unicode.Scalar
        ) -> SearchGraphemeKey? {
            let value = scalar.value
            if value < 0x80 {
                return .scalar(value >= 0x41 && value <= 0x5A ? value + 0x20 : value)
            }
            return isCanonicalCaselessIdentity(scalar) ? .scalar(value) : nil
        }

        private static func range(
            _ range: TextAnchorRange,
            intersects rows: Range<Int>
        ) -> Bool {
            guard rows.isEmpty == false else { return false }
            let lastIncludedRow = range.end.column == 0 && range.end.row > range.start.row
                ? range.end.row - 1
                : range.end.row
            return range.start.row < rows.upperBound && lastIncludedRow >= rows.lowerBound
        }
    }
}
