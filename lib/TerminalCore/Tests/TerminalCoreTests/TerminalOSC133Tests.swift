// OSC 133 semantic-prompt parsing, row stamping, and shell redraw resize proofs.
import Testing

@testable import TerminalCore

/// Locks shell semantic-prompt state to the resize behavior that consumes it.
struct TerminalOSC133Tests {
    @Test("interleaved prompt repaints do not accumulate a resize staircase")
    func resizeSweepKeepsOnePrompt() throws {
        // Intent: prove repeated resize and shell repaint cycles converge to one prompt.
        // Why it exists: without pre-reflow OSC 133 clearing, every cycle strands an
        //   old soft-wrapped prompt head and grows one giant logical line.
        // Scenario: zsh repaints its two-line prompt after every width change while a
        //   neighboring split animates open and closed.
        var terminal = try #require(Terminal(columns: 12, rows: 5))
        let prompt = "ABCDEFGHIJKL\r\n> "
        terminal.feed(Array("\u{1B}]133;A\u{7}\(prompt)\u{1B}]133;B\u{7}".utf8))

        for width in [11, 10, 9, 10, 11, 12] {
            terminal.resize(columns: width, rows: 5)
            terminal.feed(Array("\r\r\u{1B}[A\u{1B}[K\u{1B}]133;A\u{7}\(prompt)\u{1B}]133;B\u{7}\u{1B}[J".utf8))
            #expect(terminal.fullHistoryText.components(separatedBy: "ABCDEFGHIJKL").count - 1 == 1)
            expectValidGrid(terminal)
        }
    }

    @Test("OSC 133 grammar is atomic while options are lenient")
    func grammarAndOptions() throws {
        var valid = try #require(Terminal(columns: 8, rows: 3))
        valid.feed(Array("old\u{1B}]133;A;future=x\u{7}prompt\u{1B}]133;B;redraw=0\u{7}input".utf8))
        valid.resize(columns: 9, rows: 3)
        #expect(valid.screenText.contains("old"))
        #expect(valid.screenText.contains("promptinput") == false)

        for malformed in ["Aextra", "L;", "L;aid=x", "Z"] {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            terminal.feed(Array("text\u{1B}]133;\(malformed)\u{7}tail".utf8))
            let control = terminal
            terminal.resize(columns: 9, rows: 3)
            var expected = control
            expected.resize(columns: 9, rows: 3)
            #expect(terminal == expected)
        }
    }

    @Test("redraw modes scope prompt clearing and absent redraw preserves the mode")
    func redrawModes() throws {
        var full = try #require(Terminal(columns: 10, rows: 4))
        full.feed(Array("output\r\n\u{1B}]133;A\u{7}> one\r\n\u{1B}]133;P;k=s\u{7}> two\u{1B}]133;B\u{7}".utf8))
        let cursor = full.geometry.cursor
        full.resize(columns: 12, rows: 4)
        #expect(full.screenText.hasPrefix("output"))
        #expect(full.screenText.contains("> one") == false)
        #expect(full.screenText.contains("> two") == false)
        #expect(full.geometry.cursor == cursor.map { TerminalCursor(row: $0.row, column: $0.column, isPendingWrap: $0.isPendingWrap) })

        var last = try #require(Terminal(columns: 10, rows: 4))
        last.feed(Array("\u{1B}]133;A;redraw=last\u{7}> one\r\n\u{1B}]133;P;k=s\u{7}> two\u{1B}]133;B\u{7}".utf8))
        last.resize(columns: 12, rows: 4)
        #expect(last.screenText.contains("> one"))
        #expect(last.screenText.contains("> two") == false)

        var disabled = try #require(Terminal(columns: 10, rows: 3))
        disabled.feed(Array("\u{1B}]133;A;redraw=0\u{7}> prompt\u{1B}]133;B\u{7}\u{1B}[!p".utf8))
        disabled.resize(columns: 12, rows: 3)
        #expect(disabled.screenText.contains("> prompt"))

        disabled.feed(Array("\u{1B}]133;A;redraw=1\u{7}> new\u{1B}]133;B\u{7}".utf8))
        disabled.resize(columns: 13, rows: 3)
        #expect(disabled.screenText.contains("> new") == false)
    }

    @Test("input newline semantics and alternate-screen ownership survive resize")
    func lineAndAlternateScreenState() throws {
        var clearsAtEnd = try #require(Terminal(columns: 8, rows: 3))
        clearsAtEnd.feed(Array("\u{1B}]133;A\u{7}> \u{1B}]133;I\u{7}cmd\r\noutput".utf8))
        clearsAtEnd.resize(columns: 10, rows: 3)
        #expect(clearsAtEnd.fullHistoryText.contains("cmd"))
        #expect(clearsAtEnd.fullHistoryText.contains("output"))

        var alternate = try #require(Terminal(columns: 8, rows: 3))
        alternate.feed(Array("\u{1B}]133;A\u{7}> prompt\u{1B}]133;B\u{7}\u{1B}[?1049halt".utf8))
        alternate.resize(columns: 10, rows: 3)
        #expect(alternate.fullHistoryText.filter { $0 != "\n" && $0 != " " }.contains("alt"))
        alternate.feed(Array("\u{1B}[?1049l".utf8))
        #expect(alternate.screenText.contains("> prompt") == false)
    }

