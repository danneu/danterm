// Runs provenance-bearing neutral terminal fixtures through every feed chunking mode.
import Foundation
import Testing

@testable import TerminalCore

/// Proves external behavioral cases use only public inspection views and remain chunk-invariant.
struct TerminalFixtureTests {
    @Test("neutral replay fixtures pass every expectation under all feed splits")
    func replayFixtures() throws {
        let urls = try fixtureURLs()
        #expect(urls.isEmpty == false)

        for url in urls {
            let fixture = try JSONDecoder().decode(
                ReplayFixture.self,
                from: Data(contentsOf: url)
            )
            try validateProvenance(fixture.provenance)

            let authored = try run(fixture, strategy: .authored)
            let bytewise = try run(fixture, strategy: .bytewise)
            #expect(bytewise == authored)

            for strategy in splitStrategies(for: fixture) {
                #expect(try run(fixture, strategy: strategy) == authored)
            }
        }
    }

    @Test("libvterm manifest classifies every case from the five resize and flow files")
    func libvtermManifestCoverage() throws {
        // Intent: pin the adoption ledger to every upstream case heading in
        //   the five source files selected for this scrollback/resize slice.
        // Why it exists: fixtures alone make deferred, superseded, and
        //   deliberately incompatible cases disappear from review.
        // Scenario: the pinned libvterm corpus is upgraded or the phase B
        //   fixture set grows without losing an explicit disposition.
        let url = try #require(
            Bundle.module.url(
                forResource: "libvterm-manifest",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self,
            from: Data(contentsOf: url)
        )

        #expect(manifest.version == 1)
        #expect(manifest.pinnedCommit == "934bc2fbf21800ac3458a499df8820ca5fb45fd3")
        #expect(Set(manifest.files.map(\.path)) == Set(Self.expectedCases.keys))
        for file in manifest.files {
            #expect(file.licenseNotice == "LICENSE.libvterm.txt")
            #expect(Set(file.cases.map(\.name)) == Self.expectedCases[file.path])
            #expect(file.cases.allSatisfy { entry in
                ["adopted", "adapted", "superseded", "out-of-scope"].contains(entry.disposition)
                    && entry.rationale.isEmpty == false
            })
        }
    }

    private func fixtureURLs() throws -> [URL] {
        let root = try #require(Bundle.module.resourceURL)
            .appending(path: "Fixtures/libvterm", directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func validateProvenance(_ provenance: FixtureProvenance) throws {
        #expect(provenance.source == "libvterm")
        #expect(provenance.url.hasPrefix("https://github.com/neovim/libvterm/"))
        #expect(provenance.pinnedCommit == "934bc2fbf21800ac3458a499df8820ca5fb45fd3")
        #expect(provenance.upstreamCase.isEmpty == false)
        #expect(provenance.license == "MIT")
        #expect(provenance.licenseNotice == "LICENSE.libvterm.txt")
    }

    private func splitStrategies(for fixture: ReplayFixture) -> [ChunkStrategy] {
        let exhaustiveThreshold = 64
        return fixture.events.enumerated().flatMap { eventIndex, event -> [ChunkStrategy] in
            guard event.type == "feed", let bytes = try? event.feedBytes() else { return [] }
            let offsets: [Int]
            if bytes.count <= exhaustiveThreshold {
                offsets = Array(0...bytes.count)
            } else {
                offsets = [0, bytes.count / 4, bytes.count / 2, bytes.count * 3 / 4, bytes.count]
            }
            return offsets.map { .split(event: eventIndex, offset: $0) }
        }
    }

    private func run(_ fixture: ReplayFixture, strategy: ChunkStrategy) throws -> Terminal {
        #expect(fixture.version == 1)
        var terminal = try #require(Terminal(
            columns: fixture.initial.columns,
            rows: fixture.initial.rows
        ))

        for (eventIndex, event) in fixture.events.enumerated() {
            switch event.type {
            case "feed":
                let bytes = try event.feedBytes()
                switch strategy {
                case .authored:
                    terminal.feed(bytes)
                case .bytewise:
                    for byte in bytes {
                        terminal.feed([byte])
                    }
                case let .split(selectedEvent, offset) where selectedEvent == eventIndex:
                    terminal.feed(Array(bytes[..<offset]))
                    terminal.feed(Array(bytes[offset...]))
                case .split:
                    terminal.feed(bytes)
                }
            case "resize":
                terminal.resize(
                    columns: try #require(event.columns),
                    rows: try #require(event.rows)
                )
            case "expect":
                try assert(event.expectation, against: terminal)
            default:
                throw FixtureError.unsupportedEvent(event.type)
            }
        }
        return terminal
    }

    private func assert(_ expectation: FixtureExpectation?, against terminal: Terminal) throws {
        let expectation = try #require(expectation)
        if let viewportText = expectation.viewportText {
            #expect(terminal.screenText == viewportText)
        }
        if let cellKinds = expectation.cellKinds {
            #expect(terminal.geometry.rows.map { $0.cells.map(\.kind.fixtureName) } == cellKinds)
        }
        if let softWraps = expectation.softWraps {
            #expect(terminal.geometry.rows.map(\.isSoftWrapped) == softWraps)
        }
        if let cursor = expectation.cursor {
            #expect(terminal.geometry.cursor == TerminalCursor(
                row: cursor.row,
                column: cursor.column,
                isPendingWrap: cursor.pendingWrap
            ))
        }
        if let scrollbackCount = expectation.scrollbackCount {
            #expect(terminal.scrollbackRowCount == scrollbackCount)
        }
        if let rows = expectation.scrollbackRows {
            #expect(terminal.scrollbackRowCount == rows.count)
            for (index, expectedRow) in rows.enumerated() {
                let actual = try #require(terminal.scrollbackRow(at: index))
                #expect(actual.isSoftWrapped == expectedRow.softWrapped)
                #expect(actual.cells.map(\.kind.fixtureName) == expectedRow.cells.map(\.kind))
                #expect(actual.cells.map { cell in
                    var text = ""
                    text.unicodeScalars.append(contentsOf: cell.scalars)
                    return text
                } == expectedRow.cells.map(\.scalars))
            }
        }
        if let fullHistoryText = expectation.fullHistoryText {
            #expect(terminal.fullHistoryText == fullHistoryText)
        }
    }

    private static let expectedCases: [String: Set<String>] = [
        "t/16state_resize.test": [
            "Placement",
            "Resize",
            "Resize without reset",
            "Resize shrink moves cursor",
            "Resize grow doesn't cancel phantom",
        ],
        "t/32state_flow.test": [
            "Spillover text marks continuation on second line",
            "CRLF in column 80 does not mark continuation",
            "EL cancels continuation of following line",
        ],
        "t/63screen_resize.test": [
            "Resize wider preserves cells",
            "Resize wider allows print in new area",
            "Resize shorter with blanks just truncates",
            "Resize shorter with content must scroll",
            "Resize shorter does not lose line with cursor",
            "Resize shorter does not send the cursor to a negative row",
            "Resize taller attempts to pop scrollback",
            "Resize can operate on altscreen",
        ],
        "t/69screen_pushline.test": [
            "Spillover text marks continuation on second line",
            "Continuation mark sent to sb_pushline",
        ],
        "t/69screen_reflow.test": [
            "Resize wider reflows wide lines",
            "Resize narrower can create continuation lines",
            "Shell wrapped prompt behaviour",
            "Cursor goes missing",
        ],
    ]
}

