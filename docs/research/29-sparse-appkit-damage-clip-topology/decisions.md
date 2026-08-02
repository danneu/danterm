# Decisions -- sparse AppKit damage clip topology

### D1 -- keep exact sparse damage with maximal-span coalescing

- Status: shipped in `f3c774d`.
- Evidence used: F3-F6; controlled parent/uncoalesced/coalesced btop profiles,
  the re-measured two-distant-row acceptance workload, and both test gates.
- Candidate solutions: revert `d378096`, keep one rectangle per row, or emit
  one rectangle per maximal contiguous span.
- Selected direction: preserve exact `TerminalDamage` for render-plan clipping
  and coalesce adjacent rows only when constructing the Core Graphics path.
- Behavioral verification: the AppKit test proves disjoint glyph halos remain
  exact and the span helper handles empty, contiguous, and disordered damage.
- Quantitative verification: btop CPU returned from 44.10% mean uncoalesced to
  22.94% coalesced versus 24.17% parent; parent/coalesced ranges overlap. The
  motivating two-row workload retained a 65% direct-draw and 8% process-CPU
  reduction with separated ranges.
- Decision and rationale: keep the revised optimization. It clears every
  keep-bar line without changing scheduling or damage semantics.

### D2 -- do not add a complexity fallback

- Status: rejected under the rule frozen before measuring F6's endpoint.
- Evidence used: the calibrated stride-four stimulus reached 50 damaged rows in
  17 spans, the maximum permitted at 66 rows by the one-row glyph halo.
- Candidate solutions: bound to one rectangle above a span threshold, draw full
  damage, or retain exact coalesced spans.
- Quantitative verification: median process CPU was 4.695 ms/draw coalesced and
  4.835 ms/draw parent; batch ranges overlapped or favored coalesced. The final
  samples showed more clip work but less direct rendering and no larger total CA
  queue count.
- Decision and rationale: retain exact coalesced spans. A threshold would add an
  unmeasured policy after the measured worst-case endpoint already cleared the
  bar.

### D3 -- retain topology diagnostics and hand permanent coverage to criterion 2

- Status: instrumentation shipped in `f3c774d`; workload calibration deferred
  intentionally to the M9 criterion-2 plan.
- Evidence used: the existing direct-draw verdict improved while asynchronous
  Core Animation work doubled process CPU, so it cannot detect this defect.
- Selected direction: retain benchmark-only row/span/full/fallback histograms
  with a mandatory sample count. Use them to calibrate a future deterministic
  sparse-many-runs workload whose primary verdict is whole-process CPU.
- Decision and rationale: topology accounting proves the workload exercised its
  independent variable. Freezing the CPU rule belongs with the broader
  visible-output gate, not with the already-settled renderer decision.
