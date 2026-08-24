# CHROME-6 Ideal Pivot: Live Alert Ages and Reusable Cells

## Problem and outcome

The alerts popover computes each relative age when AppKit builds the row. An
open popover can therefore keep showing an age after it is false until an
unrelated message changes the projection. The same code also rebuilds each
row's complete view tree instead of reusing a typed cell.

These are independent concerns. Fix stale age text through the existing
model-projection and runtime-scheduling architecture, then refactor row
construction separately. Preserve alert content, ordering, and activation
behavior.

## Decision

- Project alert age text from the alert timestamp and an explicit current
  time supplied at the reconcile call site through the runtime's existing
  `CoreEnv.now` seam. AppKit receives the display text and does not read the
  clock.
- While the alerts popover is presented, the runtime owns one census-backed
  60-second refresh. Its payload-free clock event enters through `Msg`, changes
  no model field, and drives a normal reconcile sweep.
- A refresh that leaves every age in the same display bucket still schedules
  the next refresh. Unrelated reconcile sweeps do not postpone an already
  pending refresh.
- Closing or dismissing the popover cancels its refresh. Reopening projects
  fresh ages immediately before scheduling another refresh.
- A reusable typed alert cell owns the complete row hierarchy and applies one
  complete row projection. Cell reuse does not own age refresh and does not
  change selection-to-alert routing.
- No public, persisted, or wire interface changes are required.

## Invariants

- The view displays only projected age text; alert timestamps remain model
  facts and never become an AppKit clock input.
- While the main actor remains responsive, an open popover can lag an age
  bucket transition by at most one 60-second refresh interval.
- No age-refresh owner exists while the alerts popover is closed.
- At most one age-refresh owner exists while the popover is open.
- Every reused row replaces all variable presentation state, including alert
  kind, tooltip, title, body, age, and unread state.
- A row click continues to activate the `AlertId` at that projected row.
- Existing age formatting remains unchanged: less than 60 seconds and future
  timestamps display `"now"`; older ages use floor-rounded minutes, hours, and
  days.

## Proof obligations

- Pure tests prove the age formatting contract at the second/minute,
  minute/hour, and hour/day boundaries, including future timestamps.
- Projection tests prove that explicit current time changes projected age text
  and that a closed popover has no projection.
- Deterministic scheduling coverage proves that opening owns one refresh,
  firing it drives a clock message and leaves one successor while open,
  unrelated reconciliation does not postpone it, and closing owns none. These
  tests do not wait for the production interval.
- UI coverage proves that a row displays supplied projected age text and that
  applying a different row replaces every visible field. It does not assert
  NSTableView object identity.
- Existing row ordering, repeated-click activation, stale-pane activation,
  empty-state, show-all, and mark-all coverage remains green.
- Each delivery commit passes its targeted core, scheduling, and alerts UI
  coverage, `just lint`, `just test-ui`, and the full `just test` gate.

## Non-goals and accepted risk

- Exact per-row transition scheduling is a non-goal. The accepted tradeoff is
  up to one refresh interval of stale display text for one coarse wakeup per
  minute while the popover is open.
- Refreshing ages while the popover is closed is a non-goal.
- Proving that NSTableView reused a particular object instance is a non-goal;
  complete repaint behavior is the contract.
- Performance thresholds are a non-goal. Typed reuse is a structural cleanup,
  not a benchmark claim.

## Delivery

1. `fix(alerts)`: project age text and refresh it through the open-popover
   clock message.
2. `refactor(alerts)`: replace rebuilt rows with complete reusable typed cells.

The former RUNTIME-2 and RUNTIME-4 conflicts are resolved by landed work. The
first commit can conflict mechanically with concurrent edits to core messages,
projections, reconciliation, or runtime scheduling. The second can conflict
with BUILD-4 at the header of `AlertsPopoverView.swift`.

## Implementation discretion

- The internal seam used to drive scheduled callbacks deterministically in
  tests is implementation discretion; it must preserve the ownership and
  no-wall-clock-wait proofs above.

## Commit progress

- [x] 1. fix(alerts): project age text and refresh it through the open-popover clock message
- [x] 2. refactor(alerts): replace rebuilt rows with complete reusable typed cells

## Implementation notes

- `AppRuntime` gives one injected `CoreEnv` to both the reducer store and view
  projections. Deterministic runtimes therefore cannot create an alert with one
  clock and project its age with another.
