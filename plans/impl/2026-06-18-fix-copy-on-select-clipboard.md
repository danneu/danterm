# Fix: intermittent copy-on-select clipboard failure

## Context

Ghostty's "copy on select" should auto-copy a mouse selection to the macOS
system (Cmd-V) clipboard with no Cmd-C. In DanTerm it is intermittent: sometimes
a selected region never reaches the clipboard, so Cmd-V pastes stale content.

**Leading hypothesis (pinned Ghostty v1.3.1 -- NOT yet empirically confirmed).**
libghostty de-dups its copy-on-select write. In `setSelection`
(`.ghostty-src/src/Surface.zig:2310-2347`):

```zig
const sel = sel_ orelse return;
if (prev_) |prev| if (sel.eql(prev)) return;   // "same" selection -> NO write
```

The de-dup compares *selections*, not clipboard contents. So when the system
clipboard changes out-of-band (DanTerm's own **Copy cwd** / **Copy session id** at
`app/PaneWrapperView.swift:509-519`, the theme-name copy, `pbcopy`, another app)
while libghostty still holds the same selection, a re-write can be skipped and the
clipboard keeps the other content -- the intermittent stale-clipboard symptom.

**Caveat: static reading does not fully establish the exact mechanism -- do not
treat this as a verified root cause.** Mouse selection sets the selection via
direct `select()` (`Surface.zig:4132,4144,4842,4880,4889`), and the only
copy-on-select write is the single release re-assertion at `:3955`, which rebuilds
`Selection.init(prev.start(), prev.end(), prev.rectangle)`. But `Selection.eql`
compares ordered start/end pins + rectangle (`Selection.zig:84-88`) and those are
preserved, so that reconstruction is `eql` to the current selection -- meaning the
de-dup at `:2322` would fire *even on a first-time selection*. Since copy-on-select
works most of the time today, the real normal-write path is more involved than this
one re-assertion, and the precise user action that leaves the clipboard stale is
**not** pinned down by code reading alone. **Step 0 below requires reproducing the
failure at the DanTerm level before building**, so QA step 1 is a real signal
rather than a vacuous one.

**Why the fix is robust regardless of the exact mechanism.** The remedy does not
depend on the diagnosis: it enforces a simple invariant -- *after a mouse-up, the
system clipboard equals the current selection* -- by reading the finalized
selection and writing it only when the clipboard does not already match. That masks
the intermittent failure whatever its precise cause.

**Why DanTerm relies on the system clipboard here (do not change):** DanTerm
never sets `copy-on-select`, so it inherits the macOS default `true`, which on
macOS targets a *separate selection pasteboard*. DanTerm passes
`supports_selection_clipboard: false` (`app/GhosttyApp.swift:151`) so
libghostty's `true` branch falls back to the **standard** clipboard
(`Surface.zig:2336-2339`). That fallback is load-bearing and correct.

**Intended outcome:** a completed mouse selection reliably lands on the system
clipboard, independent of libghostty's de-dup, without regressing normal
copy-on-select, Cmd-C/Cmd-V, or OSC-52 read/write.

**Confirmed DanTerm-level repro (2026-06-18, pre-fix build).** A normal
drag-select copied the selected terminal text to `NSPasteboard.general`; after
`pbcopy` overwrote the clipboard with `OUT_OF_BAND`, repeating the identical
drag over the same visible terminal text left `pbpaste` as `OUT_OF_BAND`. There
was no intervening single-click clear -- the stale case is same-region
drag-select after an out-of-band clipboard write.

## Approach: DanTerm owns the copy on mouse-up

In `TerminalView.mouseUp`, *after* the event is forwarded to the surface (which
finalizes the selection synchronously), read the current selection and write it to
`NSPasteboard.general` ourselves -- but only when the clipboard does not already
hold that text (**compare-before-write**). This enforces the clipboard==selection
invariant independent of libghostty's de-dup, while staying idempotent: in the
common case libghostty already wrote the selection, the clipboard already matches,
and DanTerm writes nothing -- so `changeCount` is not bumped a second time and
clipboard managers (Maccy, Raycast, Paste) don't record duplicate entries on every
drag/double-click. This single hook covers all mouse-driven selection (drag,
shift-click extend, double/triple-click word/line).

C API (verified, `.ghostty-src/include/ghostty.h`):

- `bool ghostty_surface_has_selection(ghostty_surface_t);` (`:1128`)
- `bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*);` (`:1129`)
- `void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);` (`:1133`)
- `ghostty_text_s` (`:381-388`): the relevant fields are `const char* text` (the
  UTF-8 selection) and `uintptr_t text_len`.

