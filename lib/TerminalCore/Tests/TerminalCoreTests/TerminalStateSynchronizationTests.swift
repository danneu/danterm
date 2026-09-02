// Round-trip proofs for terminal state serialized as terminal-protocol bytes.

import Testing
@testable import TerminalCore

/// Proves that a reset terminal can resume from one complete engine state fence.
struct TerminalStateSynchronizationTests {
    @Test("state bytes preserve DECAWM-off live and saved last-column state")
    func reconstructsModeIndependentLastColumnState() throws {
        // Intent: synchronize both last-column flags while DECAWM is disabled, then prove the
        //   source and replica make the same later wrapping decision.
        // Why it exists: reconstruction used to gate both flags on the active DECAWM value.
        // Scenario: a pane saves one full row, fills another, reconnects, and then enables wrap.
        var source = try #require(Terminal(columns: 4, rows: 3))
        source.feed(Array("\u{1B}[?7lABCD\u{1B}7\rWXYZ".utf8))

        let synchronization = source.stateSynchronization
        var replica = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        replica.feed(synchronization.bytes)
        #expect(replica.geometry.cursor?.isPendingWrap == true)

        let continuation = Array("\u{1B}8\u{1B}[?7hQ".utf8)
        source.feed(continuation)
        replica.feed(continuation)
        expectObservableState(replica, equals: source, phase: "last-column continuation")
        #expect(replica.screenText == "WXYZ\nQ   \n    ")

        var wideSource = try #require(Terminal(columns: 4, rows: 3))
        wideSource.feed(Array("\u{1B}[?7l\u{754C}\u{754C}\u{1B}7\r\u{754C}\u{754C}".utf8))
        let wideSynchronization = wideSource.stateSynchronization
        var wideReplica = try #require(Terminal(
            columns: wideSynchronization.columns,
            rows: wideSynchronization.rows
        ))
        wideReplica.feed(wideSynchronization.bytes)

        wideSource.feed(continuation)
        wideReplica.feed(continuation)
        expectObservableState(wideReplica, equals: wideSource, phase: "wide last-column continuation")
        #expect(wideReplica.screenText == "\u{754C}\u{754C}\nQ   \n    ")
    }

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

    @Test("state bytes carry the alternate screen the source retains but is not showing")
    func reconstructsRetainedInactiveAlternateScreen() throws {
        // Intent: a retained alternate screen and everything about it that survives re-entry --
        //   its rows, its semantic ownership, its DECSC slot, and its Kitty keyboard stack --
        //   reach the replica, without disturbing the primary the source is showing.
        // Why it exists: mode 47 re-enters a retained grid without clearing it, so what an
        //   earlier program left there is content a later one can bring straight back. The
        //   busy primary here is what fails a replay ordered after the primary's own
        //   reconstruction: the switch carries the live cursor and drops pending wrap.
        // Scenario: a full-screen program draws prompt-owned rows, saves a cursor, and leaves;
        //   the shell beneath it resumes with a loaded pen, origin mode, and a pending wrap.
        var source = try #require(Terminal(columns: 8, rows: 3))
        source.feed(Array("shell\r\n".utf8))
        source.feed(Array("\u{1B}[?47h\u{1B}]133;A\u{7}frame that wraps".utf8))
        source.feed(Array("\u{1B}]133;B\u{7}\u{1B}[>3u\u{1B}[2;3H\u{1B}[36m\u{1B}7".utf8))
        source.feed(Array("\u{1B}[?47l".utf8))
        source.feed(Array("\u{1B}[2;3r\u{1B}[?6h\u{1B}[1;1H\u{1B}7\u{1B}[41mZ".utf8))
        source.feed(Array("\u{1B}[2;8Hw".utf8))
        #expect(source.geometry.cursor?.isPendingWrap == true)

        let synchronization = source.stateSynchronization
        var replica = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        replica.feed(synchronization.bytes)
        expectObservableState(replica, equals: source, phase: "retained alternate, primary live")

        // Everything that survives re-entry is judged by what a later re-entry shows and by
        // what the state it restores does, never by the encoded bytes.
        let reentry = Array("\u{1B}[?47h".utf8)
        source.feed(reentry)
        replica.feed(reentry)
        expectObservableState(replica, equals: source, phase: "re-entered alternate")

        source.resize(columns: 5, rows: 4)
        replica.resize(columns: 5, rows: 4)
        expectObservableState(replica, equals: source, phase: "re-entered alternate resized")

        let restore = Array("\u{1B}[3;5H\u{1B}8Q\u{1B}[?u".utf8)
        source.feed(restore)
        replica.feed(restore)
        expectObservableState(replica, equals: source, phase: "alternate saved state restored")
        #expect(replica.drainReplyBytes() == source.drainReplyBytes())
    }

    @Test("a blank retained alternate screen costs nothing and still overwrites a dirty replica")
    func reconstructsBlankRetainedAlternateScreen() throws {
        // Intent: a source whose retained alternate is blank and default converges a replica
        //   that holds an alternate frame of its own, and spends no bytes doing it.
        // Why it exists: the synchronization stream opens with RIS, so the only thing that can
        //   drop a frame the replica retains and the source does not is RIS itself.
        // Scenario: a replica reconnects to a session that never drew on its alternate screen.
        var source = try #require(Terminal(columns: 6, rows: 2))
        source.feed(Array("shell\u{1B}[?47h\u{1B}[?47l".utf8))
        var quiet = try #require(Terminal(columns: 6, rows: 2))
        // The trailing cursor address only matches what the round trip through the alternate
        // screen already did to grapheme attachment; it says nothing about the retained screen.
        quiet.feed(Array("shell\u{1B}[1;6H".utf8))
        #expect(source.stateSynchronization.bytes == quiet.stateSynchronization.bytes)

        let synchronization = source.stateSynchronization
        var replica = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        replica.feed(Array("\u{1B}[?47hSTALE\u{1B}[?47l".utf8))
        replica.feed(synchronization.bytes)

        let reentry = Array("\u{1B}[?47h".utf8)
        source.feed(reentry)
        replica.feed(reentry)
        expectObservableState(replica, equals: source, phase: "blank retained alternate")
    }

    @Test("a blank retained alternate screen still carries its screen-scoped state")
    func reconstructsScreenScopedStateOfBlankRetainedAlternate() throws {
        // Intent: an alternate screen left blank but holding a non-default DECSC slot and a
        //   non-empty Kitty keyboard stack reaches the replica anyway.
        // Why it exists: a blank grid costs no bytes, and the cheapest way to get that property
        //   is to skip a retained screen whose rows are blank -- which silently drops the state
        //   that a later re-entry restores.
        // Scenario: a program enters the alternate screen only to park a cursor and a keyboard
        //   mode there, then leaves without drawing anything.
        var source = try #require(Terminal(columns: 6, rows: 2))
        source.feed(Array("shell\u{1B}[?47h\u{1B}[>5u\u{1B}[2;4H\u{1B}[35m\u{1B}7".utf8))
        source.feed(Array("\u{1B}[?47l".utf8))

        let synchronization = source.stateSynchronization
        var replica = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        replica.feed(synchronization.bytes)

        let reentry = Array("\u{1B}[?47h\u{1B}[1;1H\u{1B}8X\u{1B}[?u".utf8)
        source.feed(reentry)
        replica.feed(reentry)
        expectObservableState(replica, equals: source, phase: "blank alternate screen-scoped state")
        #expect(replica.drainReplyBytes() == source.drainReplyBytes())
    }

    @Test(
        "state bytes reconstruct every terminal mode on an active alternate screen",
        arguments: [0, 1000, 1002, 1003]
    )
    func reconstructsTerminalModes(mouseMode: Int) throws {
        // Intent: preserve every terminal-scoped mode, every mouse state, both screen-owned
        //   keyboard stacks, and origin-relative cursor placement through one state fence.
        // Why it exists: a mode accepted by set/reset must not disappear from synchronization,
        //   and terminal-scoped modes must not replay twice when the alternate screen is active.
        // Scenario: a full-screen program reconnects with non-default input and presentation
        //   modes while the shell beneath it retains a different kitty keyboard stack.
        var source = try #require(Terminal(columns: 8, rows: 6))
        source.feed(Array("primary\u{1B}[>1u".utf8))
        source.feed(Array("\u{1B}[4;20h\u{1B}[?1;6;12;1004;1006;2004;2026h".utf8))
        source.feed(Array("\u{1B}[?7;25;1007l\u{1B}=\u{1B}[4 q".utf8))
        if mouseMode != 0 {
            source.feed(Array("\u{1B}[?\(mouseMode)h".utf8))
        }
        source.feed(Array("\u{1B}[?1047h\u{1B}[>2ualt\u{1B}[2;5r\u{1B}[3;4H".utf8))

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)

        expectObservableState(resumed, equals: source, phase: "mode catalog mouse \(mouseMode)")

        let queries = Array(
            "\u{1B}[4$p\u{1B}[20$p"
                .appending("\u{1B}[?1$p\u{1B}[?6$p\u{1B}[?7$p\u{1B}[?12$p\u{1B}[?25$p")
                .appending("\u{1B}[?1000$p\u{1B}[?1002$p\u{1B}[?1003$p\u{1B}[?1004$p")
                .appending("\u{1B}[?1006$p\u{1B}[?1007$p\u{1B}[?1047$p\u{1B}[?1048$p\u{1B}[?1049$p")
                .appending("\u{1B}[?2004$p\u{1B}[?2026$p\u{1B}[?2027$p")
                .utf8
        )
        source.feed(queries)
        resumed.feed(queries)
        #expect(resumed.drainReplyBytes() == source.drainReplyBytes())

        let continuation = Array("\u{1B}[?1047l\u{1B}[?6l\rX\nY".utf8)
        source.feed(continuation)
        resumed.feed(continuation)
        expectObservableState(resumed, equals: source, phase: "mode continuation \(mouseMode)")
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

    @Test("state bytes preserve one linked derived wide-wrap gap")
    func reconstructsDerivedWideWrapGap() throws {
        // Intent: synchronization carries the visible spacer projection and its following wide
        //   glyph once, with the follower's current style, hyperlink, and run identity intact.
        // Why it exists: the source stores a plain wrap-time blank at the margin, so serializing
        //   stored rows would lose the projected cell or emit the wide head twice to restyle it.
        // Scenario: a blue linked glyph wraps early, its live head is redrawn red, and a fresh
        //   terminal resumes from the resulting state fence.
        var source = try #require(Terminal(columns: 4, rows: 2))
        source.feed(Array(
            "\u{1B}[44m\u{1B}]8;id=sync-gap;https://gap.test\u{7}"
                .appending("\u{1B}[1;4H\u{754C}\u{1B}[2;1H\u{1B}[41m\u{754C}\u{1B}]8;;\u{7}")
                .utf8
        ))
        #expect(source.cell(row: 0, column: 3)?.kind == .spacerHead)
        #expect(source.cell(row: 0, column: 3)?.style.background == .indexed(1))

        let synchronization = source.stateSynchronization
        let wideBytes = Array("\u{754C}".utf8)
        let wideEmissionCount = synchronization.bytes.indices.reduce(into: 0) { count, index in
            guard index + wideBytes.count <= synchronization.bytes.count else { return }
            if Array(synchronization.bytes[index..<(index + wideBytes.count)]) == wideBytes {
                count += 1
            }
        }
        #expect(wideEmissionCount == 1)

        var resumed = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        resumed.feed(synchronization.bytes)

        expectObservableState(resumed, equals: source, phase: "derived wide-wrap gap")
        let sourceGap = try #require(source.activatableLink(at: .init(row: 0, column: 3)))
        let resumedGap = try #require(resumed.activatableLink(at: .init(row: 0, column: 3)))
        let resumedHead = try #require(resumed.activatableLink(at: .init(row: 1, column: 0)))
        #expect(resumedGap == sourceGap)
        #expect(resumedGap == resumedHead)
        #expect(resumedGap.matchesActivation(resumedHead))
    }

    @Test("state bytes preserve a blank wide-wrap row in the live primary grid")
    func reconstructsBlankWideWrapRowInPrimaryGrid() throws {
        // Intent: serialize the projected spacer that a live primary row derives at its margin.
        // Why it exists: raw grid storage keeps that margin as default padding, which lets the
        //   following wide head print on the wrong row during replay.
        // Scenario: a default-pen wide glyph wraps from the last column of a blank 4x2 grid.
        var source = try #require(Terminal(columns: 4, rows: 2))
        source.feed(Array("\u{1B}[4G\u{754C}".utf8))

        try expectRoundTrip(of: source, phase: "blank primary wide wrap")
    }

    @Test("state bytes preserve a blank wide-wrap row on the active alternate screen")
    func reconstructsBlankWideWrapRowOnActiveAlternateScreen() throws {
        // Intent: project each active alternate row through the same margin rule as primary rows.
        // Why it exists: alternate grids have no history store but derive the same live spacer.
        // Scenario: a default-pen wide glyph wraps from a blank row after DECSET 1049.
        var source = try #require(Terminal(columns: 4, rows: 2))
        source.feed(Array("\u{1B}[?1049h\u{1B}[4G\u{754C}".utf8))

        try expectRoundTrip(of: source, phase: "blank active alternate wide wrap")
    }

    @Test("state bytes preserve a blank wide-wrap row on a retained alternate screen")
    func reconstructsBlankWideWrapRowOnRetainedAlternateScreen() throws {
        // Intent: serialize a derived spacer retained on an inactive alternate grid.
        // Why it exists: mode 47 preserves alternate content, so active-grid comparison cannot
        //   prove the offscreen row survived synchronization.
        // Scenario: a wide glyph wraps on the alternate, both terminals leave it, synchronize,
        //   and then re-enter mode 47 to compare the retained grid.
        var source = try #require(Terminal(columns: 4, rows: 2))
        source.feed(Array("\u{1B}[?47h\u{1B}[4G\u{754C}\u{1B}[?47l".utf8))

        let synchronization = source.stateSynchronization
        var replica = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        replica.feed(synchronization.bytes)

        let reentry = Array("\u{1B}[?47h".utf8)
        source.feed(reentry)
        replica.feed(reentry)
        expectObservableState(replica, equals: source, phase: "blank retained alternate wide wrap")
    }

    @Test("row state precedes a deferred wide head")
    func reconstructsMarksAcrossBlankWideWrapRow() throws {
        // Intent: apply each synchronized semantic mark to the row it describes.
        // Why it exists: printing a deferred wide head wraps to the follower before later bytes
        //   can address the spacer row's state.
        // Scenario: a prompt-marked blank row wraps into a follower marked as output.
        var source = try #require(Terminal(columns: 4, rows: 2))
        source.feed(Array(
            "\u{1B}]133;A\u{7}\u{1B}[4G\u{754C}\u{1B}]133;C\u{7}".utf8
        ))

        try expectRoundTrip(of: source, phase: "wide-wrap row marks")
    }

    @Test("seeded synchronization round trips projected row shapes")
    func seededProjectedRowRoundTrips() throws {
        // Intent: reproduce every observable row and cell after mixed writes, jumps, and erases.
        // Why it exists: styling accidentally hid the blank wide-wrap failure in the focused test.
        // Scenario: one fixed random stream drives narrow and wide glyphs, horizontal cursor
        //   jumps, and line erases across 300 small terminals before their state fences.
        var random = SynchronizationRandom(state: 250)
        for iteration in 0..<300 {
            var source = try #require(Terminal(columns: 4, rows: 3))
            for _ in 0..<2 {
                let bytes: [UInt8] = switch (random.next() >> 32) % 8 {
                case 0: Array("a".utf8)
                case 1: Array("Z".utf8)
                case 2: Array("\u{754C}".utf8)
                case 3: Array("\u{1B}[\(((random.next() >> 32) % 4) + 1)G".utf8)
                default: Array("\u{1B}[K".utf8)
                }
                source.feed(bytes)
            }

            try expectRoundTrip(of: source, phase: "seeded iteration \(iteration)")
        }
    }

    #if os(macOS)
    @Test("a projected soft wrap that stops before the margin cannot be synchronized")
    func rejectsSoftWrapThatCannotReachItsMargin() async {
        // Intent: reject a soft-wrapped projected row whose bytes cannot position the replica at
        //   the margin before the following row begins.
        // Why it exists: accepting that shape silently shifts every following serialized row.
        // Scenario: public terminal input combines wraps, erases, and line feeds into the invalid
        //   row shape, then state synchronization observes the invariant violation.
        await #expect(processExitsWith: .failure) {
            guard var source = Terminal(columns: 4, rows: 3) else { return }
            source.feed(Array(
                "\u{1B}[4G\u{754C}\u{1B}[2K\u{754C}\r\n\u{1B}[K"
                    .appending("\u{1B}[4Ga\u{1B}[2K\u{1B}[2K\u{1B}[K\r\n\u{1B}[K")
                    .appending("\u{1B}[2G\u{754C}\u{754C}\r\naZ\u{754C}Z\r\na\u{1B}[2K")
                    .utf8
            ))
            _ = source.stateSynchronization
        }
    }
    #endif

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
        // A scalar run followed by an unfinished sequence: the run's scalars live in a scratch
        // that dies with the feed, so the fence has to carry the pending prefix and nothing else.
        (prefix: Array("\u{65E5}\u{672C}".utf8) + [0xE2], continuation: [0x82, 0xAC]),
        (prefix: Array("\u{1B}[31".utf8), continuation: Array("mX".utf8)),
        (prefix: Array("\u{1B}[?6$".utf8), continuation: Array("p".utf8)),
        (prefix: Array("\u{1B}P1;2|payload".utf8), continuation: Array("\u{1B}\\X".utf8)),
        // A routed DCS retains its header, so the fence has to replay the parameters that
        // decide the request invalid -- not just the intermediate and the final.
        (prefix: Array("\u{1B}P$qm".utf8), continuation: Array("\u{1B}\\X".utf8)),
        (prefix: Array("\u{1B}P1$qm".utf8), continuation: Array("\u{1B}\\X".utf8)),
        (prefix: Array("\u{1B}P1;2$qm".utf8), continuation: Array("\u{1B}\\X".utf8)),
        (prefix: Array("\u{1B}P12+q544e".utf8), continuation: Array("\u{1B}\\X".utf8)),
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

    @Test("state bytes carry an open tail's pending wide margin at full width")
    func reconstructsPendingWideMarginOpenTail() throws {
        // Intent: the last retained row of a source whose open tail is waiting on a wide
        //   margin comes back `columns` wide on the replica, spacer included.
        // Why it exists: history stores that row one column short and the seam is re-derived
        //   from the live grid's first cell; the encoder has to reproduce the seam whichever
        //   route it takes to the row.
        // Scenario: a wide glyph at the last column of a one-row grid wraps, retiring a
        //   three-cell row `abc` with a pending margin under a live wide head.
        var source = try #require(Terminal(columns: 4, rows: 1))
        source.feed(Array("abc\u{754C}".utf8))
        #expect(source.scrollbackRow(at: 0)?.cells[3].kind == .spacerHead)

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)

        #expect(resumed.scrollbackRow(at: 0)?.cells.count == 4)
        expectObservableState(resumed, equals: source, phase: "pending margin")
    }

    @Test("state bytes carry a pending wide margin beneath an active alternate screen")
    func reconstructsPendingWideMarginUnderAlternateScreen() throws {
        // Intent: the same open tail synchronized while the alternate screen is active
        //   matches the source both then and after the source leaves the alternate screen.
        // Why it exists: the active stream severs the seam while the alternate screen is
        //   up, but the encoder replays the primary stream, whose seam is never severed.
        // Scenario: the wrapped wide glyph of the test above, then the alternate screen is
        //   entered before synchronization and left afterwards on both terminals.
        var source = try #require(Terminal(columns: 4, rows: 1))
        source.feed(Array("abc\u{754C}\u{1B}[?1047h".utf8))
        #expect(source.scrollbackRow(at: 0)?.isSoftWrapped == false)

        let synchronization = source.stateSynchronization
        var resumed = try #require(Terminal(columns: synchronization.columns, rows: synchronization.rows))
        resumed.feed(synchronization.bytes)
        expectObservableState(resumed, equals: source, phase: "alternate")

        source.feed(Array("\u{1B}[?1047l".utf8))
        resumed.feed(Array("\u{1B}[?1047l".utf8))
        #expect(resumed.scrollbackRow(at: 0)?.cells[3].kind == .spacerHead)
        expectObservableState(resumed, equals: source, phase: "primary")
    }

    @Test("a resized retained line crosses former record seams during synchronization")
    func resizedLongRetainedLineSynchronizes() throws {
        // Intent: a retained logical line stays continuous at a width that does not divide its
        //   admitting width, and the projected rows can be serialized and replayed.
        // Why it exists: DanTerm 0.1.25 split retained lines at storage seams. After a resize,
        //   one split piece ended short of the margin while still claiming a soft wrap, and the
        //   synchronization encoder trapped on that impossible row.
        // Scenario: one 4,000-cell line scrolls at 20 columns, then a remote client claims the
        //   pane after it has resized to 53 columns.
        var source = try #require(Terminal(
            columns: 20,
            rows: 4,
            scrollbackBudgetBytes: 1 << 16
        ))
        source.feed(Array(repeating: UInt8(ascii: "x"), count: 4_000))
        source.resize(columns: 53, rows: 4)

        let synchronization = source.stateSynchronization
        var replica = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows,
            scrollbackBudgetBytes: 1 << 16
        ))
        replica.feed(synchronization.bytes)

        #expect(replica.screenText == source.screenText)
        #expect(replica.fullHistoryText == source.fullHistoryText)
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

    private func expectRoundTrip(of source: Terminal, phase: String) throws {
        let synchronization = source.stateSynchronization
        var replica = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        replica.feed(synchronization.bytes)
        expectObservableState(replica, equals: source, phase: phase)
    }

    private struct SynchronizationRandom {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }
}
