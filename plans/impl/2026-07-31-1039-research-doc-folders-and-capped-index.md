# Research doc system: folder form, capped index, enforced contract

## Context

`docs/research/` is a testbed for a portable research skill. Two failure modes
have now been observed empirically rather than predicted, and both are drift
under load rather than bad rules.

**Individual docs grow unboundedly and unpredictably.** Doc 20 went 0 -> 1,353
lines in one day. Doc 19 went 282 -> 1,045 in the same day, from "nothing
measured yet". Doc 8 is 3,294. Nothing at creation time distinguished these from
doc 2, which is 34 lines and closed.

**The index absorbs what the docs can't carry.** Index rows 1-14 are 90-260
characters. Rows 15-23 run 471-10,327. Total index-row text went ~16,850 ->
36,298 characters in two days. The mechanism: once a doc is too long for
its own `## Outcome` to be trusted as the summary, the index row quietly becomes
the real summary and then has to carry everything. Same root cause as the first
failure mode.

Verified against docs 15, 17, 18: every oversized row is a lossy duplicate of an
`## Outcome` section that already says it better, and doc 17's row restates
`F14`/`F17` conclusions its own file later revised. The index is a second copy
that drifts.

Section-size measurement across the 13 largest docs sets the split point:
`Findings log` is 39-61% of every doc and the largest section in all 13.
`Decision log` is absent in two docs but 24%, 26%, 29% in the three most recent.
Together, 53-76% (median ~68%).

Intended outcome: new docs are born in a form that scales, the index stays
scannable, and both properties are enforced by `just test` rather than by habit
-- so the format's failures show up as test failures while it is still cheap to
change.

## Decision

Three changes, one contract.

**D1 -- New research docs are folders.** Doc 24 onward is created as
`N-topic/` containing `README.md`, `findings.md`, `decisions.md`. Unconditional:
no size threshold. `README.md` holds purpose, investigation rules, trigger,
hypotheses, task ledger, rejected, open questions, and outcome -- the
orientation layer the reading-order rule already sends agents to first.

Anything else that grows -- a large finding, a hypotheses section, reproduction
recipes, scratch evidence -- is promoted to its own file in the folder under one
general rule, rather than a menu of named files. Two named defaults plus one
promotion rule, because the third-tier sections are not universal across docs
and naming them would encode performance research specifically.

**D2 -- The index row is capped and enforced.** A row carries the doc number, a
linked title, one clause naming what the doc owns, and one clause on what
changed (or, for a live doc, what it is waiting on). Nothing else -- status is
carried by table membership per `D3`. The arc, the evidence, and the reopening
condition live in the doc's `## Outcome`; a durable cross-cutting lesson goes in the
README's "results worth knowing" block or graduates to `agent-docs/`.

The diagnostic reading is part of the contract: **a row that will not fit means
the doc's `## Outcome` is underwritten -- fix it there.**

**D3 -- The index is two tables, `## Live` and `## Closed`.** New docs are
appended and new docs are live, so a single appended table buries activity at
the bottom while the top becomes archive, and no position reliably means
"active". Each table stays in ascending numeric order, so lookup by citation
(`17/F7` -> doc 17) still works by scan.

Membership carries liveness structurally, replacing today's textual convention
that "a file is live iff its own row says so". Closure is one-way under the
existing contract -- reopening gets a new number and a backreference -- so a row
moves tables at most once, in a commit that means something.

The two tables take different final columns: a closed doc's useful field is what
changed, a live doc's is what it is waiting on. Forcing both through one
Result-shaped cell is part of why the live rows are among the fattest today.

**D4 -- The contract is machine-checked.** A new `scripts/research-index-lint.sh`
plus `scripts/tests/research-index-lint_test.sh`, wired into `just test`,
following the established pattern of `scripts/core-purity-lint.sh` and its
self-test. A documented-only cap is what exists today, and rows still reached
10,327 characters.

## Invariants

- **I1** -- Every research doc has exactly one index row across both tables, and
  every index row's Doc cell links to that doc's canonical path -- `N-topic.md`
  for a flat doc, `N-topic/README.md` for a folder doc. A row whose link is
  absent, unresolvable, or pointing at a different doc is a violation, not just
  a cosmetic defect: the link is how a reader navigates across two storage
  forms. No orphans in either direction.
- **I2** -- The index is exactly two tables, `## Live` and `## Closed`. Each is
  unbroken and in ascending doc-number order. (`docs/research/README.md:29` is a
  blank line today, orphaning rows 17-23 out of the single table.)
- **I3** -- No index cell exceeds 100 characters.
- **I4** -- Every Result cell in `## Closed` opens with a word from a fixed
  vocabulary: `Shipped`, `No change`, `Rejected`, `Declined`, `Superseded`,
  `Tooling`. The `## Live` table's final column is free text under the cap,
  because a live doc has no result yet.