    @Test("OSC 133 streams are chunk invariant and RIS restores prompt redraw defaults")
    func chunkAndResetLifecycle() throws {
        let bytes = Array("x\u{1B}]133;A;redraw=0;k=i;future=x\u{7}> \u{1B}]133;B\u{7}cmd\r\n\u{1B}]133;C;k=s\u{7}out".utf8)
        var whole = try #require(Terminal(columns: 9, rows: 4))
        whole.feed(bytes)
        var bytewise = try #require(Terminal(columns: 9, rows: 4))
        for byte in bytes { bytewise.feed([byte]) }
        #expect(whole == bytewise)

        var reset = try #require(Terminal(columns: 9, rows: 3))
        reset.feed(Array("\u{1B}]133;A;redraw=0\u{7}> old\u{1B}c\u{1B}]133;A\u{7}> new\u{1B}]133;B\u{7}".utf8))
        reset.resize(columns: 10, rows: 3)
        #expect(reset.screenText.contains("> new") == false)
    }

    @Test("prompt actions stamp rows and lifecycle operations retain only intended state")
    func actionAndMarkerLifecycle() throws {
        var fresh = try #require(Terminal(columns: 8, rows: 4))
        fresh.feed(Array("prefix\u{1B}]133;A\u{7}> ".utf8))
        #expect(fresh.screenText.hasPrefix("prefix  \n> "))
        let row = fresh.geometry.cursor?.row
        fresh.feed(Array("\r\u{1B}]133;A\u{7}".utf8))
        #expect(fresh.geometry.cursor?.row == row)
        fresh.feed(Array("x\u{1B}]133;L\u{7}".utf8))
        #expect(fresh.geometry.cursor?.row == row.map { $0 + 1 })
        fresh.feed(Array("x\u{1B}]133;N\u{7}".utf8))
        #expect(fresh.geometry.cursor?.row == row.map { $0 + 2 })

        var explicit = try #require(Terminal(columns: 8, rows: 4))
        explicit.feed(Array("\u{1B}]133;A\u{7}> \u{1B}]133;B\u{7}one\r\ntwo".utf8))
        explicit.resize(columns: 9, rows: 4)
        #expect(explicit.fullHistoryText.contains("one") == false)
        #expect(explicit.fullHistoryText.contains("two") == false)

        var endOfLine = try #require(Terminal(columns: 8, rows: 4))
        endOfLine.feed(Array("\u{1B}]133;A\u{7}> \u{1B}]133;I\u{7}one\r\ntwo".utf8))
        endOfLine.resize(columns: 9, rows: 4)
        #expect(endOfLine.fullHistoryText.contains("two"))

        var fish = try #require(Terminal(columns: 8, rows: 3))
        fish.feed(Array("\u{1B}]133;A\u{7}> old\r\u{1B}]133;C;k=s\u{7}\u{1B}]133;B\u{7}kept".utf8))
        fish.resize(columns: 9, rows: 3)
        #expect(fish.fullHistoryText.contains("kept"))

        var ended = try #require(Terminal(columns: 8, rows: 3))
        ended.feed(Array("\u{1B}]133;A\u{7}> \u{1B}]133;B\u{7}cmd\u{1B}]133;D;7\u{7}".utf8))
        let endedControl = ended
        ended.resize(columns: 9, rows: 3)
        var expectedEnded = endedControl
        expectedEnded.feed(Array("\u{1B}]133;C\u{7}".utf8))
        expectedEnded.resize(columns: 9, rows: 3)
        #expect(ended.screenText == expectedEnded.screenText)

        var carried = try #require(Terminal(columns: 8, rows: 3))
        carried.feed(Array("\u{1B}]133;A\u{7}12345678\u{1B}]133;B\u{7}".utf8))
        carried.resize(columns: 6, rows: 3)
        carried.resize(columns: 10, rows: 3)
        #expect(carried.fullHistoryText.contains("12345678") == false)

        var erased = try #require(Terminal(columns: 8, rows: 3))
        erased.feed(Array("\u{1B}]133;A\u{7}> old\u{1B}]133;B\u{7}\u{1B}[2Jkept".utf8))
        erased.resize(columns: 9, rows: 3)
        #expect(erased.fullHistoryText.contains("kept"))

        var heightOnly = try #require(Terminal(columns: 8, rows: 3))
        heightOnly.feed(Array("\u{1B}]133;A\u{7}> prompt\u{1B}]133;B\u{7}".utf8))
        heightOnly.resize(columns: 8, rows: 4)
        #expect(heightOnly.fullHistoryText.contains("> prompt") == false)
    }
}
