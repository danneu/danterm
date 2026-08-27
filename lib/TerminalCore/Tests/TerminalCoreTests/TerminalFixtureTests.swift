// Runs provenance-bearing neutral terminal fixtures through every feed chunking mode.
import Foundation
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Proves external behavioral cases use only public inspection views and remain chunk-invariant.
struct TerminalFixtureTests {
    @Test(
        "neutral replay fixtures pass every expectation under all feed splits",
        arguments: try TerminalFixtureTests.chunkInvariantFixtureNames()
    )
    func replayFixtures(_ name: String) throws {
        try replayFixture(at: Self.fixtureURL(named: name))
    }

    @Test("the chunk-invariance replay covers every external fixture except the Milestone 8 five")
    func chunkInvariantFixtureInventory() throws {
        // Intent: the argument list `replayFixtures` is parameterized over is exactly the
        //   external corpus minus the five Milestone 8 recordings replayed at authored
        //   chunking by `milestone8ApplicationReplay`.
        // Why it exists: a parameterized test whose arguments come back short runs fewer
        //   cases and still reports green, so the corpus has to be pinned somewhere other
        //   than inside the parameterized test itself. This is that somewhere.
        // Scenario: a fixture directory is renamed, a recording is dropped, or the
        //   Milestone 8 exclusion list drifts away from the files on disk.
        let expected = Set(
            Self.expectedLibvtermRecordings.map { "libvterm/\($0)" }
                + Self.adoptedAlacrittyRecordings
                    .subtracting(Self.milestone8AlacrittyRecordings)
                    .map { "alacritty/\($0)" }
                + ["windows-terminal/osc52-unicode"]
        )
        let names = try Self.chunkInvariantFixtureNames()
        #expect(names.count == 70)
        #expect(Set(names) == expected)
    }

    @Test("the libvterm fixture directory holds exactly the recordings named here")
    func libvtermFixtureInventory() throws {
        // Intent: the checked-in libvterm corpus is exactly this name set -- no fixture
        //   silently disappears, and a new one has to be declared.
        // Why it exists: `replayFixtures` runs whatever is on disk, so a deleted recording
        //   makes it faster rather than red, and `libvtermManifestCoverage` pins upstream
        //   case names rather than fixture files. This is the only thing that fails when a
        //   vttest or state-mouse recording stops existing, which is what the same-shaped
        //   `alacrittyManifestCoverage` fixtureNames check does for the Alacritty corpus.
        // Scenario: the pinned libvterm corpus is regenerated or pruned.
        let names = Set(
            try libvtermFixtureURLs().map { $0.deletingPathExtension().lastPathComponent }
        )
        #expect(names == Self.expectedLibvtermRecordings)
    }

