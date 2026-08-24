// Proves bounded OSC 8 state, identity carry, and pure HTTP(S) link resolution.
import Testing

@testable import TerminalCore

/// Locks terminal-originated links behind bounded storage and a pure activation gate.
struct TerminalHyperlinkTests {
    @Test("OSC 8 opens, closes, preserves semicolons, and reuses explicit ids")
    func grammarAndIdentity() {
        var terminal = Terminal(columns: 20, rows: 2)!

        terminal.feed(osc8(params: "id=42:unknown=value:broken", uri: "http://a.test/x;y"))
        terminal.feed(Array("ab".utf8))
        terminal.feed(osc8(params: "id=42", uri: "http://a.test/x;y"))
        terminal.feed(Array("c".utf8))
        terminal.feed(osc8(params: "id=ignored", uri: ""))
        terminal.feed(Array("d".utf8))

        let first = terminal.cell(row: 0, column: 0)?.hyperlink
        #expect(first == TerminalHyperlink(uri: "http://a.test/x;y", explicitId: "42"))
        #expect(terminal.cell(row: 0, column: 1)?.hyperlink == first)
        #expect(terminal.cell(row: 0, column: 2)?.hyperlink == first)
        #expect(terminal.cell(row: 0, column: 3)?.hyperlink == nil)
        #expect(terminal.retainedHyperlinkCount == 1)

        terminal.feed([0x1B, 0x5D] + Array("8;id=".utf8) + [0xFF]
            + Array(";https://malformed-params.test".utf8) + [0x07, 0x65])
        #expect(terminal.cell(row: 0, column: 4)?.hyperlink
            == TerminalHyperlink(uri: "https://malformed-params.test"))
    }

    // Intent: an empty `id=` value behaves exactly as an absent `id` parameter,
    // and leaves the URI alone.
    // Why it exists: BUG-35 -- the decoder stored `""`, so the pen carried an
    // empty explicit id that no OSC 8 writer ever asked for.
    // Scenario: a run opened with `id=` and no other parameters.
    @Test("an empty OSC 8 id value is no id at all")
    func emptyExplicitIdIsAbsent() {
        var terminal = Terminal(columns: 20, rows: 2)!

        terminal.feed(osc8(params: "id=", uri: "http://a.test/x"))
        terminal.feed(Array("ab".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.hyperlink
            == TerminalHyperlink(uri: "http://a.test/x"))
    }

    // Intent: two empty-id opens of one URI are two links, the way two opens
    // with no `id` parameter are.
    // Why it exists: BUG-35 -- `dispatchOSC8` reuses a target when the explicit
    // id and URI both match, so a stored `""` collapsed unrelated runs into one
    // link that highlighted together on hover.
    // Scenario: two runs of the same URI, each opened with `id=` and separated
    // by a close.
    @Test("empty OSC 8 ids do not join separate runs of one URI")
    func emptyExplicitIdsDoNotShareATarget() {
        var terminal = Terminal(columns: 20, rows: 2)!

        terminal.feed(osc8(params: "id=", uri: "http://a.test/x"))
        terminal.feed(Array("a".utf8))
        terminal.feed(osc8(params: "", uri: ""))
        terminal.feed(osc8(params: "id=", uri: "http://a.test/x"))
        terminal.feed(Array("b".utf8))
        #expect(terminal.retainedHyperlinkCount == 2)

        var shared = Terminal(columns: 20, rows: 2)!
        shared.feed(osc8(params: "id=7", uri: "http://a.test/x"))
        shared.feed(Array("a".utf8))
        shared.feed(osc8(params: "", uri: ""))
        shared.feed(osc8(params: "id=7", uri: "http://a.test/x"))
        shared.feed(Array("b".utf8))
        #expect(shared.retainedHyperlinkCount == 1)
    }

    @Test("OSC 8 is terminator- and chunk-invariant")
    func terminatorAndChunkInvariance() {
        let bodies = [
            Array("\u{1B}]8;;https://example.com\u{7}x".utf8),
            Array("\u{1B}]8;;https://example.com\u{1B}\\x".utf8),
        ]
        var authored = Terminal(columns: 20, rows: 2)!
        authored.feed(bodies[0])

        for bytes in bodies {
            var whole = Terminal(columns: 20, rows: 2)!
            whole.feed(bytes)
            #expect(whole == authored)
            for offset in 0...bytes.count {
                var split = Terminal(columns: 20, rows: 2)!
                split.feed(Array(bytes[..<offset]))
                split.feed(Array(bytes[offset...]))
                #expect(split == authored)
            }
        }
    }

    @Test("OSC 8 rejects invalid UTF-8 and oversized targets without changing the pen")
    func rejectionIsAtomic() {
        var terminal = Terminal(columns: 70_000, rows: 1)!
        terminal.feed(osc8(uri: "https://kept.test"))
        terminal.feed(Array("a".utf8))
        let baseline = terminal

        terminal.feed([0x1B, 0x5D] + Array("8;;".utf8) + [0xFF, 0x07])
        terminal.feed([0x1B, 0x5D] + Array("8;;https://invalid".utf8) + [0x9C, 0x1B, 0x5C])
        terminal.feed(osc8(uri: "https://" + String(repeating: "x", count: 65_529)))
        #expect(terminal == baseline)

        terminal.feed(Array("b".utf8))
        #expect(terminal.cell(row: 0, column: 1)?.hyperlink?.uri == "https://kept.test")
    }

    @Test("OSC 8 accepts exactly 64 KiB of target metadata")
    func perTargetBoundary() {
        let prefix = "https://"
        let accepted = prefix + String(repeating: "a", count: 65_536 - prefix.utf8.count)
        let rejected = accepted + "a"
        var terminal = Terminal(columns: 2, rows: 1)!

        terminal.feed(osc8(uri: accepted))
        terminal.feed(Array("x".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == accepted)
        let acceptedState = terminal
        terminal.feed(osc8(uri: rejected))
        #expect(terminal == acceptedState)
    }

    @Test("aggregate pressure sweeps dead targets atomically before admission")
    func aggregateBudgetSweepAndRefusal() {
        // Intent: aggregate admission sweeps dead cell identities but commits no part of a
        //   candidate when the live table still cannot fit it.
        // Why it exists: a mark-and-sweep performed directly on live state could delete old
        //   metadata even though the OSC 8 open itself must be apply-none.
        // Scenario: a pane sits just below 256 KiB, one old cell is overwritten, and another
        //   maximum-sized target arrives before enough dead metadata exists to admit it.
        var terminal = Terminal(columns: 20, rows: 1)!
        let retainedLength = 65_500
        for index in 0..<4 {
            let prefix = "https://\(index).test/"
            terminal.feed(osc8(uri: prefix + String(repeating: "a", count: retainedLength - prefix.utf8.count)))
            terminal.feed(Array("x".utf8))
        }
        #expect(terminal.retainedHyperlinkMetadataBytes == 4 * retainedLength)

        terminal.feed(osc8(uri: ""))
        let baseline = terminal
        let maximum = "https://candidate.test/"
            + String(repeating: "b", count: 65_536 - "https://candidate.test/".utf8.count)
        terminal.feed(osc8(uri: maximum))
        #expect(terminal == baseline)

        terminal.feed(Array("\u{1B}[1;1Hy".utf8))
        terminal.feed(osc8(uri: maximum))
        #expect(terminal.retainedHyperlinkCount == 4)
        #expect(terminal.retainedHyperlinkMetadataBytes <= 256 * 1_024)
    }

    @Test("metadata sweep preserves a link held only by the offscreen primary")
    func aggregateBudgetSweepWalksOffscreenPrimary() {
        // Intent: hyperlink reclamation treats the retained primary as live while the alternate
        //   screen is active.
        // Why it exists: the collector walks both resident grids by hand, so omitting the
        //   offscreen one would recycle an id that the primary still uses.
        // Scenario: a shell link stays on the primary while a full-screen program creates enough
        //   dead targets to force metadata reclamation.
        var terminal = Terminal(columns: 2, rows: 1)!
        terminal.feed(osc8(uri: "https://primary.test"))
        terminal.feed(Array("p".utf8))
        terminal.feed(osc8(uri: ""))
        terminal.feed(Array("\u{1B}[?1047h".utf8))

        let targetLength = 60_000
        for index in 0..<5 {
            let prefix = "https://alternate-\(index).test/"
            let uri = prefix + String(repeating: "x", count: targetLength - prefix.utf8.count)
            terminal.feed(Array("\u{1B}[1;1H".utf8))
            terminal.feed(osc8(uri: uri))
            terminal.feed(Array("a".utf8))
            terminal.feed(osc8(uri: ""))
        }

        #expect(terminal.retainedHyperlinkCount < 6)
        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == "https://primary.test")
    }

    @Test("SGR preserves the link pen while resets and blank-producing operations clear links")
    func penSemantics() {
        var terminal = Terminal(columns: 8, rows: 2)!
        terminal.feed(osc8(uri: "https://example.com"))
        terminal.feed(Array("a\u{1B}[0mb\u{1B}[mc\u{1B}[1;0md".utf8))
        for column in 0..<4 {
            #expect(terminal.cell(row: 0, column: column)?.hyperlink != nil)
        }

        terminal.feed(Array("\u{1B}7\u{1B}]8;;\u{7}\u{1B}8e\u{1B}[2J\u{1B}#8".utf8))
        #expect(terminal.cell(row: 0, column: 4)?.hyperlink == nil)
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink == nil)

        // DECALN homed the cursor, so "x" and "y" land on the first two columns.
        terminal.feed(osc8(uri: "https://reset.test"))
        terminal.feed(Array("x\u{1B}[!py".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink != nil)
        #expect(terminal.cell(row: 0, column: 1)?.hyperlink == nil)
    }

    @Test("REP inherits the pen while resize fill, alternate cells, and RIS do not leak links")
    func penAcrossStructuralOperations() {
        var terminal = Terminal(columns: 4, rows: 2)!
        terminal.feed(osc8(uri: "https://primary.test"))
        terminal.feed(Array("x\u{1B}[2b".utf8))
        for column in 0..<3 {
            #expect(terminal.cell(row: 0, column: column)?.hyperlink?.uri
                == "https://primary.test")
        }

        terminal.resize(columns: 6, rows: 2)
        #expect(terminal.cell(row: 0, column: 4)?.hyperlink == nil)
        terminal.feed(osc8(uri: ""))
        terminal.feed(Array("\u{1B}[?1047h".utf8))
        terminal.feed(osc8(uri: "https://alternate.test"))
        terminal.feed(Array("a".utf8))
        #expect(terminal.cell(row: 0, column: 3)?.hyperlink?.uri
            == "https://alternate.test")
        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == "https://primary.test")
        #expect(terminal.cell(row: 0, column: 3)?.hyperlink == nil)

        terminal.feed(osc8(uri: "https://reset.test"))
        terminal.feed(Array("\u{1B}cy".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink == nil)
        #expect(terminal.retainedHyperlinkCount == 0)
    }

    @Test("link identity survives wide cells, soft wraps, reflow, scrollback, and eviction")
    func identityCarry() {
        // Sized at the *widest* geometry this test reaches (it resizes 5 -> 3 -> 6), because the
        // budget is denominated in bytes: a budget that holds a row at 5 columns holds none at 6.
        var terminal = Terminal(columns: 5, rows: 2, scrollbackBudgetBytes: historyBudget(lines: 4, cells: 6, paneColumns: 6))!
        terminal.feed(osc8(params: "id=wide", uri: "https://wide.test"))
        terminal.feed(Array("abc界z\nnext\nlast".utf8))
        terminal.resize(columns: 3, rows: 2)
        terminal.resize(columns: 6, rows: 2)

        let linkedCells = (0..<terminal.scrollbackRowCount).reduce(into: [TerminalCell]()) {
            $0.append(contentsOf: terminal.scrollbackRow(at: $1)?.cells ?? [])
        }.filter { $0.hyperlink?.explicitId == "wide" }
        #expect(linkedCells.isEmpty == false)
        #expect(terminal.retainedHyperlinkMetadataBytes <= 1_048_576)
        expectValidGrid(terminal)
    }

    @Test("an OSC 8 run resolves from both sides of a wide-wrap gap")
    func explicitLinkCrossesWideWrapGap() throws {
        // Intent: the projected gap and its following wide head activate one OSC 8 run.
        // Why it exists: the gap stores no hyperlink; activation must consume the same
        //   follower-derived cell that geometry and rendering expose.
        // Scenario: a linked wide glyph wraps early from the last column, and the user points
        //   first at the gap above it and then at the glyph below it.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array(
            "\u{1B}]8;id=gap;https://gap.test\u{7}\u{1B}[1;4H\u{754C}\u{1B}]8;;\u{7}".utf8
        ))

        let gap = try #require(terminal.activatableLink(at: .init(row: 0, column: 3)))
        let head = try #require(terminal.activatableLink(at: .init(row: 1, column: 0)))
        #expect(gap.hyperlink.uri == "https://gap.test")
        #expect(gap.hyperlink.explicitId == "gap")
        #expect(gap == head)
        #expect(gap.matchesActivation(head))
        #expect(gap.range == TerminalTextRange(
            start: .init(row: 0, column: 3),
            end: .init(row: 1, column: 2)
        ))
    }

    @Test("links keep working after far more distinct targets than the id space holds at once")
    func linksSurviveIdSpaceExhaustion() {
        // Intent: a session that emits more distinct OSC 8 targets than the identifier space can
        //   hold simultaneously still resolves later links, and never resolves one to an earlier
        //   target's URI.
        // Why it exists: cell-held link ids are a narrow integer (`research/15/D3`), so the id space
        //   is exhaustible in a way an unbounded counter's was not, and the counter must therefore
        //   wrap and recycle. This test covers the recycling half: an id handed out again while a
        //   live cell still points at it would show that cell another target's URI. The half where
        //   recycling is no longer possible -- every id occupied at once -- is
        //   `fullIdSpaceRefusesFurtherOpens` below. Both are invisible to every other test here,
        //   which uses a handful of links.
        // Scenario: a long-lived pane running a tool that emits a uniquely-identified link per
        //   line -- `ls --hyperlink`, a build log, a test runner -- for hours.
        // Walking the cursor to the wrap for real costs 65,536 targets, and admission is linear in
        // the live table, so that is quadratic work for one boundary crossing. The warm-up below
        // is sized only to force at least one metadata sweep -- which is what puts previously
        // issued low ids back in the free pool -- and `primeHyperlinkIdWrapForTesting` then jumps
        // the cursor to the last id before the wrap. The recycled ids the post-wrap phase hands
        // out are therefore genuinely reissued, not pristine.
        let warmUpCount = 600
        let postWrapCount = 120
        let linkCount = warmUpCount + postWrapCount
        var terminal = Terminal(columns: 8, rows: 2)!

        // Column 0 is written once and never touched again, so its link stays live for the whole
        // run. It is the cell that catches a recycled id landing on a target something still
        // points at -- the assertion below reads the *old* URI, not the newest one.
        terminal.feed(osc8(uri: "https://pinned.test"))
        terminal.feed(Array("a".utf8))
        let pinnedId = terminal.liveRowForTesting(at: 0)?.cell(at: 0).hyperlinkId

        // Padded to ~512 bytes so the 256 KiB metadata cap admits only a few hundred targets at a
        // time. Short URIs would let the table grow into the thousands between sweeps, and
        // admission is linear in table size, which makes this test minutes long for no extra
        // coverage -- the property under test is the *id* space, not the byte cap.
        let padding = String(repeating: "p", count: 480)
        func emit(_ index: Int) {
            // Rewrite column 1 in place. Nothing scrolls, so the pinned cell above survives, and
            // each link's only cell dies as the next one overwrites it.
            terminal.feed(Array("\u{1B}[1;2H".utf8))
            terminal.feed(osc8(uri: "https://h\(index).test/\(padding)"))
            terminal.feed(Array("x".utf8))
        }

        for index in 0..<warmUpCount { emit(index) }

        terminal.primeHyperlinkIdWrapForTesting()
        var idsAfterPriming = Set<Terminal.HyperlinkId>()
        for index in warmUpCount..<linkCount {
            emit(index)
            if let id = terminal.liveRowForTesting(at: 0)?.cell(at: 1).hyperlinkId {
                idsAfterPriming.insert(id)
            }
        }

        #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == "https://pinned.test")
        #expect(terminal.cell(row: 0, column: 1)?.hyperlink?.uri
            == "https://h\(linkCount - 1).test/\(padding)")
        // The wrap really happened, and the allocator walked back into the low ids rather than
        // refusing or reissuing the one the pinned cell still holds. Asserting the issued ids
        // directly is what keeps the priming honest: a seam that failed to reach the boundary,
        // or a skip that stopped skipping, changes this set rather than passing silently.
        #expect(pinnedId == 1)
        #expect(idsAfterPriming.contains(Terminal.HyperlinkId.max))
        #expect(idsAfterPriming.contains(2))
        #expect(idsAfterPriming.contains(0) == false)
        #expect(idsAfterPriming.contains(1) == false)
        // The live table must stay bounded rather than growing with the number of targets seen,
        // which is the property that keeps a narrow id sufficient in the first place. Failing this
        // also means no sweep ran, which would leave the recycled ids above pristine.
        #expect(terminal.retainedHyperlinkCount < linkCount)
        expectValidGrid(terminal)
    }

    @Test("hyperlink id 0 is never stored in a cell")
    func zeroHyperlinkIdIsReservedForAbsentLinks() {
        // Intent: every linked cell carries a nonzero id, including the first cell written after
        //   the allocator wraps.
        // Why it exists: the packed cell representation uses 0 as the absent-link sentinel. If
        //   the allocator emits 0 after `HyperlinkId.max`, that link becomes indistinguishable
        //   from an unlinked cell when the representation changes.
        // Scenario: two distinct links straddle the id wrap and each writes one visible cell.
        var terminal = Terminal(columns: 2, rows: 1)!
        terminal.primeHyperlinkIdWrapForTesting()

        terminal.feed(osc8(uri: "https://maximum.test"))
        terminal.feed(Array("a".utf8))
        terminal.feed(osc8(uri: "https://wrapped.test"))
        terminal.feed(Array("b".utf8))

        #expect(terminal.liveRowForTesting(at: 0)?.cell(at: 0).hyperlinkId
            == Terminal.HyperlinkId.max)
        #expect(terminal.liveRowForTesting(at: 0)?.cell(at: 1).hyperlinkId == 1)
    }

    @Test("a full id space refuses further opens instead of spinning, and keeps the pen")
    func fullIdSpaceRefusesFurtherOpens() {
        // Intent: once every hyperlink id is taken, an OSC 8 open changes nothing -- no new
        //   target, no new pen -- and later text keeps the link that was already open.
        // Why it exists: `allocateHyperlinkId` scans forward from a rotating cursor for a free id,
        //   so a completely occupied table has no free candidate to find. Two independent things
        //   make that a refusal rather than an infinite loop inside `feed` -- the count guard's
        //   early return, and the scan's own bound over the id space -- and this pins the
        //   behavior they agree on, so neutralizing either one alone still leaves it green. The
        //   sibling test above covers the other half of the id space -- the wrap, where ids are
        //   still recyclable. Nothing covered this half, because a table that reaches 65,536
        //   entries needs short URIs, and the padded targets that test needs steady-state at ~500.
        // Scenario: a pane whose output alternates two very short OSC 8 targets. Each open dedupes
        //   only against the current pen, so every one mints a fresh id while the one-byte URIs
        //   keep the table far below the 256 KiB metadata cap -- the table grows until the ids,
        //   not the bytes, run out.
        var terminal = Terminal(columns: 4, rows: 1)!
        terminal.primeHyperlinkIdSpaceForTesting()

        // One id is still free, so this open must succeed -- and taking it is what saturates the
        // space. Straddling the boundary with real feeds keeps the seam from deciding the outcome.
        terminal.feed(osc8(uri: "https://last.test"))
        terminal.feed(Array("x".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == "https://last.test")
        #expect(terminal.retainedHyperlinkCount == Int(Terminal.HyperlinkId.max))

        let saturated = terminal
        terminal.feed(osc8(uri: "https://refused.test"))
        #expect(terminal == saturated)

        terminal.feed(Array("y".utf8))
        #expect(terminal.cell(row: 0, column: 1)?.hyperlink?.uri == "https://last.test")
        #expect(terminal.retainedHyperlinkCount == Int(Terminal.HyperlinkId.max))
        expectValidGrid(terminal)
    }

    @Test("explicit links resolve by contiguous run and take precedence over detection")
    func explicitResolution() {
        var terminal = Terminal(columns: 12, rows: 2)!
        terminal.feed(osc8(uri: "https://explicit.test"))
        terminal.feed(Array("abc".utf8))
        terminal.feed(osc8(uri: ""))
        terminal.feed(Array(" http://x.io".utf8))

        let explicit = terminal.activatableLink(at: .init(row: 0, column: 1))
        #expect(explicit?.hyperlink.uri == "https://explicit.test")
        #expect(explicit?.range == range(0, 0, 0, 3))
        #expect(terminal.activatableLink(at: .init(row: 0, column: 5))?.hyperlink.uri == "http://x.io")
    }

    @Test("automatic detection follows soft wraps and ignores surrounding punctuation")
    func automaticDetection() {
        var terminal = Terminal(columns: 10, rows: 3)!
        terminal.feed(Array("see (https://example.com/path), ok".utf8))

        let link = terminal.activatableLink(at: .init(row: 1, column: 3))
        #expect(link?.hyperlink.uri == "https://example.com/path")
        #expect(link?.range.start == .init(row: 0, column: 5))
        #expect(terminal.activatableLink(at: .init(row: 0, column: 1)) == nil)
    }

    @Test("automatic detection trims terminal punctuation and resolves only URL cells")
    func automaticDetectionBoundaries() throws {
        // Intent: automatic HTTP(S) detection finds the complete token from any URL cell,
        //   trims prose punctuation, and does not extend activation into adjacent whitespace.
        // Why it exists: the previous coverage exercised only `(URL),`, leaving the rest of
        //   the detector's punctuation and token-boundary policy unproved.
        // Scenario: command output contains URLs beside punctuation, leading whitespace, and
        //   malformed lookalikes, and the user Command-clicks both inside and beside them.
        // Adapted from kitty_tests/datatypes.py#test_url_at
        //   (kitty v0.48.2 2cb1d95, body sha256:2ba030f7abcf).
        //   Divergence: asserts through `activatableLink(at:)`, supports only HTTP(S), trims an
        //   unbalanced `)` in agreement with WezTerm/foot/iTerm2, and does not activate whitespace.
        let cases: [(text: String, click: Int, uri: String)] = [
            ("http://xyz.com.", 7, "http://xyz.com"),
            ("http://xyz.com,", 7, "http://xyz.com"),
            ("http://xyz.com\\", 7, "http://xyz.com"),
            ("http://xyz.com}", 7, "http://xyz.com"),
            ("http://xyz.com]", 7, "http://xyz.com"),
            ("http://xyz.com>", 7, "http://xyz.com"),
            ("http://xyz.com)", 7, "http://xyz.com"),
            ("http://-abcd] ", 8, "http://-abcd"),
            ("http://a.b?q=1/", 8, "http://a.b?q=1/"),
            ("http://a.b?q=1-", 8, "http://a.b?q=1-"),
            ("http://a.b?q=1&", 8, "http://a.b?q=1&"),
        ]
        for entry in cases {
            var terminal = try #require(Terminal(columns: entry.text.utf8.count + 1, rows: 1))
            terminal.feed(Array(entry.text.utf8))
            #expect(
                terminal.activatableLink(at: .init(row: 0, column: entry.click))?.hyperlink.uri
                    == entry.uri,
                "input: \(entry.text)"
            )
        }

        let surrounded = "  https://testing.me  "
        var terminal = try #require(Terminal(columns: surrounded.utf8.count, rows: 1))
        terminal.feed(Array(surrounded.utf8))
        for column in 2..<(surrounded.utf8.count - 2) {
            #expect(
                terminal.activatableLink(at: .init(row: 0, column: column))?.hyperlink.uri
                    == "https://testing.me"
            )
        }
        #expect(terminal.activatableLink(at: .init(row: 0, column: 0)) == nil)
        #expect(terminal.activatableLink(at: .init(row: 0, column: 1)) == nil)
        #expect(terminal.activatableLink(at: .init(row: 0, column: surrounded.utf8.count - 1)) == nil)

        for text in ["https:// testing.me", "h ttp://acme.com", "http: //acme.com", "http:/ /acme.com"] {
            var malformed = try #require(Terminal(columns: text.utf8.count + 1, rows: 1))
            malformed.feed(Array(text.utf8))
            for column in 0..<text.utf8.count {
                #expect(malformed.activatableLink(at: .init(row: 0, column: column)) == nil)
            }
        }
    }

    @Test("automatic detection accepts 64 KiB and rejects one byte more")
    func detectedTargetBoundary() {
        let prefix = "https://example.test/"
        let accepted = prefix + String(repeating: "a", count: 65_536 - prefix.utf8.count)
        let rejected = accepted + "a"
        var acceptedTerminal = Terminal(columns: 65_540, rows: 1)!
        acceptedTerminal.feed(Array(accepted.utf8))
        #expect(
            acceptedTerminal.activatableLink(at: .init(row: 0, column: 100))?.hyperlink.uri
                == accepted
        )

        var rejectedTerminal = Terminal(columns: 65_540, rows: 2)!
        rejectedTerminal.feed(Array(rejected.utf8))
        #expect(rejectedTerminal.activatableLink(at: .init(row: 0, column: 100)) == nil)
        #expect(rejectedTerminal.retainedHyperlinkCount == 0)
    }

    @Test("activation rejects unsafe schemes and malformed HTTP authorities")
    func activationValidation() {
        let rejected = [
            "javascript:alert(1)", "file:///tmp/a", "data:text/plain,x", "mailto:a@b.test",
            "http:/missing", "http://", "http://:80/a", "http://host:0/a",
            "http://host:65536/a", "http://host:abc/a", "http://host name/a",
            "http://bad%zz.test/a", "http://[gg::1]/a", "http://a@b@example.com/a",
        ]
        for uri in rejected {
            var terminal = Terminal(columns: 80, rows: 1)!
            terminal.feed(osc8(uri: uri))
            terminal.feed(Array("x".utf8))
            #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == uri)
            #expect(terminal.activatableLink(at: .init(row: 0, column: 0)) == nil)
        }

        for uri in ["HTTP://example.com", "Https://user@example.com:443/a?b=c#d", "http://[::1]:8080/"] {
            var terminal = Terminal(columns: 80, rows: 1)!
            terminal.feed(osc8(uri: uri))
            terminal.feed(Array("x".utf8))
            #expect(terminal.activatableLink(at: .init(row: 0, column: 0))?.hyperlink.uri == uri)
        }
    }

    // Intent: a URI carrying an invisible, bidi-affecting, or non-ASCII whitespace scalar
    //   anywhere -- not just in the authority -- is never activatable, while a URI whose only
    //   non-ASCII content is ordinary visible text stays activatable.
    // Why it exists: the activation gate validated only the authority against RFC 3986 and let
    //   the path, query, and fragment through on a bare "greater than 0x20" check. Those scalars
    //   render as nothing (or reorder their neighbours) in the hover preview, and the app's
    //   separate pre-open check rejected them, so the terminal drew a link, armed it on
    //   Cmd-press, and then silently opened nothing.
    // Scenario: a program emits OSC 8 whose path hides a zero-width space; hovering must not
    //   offer the link at all rather than offer one that cannot be opened.
    @Test("activation rejects invisible and whitespace scalars anywhere in the URI")
    func activationRejectsHiddenScalars() {
        let hidden: [Unicode.Scalar] = [
            "\u{200B}", "\u{200E}", "\u{202E}", "\u{2066}", "\u{FEFF}", "\u{00AD}",
            "\u{061C}", "\u{2060}", "\u{0085}", "\u{E0041}",
            "\u{00A0}", "\u{2028}", "\u{2029}", "\u{3000}",
        ]
        for scalar in hidden {
            for uri in [
                "https://example.com/a\(scalar)b",
                "https://example.com/?q=a\(scalar)b",
                "https://example.com/#a\(scalar)b",
            ] {
                var terminal = Terminal(columns: 80, rows: 1)!
                terminal.feed(osc8(uri: uri))
                terminal.feed(Array("x".utf8))
                #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == uri)
                #expect(terminal.activatableLink(at: .init(row: 0, column: 0)) == nil)
            }
        }

        for uri in [
            "https://ja.wikipedia.org/wiki/日本語",
            "https://example.com/a%20b?q=1#f",
            "https://example.com/emoji/🐈",
        ] {
            var terminal = Terminal(columns: 80, rows: 1)!
            terminal.feed(osc8(uri: uri))
            terminal.feed(Array("x".utf8))
            #expect(terminal.activatableLink(at: .init(row: 0, column: 0))?.hyperlink.uri == uri)
        }
    }

    private func osc8(params: String = "", uri: String) -> [UInt8] {
        Array("\u{1B}]8;\(params);\(uri)\u{7}".utf8)
    }

    private func range(_ sr: Int, _ sc: Int, _ er: Int, _ ec: Int) -> TerminalTextRange {
        TerminalTextRange(
            start: .init(row: sr, column: sc),
            end: .init(row: er, column: ec)
        )
    }
}
