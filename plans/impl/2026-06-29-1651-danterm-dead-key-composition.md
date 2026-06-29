# Plan: Fix DanTerm dead-key double-emit (accents broken in neovim)

## Context

Typing a macOS dead-key accent (Option+E then `o` for `ó`, also umlaut/tilde/grave)
inserts nothing in neovim's insert mode and silently drops you back to normal mode.
Option+I (circumflex) is the only one that works. The same root cause made Option+E
open `$EDITOR` at the fish prompt (it tripped fish's `alt-e` -> `edit_command_buffer`).

Diagnosed end-to-end:

- It is **not** neovim, the kitty keyboard protocol, or the world nix config. Proven
  with `cat -v` (no protocol active): Option+E then `o` emits `^[eó` = `ESC` + `e` + `ó`.
  DanTerm sends the Alt-e escape sequence **and** composes the dead key for one keypress.
- The stray `ESC` exits neovim's insert mode, so the composed `ó` lands in normal mode
  and is discarded.
- DanTerm is our own libghostty terminal (`/Users/dan/world/my-apps/danterm`) and there
  is no newer libghostty to update to, so the fix lives in DanTerm's source.

Intended outcome: a single Option dead-key press composes cleanly (no escape sequence),
so accents work in neovim and every other app, with no change to normal typing,
Ctrl-combos, or Option-produced symbols (Option+8 = `•`). `macos-option-as-alt = true`
must keep emitting `ESC e` -- which the composing fix below would otherwise break, so the
fix also ports the reference's option-mods translation step to keep that config correct.

## Implementation history

- `a60721d fix(app): suppress alt dead-key escape during composition` implemented the
  reference-parity `keyDown` preprocessing: capture marked-text state, pass
  `composing: true` for textless dead-key preedit events, thread a `translationEvent` into
  `sendKeyEvent`, and compute `consumed_mods` from that translated event so explicit
  option-as-alt still emits an Alt sequence.
- `9fcc1a1 fix(app): preserve unset option dead-key composition` fixed a regression in the
  first commit: calling `ghostty_surface_key_translation_mods` unconditionally is not
  byte-identical when `macos-option-as-alt` is unset. The helper falls back to Ghostty's
  keyboard-layout heuristic (`embedded.zig:1752-1755`), and US layouts return
  option-as-alt `.true` (`keyboard.zig:45-52`). That stripped Option before AppKit saw the
  event, so Option+I no longer entered dead-key composition at all. DanTerm now calls the
  translation helper only when the config key is explicitly present; unset config leaves
  the original AppKit event intact.

## Root cause (source-verified)

`app/TerminalView.swift` `keyDown(with:)` (line 401) drives the macOS IME via
`interpretKeyEvents([event])`, then sends the key to libghostty:

- **Text branch** (`:415-419`): IME produced composed text (the final `ó`) ->
  `sendKeyEvent(..., text:)` with default `composing: false`. Correct.
- **No-text branch** (`:420-440`): during dead-key composition there is no composed
  text yet but `markedText` is set, so execution falls here and calls
  `sendKeyEvent(action, event: event, text: text)` -- again `composing: false`
  (`:439`). **This is the bug.** libghostty re-encodes the press as Alt-E -> `ESC e`.

Why the `composing` flag fixes it (libghostty source): the reported `cat -v` repro has no
keyboard protocol active, so encoding goes through the **legacy** encoder, where
`key_encode.zig:331` -- *"If we're in a dead key state then we never emit a sequence"* --
returns before writing anything when `composing` is true. (The kitty encoder has the same
guard at `key_encode.zig:146`, *"When composing, the only keys sent are plain modifiers"*,
so the fix also holds whenever a protocol is active.) So a composing Option+E emits nothing
(no `ESC e`), while the IME still composes and delivers `ó` on the next key via the text
branch. This is exactly what Ghostty's reference does
(`.ghostty-src/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1188-1194`:
`composing: markedText.length > 0 || markedTextBefore`).

The `sendKeyEvent` encoder already supports the flag
(`app/TerminalView.swift:469` `composing: Bool = false`, `:480`
`keyEvent.composing = composing`) -- the no-text call site just never sets it.

## The fix (reference-parity keyDown IME preprocessing)

All changes are in one file/method: `app/TerminalView.swift` `keyDown(with:)`. There are
two coupled parts: **composing suppression** (fixes the reported accent bug) and
**option-mods translation** (keeps `macos-option-as-alt = true` correct -- without it,
Part 1 would regress that config; see below). Both mirror Ghostty's reference
`SurfaceView_AppKit.swift keyDown` (`:1086-1196`).

### Part 1 -- composing suppression (fixes the reported accent bug)

1. Capture preedit state before the IME runs, just before the `interpretKeyEvents`
   call (currently `:413`):

   ```swift
   // Whether we had preedit (marked text) before this event, so the textless branch
   // below can tell an active/just-reset composition apart from a real key press.
   // Mirrors Ghostty's SurfaceView_AppKit keyDown.
   let markedTextBefore = markedText.length > 0
   ```

2. Pass `composing` in the no-text branch (currently `:439`). `event:` stays the original
   event; `translationEvent:` is added in Part 2 (step 6) and drives `consumed_mods`:

   ```swift
   // If the IME is composing (e.g. a macOS dead key like option+e for an acute
   // accent), this textless press must NOT be encoded: otherwise libghostty also
   // emits the Alt sequence (ESC e) alongside the later composed character, and the
   // stray ESC drops modal apps like neovim out of insert mode. markedText.length > 0
   // catches an active preedit; markedTextBefore catches a key that only cancels an
   // existing preedit. Mirrors Ghostty's SurfaceView_AppKit keyDown.
   sendKeyEvent(
       action,
       event: event,
       translationEvent: translationEvent,   // Part 2: feeds consumed_mods
       text: text,
       composing: markedText.length > 0 || markedTextBefore
   )
   ```

   `sendKeyEvent` already plumbs the flag (`:469` `composing: Bool = false`, `:480`
   `keyEvent.composing = composing`); the no-text call site just never set it. The
   `markedTextBefore` term (vs. the minimal `markedText.length > 0`) costs nothing extra
   and covers "a key just cancelled an active composition" (e.g. backspace during a CJK
   preedit).

### Part 2 -- option-mods translation (prevents a `macos-option-as-alt` regression)

Part 1 alone breaks `macos-option-as-alt = true`. DanTerm currently feeds the **original**
event to the IME (`:413` `interpretKeyEvents([event])`), so with option-as-alt on, macOS
still composes the dead key (the OS doesn't know about Ghostty's option-as-alt setting),
`markedText` gets set, the new `composing` evaluates **true**, and the `ESC e` an
option-as-alt user expects is suppressed. (Today they get `ESC e`, plus a messy pending
composition; after Part 1 alone they would get nothing.)

The reference avoids this by translating the modifiers *for the IME only* before
`interpretKeyEvents`: option-as-alt strips Option for composition, while the original
event -- still carrying the real Alt mod -- drives libghostty's encoder. DanTerm must use
that reference path only when `macos-option-as-alt` is explicitly configured. If the key is
unset, `ghostty_surface_key_translation_mods` uses Ghostty's layout heuristic; on US
layouts that heuristic strips Option and prevents AppKit dead-key composition, which is the
regression fixed by `9fcc1a1`. Port the reference behavior with that explicit-config gate
(reference `:1086-1127, :1155, :1186`):

3. Before `interpretKeyEvents`, compute translation mods and build a translation event:

   ```swift
   var translationMods = event.modifierFlags
   if Self.hasExplicitMacOSOptionAsAlt(ghosttyApp.config) {
       // Translate mods (maybe) for the IME so configs like macos-option-as-alt work:
       // libghostty says which mods to use for *translation* (composition);
       // option-as-alt strips Option there so it does not dead-key-compose, while
       // the ORIGINAL event below still carries Alt for libghostty's encoder.
       let translationModsGhostty = Self.eventModifierFlags(
           ghostty_surface_key_translation_mods(surface, Self.ghosttyMods(event.modifierFlags))
       )
       for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
           if translationModsGhostty.contains(flag) { translationMods.insert(flag) }
           else { translationMods.remove(flag) }
       }
   }
   // Reuse the original event when mods are unchanged (including unset/default config).
   // REQUIRED: AppKit relies on event object identity here to keep Korean/CJK input working.
   let translationEvent: NSEvent
   if translationMods == event.modifierFlags {
       translationEvent = event
   } else {
       translationEvent = NSEvent.keyEvent(
           with: event.type, location: event.locationInWindow,
           modifierFlags: translationMods, timestamp: event.timestamp,
           windowNumber: event.windowNumber, context: nil,
           characters: event.characters(byApplyingModifiers: translationMods) ?? "",
           charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
           isARepeat: event.isARepeat, keyCode: event.keyCode
       ) ?? event
   }
   ```

   For this to use an unwrapped `surface`, change the top-of-`keyDown` guard (`:402`) from
   `guard surface != nil else { interpretKeyEvents([event]); return }` to
   `guard let surface = surface else { interpretKeyEvents([event]); return }`. The current
   guard leaves `surface` optional in the body (it compiles only because the C `void*`
   param imports as implicitly-unwrapped); `guard let` matches how the rest of the file
   unwraps before every C call (`:471`, `:552`, `:563`, `:613`).

4. Feed the translation event to the IME: `interpretKeyEvents([translationEvent])`
   (was `[event]`).

5. In the no-text branch, derive `text` from `translationEvent` instead of `event` (keep
   the existing PUA / control-character filtering verbatim; for non-option keys
   `translationEvent == event`, so behavior is unchanged).

6. **Thread the translation event into the encoder so `macos-option-as-alt = true` still
   emits `ESC e` (load-bearing -- without this the option-as-alt path emits a bare `e`).**
   Keeping `event: event` is *not* sufficient: under option-as-alt the active path is the
   **text branch** (the IME inserts a plain `e`, so `keyTextAccumulator` is non-empty), and
   `sendKeyEvent` computes `consumed_mods` from the original Alt-bearing event
   (`:475-478`, subtracting only `[.control, .command]` -- so Alt stays consumed). The
   encoder's `effectiveMods = mods.unset(consumed_mods)` (`key.zig:53-56`) then cancels Alt
   whenever utf8 text is present, so `binding_mods.alt` is false and `legacyAltPrefix` bails
   (`key_encode.zig:542`) -- only `e` is written. The upstream encoder tests pin this
   contract: option-as-alt=true requires `consumed_mods = .{}` (`key_encode.zig:2069-2082`),
   false requires `consumed_mods = .{ .alt = true }` (`:2084-2098`). DanTerm's formula
   always yields the latter when Option is held -- right for the default config (why
   Option+8 = `•` works today), wrong for option-as-alt=true.

   The reference fixes this by deriving `consumed_mods` from the *translation* mods
   (`SurfaceView_AppKit.swift:1411` `event.ghosttyKeyEvent(action, translationMods:
   translationEvent?.modifierFlags)`). Mirror it: add a `translationEvent: NSEvent? = nil`
   parameter to `sendKeyEvent`, keep `keyEvent.mods` from the original `event`, and compute
   `consumed_mods` from `translationEvent ?? event`:

   ```swift
   private func sendKeyEvent(
       _ action: ghostty_input_action_e,
       event: NSEvent,
       translationEvent: NSEvent? = nil,
       text: String?,
       composing: Bool = false
   ) {
       ...
       keyEvent.mods = Self.ghosttyMods(event.modifierFlags)            // original: real Alt
       keyEvent.consumed_mods = Self.ghosttyMods(
           (translationEvent ?? event).modifierFlags.subtracting([.control, .command])
       )                                                                // translated: Alt stripped under option-as-alt
       ...
   }
   ```

   Pass `translationEvent: translationEvent` at **both** call sites: the text branch
   (`:418`) and the no-text branch (`:439`). For unset/default config the translation
   helper is skipped, so `translationEvent == event` and `consumed_mods` is byte-identical
   to today (Option+8 still yields `•`); for explicit `macos-option-as-alt = true` the
   stripped Option drops Alt from `consumed_mods`, the encoder keeps Alt in
   `effectiveMods`, and the `ESC e` prefix survives.

This needs two new helpers. First, the inverse of the existing `ghosttyMods` (DanTerm only
has the forward direction):

```swift
// ghostty_input_mods_e -> NSEvent.ModifierFlags. Inverse of ghosttyMods; only the four
// flags consulted by the translation loop need mapping. Mirrors Ghostty.eventModifierFlags.
static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue  != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue   != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
}
```

Second, a presence check for the optional enum config:

```swift
// `ghostty_config_get` returns false when optional config keys are unset, and true for an
// explicit enum value, including `macos-option-as-alt = false`. We only need presence here.
static func hasExplicitMacOSOptionAsAlt(_ config: ghostty_config_t?) -> Bool {
    guard let config else { return false }
    var value: UnsafePointer<Int8>?
    let key = "macos-option-as-alt"
    return ghostty_config_get(config, &value, key, UInt(key.utf8.count))
}
```

`ghostty_surface_key_translation_mods` is exported by the linked `GhosttyKit.xcframework`
(`Headers/ghostty.h:1092`), so no library rebuild is needed.

### Behavior across configs (correct by construction)

- **Unset `macos-option-as-alt` (Dan's default path):** skip Ghostty's translation helper
  entirely, so `translationEvent == event` and the IME sees exactly today's input
  (byte-identical default path -- also what keeps CJK working). Dead keys compose, the
  no-text branch fires, `composing` suppresses the stray `ESC e`. Bug fixed. This is the
  `9fcc1a1` correction: unset must not mean "let Ghostty's US-layout heuristic strip
  Option before AppKit sees the dead key."
- **Explicit `macos-option-as-alt = false`:** the translation helper is allowed to run
  because the user explicitly configured the key, but it returns the original modifiers.
  The resulting event remains identity/equivalent and dead keys compose normally.
- **Explicit `macos-option-as-alt = true` (or matching left/right):** Option is stripped
  for translation, so the IME sees a plain `e`, inserts it immediately, and the **text**
  branch runs with the original (Alt-bearing) `event` for `mods` but the translation event
  (Alt stripped) for `consumed_mods` (step 6). The encoder keeps Alt in `effectiveMods` ->
  `legacyAltPrefix` emits the `ESC e` prefix, with no stuck composition. Regression
  avoided. (Without step 6, `consumed_mods` would cancel the Alt and this would degrade to
  a bare `e`.)
- **Default option-produced symbols (Option+8 = `•`, Option+5):** single-press
  `insertText` -> text branch, untouched.

### Why other paths don't change

- `keyUp` / `flagsChanged` stay `composing: false` (release / bare-modifier events must
  encode normally) and don't go through the IME, so they pass no `translationEvent` (the
  `nil` default leaves `consumed_mods` computed from the original event, as today).
- The text branch keeps `composing: false` (it only runs on composed/inserted text) but
  does gain `translationEvent:` (step 6) so option-as-alt's `consumed_mods` is correct;
  for the default config that argument equals `event` and changes nothing.
- AppRuntime's programmatic injectors (`AppRuntime.swift:402-436`, IPC / keybinding
  actions) never go through the IME and correctly hard-code `composing = false`.

