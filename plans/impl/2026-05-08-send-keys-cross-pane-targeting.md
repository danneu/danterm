# send-keys: target a specific pane with tmux-style key arguments

## Context

`danterm send-keys` today has two limitations:

1. **No cross-pane targeting.** Always sends to the *caller's* pane — the
   one identified by `$DANTERM_PANE` in the request context. A script in
   pane A cannot type into pane B.
2. **No special keys.** The argv is joined with spaces and sent through the
   `.sendText` Effect (`app/AppRuntime.swift:300`), which calls
   `ghostty_surface_text`. That API is **the paste path**, not key input.
   Verified in `.ghostty-src/`:
   - `embedded.zig:1786` doc: *"this isn't useful for sending escape
     sequences. For that, individual key input should be used."*
   - `Surface.zig:3237` `textCallback` calls `completeClipboardPaste`.
   - `input/paste.zig:34-90` `encode()` replaces these bytes with
     spaces (xterm parity, security):
     `0x00 NUL, 0x08 BS, 0x05 ENQ, 0x04 EOT, 0x1B ESC, 0x7F DEL,
     0x03 Ctrl-C, 0x1C, 0x15, 0x1A, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0F`.
   So `C-c`, `Escape`, `Backspace`, and any key emitting an ESC sequence
   (arrows, F-keys) cannot reach the PTY through this path. We must use
   `ghostty_surface_key` (`embedded.zig:1092` C-API) for those.

Goal: type real key sequences into any pane. The user-facing surface is
unchanged from the prior draft; the implementation pivots from
"client-side raw-byte translation + paste path" to "structured
text/key-event sequence + dispatch through `surface_key`".

Reference sources cross-checked:
- `app/TerminalView.swift:476-512` — DanTerm's existing key-event
  construction from NSEvent. Same struct shape.

## CLI surface

```
danterm send-keys [--pane <uuid>] [--literal] -- <token>...
```

Examples:
- `danterm send-keys --pane <uuid> -- "ls" Enter`
- `danterm send-keys --pane <uuid> -- vim Enter "i" "hello" Escape ":wq" Enter`
- `danterm send-keys --pane <uuid> -- C-c`
- `danterm send-keys --literal -- "Enter literally"`

`danterm ls` already exposes `id` per pane (`Model.swift:279`
`PaneSnapshot.id`) for discovery.

## Token classification rule (resolves F2)

In tmux-mode, each argv token is classified as text or key. The rule is
**deterministic and one-shot — no fall-through that contradicts itself**:

1. `literal` flag set → every token is `.text(token)`.
2. Token has a modifier prefix (`C-`, `M-`, `S-`, or any combination like
   `C-M-`):
   - **If any prefix is `S-`** (anywhere in the chain — `S-Tab`, `C-S-Up`,
     etc.) → **throw `unknownKey(token)` immediately**, without trying to
     resolve the base. V1 doesn't support shifted special keys; for
     letters use uppercase directly.
   - Otherwise: strip remaining prefixes; require the base to resolve to a
     known keyname or a single ASCII letter `a`-`z`/`A`-`Z`. If yes →
     `.key(base, mods)`. If no → throw `unknownKey(token)` (key-shaped but
     unresolvable).
   - Modifier-prefixed `Space` (`C-Space`, `M-Space`) is also out of
     scope and throws — see §Out of scope.
3. Token has function-key shape — starts with `F` followed by ASCII
   digits, with **no leading zeros**:
   - The accepted strings are exactly the twelve canonical names
     `F1`, `F2`, ..., `F12` (case-sensitive). Any other F-shaped token
     — including `F0`, `F01`, `F02`, `F012`, `F13`, `F+1` — throws
     `unknownKey(token)`. The wire decoder (`KeyName(wireName:)`) and
     the CLI token parser must agree on this exact set; do not lean on
     `Int(...)` to derive the suffix, since that silently accepts
     leading-zero variants and weakens the wire validation.
4. Token is exactly `Space` (no prefix) → **`.text(" ")`** (a literal
   single space). Routed through the structured-text path (`.sendInputText`)
   so it reliably emits 0x20 — sidesteps the question of how
   `surface_key` encodes a bare Space keycode with no UTF-8 text.
