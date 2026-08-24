# Unify Search-Unit Cell Classification

## Problem

Closed-history search and live-projection search classify terminal cells with
two copies of the same rule. The traversals themselves are different: one walks
logical records and the other walks projected display rows. Combining them would
parameterize their real differences instead of removing them.

A projected wide head cannot end at the row extent without its tail. The engine's
whole-cell invariant forbids orphaned halves, and record admission force-splits
only at display-row boundaries. The special wide forced-split seam separates a
dropped spacer from the follower's wide head, not a wide head from its tail.
Therefore the apparent endpoint-clamp asymmetry is unreachable in a valid
projection and is not a search defect.

## Decision

Give search one shared cell classifier. Both traversals use it to map a cell kind
and borrowed scalars to an optional search key. Keep iteration, boundary
detection, width handling, and coordinate construction in each traversal.

This changes no public API.

## Invariants

- I1. A terminal cell has the same search key in closed history and in the live
  projection.
- I2. Moving content across the closed-history seam does not change its match
  count, match range, or active occurrence.
- I3. Record boundaries remain record-owned, and display-row boundaries remain
  projection-owned.
- I4. Existing scan-derived search ranks and overlapping-match semantics do not
  change.

## Proof Obligations

- PO1 (I1, I2, I3): The existing
  `retainedIndexKeysWideAndSpilledCellsLikeAFullScan` characterization test stays
  unchanged. It covers wide and multi-scalar cells plus a hard boundary as
  content moves into closed history.
- PO2 (I4): Existing seam, normalization, overlap, and search-rank tests pass
  unchanged.
- PO3: Run the targeted TerminalCore Search suite and lint during the edit loop,
  then run the full local gate before commit.

## Non-goals and Rejected Ideas

- Non-goal: Change the matcher, its retained boundary window, or its key-ring
  representation. The skipped matcher rewrite has no measured justification and
  is independent of this work.
- Non-goal: Change search ranking, retained-index ownership, projection-row
  storage, or public search interfaces.
- Rejected idea: Clamp or unify projected-row unit endpoints. Margin projection
  can yield only its stored cell, a spacer head, or a blank -- never a new wide
  head. A projected wide head without its tail therefore violates the engine's
  whole-cell invariant; if such a state becomes reachable, fix the producer
  instead of masking it in projection consumers.
- Rejected idea: A generic search-unit emitter. It would parameterize row source,
  coordinates, and boundary semantics that are genuinely different while sharing
  little more than the classifier.
- Rejected idea: A classifier-specific structure test. Behavioral seam and
  independent-oracle proofs cover the contract without coupling tests to a
  private helper.

## Implementation Discretion

- The classifier's private name and exact declaration shape are implementation
  details.

## Commit progress

- [x] 1. refactor(search): share terminal-cell classification
