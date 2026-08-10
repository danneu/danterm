// Pins the behavior that a round of Terminal.swift refactors must not move: strict
// UTF-8 admission on every OSC payload that reaches a `String`, and the shared
// hyperlink-metadata admission arithmetic that hover, arm, and OSC 8 all price against.
// These are characterization tests -- they assert contracts that already hold, so a
// later consolidation of the duplicated spellings cannot quietly change a reject into
// an accept. Behavior owned elsewhere (OSC grammar, hover anchoring, eviction) stays in
// the suites that own it; only the invariants those refactors put at risk live here.
import Testing

@testable import TerminalCore

/// Guards the strict-UTF-8 gate shared by every OSC payload that becomes a `String`.
@Suite("Terminal OSC strict UTF-8 admission")
struct TerminalOSCStrictUTF8Tests {
    @Test("OSC title rejects an invalid UTF-8 value and leaves the previous title standing")
    func titleRejectsInvalidUTF8() throws {
        // Intent: an OSC 0/2 payload that is not valid UTF-8 emits no title event.
        // Why it exists: the title decode is one of several sites spelling "decode only
        //   if valid" by hand; a consolidation that used a lossy decode would silently
        //   start reporting U+FFFD-laden titles to the embedder.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("\u{1B}]2;good\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.title("good")])

        terminal.feed([0x1B, 0x5D] + Array("2;bad".utf8) + [0xFF, 0x07])
        #expect(terminal.drainSemanticEvents().isEmpty)
    }

    @Test("OSC 777 notification rejects invalid UTF-8 in either the title or the body")
    func notificationRejectsInvalidUTF8() throws {
        // Intent: both notification halves are decoded strictly, and either one failing
        //   drops the whole event rather than emitting a half-decoded notification.
        // Why it exists: title and body are decoded by two separate calls, so a change
        //   that relaxed one of them would leave an asymmetry no other test would catch.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed([0x1B, 0x5D] + Array("777;notify;t".utf8) + [0xFF] + Array(";body".utf8) + [0x07])
        #expect(terminal.drainSemanticEvents().isEmpty)

        terminal.feed([0x1B, 0x5D] + Array("777;notify;title;b".utf8) + [0xFF, 0x07])
        #expect(terminal.drainSemanticEvents().isEmpty)

        terminal.feed(Array("\u{1B}]777;notify;title;body\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [
            .desktopNotification(title: "title", body: "body"),
        ])
    }

    @Test("OSC 7 rejects a URI whose host or percent-decoded path is not valid UTF-8")
    func workingDirectoryRejectsInvalidUTF8() throws {
        // Intent: the host and the percent-decoded path are each admitted only when they
        //   decode as valid UTF-8, so no working directory is reported from either.
        // Why it exists: `%FF` is the only route by which a well-formed OSC 7 sequence
        //   carries a byte no UTF-8 string can hold, and the path decode is the one call
        //   standing between it and a lossily-substituted directory the app would spawn in.
        var terminal = try #require(Terminal(columns: 20, rows: 2, machineHostname: "mac"))
        terminal.feed(Array("\u{1B}]7;file://mac/tmp/%FF\u{7}".utf8))
        #expect(terminal.drainSemanticEvents().isEmpty)

        terminal.feed([0x1B, 0x5D] + Array("7;file://m".utf8) + [0xFF] + Array("/tmp\u{7}".utf8))
        #expect(terminal.drainSemanticEvents().isEmpty)

        terminal.feed(Array("\u{1B}]7;file://mac/tmp/%20ok\u{7}".utf8))
        #expect(terminal.drainSemanticEvents() == [.workingDirectory("/tmp/ ok")])
    }

    @Test("OSC 52 rejects a base64 payload that decodes to invalid UTF-8")
    func clipboardWriteRejectsInvalidUTF8() throws {
        // Intent: base64 that decodes to bytes no UTF-8 string can hold produces no
        //   clipboard write at all.
        // Why it exists: OSC 52 is the one path where a remote process controls raw bytes
        //   destined for the system pasteboard, so a lossy decode would hand the user
        //   replacement characters instead of refusing the write.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("\u{1B}]52;c;/w==\u{7}".utf8))
        #expect(terminal.drainPendingClipboardWrite() == nil)

        terminal.feed(Array("\u{1B}]52;c;aGk=\u{7}".utf8))
        #expect(terminal.drainPendingClipboardWrite() == "hi")
    }
}

/// Guards the shared hyperlink admission arithmetic that hover, arm, and OSC 8 price against.
@Suite("Terminal hyperlink admission arithmetic")
struct TerminalHyperlinkAdmissionArithmeticTests {
    @Test("arming reclaims dead targets and then admits, matching its own admission check")
    func armReclaimsBeforeAdmitting() throws {
        // Intent: `setArmedLink` and `canAdmitArmedLink` agree, and an over-cap arm is
        //   admitted only after the dead OSC 8 targets are swept out of the table.
        // Why it exists: the arm path prices the retained table, the hover slot, and the
        //   semantic-event budget together, then reclaims and re-prices. Folding those two
        //   spellings into one helper must not change which arms are refused, nor leave
        //   the reclaimed table unstored when the arm succeeds.
        var terminal = try #require(Terminal(columns: 70_000, rows: 1))
        let retainedLength = 61_500
        for index in 0..<4 {
            let prefix = "https://\(index).test/"
            let uri = prefix + String(repeating: "a", count: retainedLength - prefix.utf8.count)
            terminal.feed(Array("\u{1B}]8;;\(uri)\u{7}x".utf8))
        }
        terminal.feed(Array("\u{1B}]8;;\u{7}".utf8))
        let detectedURI = "https://detected.test/"
            + String(repeating: "b", count: 65_536 - "https://detected.test/".utf8.count)
        terminal.feed(Array((" " + detectedURI).utf8))
        let detected = try #require(terminal.activatableLink(at: .init(row: 0, column: 10)))

        #expect(terminal.canAdmitArmedLink(detected) == false)
        let refused = terminal.setArmedLink(detected)
        #expect(refused == false)
        #expect(terminal.armedLink == nil)
        #expect(terminal.retainedHyperlinkMetadataBytes == 4 * retainedLength)

        // Overwrite the cells holding the first two targets so a reclaim can drop them.
        terminal.feed(Array("\u{1B}[1;1Hyz".utf8))

        #expect(terminal.canAdmitArmedLink(detected))
        let armed = terminal.setArmedLink(detected)
        #expect(armed)
        #expect(terminal.armedLink == detected)
        #expect(terminal.retainedHyperlinkMetadataBytes <= 256 * 1_024)
    }
}
