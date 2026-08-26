# Decisions

### D1 -- which ranked sites to implement

- Status: open, waiting for `F2` (Phase 1 sampling).
- Evidence used: `F1` ranking.
- Candidate solutions: ranks 1, 2, 4, 6 of `F1`; rank 5 as a low-expectation exercise.
- Recommendation: scalar rewrite of `appendCells` first; it may capture the rank-1 win without SIMD.