- **I5** -- The set of docs permitted to stay flat `N-topic.md` is **frozen at
  the docs that exist when this lands**, enumerated rather than expressed as a
  numeric range. Everything else must be a folder `N-topic/README.md`. The set
  is enumerated because a range is a claim about numbers rather than about
  files, and the number line has a hole in it: `5-topic.md` is a file that does
  not exist inside a range that would admit it. Enumeration says what it means
  -- these files, no others. This is what makes `D1` enforced rather than merely
  documented; it constrains form, not number allocation (`AR5`).
- **I6** -- Every markdown file in a doc folder other than `README.md` is
  linked from that `README.md` with a one-line blurb. A supporting file that
  nothing links to is unreachable and does not exist as far as a reader is
  concerned.
- **I7** -- The portable/project seam holds: below the `## Contract` heading, no
  markdown link resolves outside `docs/research/`. Generic research prose,
  placeholder paths (`N-topic.md`), and citation-syntax examples (`9/F3`) are
  portable content and stay. The seam is defined by outbound links only --
  vocabulary is not policed.

## Proof obligations

Each is discharged by a case in `scripts/tests/research-index-lint_test.sh`,
which builds fixture trees and asserts the lint's exit status.

- **PO1** (I1) -- A doc with no row fails; a row naming no doc fails; a doc
  appearing in both tables fails. Correct links to a flat doc and to a folder
  doc both pass; an unlinked Doc cell, a link to a nonexistent path, and a link
  resolving to a different doc each fail.
- **PO2** (I2) -- A table split by a blank line fails; rows out of ascending
  order fail.
- **PO3** (I3, I4) -- An over-cap cell fails; a `## Closed` Result cell opening
  with a word outside the vocabulary fails.
- **PO4** (I5) -- Every doc in the frozen flat set passes as a flat file; a new
  flat doc fails, including one claiming an unused historical number such as
  `5-topic.md`; a new folder doc passes; a tree mixing the two forms passes.
- **PO5** (I6) -- A folder whose `README.md` links and blurbs both `findings.md`
  and `decisions.md` passes; the same folder with one of them unlinked fails.
  The positive case is required: a lint that rejected every supporting file
  would satisfy the negative case alone and stay green against today's all-flat
  tree, then reject the first folder created under `D1`.
- **PO6** (I7) -- A link to a path outside `docs/research/` below the
  `## Contract` heading fails. Portable prose containing `9/F3`, the word
  benchmark, and a `N-topic.md` placeholder link passes.
- **PO7** -- The lint fails against `docs/research/README.md` as it stands
  today, before the index rewrite, and passes after. Write the lint first and
  observe the red.

## Deliverables

- `scripts/research-index-lint.sh`, `scripts/tests/research-index-lint_test.sh`,
  both wired into the `test` recipe in `justfile`.
- `docs/research/README.md`: index split into `## Live` (docs 1, 18, 19, 21) and
  `## Closed` (the other 18), all 22 rows rewritten to the cap, Contract section
  extended with D1/D2/D3's rules and an explicit note naming the frozen set of
  grandfathered flat docs, seam marked at the `## Contract` boundary, and the one
  outbound link below it removed or relocated above the seam (the "Claims cite
  evidence" bullet hard-links `agent-docs/terminal-performance.md`; it is the
  only below-seam link besides the `N-topic.md` placeholder).
- `docs/research/FORMAT-NOTES.md`: dated `observation -> cost -> rule changed or
  rejected` entries, above the seam so it never ships with the skill. Seed it
  with the evidence in this plan's Context, and with the three rules whose
  support is performance-research-only and may be overfit -- the
  findings/decisions split, phases-as-evidence-funnel, and "claims cite
  evidence".

Example of the target shape, for the pattern rather than the wording:

```markdown
## Live

| # | Doc | Owns | Next |
| --- | --- | --- | --- |
| 19 | [Owner-queue occupancy](19-owner-queue-occupancy.md) | How long one job holds the PTY host's queue, and who waits | Why stacked prompts survive a resize storm |

## Closed

| # | Doc | Owns | Result |
| --- | --- | --- | --- |
| 11 | [Render frame budget](11-render-frame-budget.md) | Whether the draw path fits the 60Hz budget | No change -- it fits; none warranted |
| 24 | [Some later topic](24-some-later-topic/README.md) | ... | ... |
```

## Verification

1. `./scripts/research-index-lint.sh` against the unmodified README -- must
   fail, naming the broken table and the over-cap rows (PO7).
2. `./scripts/tests/research-index-lint_test.sh` -- all cases pass.
3. Rewrite the index, then re-run the lint -- must pass.
4. `just test` -- full local gate green with the two new entries.
5. Render `docs/research/README.md` and confirm two continuous tables with the
   four live docs at the top.

## Non-goals

- Migrating the existing docs to the folder form. Explicitly scoped out; the
  lint accepts them as flat indefinitely. It does not accept a *new* flat doc --
  see `I5`.
- Adding a machine-readable status marker to doc bodies. See `AR4`.
- Editing the body of any research doc.
- Renumbering the "results worth knowing" block into citable `R1..Rn` entries.
  Capping the table pushes pressure onto that block and it has no cap of its
  own, but it is a separate pass.
- Extracting the skill itself.

