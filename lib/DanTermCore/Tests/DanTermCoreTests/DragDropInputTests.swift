// Swift Testing migration of the legacy `tests/DragDropInputTests.swift`
// harness suite. Pins `DragDropInput.shellQuote` and
// `DragDropInput.buildContent`'s priority + quoting + empty-input rules
// against the matrix the legacy suite asserted.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct DragDropInputTests {
    @Test("shellQuote: simple path")
    func shellQuoteSimplePath() {
        // Intent: a path with no special chars wraps in single quotes.
        // Why it exists: pins the baseline single-quote wrap so a refactor to
        //   shell-escape via backslashes does not regress the simple case.
        // Scenario: spec-first quoting check -- the user drops "/path/to/file"
        //   and the terminal receives the safely-quoted form.
        #expect(DragDropInput.shellQuote("/path/to/file") == "'/path/to/file'")
    }

    @Test("shellQuote: path with spaces")
    func shellQuotePathWithSpaces() {
        // Intent: spaces inside the path stay literal inside single quotes.
        // Why it exists: pins single-quote behavior for the common spaces-
        //   in-filename case so the shell does not word-split it.
        // Scenario: spec-first quoting check -- a Finder drag of a file with
        //   spaces lands as one argument to the shell.
        #expect(DragDropInput.shellQuote("/path/to/my file.png") == "'/path/to/my file.png'")
    }

    @Test("shellQuote: path with embedded single quote")
    func shellQuotePathWithEmbeddedSingleQuote() {
        // Intent: an apostrophe inside the path is escaped via the canonical
        //   POSIX `'\''` close-quote / escaped-quote / open-quote dance.
        // Why it exists: pins the embedded-quote escape so paths like
        //   "/path/to/it's here" survive a single-quoted shell argument.
        // Scenario: spec-first quoting check -- a drag of a file whose name
        //   contains an apostrophe must remain one shell token.
        #expect(DragDropInput.shellQuote("/path/to/it's here") == "'/path/to/it'\\''s here'")
    }

    @Test("buildContent: single file path")
    func buildContentSingleFilePath() {
        // Intent: one file path is shell-quoted into the assembled content.
        // Why it exists: pins the single-file happy path that the input
        //   bridge feeds verbatim to the running shell.
        // Scenario: spec-first content check -- a drag of a single file is
        //   inserted at the cursor as a quoted shell token.
        let result = DragDropInput.buildContent(filePaths: ["/path/to/my file.png"], urlString: nil, plainString: nil)
        #expect(result == "'/path/to/my file.png'")
    }

    @Test("buildContent: multiple file paths")
    func buildContentMultipleFilePaths() {
        // Intent: multiple file paths quote individually and join with single
        //   spaces in declared order.
        // Why it exists: pins the join order and separator so a multi-select
        //   drag becomes a deterministic shell argument list.
        // Scenario: spec-first content check -- a Finder multi-select drag.
        let result = DragDropInput.buildContent(filePaths: ["/a/b", "/c/d"], urlString: nil, plainString: nil)
        #expect(result == "'/a/b' '/c/d'")
    }

    @Test("buildContent: file paths take priority over urlString and plainString")
    func buildContentFilePathsTakePriorityOverURLAndPlain() {
        // Intent: when filePaths is non-empty, urlString and plainString are
        //   ignored entirely.
        // Why it exists: pins the priority order so a mixed pasteboard (e.g.
        //   Finder drag carrying both file + URL representations) does not
        //   produce a duplicated or wrong-representation insertion.
        // Scenario: spec-first priority check -- a Finder drag arrives with
        //   filePaths, urlString, AND plainString; the file wins.
        let result = DragDropInput.buildContent(filePaths: ["/a/b"], urlString: "https://example.com", plainString: "hello")
        #expect(result == "'/a/b'")
    }

    @Test("buildContent: non-file URL string")
    func buildContentNonFileURLString() {
        // Intent: when filePaths is empty, the URL string is shell-quoted as
        //   the inserted content.
        // Why it exists: pins the URL fallback so a browser-link drag still
        //   becomes a safe terminal token.
        // Scenario: spec-first fallback check -- a drag of a URL (no file
        //   representation) lands as a single quoted argument.
        let result = DragDropInput.buildContent(filePaths: [], urlString: "https://example.com", plainString: nil)
        #expect(result == "'https://example.com'")
    }

    @Test("buildContent: plain string passthrough unquoted")
    func buildContentPlainStringPassthroughUnquoted() {
        // Intent: when filePaths and urlString are unavailable, the plain
        //   string passes through verbatim (NOT quoted).
        // Why it exists: pins the "text drop = literal text" convention so a
        //   user dragging in a snippet does not get spurious quotes inserted.
        // Scenario: spec-first text-drop check -- a drag of plain "hello
        //   world" inserts as raw text at the cursor.
        let result = DragDropInput.buildContent(filePaths: [], urlString: nil, plainString: "hello world")
        #expect(result == "hello world")
    }

    @Test("buildContent: all inputs empty/nil returns nil")
    func buildContentAllInputsEmptyOrNilReturnsNil() {
        // Intent: with no usable representation (all nil / empty / whitespace
        //   only), the resolver returns nil so the caller skips insertion.
        // Why it exists: pins the no-op guard so an empty pasteboard cannot
        //   silently produce an empty inserted token.
        // Scenario: spec-first guard check -- three flavors of "nothing
        //   usable" all collapse to nil.
        #expect(DragDropInput.buildContent(filePaths: [], urlString: nil, plainString: nil) == nil)
        #expect(DragDropInput.buildContent(filePaths: [], urlString: "", plainString: "") == nil)
        #expect(DragDropInput.buildContent(filePaths: [], urlString: "  ", plainString: "  ") == nil)
    }

    @Test("buildContent: empty-string file paths filtered out")
    func buildContentEmptyStringFilePathsFilteredOut() {
        // Intent: empty / whitespace-only entries in filePaths are filtered
        //   before priority resolution; if no real path remains, the URL
        //   string fallback takes over.
        // Why it exists: pins the filtering of stray-empty filePaths entries
        //   that some pasteboard sources include alongside real data.
        // Scenario: spec-first filtering check -- a pasteboard reports two
        //   empty filePaths plus a real URL; the URL must be inserted.
        let result = DragDropInput.buildContent(filePaths: ["", "  "], urlString: "https://example.com", plainString: nil)
        #expect(result == "'https://example.com'")
    }
}
