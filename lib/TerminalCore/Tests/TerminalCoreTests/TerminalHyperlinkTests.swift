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

    @Test("OSC 8 is terminator- and chunk-invariant")
    func terminatorAndChunkInvariance() {
        let bodies = [
            Array("\u{1B}]8;;https://example.com\u{7}x".utf8),
            Array("\u{1B}]8;;https://example.com\u{1B}\\x".utf8),
            [0x1B, 0x5D] + Array("8;;https://example.com".utf8) + [0x9C, 0x78],
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
        // Scenario: a pane sits just below 1 MiB, one old cell is overwritten, and another
        //   maximum-sized target arrives before enough dead metadata exists to admit it.
        var terminal = Terminal(columns: 20, rows: 1)!
        let retainedLength = 61_500
        for index in 0..<17 {
            let prefix = "https://\(index).test/"
            terminal.feed(osc8(uri: prefix + String(repeating: "a", count: retainedLength - prefix.utf8.count)))
            terminal.feed(Array("x".utf8))
        }
        #expect(terminal.retainedHyperlinkMetadataBytes == 17 * retainedLength)

        terminal.feed(osc8(uri: ""))
        terminal.feed(Array("\u{1B}[1;1Hy".utf8))
        let baseline = terminal
        let maximum = "https://candidate.test/"
            + String(repeating: "b", count: 65_536 - "https://candidate.test/".utf8.count)
        terminal.feed(osc8(uri: maximum))
        #expect(terminal == baseline)

        terminal.feed(Array("\u{1B}[1;2Hz".utf8))
        terminal.feed(osc8(uri: maximum))
        #expect(terminal.retainedHyperlinkCount == 16)
        #expect(terminal.retainedHyperlinkMetadataBytes <= 1_048_576)
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

        terminal.feed(osc8(uri: "https://reset.test"))
        terminal.feed(Array("x\u{1B}[!py".utf8))
        #expect(terminal.cell(row: 0, column: 5)?.hyperlink != nil)
        #expect(terminal.cell(row: 0, column: 6)?.hyperlink == nil)
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
        var terminal = Terminal(columns: 5, rows: 2, scrollbackBudgetBytes: 400)!
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
