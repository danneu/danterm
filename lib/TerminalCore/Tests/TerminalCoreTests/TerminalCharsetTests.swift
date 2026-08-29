// Behavioral pins for the 7-bit GL half of ISO 2022: SCS designation, locking and single
// shifts, and the translation of GL bytes on the print path.
//
// The engine has no GR bank -- every byte at or above 0x80 is consumed by the UTF-8 decoder
// before charset logic could see it -- so the invocations that select GR are pinned here as
// inert rather than as behavior.
//
// What does not belong here: how a run of GL bytes translates internally. That is proven
// equivalent to the per-character path by the chunk sweep in `TerminalBulkRunTests`.
import Testing

@testable import TerminalCore

/// Pins designation, invocation, translation, and every reset or restore that moves the state.
struct TerminalCharsetTests {
    /// The scalars 0x20...0x7E map to under DEC Special Graphics, in byte order.
    ///
    /// Matches `references/xterm/charsets.h#map_DEC_Spec_Graphic` on every remapped byte and
    /// `references/ghostty/src/terminal/charsets.zig#dec_special` on all of them: 0x5F stays
    /// `_` here, where xterm's wide build maps it to U+2426.
    private static let decSpecialGraphicsText =
        " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_"
        + "\u{25C6}\u{2592}\u{2409}\u{240C}\u{240D}\u{240A}\u{00B0}\u{00B1}"
        + "\u{2424}\u{240B}\u{2518}\u{2510}\u{250C}\u{2514}\u{253C}\u{23BA}"
        + "\u{23BB}\u{2500}\u{23BC}\u{23BD}\u{251C}\u{2524}\u{2534}\u{252C}"
        + "\u{2502}\u{2264}\u{2265}\u{03C0}\u{2260}\u{00A3}\u{00B7}"

    @Test("designating DEC Special Graphics into G0 draws lines until ASCII is designated back")
    func designationIntoG0Translates() throws {
        // Intent: `ESC ( 0` makes GL bytes draw box glyphs, and `ESC ( B` ends that.
        // Why it exists: `TERM=xterm-256color` defines `smacs=\E(0` and `sgr0=\E(B\E[m`, so
        //   every ncurses program that draws a border depends on this pair. Without it the
        //   user sees rows of literal `lqk` where a frame belongs.
        var terminal = try #require(Terminal(columns: 10, rows: 1))
        terminal.feed(Array("\u{1B}(0lqk\u{1B}(Bab".utf8))

        #expect(terminal.screenText == "\u{250C}\u{2500}\u{2510}ab     ")
        expectValidGrid(terminal)
    }

    @Test("SO and SI lock GL onto G1 and back onto G0")
    func lockingShiftsSelectSlots() throws {
        // Intent: `ESC ) 0` designates into G1, SO invokes it, and SI returns to G0.
        // Why it exists: the vt100 and screen terminfo family reaches line drawing through
        //   `smacs=^N` / `rmacs=^O` with `enacs=\E(B\E)0` rather than through designation,
        //   so a designation-only implementation still shows GNU screen literal `lqk`.
        var terminal = try #require(Terminal(columns: 10, rows: 1))
        terminal.feed(Array("\u{1B})0\u{0E}lqk\u{0F}ab".utf8))

        #expect(terminal.screenText == "\u{250C}\u{2500}\u{2510}ab     ")
        expectValidGrid(terminal)
    }

    @Test("the DEC Special and UK tables translate exactly the bytes they claim")
    func tablesMatchTheirReferences() throws {
        var special = try #require(Terminal(columns: 95, rows: 1))
        special.feed(Array("\u{1B}(0".utf8))
        special.feed(Array((0x20...0x7E).map { UInt8($0) }))
        #expect(special.screenText == Self.decSpecialGraphicsText)
        expectValidGrid(special)

        var british = try #require(Terminal(columns: 95, rows: 1))
        british.feed(Array("\u{1B}(A".utf8))
        british.feed(Array((0x20...0x7E).map { UInt8($0) }))
        var expected = (0x20...0x7E).map { Character(Unicode.Scalar(UInt8($0))) }
        expected[0x23 - 0x20] = "\u{00A3}"
        #expect(british.screenText == String(expected))
        expectValidGrid(british)
    }