## Out of scope (independent follow-ups, not needed for this bug)

- The keyboard-layout-change guard (reference `:1141-1161`): captures `KeyboardLayout.id`
  before `interpretKeyEvents` and bails if an input method swapped the layout mid-event.
  Independent of both option-as-alt and this bug; optional reference-parity hardening that
  DanTerm has no `KeyboardLayout` helper for yet. Track separately.

## Testing

- **No automated test.** `TerminalView` is an AppKit + GhosttyKit shim, in no test
  target, and can't link GhosttyKit C symbols; the NSEvent -> `ghostty_surface_key`
  wiring is not unit-testable (AGENTS.md states app/ is non-unit-testable, confirmed:
  zero existing key-input/IME coverage). The composing predicate and the mods-translation
  decision both depend on live state -- `markedText` and the surface-bound
  `ghostty_surface_key_translation_mods` call -- so neither is cleanly unit-testable. The
  new `eventModifierFlags` helper is pure, but it just mirrors the already-untested forward
  `ghosttyMods`; a bit-mapping test would be low-value structure-sensitive theater that
  doesn't exercise the integration that can break. Skip it.
- **Behavioral contracts are pinned upstream (the spec to validate against).** The two
  claims that can break are already covered by libghostty's own encoder tests: `composing`
  suppression in the legacy/kitty encoders, and the exact `consumed_mods` contract the
  step-6 fix turns on -- option-as-alt=true => `consumed_mods = .{}`, false =>
  `.{ .alt = true }` (`key_encode.zig:2069-2098`). Read those as the reference for what the
  Swift `mods`/`consumed_mods` plumbing must produce; they are not run by DanTerm's
  `just test` (they live in the libghostty source, not the linked xcframework).
