# Ignore decoded C1 controls in ground state

## Problem

DanTerm prints valid UTF-8 scalars U+0080 through U+009F as narrow cells. Each
one stores an invisible control scalar, advances the cursor, and shifts later
text. Current terminal references agree that these scalars must not consume a
cell.

The behavior survives in the current tree. The adapted libvterm UTF-8 fixture
records decoded U+0080 and U+0090 as visible terminal content, even though
decoder correctness is independently covered by `UTF8DecoderTests`.

## Decision

Ignore decoded U+0080 through U+009F in the stream's ground state. Consume the
valid UTF-8 input without producing a terminal action or mutating the grid.

The stream parser owns this policy. It must apply equally to ordinary
incremental decoding and decoded-scalar bulk recognition. Unicode width data
does not decide whether terminal protocol controls become printable content.

Update the engine design contract and fixture provenance ledgers with the same
policy. Correct the adapted libvterm terminal fixture so decoded C1 scalars do
not appear in its viewport while its malformed-input coverage remains intact.
Both its two-byte boundary expectation and its malformed early-restart
expectation change. Terminal-level U+0080 decoding evidence is intentionally
left to the decoder corpus case `C2 80 22`.

## Invariants

- A decoded C1 scalar in ground state produces no parser action, grid content,
  cursor movement, damage, or pending-wrap change.
- Raw bytes `0x80...0x9F` remain malformed UTF-8 and produce U+FFFD.
- U+00A0 and later printable scalars retain their current behavior.
- Bytes inside OSC, DCS, APC, PM, and SOS remain opaque to UTF-8 control
  interpretation.
- In ground state, DanTerm continues not to support raw C1 introducers, 8-bit
  ST, or S8C1T.
- Feed chunking cannot change any of these outcomes.

## Proof obligations

- Prove that every valid UTF-8 scalar from U+0080 through U+009F is ignored
  between printable sentinels under authored, bytewise, and split feeds.
  Include non-ASCII sentinels on both sides so a decoded-scalar run stops at
  the C1 scalar and resumes without dropping or duplicating content.
- Prove the boundary between raw malformed C1 bytes, ignored decoded C1
  scalars, and printable U+00A0.
- Prove under split feeds that OSC preserves exact C1-range payload bytes,
  while DCS, APC, PM, and SOS absorb them without C1 interpretation or
  premature termination.
- Reproduce the reported terminal behavior: `A\u{0092}B` in a 5x1 terminal
  displays `AB   `, stores no C1 scalar, and leaves the cursor at column 2.
- Prove that an ignored decoded C1 scalar leaves pending wrap armed at the last
  column, so the next printable still wraps, and that a feed containing only
  ignored decoded C1 scalars reports no damage.
- Keep the adapted UTF-8 fixture green under every feed split after removing
  decoded U+0080 from its two-byte boundary expectation and decoded U+0090
  from its malformed early-restart expectation.
- Run the focused stream, decoder, and fixture suites, then the full local
  gate.

## Non-goals

- Do not add 8-bit C1 parsing or a parser mode for it.
- Do not change rendering, PTY behavior, CLI behavior, or public APIs.
- Do not regenerate Unicode tables.

## Rejected ideas

- Marking Unicode category `Cc` as zero width. This hides a protocol decision
  in cell geometry and still sends ignored input through grid reduction.
- Executing decoded C1 controls. DanTerm deliberately does not implement 8-bit
  C1 semantics, so execution would add behavior outside this fix.
- Adding an explicit ignore action. Ignored input has no observable terminal
  effect and needs no reducer event.

## Implementation discretion

- The internal expression of the shared decoded-scalar policy, provided every
  ground-state decoding path uses one authority.
- The organization of parameterized test data, provided the proof obligations
  remain behavioral and structure-insensitive.

## Integration

The decoded-scalar bulk work in commit `9df876a9` added a second scalar exit
that this fix must cover. Expected merge overlap is limited to the stream
parser, its tests, the adapted UTF-8 fixture and provenance assertions, and the
engine design document. The current tracked working tree has no overlapping
changes.
