# Decisions

### D1 -- which ranked sites to implement

- Status: decided, 2026-08-26.
- Evidence used: `F2` (three Time Profiler traces at 7bf8459f), `F1` ranking.
- Candidate solutions: ranks 1, 2, 4, 6 of `F1`; rank 5 as a low-expectation exercise.
- Decision: keep rank 1 and rank 6; reject ranks 2 and 4 for want of a workload;
  hold rank 5.

Rank 1 (`appendCells`) survives, but the work it earns is the scalar rewrite, not
lanes. `F2` puts 8.99% of total CPU in copy-on-write and bounds checks under the
function, against 6.35% self -- so the two hoists it names
(`withUnsafeMutableBufferPointer` over the arena chunk, local open-run variables for
`openIdentityRuns`) are the whole of the near-term win. The blocked kind compare is
deferred until a post-rewrite trace shows whether anything compare-shaped is left.

Ranks 2 (`eraseCells`) and 4 (`moveAndFillCells`) are rejected, not deferred. Neither
appears in any calibrated workload's profile, and the reason is in the stimulus, not
the sampling: no calibrated workload emits a timed ED, and the one EL any of them emits
costs 0.061% on `localized-draw-acceptance`. A site the ladder cannot see cannot clear
a threshold, so there is nothing to implement against. Reopening either one requires a
new calibrated workload that emits erase and scroll-region sequences, and that workload
is the prerequisite task -- not the SIMD change.

Rank 6 (`admissionExtent` -> maintained `contentEnd`) is unaffected by `F2`: it is a
deletion, not an acceleration, and `F1` section 4's rule prefers it regardless of what
the profile shows.

Rank 5 (ASCII ground-run scan) is held as written -- a clean `SIMD16<UInt8>` exercise,
expected to land under the `terminal-feed` threshold, to be sized with
`just benchmark-feed-sample` if it is picked up at all.
