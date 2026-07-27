# Damage-aware frame planning

## Context

Frame planning, not drawing, dominates main-thread time in the Swift terminal
engine. Four `just benchmark-sample` profiles at 179x66 agree: real rendering
(`drawRenderFrame`) is under 10% of main-thread busy time, while `planFrame` is
3000-4300 samples per 20s run.

Planning ignores damage entirely. `planFrame` always plans the whole viewport;
`clipFramePlan` only filters the finished plan. The `incremental-mixed` workload
changes 4 of 66 rows and spends *more* in planning (4303 samples) than the
full-screen `content-churn` workload (3240). An idle terminal whose only change
is a cursor blink replans all 11,814 cells.

Desired outcome: planning cost proportional to what changed.

## Direction

Confined to `lib/TerminalCore/Sources/TerminalRenderPlanning/` plus the one call
site in `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`.

`planFrame` gains a variant that accepts the previous frame's reuse state and the
damage since it was built, copies the runs of undamaged rows instead of
recomputing them, and returns a *complete* viewport plan plus fresh reuse state.

Two architectural constraints on that reuse state:

- It carries every planning input the damage model does not cover. Today that is
  `RenderPresentation`: `setPaneTheme` already exists (`app/DanTermCore/Msg.swift:71`)
  while `TerminalPaneSession.swift` still hardcodes `theme: .dark`, so when
  per-pane themes reach the Swift engine a theme switch will change presentation
  and record zero damage. Carrying presentation in the reuse state makes that
  stale-row bug unrepresentable rather than merely untested.
- The reuse entry point is not public API. It stays scoped to the pane planning
  path, because reuse state, accumulated damage, and terminal snapshots are only
  jointly meaningful within one pane's ordered frame stream; nothing binds them to
  each other at the type level, so a cross-pane call would silently reuse another
  pane's rows.

## Invariants

- A reused plan is equal to the plan `planFrame(for:presentation:)` produces from
  scratch for the same terminal and presentation. This is the whole correctness
  claim; `RenderFramePlan` is `Equatable`, so it is directly assertable.
- Reuse state, accumulated damage, and terminal snapshots passed to one reusing
  call belong to a single pane's ordered frame stream.
- Reuse is refused, and the full viewport replanned, whenever presentation
  differs from the retained state's, the grid dimensions differ, damage is full,
  or no retained state exists.
- The existing `planFrame(for:presentation:)` signature and behavior are
  preserved, so every current caller and test remains valid.
- Selection runs, search-match runs, and the cursor are recomputed every frame
  rather than reused. They are derived from stream ranges rather than from
  inspected cells, and they do not appear in the profiles.

Row reuse is sound because damaged rows are the only rows whose planned output
can change: the three cell-derived layers are strictly row-local (each flushes
its open run at the row boundary), and `TerminalDamage` escalates to `.full` for
every event where viewport row identity is unstable -- scroll position change,
resize, alt-screen switch, reset, and any content mutation while scrolled back.

## Non-goals

- Teaching `TerminalDamage` a scroll delta. Sustained output damages every row
  (`Terminal.swift:4747`), so this change does not speed up scrolling. Doing so
  means changing the damage model the whole engine's correctness rests on, and is
  not justified until a profile shows scroll planning still dominant afterwards.
- Removing the whole-viewport `terminal.geometry` materialization. Measured at 31
  samples; not worth the risk.
- The per-cell costs inside `inspectedCells` -- the per-cell `Array(cell.scalars)`
  heap allocation, the per-cell row re-fetch, and the unmemoized `resolveCellStyle`.
  Each is a real defect and a candidate follow-up; none is required here.

## Accepted risks

- Damage-aware reuse delivers nothing for `content-churn`, `style-churn`, or
  `scrollback-stream`, where every row is damaged. Its value is interactive
  latency and idle power (typing, cursor movement, hover, selection), which the
  routine benchmark ladder measures only through `incremental-mixed`.
- `isHovered` re-materializes the entire viewport geometry per cell
  (`RenderFramePlanner.swift:225`) whenever a link is hovered. Reuse shrinks how
  often that runs but does not remove the cliff.
- Lineage is an owner invariant, not a type-level guarantee. Scoping the entry
  point to the pane planning path is the enforcement; a mismatched pairing inside
  that path would produce a stale frame no test can catch.

## Verification

Behavioral proofs, all in `lib/TerminalCore/Tests/TerminalRenderPlanningTests/`
using the existing Swift Testing idiom and `assertCanonical`:

- A reused plan equals a from-scratch plan. Discharge over the recorded corpus by
  extending `RenderCorpusPlanningTests`, which already replays every neutral event
  and every libvterm checkpoint with per-step damage -- the equality assertion is
  the same shape as its existing `assertDamageEquivalence`.
- Reuse is refused on changed presentation. A retained state built under one
  presentation, replanned under another with no damage, equals a from-scratch
  plan under the new presentation.
- Reuse is refused on changed grid dimensions and on full damage.

That planning work actually scales with damage is a performance property, and no
structural test proves it. The plan-time estimate is uncalibrated and carries no
verdict (`agent-docs/terminal-performance.md`), so it is descriptive evidence
only: it can motivate keeping or reverting the change, but no durable speed claim
may rest on it until planning-time thresholds are calibrated. Only the calibrated
draw verdict licenses a durable claim.

