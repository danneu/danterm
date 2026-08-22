# Launch-input-owned PTY geometry

## Problem

`TerminalPTYHost` constructs its terminal from one initial-dimensions value and
later receives the same fact inside its launch input. A mismatch is possible in
the API even though production construction keeps both values equal. The host
handles a mismatch by replacing valid launch dimensions with 0x0, which reports
`.launchFailed(.invalidDimensions)` for input whose dimensions were valid.

The session controller also retains the birth dimensions for recordings and
receives birth pinnedness separately even though the host's flight tape already
owns the matching grid, pinnedness, and event stream as one fact. These copies
make one pane's birth geometry a convention instead of one owned fact. This
conflicts with the single-owner boundary in
`docs/design/2026-08-06-swift-terminal-engine.md B3`.

## Decision

- The immutable launch input is required when a PTY host is constructed. The
  host derives its terminal and child PTY dimensions from that value and owns
  the paired birth grid and pinnedness in its flight recorder.
- Starting a constructed host supplies no launch input. Delayed start remains
  available, and initial-input completion keeps its current ordering and
  rejection behavior.
- The session controller receives no launch input, birth dimensions, or birth
  pinnedness. It seeds its initial live-grid projection from the host-owned
  birth geometry, and recordings get their birth dimensions from the same
  flight-tape capture as their events.
- Invalid birth dimensions fail host construction. Launch-policy failures that
  occur after valid construction continue through the pane lifecycle.
- The redundant initial-dimensions projection on the pane launch configuration
  is removed. The launch input is the only geometry authority at that boundary.

## Invariants

- I1. A host's initial terminal grid, flight-tape birth grid, and spawned PTY
  grid cannot disagree, and the flight tape owns the paired grid and pinnedness
  after construction.
- I2. No launch failure is fabricated by changing a caller's dimensions.
- I3. A completed or diagnostic recording pairs birth geometry and events from
  one owner-fenced capture.
- I4. Registering initial-input completion still precedes launch reduction, and
  a queued start whose host is gone still rejects completion as process-ended.
- I5. Valid launch-policy failures still publish one final lifecycle result and
  do not create a render plan for an unchanged terminal.

## Proof obligations

- PO1. A pane born pinned at a non-default grid exposes that grid in the initial
  terminal snapshot, child-side `TIOCGWINSZ` result, and flight-tape origin. An
  identical pinned submission is deduplicated, while a pinnedness-only change
  is submitted.
- PO2. Non-positive launch geometry fails host construction, while the pure
  launch policy continues to reject invalid geometry when tested directly.
- PO3. After a pane resizes away from a non-default birth grid, completed and
  diagnostic recordings still start replay from the capture's birth dimensions
  and apply the recorded resize to reach the live grid.
- PO4. A valid-geometry policy failure, such as no usable shell, emits one final
  host update and one controller session-ended result without a render plan.
- PO5. Existing initial-input completion coverage continues to prove delivery,
  typed rejection, and process-ended rejection ordering.
- PO6. The TerminalPTY package tests and the full `just test` gate pass.

## Non-goals

- NG1. This change does not move post-launch resize deduplication into the host
  or remove the controller's last-submitted-grid state. That is the separate
  applied-geometry refactor.
- NG2. This change does not remove invalid-dimension validation from the pure
  launch policy because its public input remains independently constructible
  with arbitrary geometry.
- NG3. This change adds no compatibility overload for the old host or controller
  construction APIs.

## Accepted risks

- AR1. Host and controller construction changes touch many tests that currently
  create a host before assembling its launch input. This mechanical churn is
  accepted because retaining the two-phase geometry API would preserve the
  invalid state this refactor removes.

## Rejected ideas

- RI1. Replacing the mismatch result with a precondition failure is rejected.
  It changes the false diagnosis into a trap but keeps duplicate authority.
- RI2. Passing the pane launch configuration into the host is rejected. It
  would reverse the package dependency from `TerminalPaneSession` to
  `TerminalPTYHost`; the lower host target already has the launch-policy input
  it needs.

## Implementation discretion

- Test-helper organization is left to implementation.
