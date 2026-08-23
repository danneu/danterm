# Revalidate LOOKUP-1's cost motivation

Source: LOOKUP-1 in
`docs/scratch/2026-08-18-construction-audit.md`, verified against the current
tree on 2026-08-23.

## Problem

The runtime constructs and compares the complete light-checkpoint projection
after each settled message while no checkpoint timer is armed. LOOKUP-1
proposes storing persisted state separately so this comparison no longer
rebuilds the snapshot DTO.

The original top-level split is invalid. Persisted and live state cut through
sessions, panes, and tabs: session recovery memos persist while lifecycle state
does not, pane recovery fields persist while `PaneLiveState` does not, and tab
focus persists while zoom does not. Treating the current `groups` value as
persisted would schedule extra checkpoint writes for live-only changes.

The corrected recursive split remains the ideal way to state persistence
membership in types instead of comments, but it is not yet justified as
performance work. The exact projection path previously passed a predeclared
128-pane cost gate, but that result predates the current model. The current cost
must be measured before performance can justify a large ownership rewrite. The
structural motivation survives either measurement outcome.

## Decision

Keep the current model, light-checkpoint projection, scheduling policy, and
snapshot format for this work. Revalidate only the cost motivation; do not let
either verdict select or implement a persisted/live representation.

Add a focused, committed probe with its own `just` recipe for the complete
snapshot-build and baseline-comparison operation. The recipe compiles the core
sources and probe into one module with full release optimization and without
`-enable-testing`; any other configuration is not a valid run.

The decision fixture has four groups, four tabs per group, and eight panes per
tab: 128 panes in balanced split trees. Every persisted facet read by
`toSnapshot` is non-default throughout the fixture: group names and collapse
state; tab titles, colors, todos, focus, and split metadata; and pane titles,
cwds beneath the live home directory, recovery command and agent memos, themes,
font steps, grid overrides, and todos. Snapshot construction uses the production
default home lookup rather than an injected test home.

Measure that fixture across a persisted title change, a persisted split-ratio
change, and a live-only progress change whose snapshot remains equal. Each
scenario runs 100,000 measured operations and reports its sample count, median
cost, build configuration, and a consumed result that proves the expected equal
or unequal comparison occurred.

The acceptance limit remains 417,000 ns per message for every scenario. This is
the limit fixed before the original measurement; do not replace it after seeing
the new results.

The new medians are not directly comparable to the 2026-08-10 projection-only
figures because this probe includes baseline comparison. Reusing the limit is
conservative and valid because the limit is an absolute share of the frame
budget, not a before/after delta.

PO4 and PO5 validate the run before the cost gate is read. A failure of either
means "not measured": issue no cost claim, repair the probe, and rerun it. Once
the run is valid, dismiss LOOKUP-1's cost motivation without a production
change only if every 128-pane scenario passes. A valid run that exceeds the
limit leaves the cost motivation open for a fresh design session. No outcome
authorizes the top-level split or selects a recursive ownership design.

## Invariants

- I1. The value used to decide whether a light checkpoint is needed is the
  value that the resulting capture encodes.
- I2. Live-only app, tab, pane, and session changes do not schedule or produce
  a light checkpoint.
- I3. Every persisted model facet changes the light-checkpoint projection.
- I4. Reverting from projection B to projection A while B is in flight still
  leaves A as the next captured projection.
- I5. Revalidation distinguishes a missing measurement from a measured value
  and cannot pass without exercising the production-shaped projection and
  comparison in the production build configuration.
- I6. The probe remains sensitive to the amount of model state traversed rather
  than reporting an optimizer-hoisted constant.

## Proof obligations

- PO1 (I1, I3): the existing persisted-facet and encoded-capture tests continue
  to show that projection equality and written checkpoint content use one
  definition of persisted state.
- PO2 (I2): retain the existing coverage for zoom, progress, alerts, and search;
  add the missing session spawn-to-running and connection-lifecycle cases, and
  show that neither projection equality nor capture decisions change.
- PO3 (I4): the existing reversion test remains green.
- PO4 (I5): the optimized probe reports the declared sample count, valid build
  configuration, and expected equal or unequal consumed result for every
  scenario before its timing can pass.
- PO5 (I6): repeat each scenario at 64, 128, and 256 panes. For both doublings,
  the median must increase by at least 1.5x; only the 128-pane median participates
  in the 417,000 ns verdict.
- PO6: targeted checkpoint tests, `just lint`, and the full `just test` gate pass.

## Audit disposition

Record the committed `just` command and result in the construction audit. On a
passing measurement, dismiss only LOOKUP-1's per-message cost claim. Rewrite
the checklist title and finding section around the surviving architecture-only
concern: state persistence membership in types across session, pane, and tab
instead of comments and hand-enumerated tests. Keep the recursive persisted/live
split as its named ideal, and mark the former cost claim measured and dismissed.
Do not mark the whole finding closed. Preserve the audit introduction as history
rather than rewriting its original unmeasured-run claim.

Remove the dismissed cost work from active dependency ordering. LOOKUP-2 becomes
independent and keeps its per-message UUID-formatting motivation because snapshot
projection remains: remove both its checklist `with LOOKUP-1` marker and its
section-level `Do after LOOKUP-1` marker. PERSIST-3 still follows LOOKUP-2. The
surviving structural LOOKUP-1 concern stays visible in the ledger without
blocking those findings.

## Non-goals

- Changing production model ownership, checkpoint timing, recovery behavior, or
  the persisted format in this work.
- Selecting or implementing a recursive persisted/live representation.
- Reopening the enriched-checkpoint policy or scrollback capture path.

## Rejected ideas

- RI1. Store current `groups` as the persisted value. Live session, pane, and
  zoom changes would then trigger extra writes.
- RI2. Perform the recursive persisted/live rewrite as part of this measurement
  task. The architecture ideal survives, but needs its own design justification
  rather than borrowing one from a passing or failing cost gate.
- RI3. Re-anchor the broader stale T6 counter probe. LOOKUP-1 needs one focused
  cost measurement, not a rewrite of unrelated whole-runtime counters.

## Implementation discretion

- The probe's internal timing helpers, provided its output and coverage satisfy
  I5-I6 and the fixed gate above.

## Commit progress

- [x] 1. test(checkpoint): make projection cost revalidation reproducible
- [ ] 2. docs(audit): narrow LOOKUP-1 to persistence membership
