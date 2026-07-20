// Runs provenance-bearing neutral terminal fixtures through every feed chunking mode.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Proves external behavioral cases use only public inspection views and remain chunk-invariant.
struct TerminalFixtureTests {
    @Test("neutral replay fixtures pass every expectation under all feed splits")
    func replayFixtures() throws {
        let urls = try fixtureURLs()
        #expect(urls.isEmpty == false)

        for url in urls {
            let data = try Data(contentsOf: url)
            let fixture = try JSONDecoder().decode(
                ReplayFixture.self,
                from: data
            )
            let recording = try JSONDecoder().decode(
                NeutralTerminalRecording.self,
                from: data
            )
            try validateProvenance(recording.provenance)

            let authored = try run(recording, expectations: fixture.events, strategy: .authored)
            let bytewise = try run(recording, expectations: fixture.events, strategy: .bytewise)
            #expect(bytewise == authored)

            for strategy in splitStrategies(for: recording) {
                #expect(try run(recording, expectations: fixture.events, strategy: strategy) == authored)
            }
        }
    }

    @Test("libvterm manifest classifies every case from the thirty-two selected source files")
    func libvtermManifestCoverage() throws {
        // Intent: pin the adoption ledger to every upstream case heading in
        //   the thirty-two source files selected through the current engine slices.
        // Why it exists: fixtures alone make deferred, superseded, and
        //   deliberately incompatible cases disappear from review.
        // Scenario: the pinned libvterm corpus is upgraded or the neutral
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
        #expect(Set(manifest.recordedDeviations) == [
            "DanTerm clears pending wrap and open grapheme attachment on every recognized valid scroll/edit operation.",
            "DanTerm pushes scrollback only for full-screen upward scrolls; bounded regions and line edits never retain vacated rows.",
            "DanTerm retains default and indexed colors semantically instead of resolving libvterm palette RGB values.",
            "Pinned libvterm lacks SGR 58/59 and mishandles 38:2::r:g:b; DanTerm deliberately consumes both correctly.",
            "Raw ground-state C1 bytes and UTF-8 encodings beyond U+10FFFF are replaced by U+FFFD using maximal-subpart recovery.",
            "DanTerm retains grapheme scalars exactly instead of truncating after five combining marks.",
            "DanTerm follows VT500 string states: C0 is absorbed inside strings and BEL terminates only OSC.",
        ])
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

    private func validateProvenance(_ provenance: NeutralTerminalProvenance) throws {
        try provenance.validate()
        #expect(provenance.source == "libvterm")
        #expect(provenance.url?.hasPrefix("https://github.com/neovim/libvterm/") == true)
        #expect(provenance.pinnedCommit == "934bc2fbf21800ac3458a499df8820ca5fb45fd3")
        #expect(provenance.upstreamCase?.isEmpty == false)
        #expect(provenance.license == "MIT")
        #expect(provenance.licenseNotice == "LICENSE.libvterm.txt")
    }

    private func splitStrategies(for fixture: NeutralTerminalRecording) -> [ChunkStrategy] {
        let exhaustiveThreshold = 64
        return fixture.events.enumerated().flatMap { eventIndex, event -> [ChunkStrategy] in
            guard case .feed(let bytes) = event else { return [] }
            let offsets: [Int]
            if bytes.count <= exhaustiveThreshold {
                offsets = Array(0...bytes.count)
            } else {
                offsets = [0, bytes.count / 4, bytes.count / 2, bytes.count * 3 / 4, bytes.count]
            }
            return offsets.map { .split(event: eventIndex, offset: $0) }
        }
    }

    private func run(
        _ fixture: NeutralTerminalRecording,
        expectations: [FixtureEvent],
        strategy: ChunkStrategy
    ) throws -> Terminal {
        var terminal = try #require(Terminal(
            columns: fixture.initial.columns,
            rows: fixture.initial.rows
        ))
        var replyBytes: [UInt8] = []

        func feed(_ bytes: [UInt8]) {
            terminal.feed(bytes)
            replyBytes.append(contentsOf: terminal.drainReplyBytes())
        }

        for (eventIndex, event) in fixture.events.enumerated() {
            switch event {
            case .feed(let bytes):
                switch strategy {
                case .authored:
                    feed(bytes)
                case .bytewise:
                    for byte in bytes {
                        feed([byte])
                    }
                case let .split(selectedEvent, offset) where selectedEvent == eventIndex:
                    feed(Array(bytes[..<offset]))
                    feed(Array(bytes[offset...]))
                case .split:
                    feed(bytes)
                }
            case .resize(let columns, let rows):
                terminal.resize(columns: columns, rows: rows)
            case .checkpoint:
                try assert(
                    expectations[eventIndex].expectation,
                    against: terminal,
                    replyBytes: replyBytes
                )
                replyBytes.removeAll(keepingCapacity: true)
            }
        }
        return terminal
    }

    private func assert(
        _ expectation: FixtureExpectation?,
        against terminal: Terminal,
        replyBytes: [UInt8]
    ) throws {
        let expectation = try #require(expectation)
        if let expectedReplyBytes = expectation.replyBytes {
            #expect(replyBytes == expectedReplyBytes)
        }
        if let presentation = expectation.cursorPresentation {
            #expect(terminal.presentation.isCursorVisible == presentation.isVisible)
            #expect(terminal.presentation.isCursorBlinking == presentation.isBlinking)
            #expect(terminal.presentation.cursorShape == (try presentation.terminalShape()))
        }
        if let currentStyle = expectation.currentStyle {
            #expect(terminal.currentStyle == (try currentStyle.terminalStyle()))
        }
        if let cellStyles = expectation.cellStyles {
            for point in cellStyles {
                let cell = try #require(terminal.cell(row: point.row, column: point.column))
                #expect(cell.style == (try point.style.terminalStyle()))
            }
        }
        if let cellScalars = expectation.cellScalars {
            for point in cellScalars {
                let cell = try #require(terminal.cell(row: point.row, column: point.column))
                #expect(cell.scalars == Array(point.scalars.unicodeScalars))
            }
        }
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
                for (column, expectedCell) in expectedRow.cells.enumerated() {
                    if let style = expectedCell.style {
                        #expect(actual.cells[column].style == (try style.terminalStyle()))
                    }
                }
            }
        }
        if let fullHistoryText = expectation.fullHistoryText {
            #expect(terminal.fullHistoryText == fullHistoryText)
        }
    }

    private static let expectedCases: [String: Set<String>] = [
        "t/02parser.test": [
            "Basic text",
            "C0",
            "C1 8bit",
            "C1 7bit",
            "High bytes",
            "Mixed",
            "Escape",
            "Escape 2-byte",
            "Split write Escape",
            "Escape cancels Escape, starts another",
            "CAN cancels Escape, returns to normal mode",
            "C0 in Escape interrupts and continues",
            "CSI 0 args",
            "CSI 1 arg",
            "CSI 2 args",
            "CSI 1 arg 1 sub",
            "CSI many digits",
            "CSI leading zero",
            "CSI qmark",
            "CSI greater",
            "CSI SP",
            "Mixed CSI",
            "Split write",
            "Escape cancels CSI, starts Escape",
            "CAN cancels CSI, returns to normal mode",
            "C0 in Escape interrupts and continues",
            "OSC BEL",
            "OSC ST (7bit)",
            "OSC ST (8bit)",
            "OSC in parts",
            "OSC BEL without semicolon",
            "OSC ST without semicolon",
            "Escape cancels OSC, starts Escape",
            "CAN cancels OSC, returns to normal mode",
            "C0 in OSC interrupts and continues",
            "DCS BEL",
            "DCS ST (7bit)",
            "DCS ST (8bit)",
            "Split write of 7bit ST",
            "Escape cancels DCS, starts Escape",
            "CAN cancels DCS, returns to normal mode",
            "C0 in OSC interrupts and continues",
            "APC BEL",
            "APC ST (7bit)",
            "APC ST (8bit)",
            "PM BEL",
            "PM ST (7bit)",
            "PM ST (8bit)",
            "SOS BEL",
            "SOS ST (7bit)",
            "SOS ST (8bit)",
            "SOS can contain any C0 or C1 code",
            "NUL ignored",
            "NUL ignored within CSI",
            "DEL ignored",
            "DEL ignored within CSI",
            "DEL inside text\"",
        ],
        "t/03encoding_utf8.test": [
            "Low", "2 byte", "3 byte", "4 byte", "Early termination",
            "Early restart", "Overlong", "UTF-16 Surrogates", "Split write",
        ],
        "t/10state_putglyph.test": [
            "Low", "UTF-8 1 char", "UTF-8 split writes", "UTF-8 wide char",
            "UTF-8 emoji wide char", "UTF-8 combining chars",
            "Combining across buffers", "Spare combining chars get truncated",
            "DECSCA protected",
        ],
        "t/11state_movecursor.test": [
            "Implicit", "Backspace", "Horizontal Tab", "Carriage Return", "Linefeed",
            "Backspace bounded by lefthand edge", "Backspace cancels phantom",
            "HT bounded by righthand edge", "Index", "Reverse Index", "Newline",
            "Cursor Forward", "Cursor Down", "Cursor Up", "Cursor Backward",
            "Cursor Next Line", "Cursor Previous Line", "Cursor Horizonal Absolute",
            "Cursor Position", "Cursor Position cancels phantom", "Bounds Checking",
            "Horizontal Position Absolute", "Horizontal Position Relative",
            "Horizontal Position Backward", "Horizontal and Vertical Position",
            "Vertical Position Absolute", "Vertical Position Relative",
            "Vertical Position Backward", "Cursor Horizontal Tab", "Cursor Backward Tab",
        ],
        "t/14state_encoding.test": [
            "Default", "Designate G0=UK", "Designate G0=DEC drawing",
            "Designate G1 + LS1", "LS0", "Designate G2 + LS2",
            "Designate G3 + LS3", "SS2", "SS3", "LS1R", "LS2R", "LS3R",
            "Mixed US-ASCII and UTF-8",
        ],
        "t/61screen_unicode.test": [
            "Single width UTF-8", "Wide char", "Combining char",
            "10 combining accents should not crash",
            "40 combining accents in two split writes of 20 should not crash",
            "Outputing CJK doublewidth in 80th column should wraparound to next line and not crash\"",
        ],
        "t/90vttest_01-movement-1.test": ["Output"],
        "t/90vttest_01-movement-2.test": ["Output"],
        "t/90vttest_01-movement-3.test": ["Output"],
        "t/90vttest_01-movement-4.test": ["Output"],
        "t/90vttest_02-screen-1.test": ["Output"],
        "t/90vttest_02-screen-2.test": ["Output"],
        "t/90vttest_02-screen-3.test": ["Output"],
        "t/90vttest_02-screen-4.test": ["Output"],
        "t/92lp1640917.test": [
            "Mouse reporting should not break by idempotent DECSM 1002",
        ],
        "t/15state_mode.test": [
            "Insert/Replace Mode",
            "Insert mode only happens once for UTF-8 combining",
            "Newline/Linefeed mode",
            "DEC origin mode",
            "DECRQM on DECOM",
            "Origin mode with DECSLRM",
            "Origin mode bounds cursor to scrolling region",
            "Origin mode without scroll region",
        ],
        "t/20state_wrapping.test": [
            "79th Column",
            "80th Column Phantom",
            "Line Wraparound",
            "Line Wraparound during combined write",
            "DEC Auto Wrap Mode",
            "80th column causes linefeed on wraparound",
            "80th column phantom linefeed phantom cancelled by explicit cursor move",
        ],
        "t/21state_tabstops.test": [
            "Initial",
            "HTS",
            "TBC 0",
            "TBC 3",
            "Tabstops after resize",
        ],
        "t/22state_save.test": [
            "Set up state",
            "Save",
            "Change state",
            "Restore",
            "Save/restore using DECSC/DECRC",
            "Save twice, restore twice happens on both edge transitions",
        ],
        "t/26state_query.test": [
            "DA",
            "XTVERSION",
            "DSR",
            "CPR",
            "DECCPR",
            "DECRQSS on DECSCUSR",
            "DECRQSS on SGR",
            "DECRQSS on SGR ANSI colours",
            "DECRQSS on SGR ANSI hi-bright colours",
            "DECRQSS on SGR 256-palette colours",
            "DECRQSS on SGR RGB8 colours",
            "S8C1T on DSR",
        ],
        "t/27state_reset.test": [
            "RIS homes cursor",
            "RIS cancels scrolling region",
            "RIS erases screen",
            "RIS clears tabstops",
        ],
        "t/12state_scroll.test": [
            "Linefeed",
            "Index",
            "Reverse Index",
            "Linefeed in DECSTBM",
            "Linefeed outside DECSTBM",
            "Index in DECSTBM",
            "Reverse Index in DECSTBM",
            "Linefeed in DECSTBM+DECSLRM",
            "IND/RI in DECSTBM+DECSLRM",
            "DECRQSS on DECSTBM",
            "DECRQSS on DECSLRM",
            "Setting invalid DECSLRM with !DECVSSM is still rejected",
            "Scroll Down",
            "Scroll Up",
            "SD/SU in DECSTBM",
            "SD/SU in DECSTBM+DECSLRM",
            "Invalid boundaries",
            "Scroll Down move+erase emulation",
            "Scroll Up move+erase emulation",
            "DECSTBM resets cursor position",
        ],
        "t/13state_edit.test": [
            "ICH",
            "ICH with DECSLRM",
            "ICH outside DECSLRM",
            "DCH",
            "DCH with DECSLRM",
            "DCH outside DECSLRM",
            "ECH",
            "IL",
            "IL with DECSTBM",
            "IL outside DECSTBM",
            "IL with DECSTBM+DECSLRM",
            "DL",
            "DL with DECSTBM",
            "DL outside DECSTBM",
            "DL with DECSTBM+DECSLRM",
            "DECIC",
            "DECIC with DECSTBM+DECSLRM",
            "DECIC outside DECSLRM",
            "DECDC",
            "DECDC with DECSTBM+DECSLRM",
            "DECDC outside DECSLRM",
            "EL 0",
            "EL 1",
            "EL 2",
            "SEL",
            "ED 0",
            "ED 1",
            "ED 2",
            "ED 3",
            "SED",
            "DECRQSS on DECSCA",
            "ICH move+erase emuation",
            "DCH move+erase emulation",
        ],
        "t/16state_resize.test": [
            "Placement",
            "Resize",
            "Resize without reset",
            "Resize shrink moves cursor",
            "Resize grow doesn't cancel phantom",
        ],
        "t/30state_pen.test": [
            "Reset",
            "Bold",
            "Underline",
            "Italic",
            "Blink",
            "Reverse",
            "Font Selection",
            "Foreground",
            "Background",
            "Bold+ANSI colour == highbright",
            "Super/Subscript",
            "DECSTR resets pen attributes",
        ],
        "t/31state_rep.test": [
            "REP no argument",
            "REP zero (zero should be interpreted as one)",
            "REP lowercase a times two",
            "REP with UTF-8 1 char",
            "REP with UTF-8 wide char",
            "REP with UTF-8 combining character",
            "REP till end of line",
        ],
        "t/32state_flow.test": [
            "Spillover text marks continuation on second line",
            "CRLF in column 80 does not mark continuation",
            "EL cancels continuation of following line",
        ],
        "t/60screen_ascii.test": [
            "Get",
            "Erase",
            "Copycell",
            "Space padding",
            "Linefeed padding",
            "Altscreen",
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
        "t/64screen_pen.test": [
            "Plain",
            "Bold",
            "Italic",
            "Underline",
            "Reset",
            "Font",
            "Foreground",
            "Background",
            "Super/subscript",
            "EL sets only colours to end of line, not other attrs",
            "DECSCNM xors reverse for entire screen",
            "Set default colours",
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
    case invalidStyleToken(String)
    case invalidCursorShape(String)
}

private struct ReplayFixture: Decodable {
    let events: [FixtureEvent]
}

private struct FixtureEvent: Decodable {
    let expectation: FixtureExpectation?

    private enum CodingKeys: String, CodingKey {
        case expectation = "expect"
    }
}

private struct FixtureExpectation: Decodable {
    let replyBytes: [UInt8]?
    let cursorPresentation: FixtureCursorPresentation?
    let viewportText: String?
    let cellKinds: [[String]]?
    let softWraps: [Bool]?
    let cursor: FixtureCursor?
    let scrollbackCount: Int?
    let scrollbackRows: [FixtureRow]?
    let fullHistoryText: String?
    let currentStyle: FixtureStyle?
    let cellStyles: [FixtureCellStyle]?
    let cellScalars: [FixtureCellScalars]?
}

/// Keeps cursor appearance expectations renderer-independent and source-neutral.
private struct FixtureCursorPresentation: Decodable {
    let isVisible: Bool
    let shape: String
    let isBlinking: Bool

    func terminalShape() throws -> TerminalCursorShape {
        switch shape {
        case "block": .block
        case "underline": .underline
        case "bar": .bar
        default: throw FixtureError.invalidCursorShape(shape)
        }
    }
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
    let style: FixtureStyle?
}

private struct FixtureCellStyle: Decodable {
    let row: Int
    let column: Int
    let style: FixtureStyle
}

private struct FixtureCellScalars: Decodable {
    let row: Int
    let column: Int
    let scalars: String
}

private struct FixtureStyle: Decodable {
    let foreground: String
    let background: String
    let attributes: [String]
    let underline: String

    func terminalStyle() throws -> TerminalStyle {
        var bold = false
        var dim = false
        var italic = false
        var reverse = false
        var hidden = false
        var strikethrough = false
        for attribute in attributes {
            switch attribute {
            case "bold": bold = true
            case "dim": dim = true
            case "italic": italic = true
            case "reverse": reverse = true
            case "hidden": hidden = true
            case "strikethrough": strikethrough = true
            default: throw FixtureError.invalidStyleToken(attribute)
            }
        }

        let underlineStyle: TerminalUnderlineStyle
        switch underline {
        case "none": underlineStyle = .none
        case "single": underlineStyle = .single
        case "double": underlineStyle = .double
        case "curly": underlineStyle = .curly
        default: throw FixtureError.invalidStyleToken(underline)
        }

        return try TerminalStyle(
            foreground: Self.color(from: foreground),
            background: Self.color(from: background),
            bold: bold,
            dim: dim,
            italic: italic,
            underline: underlineStyle,
            reverse: reverse,
            hidden: hidden,
            strikethrough: strikethrough
        )
    }

    private static func color(from token: String) throws -> TerminalColor {
        if token == "default" {
            return .default
        }
        if token.hasPrefix("indexed:"),
           let index = UInt8(token.dropFirst("indexed:".count))
        {
            return .indexed(index)
        }
        if token.hasPrefix("rgb:") {
            let components = token.dropFirst("rgb:".count).split(separator: ",")
            if components.count == 3,
               let red = UInt8(components[0]),
               let green = UInt8(components[1]),
               let blue = UInt8(components[2])
            {
                return .rgb(red: red, green: green, blue: blue)
            }
        }
        throw FixtureError.invalidStyleToken(token)
    }
}

private struct FixtureManifest: Decodable {
    let version: Int
    let pinnedCommit: String
    let recordedDeviations: [String]
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
