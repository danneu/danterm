// The host half of link opening: turning a URI the terminal has already approved into a `URL`
// AppKit can hand to the workspace. Whether a link may be opened at all is not decided here.
import Foundation
// The UI suite has no TerminalCore module; it compiles the engine's own
// ActivatableWebURI.swift in directly, so the gate below is the real one there
// too and not a stub.
#if !DANTERM_UI_TEST
import TerminalCore
#endif

/// Converts an activation-approved URI into an openable `URL`, and refuses everything the
/// terminal did not approve.
///
/// This is a converter, not a second policy, and the distinction is the reason it exists as its
/// own named function. `TerminalCore.isActivatableWebURI` is the only place link activation is
/// decided; when the host re-derived that rule against Foundation's character sets it reached a
/// stricter answer, so a link the terminal had drawn, given a pointing-hand cursor, previewed,
/// and armed on Cmd-press would then open nothing at all, with no error and no log. Foundation
/// appears here only to percent-encode the visible non-ASCII text the gate allows through.
func openableWebURL(_ uri: String) -> URL? {
    guard isActivatableWebURI(uri) else { return nil }
    return URLComponents(string: uri)?.url
}
