# Fix: cmd-click does not open URLs (handle GHOSTTY_ACTION_OPEN_URL)

## Context

Cmd-clicking a URL in a DanTerm terminal pane does nothing. When you cmd-click a
detected link, libghostty fires the `GHOSTTY_ACTION_OPEN_URL` action (kind
`UNKNOWN`) back to the host app. DanTerm's action handler `handleAction` in
`app/GhosttyApp.swift` has no case for it, so it falls through to
`default: return false` (app/GhosttyApp.swift:497-498).

Returning `false` is not a silent no-op, though: libghostty treats an unhandled
`open_url` as "apprt declined" and runs its own cross-platform fallback --
`internal_os.open`, which spawns `open <url>` (`.text` -> `open -t <url>`) as a
child process (.ghostty-src/src/Surface.zig:4528-4548,
.ghostty-src/src/os/open.zig:35-41). Ghostty logs `apprt did not handle open URL
action, falling back to default opener` and explicitly notes that "well-behaved
apprts should handle this themselves." So the missing case means DanTerm leans on
that subprocess fallback instead of opening links app-natively.

The fix makes DanTerm the native handler for `.unknown` link opens via
`NSWorkspace.shared.open` -- the path Ghostty recommends, which does not depend on
spawning a subprocess. It returns AppKit's success result rather than a hardcoded
`true`, so a refused open still falls through to libghostty's fallback opener.

Verified around the change:

- The cmd modifier reaches libghostty: `TerminalView.mouseDown` forwards the
  left-click with mods, and `ghosttyMods` maps `.command -> GHOSTTY_MODS_SUPER`
  without stripping it (app/TerminalView.swift:273-284, 641-656).
- We handle `GHOSTTY_ACTION_MOUSE_SHAPE` (app/GhosttyApp.swift:317-320), so the
  link-hover cursor change is wired.
- No config gate disables link clicking. DanTermConfig only recognizes
  `remote-theme` and `alert-clear-mode`; all Ghostty keys pass through unchanged.
- DanTerm enables no App Sandbox (`dev-entitlements.plist` sets only
  `com.apple.security.get-task-allow`, not `com.apple.security.app-sandbox`), so
  the fallback's `open` subprocess is not blocked.

**Diagnostic caveat.** Because the fallback *should* already run `open <url>`,
the missing case alone does not fully explain why links fail to open for the
user. Before implementing, confirm the failure mode (Verification step 0): if the
"falling back to default opener" warning never appears on cmd-click, the click is
not reaching libghostty's `openUrl` at all (a different bug -- mouse routing or
link mods) and this plan must be revisited. The native handler is the right fix
wherever `openUrl` is reached, but it cannot fix a click that never gets there.

Git history shows this action was never handled (`git log -S open_url --all` is
empty); stock Ghostty handles it (`.ghostty-src/.../Ghostty.App.swift:623`).

Outcome: cmd-clicking an http(s) link opens it in the default browser; cmd-clicking
a file path opens it in its default app.

## Root cause

Missing `case GHOSTTY_ACTION_OPEN_URL:` in `handleAction`. The action struct is:

```c
typedef struct {
  ghostty_action_open_url_kind_e kind;   // UNKNOWN | TEXT | HTML
  const char* url;
  uintptr_t len;
} ghostty_action_open_url_s;
```

Cmd-clicked links -- plain links and OSC8 hyperlinks -- always arrive as kind
`UNKNOWN` (.ghostty-src/src/Surface.zig:4499-4526). `TEXT`/`HTML` are only emitted
by write-screen / open-selection actions, never by a link click. So the fix
handles `UNKNOWN` natively via `NSWorkspace.shared.open` (returning its result)
and leaves `TEXT`/`HTML` to libghostty's existing kind-specific fallback.

## The fix

Two parts, matching the project's pure-core / runtime split.

### Part 1 -- pure URL resolution (testable)

New file `lib/DanTermCore/Sources/DanTermCore/UrlResolution.swift`. Mirror
upstream's scheme-vs-filepath decision (the subtle part, guarded by Ghostty
issue #8763: a schemeless string like `/Users/x/f.txt` must be treated as a file
path, not a schemeless URL) and reuse the existing `expandTilde` helper
(lib/DanTermCore/Sources/DanTermCore/Model.swift:572) for `~` expansion:

```swift
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
```

Notes:

- `home` is a *required* parameter (no `NSHomeDirectory()` default), so the
  function reads nothing ambient and needs no `// core-purity: ambient-seam`
  marker. The runtime passes the ambient home at the call site instead.
- Purity-lint safe: `URL`, `URL(string:)`, `URL(filePath:)` are Foundation, not
  in the hard-ban list (`scripts/core-purity-lint.sh`). `URL(filePath:)` requires
  macOS 13+; deployment target is `.macOS(.v26)`.
- Reuses `expandTilde` rather than `NSString.standardizingPath`, because
  `standardizingPath` expands `~` against the ambient home (nondeterministic /
  unassertable). `expandTilde(_:home:)` does the same `~` expansion with an
  injected home.

### Part 2 -- runtime action case (side effect)

Add the case to `handleAction` in `app/GhosttyApp.swift`, just before `default:`:

```swift
case GHOSTTY_ACTION_OPEN_URL:
    let v = action.action.open_url
    // Only take over `.unknown` (cmd-clicked links / OSC8). Return false for
    // `.text`/`.html` so libghostty keeps its kind-specific fallback (`open -t`
    // for text) until DanTerm ports native handling for those kinds.
    guard v.kind == GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN else { return false }
    guard v.len > 0, let ptr = v.url,
          let raw = String(data: Data(bytes: ptr, count: Int(v.len)), encoding: .utf8),
          !raw.isEmpty
    else { return false }
    // Synchronous: the action callback already runs on the main thread (via
    // wakeup_cb), so NSWorkspace.open is safe to call directly -- no dispatch,
    // no captured-self lifetime concern.
    // Ambient home: opening a URL is a live, discarded effect (not saved/sent/
    // asserted), so reading the real home here is correct per the inject-vs-
    // ambient rule. The pure resolveOpenUrl stays deterministic via the param.
    //
    // Return AppKit's success Bool, NOT a hardcoded `true`: if NSWorkspace
    // refuses the open (false), libghostty re-runs its own fallback opener
    // (Surface.zig:4528-4548), so a failed native open degrades to the
    // subprocess path instead of dying silently.
    return NSWorkspace.shared.open(resolveOpenUrl(raw, home: NSHomeDirectory()))
```

Notes:

- Reads the C string length-bounded via `Data(bytes:count:)` + `String(data:
  encoding:)`, matching upstream's idiom for the same `(url, len)` shape
  (`.ghostty-src/.../Ghostty.App.swift:1786-1787`), rather than `String(cString:)`
  which assumes null-termination.
- Switches on `kind`: `.unknown` is handled natively (returning AppKit's open
  result); `.text` and `.html` return `false` so libghostty's fallback keeps its
  kind-specific behavior (`open -t` opens text in the default editor). Returning
  `false` here preserves whatever the fallback does today for those kinds -- no
  regression -- and avoids porting Ghostty's private `NSWorkspace`
  editor-selection extensions (`defaultApplicationURL(forExtension:)`,
  `defaultTextEditor`). Native `.text`/`.html` handling is a possible follow-up.
- Returns `NSWorkspace.shared.open(...)`'s `Bool` instead of a hardcoded `true`.
  AppKit's `open(_:)` reports whether it launched; on `false` (it refused the
  URL/file) libghostty still runs its fallback opener. Hardcoding `true` would
  suppress that fallback and leave a refused open dead with no warning.

## Files

- `lib/DanTermCore/Sources/DanTermCore/UrlResolution.swift` -- new; `resolveOpenUrl`.
- `lib/DanTermCore/Tests/DanTermCoreTests/UrlResolutionTests.swift` -- new; tests below.
- `app/GhosttyApp.swift` -- add the `GHOSTTY_ACTION_OPEN_URL` case in `handleAction`
  (before the `default` at ~line 497).

Reused, not modified: `expandTilde` (Model.swift:572).

## Tests

TDD: write `UrlResolutionTests.swift` first and watch it fail to compile/resolve,
then add `UrlResolution.swift`. Swift Testing `@Test`, matching the structure of
`ScrollbarMathTests.swift`. The assertions are on the returned `URL` value
(behavioral, structure-insensitive). Cases:

1. **http(s) URL with scheme returned verbatim** -- `resolveOpenUrl("https://example.com/path", home: "/Users/test")` equals `URL(string: "https://example.com/path")`. The primary user scenario.
2. **schemeless absolute path becomes a file URL** (pins issue #8763) --
   `resolveOpenUrl("/Users/test/file.txt", home: "/Users/test")` equals
   `URL(filePath: "/Users/test/file.txt")`, i.e. `.isFileURL == true` and not a
   schemeless web URL. Preamble names this as the #8763 contract.
3. **`~`-prefixed path expands against the injected home** --
   `resolveOpenUrl("~/notes.md", home: "/Users/test")` equals
   `URL(filePath: "/Users/test/notes.md")`. Proves home is injected, not ambient.
4. **schemeless path with a space falls to a file URL** --
   `resolveOpenUrl("/Users/test/my file.txt", home: "/Users/test")` returns a file
   URL (`.isFileURL == true`). Note `URL(string:)` does *not* return `nil` here --
   it parses the path as a *schemeless* URL (scheme `nil`); the `scheme != nil`
   guard is what routes it to `URL(filePath:)`. This pins that the guard, not a
   `nil` parse, is what catches bare paths.

The runtime case (kind switch + `NSWorkspace.open`) is AppKit and not unit-tested;
covered by manual verification below.

## Verification

0. **Confirm the failure mode first (de-risks the diagnosis).** With the *current*
   unpatched build, cmd-click a URL and watch the app's stderr / Console for
   `apprt did not handle open URL action, falling back to default opener`.
   - Warning appears -> `openUrl` is being reached; the missing native handler is
     the right place to fix and the subprocess fallback is what is misbehaving.
     Proceed.
   - Warning does NOT appear -> the click never reaches libghostty's `openUrl`
     (mouse routing / link detection / link-mods). Stop and revisit -- this plan
     will not fix that.
1. `just test` -- runs the new `UrlResolutionTests` (core Swift Testing) plus the
   core-purity lint, confirming the helper is pure and the new test passes.
2. `just build-run` -- launch the dev app. In a pane, `printf 'https://example.com\n'`,
   then cmd-hover the link (cursor becomes a pointer) and cmd-click it; confirm it
   opens in the default browser and the fallback warning no longer logs.
3. File-path case: `printf '%s\n' ~/.zshrc` (or any existing path), cmd-click the
   printed path; confirm it opens in the default app for that file type.

## Implementation notes

- `v.len` is `uintptr_t`, which Swift imports as `UInt`, but
  `Data(bytes:count:)` takes an `Int`, so the call needed `count: Int(v.len)`
  (the plan snippet wrote `count: v.len`). Corrected in the plan body and the
  impl alike.
