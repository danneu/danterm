# Spell the Hangul grapheme-break rules as `==` chains

## Problem

`GraphemeBreakState.shouldBreak` (`lib/TerminalCore/Sources/TerminalCore/GraphemeBreak.swift:71-73`)
decides the GB6-GB8 Hangul rules by building four array literals and calling
linear `contains` on them. It runs once per non-ASCII printed scalar and once
per search-query scalar pair. Whether those literals allocate depends on the
optimizer; the five class predicates in the same file (`isControl`, `isExtend`,
`isIndicExtend`, `isEmojiSequenceClass`, `isIndicSequenceClass`) already spell
the same idea as `==` chains, so the file is internally inconsistent.

This resolves audit findings UNI-3 and FEED-5
(`docs/scratch/2026-08-18-construction-audit.md`) as one problem. Their vetting
corrections contradicted each other (bitmask vs `==` chains); a verify-issue
pass adjudicated for the chains.

## Decision

Rewrite the four array literals in the three Hangul rules as `==` chains,
matching the file's existing predicate style. No new vocabulary, no generator
change, no behavior change.

This is a representation/consistency cleanup. It claims no speedup; the
expected benchmark result is `equivalent`, so no benchmark run is part of the
change.

In the audit document, record the merged outcome before marking it done: the
X11 consolidated resolution and UNI-3's correction still prescribe the bitmask,
so rewrite both to say the merged FEED-5/UNI-3 fix is the `==` chains. Then mark
the UNI-3 and FEED-5 checkboxes done (lines 1227 and 1230), following the
existing `chore(audit): mark ... done` pattern. An audit whose resolution text
disagrees with what was built invites a later pass to reopen the work.

## Invariants

- I1: Grapheme boundary decisions are unchanged for every class pair.
- I2: Class-set membership in `shouldBreak` is expressed without constructing
  a collection, the same way as the file's existing class predicates.

## Proof obligations

- PO1 (I1), two parts. Membership is unchanged for every class pair because
  each rewritten expression is equivalent to the array literal it replaces --
  shown by inspection of the diff, which is what a finite enumerated set
  admits. Separately, the existing `GraphemeBreakTests` conformance suite
  (`lib/TerminalCore/Tests/TerminalCoreTests/GraphemeBreakTests.swift`, corpus
  sha pinned in the generated header) must still pass: it covers the official
  grapheme-boundary cases and is insensitive to how membership is spelled. No
  new tests.
- I2 holds by inspection of the diff; it has no behavioral test by design.

## Verification

- `swift test --package-path lib/TerminalCore --filter GraphemeBreakTests`
- `just test` before commit.

## Non-goals / Rejected ideas

- RI1: UNI-3's generated 19x19 pair-verdict table — rejected. `normalize`
  mutates state before any rule runs, and the GB9c/GB11/GB12 arms read and
  write state, so most pairs would be `consultState`: the table adds a
  generated artifact and a hand-transcribed precedence reading without
  removing the cascade.
- RI2: the `UInt32` class bitmask (FEED-5's headline, UNI-3's fallback) —
  rejected. It achieves its claimed uniformity only by also rewriting five
  correct `==`-chain predicates, and for 2-4-element sets the generated code
  is equivalent to comparisons. The chains are the file's existing uniform
  representation; the array literals are the deviation.
- Non-goal: the cold-path array-literal `contains` siblings
  (`Terminal.swift` OSC 133 dispatch, `DanTermConfigDocument.swift` parsing) —
  prompt/startup frequency, idiomatic as written.
- Non-goal: any perf claim or benchmark run. If anyone wants a number later,
  `just benchmark-feed-sample` is the diagnostic, separate from this change.

## Files

- `lib/TerminalCore/Sources/TerminalCore/GraphemeBreak.swift` (lines 71-73)
- `docs/scratch/2026-08-18-construction-audit.md` (X11 resolution, UNI-3
  correction, and the two checkboxes)
