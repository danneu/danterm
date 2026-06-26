// Pins `resolveOpenUrl`, the pure scheme-vs-file-path decision behind DanTerm's
// native cmd-click link opener (the GHOSTTY_ACTION_OPEN_URL handler). The
// bug-prone case is #8763: a schemeless absolute path like `/Users/x/f.txt`
// must resolve to a file URL, not a schemeless web URL. Assertions are on the
// returned `URL` value (behavioral, AppKit-free), so the runtime side effect
// (NSWorkspace.open) stays out of scope. Mirrors `ScrollbarMathTests` structure.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UrlResolutionTests {
    @Test("resolveOpenUrl: an http(s) URL with a scheme is returned verbatim")
    func httpUrlWithSchemeReturnedVerbatim() {
        // Intent: a raw string that parses as a URL with a scheme is handed
        //   back unchanged, never reinterpreted as a file path.
        // Why it exists: pins the primary user scenario (cmd-clicking a web
        //   link) so a refactor of the file-path branch can't swallow real URLs.
        // Scenario: spec-first happy path -- the user cmd-clicks `https://...`
        //   in a pane and that exact URL must reach the browser.
        let result = resolveOpenUrl("https://example.com/path", home: "/Users/test")
        #expect(result == URL(string: "https://example.com/path"))
    }

    @Test("resolveOpenUrl: a schemeless absolute path becomes a file URL")
    func schemelessAbsolutePathBecomesFileUrl() {
        // Intent: a schemeless absolute path resolves to a file URL, not a
        //   schemeless web URL.
        // Why it exists: pins the Ghostty issue #8763 contract -- the subtle
        //   bug where `/Users/x/f.txt` is mistaken for a schemeless URL and
        //   never opens as a file.
        // Scenario: spec-first #8763 case -- the user cmd-clicks a printed
        //   absolute path and it must open in the file's default app.
        let result = resolveOpenUrl("/Users/test/file.txt", home: "/Users/test")
        #expect(result == URL(filePath: "/Users/test/file.txt"))
        #expect(result.isFileURL)
    }

    @Test("resolveOpenUrl: a ~-prefixed path expands against the injected home")
    func tildePathExpandsAgainstInjectedHome() {
        // Intent: a leading `~` expands against the injected `home`, producing
        //   a file URL rooted at that home.
        // Why it exists: proves `home` is injected (deterministic), not read
        //   ambiently -- the determinism-seam guarantee the pure core depends on.
        // Scenario: spec-first expansion case -- the user cmd-clicks `~/notes.md`
        //   and it must open the file under their home directory.
        let result = resolveOpenUrl("~/notes.md", home: "/Users/test")
        #expect(result == URL(filePath: "/Users/test/notes.md"))
    }

    @Test("resolveOpenUrl: a schemeless path with a space falls to a file URL")
    func schemelessPathWithSpaceFallsToFileUrl() {
        // Intent: a schemeless path containing a space resolves to a file URL.
        // Why it exists: pins that the `scheme != nil` guard -- not a `nil`
        //   parse -- is what routes bare paths to `URL(filePath:)`. `URL(string:)`
        //   does not return nil here; it parses the path as a *schemeless* URL
        //   (scheme nil), and the guard is what catches it.
        // Scenario: spec-first edge case -- the user cmd-clicks a path with a
        //   space in it and it must still open as a file.
        let result = resolveOpenUrl("/Users/test/my file.txt", home: "/Users/test")
        #expect(result.isFileURL)
    }
}
