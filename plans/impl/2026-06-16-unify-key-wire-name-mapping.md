# Plan: unify the KeyName <-> wire-string mapping into one source of truth

## Context

The `pane.input` IPC path serializes and deserializes key names ("Enter",
"BSpace", "F12", ...). Today that one bijection is encoded by **three**
hand-maintained structures spread across **two** files in `DanTermProtocol`:

- `namedAliases: [String: NamedKey]` -- decode, non-function keys, many-to-one
  (`InputEvent.swift:40-56`)
- `parseFunctionKey(_:)` -- decode, F1-F12 only (`InputEvent.swift:58-74`)
- `wireName(for:)` -- encode, all 25 `NamedKey` cases + `.letter`
  (`CLIParser.swift:409-442`)

These must stay mutually inverse, and the drift is **silent and asymmetric**:
`wireName(for:)` and `macKeyMapping` are exhaustive switches with no `default`,
so adding a `NamedKey` case is a *compile error* there -- but the decode side
(`namedAliases` dict + defaulted `parseFunctionKey`) is **not** compiler-guarded.
So adding `.f13` forces an encode update while the decoder keeps rejecting
"F13", silently breaking the `parse -> JSON -> decode` round-trip. There is no
test pinning the round-trip today.

A **fourth** copy of the list lives in prose at
`integrations/danterm/SKILL.md:292-294` (a human-facing mirror; see "Out of
scope" for how it's handled).

**Outcome:** collapse the three code structures into one source of truth --
`NamedKey.wireName` -- from which the decode map is *derived*. After this,
decode-side drift is impossible by construction, and a `CaseIterable`
round-trip test pins encode/decode agreement so a future case that forgets to
round-trip fails a test instead of shipping a wire bug.

This touches only `DanTermProtocol`; it does **not** involve the `CoreEnv`
inject-vs-ambient seam (no home/id/time), and `wireName` is pure.

## Approach (full unification)

### 1. `lib/DanTermProtocol/Sources/DanTermProtocol/InputEvent.swift`

**Add `var wireName: String` on `NamedKey`** -- the single source of truth for
canonical serialization. Exhaustive switch, **no `default`** (a new case fails
to compile until given a wire name). Move the case->string bodies verbatim from
the current `CLIParser.wireName(for:)` `.named` arm (preserving exact strings:
`.bspace -> "BSpace"`, `.escape -> "Escape"`, `.pgUp -> "PgUp"`, `.f1.."F1"`, ...).

**Add `var wireName: String` on `KeyName`** that delegates, so the full encode
logic lives next to the type (not in the parser):

```swift
public var wireName: String {
    switch self {
    case .letter(let c): return String(c)
    case .named(let n):  return n.wireName
    }
}
```

**Derive `namedAliases` from `allCases`** and drop the explicit literal:

```swift
public static let namedAliases: [String: NamedKey] = {
    var map = Dictionary(uniqueKeysWithValues: NamedKey.allCases.map { ($0.wireName, $0) })
    // Decode-only aliases that have no canonical wireName of their own.
    map["Backspace"] = .bspace
    map["Esc"] = .escape
    return map
}()
```

This subsumes both the old canonical entries **and** the function keys (F1-F12
are in `allCases`), so:

**Delete `parseFunctionKey(_:)`** and its call inside `init?(wireName:)`. The
remaining `init?` body is: `namedAliases` lookup -> single-lowercase-letter ->
`nil`. "F12" now decodes via the first branch; "F30"/"F0"/"F01"/"F012" are
absent from the derived map and fall through to `nil` exactly as before.

**Update doc comments:** the `namedAliases` comment now states it is *derived*
from `NamedKey.wireName` plus the two decode-only aliases, and that
`NamedKey.wireName` is the source of truth; remove the `parseFunctionKey`
mention from `init?(wireName:)`; extend the file header to note encode goes via
`KeyName.wireName` (inverse of `init?(wireName:)`, pinned by a round-trip test).

### 2. `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift`

In `inputEventToJSON` (line 398) replace `wireName(for: key)` with `key.wireName`,
then **delete the private `wireName(for:)`** function (lines 409-442). Encode now
lives entirely in `InputEvent.swift`.

### 3. `lib/DanTermProtocol/Tests/DanTermProtocolTests/KeyTokensTests.swift`

Add the structure-insensitive guard (XCTest, matching the existing
`testWireName*` tests in this file -- this target is XCTest, not Swift Testing):

```swift
// Intent: every NamedKey's canonical wireName decodes back to that same key.
// Why it exists: NamedKey.wireName (encode) and namedAliases/KeyName(wireName:)
//   (decode) are now one derived pair; this CaseIterable sweep turns any future
//   case that forgets to round-trip into a test failure, not a silent wire bug.
// Scenario: spec-first invariant for the pane.input key serialization bijection.
func testEveryNamedKeyWireNameRoundTrips() {
    for k in NamedKey.allCases {
        XCTAssertEqual(KeyName(wireName: KeyName.named(k).wireName), .named(k),
                       "wireName round-trip failed for \(k)")
    }
}
```

The existing alias tests (`testWireNameBackspaceAlias`, `testWireNameEscAlias`)
and the F30/F0/F01/F012-rejection tests already cover the derived map's edges --
keep them as the regression net proving this change is behavior-preserving. (A
letter *round-trip* line here is redundant: the `.letter` encode arm is pinned
by the CLI wire-shape test in step 4, and letter *decode* by the existing
`testWireNameLowercaseLetter`.)

### 4. `lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift`

The round-trip test above pins the `KeyName.wireName` <-> `KeyName(wireName:)`
bijection, but **not** the encode path this plan rewires: `inputEventToJSON`
calling `key.wireName` and building the `params["input"]` array
(`CLIParser.swift:243`). The existing `pane input` test
(`CLIParserTests.swift:205-208`) asserts only method/pane/outputMode, never the
serialized payload -- so a bad `.letter` arm or a mis-wired `inputEventToJSON`
call would slip through. Add a required behavioral test pinning the exact `pane
input` JSON across all three `KeyName.wireName` arms a key can take -- a named
key, an F-key, and a modifier-letter (the last also pins the `mods` array):

```swift
// Intent: `pane input` serializes each token to the exact wire JSON the IPC
//   decoder consumes -- the encode path end-to-end (argv -> params["input"]).
// Why it exists: this plan moves key encoding into KeyName.wireName and rewires
//   inputEventToJSON; without asserting the payload, a bad `.letter` arm or a
//   mis-wired call ships silently (the round-trip and classifier tests miss it).
// Scenario: spec-first contract for the pane.input params["input"] array.
func testPaneInputSerializesKeyEventJSON() throws {
    let cmd = try parseCLI(["pane", "input", "--pane", "P1", "--", "BSpace", "F12", "C-c"])
    XCTAssertEqual(cmd.params["input"], .array([
        .object(["key": .string("BSpace")]),
        .object(["key": .string("F12")]),
        .object(["key": .string("c"), "mods": .array([.string("ctrl")])]),
    ]))
}
```

`BSpace` doubles as a check that the canonical name -- not the `Backspace`
alias -- is what gets emitted on the wire. `JSONValue.object` compares as a
dictionary, so the `key`/`mods` order in the expected value is irrelevant.

## Out of scope (named so the picture is complete)

- **`app/AppRuntime.swift:1495` `macKeyMapping(for:)`** -- a *different* mapping
  (`NamedKey` -> macOS kVK keycode), not a wire-name inverse, and already an
  exhaustive no-`default` switch (compiler-guarded). It stays. After this pivot,
  the only sites that change when adding a `NamedKey` case are `NamedKey.wireName`
  and `macKeyMapping` (both compiler-forced); `namedAliases` updates itself.
- **`integrations/danterm/SKILL.md:292-294`** -- prose mirror of the key list.
  This change adds/removes no key, so its content needs no edit now. It cannot
  be auto-derived (markdown), and a parsing test would be brittle; instead add a
  one-line `//` pointer comment above `NamedKey.wireName` noting SKILL.md is the
  human-facing list to update when a case is added. (Flag, don't over-engineer.)
- **`KeyTokens.swift`** -- unchanged. Function-shaped tokens are caught at Step 3
  before the Step 5 `namedAliases[token] != nil` guard, so widening the derived
  map to include F1-F12 does not alter classification; bare letters still fall to
  text at Step 6.

## Why this is safe

- **No `Dictionary` trap:** all 25 `wireName` values are distinct, so
  `uniqueKeysWithValues` never collides; the two aliases are added via subscript
  (overwrite-safe) and don't shadow any canonical name.
- **No init-order cycle:** `namedAliases` reads `NamedKey.wireName` (a pure
  computed property), never `KeyName(wireName:)`; `wireName` never reads
  `namedAliases`.
- **Non-breaking public API:** `namedAliases` stays `public`; it gains F1-F12
  keys (a more-correct superset) and is consumed only in-module.

## Verification

- `swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests`
  -- the new round-trip test and the new `pane input` wire-shape test
  (`testPaneInputSerializesKeyEventJSON`) pass; all existing `KeyTokensTests`
  (aliases, F-key rejection, classifier) and `CLIParserTests` still green,
  proving behavior preservation.
- `just test` -- full local gate (protocol XCTest + core + DanTermSupport +
  core-purity lint + shell self-tests).
- Manual end-to-end sanity (optional): `just build-run`, then from another pane
  `danterm pane input --pane <id> -- ls Enter` and `... -- F12` and confirm the
  target pane receives them (exercises CLI parse -> `key.wireName` -> JSON ->
  `KeyName(wireName:)` decode -> `macKeyMapping`).

## Critical files

- `lib/DanTermProtocol/Sources/DanTermProtocol/InputEvent.swift` (add
  `wireName` x2, derive `namedAliases`, delete `parseFunctionKey`, docs)
- `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift` (call
  `key.wireName`, delete `wireName(for:)`)
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/KeyTokensTests.swift` (add
  `NamedKey` round-trip test)
- `lib/DanTermProtocol/Tests/DanTermProtocolTests/CLIParserTests.swift` (add
  `pane input` wire-shape test pinning the encode payload)
