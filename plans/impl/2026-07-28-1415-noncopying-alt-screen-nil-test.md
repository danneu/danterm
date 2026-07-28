# Test `inactivePrimaryScreen` for emptiness without copying its payload

Candidate **R2** from [13-live-app-compositing-and-draw-hotspots.md](../../docs/research/13-live-app-compositing-and-draw-hotspots.md).

## Problem and evidence

`Terminal.inactivePrimaryScreen` is an `Optional<InactivePrimaryScreen>`, and
`InactivePrimaryScreen` is `Equatable` and holds `rows: [GridRow]`. Every
`inactivePrimaryScreen == nil` / `!= nil` therefore resolves to the generic
two-operand `==`, which copies both operands -- retaining and releasing the row
array -- to answer a question whose entire semantic content is "is this optional
populated".

The feed path asks that question repeatedly. `damageActionSnapshot` asks it
twice per build, and `Terminal.feed` builds a snapshot per action.

Load-bearing evidence:

- **13/F3**: on the live app's PTY-host thread, `outlined destroy of
  (InactivePrimaryScreen?, InactivePrimaryScreen?)` is **187 of 831 inclusive
  samples -- 22.5% of the whole thread and 25% of `Terminal.feed`**. The tuple
  arity localizes it to a *pair* of comparison temporaries rather than the
  getter's own teardown.
- **13/F6**: the repeat capture reproduces the node (187 then 166 samples) on a
  byte-identical binary.
- **10/F9, 10/D5**: feed work moves `terminal-feed` and `scrollback-stream` and
  does not move the render-bound workloads. That bounds what this change can be
  expected to do.

The mechanism is confirmed live in the current tree: `InactivePrimaryScreen`
declares `Equatable` while holding a row array, and the comparison appears both
inside `damageActionSnapshot` and at roughly two dozen further sites across
`Terminal.swift`, including the public `isAlternateScreenActive`.

## Decision

Ask whether the optional is populated **without copying its payload**, at every
site that currently asks by comparing against `nil`.

Behavioral scope: none. This is a change of how a question is spelled, not of
what any caller observes. There are no ownership moves or new cross-object
invariants. Whether `Terminal`'s layout changes is reserved implementation
discretion and is decided by the paired benchmark as described below.

Decisive constraint: the two cursor-row projections -- one in
`damageActionSnapshot`, one in the public `geometry` -- branch on this test and
compute a *different stream row* per branch (primary adds the scrollback depth,
alternate does not). A silently inverted branch does not crash and does not
change any grid content; it pushes the cursor's window row outside the viewport,
so the cursor reads `nil` and its damage is simply never recorded. That is the
failure mode doc 10's correctness rule names as invisible to both benchmarks and
most tests, and the coverage audit below confirms the existing suite would not
catch it.

## Invariants

- **I1.** Whether the alternate screen is active is observably identical to
  today across every transition: entry, exit, redundant entry/exit, the inert
  modes, and reset.
- **I2.** The cursor's projected row is unchanged on both screens, including
  when the alternate screen is active over non-empty primary scrollback -- the
  case the branch exists for.
- **I3.** Cursor damage still covers both the old and the new cursor row on both
  screens, including alternate-over-scrollback.
- **I4.** `Terminal` value equality still distinguishes terminals that differ
  only in alternate-screen state.

## Proof obligations

The existing suite covers alternate-screen behavior well but has a hole shaped
exactly like this change. Audited against `lib/TerminalCore/Tests/`:
`TerminalAlternateScreenTests` asserts cursors only on terminals with empty
scrollback, and the alt tests that *do* build scrollback assert history text and
never the cursor. So the primary-vs-alternate branch is currently unpinned.

- **PO1** (I2, the gap): enter the alternate screen over non-empty primary
  scrollback and assert the projected cursor. Today no test does, and inverting
  the branch fails nothing.
- **PO2** (I3, the gap): with the alternate screen active over non-empty
  scrollback, move the cursor and assert damage covers the old and new rows.
  `TerminalDamageTests` currently uses the alternate screen only to prove
  full-damage escalation, so the snapshot's alternate branch is unpinned for row
  correctness.
- **PO3** (I1, I2, the mutation gap): with the alternate screen active over
  non-empty primary scrollback, resize the terminal and assert that the
  alternate screen stays active and the projected cursor remains screen-relative.
  Resize mutates and reassigns `inactivePrimaryScreen` without leaving the
  alternate screen; this pins any maintained emptiness state across that path.
- **PO4** (I1): assert alternate-screen state flips false on exit and after
  reset, and stays false for the inert modes. TerminalCore asserts this property
  only through a fixture manifest field today; the only true false-transition
  assertions live outside the module.
- **PO5** (I4): already discharged by the existing alternate-screen equality
  test. It must keep passing; it is the reason the `Equatable` conformance
  cannot simply be deleted.

## Deciding the benchmark

**`benchmark-confirm` decides this, not `benchmark-quick`.** Doc 10's own rule
and 12/F8 both say so, and 12/F8 is the specific precedent: a change decided on
one workload was blindsided by a second.

- **Baseline acceptance:** before implementation changes begin, resolve and
  record the pre-change revision. Pass that exact revision as
  `baseline=<pre-change revision>` to `benchmark-confirm`; do not infer the
  baseline from `HEAD` after work has started.
- **Deciders:** `terminal-feed` and `scrollback-stream`. These are the two
  collectors that can see feed work (10/F9). 13/R2 predicts `terminal-feed`
  **-8% to -15%**.
- **Predicted null, not failure:** `content-churn`, `style-churn`,
  `incremental-mixed`. Per 10/F9 the entire feed investigation moved the
  render-bound workloads +0.03% and +0.63%. An `equivalent` there is the
  expected result and must not be read as the change doing nothing.
- **What could move the wrong way, named in advance:** if the emptiness test is
  answered by a *stored* flag on `Terminal` rather than by pattern-matching the
  optional in place, that adds a field to a 932-byte struct whose copies are
  themselves suspected hot (10/H3). 12/F8's regression came from a type growing
  on a path nobody was watching -- `GridRow`, not the `GridCell` the plan was
  tracking. `scrollback-stream` is where that would show up, and it is already a
  decider.

## Non-goals

- Changing what `DamageActionSnapshot` *contains* (that is 10/H1(b), separately
  reopened).
- Changing how *often* the snapshot is built (that is 10/H1(a)).
- Anything on the draw or plan path (13/R1, R1b, R4).
- Moving the render-bound workloads. Nothing in the feed path can.

## Accepted risks

- **AR1.** The win may be smaller than 13/R2's -8% to -15%: the attribution is a
  live-app profile of the PTY thread, and `terminal-feed` is a headless harness
  with a different shape. The prediction's confidence is medium on magnitude and
  low-risk on mechanism (13/F3). A smaller-but-real win is still a win; an
  `equivalent` on both deciders means the attribution did not transfer, and that
  result gets recorded rather than tuned around.
- **AR2.** The comparison sites are numerous and mechanical. Missing some leaves
  win on the table but cannot change behavior, since each site's meaning is
  unchanged.

## Rejected ideas

- **RI1. Drop the `Equatable` conformance from `InactivePrimaryScreen`.** It
  would remove the copying comparison at the root, but `Terminal`'s own value
  equality is synthesized through it and is asserted by an existing
  alternate-screen test (PO5). The conformance is load-bearing; only the
  *nil-test* use of it is wasteful.
- **RI2. Decide on `benchmark-quick` alone.** 10's rules record five `quick`
  runs on one unchanging pair of trees spanning -6.05% to +7.61%, and 12/F8 is
  the reverted change that trusted a single workload.

## Implementation discretion

- How emptiness is tested at each site -- in-place pattern matching, a
  maintained flag, or a mix -- subject to the growth risk named above being
  measured on `scrollback-stream` rather than assumed away.
- Which sites beyond the feed path are converted, and whether in one commit or
  several.

## Implementation notes

- Benchmark baseline revision, resolved before any implementation change began:
  `20a6eafb8abd8e171719f17d3c2f7b6f2ecda943` (`docs(research): stop H3 from
  assuming a POD cell the revert undid`). `benchmark-confirm` in commit 2 is
  passed this exact revision, not an inferred `HEAD`.
- Commit split: the PO1-PO4 coverage lands first, on the unchanged engine, so a
  reviewer can confirm it passes against pre-change behavior; the non-copying
  test itself lands second, against that net.

## Commit progress

- [x] 1. test(terminal): pin the primary-vs-alternate cursor branch (PO1-PO4)
- [ ] 2. perf(terminal): test the inactive primary screen without copying it