Performance, measured not asserted. Baseline is `8e9bc45` (the commit before this
work); note it before starting since `HEAD` moves:

    just benchmark-quick baseline=8e9bc45 workload=incremental-mixed
    just benchmark-confirm baseline=8e9bc45   # before any durable claim

A `quick` result of `equivalent` on the full-damage workloads is the expected
outcome, not a failure. Record the decision-bearing values in the commit.

Full gate: `just test`. The planning and damage suites live in
`lib/TerminalCore`, so `swift test --package-path lib/TerminalCore` is the
tight loop.

## Commit progress

- [x] **Damage-aware row reuse.** Add the reusing `planFrame` variant and its
      reuse state, adopt it in the pane planning path, and add the equivalence and
      refusal proofs above. Benchmark `incremental-mixed` against the baseline,
      recording plan time as descriptive evidence only.

## Implementation notes

- The reuse entry point is `PaneFramePlanner`, a stateful `public struct` that
  owns its retained rows, rather than the free function plus caller-held reuse
  state the Direction describes. `TerminalCore` and `TerminalPTY` are separate
  SwiftPM packages, so `package` access cannot span them and the entry point had
  to be `public` whatever its shape. Owning the state instead of handing it out
  recovers the intent the Direction wanted from non-public access: the retained
  rows never escape, so the only way to violate lineage is to feed one pane's
  planner another pane's terminal, and "one planner per pane" replaces a
  per-call obligation. `RetainedFrameRows` itself stays internal.

- Presentation is compared in `PaneFramePlanner`, while the grid-dimension and
  full-damage refusals live in `FramePlanner.plan(reusing:damage:)` -- the
  planner can see grid shape for itself but has no memory of presentation.

- The layer builders (`backgroundRuns`, `textRuns`, `decorationRuns`) now take
  one row instead of the whole viewport, and `plan()` concatenates the per-row
  results. From-scratch planning therefore runs the exact same per-row code as
  reuse, which is what makes the equality invariant structural rather than a
  coincidence of two parallel implementations.

- The dimension-refusal test replans against a taller grid, then a *shorter*
  one, then a wider one. Only the shrink direction distinguishes a real equality
  check from a mere bounds check: growing the grid makes an over-long retained
  array unreadable anyway, so a `rowCount >= rowCount` bug survives the grow
  case. Verified by mutating the check and watching only the shrink assertion
  fail.

## Measured outcome

`just benchmark-confirm baseline=8e9bc45`, candidate tree `6e2ecb7b7250`,
baseline tree `9b880546c0db`:

| workload | draw verdict | plan time (descriptive) |
| --- | --- | --- |
| `incremental-mixed` | slower, +8.65% (6 pairs) | -163.65% (6 pairs) |
| `content-churn` | equivalent, -0.12% (4 pairs) | +0.01% |
| `style-churn` | equivalent, -0.19% (4 pairs) | +0.73% |
| `scrollback-stream` | equivalent, -0.56% (4 pairs) | absent |
| `terminal-feed` | inconclusive, -0.78% (2 pairs) | absent |

Planning cost on the targeted workload fell roughly 2.6x, and the full-damage
workloads came back `equivalent` as the plan predicted. The draw regression on
`incremental-mixed` was not predicted. It is attributable to reuse itself, not
to the row-granular refactor: with `PaneFramePlanner` forced to pass no retained
rows, the same tree measured `equivalent (+0.24%)` on draw and `-0.38%` on plan
time. The likely mechanism is locality -- a reused row's `RenderTextRun.cells`
arrays are heap allocations from an older frame, so `clipFramePlan` and
`drawRenderFrame` walk scattered storage with more refcount traffic than the
contiguous, freshly-allocated runs a full replan produces.

No durable speed claim rests on the plan-time numbers; they remain uncalibrated
and carry no verdict. The change was taken on the judgment that planning
dominates main-thread busy time while drawing is under 10% of it, so the net
main-thread effect is very likely positive -- but that judgment is not a
measured claim, and the calibrated axis says drawing got slower.

## Follow Up

- Re-materialize reused rows' run storage into fresh per-frame arrays and
  re-measure `incremental-mixed`. Cell inspection -- the actual planning cost --
  would still be skipped, so most of the -163.65% should survive while drawing
  walks contiguous allocations again. This is the direct candidate fix for the
  +8.65% draw regression this commit accepts.
- Calibrate plan-time thresholds in the benchmark harness so planner changes get
  a real verdict instead of descriptive evidence
  (`agent-docs/terminal-performance.md`). This change is the second planner
  change in a row whose primary effect no verdict can speak to.
- `TerminalPaneSessionController.diagnosticCapture(test:)`
  (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift:428`)
  replaces `cachedTerminal` from `host.fencedDiagnosticState()` without folding
  that state's damage into `pendingDamage`. Before row reuse this was harmless
  because every frame replanned in full; now a diagnostic capture taken between
  frames could leave the planner reusing rows for content it never saw damaged.
  It is a `package` test seam, so no shipping path is affected, but the
  invariant it breaks is now load-bearing.
