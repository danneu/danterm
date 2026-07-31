// Decoder-focused boundary and malformed-input coverage independent of terminal control dispatch.
import Foundation
import Testing

@testable import TerminalCore

/// Pins DanTerm's incremental decoder to modern maximal-subpart recovery over a systematic corpus.
struct UTF8DecoderTests {
    @Test("Kuhn stress cases follow maximal-subpart UTF-8 recovery")
    func kuhnStressCorpus() throws {
        // Intent: exercise every decoder byte class and Unicode boundary selected
        //   from Markus Kuhn's systematic UTF-8 stress corpus.
        // Why it exists: terminal fixtures covered representative failures but
        //   omitted whole lead-byte classes, impossible bytes, and noncharacters.
        // Scenario: arbitrary PTY output contains malformed or unusual UTF-8 and
        //   must recover identically regardless of which invalid class appeared.
        let url = try #require(Bundle.module.url(
            forResource: "utf8-decoder-corpus",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let corpus = try JSONDecoder().decode(
            UTF8DecoderCorpus.self,
            from: Data(contentsOf: url)
        )

        #expect(corpus.version == 1)
        #expect(corpus.provenance.source == "Markus Kuhn UTF-8 decoder capability and stress test")
        #expect(corpus.provenance.version == "2015-08-28")
        #expect(corpus.provenance.sha256 == "b51cfe9a8d2689c90b10a13a3624092d546e0837c6ff835b6e5d713c5749c8c6")
        #expect(corpus.provenance.license == "CC-BY-4.0")
        #expect(corpus.provenance.licenseNotice == "LICENSE.UTF-8-test.txt")
        #expect(Set(corpus.cases.map(\.section)) == ["1", "2", "3.1", "3.2", "3.3-3.4", "3.5", "4", "5.1-5.2", "5.3"])

        for fixture in corpus.cases {
            let bytes = try fixture.hex.split(separator: " ").map { component in
                try #require(UInt8(component, radix: 16), "Invalid hex in \(fixture.name)")
            }
            let decoded = decode(bytes)
            let standardLibrary = String(decoding: bytes, as: UTF8.self)
                .unicodeScalars.map(\.value)

            #expect(decoded == standardLibrary, "Maximal-subpart mismatch in \(fixture.name)")
            #expect(
                decoded.filter { $0 == 0xFFFD }.count == fixture.expectedFFFDCount,
                "Unexpected replacement count in \(fixture.name)"
            )
            #expect(decoded.last == 0x22, "\(fixture.name) did not resynchronize to its quote sentinel")
            if let expectedScalarValues = fixture.expectedScalarValues {
                #expect(decoded == expectedScalarValues, "Boundary mismatch in \(fixture.name)")
            }
        }
    }

    private func decode(_ bytes: [UInt8]) -> [UInt32] {
        var decoder = UTF8Decoder()
        var scalars: [UInt32] = []
        for byte in bytes {
            var result = decoder.next(byte)
            while true {
                if let scalar = result.scalar {
                    scalars.append(scalar.value)
                }
                if result.consumed {
                    break
                }
                result = decoder.next(byte)
            }
        }
        return scalars
    }
}

private struct UTF8DecoderCorpus: Decodable {
    var version: Int
    var provenance: UTF8DecoderCorpusProvenance
    var cases: [UTF8DecoderCorpusCase]
}

private struct UTF8DecoderCorpusProvenance: Decodable {
    var source: String
    var version: String
    var sha256: String
    var license: String
    var licenseNotice: String
}

private struct UTF8DecoderCorpusCase: Decodable {
    var name: String
    var section: String
    var hex: String
    var expectedFFFDCount: Int
    var expectedScalarValues: [UInt32]?
}