- **Compile gate:** `just build` (from `my-apps/danterm`; no GUI launch) -- required
  because this change lives in the AppKit app target and `just test` does not compile
  `app/TerminalView.swift`.
- **Regression gate:** `just test` (from `my-apps/danterm`; no GUI needed) -- protocol +
  core + support suites + purity lint must stay green, but it is not sufficient by itself
  for this AppKit file.

## Verification (end-to-end, manual -- human launches the app)

1. Build + install the dev app (does not launch): `cd ~/world/my-apps/danterm && just build`.
   (One-time prereq if never run: `./build-lib.sh`.)
2. Launch `~/Applications/DanTerm Dev.app` yourself (agent must not launch it).
3. In a fish prompt: `cat -v`, type Option+E then `o`, Enter. Expect `ó` (shown
   `M-CM-3`) with **no** `^[`. Was `^[eó` before. Repeat for Option+U/I/N/grave.
4. In neovim insert mode: Option+E `o` -> `ó`; verify all five dead keys insert and
   Option+I (circumflex) still works.
   The Option+I check specifically catches the `a60721d` regression fixed by `9fcc1a1`,
   where unset config still called Ghostty's layout-based translation helper and stripped
   Option before AppKit could compose.
5. No-regression spot checks (default config): normal typing, Ctrl-combos, Option+8 (`•`),
   and a CJK input method (e.g. Korean) still composes.
6. `macos-option-as-alt = true` check (Part 2): set `macos-option-as-alt = true` in the
   DanTerm config, relaunch, and in `cat -v` press Option+E. Expect `^[e` (ESC e), **not**
   a dead-key compose and **not** nothing. Restore the config afterward.
7. `just build` compiles the AppKit app target.
8. `just test` stays green.

## Related cleanup (separate repo, optional)

The committed fish change (`world` `7a16c2f`, `bind --erase alt-e` in
`hosts/macbook/modules/shells.nix`) was a workaround for a *symptom* of this same bug --
Option+E reaching fish as `ESC e`. After this fix Option+E no longer emits `ESC e` during
composition, so that workaround is no longer needed for the accent case. It also disables
fish's intentional `alt-e`/`alt-v` -> editor binding; revert it if you want that binding
back, or keep it if you never want Option+E opening the editor. Not part of this plan.