    @Test("every scalar a charset table can emit is narrow and breaks as .other")
    func translatedScalarsAreNarrowAndBreakOther() {
        // Intent: the generated Unicode table classifies every table output as one cell wide
        //   with grapheme-break class `.other`.
        // Why it exists: this is the premise the bulk run path rests on. It stamps translated
        //   scalars as narrow `.other` cells without ever calling the classifier, so a wide or
        //   cluster-joining output would reach the grid with nothing else to catch it.
        for byte in UInt8(0x20)...UInt8(0x7E) {
            for charset in [TerminalCharset.ascii, .british, .decSpecialGraphics] {
                let scalar = charset.translate(byte)
                let classification = terminalUnicodeClassification(for: scalar)
                let name = "U+\(String(scalar.value, radix: 16, uppercase: true))"
                #expect(classification.properties.cellWidth == .narrow, "\(name) is not narrow")
                #expect(
                    classification.graphemeBreakClass == .other,
                    "\(name) does not break as .other"
                )
                #expect(classification.properties.isEmojiModifier == false)
            }
        }
    }

    @Test("LS2 and LS3 invoke G2 and G3 for good, SS2 and SS3 for one character")
    func lockingAndSingleShiftsReachG2AndG3() throws {
        var locking = try #require(Terminal(columns: 4, rows: 1))
        locking.feed(Array("\u{1B}*0\u{1B}nqq".utf8))
        #expect(locking.screenText == "\u{2500}\u{2500}  ")

        var single = try #require(Terminal(columns: 4, rows: 1))
        single.feed(Array("\u{1B}+0\u{1B}Oqq".utf8))
        #expect(single.screenText == "\u{2500}q  ")
        expectValidGrid(single)
    }

    @Test("a printed non-GL scalar consumes a pending single shift")
    func nonGLScalarConsumesPendingShift() throws {
        // Intent: a single shift applies to the next printed graphic character whatever it is,
        //   not to the next byte the shift could have translated.
        // Why it exists: leaving the shift pending until a GL byte arrives would carry it
        //   across arbitrary UTF-8 text and translate a character the program never shifted.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("\u{1B}+0\u{1B}O\u{00E9}q".utf8))

        #expect(terminal.screenText == "\u{00E9}q  ")
        expectValidGrid(terminal)
    }

    @Test("DECSC and DECRC carry the full charset state through the saved slot")
    func savedCursorRoundTripsCharsetState() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 1))
        terminal.feed(Array("\u{1B})0\u{0E}\u{1B}7\u{0F}\u{1B})B\u{1B}8q".utf8))

        #expect(terminal.screenText == "\u{2500}     ")
        expectValidGrid(terminal)
    }

    @Test("the 1049 round trip gives the shell back the charset it had")
    func alternateScreenRoundTripRestoresCharset() throws {
        // Intent: a full-screen program that enters and leaves the alternate screen leaves the
        //   shell's designations exactly as it found them.
        // Why it exists: 1049 saves and restores the cursor, and charset state rides that slot,
        //   so a per-screen or reset-on-switch implementation would leave the shell drawing
        //   lines after vim exits.
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("\u{1B}(0\u{1B}[?1049h".utf8))
        terminal.feed(Array("\u{1B}(Bq\u{1B}[?1049lq".utf8))

        #expect(terminal.screenText.hasPrefix("\u{2500}     "))
        expectValidGrid(terminal)
    }

    @Test("live charset state survives a 1047 switch in both directions")
    func rawAlternateScreenSwitchKeepsLiveCharset() throws {
        // Intent: `CSI ?1047h` and `CSI ?1047l` save and restore nothing, so the charset a
        //   program invoked before entering is still invoked inside, and a change made inside
        //   is still in force after leaving.
        // Why it exists: this is what separates terminal-scoped live state from per-screen
        //   storage. The 1049 test cannot see the difference, because 1049 restores the slot.
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("\u{1B}(0\u{1B}[?1047hq".utf8))
        #expect(terminal.screenText.hasPrefix("\u{2500}     "))

        terminal.feed(Array("\u{1B}(B\u{1B}[?1047l\u{1B}[Hq".utf8))
        #expect(terminal.screenText.hasPrefix("q     "))
        expectValidGrid(terminal)
    }

    @Test("RIS and DECSTR both put every slot back to ASCII")
    func resetsRestoreASCII() throws {
        for reset in ["\u{1B}c", "\u{1B}[!p"] {
            var terminal = try #require(Terminal(columns: 4, rows: 1))
            terminal.feed(Array("\u{1B}(0".utf8))
            terminal.feed(Array(reset.utf8))
            terminal.feed(Array("q".utf8))

            #expect(terminal.screenText == "q   ", "\(reset.debugDescription) left GL translating")
            expectValidGrid(terminal)
        }
    }

    @Test("an unrecognized designation designates ASCII rather than leaving the slot stale")
    func unrecognizedDesignationsFallBackToASCII() throws {
        // Intent: an unknown final and an extra intermediate both clear the slot to ASCII.
        // Why it exists: a program that designates a set DanTerm does not have expects its own
        //   glyphs, not the previous set's. Leaving the slot stale turns every later GL byte
        //   into history-dependent line-drawing garbage; ASCII is at least deterministic.
        for designation in ["\u{1B}(K", "\u{1B}(%5"] {
            var terminal = try #require(Terminal(columns: 4, rows: 1))
            terminal.feed(Array("\u{1B}(0".utf8))
            terminal.feed(Array(designation.utf8))
            terminal.feed(Array("q".utf8))

            #expect(
                terminal.screenText == "q   ",
                "\(designation.debugDescription) left the stale designation in place"
            )
            expectValidGrid(terminal)
        }
    }

    @Test("the GR locking shifts print nothing and leave GL alone")
    func rightHalfInvocationsAreInert() throws {
        // Intent: LS1R, LS2R, and LS3R are recognized escape finals that change no state.
        // Why it exists: DanTerm is UTF-8 only, so there is no byte path a GR bank could ever
        //   be observed through. These must stay absorbed rather than becoming printed text.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("\u{1B}(0\u{1B}~\u{1B}}\u{1B}|q".utf8))

        #expect(terminal.screenText == "\u{2500}   ")
        expectValidGrid(terminal)
    }

    @Test("REP repeats the translated glyph rather than translating it twice")
    func repeatUsesAlreadyTranslatedScalars() throws {
        // Intent: `ESC ( 0` `q` `CSI b` fills two cells with the same box glyph.
        // Why it exists: REP re-feeds stored cell scalars through the print path. If
        //   translation lived there instead of at the GL byte boundary, the repeat would
        //   translate an already-translated scalar.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("\u{1B}(0q\u{1B}[b".utf8))

        #expect(terminal.screenText == "\u{2500}\u{2500}  ")
        expectValidGrid(terminal)
    }

    @Test("charset traffic does not close an open grapheme cluster")
    func openClusterSurvivesCharsetTraffic() throws {
        // Intent: designations, locking shifts, and an armed single shift all consume no cell,
        //   so a combining mark that arrives after them still joins the cell before them.
        // Why it exists: `sgr0=\E(B\E[m` emits a designation on every attribute reset, so
        //   closing the cluster there would split ordinary accented output into two cells.
        //   The single-shift case also states where the shift is spent: a mark that joins an
        //   existing cell writes no cell of its own and leaves the shift armed for the next
        //   character that does.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("a\u{1B}(0\u{0E}\u{0F}\u{0301}".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["a", "\u{0301}"])

        var shifted = try #require(Terminal(columns: 4, rows: 1))
        shifted.feed(Array("\u{1B}+0a\u{1B}O\u{0301}q".utf8))
        #expect(shifted.cell(row: 0, column: 0)?.scalars == ["a", "\u{0301}"])
        #expect(shifted.cell(row: 0, column: 1)?.scalars == ["\u{2500}"])
        expectValidGrid(shifted)
    }

    @Test("charset traffic does not disturb a latched pending wrap")
    func pendingWrapSurvivesCharsetTraffic() throws {
        // Intent: designations and locking shifts consume no cell, so a wrap latched at the
        //   right margin is still latched afterwards and the next GL byte wraps and translates.
        // Why it exists: `sgr0=\E(B\E[m` puts a designation into every attribute reset, so
        //   clearing the latch on designation would break wrapping in ordinary ncurses output.
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        terminal.feed(Array("\u{1B}(0qqq".utf8))
        #expect(terminal.geometry.cursor?.isPendingWrap == true)

        terminal.feed(Array("\u{1B}(B\u{1B}(0\u{0E}\u{0F}".utf8))
        #expect(terminal.geometry.cursor?.isPendingWrap == true)

        terminal.feed(Array("q".utf8))
        #expect(terminal.screenText == "\u{2500}\u{2500}\u{2500}\n\u{2500}  ")
        expectValidGrid(terminal)
    }
}
