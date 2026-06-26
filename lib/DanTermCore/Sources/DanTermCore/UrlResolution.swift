// Pure resolution of a raw open-url string (from libghostty's OPEN_URL action)
// into the URL to hand to NSWorkspace. Split out so the scheme-vs-file-path
// decision -- the bug-prone part (Ghostty issue #8763) -- is unit-testable
// without AppKit. The side effect (opening) stays in the runtime.
import Foundation

/// Resolve a raw link string into a URL. If it parses as a URL with a scheme,
/// use it verbatim; otherwise treat it as a (possibly `~`-prefixed) file path.
/// `home` is injected (not read ambiently) so tests assert a fixed expansion.
func resolveOpenUrl(_ raw: String, home: String) -> URL {
    if let candidate = URL(string: raw), candidate.scheme != nil {
        return candidate
    }
    return URL(filePath: expandTilde(raw, home: home))
}