private enum ChunkStrategy {
    case authored
    case bytewise
    case split(event: Int, offset: Int)
}

private enum FixtureError: Error {
    case invalidHex(String)
    case unsupportedEvent(String)
}

private struct ReplayFixture: Decodable {
    let version: Int
    let provenance: FixtureProvenance
    let initial: FixtureDimensions
    let events: [FixtureEvent]
}

private struct FixtureProvenance: Decodable {
    let source: String
    let url: String
    let pinnedCommit: String
    let upstreamCase: String
    let license: String
    let licenseNotice: String
    let recordedDeviations: [String]
}

private struct FixtureDimensions: Decodable {
    let columns: Int
    let rows: Int
}

private struct FixtureEvent: Decodable {
    let type: String
    let text: String?
    let hex: String?
    let columns: Int?
    let rows: Int?
    let expectation: FixtureExpectation?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case hex
        case columns
        case rows
        case expectation = "expect"
    }

    func feedBytes() throws -> [UInt8] {
        if let text {
            guard hex == nil else { throw FixtureError.invalidHex(hex ?? "") }
            return Array(text.utf8)
        }
        guard let hex else { throw FixtureError.invalidHex("") }
        let compact = hex.filter { $0.isWhitespace == false }
        guard compact.count.isMultiple(of: 2) else { throw FixtureError.invalidHex(hex) }
        return try stride(from: 0, to: compact.count, by: 2).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: 2)
            guard let byte = UInt8(compact[start..<end], radix: 16) else {
                throw FixtureError.invalidHex(hex)
            }
            return byte
        }
    }
}

private struct FixtureExpectation: Decodable {
    let viewportText: String?
    let cellKinds: [[String]]?
    let softWraps: [Bool]?
    let cursor: FixtureCursor?
    let scrollbackCount: Int?
    let scrollbackRows: [FixtureRow]?
    let fullHistoryText: String?
}

private struct FixtureCursor: Decodable {
    let row: Int
    let column: Int
    let pendingWrap: Bool
}

private struct FixtureRow: Decodable {
    let softWrapped: Bool
    let cells: [FixtureCell]
}

private struct FixtureCell: Decodable {
    let kind: String
    let scalars: String
}

private struct FixtureManifest: Decodable {
    let version: Int
    let pinnedCommit: String
    let files: [ManifestFile]
}

private struct ManifestFile: Decodable {
    let path: String
    let licenseNotice: String
    let cases: [ManifestCase]
}

private struct ManifestCase: Decodable {
    let name: String
    let disposition: String
    let rationale: String
}

private extension TerminalCellKind {
    var fixtureName: String {
        switch self {
        case .padding: "padding"
        case .narrow: "narrow"
        case .wideHead: "wide-head"
        case .wideTail: "wide-tail"
        case .spacerHead: "spacer-head"
        }
    }
}