5. Token exactly matches a known keyname (`Enter`, `Tab`, `BSpace`,
   `Backspace`, `Escape`, `Esc`, `Up`, `Down`, `Left`, `Right`, `Home`,
   `End`, `PgUp`, `PgDn`, `Delete`) → `.key(keyName, [])`.
6. Otherwise → `.text(token)`.

Consequences:

| Token | Result | Note |
|---|---|---|
| `"ls"` | `.text("ls")` | step 6 fall-through |
| `"Enter"` | `.key(Enter, [])` | step 5 keyname |
| `"Space"` | `.text(" ")` | **step 4 — bare Space goes through text path** |
| `":wq"` | `.text(":wq")` | step 6 |
| `"Entr"` | `.text("Entr")` | step 6 (no prefix, not a keyname) |
| `"C-c"` | `.key("c", [.ctrl])` | step 2 |
| `"C-yz"` | throws | step 2 — key-shaped + unresolvable |
| `"F5"` | `.key(F5, [])` | step 3 |
| `"F30"` | throws | step 3 — out of range |
| `"F01"` | throws | step 3 — leading zero; not a canonical name |
| `"F0"` | throws | step 3 — `F0` is not in the canonical set |
| `"S-Tab"` | throws | step 2 — S- rejected before base resolution |
| `"C-S-Up"` | throws | step 2 — any S- in the chain rejects |
| `"C-Space"` | throws | step 2 — modifier-prefixed Space is OOS |
| `"C-M-Up"` | `.key(Up, [.ctrl, .alt])` | step 2 |

`Insert` is dropped from v1 (no macOS HW keycode equivalent).

## Wire protocol

`Methods.sendKeys` (`app/Update.swift:1383`) is extended:

```jsonc
{
  "_ctx": { "paneId": "..." },          // unchanged
  "pane": "<uuid>",                     // NEW: optional explicit override
  "input": [                            // NEW: ordered events
    { "text": "ls" },
    { "key": "Enter" },                 // mods is optional; omitted == []
    { "text": "vim" },
    { "key": "c", "mods": ["ctrl"] }
  ],
  "text": "ls\r"                        // existing direct-IPC paste path
}
```

Resolution rules:

- Exactly one of `text` xor `input` must be present (else
  `invalid params: text or input required`).
- Pane resolution **(resolves F3)**:
  - If `pane` key is present in params, require it to be a non-empty
    string that resolves to an existing pane. A non-string `pane` value
    or an unknown UUID returns an error — never silently fall back to
    context.
  - Else use `_ctx.paneId`.
  - Else error `no pane in context`.

For `input`, each event is either `{"text": "..."}` or
`{"key": "<name>"}` / `{"key": "<name>", "mods": [<string>...]}`.
Events are dispatched in order to the resolved pane. The `mods` field
is **optional** and defaults to `[]` when omitted — `{"key": "Enter"}`
is a complete, valid key event. When present, recognized values in v1
are `"ctrl"` and `"alt"`. `"shift"` is **rejected** with
`invalid params: unknown mod shift` (parallel to the S- prefix being
out of scope at the CLI parser, F2). Any other mod string also returns
`invalid params: unknown mod <name>`. Non-array `mods` (e.g. a string
or number) → `invalid params: mods must be an array`.

Server emits Effects in the same order:
- `input` `.text` event → NEW `.sendInputText(paneId, text)` Effect.
  Routes through `ghostty_surface_key` with `keycode: 0`. This avoids
  paste-stripping AND bracketed-paste markers, so vim/htop receive
  characters as if typed.
- `input` `.key` event → NEW `.sendInputKey(paneId, key, mods)` Effect.
- Top-level direct-IPC `text` field → existing `.sendText(paneId, text)`
  Effect (paste path, `ghostty_surface_text`). The CLI no longer emits
  this field; it always sends structured `input`.

Why structured `text` doesn't reuse `.sendText`: the paste path strips
the bytes listed in §Context (incl. ESC, DEL, NUL, Ctrl-C, plus `\n`
mangling and bracketed-paste fence-posting) and applies bracketed-paste
mode if active, which alters how some TUIs see the input. Routing
tmux-mode text runs through `surface_key` with `keycode: 0` produces a
clean "as-if-typed" stream that matches what `.key` events look like
to the terminal.

