# Extract the pure OSC payload decoders from Terminal.swift

## Context

Audit finding S53 (docs/scratch/2026-08-11-simplification-audit.md) observed
that `Terminal.swift` carries ~250 lines of byte-level decoders -- base64,
percent/hex decoding, selector and numeric parsing, hostname normalization --
declared as private instance methods on `Terminal`. Verification confirmed the
purity claim: none of them reads Terminal state (the one apparent exception,
`localFilePath`, reads only `machineHostname`), and `decodeBase64` already
takes its byte cap as a parameter.

The audit's broader file-splitting proposal is no longer one decision: search
has since moved into `TerminalSearch.swift` as its own stateful subsystem, while
`Terminal` retains the live grid, viewport changes, and damage. The current
`Terminal.swift` header still documents an explicit admission rule: live-screen
mutation or interpretation belongs in the file; "a representation, a table, or
a decision that can be made without the screen" does not. The decoders fail
that rule; the remaining OSC dispatch, reflow, and damage regions satisfy it.
So the right work here is the extraction the header's own rule already
endorses, and nothing more.

Desired outcome: the pure/impure boundary inside the OSC region becomes
visible in the file layout, the decoders become directly unit-testable, and
`Terminal.swift`'s header stays an accurate map.

## Decision

Move the pure payload decoders out of `Terminal` into a new file in
`TerminalCore`, as static functions under a single namespace. Only the
cohesive operations `Terminal` actually calls are internal (tests use
`@testable import`): `decodeBase64`, `decodedCanonicalBase64`,
`percentDecoded`, `parseOSCSelector`, `canonicalConEmuSelector`,
`progressPercent`, `canonicalExitStatus`, `oscColorComponent`,
`osc8ExplicitId`, `localFilePath`. Their leaf mechanics --
`appendDecodedBase64Quartet`, `base64Value`, `hexadecimalValue`,
`namesThisMachine`, `normalizedHost` -- stay private, so a later pure
refactor of the decomposition costs no test or API churn. The OSC `dispatch*` functions stay
in `Terminal.swift` -- they write semantic events, title/CWD, hyperlink
tables, and prompt-row stamps, which the header claims for that file.

Scope of the move -- every helper that is a decision made without the screen:

- base64: `decodeBase64`, `appendDecodedBase64Quartet`, `base64Value`,
  `decodedCanonicalBase64`
- percent/hex: `percentDecoded`, `hexadecimalValue`
- numeric/selector parsing: `parseOSCSelector`, `canonicalConEmuSelector`,
  `progressPercent`, `canonicalExitStatus`
- reply formatting: `oscColorComponent`
- OSC 8 params: `osc8ExplicitId`
- OSC 7 file-URI policy: `localFilePath`, `namesThisMachine`,
  `normalizedHost` (the last two are already static)

`hyperlinkByteCost` and the admission arithmetic stay: they price against
`Terminal`'s metadata budget, which is screen-anchored policy.

Decisive constraints:

- Extracted functions take every input as a parameter -- byte caps
  (`decodedCanonicalBase64`'s cap, currently read from
  `Self.maximumSemanticValueBytes`) and the machine hostname
  (`localFilePath`) included. The constants themselves stay defined on
  `Terminal`, which passes them at the call sites.
- The new file opens with a header stating its admission rule (pure byte
  decoding, no screen state) and the constraint that explains the hand-rolled
  base64: `TerminalCore` is Foundation-free (imports only `DequeModule`), so
  Foundation's codecs are not available.
- `Terminal.swift`'s header gains the new file in its "what deliberately
  lives elsewhere" list; the admission-rule text itself is unchanged.

## Invariants

- I1: The extracted decoders read no `Terminal` state; every limit and
  identity they consult arrives as a parameter.
- I2: Observable OSC behavior is unchanged -- which payloads are accepted or
  rejected, which events are emitted, and every byte cap keep their current
  values.
- I3: The security posture of OSC 7 host matching is preserved: only
  `localhost`, or the machine hostname modulo ASCII case / trailing dot /
  `.local`, is local; `mac.evil.com` never is.

## Proof obligations

- PO-I2: The existing `TerminalCore` suite passes unmodified. It already
  binds each moved decoder's behavior through fed bytes:
  `TerminalOSC52Tests` (base64 decode, 1 MiB clipboard cap),
  `TerminalShellEventTests` (canonical base64, exit-status grammar, 64 KiB
  decoded cap), `TerminalSemanticEventTests` (64 KiB semantic cap, OSC 7
  host rule), `TerminalQueryTests` (`oscColorComponent` through observable
  OSC 10/11 replies), `TerminalHyperlinkTests` (OSC 8 identity and size
  limits).
- PO-I3: The parametrized hostname tests in `TerminalSemanticEventTests`
  pass unmodified.
- PO-I1 / new coverage: each internal entry point gets direct unit tests of
  its acceptance/rejection boundary -- edge cases reachable today only by
  composing full OSC sequences (non-canonical base64 padding, truncated
  percent escape, selector overflow, exit-status leading zeros, out-of-range
  progress percent). Nothing tests a private leaf directly. Spec-first per
  repo TDD: the tests target the new API and are written before the move
  compiles.

## Non-goals / Rejected ideas

- RI1: Splitting the remaining `Terminal.swift` regions into per-seam extension
  files (`TerminalOSC.swift`, reflow, damage). Rejected: contradicts the file's
  documented one-file design, and each of those regions passes the header's
  admission rule. Search is outside this rejection because it already lives in
  `TerminalSearch.swift`. Overturning the remaining one-file design is a
  separate conversation about the header, not a simplification item.
- RI2: Replacing the hand-rolled base64/percent decoders with Foundation.
  Rejected: `TerminalCore` is Foundation-free by design.
- Non-goal: no change to `Terminal`'s public API, to any OSC sequence's
  handling, or to the other `Terminal.swift` regions.

## Implementation discretion

- The namespace and file name (e.g. `OSCPayload`), and whether
  `decodedCanonicalBase64` / `localFilePath` move whole or remain as one-line
  `Terminal` wrappers over moved primitives.

## Verification

- `swift test --package-path lib/TerminalCore` green, including the new
  decoder tests.
- `just test` as the full local gate before commit.
