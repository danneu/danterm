# Plan: MIME-preserving `write_clipboard_cb`

## Context

`write_clipboard_cb` in `app/GhosttyApp.swift` (currently lines 203-216) is the
callback libghostty invokes whenever a surface writes the system clipboard
(Cmd-C, `copy_to_clipboard:*` keybinds, libghostty's own copy-on-select write,
and OSC-52 writes). Today it scans the content array for an **exact** `text/plain`
item, converts it with `String(cString:)`, clears `NSPasteboard.general`, writes
it as `.string`, and breaks.

That drops everything except `text/plain`:

- `CopyToClipboard` defaults to `.mixed` (`.ghostty-src/src/input/Binding.zig`,
  `CopyToClipboard.default = .mixed`), so Cmd-C and copy-on-select emit **both**
  `text/plain` and `text/html` (`.ghostty-src/src/Surface.zig`
  `copySelectionToClipboards`, `.mixed` branch appends `text/plain` then
  `text/html`). DanTerm keeps the plain half and **discards the HTML half**, so
  pasting into a rich-text target never carries formatting.
- An explicit `copy_to_clipboard:html` keybind emits **html-only** (single
  `text/html` item, no `text/plain`). DanTerm drops it entirely -- the copy is
  silently lost.

This is the follow-up explicitly carved out of
`plans/impl/2026-06-18-fix-copy-on-select-clipboard.md`
(see its `## Follow-up (out of scope for this plan): MIME-preserving clipboard
write`). That plan also flags the known-bad shortcut: a naive "fall back to any
`text/*` item, write as `.string`" must **not** ship, because it pastes HTML
markup as plain text.

**Intended outcome:** preserve every clipboard MIME item Ghostty hands us --
keep `text/plain` working exactly as today, restore `text/html` so rich-text
paste keeps formatting and html-only copies stop vanishing -- mapping each MIME
to its own pasteboard type and never collapsing a non-plain type onto `.string`.

## Verified findings (re-grep by symbol; line numbers drift)

C callback shape, from the **linked** header
`lib/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h`:

```c
typedef struct { const char *mime; const char *data; } ghostty_clipboard_content_s;  // :48-51

typedef void (*ghostty_runtime_write_clipboard_cb)(void*,
    ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool);          // :981-985
```

