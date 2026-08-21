// Unicode 17.0 canonical decomposition and root-locale full case folding for search.
//
// Every scalar-level question this file asks -- combining class, canonical
// decomposition, full case fold -- is one read of the generated per-scalar
// record, so a scalar that maps to itself costs a single table lookup rather
// than a binary search per question. The record table is search-only; the feed
// path's classification palette is a separate table and never carries these
// properties.

/// Produces pinned NFD scalars without importing Foundation or inheriting the toolchain's Unicode version.
func canonicalDecomposition(of scalars: some Collection<Unicode.Scalar>) -> [Unicode.Scalar] {
    var result: [UInt32] = []
    result.reserveCapacity(scalars.count)
    for scalar in scalars {
        appendCanonicalDecomposition(of: scalar.value, to: &result)
    }
    canonicallyOrder(&result)
    return result.map { Unicode.Scalar($0)! }
}

/// Returns the Unicode full case-fold mapping for one scalar, or the scalar itself when unmapped.
///
/// Returns `TerminalScalars` rather than an array so the overwhelmingly common
/// identity and one-to-one mappings stay off the heap.
func fullCaseFold(of scalar: Unicode.Scalar) -> TerminalScalars {
    let record = GeneratedCanonicalCaselessTables.record(for: scalar.value)
    guard record.foldLength > 0 else { return TerminalScalars(scalar) }
    if record.foldLength == 1 {
        return TerminalScalars(
            Unicode.Scalar(GeneratedCanonicalCaselessTables.foldPool[record.foldStart])!
        )
    }
    var folded = TerminalScalars()
    for index in record.foldStart..<(record.foldStart + record.foldLength) {
        folded.append(Unicode.Scalar(GeneratedCanonicalCaselessTables.foldPool[index])!)
    }
    return folded
}

/// Reports that a scalar is already its own canonical caseless key, so search can
/// answer a one-scalar cell without constructing a key at all.
func isCanonicalCaselessIdentity(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    // Hangul syllables decompose arithmetically and so carry no table mapping;
    // without this guard the record would call every one of them unmapped.
    guard isHangulSyllable(value) == false else { return false }
    return GeneratedCanonicalCaselessTables.record(for: value).mapsToItself
}

/// Builds the D145 canonical caseless key used to compare already-segmented graphemes.
func canonicalCaselessKey(for scalars: some Collection<Unicode.Scalar>) -> [Unicode.Scalar] {
    var decomposed: [UInt32] = []
    decomposed.reserveCapacity(scalars.count)
    for scalar in scalars {
        appendCanonicalDecomposition(of: scalar.value, to: &decomposed)
    }
    canonicallyOrder(&decomposed)

    var folded: [UInt32] = []
    folded.reserveCapacity(decomposed.count)
    for value in decomposed {
        appendFullCaseFold(of: value, to: &folded)
    }

    // Unicode 17.0 D145 requires this second NFD pass because folding can
    // introduce a scalar with its own canonical decomposition.
    var result: [UInt32] = []
    result.reserveCapacity(folded.count)
    for value in folded {
        appendCanonicalDecomposition(of: value, to: &result)
    }
    canonicallyOrder(&result)
    return result.map { Unicode.Scalar($0)! }
}

private let hangulSyllableBase: UInt32 = 0xAC00
private let hangulLeadingBase: UInt32 = 0x1100
private let hangulVowelBase: UInt32 = 0x1161
private let hangulTrailingBase: UInt32 = 0x11A7
private let hangulLeadingCount: UInt32 = 19
private let hangulVowelCount: UInt32 = 21
private let hangulTrailingCount: UInt32 = 28
private let hangulSyllableCount = hangulLeadingCount * hangulVowelCount * hangulTrailingCount

private func isHangulSyllable(_ value: UInt32) -> Bool {
    value >= hangulSyllableBase && value < hangulSyllableBase + hangulSyllableCount
}

/// Appends a scalar's canonical decomposition, handling Hangul's algorithmic form inline.
///
/// The table holds decompositions already resolved to their final components, so
/// this walks a flat pool slice instead of recursing per component.
private func appendCanonicalDecomposition(of value: UInt32, to result: inout [UInt32]) {
    if isHangulSyllable(value) {
        let syllableIndex = value - hangulSyllableBase
        result.append(hangulLeadingBase + syllableIndex / (hangulVowelCount * hangulTrailingCount))
        result.append(hangulVowelBase + (syllableIndex % (hangulVowelCount * hangulTrailingCount)) / hangulTrailingCount)
        let trailingIndex = syllableIndex % hangulTrailingCount
        if trailingIndex != 0 {
            result.append(hangulTrailingBase + trailingIndex)
        }
        return
    }

    let record = GeneratedCanonicalCaselessTables.record(for: value)
    guard record.decompositionLength > 0 else {
        result.append(value)
        return
    }
    let start = record.decompositionStart
    result.append(
        contentsOf: GeneratedCanonicalCaselessTables.decompositionPool[
            start..<(start + record.decompositionLength)
        ]
    )
}

private func appendFullCaseFold(of value: UInt32, to result: inout [UInt32]) {
    let record = GeneratedCanonicalCaselessTables.record(for: value)
    guard record.foldLength > 0 else {
        result.append(value)
        return
    }
    let start = record.foldStart
    result.append(
        contentsOf: GeneratedCanonicalCaselessTables.foldPool[
            start..<(start + record.foldLength)
        ]
    )
}

/// Applies the stable canonical-ordering rule within each starter-delimited combining run.
private func canonicallyOrder(_ values: inout [UInt32]) {
    // Guard first: most graphemes decompose to a single scalar, and a lone
    // scalar is trivially ordered.
    guard values.count > 1 else { return }
    for index in 1..<values.count {
        let value = values[index]
        let combiningClass = GeneratedCanonicalCaselessTables.record(for: value).combiningClass
        guard combiningClass != 0 else { continue }
        var insertionIndex = index
        while insertionIndex > 0,
              GeneratedCanonicalCaselessTables.record(
                  for: values[insertionIndex - 1]
              ).combiningClass > combiningClass {
            values[insertionIndex] = values[insertionIndex - 1]
            insertionIndex -= 1
        }
        values[insertionIndex] = value
    }
}
