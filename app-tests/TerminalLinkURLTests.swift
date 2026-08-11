// Proves the terminal's link-activation gate and the host's URL conversion agree: everything
// the terminal offers as a link can actually be opened. This test lives here rather than beside
// either half because it is the only target that compiles both -- `TerminalCore`'s activation
// gate and the app's Foundation conversion -- and the claim is about the two of them agreeing.
import Foundation
import Testing
import TerminalCore

@testable import DanTerm

/// Pins that link activation is decided in exactly one place, so a hovered link always opens.
struct TerminalLinkURLTests {
    // Intent: every URI the activation gate approves converts to a URL, and every URI it
    //   rejects converts to nothing.
    // Why it exists: the host used to re-derive activation with Foundation's character sets and
    //   land somewhere stricter than the gate. The two only disagreed on inputs no test covered
    //   -- invisible scalars outside the authority -- and the disagreement was silent by
    //   construction: the terminal drew the link, hovered it, armed it on Cmd-press, and then
    //   `openLink` returned early, so a click did nothing and reported nothing.
    // Scenario: hovering a link whose path holds a zero-width space, and one whose path is
    //   ordinary Japanese text. Exactly one of them is a link, and it opens.
    @Test("every activatable URI converts to an openable URL, and no other URI does")
    func activationAndConversionAgree() {
        let activatable = [
            "http://example.com",
            "https://example.com/",
            "HTTP://example.com",
            "Https://user@example.com:443/a?b=c#d",
            "http://[::1]:8080/",
            "http://[v7.aa]/x",
            "https://ja.wikipedia.org/wiki/日本語",
            "https://example.com/emoji/🐈",
            "https://example.com/a%20b?q=1#f",
            "https://example.com/x;y",
        ]
        for uri in activatable {
            #expect(isActivatableWebURI(uri), "gate should accept \(uri)")
            #expect(openableWebURL(uri) != nil, "gate accepted \(uri) but it does not open")
        }

        let rejected = [
            "javascript:alert(1)", "file:///tmp/a", "data:text/plain,x", "mailto:a@b.test",
            "http:/missing", "http://", "http://:80/a", "http://host:0/a",
            "http://host name/a", "http://bad%zz.test/a", "http://a@b@example.com/a",
            "https://example.com/a\u{200B}b",
            "https://example.com/?q=a\u{202E}b",
            "https://example.com/#a\u{FEFF}b",
            "https://example.com/a\u{00A0}b",
        ]
        for uri in rejected {
            #expect(isActivatableWebURI(uri) == false, "gate should reject \(uri)")
            #expect(openableWebURL(uri) == nil, "gate rejected \(uri) but it still opens")
        }
    }

    // Intent: conversion preserves the host the hover preview showed.
    // Why it exists: the preview pill is the only thing the user reads before Cmd-clicking, so
    //   the URL that reaches the workspace has to name the same site. Percent-encoding the
    //   visible non-ASCII path must not disturb the authority.
    @Test("conversion preserves the previewed host")
    func conversionPreservesHost() {
        #expect(openableWebURL("https://ja.wikipedia.org/wiki/日本語")?.host == "ja.wikipedia.org")
        #expect(openableWebURL("Https://user@example.com:443/a")?.host == "example.com")
        #expect(openableWebURL("http://[::1]:8080/")?.port == 8080)
    }
}