- `mime` and `data` are **sentinel-terminated C strings** (`[*:0]const u8` in
  `.ghostty-src/src/apprt/embedded.zig`). There is **no length field** -- the data
  is a NUL-terminated string, so `String(cString:)` is the only available decode
  (it matches the current code and upstream's behavior). Items are passed as a
  **pointer + count** (`content`, `len`), not a NUL-terminated array.
- The 5th argument `confirm` is a **`Bool`** (not a closure). The Swift closure
  in `GhosttyApp.swift` already binds it as `{ userdata, location, content, len,
  confirm in ... }`.

Upstream macOS reference (`.ghostty-src/macos/Sources/Ghostty/Ghostty.App.swift`,
`writeClipboard(...)`): when `confirm == false` it maps every item's mime through
`NSPasteboard.PasteboardType(mimeType:)`, calls `declareTypes(_:owner:)` once with
all mapped types, then `setString(item.data, forType:)` per type. When
`confirm == true` it posts a NotificationCenter confirmation request showing only
the `text/plain` item (DanTerm has no equivalent UI -- see Confirm decision).

**Toolchain caveat -- do NOT copy upstream's MIME mapping verbatim.**
`NSPasteboard.PasteboardType(mimeType:)` is upstream-only; it does **not** build
in DanTerm's toolchain. Verified with `swiftc -typecheck`: it fails with
`error: extraneous argument label 'mimeType:' in call`, and there is no extension
defining it under `.ghostty-src/macos/`. DanTerm maps via `UniformTypeIdentifiers`
instead (already imported in `app/AppRuntime.swift:5`):
`UTType(mimeType: mime)` -> `NSPasteboard.PasteboardType(type.identifier)`. The
`UTType` + `.html` + `UTType.html.identifier` route typechecks cleanly.

**The safety constraint that drives the design:** every plain-text *reader* in
DanTerm pulls `.string` specifically:

- OSC-52 read `read_clipboard_cb` -> `NSPasteboard.general.string(forType: .string)`
  (`app/GhosttyApp.swift:191`),
- the just-landed mouse-up reassertion -> `pasteboard.string(forType: .string)` /
  `setString(..., forType: .string)` (`app/TerminalView.swift:295,297`),
- drag-drop plain fallback -> `pb.string(forType: .string)` (`app/TerminalView.swift:676`).

So the new write path **must** keep `text/plain` under `.string` exactly. We do
not rely on whatever `UTType(mimeType: "text/plain")` resolves to; we pin
`text/plain -> .string` explicitly so plain paste, OSC-52 read, the mouse-up
reassertion, and drag-drop are byte-for-byte unchanged.

Existing seam precedent to mirror: `app/ThemeBrowserView.swift` defines
`protocol ThemeNamePasteboard` + `extension NSPasteboard: ThemeNamePasteboard {}`
and tests inject a `RecordingThemePasteboard` spy (`tests-ui/ThemeBrowserViewTests.swift`).
That is exactly the pattern this plan generalizes for declare+set.

## Approach

Three layers, splitting pure decisions (testable headless in `just test`) from
the AppKit mapping (testable in the GUI harness `just test-ui`) from the thin
GhosttyKit C-interop adapter (kept dumb so its lack of a unit test is harmless).

### Layer A -- pure normalization (`DanTermCore`, no AppKit)

New file `lib/DanTermCore/Sources/DanTermCore/ClipboardWriteItems.swift` (plain
free function + small value type, no access modifier -- same convention as
`ScrollbarMath.swift` / `CopyOnSelect.swift`; stdlib only, passes the pure
profile of `scripts/core-purity-lint.sh`):

```swift
/// One clipboard payload as handed to us by libghostty: a MIME type and its
/// UTF-8 string. App-neutral so the write decision (filter/dedup/order) is
/// unit-testable without AppKit; the impure caller maps mime -> pasteboard type.
struct ClipboardWriteItem: Equatable { let mime: String; let data: String }

/// Normalize the raw items into the exact ordered list to write: drop items with
/// an empty MIME (can't map to a pasteboard type), but PRESERVE empty data --
/// OSC-52 clear (`52;;`) writes a `text/plain` item with empty data to CLEAR the
/// clipboard (`Surface.zig` setClipboard with an empty `text/plain`; today's
/// callback clears + sets an empty `.string` at `GhosttyApp.swift:211-213`), so
/// dropping empty data would leave stale clipboard contents. Dedup by mime
/// keeping the FIRST occurrence (deterministic; Ghostty emits at most one item
/// per mime in practice -- this is defensive). Order is otherwise preserved so
/// `.mixed` stays [text/plain, text/html].
func clipboardItemsToWrite(_ raw: [ClipboardWriteItem]) -> [ClipboardWriteItem]
```

### Layer B -- AppKit mapping + write (`app/`, GhosttyKit-free)

New file `app/ClipboardWriteSurface.swift` (imports `AppKit` +
`UniformTypeIdentifiers`; both are system frameworks auto-linked via `import`, so
the harness needs no extra linker flags -- `app/AppRuntime.swift` already imports
`UniformTypeIdentifiers`). **Must not** reference any GhosttyKit symbol, because
the GUI test harness (`test-ui.sh`) is GhosttyKit-free and will compile this file.

```swift
/// Minimal pasteboard surface the clipboard write needs, split out so tests can
/// observe declared types and per-type payloads without touching real clipboard
/// services (mirrors ThemeNamePasteboard).
protocol ClipboardWriteSurface: AnyObject {
    @discardableResult func declareTypes(_ newTypes: [NSPasteboard.PasteboardType], owner: Any?) -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}
extension NSPasteboard: ClipboardWriteSurface {}   // signatures already match exactly

/// Map a MIME type to its pasteboard type. `text/plain` is pinned to `.string`
/// -- the exact type every DanTerm reader pulls (OSC-52 read, mouse-up
/// reassertion, drag-drop) -- independent of how the UTI machinery resolves
/// text/plain. All other mimes go through `UniformTypeIdentifiers` (DanTerm's
/// toolchain has no `NSPasteboard.PasteboardType(mimeType:)`); an unmappable
/// mime returns nil and is skipped (never written under a wrong type).
func defaultClipboardTypeMap(_ mime: String) -> NSPasteboard.PasteboardType? {
    if mime == "text/plain" { return .string }
    guard let type = UTType(mimeType: mime) else { return nil }
    return NSPasteboard.PasteboardType(type.identifier)
}

/// Write the normalized items to `surface`, each under its mapped pasteboard type.
/// Skips mimes that don't map. Leaves the pasteboard UNTOUCHED when nothing maps
/// (no declareTypes -> no clear), so a write with no mappable items can't wipe
/// the clipboard (a deliberate improvement over a naive upstream port, which
/// would declareTypes([]) and clear).
func writeClipboardItems(
    _ items: [ClipboardWriteItem],
    mapType: (String) -> NSPasteboard.PasteboardType? = defaultClipboardTypeMap,
    to surface: ClipboardWriteSurface
) {
    let mapped: [(NSPasteboard.PasteboardType, String)] =
        items.compactMap { item in mapType(item.mime).map { ($0, item.data) } }
    guard !mapped.isEmpty else { return }
    surface.declareTypes(mapped.map(\.0), owner: nil)
    for (type, data) in mapped { surface.setString(data, forType: type) }
}
```

The injectable `mapType` (defaulted, so the call site stays clean) is what makes
"unmappable mime is skipped" and "all-unmappable leaves the pasteboard untouched"
**deterministically** testable without depending on the OS's UTI resolution of an
arbitrary mime (we cannot guarantee at plan time that any specific non-empty mime
string resolves to nil). The real `defaultClipboardTypeMap` is tested directly.

### Layer C -- C-interop adapter (inline in `GhosttyApp.swift`)

Rewrite the `write_clipboard_cb` body. The marshalling loop is the only untested
surface; keep it dumb (loop + `String(cString:)`, nil -> ""), pushing all
filtering into Layer A and all mapping into Layer B:

```swift
write_clipboard_cb: { userdata, location, content, len, confirm in
    // `confirm` is intentionally not honored: DanTerm has no clipboard
    // confirmation UI (read_clipboard_cb also completes without one), so this
    // preserves current always-write behavior. See plan "Confirm decision".
    // `location` is ignored as today: supports_selection_clipboard is false, so
    // writes target the standard clipboard (NSPasteboard.general).
    guard let content = content, len > 0 else { return }
    var raw: [ClipboardWriteItem] = []
    raw.reserveCapacity(len)
    for i in 0..<len {
        let item = content[i]
        let mime = item.mime.map { String(cString: $0) } ?? ""
        let data = item.data.map { String(cString: $0) } ?? ""
        raw.append(ClipboardWriteItem(mime: mime, data: data))
    }
    writeClipboardItems(clipboardItemsToWrite(raw), to: NSPasteboard.general)
},
```

`ClipboardWriteItem` and the Layer-B functions are visible same-module (the app
compiles `DanTermCore` via the `app/DanTermCore` symlink and `app/*.swift`
together -- no `import`).

### Confirm decision (scoped out, deliberately)

DanTerm has **no clipboard-confirmation UI anywhere**: `read_clipboard_cb` and
`confirm_read_clipboard_cb` both call `ghostty_surface_complete_clipboard_request`
immediately with no dialog, and the current `write_clipboard_cb` ignores
`confirm` and writes unconditionally. This plan **preserves that** -- writes
always proceed, `confirm` is ignored -- and documents it at the call site.

Rationale, so this is a deliberate scope decision rather than an oversight:

- It is the status quo; honoring `confirm` only on writes while reads never
  confirm would be inconsistent.
- Adding an OSC-52 write-confirmation sheet is a separate feature: it needs a
  surface-bound modal, NotificationCenter (or direct) wiring, and the
  AppKit-lifetime-safety review in `docs/design/2026-06-09-appkit-lifetime-safety.md`
  -- out of proportion to a clipboard-format fix.
- The MIME change does **not** widen the OSC-52 attack surface: OSC-52 carries a
  single payload that Ghostty emits as `text/plain` only, so remote-triggered
  writes still produce just `text/plain`. The new `text/html` paths come from
  local Cmd-C / `copy_to_clipboard` keybinds, which set `confirm == false`.

A future OSC-52 write-confirmation dialog is listed in Out of scope.

### Interaction with the just-landed mouse-up reassertion (no change needed)

After a mouse selection, libghostty's copy-on-select calls `write_clipboard_cb`
with `.mixed` [text/plain, text/html]; the new code writes `.string` + the HTML
type. The reassertion in `TerminalView.mouseUp` then reads `.string`, finds it
already equals the selection, and no-ops -- so the HTML survives and copy-on-select
now also carries rich text (a safe bonus). In the rare stale-clipboard recovery
case the reassertion does `clearContents()` + `setString(selection, forType:
.string)`, which drops the HTML but restores the plain-text invariant -- acceptable,
and it requires no change to the reassertion. **Do not modify `TerminalView.mouseUp`.**

## Files

New:

- `lib/DanTermCore/Sources/DanTermCore/ClipboardWriteItems.swift` -- Layer A.
- `lib/DanTermCore/Tests/DanTermCoreTests/ClipboardWriteItemsTests.swift` -- Layer A tests (auto-discovered).
- `app/ClipboardWriteSurface.swift` -- Layer B (GhosttyKit-free).
- `tests-ui/ClipboardWriteTests.swift` -- Layer B tests; defines `func clipboardWriteTests()`.

Changed:

- `app/GhosttyApp.swift` -- rewrite the `write_clipboard_cb` body (Layer C). Each
  file gets the standard top-of-file `//` header comment per AGENTS.md.
- `test-ui.sh` -- add the three new compiled sources to the file list:
  `lib/DanTermCore/Sources/DanTermCore/ClipboardWriteItems.swift`,
  `app/ClipboardWriteSurface.swift`, and `tests-ui/ClipboardWriteTests.swift`
  (the harness compiles a hand-curated subset; new files must be listed).
- `tests-ui/PaneSplitViewTests.swift` -- the harness runner; add a
  `clipboardWriteTests()` call next to `themeBrowserViewTests()`.

No `./build-lib.sh` re-run: `ghostty_clipboard_content_s` and the callback are
already in the pinned `GhosttyKit.xcframework` (the current callback uses them).

Do not touch `.ghostty-src/`, `lib/GhosttyKit.xcframework/`, the working tree's
unrelated dirty files (`README.md`, the `integrations/claude-code/*` notify
scripts, untracked notes/plans), or the mouse-up reassertion.

## Test plan (TDD: failing test first, verify red for the right reason, then green)

### Layer A -- `ClipboardWriteItemsTests.swift` (runs in `just test`, no AppKit)

Swift Testing (`import Testing`, `@testable import DanTermCore`, `@Suite`/`@Test`,
Intent/Why/Scenario preamble for contract-pinning cases), mirroring
`ScrollbarMathTests.swift`. Cases for `clipboardItemsToWrite`:

- **mixed preserves both, in order:** `[plain "hi", html "<b>hi</b>"]` ->
  unchanged (both kept, plain first).
- **html-only is kept:** `[html "<b>x</b>"]` -> `[html "<b>x</b>"]` (pins the
  core bug: html-only copies must not be dropped here).
- **empty data is PRESERVED (OSC-52 clear):** `[plain ""]` -> `[plain ""]` -- a
  `text/plain` with empty data is how OSC-52 `52;;` clears the clipboard; it must
  survive normalization so the write path can clear `.string`. Regression guard
  for F2.
- **empty mime dropped:** `[("", "data")]` -> `[]` (can't map to a type).
- **duplicate text/plain keeps first (intentional, defensive):**
  `[plain "A", plain "B"]` -> `[plain "A"]`.
- **empty input -> empty output.**

### Layer B -- `ClipboardWriteTests.swift` (runs in `just test-ui`, uses AppKit but never the system pasteboard)

Custom harness idiom (`func clipboardWriteTests()` with `uiTest(...)` /
`uiExpect(...)`), mirroring `ThemeBrowserViewTests.swift`. Add a
`RecordingClipboardSurface` spy conforming to `ClipboardWriteSurface` that records
an ordered log of `declareTypes(_)` and `setString(type, data)` calls.

`defaultClipboardTypeMap` (real mapping; pins the safety contract):

- `defaultClipboardTypeMap("text/plain") == .string` (plain stays on the exact
  type every reader pulls).
- `defaultClipboardTypeMap("text/html") != .string` and equals
  `NSPasteboard.PasteboardType(UTType.html.identifier)` (== `.html`; html maps to
  its own type and can never collapse onto `.string` -- the core regression
  guard). During TDD, print the resolved rawValues to document the relationship.

`writeClipboardItems` (default map; via the recording surface):

- **mixed preserves both under their own types:** input `[plain "hi", html
  "<b>hi</b>"]` -> recorder shows `declareTypes([.string, htmlType])` then
  `setString(.string, "hi")` and `setString(htmlType, "<b>hi</b>")`. Asserts plain
  under `.string`, html under the html type, both present, order preserved.
- **html-only writes the html type and no `.string`:** input `[html "<b>x</b>"]`
  -> recorder has the html type only; `.string` never set (restores the dropped
  html-only path).
- **text/plain with empty data still clears `.string` (OSC-52 clear):** input
  `[plain ""]` -> recorder shows `declareTypes([.string])` then
  `setString("", .string)`, matching today's `clearContents()` + `setString("")`.
  This is the write-side half of the F2 regression guard.

`writeClipboardItems` (injected `mapType`; deterministic skip / no-clear):

- **unmappable mime is skipped:** map returns nil for `"x/unknown"`, a type for
  `text/plain`; input `[plain "hi", ("x/unknown","junk")]` -> only `.string`
  declared/set.
- **no mappable items leaves the pasteboard untouched:** map returns nil for
  everything -> recorder records **zero** calls (no `declareTypes`, no clear).
  This is the all-unmappable / empty-mime path; an empty-DATA `text/plain` still
  maps to `.string` and clears (see the OSC-52-clear case above) -- the two must
  not be conflated.
- **empty input leaves the pasteboard untouched:** `writeClipboardItems([], to:
  recorder)` -> zero calls.

## Verification

1. **Targeted Layer A:** `swift test --package-path lib/DanTermCore --filter ClipboardWriteItems`
   (red first, then green).
2. **Full headless gate:** `just test` (protocol XCTest + core + DanTermSupport +
   purity lints + shell self-tests). The new core file must pass the pure profile;
   Layer A tests run here.
3. **GUI harness:** `just test-ui` (compiles + runs the AppKit harness, including
   the new `clipboardWriteTests()`).
4. **Build:** `just build` (and `just build-run` for manual QA).

### Manual QA

1. **Default Cmd-C (`.mixed`) preserves plain AND html:** select terminal text,
   Cmd-C. Paste into TextEdit (or Notes) -> styled/rich text. Paste into a
   plain-text field and back into the terminal (Cmd-V) -> correct plain text.
   (Pre-fix: rich target gets plain only.)
2. **Explicit html-only copy is no longer dropped:** add
   `keybind = cmd+shift+c=copy_to_clipboard:html` to `~/.config/ghostty/config`,
   reload, select, trigger it, paste into a rich target -> HTML content appears.
   (Pre-fix: nothing copied.) If binding is impractical, note it and rely on the
   html-only Layer B test + the mixed-path QA.
3. **Plain paste in the terminal (Cmd-V) unchanged.**
4. **OSC-52 unaffected:** write via OSC-52
   (`printf '\e]52;c;'"$(printf hello | base64)"'\a'`) then Cmd-V elsewhere ->
   `hello`; and a terminal-side paste/read still returns the clipboard. This
   confirms `text/plain` still lands under `.string` so `read_clipboard_cb` works.
4b. **OSC-52 clear still empties the clipboard:** with text on the clipboard, run
   OSC-52 clear (`printf '\e]52;c;\a'`, empty payload) -> Cmd-V pastes nothing.
   Guards F2: empty `text/plain` must clear, not no-op.
5. **Copy-on-select still works** (select, Cmd-V in another app) -- and now also
   carries html; the mouse-up reassertion still no-ops in the common case.
6. **Clipboard manager (Maccy/Raycast/Paste):** a normal copy records one entry,
   not duplicates (no regression from the extra type).

## Out of scope

- OSC-52 **write** confirmation UI (honoring `confirm == true` with a dialog) --
  a separate feature; DanTerm has no clipboard-confirmation UI for reads either.
- `text/vt` ANSI-sequence copies: Ghostty emits these as `text/plain`
  (`Surface.zig` `.vt` branch), so they already flow through the `text/plain ->
  .string` path; no special handling needed.
- Selection-clipboard routing (`location`): `supports_selection_clipboard` stays
  `false`; writes target `NSPasteboard.general` as today.
- Any change to `read_clipboard_cb`, Cmd-V paste, drag-drop, or the just-landed
  `TerminalView.mouseUp` copy-on-select reassertion.

## Risks / landmines

- **Regressing plain readers** is the headline risk; mitigated by pinning
  `text/plain -> .string` (Layer B test 1) rather than trusting the UTI
  resolution of `text/plain`.
- **`NSPasteboard.PasteboardType(mimeType:)` does not compile here** (upstream
  only). Map non-plain mimes via `UniformTypeIdentifiers` -- `UTType(mimeType:)`
  + `NSPasteboard.PasteboardType(type.identifier)` -- which typechecks.
- **OSC-52 clear (empty `text/plain`) must still empty the clipboard.** Dropping
  empty data would silently regress it; that is why normalization keeps empty
  data and only drops empty mime, guarded by the dedicated Layer A + Layer B
  empty-data cases.
- **`test-ui.sh` is a manual file list** -- forgetting to add the three new
  sources or the runner call yields a confusing "symbol not found" or a silently
  unrun test. Both wiring edits are mandatory.
- **Layer B file must stay GhosttyKit-free** or the GUI harness won't compile;
  keep all `ghostty_clipboard_content_s` handling inside `GhosttyApp.swift`.
- **No reliably-nil non-empty mime** is guaranteed from `UTType(mimeType:)` across
  OS versions; this is exactly why the skip/no-clear tests inject `mapType`
  instead of probing a real mime.
