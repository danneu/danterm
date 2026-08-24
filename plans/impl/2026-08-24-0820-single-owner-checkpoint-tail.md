# Single-owner checkpoint history tail

## Problem

An enriched checkpoint decides its retained history tail twice. TerminalCore
projects enough primary history for a later truncation to be safe, then
DanTermCore trims and applies the line and character limits again. This leaves
two definitions of the same cut that can drift.

The work is bounded, periodic checkpoint work. It runs on the serial checkpoint
queue, except for the final synchronous checkpoint at clean exit. No current
measurement shows that the remaining duplicate work is user-visible or
material, so performance is not the reason to accept this change.

LOOKUP-2 and PERSIST-3 are already merged. Snapshot identities are typed, and
scrollback grafting uses the snapshot's complete pane-leaf traversal. Neither
change removes this duplicate cut.

## Decision

TerminalCore will return a positional tail of primary history under plain line
and grapheme limits. It will use the canonical hard boundaries to avoid a
partial oldest line, but it will not trim or classify whitespace, know
`ScrollbackRetention`, or synthesize a final newline.

DanTermCore will remain the owner of checkpoint retention policy and stored
normalization. It will reserve room for the stored final newline when it
supplies the engine's character limit, trim the bounded result with the current
`.whitespacesAndNewlines` rule, omit a result with no content, and append exactly
one final newline otherwise.

This deliberately changes two legacy edge cases. Boundary whitespace can consume
part or all of the positional budget before persistence trims it, so the stored
tail can be shorter than today's trim-before-cut result. A single logical line
whose kept character window contains no hard boundary now produces no stored
history and schedules no initial recovery; today the synthetic newline makes
that case store `""` and schedule recovery.

The checkpoint pipeline will derive the reserved limits once and supply them
when it creates each pane read. A deferred reader will close over those limits;
the existing eager fallback will read with the same values before returning its
constant result. Both branches will remain supported, and the downstream second
budget cut will be removed.

The initial recovered-history check currently asks whether
`truncateScrollback(fullPrimaryHistory) != nil`. It will instead normalize the
same bounded positional result the checkpoint would store and schedule work only
when that result is non-nil.

The terminal design record will state this ownership boundary and the deliberate
format edge-case changes. The checkpoint schema and its limits remain unchanged.

## Invariants

- **I1. Single cut.** One engine operation owns the line and grapheme cut. No
  downstream component reapplies those budgets.
- **I2. Stored compatibility.** Stored history is byte-identical to the current
  result except where boundary whitespace consumes positional budget before it
  is trimmed and where an over-budget line has no hard boundary in its kept
  window. Those cases follow the new behavior stated in the Decision.
- **I3. Layering.** TerminalCore receives only plain limits. DanTermCore owns the
  4,000-line and 400,000-grapheme checkpoint policy, whitespace normalization,
  omission, and the stored trailing newline.
- **I4. Projection fidelity.** The bounded content uses the canonical primary
  projection, including hard and soft boundaries, wide and multi-scalar cells,
  trailing blank rows, and the primary screen while an alternate screen is
  active.
- **I5. Bounded cost.** A fixed-budget read remains independent of retained
  history depth and does not materialize the discarded prefix.
- **I6. Queue placement.** Periodic projection, storage formatting, grafting,
  and encoding remain deferred to the checkpoint queue. Capture performs no
  pane read.
- **I7. Capture identity.** Each pane is read once per enriched capture, and its
  content remains paired with the model snapshot captured beside it. Both eager
  and deferred reads receive the one set of limits derived for that capture.
- **I8. Recovery scheduling.** Initial recovery is scheduled exactly when
  persistence normalization of the bounded positional result produces stored
  content.

## Proof obligations

- **PO1 (I1-I3).** Compare the new stored result against a test-local reference
  for the old full-projection-plus-truncation behavior. Prove equality outside
  the documented deviations and prove the chosen result for each deviation,
  including one line longer than the character budget with no newline in the
  kept window.
- **PO2 (I2, I4).** Prove the bounded result names the corresponding region of
  the canonical primary projection across short and long history, hard and soft
  wraps, boundary whitespace, blank runs, trailing viewport blanks,
  alternate-screen activity, wide cells, combining sequences, and multi-scalar
  graphemes. This exact-output contract supersedes the existing suffix and
  coverage tests for the former over-read API.
- **PO3 (I3).** Prove that the engine does not synthesize a final newline and
  that persistence stores non-empty content with exactly one final newline
  inside the 400,000-grapheme stored bound.
- **PO4 (I5).** Keep a deterministic row-work assertion showing that equal
  limits visit bounded work at different retained-history depths. No test may
  pass or fail on wall-clock time.
- **PO5 (I6, I7).** Keep the checkpoint capture tests for deferred execution,
  common limits across eager and deferred reads, one read per pane,
  capture/snapshot pairing, light-checkpoint identity, and exact restored
  content.
- **PO6 (I8).** Compare initial recovery scheduling with the current
  `truncateScrollback(fullPrimaryHistory) != nil` reference for ordinary empty,
  whitespace-only, and non-empty history, and pin the deliberate over-budget
  unbroken-line deviation.
- **PO7.** The cross-module reference proof belongs in `DanTermAppTests`, the
  target that sees both TerminalCore and DanTermCore. Run
  `swift test --filter DanTermAppTests` with the TerminalCore and DanTermCore
  targeted suites and lint during development, then run `just test` as the
  final gate.

## Non-goals

- Changing the checkpoint cadence, retained-history limits, JSON schema, or
  restore schema.
- Moving work onto the feed, render, or main-actor steady-state paths.
- Claiming a speedup without a checkpoint-specific measurement.
- Implementing semantic or styled recovery.

## Accepted risks

- **AR1. Shared capture seam.** Styled recovery also targets primary-history
  capture. Concurrent implementation would create a direct semantic conflict,
  so that work must be sequenced after this contract settles.

## Rejected ideas

- **RI1. Keep the split and optimize its scans.** This can reduce local work but
  preserves two owners of the cut and the possibility that they disagree.
- **RI2. Move the stored newline into TerminalCore.** This makes a terminal text
  API own a DanTerm persistence format and violates the layer boundary.
- **RI3. Treat this as feed-path performance work.** The corrected call path is
  periodic checkpoint-queue work, and no measurement supports that claim.

## Implementation discretion

- The private traversal and accumulator shape is open, provided it reuses the
  canonical projection rules, reads only bounded tail work, and satisfies the
  positional-output proof.
- Internal symbol names and test grouping are open; public comments must state
  the engine-content versus persistence-format boundary.

## Implementation notes

- The engine keeps the bounded row-window projection and applies the exact
  positional cut to that suffix. This preserves cost independent of retained
  history depth without materializing the discarded prefix.
