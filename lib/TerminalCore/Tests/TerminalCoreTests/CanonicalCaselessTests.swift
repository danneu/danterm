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
        for (line, columns) in try normalizationFixtures() {
            let c1 = try scalars(columns[0])
            let c2 = try scalars(columns[1])
            let c3 = try scalars(columns[2])
            let c4 = try scalars(columns[3])
            let c5 = try scalars(columns[4])
            #expect(canonicalDecomposition(of: c1) == c3, "corpus line \(line), c1")
            #expect(canonicalDecomposition(of: c2) == c3, "corpus line \(line), c2")
            #expect(canonicalDecomposition(of: c3) == c3, "corpus line \(line), c3")
            #expect(canonicalDecomposition(of: c4) == c5, "corpus line \(line), c4")
            #expect(canonicalDecomposition(of: c5) == c5, "corpus line \(line), c5")
        }
    }

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
                fullCaseFold(of: scalar) == expected,
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

    private func scalars(_ values: [UInt32]) throws -> [Unicode.Scalar] {
        try values.map { try #require(Unicode.Scalar($0)) }
    }

    private func normalizationFixtures() throws -> [(Int, [[UInt32]])] {
        let text = try corpus(named: "NormalizationTest-17.0.0")
        return try text.split(separator: "\n").enumerated().compactMap { offset, rawLine in
            let data = rawLine.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
                .trimmingCharacters(in: .whitespaces)
            guard data.isEmpty == false, data.hasPrefix("@") == false else { return nil }
            let columns = try data.split(separator: ";").prefix(5).map {
                try parseScalarList(String($0))
            }
            guard columns.count == 5 else {
                throw CorpusError.malformedLine(offset + 1)
            }
            return (offset + 1, columns)
        }
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
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "txt",
                subdirectory: "Fixtures/unicode"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parseScalarList(_ text: String) throws -> [UInt32] {
        try text.split(whereSeparator: { $0.isWhitespace }).map { value in
            guard let scalar = UInt32(value, radix: 16) else {
                throw CorpusError.invalidScalar(String(value))
            }
            return scalar
        }
    }

    private enum CorpusError: Error {
        case malformedLine(Int)
        case invalidScalar(String)
    }
}