## AppRuntime: route input through ghostty_surface_key (resolves F1)

Two new Effect cases in `app/Effect.swift`:

```swift
case sendInputText(paneId: PaneId, text: String)             // structured text run
case sendInputKey(paneId: PaneId, key: KeyName, mods: KeyMods) // named key event
```

Existing `.sendText(paneId:, text:)` is preserved unchanged for the
top-level direct-IPC `text` field. Both new cases call
`ghostty_surface_key`.

New `.sendInputText` handler:

```swift
case .sendInputText(let paneId, let text):
    guard !text.isEmpty,
          let surface = surfaces[paneId]?.surface else { break }
    var ev = ghostty_input_key_s()
    ev.action = GHOSTTY_ACTION_PRESS
    ev.keycode = 0
    ev.mods = GHOSTTY_MODS_NONE
    ev.consumed_mods = GHOSTTY_MODS_NONE
    ev.unshifted_codepoint = 0
    ev.composing = false
    text.withCString { ptr in
        ev.text = ptr
        _ = ghostty_surface_key(surface, ev)
    }
```

New `.sendInputKey` handler (next to the existing `.sendText`
handler at line 300):

```swift
case .sendInputKey(let paneId, let key, let mods):
    guard let surface = surfaces[paneId]?.surface else { break }
    let (keycode, codepoint) = macKeyMapping(for: key)   // total: no nil
    var ev = ghostty_input_key_s()
    ev.action = GHOSTTY_ACTION_PRESS
    ev.keycode = keycode
    ev.mods = ghosttyMods(mods)
    ev.consumed_mods = GHOSTTY_MODS_NONE
    ev.unshifted_codepoint = codepoint
    ev.composing = false
    ev.text = nil
    _ = ghostty_surface_key(surface, ev)
    // Send the matching release so any future key event isn't seen as a repeat.
    ev.action = GHOSTTY_ACTION_RELEASE
    _ = ghostty_surface_key(surface, ev)
```

`macKeyMapping(for:)` is a **total** function — an exhaustive switch over
the closed `KeyName` enum cases. Returns `(UInt32, UInt32)` directly,
not optional. Validation of incoming wire `key` strings happens at the
IPC handler boundary in `Update.swift` (see below), so by the time a
`KeyName` reaches the runtime it is already a valid case. No fallback
log/break path is needed. (Project convention is `print(...)` for
diagnostics — `AppRuntime.swift` lines 628-960; no `log.warn` namespace
exists.)

Initial table:

| Key | macOS keycode (kVK_*) | unshifted_codepoint |
|---|---|---|
| `Enter` | 36 (`Return`) | 0 |
| `Tab` | 48 (`Tab`) | 0 |
| `BSpace`/`Backspace` | 51 (`Delete`) | 0 |
| `Escape`/`Esc` | 53 (`Escape`) | 0 |
| `Up` | 126 (`UpArrow`) | 0 |
| `Down` | 125 (`DownArrow`) | 0 |
| `Left` | 123 (`LeftArrow`) | 0 |
| `Right` | 124 (`RightArrow`) | 0 |
| `Home` | 115 | 0 |
| `End` | 119 | 0 |
| `PgUp` | 116 | 0 |
| `PgDn` | 121 | 0 |
| `Delete` | 117 (`ForwardDelete`) | 0 |
| `F1`..`F12` | 122,120,99,118,96,97,98,100,101,109,103,111 | 0 |
| Letter `a`-`z` | `kVK_ANSI_A`..`kVK_ANSI_Z` (note non-sequential ordering) | ASCII codepoint of lowercase letter |

For modifier letters (e.g. `C-c`): keycode is the letter's `kVK_ANSI_*`,
mods include `ctrl`, `unshifted_codepoint` is the ASCII value of the
lowercase letter. Ghostty's keymap layer encodes the right terminal
bytes (and handles DECCKM/cursor-key-mode automatically — a free win
over the prior raw-byte plan).

`ghosttyMods(mods)` is `or`-combined `GHOSTTY_MODS_CTRL`,
`GHOSTTY_MODS_ALT`, `GHOSTTY_MODS_SHIFT`.

## Update.swift handler

Replace the body of `case Methods.sendKeys:` at `app/Update.swift:1383`
with a parser that:

1. Resolves `paneId` via the pane-presence-aware helper (F3).
2. Validates exactly one of `text`/`input` is present.
3. Validates each `input[i]` is well-formed (**all validation happens
   here so unknown values never reach the runtime**):
   - Must be an object with **either** a string `text` field **or**
     a string `key` field. Both/neither → `invalid params: input event
     must have text xor key`.
   - The `key` value must parse into the closed `KeyName` enum via
     `KeyName(wireName:)` (see `lib/DanTermProtocol/Sources/DanTermProtocol/InputEvent.swift`).
     Unknown name → `invalid params: unknown key <name>`. The accepted
     set is exactly the `KeyName` cases (`Enter`, `Tab`, `BSpace`/
     `Backspace`, `Escape`/`Esc`, `Up`, `Down`, `Left`, `Right`, `Home`,
     `End`, `PgUp`, `PgDn`, `Delete`, `F1`..`F12`, plus single lowercase
     letter `a`..`z` for modifier-letter combos like `C-c`).
   - The `mods` field is **optional**; when omitted, defaults to `[]`.
     When present, it must be an array (else `invalid params: mods must
     be an array`); each element must be `"ctrl"` or `"alt"`. `"shift"`
     and any other string → `invalid params: unknown mod <name>`.
4. For top-level direct-IPC `text`: emits `[.sendText(paneId, text), .ipcReply(...)]`
   (paste path).
5. For `input`: walks the validated typed events in order; emits
   `.sendInputText` for `.text` events and `.sendInputKey(paneId, KeyName, KeyMods)`
   for `.key` events, plus the trailing `.ipcReply`. **All structured
   input goes through `surface_key`** — the F1 fix.

The closed-enum validation at step 3 plus the total `macKeyMapping(for:)`
in `AppRuntime` together guarantee a malicious or buggy direct-IPC
client sending `{"key": "Bogus"}` gets a loud JSON-RPC error — never
a silent drop with `ok` reply.

New helper next to `resolveIpcPaneId` at `app/Update.swift:1506`:

```swift
// F3: explicit pane (if the key is present) must be a string AND must
// resolve. Don't silently fall back to context on a malformed/missing pane.
private func resolveSendKeysPane(
    params: JSONValue, context: IpcRequestContext, in model: AppModel
) -> Result<PaneId, String> {
    if case .object(let object) = params, let raw = object["pane"] {
        guard case .string(let str) = raw else {
            return .failure("pane must be a string")
        }
        guard let id = parsePaneId(str), model.panes[id] != nil else {
            return .failure("pane not found")
        }
        return .success(id)
    }
    if let id = resolveIpcPaneId(context, in: model) { return .success(id) }
    return .failure("no pane in context")
}
```

## CLI parser

The flag/separator parsing and token-to-event translation are extracted
into a free function in `DanTermProtocol` so they're testable in
`DanTermProtocolTests` **(resolves F4)**:

```swift
// lib/DanTermProtocol/Sources/DanTermProtocol/SendKeysArgs.swift
public struct ParsedSendKeys: Equatable {
    public let pane: String?
    public let events: [InputEvent]   // tmux-mode: from -- separator
}

public enum SendKeysParseError: Error, Equatable {
    case unknownFlag(String)
    case missingPaneArg
    case literalRequiresSeparator
    case missingArguments
    case keyToken(KeyTokenError)
}

public func parseSendKeysArgs(_ args: [String]) throws -> ParsedSendKeys
```

`cli/main.swift:96` calls `parseSendKeysArgs(...)`, then maps the result
to JSON-RPC params (`input`, plus optional `pane`). The CLI also catches
`keyToken` errors and re-throws them as a `CLIError` of the form
`unknown key: <token>`.

## Help text (resolves F5)

Update `usageText` at `cli/main.swift:34-63`:

```
  send-keys [--pane <id>] [--literal] -- <token>...
                              Send keystrokes to a pane (tmux-style: "ls" Enter,
                              C-c, Up, Escape). Use --pane to target a specific
                              pane (default: caller's via $DANTERM_PANE).
```

## Files to modify

- `lib/DanTermProtocol/Sources/DanTermProtocol/InputEvent.swift` — NEW
  (event enum + closed `KeyName` enum with `init(wireName:)` failable
  initializer + `KeyMods` option set with a `decode(wire:)` helper)