    @Test(
        "Milestone 8 Alacritty application recordings replay at authored chunking",
        arguments: Self.milestone8AlacrittyRecordings
    )
    func milestone8ApplicationReplay(_ name: String) throws {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/alacritty"
        ))
        try replayFixture(at: url)
    }

    @Test("primary-history generation covers every fixture-frame text mutation")
    func primaryHistoryGenerationCoversFixtureFrames() throws {
        // Intent: every primary-history text mutation in the committed recording corpora
        //   advances the cheap generation observed by recovery.
        // Why it exists: history generation is derived from the damage funnel, so a new
        //   mutation path that bypasses damage could otherwise leave recovery stale.
        // Scenario: replay every authored libvterm, Alacritty, and DanTerm frame
        //   and require changed recovery text to remain observable without requiring exact bumps.
        for url in try recordingFixtureURLs() {
            let recording = try JSONDecoder().decode(
                NeutralTerminalRecording.self,
                from: Data(contentsOf: url)
            )
            var terminal = try #require(Terminal(
                columns: recording.initial.columns,
                rows: recording.initial.rows
            ))
            var interactionState = TerminalInteractionState()

            for (eventIndex, event) in recording.events.enumerated() {
                let previousText = terminal.primaryHistoryText
                let previousGeneration = terminal.primaryHistoryGeneration

                switch event {
                case .feed(let bytes):
                    terminal.feed(bytes)
                case .resize(let columns, let rows, _):
                    terminal.resize(columns: columns, rows: rows)
                case .viewport(let navigation):
                    switch navigation {
                    case .byRows(let rows): terminal.scroll(byRows: rows)
                    case .toTopRow(let row): terminal.scroll(toTopRow: row)
                    case .toBottom: terminal.scrollToBottom()
                    }
                case .mouse(let mouse):
                    _ = applyNeutralTerminalMouse(
                        mouse,
                        terminal: &terminal,
                        interactionState: &interactionState
                    )
                case .write, .input, .paste, .focus, .checkpoint:
                    break
                }

                if terminal.primaryHistoryText != previousText {
                    #expect(
                        terminal.primaryHistoryGeneration != previousGeneration,
                        "Missed primary-history generation for \(url.lastPathComponent) event \(eventIndex)"
                    )
                }
            }
        }
    }

    @Test("libvterm manifest classifies every case from the forty-three selected source files")
    func libvtermManifestCoverage() throws {
        // Intent: pin the adoption ledger to every upstream case heading in
        //   the forty-three source files selected through the current engine slices.
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
            "DanTerm retains rows scrolled off the top of a region anchored at row 0 (libvterm's premove rule) but never retains rows vacated by line edits.",
            "DanTerm retains default and indexed colors semantically instead of resolving libvterm palette RGB values.",
            "Pinned libvterm lacks SGR 58/59 and mishandles 38:2::r:g:b; DanTerm deliberately consumes both correctly.",
            "Raw ground-state C1 bytes and UTF-8 encodings beyond U+10FFFF are replaced by U+FFFD using maximal-subpart recovery; decoded C1 scalars are ignored.",
            "DanTerm retains grapheme scalars exactly instead of truncating after five combining marks.",
            "DanTerm follows VT500 string states: C0 is absorbed inside strings and BEL terminates only OSC.",
            "DanTerm emits strict xterm legacy encodings where pinned libvterm emits unsolicited fixterms CSI-u for modified letters, Space, and Tab.",
            "DanTerm reports DECRQM 0 for unsupported UTF-8 1005 and rxvt 1015 mouse encodings instead of libvterm's reset-state 2.",
            "DanTerm emits one complete OSC 52 clipboard write at termination instead of streaming partial selection-set callbacks.",
            "DanTerm rejects invalid OSC 52 base64 without clearing the clipboard.",
            "DanTerm denies OSC 52 read queries without emitting clipboard contents.",
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

    @Test("Milestone 7 closes the remaining protocol fixture classifications")
    func milestone7ProtocolClassifications() throws {
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
        func disposition(_ path: String, _ name: String) -> String? {
            manifest.files.first { $0.path == path }?.cases.first { $0.name == name }?.disposition
        }

        #expect(disposition("t/26state_query.test", "XTVERSION") == "adapted")
        #expect(disposition("t/18state_termprops.test", "Cursor visibility") == "superseded")
        #expect(disposition("t/18state_termprops.test", "Cursor blink") == "superseded")
        #expect(disposition("t/18state_termprops.test", "Cursor shape") == "superseded")
        #expect(disposition("t/18state_termprops.test", "Title") == "adapted")
        #expect(disposition("t/18state_termprops.test", "Title split write") == "adapted")
        #expect(disposition("t/68screen_termprops.test", "Cursor visibility") == "superseded")
        #expect(disposition("t/68screen_termprops.test", "Title") == "superseded")
    }

    @Test("Alacritty manifest classifies the exact pinned recording inventory")
    func alacrittyManifestCoverage() throws {
        // Intent: pin every upstream recording to an explicit milestone disposition and evidence seam.
        // Why it exists: adopted fixtures alone cannot reveal recordings that silently disappear or remain unclassified.
        // Scenario: the pinned Alacritty corpus is refreshed and its ledger must change deliberately with the source tree.
        let url = try #require(Bundle.module.url(
            forResource: "alacritty-manifest",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let manifest = try JSONDecoder().decode(
            AlacrittyManifest.self,
            from: Data(contentsOf: url)
        )

        assertAlacrittyLedger(manifest)

        let adopted = Self.adoptedAlacrittyNames(in: manifest)
        let fixtureNames = Set(try alacrittyFixtureURLs().map { (url: URL) -> String in
            url.deletingPathExtension().lastPathComponent
        })
        #expect(fixtureNames == adopted)
        try assertMilestone8AlacrittyFixtureShape()
    }

    /// The ledger's own consistency: the pin it was cut from, the inventory size, and the
    /// disposition and evidence every recording has to carry.
    private func assertAlacrittyLedger(_ manifest: AlacrittyManifest) {
        let recordings = manifest.recordings
        let taken = Self.alacrittyTakenDispositions
        let known: Set<String> = ["adopted", "adapted", "superseded", "out-of-scope", "pending"]
        let superseded = recordings.filter { $0.disposition == "superseded" }

        #expect(manifest.version == 1)
        #expect(manifest.pinnedCommit == "852e971cddfabe222d2d5bcda466e130f53af207")
        #expect(Set(recordings.map(\.name)) == Self.expectedAlacrittyRecordings)
        #expect(recordings.count == 45)
        #expect(recordings.filter { $0.milestone == 6 && taken.contains($0.disposition) }.count == 15)
        #expect(recordings.filter { $0.milestone == 8 && taken.contains($0.disposition) }.count == 5)
        #expect(recordings.filter { $0.milestone == 7 }.allSatisfy { $0.disposition != "pending" })
        #expect(superseded.count == 23)
        #expect(superseded.allSatisfy { $0.evidence?.isEmpty == false })
        #expect(superseded.allSatisfy { Self.alacrittyEvidence.contains($0.evidence ?? "") })
        #expect(recordings.allSatisfy { entry in
            known.contains(entry.disposition) && entry.rationale.isEmpty == false
        })
    }

    /// The recordings the ledger says milestones 6 and 8 took, which is the set that must have a
    /// fixture on disk.
    private static func adoptedAlacrittyNames(in manifest: AlacrittyManifest) -> Set<String> {
        let taken = Self.alacrittyTakenDispositions
        let milestones: Set<Int> = [6, 8]
        return Set(manifest.recordings.compactMap { entry -> String? in
            guard let milestone = entry.milestone,
                  milestones.contains(milestone),
                  taken.contains(entry.disposition) else {
                return nil
            }
            return entry.name
        })
    }

    /// Milestone 8 adopted its recordings for alternate-screen evidence, so each of those fixtures
    /// has to pin the whole seam rather than a viewport snapshot.
    private func assertMilestone8AlacrittyFixtureShape() throws {
        for url in try alacrittyFixtureURLs()
            where Self.milestone8AlacrittyRecordings.contains(url.deletingPathExtension().lastPathComponent)
        {
            let fixture = try JSONDecoder().decode(ReplayFixture.self, from: Data(contentsOf: url))
            let expectation = try #require(fixture.events.last?.expectation)
            #expect(expectation.viewportText != nil)
            #expect(expectation.cellStyleRuns?.isEmpty == false)
            #expect(expectation.cursor != nil)
            #expect(expectation.cursorPresentation != nil)
            #expect(expectation.scrollbackCount == 0)
            #expect(expectation.primaryHistoryContains?.isEmpty == false)
            #expect(expectation.alternateScreenActive == true)
            #expect(expectation.inputModes != nil)
        }
    }

    @Test("windows-terminal manifest classifies the whole pinned corpus")
    func windowsTerminalManifestCoverage() throws {
        // Intent: pin the ledger's shape -- which files it claims, how many cases each
        //   holds, the disposition vocabulary, and which cases produced a test.
        // Why it exists: this ledger covered three of sixteen files for a month while
        //   nothing recorded that it was partial, because an absent file and a file with
        //   nothing worth taking look identical. The case names live in the manifest and
        //   are checked against the pinned checkout by
        //   scripts/external-corpus-ledger-lint.py; duplicating all 213 here would be a
        //   second copy of the ledger under no maintenance.
        // Scenario: the reference pin or a fixture changes and the adoption ledger must
        //   stay complete, provenance-bearing, and honest about its own scope.
        let url = try #require(Bundle.module.url(
            forResource: "windows-terminal-manifest",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let manifest = try JSONDecoder().decode(
            FixtureManifest.self,
            from: Data(contentsOf: url)
        )

        #expect(manifest.version == 1)
        #expect(manifest.pinnedCommit == "1cea42d433253d95c4487a3037db48197b5e72f4")
        #expect(manifest.recordedDeviations == [
            "DanTerm requires canonical padded Base64 where windows-terminal also accepts omitted padding.",
            "DanTerm supports xterm X10 and SGR mouse encodings, not UTF-8 1005.",
            "DanTerm treats raw C1 bytes as UTF-8 input and does not expose parser states or dispatch callbacks.",
        ])
        #expect(
            Set(manifest.files.map(\.path)) == Set(Self.expectedWindowsTerminalCaseCounts.keys)
        )
        #expect(manifest.files.flatMap(\.cases).count == 213)
        #expect(Set(manifest.files.flatMap(\.cases).filter { $0.disposition == "adopted" }.map(\.name)) == [
            "DecodeUTF8", "TestSetClipboard",
        ])
        // The six adapted cases each became a native test rather than a replay fixture:
        // four assert bytes the terminal sends for a key event, which is the opposite
        // direction from the fixture format, and the other two assert parser stream
        // actions and a DECRQSS reply.
        #expect(Set(manifest.files.flatMap(\.cases).filter { $0.disposition == "adapted" }.map(\.name)) == [
            "KeyPressTests",
            "TerminalInputNullKeyTests",
            "DifferentModifiersTest",
            "DcsDataStringsReceivedByHandler",
            "RequestSettingsTests",
        ])
        for file in manifest.files {
            #expect(file.licenseNotice == "LICENSE.windows-terminal.txt")
            #expect(file.cases.count == Self.expectedWindowsTerminalCaseCounts[file.path])
            #expect(Set(file.cases.map(\.name)).count == file.cases.count)
            #expect(file.cases.allSatisfy { entry in
                [
                    "adopted", "adapted", "superseded", "out-of-scope",
                    "implementation-coupled",
                ].contains(entry.disposition)
                    && entry.rationale.isEmpty == false
            })
        }
    }

    /// The `directory/name` identifiers `replayFixtures` is parameterized over, static because a
    /// `@Test(arguments:)` list is evaluated before any suite instance exists. Names rather than
    /// URLs so a failing case reads as the fixture it replayed; `chunkInvariantFixtureInventory`
    /// pins the result so a short list cannot quietly shrink the corpus.
    private static func chunkInvariantFixtureNames() throws -> [String] {
        guard let resources = Bundle.module.resourceURL else {
            throw FixtureError.missingResourceRoot
        }
        let root = resources.appending(path: "Fixtures", directoryHint: .isDirectory)
        let directories: [String] = ["libvterm", "alacritty", "windows-terminal"]
        var names: [String] = []
        for directory in directories {
            let directoryURL: URL = root.appending(path: directory, directoryHint: .isDirectory)
            let contents: [URL] = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            for url in contents where url.pathExtension == "json" {
                let stem: String = url.deletingPathExtension().lastPathComponent
                if Self.milestone8AlacrittyRecordings.contains(stem) {
                    continue
                }
                names.append("\(directory)/\(stem)")
            }
        }
        return names.sorted()
    }

    private static func fixtureURL(named name: String) throws -> URL {
        let parts = name.split(separator: "/")
        guard parts.count == 2,
              let url = Bundle.module.url(
                  forResource: String(parts[1]),
                  withExtension: "json",
                  subdirectory: "Fixtures/\(parts[0])"
              )
        else {
            throw FixtureError.unknownFixture(name)
        }
        return url
    }

    private func recordingFixtureURLs() throws -> [URL] {
        let root = try #require(Bundle.module.resourceURL)
            .appending(path: "Fixtures", directoryHint: .isDirectory)
        return try ["libvterm", "alacritty", "danterm", "windows-terminal"].flatMap { directory in
            try FileManager.default.contentsOfDirectory(
                at: root.appending(path: directory, directoryHint: .isDirectory),
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
        }
        .sorted { $0.path < $1.path }
    }

    private func libvtermFixtureURLs() throws -> [URL] {
        let root = try #require(Bundle.module.resourceURL)
            .appending(path: "Fixtures/libvterm", directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func alacrittyFixtureURLs() throws -> [URL] {
        let root = try #require(Bundle.module.resourceURL)
            .appending(path: "Fixtures/alacritty", directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func validateProvenance(_ provenance: NeutralTerminalProvenance) throws {
        try provenance.validate()
        #expect(Bundle.module.url(
            forResource: provenance.licenseNotice,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) != nil)
        switch provenance.source {
        case "libvterm":
            #expect(provenance.url?.hasPrefix("https://github.com/neovim/libvterm/") == true)
            #expect(provenance.pinnedCommit == "934bc2fbf21800ac3458a499df8820ca5fb45fd3")
            #expect(provenance.upstreamCase?.isEmpty == false)
            #expect(provenance.license == "MIT")
            #expect(provenance.licenseNotice == "LICENSE.libvterm.txt")
        case "alacritty":
            #expect(provenance.url?.hasPrefix("https://github.com/alacritty/alacritty/") == true)
            #expect(provenance.pinnedCommit == "852e971cddfabe222d2d5bcda466e130f53af207")
            #expect(Self.adoptedAlacrittyRecordings.contains(provenance.upstreamCase ?? ""))
            #expect(provenance.license == "Apache-2.0")
            #expect(provenance.licenseNotice == "LICENSE.alacritty.txt")
        case "windows-terminal":
            #expect(provenance.url?.hasPrefix("https://github.com/microsoft/terminal/") == true)
            #expect(provenance.pinnedCommit == "1cea42d433253d95c4487a3037db48197b5e72f4")
            #expect(
                provenance.upstreamCase
                    == "Base64Test.cpp#DecodeUTF8 and OutputEngineTest.cpp#TestSetClipboard"
            )
            #expect(provenance.license == "MIT")
            #expect(provenance.licenseNotice == "LICENSE.windows-terminal.txt")
        default:
            Issue.record("Unexpected external fixture source: \(provenance.source)")
        }
    }

    private func splitStrategies(for fixture: NeutralTerminalRecording) -> [ChunkStrategy] {
        guard fixture.provenance.source != "alacritty" else { return [] }
        let exhaustiveThreshold = 64
        return fixture.events.enumerated().flatMap { eventIndex, event -> [ChunkStrategy] in
            guard case .feed(let bytes) = event else { return [] }
            let offsets: [Int]
            if fixture.provenance.source == "windows-terminal" || bytes.count <= exhaustiveThreshold {
                offsets = Array(0...bytes.count)
            } else {
                offsets = [0, bytes.count / 4, bytes.count / 2, bytes.count * 3 / 4, bytes.count]
            }
            return offsets.map { .split(event: eventIndex, offset: $0) }
        }
    }

    private static let adoptedAlacrittyRecordings: Set<String> = [
        "alt_reset", "clear_underline", "colored_reset", "colored_underline", "fish_cc",
        "history", "hyperlinks", "saved_cursor", "saved_cursor_alt", "scroll_in_region_up_preserves_history",
        "sgr", "tab_rendering", "tmux_git_log", "tmux_htop", "underline", "vim_24bitcolors_bce",
        "vim_large_window_scroll", "vim_simple_edit", "wrapline_alt_toggle", "zsh_tab_completion",
    ]

    private static let milestone8AlacrittyRecordings = [
        "tmux_git_log", "tmux_htop", "vim_24bitcolors_bce", "vim_large_window_scroll", "vim_simple_edit",
    ]

    private static let expectedLibvtermRecordings: Set<String> = [
        "edit-characters", "edit-lines", "edit-lines-scrollback", "encoding-utf8",
        "erase-scrollback", "flow-hard-boundary", "flow-soft-wrap", "parser-csi",
        "parser-strings", "reflow-narrow-wide", "reflow-shell-prompt", "resize-altscreen",
        "resize-grow-phantom", "resize-height-transfer", "resize-mid-csi", "screen-altscreen",
        "screen-copycell", "screen-damage", "screen-pen", "screen-protect", "screen-unicode",
        "scroll-boundaries", "scroll-controls", "scroll-region-index", "scroll-region-linefeed",
        "scroll-region-up-down", "scroll-up-down", "scrollback-pushline", "state-charset",
        "state-input",
        "state-mode", "state-mouse", "state-mouse-idempotent-1002", "state-movecursor",
        "state-pen", "state-putglyph", "state-query", "state-rep",
        "state-rep-edge", "state-reset", "state-reset-erase", "state-save",
        "state-selection", "state-tabstops", "state-wrapping", "state-wrapping-bottom",
        "vttest-movement-1", "vttest-movement-2", "vttest-movement-3", "vttest-movement-4", "vttest-screen-1",
        "vttest-screen-2", "vttest-screen-3", "vttest-screen-4",
    ]

    /// The two dispositions that mean the recording became a fixture in this tree, as opposed to
    /// being declined or covered elsewhere.
    private static let alacrittyTakenDispositions: Set<String> = ["adopted", "adapted"]

    private static let expectedAlacrittyRecordings: Set<String> = [
        "alt_reset", "clear_underline", "colored_reset", "colored_underline", "csi_rep",
        "decaln_reset", "deccolm_reset", "delete_chars_reset", "delete_lines", "erase_chars_reset",
        "erase_in_line", "fish_cc", "grid_reset", "history", "hyperlinks",
        "indexed_256_colors", "insert_blank_reset", "issue_855", "ll", "newline_with_cursor_beyond_scroll_region",
        "origin_goto", "region_scroll_down", "row_reset", "saved_cursor", "saved_cursor_alt",
        "scroll_in_region_up_preserves_history", "scroll_up_reset", "selective_erasure", "sgr", "tab_rendering",
        "tmux_git_log", "tmux_htop", "underline", "vim_24bitcolors_bce", "vim_large_window_scroll",
        "vim_simple_edit", "vttest_cursor_movement_1", "vttest_insert", "vttest_origin_mode_1", "vttest_origin_mode_2",
        "vttest_scroll", "vttest_tab_clear_set", "wrapline_alt_toggle", "zerowidth", "zsh_tab_completion",
    ]

    /// Per-file case counts for the windows-terminal ledger, which now covers the whole pinned
    /// corpus rather than the three files research doc 26 read. Counts rather than the 213 case
    /// names: the manifest is the ledger, and mirroring its contents here would be a second copy
    /// under no maintenance. `scripts/external-corpus-ledger-lint.py` checks the names against the
    /// pinned checkout, which is the only place the question can actually be answered.
    private static let expectedWindowsTerminalCaseCounts: [String: Int] = [
        "src/terminal/parser/ut_parser/Base64Test.cpp": 2,
        "src/terminal/adapter/ut_adapter/MouseInputTest.cpp": 5,
        "src/terminal/parser/ut_parser/OutputEngineTest.cpp": 64,
        "src/terminal/adapter/ut_adapter/adapterTest.cpp": 53,
        "src/terminal/parser/ut_parser/InputEngineTest.cpp": 25,
        "src/terminal/adapter/ut_adapter/kittyKeyboardProtocol.cpp": 4,
        "src/terminal/adapter/ut_adapter/inputTest.cpp": 9,
        "src/terminal/parser/ut_parser/StateMachineTest.cpp": 7,
        "src/buffer/out/ut_textbuffer/TextAttributeTests.cpp": 7,
        "src/buffer/out/ut_textbuffer/TextColorTests.cpp": 5,
        "src/buffer/out/ut_textbuffer/ReflowTests.cpp": 15,
        "src/types/ut_types/UtilsTests.cpp": 10,
        "src/types/ut_types/CodepointWidthDetectorTests.cpp": 4,
        "src/types/ut_types/UuidTests.cpp": 2,
        "src/buffer/out/ut_textbuffer/UTextAdapterTests.cpp": 1,
    ]

    private static let alacrittyEvidence: Set<String> = [
        "CSICursorMovementTests", "CSIEraseTests", "Fixtures/libvterm/state-movecursor.json", "TerminalEditingTests",
        "TerminalGraphemeTests", "TerminalModeTests", "TerminalRepeatTests", "TerminalResetTests",
        "TerminalScrollRegionTests", "TerminalScrollbackTests", "TerminalStyleTests", "TerminalTabStopTests",
    ]

    private func replayFixture(at url: URL) throws {
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(ReplayFixture.self, from: data)
        let recording = try JSONDecoder().decode(NeutralTerminalRecording.self, from: data)
        try validateProvenance(recording.provenance)

        // Alacritty recordings are replayed at authored chunking only, so there is no second run
        // for their checkpoint vector to be compared against.
        let rechunks = recording.provenance.source != "alacritty"
        let authored = try run(
            recording,
            expectations: fixture.events,
            strategy: .authored,
            recordingCheckpoints: rechunks
        )
        if rechunks {
            let bytewise = try run(
                recording,
                expectations: fixture.events,
                strategy: .bytewise,
                recordingCheckpoints: true
            )
            expectCheckpoints(bytewise.checkpoints, matchAuthored: authored.checkpoints)
            #expect(bytewise.terminal == authored.terminal)
        }

        for strategy in splitStrategies(for: recording) {
            #expect(
                try run(recording, expectations: fixture.events, strategy: strategy).terminal
                    == authored.terminal
            )
        }
    }

    /// Requires a rechunked replay to have passed through the same state as the authored one at
    /// every checkpoint, reporting the first checkpoint that differs and what differs there.
    ///
    /// Spelled out rather than `#expect(a == b)` because Swift Testing renders a failed array
    /// equality by describing both operands, and describing two vectors of whole `Terminal`s
    /// emits hundreds of megabytes of arena bytes -- a failure nobody can read.
    private func expectCheckpoints(
        _ actual: [ReplayCheckpoint],
        matchAuthored expected: [ReplayCheckpoint]
    ) {
        guard actual.count == expected.count else {
            Issue.record(
                "Rechunked replay reached \(actual.count) checkpoints, authored reached \(expected.count)"
            )
            return
        }
        for (rechunked, authored) in zip(actual, expected) where rechunked != authored {
            Issue.record(
                """
                Rechunked replay diverged at the checkpoint after event \(authored.eventIndex): \
                \(rechunked.divergence(from: authored))
                """
            )
            return
        }
    }

    /// Replays `fixture` under one chunking strategy, optionally recording the
    /// checkpoint-by-checkpoint state vector the bytewise run is compared against.
    ///
    /// `recordingCheckpoints` is off by default because retaining and later comparing a whole
    /// `Terminal` per checkpoint measured ~0.4ms in a debug build -- more than the fixture's own
    /// expectation block costs -- so paying it on all ~3,700 split replays would slow the suite
    /// rather than speed it. The two runs that do pay it are one per fixture each.
    private func run(
        _ fixture: NeutralTerminalRecording,
        expectations: [FixtureEvent],
        strategy: ChunkStrategy,
        recordingCheckpoints: Bool = false
    ) throws -> ReplayOutcome {
        var terminal = try #require(Terminal(
            columns: fixture.initial.columns,
            rows: fixture.initial.rows
        ))
        var interactionState = TerminalInteractionState()
        var replyBytes: [UInt8] = []
        var inputBytes: [UInt8] = []
        var clipboardWrites: [String] = []
        var semanticEvents: [TerminalSemanticEvent] = []
        var checkpoints: [ReplayCheckpoint] = []

        func feed(_ bytes: [UInt8]) {
            terminal.feed(bytes)
            replyBytes.append(contentsOf: terminal.drainReplyBytes())
            if let write = terminal.drainPendingClipboardWrite() {
                clipboardWrites.append(write)
            }
            semanticEvents.append(contentsOf: terminal.drainSemanticEvents())
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
            case .write:
                // Bytes a live capture already transmitted toward its child. The arms below
                // assert what this build's encoders produce, which a recorded transfer cannot
                // stand in for, so it drives nothing.
                break
            case .input(let key, let modifiers):
                inputBytes.append(contentsOf: encodeTerminalKey(
                    key,
                    modifiers: modifiers,
                    modes: terminal.inputModes
                ))
            case .paste(let text):
                inputBytes.append(contentsOf: encodeTerminalPaste(text, modes: terminal.inputModes))
            case .focus(let focused):
                inputBytes.append(contentsOf: terminal.setFocused(focused))
            case .mouse(let mouse):
                inputBytes.append(contentsOf: applyNeutralTerminalMouse(
                    mouse,
                    terminal: &terminal,
                    interactionState: &interactionState
                ))
            case .resize(let columns, let rows, _):
                terminal.resize(columns: columns, rows: rows)
            case .viewport(let navigation):
                switch navigation {
                case .byRows(let rows): terminal.scroll(byRows: rows)
                case .toTopRow(let row): terminal.scroll(toTopRow: row)
                case .toBottom: terminal.scrollToBottom()
                }
            case .checkpoint:
                if recordingCheckpoints {
                    checkpoints.append(ReplayCheckpoint(
                        eventIndex: eventIndex,
                        terminal: terminal,
                        replyBytes: replyBytes,
                        inputBytes: inputBytes,
                        clipboardWrites: clipboardWrites,
                        semanticEvents: semanticEvents
                    ))
                }
                try assert(
                    expectations[eventIndex].expectation,
                    against: terminal,
                    replyBytes: replyBytes,
                    inputBytes: inputBytes,
                    clipboardWrites: clipboardWrites,
                    semanticEvents: semanticEvents
                )
                replyBytes.removeAll(keepingCapacity: true)
                inputBytes.removeAll(keepingCapacity: true)
                clipboardWrites.removeAll(keepingCapacity: true)
                semanticEvents.removeAll(keepingCapacity: true)
            }
        }
        return ReplayOutcome(terminal: terminal, checkpoints: checkpoints)
    }

    private func assert(
        _ expectation: FixtureExpectation?,
        against terminal: Terminal,
        replyBytes: [UInt8],
        inputBytes: [UInt8],
        clipboardWrites: [String],
        semanticEvents: [TerminalSemanticEvent]
    ) throws {
        let expectation = try #require(expectation)
        try assertSideChannels(
            expectation,
            replyBytes: replyBytes,
            inputBytes: inputBytes,
            clipboardWrites: clipboardWrites,
            semanticEvents: semanticEvents
        )
        try assertStyling(expectation, against: terminal)
        try assertCellContent(expectation, against: terminal)
        assertText(expectation, against: terminal)
        try assertScreenState(expectation, against: terminal)
    }

    /// The four channels the replay captured outside the grid: what the terminal replied, what it
    /// asked to be typed back, what it wrote to the clipboard, and which semantic events it emitted.
    private func assertSideChannels(
        _ expectation: FixtureExpectation,
        replyBytes: [UInt8],
        inputBytes: [UInt8],
        clipboardWrites: [String],
        semanticEvents: [TerminalSemanticEvent]
    ) throws {
        if let expectedReplyBytes = expectation.replyBytes {
            #expect(replyBytes == expectedReplyBytes)
        }
        if let expectedInputBytes = expectation.inputBytes {
            #expect(inputBytes == expectedInputBytes)
        }
        if let expectedClipboardWrites = expectation.clipboardWrites {
            #expect(clipboardWrites == expectedClipboardWrites)
        }
        if let expectedSemanticEvents = expectation.semanticEvents {
            #expect(semanticEvents == expectedSemanticEvents.map(\.terminalEvent))
        }
    }

    /// Cursor presentation, the pen's current style, and the styles the fixture pins per cell or run.
    private func assertStyling(_ expectation: FixtureExpectation, against terminal: Terminal) throws {
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
        if let runs = expectation.cellStyleRuns {
            for run in runs {
                for column in run.startColumn..<run.endColumn {
                    let cell = try #require(terminal.cell(row: run.row, column: column))
                    let expected = try run.style.terminalStyle()
                    guard cell.style == expected else {
                        throw FixtureError.cellStyleMismatch(
                            row: run.row,
                            column: column,
                            actual: cell.style,
                            expected: expected
                        )
                    }
                }
            }
        }
    }

    /// What the cells hold apart from style: scalars, hyperlinks, kind, and the per-row wrap flag.
    private func assertCellContent(_ expectation: FixtureExpectation, against terminal: Terminal) throws {
        if let cellScalars = expectation.cellScalars {
            for point in cellScalars {
                let cell = try #require(terminal.cell(row: point.row, column: point.column))
                #expect(cell.scalars == TerminalScalars(point.scalars.unicodeScalars))
            }
        }
        if let cellHyperlinks = expectation.cellHyperlinks {
            for point in cellHyperlinks {
                let cell = try #require(terminal.cell(row: point.row, column: point.column))
                #expect(cell.hyperlink?.uri == point.hyperlink?.uri)
                #expect(cell.hyperlink?.explicitId == point.hyperlink?.explicitId)
            }
        }
        if let cellKinds = expectation.cellKinds {
            #expect(terminal.geometry.rows.map { $0.cells.map(\.kind.fixtureName) } == cellKinds)
        }
        if let softWraps = expectation.softWraps {
            #expect(terminal.geometry.rows.map(\.isSoftWrapped) == softWraps)
        }
    }

    /// The rendered text of the viewport and of the history behind it.
    private func assertText(_ expectation: FixtureExpectation, against terminal: Terminal) {
        if let viewportText = expectation.viewportText {
            #expect(terminal.screenText == viewportText)
        }
        if let viewportContains = expectation.viewportContains {
            for fragment in viewportContains {
                #expect(terminal.screenText.contains(fragment))
            }
        }
        if let viewportExcludes = expectation.viewportExcludes {
            for fragment in viewportExcludes {
                #expect(terminal.screenText.contains(fragment) == false)
            }
        }
        if let fullHistoryText = expectation.fullHistoryText {
            #expect(terminal.fullHistoryText == fullHistoryText)
        }
        if let primaryHistoryContains = expectation.primaryHistoryContains {
            for fragment in primaryHistoryContains {
                #expect(terminal.primaryHistoryText.contains(fragment))
            }
        }
    }

    /// Where the cursor sits, what the scrollback holds, and which screen and input modes are active.
    private func assertScreenState(_ expectation: FixtureExpectation, against terminal: Terminal) throws {
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
        if let alternateScreenActive = expectation.alternateScreenActive {
            #expect(terminal.isAlternateScreenActive == alternateScreenActive)
        }
        if let inputModes = expectation.inputModes {
            let expected = try inputModes.terminalModes()
            guard terminal.inputModes == expected else {
                throw FixtureError.inputModesMismatch(actual: terminal.inputModes, expected: expected)
            }
        }
    }

    private static let expectedCases: [String: Set<String>] = [
        "t/62screen_damage.test": [
            "Putglyph",
            "Erase",
            "Scroll damages entire line in two chunks",
            "Scroll down damages entire screen in two chunks",
            "Altscreen damages entire area",
            "Scroll invokes moverect but not damage",
            "Merge to cells",
            "Merge entire rows",
            "Merge entire screen",
            "Merge entire screen with moverect",
            "Merge scroll",
            "Merge scroll with damage",
            "Merge scroll with damage past region",
            "Damage entirely outside scroll region",
            "Damage overlapping scroll region",
            "Merge scroll*2 with damage",
        ],
        "t/17state_mouse.test": [
            "DECRQM on with mouse off",
            "Mouse in simple button report mode",
            "Press 1",
            "Release 1",
            "Ctrl-Press 1",
            "Button 2",
            "Position",
            "Wheel events",
            "DECRQM on mouse button mode",
            "Drag events",
            "DECRQM on mouse drag mode",
            "Non-drag motion events",
            "DECRQM on mouse motion mode",
            "Bounds checking",
            "DECRQM on standard encoding mode",
            "UTF-8 extended encoding mode",
            "DECRQM on UTF-8 extended encoding mode",
            "SGR extended encoding mode",
            "DECRQM on SGR extended encoding mode",
            "rxvt extended encoding mode",
            "DECRQM on rxvt extended encoding mode",
            "Mouse disabled reports nothing",
            "DECSM can set multiple modes at once",
        ],
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
        "t/18state_termprops.test": [
            "Cursor visibility", "Cursor blink", "Cursor shape", "Title", "Title split write",
        ],
        "t/28state_dbl_wh.test": [
            "Single Width, Single Height", "Double Width, Single Height",
            "Double Height", "Double Width scrolling",
        ],
        "t/29state_fallback.test": [
            "Unrecognised control", "Unrecognised CSI", "Unrecognised OSC",
            "Unrecognised DCS", "Unrecognised APC", "Unrecognised PM", "Unrecognised SOS",
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
        "t/40state_selection.test": [
            "Set clipboard; final chunk len 4",
            "Set clipboard; final chunk len 3",
            "Set clipboard; final chunk len 2",
            "Set clipboard; split between chunks",
            "Set clipboard; split within chunk",
            "Set clipboard; empty first chunk",
            "Set clipboard; empty final chunk",
            "Set clipboard; longer than buffer",
            "Clear clipboard",
            "Set invalid data clears and ignores",
            "Query clipboard",
            "Send clipboard; final chunk len 4",
            "Send clipboard; final chunk len 3",
            "Send clipboard; final chunk len 2",
            "Send clipboard; split between chunks",
            "Send clipboard; split within chunk",
        ],
        "t/25state_input.test": [
            "Unmodified ASCII", "Ctrl modifier on ASCII letters",
            "Alt modifier on ASCII letters", "Ctrl-Alt modifier on ASCII letters",
            "Special handling of Ctrl-I", "Special handling of Space",
            "Cursor keys in reset (cursor) mode", "Cursor keys in application mode",
            "Shift-Tab should be different", "Enter in linefeed mode",
            "Enter in newline mode", "Unmodified F1 is SS3 P", "Modified F1 is CSI P",
            "Keypad in DECKPNM", "Keypad in DECKPAM", "Bracketed paste mode off",
            "Bracketed paste mode on", "Focus reporting disabled", "Focus reporting enabled",
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
        "t/65screen_protect.test": ["Selective erase", "Non-selective erase"],
        "t/66screen_extent.test": ["Bold extent"],
        "t/67screen_dbl_wh.test": [
            "Single Width, Single Height", "Double Width, Single Height",
            "Double Height", "Late change", "DWL doesn't spill over on scroll",
        ],
        "t/68screen_termprops.test": ["Cursor visibility", "Title"],
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

/// Everything one replay of a fixture can be judged on: the terminal it ended in, and -- when the
/// run was asked to record them -- the state it passed through at each authored checkpoint.
private struct ReplayOutcome {
    let terminal: Terminal
    let checkpoints: [ReplayCheckpoint]
}

/// The complete observable state of a replay at one authored checkpoint.
///
/// `Terminal` is the whole engine value, so its `Equatable` already covers every public
/// inspection view (grid cells and their kinds, styles and hyperlinks, soft wraps, cursor and
/// pending wrap, retained history content, alternate-screen selection, modes, saved cursor) --
/// there is no cell a fixture expectation could name that two equal `Terminal`s disagree on. The
/// four buffers alongside it are the side channels the terminal emits rather than stores, drained
/// since the previous checkpoint, and are the only replay-visible state `Terminal` itself omits.
///
/// Comparing a vector of these positionally is what makes a divergence that *re-converges*
/// visible: a final-state comparison cannot see one, and re-running the fixture's expectations
/// only sees the aspects that fixture happens to name.
private struct ReplayCheckpoint: Equatable {
    let eventIndex: Int
    let terminal: Terminal
    let replyBytes: [UInt8]
    let inputBytes: [UInt8]
    let clipboardWrites: [String]
    let semanticEvents: [TerminalSemanticEvent]

    /// Names what differs from `other`, preferring the side channels (small and printable) and
    /// falling back to the public terminal projections a reader can act on. The list is a
    /// diagnostic, not the comparison: two checkpoints can be unequal with every line here equal,
    /// which is reported as such rather than silently as "no difference".
    func divergence(from other: Self) -> String {
        if replyBytes != other.replyBytes {
            return "reply bytes \(replyBytes) vs authored \(other.replyBytes)"
        }
        if inputBytes != other.inputBytes {
            return "input bytes \(inputBytes) vs authored \(other.inputBytes)"
        }
        if clipboardWrites != other.clipboardWrites {
            return "clipboard writes \(clipboardWrites) vs authored \(other.clipboardWrites)"
        }
        if semanticEvents != other.semanticEvents {
            return "semantic events \(semanticEvents) vs authored \(other.semanticEvents)"
        }
        var differences: [String] = []
        if terminal.geometry.cursor != other.terminal.geometry.cursor {
            differences.append("cursor \(String(describing: terminal.geometry.cursor)) vs authored \(String(describing: other.terminal.geometry.cursor))")
        }
        if terminal.screenText != other.terminal.screenText {
            differences.append("viewport text differs")
        }
        if terminal.fullHistoryText != other.terminal.fullHistoryText {
            differences.append("history text differs")
        }
        if terminal.scrollbackRowCount != other.terminal.scrollbackRowCount {
            differences.append("scrollback rows \(terminal.scrollbackRowCount) vs authored \(other.terminal.scrollbackRowCount)")
        }
        if terminal.isAlternateScreenActive != other.terminal.isAlternateScreenActive {
            differences.append("alternate screen \(terminal.isAlternateScreenActive) vs authored \(other.terminal.isAlternateScreenActive)")
        }
        if terminal.inputModes != other.terminal.inputModes {
            differences.append("input modes \(terminal.inputModes) vs authored \(other.terminal.inputModes)")
        }
        if terminal.currentStyle != other.terminal.currentStyle {
            differences.append("current style \(terminal.currentStyle) vs authored \(other.terminal.currentStyle)")
        }
        if terminal.presentation != other.terminal.presentation {
            differences.append("cursor presentation \(terminal.presentation) vs authored \(other.terminal.presentation)")
        }
        return differences.isEmpty
            ? "terminal state differs outside the projections named here"
            : differences.joined(separator: "; ")
    }
}

private enum ChunkStrategy {
    case authored
    case bytewise
    case split(event: Int, offset: Int)
}

private enum FixtureError: Error {
    case missingResourceRoot
    case unknownFixture(String)
    case invalidStyleToken(String)
    case invalidCursorShape(String)
    case invalidMouseTrackingMode(String)
    case cellStyleMismatch(row: Int, column: Int, actual: TerminalStyle, expected: TerminalStyle)
    case inputModesMismatch(actual: TerminalInputModes, expected: TerminalInputModes)
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
    let inputBytes: [UInt8]?
    let clipboardWrites: [String]?
    let semanticEvents: [FixtureSemanticEvent]?
    let cursorPresentation: FixtureCursorPresentation?
    let viewportText: String?
    let viewportContains: [String]?
    let viewportExcludes: [String]?
    let cellKinds: [[String]]?
    let softWraps: [Bool]?
    let cursor: FixtureCursor?
    let scrollbackCount: Int?
    let scrollbackRows: [FixtureRow]?
    let fullHistoryText: String?
    let primaryHistoryContains: [String]?
    let alternateScreenActive: Bool?
    let inputModes: FixtureInputModes?
    let currentStyle: FixtureStyle?
    let cellStyles: [FixtureCellStyle]?
    let cellStyleRuns: [FixtureCellStyleRun]?
    let cellScalars: [FixtureCellScalars]?
    let cellHyperlinks: [FixtureCellHyperlink]?
}

private struct FixtureSemanticEvent: Decodable {
    let kind: String
    let value: String?

    var terminalEvent: TerminalSemanticEvent {
        switch kind {
        case "title": .title(value ?? "")
        case "cwd": .workingDirectory(value)
        case "bell": .bell
        default: preconditionFailure("Unknown semantic fixture event: \(kind)")
        }
    }
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

/// Compactly retains complete public cell presentation for large application grids.
private struct FixtureCellStyleRun: Decodable {
    let row: Int
    let startColumn: Int
    let endColumn: Int
    let style: FixtureStyle
}

/// Captures the child-controlled input policy left active by an application recording.
private struct FixtureInputModes: Decodable {
    let applicationCursorKeys: Bool
    let applicationKeypad: Bool
    let lineFeedNewLine: Bool
    let focusReporting: Bool
    let bracketedPaste: Bool
    let mouseTracking: String
    let sgrMouseEncoding: Bool
    let kittyKeyboardFlags: UInt16

    func terminalModes() throws -> TerminalInputModes {
        let tracking: TerminalMouseTrackingMode
        switch mouseTracking {
        case "off": tracking = .off
        case "click": tracking = .click
        case "drag": tracking = .drag
        case "any-motion": tracking = .anyMotion
        default: throw FixtureError.invalidMouseTrackingMode(mouseTracking)
        }
        return TerminalInputModes(
            applicationCursorKeys: applicationCursorKeys,
            applicationKeypad: applicationKeypad,
            lineFeedNewLine: lineFeedNewLine,
            focusReporting: focusReporting,
            bracketedPaste: bracketedPaste,
            mouseTracking: tracking,
            sgrMouseEncoding: sgrMouseEncoding,
            kittyKeyboardFlags: .init(reported: kittyKeyboardFlags)
        )
    }
}

private struct FixtureCellScalars: Decodable {
    let row: Int
    let column: Int
    let scalars: String
}

private struct FixtureCellHyperlink: Decodable {
    let row: Int
    let column: Int
    let hyperlink: FixtureHyperlink?
}

private struct FixtureHyperlink: Decodable {
    let uri: String
    let explicitId: String?
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
        var protected = false
        for attribute in attributes {
            switch attribute {
            case "bold": bold = true
            case "dim": dim = true
            case "italic": italic = true
            case "reverse": reverse = true
            case "hidden": hidden = true
            case "strikethrough": strikethrough = true
            case "protected": protected = true
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
            strikethrough: strikethrough,
            protected: protected
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

private struct AlacrittyManifest: Decodable {
    let version: Int
    let pinnedCommit: String
    let recordings: [AlacrittyManifestRecording]
}

private struct AlacrittyManifestRecording: Decodable {
    let name: String
    let disposition: String
    let milestone: Int?
    let rationale: String
    let evidence: String?
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
