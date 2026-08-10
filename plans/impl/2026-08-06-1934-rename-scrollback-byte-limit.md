# Rename `Terminal.productionScrollbackBudgetBytes` -> `Terminal.scrollbackByteLimit`

## Context

`Terminal.productionScrollbackBudgetBytes` (lib/TerminalCore/Sources/TerminalCore/Terminal.swift)
is the public per-pane retained-history byte bound. The `production` prefix is
noise -- there is no non-production sibling -- and `BudgetBytes` restates the
type. `scrollbackByteLimit` says the same thing shorter.

The rename is behavior-preserving: the value stays 16,777,216, pinned by
`TerminalScrollbackBudgetTests`. What the rename does change is visibility --
after it, the engine's live contract doc and the resize probe's own doc
comments will visibly disagree with the constant they describe, because both
still say the budget is 10 MiB. Correcting that staleness is in scope; a rename
that leaves the shipped limit documented as the pre-`research/28/D11` value
would let future work restore the wrong eviction bound.

## Changes

**1. The symbol.** `productionScrollbackBudgetBytes` -> `scrollbackByteLimit`
everywhere it appears in the working tree's Swift sources and tests, including
inside comments and `file#identifier` citations (a citation naming the old
identifier no longer resolves). Callers' own `scrollbackBudgetBytes:` argument
labels are a different name and stay unchanged. Find the sites by search, not
from a list; the compiler and the verification grep below close the loop.

`Terminal.minimumScrollbackBudgetBytes` stays as it is. It is the internal
initializer's minimum *valid* arena budget, not the low end of this bound --
internal callers legitimately request budgets above and below the production
figure -- so renaming it alongside would make it less accurate, not more.

**2. The live contract doc.** In
[docs/design/2026-08-06-swift-terminal-engine.md](docs/design/2026-08-06-swift-terminal-engine.md),
rows `D5` and `D9` both still state a 10 MiB budget. Amend both to 16 MiB, and
give `D5` the `Terminal.scrollbackByteLimit` reference so the number has a
source. Both rows are `live`, and a `live` row states the shipped contract.

**3. Present-tense probe documentation.** `TerminalResizeProbeSupport.swift`
describes its current recipes as running against a 10 MiB budget -- the
`ResizeProbePayload` header's density comparison and the `saturating` recipe's
doc comment. They run against `scrollbackByteLimit`. Update the budget and any
row count derived from it in text that describes what the recipes do *now*,
deriving depths from the constant and the B/row figures the comments already
state (the store reserves budget/16, so the arena is the capacity that divides).
Leave genuinely historical text alone: the constant's own 10-to-16 MiB
derivation, the `SearchMatchCache` comment recording the condition that
motivated the cache, and the measured 10 MiB citations in
`TerminalResizeProbeSupportTests` are records of what was true when measured.
Do not invent a number no source supports -- if a derived depth cannot be
recomputed from figures already in the tree, drop the figure rather than
guess it.

## Scope exclusions

- `.claude/worktrees/*` -- separate checkouts, not this branch's tree.
- `plans/impl/*`, `docs/research/*`, `docs/scratch/*` -- historical records;
  they document what the symbol was called and what the budget was when they
  were written.

## Verification

- `swift build --package-path lib/TerminalCore` -- the compiler finds every
  missed Swift reference; a rename that builds is a rename that is complete.
- `swift test --package-path lib/TerminalCore` -- behavior is unchanged, so the
  suite must pass with no assertion edits.
- `grep -rn productionScrollbackBudgetBytes lib/ app/ docs/design/` returns
  nothing.
- `grep -rn '10 MiB' lib/ docs/design/` returns only the historical text named
  above.

## Implementation notes

- The `ResizeProbePayload` header's density comparison now states the arena
  capacity (15,728,640 bytes) rather than the budget, so both depths recompute
  from the sentence itself: `15,728,640 / 4,607 = 3,414` and
  `15,728,640 / 186 = 84,562`. Neither old number could be scaled forward. The
  old 2,276 divided the full 10 MiB budget rather than the arena, and 56,273 was
  a measured figure with no derivation in the tree, so the two were not even in
  the same lineage.
- The `saturating` recipe's "~82,000 rows" became ~42,000, not `82,000 x 1.6`.
  No charge rate anywhere in the tree supports 82,000, so it was not a figure to
  scale. `TerminalResizeProbeSupportTests` measures the dense payload at 373
  B/line, giving `15,728,640 / 373 = 42,168`, and the same test's measured 2.85x
  dense margin over a 120,000 `lineCount` gives `120,000 / 2.85 = 42,105`
  independently.
