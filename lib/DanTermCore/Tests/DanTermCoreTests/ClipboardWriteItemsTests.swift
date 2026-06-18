// Swift Testing coverage for pure clipboard-write item normalization. The tests
// pin MIME filtering, deduplication, and empty-data handling before AppKit maps
// items onto concrete pasteboard types.
import Testing

@testable import DanTermCore

@Suite struct ClipboardWriteItemsTests {
    @Test("mixed clipboard write keeps plain and html in order")
    func mixedPreservesBothInOrder() {
        // Intent: mixed clipboard writes preserve both the plain and html
        //   payloads in the order Ghostty supplies them.
        // Why it exists: pins the core normalization contract that lets the
        //   AppKit writer declare both pasteboard types for rich-text targets.
        // Scenario: spec-first; Cmd-C/copy-on-select emit text/plain followed
        //   by text/html, and both must reach the write surface unchanged.
        let items = [
            ClipboardWriteItem(mime: "text/plain", data: "hi"),
            ClipboardWriteItem(mime: "text/html", data: "<b>hi</b>"),
        ]

        #expect(clipboardItemsToWrite(items) == items)
    }

    @Test("html-only clipboard write is kept")
    func htmlOnlyIsKept() {
        // Intent: normalization keeps html-only payloads rather than treating
        //   text/plain as required.
        // Why it exists: guards the bug where explicit copy_to_clipboard:html
        //   silently vanished before the AppKit layer saw it.
        // Scenario: spec-first; a user binds an html-only copy action and the
        //   single text/html item must be written as rich clipboard content.
        let items = [ClipboardWriteItem(mime: "text/html", data: "<b>x</b>")]

        #expect(clipboardItemsToWrite(items) == items)
    }

    @Test("empty data is preserved for OSC-52 clear")
    func emptyDataIsPreserved() {
        // Intent: a text/plain item with empty data survives normalization.
        // Why it exists: OSC-52 clear writes an empty text/plain payload; if
        //   this layer drops it, stale clipboard contents remain.
        // Scenario: a terminal sends OSC-52 clear (`52;;`), which must become
        //   an empty .string write in the AppKit layer.
        let items = [ClipboardWriteItem(mime: "text/plain", data: "")]

        #expect(clipboardItemsToWrite(items) == items)
    }

    @Test("empty MIME is dropped")
    func emptyMimeIsDropped() {
        let items = [ClipboardWriteItem(mime: "", data: "data")]

        #expect(clipboardItemsToWrite(items).isEmpty)
    }

    @Test("duplicate MIME keeps first item")
    func duplicateMimeKeepsFirst() {
        // Intent: duplicate MIME entries are deterministic: the first payload
        //   wins and later duplicates are ignored.
        // Why it exists: Ghostty should emit one item per MIME in practice, but
        //   defensive normalization must not let duplicate order change writes.
        // Scenario: a malformed content array supplies two text/plain entries;
        //   DanTerm writes the first one and ignores the duplicate.
        let items = [
            ClipboardWriteItem(mime: "text/plain", data: "A"),
            ClipboardWriteItem(mime: "text/plain", data: "B"),
        ]

        #expect(clipboardItemsToWrite(items) == [ClipboardWriteItem(mime: "text/plain", data: "A")])
    }

    @Test("empty clipboard write input stays empty")
    func emptyInputStaysEmpty() {
        #expect(clipboardItemsToWrite([]).isEmpty)
    }
}
