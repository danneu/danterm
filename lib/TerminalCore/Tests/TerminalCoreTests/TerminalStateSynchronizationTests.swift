// Round-trip proofs for terminal state serialized as terminal-protocol bytes.

import Testing
@testable import TerminalCore

/// Proves that a reset terminal can resume from one complete engine state fence.
struct TerminalStateSynchronizationTests {
    @Test("state bytes reconstruct retained and active terminal state")
    func reconstructsTerminalState() throws {
        // Intent: preserve the complete observable primary state and control modes.
        // Why it exists: a late tape reader cannot rely on later repaint traffic to restore history or input modes.
        // Scenario: a styled shell transcript leaves history, links, modes, margins, tabs, and a saved cursor.
        var source = try #require(Terminal(columns: 8, rows: 3))
        source.feed(Array("one\r\ntwo\r\nthree\r\nfour".utf8))
        source.feed(Array("\u{1B}[2;3H\u{1B}[1;3;4:3;38;2;9;8;7;48;5;17;58;5;33m".utf8))
        source.feed(Array("\u{1B}]8;id=sync;https://example.test/path\u{7}界x\u{1B}]8;;\u{7}".utf8))
        source.feed(Array("\u{1B}[?1;6;7;25;1004;1006;2004h\u{1B}[4h\u{1B}[3;3r".utf8))
        source.feed(Array("\u{1B}[2 q\u{1B}[?2026h\u{1B}[2;5H\u{1B}7".utf8))
        source.feed(Array("\u{1B}[3g\u{1B}[1;4H\u{1B}H\u{1B}[1;1H".utf8))
        source.feed(Array("\u{1B}]8;id=pen;https://pen.test\u{7}".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(Array("stale1\r\nstale2\r\nstale3\r\nstale4".utf8))
        resumed.feed(synchronization.bytes)

        expectObservableState(resumed, equals: source, phase: "initial")

        let continuation = Array("\u{1B}8Z\r\tT".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        expectObservableState(resumed, equals: source, phase: "continued")
    }

    @Test("state bytes retain primary state beneath an active alternate screen")
    func reconstructsActiveAlternateScreen() throws {
        // Intent: carry the active alternate grid and the primary state retained below it.
        // Why it exists: leaving a reconstructed full-screen program must reveal the real shell transcript.
        // Scenario: a shell has history before an alternate-screen program draws styled wide text.
        var source = try #require(Terminal(columns: 6, rows: 2))
        source.feed(Array("old1\r\nold2\r\nshell".utf8))
        source.feed(Array("\u{1B}[?1049h\u{1B}[?1h\u{1B}[31mALT界".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "alternate")

        source.feed(Array("\u{1B}[?1049l".utf8))
        resumed.feed(Array("\u{1B}[?1049l".utf8))
        expectObservableState(resumed, equals: source, phase: "primary")
    }

    @Test("state bytes round-trip a style carrying every attribute and RGB color")
    func reconstructsFullyLoadedStyle() throws {
        // Intent: the worst-case style the writer can emit survives its own round trip.
        // Why it exists: that sequence spends exactly the parser's 24-parameter budget, so
        //   the resync sits on the overflow boundary and must stay on the safe side of it.
        // Scenario: a cell and the live pen both carry every attribute plus an RGB
        //   foreground, background, and underline color.
        var source = try #require(Terminal(columns: 4, rows: 1))
        source.feed(Array("\u{1B}[1\"q\u{1B}[1;2;3;4:3;7;8;9;38;2;1;2;3;48;2;4;5;6;58;2;7;8;9mx".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)

        expectObservableState(resumed, equals: source, phase: "fully loaded style")
    }

    @Test("state bytes preserve DECSCA protection on cells, the pen, and the saved pen")
    func reconstructsCharacterProtection() throws {
        // Intent: protected cells in the viewport and in history, a protected live pen, and a
        //   protected saved pen all survive the round trip.
        // Why it exists: the writer's leading SGR 0 no longer clears protection, so every
        //   style run has to state it -- a run that inherited it would replicate the wrong
        //   cells the moment a resync landed mid-stream.
        // Scenario: a replica resumes a form-drawing program that protects its field labels.
        var source = try #require(Terminal(columns: 4, rows: 2))
        source.feed(Array("\u{1B}[1\"qP\u{1B}[0\"qq\r\n".utf8))
        source.feed(Array("x\r\n".utf8))
        #expect(source.scrollbackRowCount == 1)
        #expect(source.scrollbackRow(at: 0)?.cells[0].style.protected == true)
        source.feed(Array("\u{1B}[1\"q\u{1B}[31mR\u{1B}7\u{1B}[0\"q\u{1B}[msT".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)

        expectObservableState(resumed, equals: source, phase: "protection")

        // The saved pen is only observable through a restore, so both terminals restore it and
        // print with what came back.
        let continuation = Array("\u{1B}8Z".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        #expect(source.currentStyle.protected)
        expectObservableState(resumed, equals: source, phase: "protection restored")
    }

    @Test("state bytes preserve live hyperlinks at the shared metadata cap")
    func reconstructsHyperlinkMetadataCap() throws {
        // Intent: replay the same surviving link set when admission has no metadata space left.
        // Why it exists: a different replay order can accept a target that the source rejected.
        // Scenario: four live maximum-size links fill the cap before a fifth open is attempted.
        var source = try #require(Terminal(columns: 4, rows: 1))
        let target = String(repeating: "h", count: 65_527)
        for index in 0..<4 {
            source.feed(Array("\u{1B}]8;id=\(index);https://\(target)\u{7}x".utf8))
        }
        #expect(source.retainedTerminalMetadataBytes == Terminal.maximumTerminalMetadataBytes)

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "metadata cap")

        let continuation = Array("\u{1B}[H\u{1B}]8;id=overflow;https://overflow.test\u{7}y".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        expectObservableState(resumed, equals: source, phase: "metadata rejection")
    }

    @Test("state bytes preserve shell-owned prompt behavior", arguments: ["0", "1", "last"])
    func reconstructsShellPromptState(redraw: String) throws {
        // Intent: preserve shell integration ownership across later geometry changes.
        // Why it exists: prompt marks control which cells a shell promises to repaint after resize.
        // Scenario: a marked prompt is active when the reader joins, then both terminals resize.
        var source = try #require(Terminal(columns: 8, rows: 3))
        source.feed(Array(
            "output\r\n\u{1B}]133;A;redraw=\(redraw)\u{7}$ \r\n"
                .appending("\u{1B}]133;P;k=c\u{7}> \u{1B}]133;B\u{7}command")
                .utf8
        ))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "prompt \(redraw)")

        source.resize(columns: 10, rows: 3)
        resumed.resize(columns: 10, rows: 3)
        expectObservableState(resumed, equals: source, phase: "prompt resize \(redraw)")
    }

    @Test("state bytes preserve vacated prompt ownership")
    func reconstructsVacatedPromptRows() throws {
        // Intent: retain blank prompt rows that the shell still owns after a redraw resize.
        // Why it exists: cell contents cannot distinguish a vacated prompt from ordinary padding.
        // Scenario: a full-redraw prompt is vacated, synchronized, and later reclaimed by a new head.
        var source = try #require(Terminal(columns: 8, rows: 3))
        source.feed(Array("output\r\n\u{1B}]133;A;redraw=1\u{7}$ prompt".utf8))
        source.resize(columns: 10, rows: 3)
        #expect(source.semanticPromptRowsForTesting.contains { $0.stamp == .vacated })

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "vacated prompt")

        let continuation = Array("\r\n\u{1B}]133;A;redraw=1\u{7}$ next".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        expectObservableState(resumed, equals: source, phase: "reclaimed prompt")
    }

    @Test("state bytes preserve pending autowrap")
    func reconstructsPendingAutowrap() throws {
        // Intent: retain the cursor boundary after printing exactly through the right margin.
        // Why it exists: the next printable byte must wrap only when the source would wrap it.
        // Scenario: the fence lands after the margin cell and before the next printable byte.
        var source = try #require(Terminal(columns: 4, rows: 2))
        source.feed(Array("abcX".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "pending wrap")

        source.feed(Array("Y".utf8))
        resumed.feed(Array("Y".utf8))
        expectObservableState(resumed, equals: source, phase: "wrapped")
    }

    @Test("state bytes preserve a stale wrap claim")
    func reconstructsStaleWrapClaim() throws {
        // Intent: retain the raw wrap transient that line-structure readers deliberately gate.
        // Why it exists: an erased margin cell cannot reveal the printer's surviving wrap claim.
        // Scenario: EL 0 erases the margin after the following character witnessed a soft wrap.
        var source = try #require(Terminal(columns: 10, rows: 3))
        source.feed(Array("AAAAAAAAAABB\u{1B}[H\u{1B}[2Kcccc".utf8))
        #expect(source.rowStructure[0].staleWrapClaim)

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "stale wrap")
    }

    @Test("state bytes preserve the last printed cluster after its cell is erased")
    func reconstructsRepeatMemory() throws {
        // Intent: retain REP's source independently from the cells that still remain on screen.
        // Why it exists: a reset reader cannot infer an erased last cluster from the rebuilt grid.
        // Scenario: the fence follows ED 2, then later traffic repeats the erased cluster.
        var source = try #require(Terminal(columns: 4, rows: 1))
        source.feed(Array("A\u{1B}[2J".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)

        let continuation = Array("\u{1B}[2G\u{1B}[b".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        expectObservableState(resumed, equals: source, phase: "repeat")
    }

    @Test("state bytes preserve an open grapheme cluster")
    func reconstructsOpenGraphemeCluster() throws {
        // Intent: retain the target and segmentation state for a following joining scalar.
        // Why it exists: cursor restoration clears the printer's open-cluster context.
        // Scenario: the fence lands after a base scalar and before its combining mark.
        var source = try #require(Terminal(columns: 4, rows: 1))
        source.feed(Array("A".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)

        let continuation = Array("\u{0301}".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        expectObservableState(resumed, equals: source, phase: "open cluster")
    }

    @Test("state bytes preserve live and saved character-set state")
    func reconstructsCharsetState() throws {
        // Intent: carry the designations, the GL invocation, and the saved slot's copy of both.
        // Why it exists: no charset field is compared directly, so a lost designation only
        // shows up as later text that stops being translated.
        // Scenario: a reader joins while G1 holds DEC Special under SO, with a different
        // designation saved by DECSC.
        var source = try #require(Terminal(columns: 8, rows: 2))
        source.feed(Array("\u{1B})0\u{0E}\u{1B}7".utf8))
        source.feed(Array("\u{0F}\u{1B}(A".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "charset")

        let live = Array("#".utf8)
        source.feed(live)
        resumed.feed(live)
        #expect(source.screenText.hasPrefix("\u{00A3}"))
        expectObservableState(resumed, equals: source, phase: "charset live")

        let restored = Array("\u{1B}8lqk".utf8)
        source.feed(restored)
        resumed.feed(restored)
        #expect(source.screenText.hasPrefix("\u{250C}\u{2500}\u{2510}"))
        expectObservableState(resumed, equals: source, phase: "charset restored")
    }

    @Test("state bytes preserve character-set state beneath an active alternate screen")
    func reconstructsCharsetStateUnderAlternateScreen() throws {
        // Intent: carry the terminal-scoped live charset and each screen's own saved slot
        // across a synchronized alternate screen.
        // Why it exists: leaving a reconstructed full-screen program must restore the shell's
        // designations, which is the regression a per-screen implementation would show.
        // Scenario: a full-screen program runs with DEC Special invoked over a shell that had
        // designated the British set.
        var source = try #require(Terminal(columns: 8, rows: 2))
        source.feed(Array("\u{1B}(A\u{1B}7\u{1B}[?1049h".utf8))
        source.feed(Array("\u{1B})0\u{0E}".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "alternate charset")

        let inAlternate = Array("lqk".utf8)
        source.feed(inAlternate)
        resumed.feed(inAlternate)
        #expect(source.screenText.hasPrefix("\u{250C}\u{2500}\u{2510}"))
        expectObservableState(resumed, equals: source, phase: "alternate charset live")

        let leave = Array("\u{1B}[?1049l#".utf8)
        source.feed(leave)
        resumed.feed(leave)
        #expect(source.screenText.hasPrefix("\u{00A3}"))
        expectObservableState(resumed, equals: source, phase: "alternate charset restored")
    }

    @Test("state bytes preserve a live pending single shift")
    func reconstructsLivePendingSingleShift() throws {
        // Intent: carry an armed SS2 across the fence, spent by exactly one character.
        // Why it exists: a single shift has no cancel sequence, so it cannot ride the replay
        // as ordinary bytes.
        // Scenario: the reader joins between SS2 and the character it shifts.
        var source = try #require(Terminal(columns: 8, rows: 2))
        source.feed(Array("\u{1B}*0\u{1B}N".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "pending single shift")

        let continuation = Array("qq".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        #expect(source.screenText.hasPrefix("\u{2500}q"))
        expectObservableState(resumed, equals: source, phase: "pending single shift spent")
    }

    @Test("state bytes preserve a single shift saved by DECSC")
    func reconstructsSavedPendingSingleShift() throws {
        // Intent: carry the pending single shift stored in the saved-cursor slot, which the
        // VT420 list includes and only DECRC can reveal.
        // Why it exists: the saved slot cannot be written without routing through live state,
        // so a replay that only restores live state silently drops it.
        // Scenario: DECSC runs with SS2 armed, the shift is then spent, and the reader joins
        // before DECRC re-arms it.
        var source = try #require(Terminal(columns: 8, rows: 2))
        source.feed(Array("\u{1B}*0\u{1B}N\u{1B}7q".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "saved single shift")

        let continuation = Array("\u{1B}8qq".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        #expect(source.screenText.hasPrefix("\u{2500}q"))
        expectObservableState(resumed, equals: source, phase: "saved single shift restored")
    }

    @Test("state bytes preserve unfinished input recognition", arguments: [
        (prefix: [0xE2], continuation: [0x82, 0xAC]),
        (prefix: Array("\u{1B}[31".utf8), continuation: Array("mX".utf8)),
        (prefix: Array("\u{1B}[?6$".utf8), continuation: Array("p".utf8)),
        (prefix: Array("\u{1B}P1;2|payload".utf8), continuation: Array("\u{1B}\\X".utf8)),
        (prefix: Array("\u{1B}]8;id=p;https://partial.test".utf8), continuation: Array("\u{7}X\u{1B}]8;;\u{7}".utf8)),
    ] as [(prefix: [UInt8], continuation: [UInt8])])
    func reconstructsUnfinishedInput(prefix: [UInt8], continuation: [UInt8]) throws {
        // Intent: keep chunk boundaries from changing state after a synchronization fence.
        // Why it exists: a fence can land between any two recorded PTY byte chunks.
        // Scenario: the source stops inside UTF-8, CSI, DCS, or OSC input and later completes it.
        var source = try #require(Terminal(columns: 8, rows: 2))
        source.feed(Array("base".utf8))
        source.feed(prefix)

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)

        source.feed(continuation)
        resumed.feed(continuation)
        expectObservableState(resumed, equals: source, phase: "unfinished")
    }

    private func expectObservableState(
        _ actual: Terminal,
        equals expected: Terminal,
        phase: String
    ) {
        #expect(actual.geometry == expected.geometry)
        #expect(actual.presentation == expected.presentation)
        #expect(actual.inputModes == expected.inputModes)
        #expect(actual.isAlternateScreenActive == expected.isAlternateScreenActive)
        #expect(actual.currentStyle == expected.currentStyle)
        #expect(actual.pendingReplyBytes == expected.pendingReplyBytes)
        #expect(actual.rowStructure == expected.rowStructure)
        #expect(actual.semanticPromptRowsForTesting == expected.semanticPromptRowsForTesting)
        #expect(actual.scrollbackRowCount == expected.scrollbackRowCount)
        for index in 0..<expected.scrollbackRowCount {
            #expect(actual.scrollbackRow(at: index) == expected.scrollbackRow(at: index))
        }
        for row in expected.geometry.rows.indices {
            for column in 0..<expected.geometry.columns {
                #expect(
                    actual.cell(row: row, column: column) == expected.cell(row: row, column: column),
                    "\(phase) cell \(row),\(column)"
                )
            }
        }
    }
}
