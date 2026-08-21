// Pins import-free canonical decomposition and full case folding to Unicode 17.0.
import Foundation
import Testing

@testable import TerminalCore

/// Proves the generated Unicode search-key data and D145 algorithm across the full pinned corpora.
@Suite struct CanonicalCaselessTests {
    @Test("canonical decomposition matches every Unicode 17.0 normalization fixture")
    func officialNormalizationCorpusMatches() throws {
        // Intent: enforce both official NFD invariants for every normalization
        //   fixture, including the distinct c4/c5 compatibility group.
        // Why it exists: samples cannot prove recursive decomposition, canonical
        //   ordering stability, canonical singletons, and algorithmic Hangul.
        // Scenario: regenerating pinned Unicode data keeps NFD conformant across
        //   the complete official corpus without adopting compatibility folding.
        //
        // The sweep is exhaustive but the assertions are not per-relation: five
        // `#expect`s per line is 100,170 expectation events, which cost far more
        // than the decompositions they check. Mismatches accumulate instead, and
        // the run ends on one `#expect` plus the first `mismatchReportLimit`
        // recorded individually, so a failure still names its corpus line, its
        // relation, and the code points on both sides.
        var mismatches: [String] = []
        var checkedLines = 0

        func check(
            _ input: [Unicode.Scalar],
            equals expected: [Unicode.Scalar],
            relation: String,
            line: Int
        ) {
            let actual = canonicalDecomposition(of: input)
            guard actual != expected else { return }
            mismatches.append(
                """
                corpus line \(line), \(relation): \
                canonicalDecomposition(\(codePoints(input))) == \(codePoints(actual)), \
                expected \(codePoints(expected))
                """
            )
        }

        for (line, columns) in try normalizationFixtures() {
            let (c1, c2, c3, c4, c5) = (columns[0], columns[1], columns[2], columns[3], columns[4])
            check(c1, equals: c3, relation: "c1", line: line)
            check(c2, equals: c3, relation: "c2", line: line)
            check(c3, equals: c3, relation: "c3", line: line)
            check(c4, equals: c5, relation: "c4", line: line)
            check(c5, equals: c5, relation: "c5", line: line)
            checkedLines += 1
        }

        // A parser that silently yields nothing would make the sweep above vacuous,
        // so the corpus size is pinned: the pinned fixture has exactly this many
        // data lines, and it only changes when the Unicode version does.
        #expect(
            checkedLines == 20_034,
            "expected every data line of the pinned corpus, checked \(checkedLines)"
        )
        for message in mismatches.prefix(mismatchReportLimit) {
            Issue.record(Comment(rawValue: message))
        }
        // The count, not the array: `#expect(mismatches.isEmpty)` renders the whole
        // captured subexpression, which for a broad table regression is megabytes of
        // dump that buries the ten readable issues recorded just above.
        let mismatchCount = mismatches.count
        #expect(
            mismatchCount == 0,
            "canonical decomposition mismatches across \(checkedLines) corpus lines"
        )
    }

    /// How many individual mismatches get their own `Issue.record`; the rest are counted only.
    private var mismatchReportLimit: Int { 10 }

    @Test("full case folding matches every Unicode 17.0 C and F mapping")
    func officialCaseFoldingCorpusMatches() throws {
        // Intent: compare every generated full case-fold lookup with its official
        //   C or F mapping, including one-to-many mappings.
        // Why it exists: a sampled repertoire could silently leave arbitrary
        //   scripts case-sensitive or accidentally apply simple folding.
        // Scenario: terminal search uses the root-locale full mapping for every
        //   mapped scalar while deliberately excluding Turkic-only mappings.
        for (scalarValue, mapping) in try caseFoldingFixtures() {
            let scalar = try #require(Unicode.Scalar(scalarValue))
            let expected = try scalars(mapping)
            #expect(
                Array(fullCaseFold(of: scalar)) == expected,
                "fold mapping for U+\(String(scalarValue, radix: 16, uppercase: true))"
            )
        }
    }

    @Test("D145 key equates canonical spellings after full folding")
    func canonicalCaselessKeyOrder() throws {
        // Intent: pin the observable result of the full
        //   NFD(toCasefold(NFD(text))) key pipeline.
        // Why it exists: independently-correct decomposition and folding tables
        //   do not prove that canonical and case variants share one search key.
        // Scenario: precomposed uppercase N-tilde and its decomposed lowercase
        //   spelling become the same grapheme key while a bare n stays distinct.
        let upper = try scalars([0x00D1])
        let decomposed = try scalars([0x006E, 0x0303])
        #expect(canonicalCaselessKey(for: upper) == decomposed)
        #expect(canonicalCaselessKey(for: decomposed) == decomposed)
        #expect(canonicalCaselessKey(for: try scalars([0x006E])) != decomposed)
    }

    @Test("an unmapped combining mark still reorders its cluster")
    func unmappedCombiningMarkStillOrders() throws {
        // Intent: pin that canonical ordering happens for a mark that has neither
        //   a canonical decomposition nor a case fold.
        // Why it exists: combining class is a third, independent reason a scalar
        //   is not its own key. A shortcut keyed only on "no decomposition and no
        //   fold" would return this cluster unordered and silently break D145
        //   equivalence for every stacked-accent search.
        // Scenario: a with acute (class 230) then dot below (class 220) must key
        //   to a with dot below then acute, whichever order the text spelled.
        let asTyped = try scalars([0x0061, 0x0301, 0x0323])
        let ordered = try scalars([0x0061, 0x0323, 0x0301])
        #expect(canonicalCaselessKey(for: asTyped) == ordered)
        #expect(canonicalCaselessKey(for: ordered) == ordered)
    }

    @Test("scalars with no canonical or case mapping key to themselves")
    func unmappedScalarsKeyToThemselves() throws {
        // Intent: pin the key of the scalars that carry no canonical
        //   decomposition, no case fold, and combining class zero.
        // Why it exists: these are the bulk of the scanned codespace, and the key
        //   path answers them from a per-scalar record rather than by searching.
        //   A record that mislabels one would change what search matches.
        // Scenario: a CJK ideograph, a box-drawing character, and a braille
        //   pattern each search as exactly the scalar the cell holds.
        for value: UInt32 in [0x4E00, 0x754C, 0x2500, 0x256C, 0x2800, 0x28FF] {
            let scalar = try scalars([value])
            #expect(
                canonicalCaselessKey(for: scalar) == scalar,
                "U+\(hex(value)) should be its own canonical caseless key"
            )
        }
    }

    @Test("decomposition and case folding stay independent properties")
    func decompositionAndFoldingAreNotConflated() throws {
        // Intent: pin the key of a scalar that decomposes but does not fold, and
        //   of one that folds but does not decompose.
        // Why it exists: one per-scalar record now answers both questions, so a
        //   record that conflated the two would still pass a test built only on
        //   scalars where both apply, such as N-tilde.
        // Scenario: lowercase a-grave decomposes to a plus grave and folds to
        //   itself; Cyrillic capital A folds to lowercase and decomposes to
        //   itself.
        #expect(canonicalCaselessKey(for: try scalars([0x00E0])) == (try scalars([0x0061, 0x0300])))
        #expect(canonicalCaselessKey(for: try scalars([0x0410])) == (try scalars([0x0430])))
    }

    @Test("the record's combining class matches every Unicode 17.0 scalar")
    func combiningClassMatchesPinnedReference() {
        // Intent: compare the packed production record with the independently
        //   emitted reference combining class for every valid Unicode scalar.
        // Why it exists: combining class now travels through interning, a record
        //   palette, and two index stages. A packing bug there would misorder
        //   clusters in scripts no sampled fixture covers.
        // Scenario: regenerating the pinned Unicode data must preserve the
        //   canonical ordering input everywhere, not only where the normalization
        //   corpus happens to look.
        var checkedScalarCount = 0
        var mismatchedScalarCount = 0
        var firstMismatch: String?
        for range in canonicalCombiningClassReferenceRanges {
            for value in range.lowerBound...range.upperBound {
                guard Unicode.Scalar(value) != nil else { continue }
                checkedScalarCount += 1
                let actual = GeneratedCanonicalCaselessTables.record(for: value).combiningClass
                guard actual != range.combiningClass else { continue }
                mismatchedScalarCount += 1
                if firstMismatch == nil {
                    firstMismatch =
                        "U+\(hex(value)) expected combining class \(range.combiningClass), "
                        + "got \(actual)"
                }
            }
        }
        // A reference that yielded no ranges would make the sweep vacuous, so the
        // count of checked scalars is pinned to the assignable codespace.
        #expect(checkedScalarCount == 1_112_064, "checked \(checkedScalarCount) scalars")
        #expect(
            mismatchedScalarCount == 0,
            "combining class mismatches: \(mismatchedScalarCount), first \(firstMismatch ?? "none")"
        )
    }

    private func scalars(_ values: [UInt32]) throws -> [Unicode.Scalar] {
        try values.map { value in
            guard let scalar = Unicode.Scalar(value) else {
                throw CorpusError.invalidScalar(hex(value))
            }
            return scalar
        }
    }

    /// Renders a scalar run as `U+XXXX ...` so a mismatch names the code points, not opaque glyphs.
    private func codePoints(_ scalars: [Unicode.Scalar]) -> String {
        "[" + scalars.map { "U+" + hex($0.value) }.joined(separator: " ") + "]"
    }

    private func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return digits.count >= 4 ? digits : String(repeating: "0", count: 4 - digits.count) + digits
    }

    /// Parses the normalization corpus over raw UTF-8 bytes; the Foundation-bridged
    /// `trimmingCharacters` path cost one bridge per line across 20,095 lines, and every
    /// field in this file is ASCII hex, semicolons, spaces, and `#` comments. Fields are
    /// walked by index rather than `split`, which would allocate a slice array per line.
    /// `offset + 1` is the true file line number: this corpus has no blank lines.
    private func normalizationFixtures() throws -> [(Int, [[Unicode.Scalar]])] {
        let bytes = try corpusBytes(named: "NormalizationTest-17.0.0")
        let lines = bytes.split(separator: asciiNewline, omittingEmptySubsequences: false)
        var fixtures: [(Int, [[Unicode.Scalar]])] = []
        fixtures.reserveCapacity(20_100)
        for (offset, rawLine) in lines.enumerated() {
            let data = trimmingASCIIWhitespace(rawLine.prefix { $0 != asciiHash })
            guard let first = data.first, first != asciiAt else { continue }
            var columns: [[Unicode.Scalar]] = []
            columns.reserveCapacity(5)
            var fieldStart = data.startIndex
            while fieldStart <= data.endIndex, columns.count < 5 {
                var fieldEnd = fieldStart
                while fieldEnd < data.endIndex, data[fieldEnd] != asciiSemicolon {
                    fieldEnd = data.index(after: fieldEnd)
                }
                columns.append(try parseScalarList(data[fieldStart..<fieldEnd], line: offset + 1))
                if fieldEnd == data.endIndex { break }
                fieldStart = data.index(after: fieldEnd)
            }
            guard columns.count == 5 else {
                throw CorpusError.malformedLine(offset + 1)
            }
            fixtures.append((offset + 1, columns))
        }
        return fixtures
    }

    private func caseFoldingFixtures() throws -> [(UInt32, [UInt32])] {
        let text = try corpus(named: "CaseFolding-17.0.0")
        return try text.split(separator: "\n").enumerated().compactMap { offset, rawLine in
            let data = rawLine.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
                .trimmingCharacters(in: .whitespaces)
            guard data.isEmpty == false else { return nil }
            let fields = data.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count >= 3 else { throw CorpusError.malformedLine(offset + 1) }
            guard fields[1] == "C" || fields[1] == "F" else { return nil }
            guard let scalar = UInt32(fields[0], radix: 16) else {
                throw CorpusError.malformedLine(offset + 1)
            }
            return (scalar, try parseScalarList(fields[2]))
        }
    }

    private func corpus(named name: String) throws -> String {
        try String(decoding: corpusBytes(named: name), as: UTF8.self)
    }

    private func corpusBytes(named name: String) throws -> [UInt8] {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "txt",
                subdirectory: "Fixtures/unicode"
            )
        )
        return try [UInt8](Data(contentsOf: url))
    }

    private func parseScalarList(_ text: String) throws -> [UInt32] {
        try text.split(whereSeparator: { $0.isWhitespace }).map { value in
            guard let scalar = UInt32(value, radix: 16) else {
                throw CorpusError.invalidScalar(String(value))
            }
            return scalar
        }
    }

    /// Parses one `;`-delimited field straight into scalars: the sweep needs 100,170 of
    /// these, and a `[UInt32]` staging array per field doubles the allocations for nothing.
    private func parseScalarList(_ field: ArraySlice<UInt8>, line: Int) throws -> [Unicode.Scalar] {
        var values: [Unicode.Scalar] = []
        values.reserveCapacity(4)
        var index = field.startIndex
        while index < field.endIndex {
            guard isASCIIWhitespace(field[index]) == false else {
                index = field.index(after: index)
                continue
            }
            var end = index
            while end < field.endIndex, isASCIIWhitespace(field[end]) == false {
                end = field.index(after: end)
            }
            let token = field[index..<end]
            guard let value = parseHex(token), let scalar = Unicode.Scalar(value) else {
                throw CorpusError.invalidScalar(
                    "corpus line \(line): \(String(decoding: token, as: UTF8.self))"
                )
            }
            values.append(scalar)
            index = end
        }
        return values
    }

    private func parseHex(_ token: ArraySlice<UInt8>) -> UInt32? {
        guard token.isEmpty == false, token.count <= 8 else { return nil }
        var value: UInt32 = 0
        for byte in token {
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41) + 10
            case 0x61...0x66: digit = UInt32(byte - 0x61) + 10
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }

    private func trimmingASCIIWhitespace(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var slice = bytes
        while let first = slice.first, isASCIIWhitespace(first) { slice = slice.dropFirst() }
        while let last = slice.last, isASCIIWhitespace(last) { slice = slice.dropLast() }
        return slice
    }

    private func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D
    }

    private var asciiNewline: UInt8 { 0x0A }
    private var asciiHash: UInt8 { 0x23 }
    private var asciiAt: UInt8 { 0x40 }
    private var asciiSemicolon: UInt8 { 0x3B }

    private enum CorpusError: Error {
        case malformedLine(Int)
        case invalidScalar(String)
    }
}