**Memory ownership (verified, `embedded.zig:1291-1304,1678-1680`):**
`read_selection` allocates the `text` buffer via libghostty's global allocator;
the caller **must** call `ghostty_surface_free_text` to free it (via `defer`).
Decode with a `text_len`-bounded UTF-8 read, mirroring the existing in-repo reader
`AppRuntime.readSurfaceRegion` (`app/AppRuntime.swift:718-734`) -- **not**
`String(cString:)`: the length-based decode is the house idiom and avoids
truncating at an embedded NUL. The read -> decode -> free dance is the
easy-to-get-wrong part, so put it in one helper (step 3) and reuse the same
`ghostty_text_s`->String decode that `readSurfaceRegion` uses.

### Gate on the *surface's* effective copy-on-select (not app config)

DanTerm-owned copy must not fire if copy-on-select is disabled. The subtlety:
libghostty gates copy-on-select on each **surface's derived config**
(`copy_on_select = config.@"copy-on-select"`, `Surface.zig:382`; gated at the
`setSelection` early-exit), and the C API exposes **no per-surface
effective-config getter**. Reading the *app* config (`GhosttyApp.config`) can
diverge from what libghostty actually gates on -- e.g. a per-surface or
conditional `copy-on-select = false`.

Mirror the existing **scrollbar pattern** (it solves the identical "per-surface
config value, kept current across reloads" problem), with **one deliberate
divergence** noted below:

- a static reader `readCopyOnSelectEnabled(from: ghostty_config_t?)` (cf.
  `readScrollbarEnabled(from:)`, `GhosttyApp.swift:13-20`);
- a **view-local stored property** `TerminalView.copyOnSelectEnabled` (cf.
  `scrollbarEnabled`, `TerminalView.swift:48`);
- **seeded** from app config when the view is created (cf. `AppRuntime.swift:1225`);
- **updated per-surface** by the **surface-target** `GHOSTTY_ACTION_CONFIG_CHANGE`
  branch only (`GhosttyApp.swift:408-415`).

`reassertCopyOnSelect()` then gates on the view-local `copyOnSelectEnabled`.

**Divergence from scrollbar: do NOT fan the value out from the app-target
`CONFIG_CHANGE` branch.** On an app-wide config reload, libghostty updates every
surface first -- synchronously emitting a surface-target `config_change` per
surface (`App.zig:138-141` -> `Surface.handleMessage` `.change_config` ->
`updateConfig`, which emits the surface action unconditionally,
`Surface.zig:947,1789-1793`) -- and emits the app-target `config_change` last
(`App.zig:156-161`). DanTerm's app-target branch also defers its view writes to
`DispatchQueue.main.async` (`GhosttyApp.swift:400`), so fanning the app value out
to all views there (as the scrollbar branch does at `GhosttyApp.swift:402-404`)
would land *after* the per-surface values were set and overwrite a
conditional/per-surface `copy-on-select = false` with the app value. Every
existing surface is already covered by its own surface-target event (the
`App.zig:139` loop is over all surfaces; emission is unconditional), so the
app-target branch only needs to refresh the cloned app config -- which it already
does (`GhosttyApp.swift:390-392`) -- for seeding future surfaces.

Config enums are returned by the C API as their **tag-name string**
(`.ghostty-src/src/config/c_get.zig:62-65`), so the reader reads
`copy-on-select` as `"false" | "true" | "clipboard"` (exactly how
`readScrollbarEnabled` reads `"scrollbar"`). Enabled iff `!= "false"`;
unreadable -> default enabled (macOS default is `true`).

### `write_clipboard_cb` is left unchanged (hardening split to a follow-up)

The bug is fixed entirely by the mouse-up reassertion above, which writes plain
selection text directly via `read_selection` and **never goes through
`write_clipboard_cb`**. The previously-proposed `write_clipboard_cb` mime
hardening is orthogonal clipboard surface area and is split to a follow-up (see
below) -- both to keep this change focused on the intermittent failure and
because the naive version is wrong (it would collapse `text/html` to plain
markup). `write_clipboard_cb` stays as-is, so Cmd-C/Cmd-V and OSC-52 behavior are
untouched by this plan.

### Scope

Mouse-driven copy-on-select only -- we only *add* an authoritative mouse-up write;
no existing path is changed or removed.

The de-dup at `Surface.zig:2322` lives in the shared `setSelection` write path, so
it is **not** mouse-specific: keyboard/keybind-driven selection (e.g.
`adjust_selection`) that routes through `setSelection` is a residual instance of
the same stale-clipboard class, which this plan does **not** close (it has no
mouse-up hook to piggyback on). This is expected to be rare -- copy-on-select is
defined on mouse release -- so a keybind-selection equivalent is a known follow-up
if it surfaces, not a gap we silently claim to cover.

## Files to read before editing

- `docs/design/2026-06-09-appkit-lifetime-safety.md` -- the mouse-up read+write
  is synchronous, main-thread, with no stored/escaping closure, observer, or
  timer, so none of the lifetime hazards apply; confirm against the doc.
- `docs/design/2026-05-28-pure-core-support-split.md` -- confirms the pure helper
  belongs in `DanTermCore` and must pass `scripts/core-purity-lint.sh`.
- `docs/design/2026-05-28-core-module-via-symlink.md` -- the new core file is seen
  same-module by the app (no `import`) and tested via the nested package.
- `app/GhosttyApp.swift` -- the **scrollbar pattern to mirror**: `readScrollbarEnabled`
  + `scrollbarEnabled` (13-23), `readConfig*` helpers (27-60), and the
  `GHOSTTY_ACTION_CONFIG_CHANGE` handler (386-419, both target branches).
- `app/TerminalView.swift` -- `scrollbarEnabled` per-view property (48-50) to
  mirror; mouse handlers (268-292); `ghosttyApp` and `surface` properties.
- `app/AppRuntime.swift` -- the surface-creation seed site (`view.scrollbarEnabled
  = ...`, ~1225) where the new value is seeded.
- `.ghostty-src/include/ghostty.h:381-388, 1128-1133` -- C API shapes
  (reference only; **do not edit** `.ghostty-src/`).

No `./build-lib.sh` re-run: the three selection symbols are already in the pinned
`GhosttyKit.xcframework` (declared at `ghostty.h:1128-1133`, exported in
`embedded.zig`).

## Implementation steps (failing tests first)

### 0. Confirm the failure empirically before building the fix

The mechanism is a hypothesis (see Context), so establish a reproducible pre-fix
symptom first -- otherwise QA step 1 proves nothing. At the DanTerm level, on the
current build, find the exact user action that leaves the clipboard stale: fresh
re-select of the same region after an out-of-band write (`pbcopy`, Copy cwd) vs.
shift-click extend, and note whether an intervening single-click clear
(`Surface.zig:4106-4108`) occurs. Record the confirmed trigger and restate the
Context repro to match it.

Confirm only at the DanTerm level; do **not** instrument libghostty as part of this
plan. Editing `.ghostty-src/src/Surface.zig` + re-running `./build-lib.sh` to log the
`:2322` `return` would build from the regenerated `.ghostty-src/` boundary (AGENTS.md)
into the **gitignored** `lib/GhosttyKit.xcframework`, and the stale guard
(`cache_at_pinned_tag`, `build-lib.sh:47-51`) compares only HEAD's commit to the
pinned tag -- never working-tree cleanliness -- so a forgotten instrumented build
leaves **no `git status` signal**, and the real fix (and `just build` / `just
test-ui`) would silently run against the logging lib. The remedy is
mechanism-agnostic, so confirming the de-dup specifically buys little against that
footgun. If the DanTerm-level symptom ever resists reproduction, reach for a careful
*throwaway* instrumented build only *then*, reverting with `git -C .ghostty-src
checkout -- src/Surface.zig && ./build-lib.sh` to regenerate the pristine xcframework
**before** building the fix. If the confirmed trigger contradicts the hypothesis,
update Context -- the remedy below (enforce clipboard==selection) stands regardless,
but QA step 1 must exercise the *confirmed* trigger.

### 1. Pure helper + its failing tests (`DanTermCore`)

New file `lib/DanTermCore/Sources/DanTermCore/CopyOnSelect.swift` (plain free
function, no access modifier -- same convention as `ScrollbarMath.swift`;
Swift-stdlib only, so it passes the pure-core lint). Reuse the test conventions
from `lib/DanTermCore/Tests/DanTermCoreTests/ScrollbarMathTests.swift` (`import
Testing`, `@testable import DanTermCore`, `@Suite`/`@Test`, Intent/Why/Scenario
preamble for contract-pinning cases).

```swift
// Pure decision for whether copy-on-select is effectively enabled, given the raw
// `copy-on-select` config value. No AppKit / GhosttyKit -- the impure caller
// (GhosttyApp) does the C-interop config read; this just maps the value to a
// bool so the gate is unit-testable without Cocoa.
import Foundation

/// Whether copy-on-select is effectively enabled, given the raw `copy-on-select`
/// config value (the C API returns the enum tag name). Mirrors libghostty's
/// per-surface `config.copy_on_select == .false` gate; `nil`/unknown -> enabled
/// (macOS default is `true`). `"clipboard"` counts as enabled.
func isCopyOnSelectEnabled(setting: String?) -> Bool {
    (setting ?? "true") != "false"
}
```

Failing tests in `lib/DanTermCore/Tests/DanTermCoreTests/CopyOnSelectTests.swift`
for `isCopyOnSelectEnabled`: `"true"` -> true, `"clipboard"` -> true, `"false"`
-> false, `nil` -> true (pins the default-enabled + clipboard-counts-as-enabled
contracts). Run `swift test --package-path lib/DanTermCore --filter CopyOnSelect`,
verify red for the right reason, then add the helper and verify green.

### 2. `GhosttyApp` -- static reader + app-level accessor (mirror scrollbar)

Add next to `readScrollbarEnabled`/`scrollbarEnabled`:

```swift
/// Read copy-on-select from any config. Returns true (enabled) unless set to
/// "false". Mirrors `readScrollbarEnabled(from:)`; the C API returns the enum as
/// its tag name, so this reads a C-string and delegates the decision to the pure
/// `isCopyOnSelectEnabled`.
static func readCopyOnSelectEnabled(from config: ghostty_config_t?) -> Bool {
    guard let config = config else { return true }
    var v: UnsafePointer<Int8>?
    let key = "copy-on-select"
    guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)), let ptr = v else { return true }
    return isCopyOnSelectEnabled(setting: String(cString: ptr))
}

/// Copy-on-select per the current app config. Used only to seed a surface's
/// view-local value at creation; CONFIG_CHANGE keeps the per-surface value current.
var copyOnSelectEnabled: Bool { Self.readCopyOnSelectEnabled(from: config) }
```

### 3. `TerminalView` -- view-local value + authoritative copy on mouse-up

Add the per-view property (mirrors `scrollbarEnabled`; no `didSet` needed -- it is
read at mouse-up):

```swift
/// Effective copy-on-select for THIS surface. Seeded from app config at creation
/// (AppRuntime) and kept in sync per-surface via GHOSTTY_ACTION_CONFIG_CHANGE,
/// exactly like `scrollbarEnabled`. libghostty gates copy-on-select on the
/// surface's derived config (Surface.zig:382 + the setSelection gate) and exposes
/// no per-surface effective-config getter, so we track the value we are handed on
/// config-change rather than reading app config here.
var copyOnSelectEnabled: Bool = true
```

Hook the reassertion into `mouseUp` and gate on the view-local value:

```swift
override func mouseUp(with event: NSEvent) {
    guard let surface = surface else { return }
    let mods = Self.ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    reassertCopyOnSelect()
}

/// After a left-mouse-up, guarantee the system (Cmd-V) clipboard holds the current
/// selection. libghostty's own copy-on-select write can be skipped by its de-dup
/// (it compares selections, not clipboard contents) -- the leading hypothesis for
/// the intermittent stale clipboard; rather than depend on that diagnosis, we
/// enforce the clipboard==selection invariant directly. Idempotent: writes only
/// when the clipboard does not already match, so the common case (libghostty
/// already wrote it) is a no-op and does not spam clipboard managers. Gated on this
/// surface's copy-on-select setting so `copy-on-select = false` is honored.
/// Synchronous, main-thread, no escaping closure -> no AppKit lifetime hazard.
private func reassertCopyOnSelect() {
    guard let surface = surface else { return }
    guard copyOnSelectEnabled, ghostty_surface_has_selection(surface) else { return }
    guard let str = readSelectionText(surface), !str.isEmpty else { return }
    guard NSPasteboard.general.string(forType: .string) != str else { return }  // already matches
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(str, forType: .string)
}

/// Current selection text, or nil if none. Owns the read -> decode -> free
/// lifecycle so callers can't leak or use-after-free. `text_len`-bounded UTF-8
/// decode, identical to `AppRuntime.readSurfaceRegion` -- factor that
/// `ghostty_text_s`->String decode into one shared app-level helper used by both.
private func readSelectionText(_ surface: ghostty_surface_t) -> String? {
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard text.text_len > 0, let ptr = text.text else { return nil }
    let len = Int(text.text_len)
    return ptr.withMemoryRebound(to: UInt8.self, capacity: len) {
        String(bytes: UnsafeBufferPointer(start: $0, count: len), encoding: .utf8)
    }
}
```

The `has_selection` guard makes the click-clears-selection case
(`Surface.zig:4106-4108`, a small/fast drag treated as a click) and a
deselecting click correctly write nothing. The post-`mouse_button` ordering is
correct: the release handler finalizes the selection synchronously under the
renderer mutex before the C call returns, and `read_selection` takes the same
lock.

### 4. Seed + keep the per-surface value current

- **Seed at creation** in `AppRuntime.swift` (~1225), beside the scrollbar seed:
  `view.copyOnSelectEnabled = ghosttyApp.copyOnSelectEnabled`.
- **Surface-target `CONFIG_CHANGE`** (`GhosttyApp.swift:408-415`) is the only
  per-surface updater: set
  `view.copyOnSelectEnabled = Self.readCopyOnSelectEnabled(from: changeConfig)`
  next to the existing `view.scrollbarEnabled = enabled`. `changeConfig` is that
  surface's derived config, so this is the authoritative per-surface value.
- **App-target `CONFIG_CHANGE`** (`GhosttyApp.swift:389-406`): **add nothing** for
  copy-on-select. It already refreshes `self.config` (390-392), which is all the
  app-level accessor needs to seed future surfaces. Do **not** add a
  `copyOnSelectEnabled` line to the all-surfaces fan-out loop (unlike scrollbar at
  402-404) -- it fires last and would clobber the per-surface values just set by
  the surface-target events (see the divergence note in the Approach section).

## Follow-up (out of scope for this plan): MIME-preserving clipboard write

`write_clipboard_cb` (`app/GhosttyApp.swift:189-201`) is intentionally left
unchanged here. It currently writes only an exact `text/plain` item, as
`.string`. That is correct for the common case: `CopyToClipboard` defaults to
`.mixed` (`Binding.zig:1075`), so Cmd-C *and* copy-on-select emit **both**
`text/plain` and `text/html` (`Surface.zig:2259-2291`) and we already pick
`text/plain`. The only gap is an explicit `copy_to_clipboard:html` bind
(html-only, no `text/plain`), which is currently dropped.

The robust fix mirrors upstream Ghostty's macOS app
(`macos/Sources/Ghostty/Ghostty.App.swift:401-408`): iterate **all** content
items, map each mime to `NSPasteboard.PasteboardType(mimeType:)`,
`declareTypes(...)`, and `setString(item.data, forType:)` per type -- preserving
`text/html` so rich-text paste keeps formatting instead of pasting raw markup,
and restoring the HTML half of `.mixed` copies that DanTerm currently discards.
That is a separable, testable change (a pure helper can map the item list to
typed payloads) and should be its own plan. A naive "fall back to any `text/*`
item, write as `.string`" must **not** be shipped -- it pastes HTML markup as
plain text.

## Verification

**Automated gate** (`just test`): protocol XCTest + core Swift Testing +
DanTermSupport + core-purity lint + shell self-tests. The new `CopyOnSelectTests`
run here; the new core file must pass the pure profile.

**Build/run:** `just build-run`.

**Manual QA matrix:**

1. **The confirmed repro (step 0) now passes:** e.g. select text -> `echo x |
   pbcopy` -> re-trigger the confirmed stale-clipboard action -> Cmd-V pastes the
   selection, not `x`.
2. Normal copy-on-select (select, then Cmd-V in another app) still works.
3. Cmd-C copy and Cmd-V paste still work (unchanged -- `write_clipboard_cb` untouched).
4. OSC-52 read and write still work (unchanged -- `write_clipboard_cb` untouched).
5. Selecting in a background/unfocused pane lands that pane's selection on the
   clipboard.
6. A bare click (no drag) and a deselecting click write nothing (clipboard
   unchanged).
7. With `copy-on-select = false` in `~/.config/ghostty/config`, a mouse selection
   does **not** auto-copy (gate honored). If you can express a per-surface or
   conditional `copy-on-select = false`, confirm a surface where it resolves to
   false does not auto-copy while others still do, and that triggering an
   app-wide config reload afterward does not re-enable it (i.e. the app-target
   fan-out does not clobber the per-surface value) -- exercising step 4.
8. With a clipboard manager running (Maccy/Raycast/Paste), a normal drag-select
   records **one** entry, not two -- confirming the compare-before-write no-op
   when libghostty already wrote the selection.
