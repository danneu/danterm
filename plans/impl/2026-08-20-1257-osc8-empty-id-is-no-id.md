# BUG-35: an empty OSC 8 `id=` is no id

## Problem

`OSC 8 ; id= ; http://a.test ST` stores a hyperlink whose `explicitId` is
`""` instead of `nil`. `dispatchOSC8` reuses an existing target whenever
`explicitId` and `uri` both match, so two unrelated runs written with a
blank id and the same URI (separated by an `OSC 8 ; ; ST` close) collapse
into one link: they highlight together on hover and count as one retained
target. With the parameter absent they are correctly two links.

Evidence: reproduced against `c47ebd7a`
(`lib/TerminalCore/Sources/TerminalCore/OSCPayload.swift#osc8ExplicitId`
returns `String(pieces[1])` with no emptiness check). References: VTE
(`references/vte/src/vteseq.cc#set_current_hyperlink`) autogenerates an id
when the `id=` value is empty; ghostty
(`references/ghostty/src/terminal/osc/parsers/hyperlink.zig#parse`) only
assigns a non-empty value and tests "hyperlink with empty id" -> null;
kitty keys its pool so empty and absent ids are identical. Only foot hashes
the empty string. Compatibility rule: references decide what a sequence
does, so DanTerm normalizes.

Audit entry: `docs/scratch/2026-08-18-construction-audit.md` BUG-35
(severity 1, unpinned, no wave).

## Decision

Normalize in the OSC 8 parameter decoder in `OSCPayload.swift`: it yields
no id when the `id=` value is empty, so no terminal-authored hyperlink ever
carries an empty explicit id. No change to `TerminalHyperlink`,
`dispatchOSC8`, or the round-trip emitters
(`Terminal.swift#hyperlinkSequence` and the tape serializer already omit
`id=` for a nil id).

Existing decision kept: the first `id=` field wins (pinned by
`OSCPayloadTests` "OSC 8 explicit ids use the first exact id field"), so
`id=:id=later` yields no id -- VTE's behavior, not ghostty's last-non-empty.

## Invariants

- I1. OSC 8 decoding never produces an empty explicit id: `id=` with an
  empty value behaves exactly as an absent `id` parameter, so a hyperlink
  built from terminal input has `explicitId == nil` or a non-empty string.
  `TerminalHyperlink.init` stays unnormalized; the invariant is the
  decoder's.
- I2. Two OSC 8 opens with an empty `id=` and the same URI, separated by a
  close, are two distinct retained targets (unchanged: with the same
  non-empty id they are one).
- I3. The URI is unaffected by the id normalization (existing J10 contract
  in `docs/design/2026-08-06-swift-terminal-engine.md`: a bad or missing
  id never invalidates a valid URI).

## Proof obligations

- PO1 (I1, I3). Terminal-level: feed `id=` with a URI and text; the cell's
  hyperlink equals `TerminalHyperlink(uri:)` with nil id.
  `TerminalHyperlinkTests`.
- PO2 (I2). Terminal-level: two `id=` opens of the same URI around a close
  -> `retainedHyperlinkCount == 2`; control with `id=7` on both -> 1.
  `TerminalHyperlinkTests`.
- PO3 (I1, first-wins). Decoder-level in `OSCPayloadTests`: `id=` -> nil
  and `id=:id=later` -> nil, beside the existing first-field case.

TDD: write PO1-PO3 first, see PO1/PO2/PO3 fail with `Optional("")` /
count 1, then change the decoder.

## Non-goals

- Changing the reuse rule in `dispatchOSC8`, id length limits, or
  the hover/activation path in `app/`.
- Adopting ghostty's last-non-empty id rule.

## Verification

- `swift test --package-path lib/TerminalCore --filter "TerminalHyperlinkTests|OSCPayloadTests"`
- `just test` (gate) before commit.
- Optional live check: `danterm --socket <slot> pane send` the byte pair
  from PO2 into a slot and confirm Cmd-hover highlights each run alone.
- Tick BUG-35 in the audit table with the commit hash, per the doc's
  plan-of-work instructions, in a follow-up `docs(audit):` commit.