- `lib/DanTermProtocol/Sources/DanTermProtocol/KeyTokens.swift` — NEW
  (token classifier per the rule above)
- `lib/DanTermProtocol/Sources/DanTermProtocol/SendKeysArgs.swift` — NEW
  (testable CLI arg parser)
- `app/Effect.swift` — NEW cases `.sendInputText(paneId, text)` and
  `.sendInputKey(paneId, key, mods)`
- `app/AppRuntime.swift:300` — handle `.sendInputText` (`surface_key`
  with `keycode: 0, text: <text>`) and `.sendInputKey`
  (keyname-to-keycode table). Keep `.sendText` unchanged for the
  top-level direct-IPC `text` path.
- `app/Update.swift:1383` — extend `Methods.sendKeys`: accept `text` xor
  `input`, emit ordered Effects
- `app/Update.swift:1506` — `resolveSendKeysPane` (F3)
- `cli/main.swift:96` — call `parseSendKeysArgs`, build params
- `cli/main.swift:34-63` — `usageText` update (F5)
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/KeyTokensTests.swift` — NEW
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/SendKeysArgsTests.swift` — NEW (F4)
- `tests/UpdateIpcTests.swift` — new IPC tests (see below)

## Tests

### `KeyTokensTests` (new — `DanTermProtocolTests`)

- `parse([])` → `[]`
- `parse(["ls"])` → `[.text("ls")]`
- `parse(["ls", "Enter"])` → `[.text("ls"), .key(Enter, [])]`
- `parse([":wq"])` → `[.text(":wq")]`
- `parse(["Entr"])` → `[.text("Entr")]` (literal — no prefix, not a keyname)
- `parse(["C-c"])` → `[.key("c", [.ctrl])]`
- `parse(["C-yz"])` → throws `unknownKey("C-yz")`
- `parse(["M-x"])` → `[.key("x", [.alt])]`
- `parse(["M-Enter"])` → `[.key(Enter, [.alt])]`
- `parse(["C-M-Up"])` → `[.key(Up, [.ctrl, .alt])]`
- `parse(["F5"])` → `[.key(F5, [])]`
- `parse(["F12"])` → `[.key(F12, [])]`
- `parse(["F30"])` → throws `unknownKey("F30")` (out of range)
- `parse(["F0"])` → throws `unknownKey("F0")` (`F0` is not canonical)
- `parse(["F01"])` → throws `unknownKey("F01")` (**no leading zeros** —
  the parser must not accept `F01` as `F1`)
- `parse(["F012"])` → throws `unknownKey("F012")` (must not silently
  parse to `F12`)
- `parse(["F1a"])` → `[.text("F1a")]` (not Fn-shaped — trailing letter)
- `parse(["S-Tab"])` → throws (S- prefix rejected at step 2, regardless
  of whether base resolves)
- `parse(["C-S-Up"])` → throws (any S- in chain rejected)
- `parse(["Space"])` → `[.text(" ")]` (bare Space → literal space)
- `parse(["echo", "Space", "hi"])` → `[.text("echo"), .text(" "), .text("hi")]`
- `parse(["C-Space"])` → throws (modifier-prefixed Space is OOS)
- Literal mode: `parse(["Enter", "C-c", "Space"], literal: true)`
  → `[.text("Enter"), .text("C-c"), .text("Space")]` (literal-mode is
  exhaustive — every token is its own characters, including the word "Space")

Plus dedicated coverage for the wire-level `KeyName` decoder (used by
direct IPC clients that bypass the CLI parser):

