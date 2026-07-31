# Phase 4: UTF-8 stress coverage and DanTerm terminal-token selection

## Problem and evidence

Phase 4 has two open questions: whether the native incremental UTF-8 decoder
needs broader external boundary coverage, and whether double-click selection
claims Unicode UAX #29 word semantics.

The native suite covers representative malformed UTF-8, but not every lead and
continuation class, impossible bytes, the exact U+10FFFF boundary, or modern
acceptance of Unicode noncharacters. Markus Kuhn's 2015-08-28
[`UTF-8-test.txt`](https://www.cl.cam.ac.uk/~mgk25/ucs/examples/UTF-8-test.txt)
systematically covers that space under CC-BY-4.0. Its SHA-256 is
`b51cfe9a8d2689c90b10a13a3624092d546e0837c6ff835b6e5d713c5749c8c6`.
A probe over all 22,781 source bytes showed DanTerm's decoder already matches
Swift's maximal-subpart decoding exactly, so production decoder changes are not
expected.

DanTerm currently selects terminal-oriented runs using ASCII tab and space plus
the punctuation set inherited from Ghostty rather than UAX #29 words. Pure UAX
#29 would improve prose segmentation but split paths, flags, and shell tokens
that terminal users commonly copy as units. The current implementation does not
treat non-ASCII Unicode whitespace as a separator.

## Decision

- Adopt the missing Kuhn decoder categories as a neutral, provenance-bearing
  fixture with a bundled CC-BY-4.0 attribution notice.
- Keep terminal-token selection as DanTerm's hard-coded double-click contract.
  Own and describe this behavior as a DanTerm decision, not as Ghostty
  compatibility.
- Expand selection separators from literal tab and space to every Unicode
  whitespace scalar. This is an intentional double-click behavior change; the
  fixed punctuation list and maximal non-separator runs remain the
  terminal-token contract.
- Rename `clusterRange(at:)` to `terminalTokenRange(at:)`, without a
  compatibility alias, and replace the remaining `cluster` and Ghostty-
  compatibility vocabulary in selection granularity, documentation, and test
  names with DanTerm-owned terminal-token terminology. The experimental engine
  has no consumer outside this repository.
- Decline Unicode 17 `WordBreakTest.txt`; DanTerm does not claim default UAX #29
  word boundaries. Reconsider it only with a separate natural-language
  selection mode and a documented UAX tailoring profile.
- Decline vte's `utf8-test.cc` and `unicode-width-test.cc`: the neutral
  Kuhn-derived fixture covers the decoder gap without importing LGPL/GPL-
  derived cases, while DanTerm's generated Unicode width-policy suite already
  supplies exhaustive native width coverage.
- Close Phase 4 and D3 in the external-corpus research record with the audit,
  probe, adoption, and selection rationale.

## Invariants

- I1: decoder output follows modern maximal-subpart recovery, accepts valid
  scalars through U+10FFFF including noncharacters, and immediately resumes at
  the first valid byte after malformed input.
- I2: incomplete UTF-8 remains pending across feeds; corpus cases use a later
  printable sentinel to test recovery rather than inventing end-of-stream flush
  behavior.
- I3: the terminal-token separators are every Unicode whitespace scalar plus
  the hard-coded punctuation set: apostrophe, double quote, U+2502, backtick,
  pipe, colon, semicolon, comma, parentheses, brackets, braces, angle brackets,
  and dollar sign.
- I4: period, slash, hyphen, underscore, and equals remain token characters, so
  paths, identifiers, and command-line assignments remain selectable as whole
  runs.
- I5: adjacent separators form one selectable run. Tokens cross soft wraps but
  never hard-line boundaries.
- I6: selection classifies a projected grapheme unit by its leading scalar and
  never splits a grapheme or wide cell.
- I7: local click granularity remains character, terminal token, then trimmed
  logical line; repeated click counts cycle through the same three units.

## Proof obligations

- PO1: the neutral Kuhn fixture covers valid boundaries, every continuation and
  legacy lead class, incomplete sequences, impossible bytes, overlong forms,
  surrogate forms, out-of-range encodings, and valid noncharacters. Decoder
  expectations prove each category's replacement count and printable recovery;
  provenance, version, hash, and license remain recorded as fixture metadata
  and an attribution notice.
- PO2: terminal-token tests prove the complete hard-coded separator set,
  representative Unicode whitespace, adjacent separator runs, and the
  intentional non-separators using paths, identifiers, flags, assignments, and
  apostrophes.
- PO3: selection tests preserve grapheme atomicity, wide-cell boundaries,
  soft-wrap continuation, hard-line stopping, retained-history clamping, and
  double-click drag behavior.

## Non-goals and rejected directions

- Non-goal: no JSON setting, Preferences field, public selection-policy type,
  or runtime configuration path is added. The policy is hard-coded in DanTerm.
- Non-goal: no locale-aware or dictionary-based segmentation is introduced.
- Rejected: default UAX #29 selection, because it changes the terminal-token
  behavior this plan intentionally preserves.
- Rejected: importing Kuhn's suggested one-replacement-per-malformed-sequence
  presentation. The source is a stress instrument, not a conformance oracle;
  DanTerm retains its stricter maximal-subpart contract.

## Implementation discretion

- The internal representation of the fixed separator set is unrestricted as
  long as the observable set and allocation behavior remain appropriate for a
  pointer-selection path.
- The neutral fixture may group equivalent Kuhn cases compactly, provided every
  category in PO1 remains explicit and attributable.

## Implementation notes

- The pre-existing Phase 3 clarification in
  `docs/research/26-external-corpus-expansion/README.md` was preserved and
  included at the owner's direction when implementation continued over the
  overlapping working-tree edits.
