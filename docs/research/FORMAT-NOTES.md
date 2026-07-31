# Format notes

The change log for the research-doc format itself, kept separately from the
format. Every entry is dated and has the same three parts: the **observation**
that prompted it, the **cost** that observation carried, and the **rule changed
or rejected** in response. A rule with no observation behind it is a guess; this
file is where the difference stays visible.

This file sits on the project side of the portable seam on purpose: it is
reachable from the project-notes block above `## Contract`, never from the
contract itself. What it records is what DanTerm's research practice actually
cost, including which rules are still supported by one research domain only. If
the contract in [README.md](README.md) is ever extracted as a portable skill,
the contract travels and this file does not.

The bar for an entry: the observation has to be a measurement or an incident,
not an impression. "The index feels long" is not an entry; "rows 15-23 run
471-10,327 characters against 90-260 for rows 1-14" is.

## 2026-07-31 -- docs grow unboundedly, and nothing at creation time predicts it

**Observation.** Doc 20 went 0 -> 1,353 lines in one day. Doc 19 went 282 ->
1,045 in the same day, starting from "nothing measured yet". Doc 8 reached
3,294. Nothing distinguished any of them at creation from doc 2, which is 34
lines and closed.

**Cost.** Once a doc is long enough that its `## Outcome` cannot be trusted as
the summary, every reader either pays the full read or works from a summary that
has drifted. Section-size measurement across the 13 largest docs located the
weight: `Findings log` is 39-61% of every doc and the largest section in all 13;
`Decision log` is absent in two but runs 24-29% in the three most recent.
Together, 53-76% (median ~68%). The orientation layer -- purpose, rules,
trigger, ledger -- is what a reader needs first and what gets crowded out.

**Rule changed.** A doc is a folder from doc 24 onward: `N-topic/` holding
`README.md`, `findings.md`, `decisions.md`, unconditionally. Anything else that
grows is promoted to its own file under one general rule and linked with a
blurb.

**Rejected: a size threshold.** A migration that has to be noticed
mid-investigation does not happen -- doc 17 reached 1,808 lines and nobody split
it -- and trajectory is not predictable when the doc is created, which is the
observation above.

**Rejected: one file per finding as the default.** Doc 17 would yield ~25 files
averaging ~55 lines, each owing a blurb. Findings here are effectively
write-once, so a finding's size is known when it is written and
promotion-on-size already covers the outliers.

## 2026-07-31 -- the index absorbed what the docs could not carry

**Observation.** Index rows 1-14 are 90-260 characters. Rows 15-23 run
471-10,327. Total index-row text went ~16,850 -> 36,298 characters in two days.

**Cost.** Checked against docs 15, 17, and 18: every oversized row is a lossy
duplicate of an `## Outcome` that already says it better, and doc 17's row
restated `F14`/`F17` conclusions its own file had since revised. So the cost is
paid twice -- every reader loads 36,298 characters to reach the table, and the
copy they read is the one that drifts. The mechanism is the same failure mode as
the entry above: the row becomes the real summary once the doc is too long to
summarize itself.

**Rule changed.** A row carries the doc number, a linked title, one clause
naming what the doc owns, and one clause on outcome or what it is waiting for.
No cell exceeds 100 characters. The diagnostic reading is part of the rule: a
row that will not fit means the doc's `## Outcome` is underwritten, so the fix
belongs there.

**Rule changed.** The index is two tables, `## Live` and `## Closed`, each in
ascending doc-number order. New docs are appended and new docs are live, so a
single appended table buried activity at the bottom while the top became
archive, and no position meant "active". Membership is now the only record of
liveness, replacing the textual convention that a doc was live iff its own row
said so.

**Rejected: reverse-numeric order, or status-sorting one table.**
Reverse-numeric is zero-churn but only approximates the goal -- doc 1 is live
and would land at the bottom. Status-sorting shuffles rows on every status edit
and breaks lookup-by-citation.

## 2026-07-31 -- the row-length rule was never written down, only practised

**Observation.** Rows 1-14 held 90-260 characters, but the contract had no
bullet about index rows at all -- no cap, no shape, nothing. Fourteen rows of
consistent brevity were habit, not a rule. Once the practice lapsed nothing
caught it, and the next nine rows ran to 10,327 characters over two days.

**Cost.** The whole growth happened between one review and the next, and it was
found by a deliberate audit rather than by anything routine.

**Rule changed.** The cap is written down *and* machine-checked, by
`scripts/research-index-lint.sh`, wired into `just test`, with a fixture-tree
self-test beside it. Written down alone was the option not taken: a convention
this format kept without help for fourteen rows still failed, so prose has
already been observed here to be insufficient against the one pressure that
breaks it. The deeper point is not tidiness -- this format is a testbed for a
portable skill, and a format whose failures surface as test failures can still
be changed cheaply.

**Not checked, deliberately.** The lint measures row length, not row quality --
a short uninformative row passes, and no mechanical check distinguishes them.
Nor does it check which *number* a new doc claims. Both are known gaps, not
oversights.

## Rules still under watch

These three are load-bearing in the contract but supported only by performance
research, which is one domain with unusually quantitative evidence. They may be
overfit. Each needs an observation from a second kind of investigation -- a
correctness bug hunt, an API design study, a dependency evaluation -- before it
is safe to treat as portable.

- **The findings/decisions split.** Justified above by section-size measurement
  across 13 performance docs. An investigation that produces few discrete
  measurements may find the two files mostly empty and the split pure ceremony.
- **Phases as an evidence funnel** (baseline -> attribute -> compare -> gate ->
  implement -> close). This is the shape of a profiling investigation. Research
  that is exploratory rather than diagnostic may have no baseline to establish
  and no single cause to attribute.
- **"Claims cite evidence."** Written around benchmark provenance -- benchmark,
  commit, compatibility conditions -- where the citation is cheap and the number
  is meaningless without it. What the equivalent is for a qualitative claim is
  not yet established here.