- `KeyName(wireName: "Enter")` → `.named(.enter)`
- `KeyName(wireName: "Backspace")` → `.named(.bspace)` (alias)
- `KeyName(wireName: "Esc")` → `.named(.escape)` (alias)
- `KeyName(wireName: "F12")` → `.named(.f12)`
- `KeyName(wireName: "F30")` → `nil`
- `KeyName(wireName: "F0")` → `nil`
- `KeyName(wireName: "F01")` → `nil` (**must not** decode as `F1` —
  the wire validation has to reject leading-zero variants so a direct
  IPC client can't bypass the closed set with `Int`-based parsing)
- `KeyName(wireName: "F012")` → `nil`
- `KeyName(wireName: "c")` → `.letter("c")`
- `KeyName(wireName: "Bogus")` → `nil` (caller surfaces as `invalid params`)
- `KeyName(wireName: "")` → `nil`
- `KeyName(wireName: "ENTER")` → `nil` (case-sensitive, matches CLI parser)

### `SendKeysArgsTests` (new — `DanTermProtocolTests`) — **F4**

- No separator: `parseSendKeysArgs(["hello", "world"])`
  → throws `.missingArguments`
- Tmux mode: `parseSendKeysArgs(["--", "ls", "Enter"])`
  → `(pane: nil, events: [.text("ls"), .key(Enter, [])])`
- Explicit pane + tmux: `parseSendKeysArgs(["--pane", "P1", "--", "x"])`
  → `(pane: "P1", events: [.text("x")])`
- Explicit pane without separator: `parseSendKeysArgs(["--pane", "P1", "hello"])`
  → throws `.missingArguments`
- Literal flag: `parseSendKeysArgs(["--literal", "--", "Enter"])`
  → `.events([.text("Enter")])`
- `--literal` without `--`: `parseSendKeysArgs(["--literal", "hello"])`
  → throws `.literalRequiresSeparator`
- Unknown flag: `parseSendKeysArgs(["--bogus", "x"])`
  → throws `.unknownFlag("--bogus")`
- Missing pane arg: `parseSendKeysArgs(["--pane"])`
  → throws `.missingPaneArg`
- Empty: `parseSendKeysArgs([])`
  → throws `.missingArguments`
- Empty after `--`: `parseSendKeysArgs(["--"])`
  → throws `.missingArguments`
- Key parser error: `parseSendKeysArgs(["--", "C-yz"])`
  → throws `.keyToken(.unknownKey("C-yz"))`

### `UpdateIpcTests.swift` additions

Existing direct-IPC `text` test at `tests/UpdateIpcTests.swift:211`
keeps passing unchanged (`text`-only path with context pane).

New tests:

- `send-keys with input array emits ordered Effects via the key path` —
  `params: ["input": [{text:"ls"}, {key:"Enter"}]]` (note: no `mods`
  field on the key event — verifies the optional default), context pane.
  Expect **`.sendInputText(p, "ls")`** then `.sendInputKey(p, Enter, [])`
  then `.ipcReply`. (Note: `.sendInputText`, NOT `.sendText` — F1.
  And the omitted `mods` defaults to `[]` — wire contract default.)
- `send-keys with explicit empty mods is equivalent to omitted mods` —
  `params: ["input": [{key:"Enter", mods:[]}]]` produces the same
  `.sendInputKey(p, Enter, [])` Effect as the omitted form above.
- `send-keys with non-array mods (e.g. {key:"Enter", mods:"ctrl"})
  → "invalid params: mods must be an array"`.
- `send-keys with key + mods emits .sendInputKey with mods` —
  `params: ["input": [{key:"c", mods:["ctrl"]}]]`. Expect
  `.sendInputKey(p, .letter("c"), [.ctrl])`.
- `send-keys text field still emits .sendText (paste path)` —
  `params: ["text": "echo hi"]`. Expect `.sendText(p, "echo hi")`.
  (This is the existing `tests/UpdateIpcTests.swift:211` test, unchanged.)
- `send-keys with both text and input → invalid params`.
- `send-keys with neither text nor input → invalid params`.
- `send-keys with input event missing both text and key → invalid params`.
- `send-keys with input event having both text and key → invalid params`.
- **`send-keys with unknown key name (e.g. "Bogus") → "invalid params:
  unknown key Bogus"`** — proves wire-level validation catches it
  before any Effect is emitted; `.ipcReply.error` is set; **no
  `.sendInputKey` Effect appears in the result list** (this is the
  load-bearing assertion — it's how we verify the silent-drop bug from
  the prior plan no longer exists).
- `send-keys with non-string key value (e.g. number) → invalid params`.
- `send-keys with unknown mod name (e.g. "bogus") → invalid params:
  unknown mod bogus`.
- `send-keys with shift mod ("shift") → invalid params` (parallel to
  S- prefix being out of scope).
- `send-keys with non-array mods → invalid params`.
- `send-keys with explicit pane param targets that pane`.
- `send-keys with explicit pane that doesn't exist → "pane not found"`
  (and does **not** fall back to context).
- `send-keys with non-string pane (e.g. number) → "pane must be a string"`
  (F3 from prior round) — and does **not** fall back to context.
- `send-keys with no pane (empty context, no explicit) → "no pane in context"`.

### `TestHarness.swift`

- IpcTests are already registered (`ipcUpdateTests()`). No new entry needed.
- `KeyTokensTests` and `SendKeysArgsTests` run via
  `swift test --package-path lib/DanTermProtocol`, which is already
  invoked by `just test`.

## Verification

```sh
just test                                             # all unit tests pass
just build && just build-run

danterm ls
danterm pane split -h
# AppModelSnapshot exposes panes at the top level (Model.swift:210), not
# under .tabs[].panes — so pick the most recently created pane like this.
PANE_ID=$(danterm ls | jq -r '.panes[-1].id')

# round-trip with the corrected key path
danterm send-keys --pane "$PANE_ID" -- "echo hi" Enter        # expect "hi" in target
danterm send-keys --pane "$PANE_ID" -- C-c                    # interrupts target
danterm send-keys --pane "$PANE_ID" -- vim Enter "i" "hello" Escape ":wq" Enter
                                                              # confirm file written with "hello"
danterm send-keys --pane "$PANE_ID" -- htop Enter; sleep 0.3
danterm send-keys --pane "$PANE_ID" -- Down Down q            # arrow + quit

# Space token in tmux-mode (verifies bare Space → text(" ") routing)
danterm send-keys --pane "$PANE_ID" -- echo Space hello Enter # types "echo hello\r"

# literal
danterm send-keys --pane "$PANE_ID" --literal -- "Enter is text here"

# error paths
danterm send-keys --pane bogus -- foo                         # "pane not found"
danterm send-keys hello world                                 # usage error: missing -- before tokens
danterm send-keys --pane bogus hello                          # usage error: missing -- before tokens
danterm send-keys -- C-yz                                     # "unknown key: C-yz"
danterm send-keys -- S-Tab                                    # "unknown key: S-Tab"
danterm send-keys -- C-Space                                  # "unknown key: C-Space"
danterm send-keys --literal hello                             # "--literal requires --"

# Wire-level validation (direct IPC client bypassing CLI parser).
# When running from inside a DanTerm pane, $DANTERM_SOCK is already set to
# the right socket (dev or release). For the dev build (just build-run),
# the bundle id becomes com.danneu.danterm-dev (dev-build.sh:47), so the
# fallback path below uses that.
SOCK="${DANTERM_SOCK:-$HOME/Library/Caches/com.danneu.danterm-dev/control.sock}"
echo '{"jsonrpc":"2.0","id":"1","method":"send-keys","params":{"_ctx":{"paneId":"'"$PANE_ID"'"},"input":[{"key":"Bogus","mods":[]}]}}' \
  | nc -U "$SOCK" | tail -1
                                                              # response.error.message contains "unknown key: Bogus"
```

End-to-end pass condition: arrow keys move cursor in `htop`/`vim`,
`C-c` interrupts a running `sleep 999`, `Escape ":wq"` saves and
exits vim. These all fail under the prior `surface_text`-only plan
and are the load-bearing verifications for the F1 pivot.

## Out of scope

- DECCKM-aware emission. **Now handled automatically by Ghostty's
  keymap layer** because all input goes through `ghostty_surface_key` —
  improvement over the prior raw-byte plan.
- Bracketed-paste interaction with tmux-mode text. **Avoided entirely**
  because tmux-mode text routes through `surface_key` (`.sendInputText`),
  not `surface_text`. Legacy top-level `text` keeps paste semantics.
- Shifted special keys: `S-` prefix (e.g. `S-Tab`, `S-Up`) is rejected
  unconditionally in v1, even before base resolution. Likewise the
  wire-level `"shift"` mod is rejected.
- Modifier-prefixed `Space` (`C-Space`, `M-Space`). Rare; can revisit if
  someone actually needs `C-Space` to send NUL.
- `Insert` key (no native macOS keycode).
- Function keys F13+.
- `--dry-run`.
- Standalone Python/TS clients.