## Accepted risks

- **AR1** -- The index can no longer convey a doc's full arc without opening the
  doc. Accepted: verified redundant with each doc's `## Outcome`, and it costs
  one file read by the rare reader who wants the arc against 36,298 characters
  loaded by every reader who does not.
- **AR2** -- Flat and folder docs coexist indefinitely, so links have two
  shapes. Accepted as the price of not migrating.
- **AR3** -- The lint checks row length, not row quality; a short uninformative
  row passes. No mechanical check distinguishes them.
- **AR4** -- Closing a doc requires moving its row between tables, and nothing
  detects a missed or wrong move in either direction. Accepted rather than
  fixed: `D3` makes membership the sole record of liveness, so there is no
  second authority to cross-check it against. Sixteen of the twenty-two docs
  carry no `**Status:**` line at all, and of the six that do, only two are
  doc-level headers -- the rest annotate an individual finding partway down the
  file. A check would first require adding a doc-level marker to twenty bodies -- excluded by the Non-goals. This is the
  status quo; today a stale `LIVE` in a row goes equally undetected.
- **AR5** -- Nothing checks which *number* a new doc claims, so a folder
  `5-topic/` -- a number the index records as absent -- passes. Accepted:
  `I5` governs storage form, and number allocation is a separate existing rule
  whose own contract text (`next unused integer`) does not unambiguously
  forbid it. The lint does not regress it either -- both forms of doc 5 are
  equally unchecked today, and `I5` newly blocks the flat one.

## Rejected ideas

- **RI1** -- A size threshold for when a doc becomes a folder. A migration that
  must be noticed mid-investigation does not happen (doc 17 reached 1,808 lines
  and nobody split it), and trajectory is unpredictable at creation.
- **RI2** -- One file per finding as the default. Doc 17 would yield ~25 files
  averaging ~55 lines, each needing a blurb. Findings are effectively write-once
  here, so a finding's size is known when written and promotion-on-size covers
  it.
- **RI3** -- Named default files for hypotheses, reproduction recipes, or
  instruments. Not universal across docs, and they encode performance research
  specifically -- the overfit the skill extraction has to avoid.
- **RI4** -- Converting an existing doc as a live worked example. The folder
  form applies to doc 24 onward only.
- **RI5** -- Reverse-numeric ordering (newest first) in one table, or sorting a
  single table by status. Reverse-numeric is zero-churn but only approximates
  the goal -- doc 1 is LIVE and would land at the bottom. Status-sorting a
  single table shuffles rows on every status edit and breaks numeric scan.

## Implementation discretion

- The lint's implementation language and the exact wording of its diagnostics.
- Whether the seam check (`I7`) is a heading-anchored scan or a marker comment
  in the README.
- How the frozen flat set (`I5`) is expressed -- an allowlist in the lint, a
  marker file, or a generated manifest.

## Commit progress
- [x] 1. Enforce the research index contract (lint, self-test, index rewrite)
- [ ] 2. Add docs/research/FORMAT-NOTES.md

## Implementation notes

- **The lint and the index rewrite land in one commit, not two.** `PO7` wants
  the lint written first and observed red, which is a development order, not a
  commit order: committing the lint before the rewrite would commit a red
  `just test`. The red was observed and is recorded below; the commit carries
  both halves so the gate is green at every commit.
- **The frozen flat set (`I5`) is an enumerated array in the lint**, exposed by
  `./scripts/research-index-lint.sh --print-flat-allowlist`. The self-test reads
  it from there rather than restating it, so `PO4`'s "every doc in the frozen set
  passes" case cannot drift from the list it is testing.
- **The seam check (`I7`) is heading-anchored**, not a marker comment: it scans
  every markdown link below `## Contract` and rejects any target that names a
  scheme, is absolute, or walks up past `docs/research/`. Existence is not
  checked below the seam, which is what lets the portable `N-topic.md`
  placeholder stay.
- **The frozen set is named above the seam, not inside `## Contract`.** The
  deliverable asked for an explicit note in the Contract; naming
  `scripts/research-index-lint.sh` below the seam would have been exactly the
  project-local content `I7` exists to keep out. The Contract carries the
  portable rule (grandfathered docs stay flat; the set is frozen, enumerated,
  and never a numeric range), and the project-notes block above the seam names
  where DanTerm's copy of the list lives.
- **`## Required shape` was restructured, and "file" became "doc" throughout.**
  `D1` moves the findings and decision logs into `findings.md`/`decisions.md`,
  so a template that still showed them as `README.md` sections would have
  contradicted the contract on the same page. Once a doc is a folder, "the file
  is live" is wrong as well; the rename is carried through consistently rather
  than half-done.
- **`PO7` red, observed against the pre-rewrite README**: the lint named the
  broken table (`## File index and status`), the missing `## Live` and
  `## Closed` tables, the below-seam `agent-docs/terminal-performance.md` link,
  and every over-cap cell -- 12 rows from 133 to 10,268 characters. The
  cell-cap check deliberately runs before the row-shape check so a structurally
  broken index still reports which rows are oversized.
