# Findings -- sparse AppKit damage clip topology

This is the append-only investigation notebook migrated from
`docs/scratch/m9-criterion-2-power-performance.md`. It began as the broader M9
criterion-2 survey, then captured the complete sparse-damage regression and fix.
The optimization-specific orientation and outcome are in [README.md](README.md);
the selected directions are in [decisions.md](decisions.md).

Stable finding map:

- F1 -- criterion-2 scheduling and platform facts.
- F2 -- AppKit bounding-union overdraw.
- F3 -- per-row compound-clip regression.
- F4 -- live post-halo topology.
- F5 -- controlled three-arm coalescing result.
- F6 -- low-complexity and maximum-span acceptance.
- F7 -- permanent benchmark gap.

The notebook remains intentionally chronological. Earlier provisional claims
are retained and superseded in place by later controlled measurements.

Rules for this file, so it stays worth trusting:

- Every claim about existing behavior cites the identifier that proves it.
- Every claim about AppKit/Darwin cites the SDK header or the rendered doc page.
- Anything unverified is marked UNVERIFIED. No exceptions -- an unmarked claim
  here will get believed later, including by me.

Target: `plan-terminal-engine/14-roadmap.md`, milestone 9, criterion 2 --
"[Power and performance](13-power-performance.md) passes idle, hidden-pane,
visible-output, recovery-freshness, sleep/wake, responsiveness, and teardown
gates."

## Gate status

Re-derive this from source before writing the plan. An earlier pass of this
table was wrong (see Corrections), so treat it as a starting point, not input.

| Gate | Status | Evidence |
| --- | --- | --- |
| idle | open | no test asserts an unchanged focused terminal schedules nothing |
| hidden pane | likely covered | `TerminalPaneSessionControllerTests` -- hidden controller exits with zero plans while `readViewportText()` shows final output |
| visible output | partly | `burstConflatesToFinalPlan` covers conflation under a stalled consumer; not framed as a power gate |
| recovery freshness | likely covered | `RecoveryCheckpointPolicyTests` is a real pure-policy suite |
| sleep/wake | open, and unimplemented | no `NSWorkspace` sleep/wake observer anywhere in `app/` |
| responsiveness | open | waived under criterion 1 as low-value, but doc 13 names it, so it returns here |
| teardown | open | nothing asserts every owner-bound timer and scheduled callback is cancelled |

## F1 -- criterion-2 scheduling and platform facts

### The scheduling policy already exists

`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#planIfNeeded`.
Every terminal mutation funnels through it. Four gates, in order:

1. `pendingDamage != .none` -- nothing changed, no work.
2. Terminal value and theme both unchanged since last plan -- skip. Whole-value
   equality on `Terminal`, so it catches output that writes without altering the
   grid.
3. Synchronized output (DECSET 2026) active -- hold, unless the child exited, so
   a crashed TUI cannot strand its last output forever.
4. Visibility -- callers only invoke it when `isVisible`. Damage accumulates
   while hidden; `TerminalPaneSession#setVisible` plans once on reveal.

Damage retention is bounded by construction: `pendingDamage` is one merged
`TerminalDamage` (row set or full-redraw marker), reset to `.none` after each
publish. Doc 13's "no event-by-event render queue" invariant therefore holds
structurally, not by test.

This matters because it means the semantic decision -- *should work happen* --
is already upstream of AppKit and unit-testable without a WindowServer, which is
what doc 13's "identical scheduling inputs produce identical requests for work
independent of AppKit timing" invariant asks for. No refactor needed.

### AppKit invalidation coalescing (verified)

`NSView.setNeedsDisplay(_:)` "increases the view's existing invalid region to
include it," and views marked as needing display "are automatically redisplayed
on each pass through the application's event loop."
Source: rendered Apple doc page for `NSView.setNeedsDisplay(_:)`, fetched
2026-08-01 via Chrome (WebFetch returns an empty SPA shell for developer.apple.com
-- do not trust a WebFetch summary of these pages, see Corrections).

So the per-row `setNeedsDisplay` calls in
`app/SwiftTerminalSessionView.swift#publish` do merge, and drawing happens once
per event-loop pass.

### Sleep/wake API surface (verified)

`AppKit.framework/Headers/NSWorkspace.h#NSWorkspaceWillSleepNotification` and
`#NSWorkspaceDidWakeNotification`, with `NSWorkspaceScreensDidSleepNotification`
and `NSWorkspaceScreensDidWakeNotification` declared alongside them.

Trap worth writing into the plan: `NSWorkspace.h#notificationCenter` states that
all notifications in that header must be registered on
`NSWorkspace.shared.notificationCenter`, and registering on any other center
receives nothing -- silently. Easy to get wrong and hard to notice.

## F2 -- AppKit bounding-union overdraw (verified)

Implementation record:
[Preserve sparse terminal damage through AppKit](../../../plans/impl/2026-08-01-2219-preserve-sparse-appkit-terminal-damage.md).

`SwiftTerminalSessionView#publish` invalidates each damaged row separately, but
AppKit passes their union to `SwiftTerminalSessionView#draw`. A controlled
optimized-app probe on 2026-08-01 changed PTY rows 2 and 33 in each published
frame. The benchmark observer at
`TerminalBenchmarkObserver#observeCompletedDraw` reported
`dirtyRowCounts: [34, 34, 34]`; the same-session single-row control reported
`[3, 3, 3]`. Both blocks measured three draws at 179x66, scale 2, while the
window was visible and thermal state nominal.

The 3-row control is the expected damaged row plus the glyph halo from
`terminalDamageRowsWithGlyphHalo`. The 34-row scattered result spans both
3-row halos and the untouched rows between them, proving that the single
`dirtyRect` consumed by `draw` is the union rather than one disjoint component.
Because `draw` derives one contiguous row range with
`TerminalRenderExecution#terminalRows(intersecting:metrics:rowCount:)`, it clips
and submits all 34 rows.

The current working-tree fix preserves and merges source row damage in
`SwiftTerminalSessionView#pendingDisplayDamage`, promotes geometry/theme/benchmark
invalidations to full damage in `#invalidateFullDisplay`, and consumes the exact
shape in `#drawingDamage` to clip both the plan and CGContext. The AppKit harness
test in `SwiftTerminalSessionViewTests#swiftTerminalSessionViewTests` publishes
two distant frames before one draw and asserts that only their two 3-row halos
reach the renderer. This turns the finding into a directly proved visible-output
gate rather than a future plan item.

A same-session descriptive before/after run on 2026-08-01 used the optimized
real-AppKit harness at 179x66, scale 2, with the identical two-row stimulus in
both arms (`scripts/terminal-draw-acceptance.py#main`). Each arm collected eight
valid batches above a 200 ms draw-work floor; the baseline had 102 draws per
batch and the candidate 697, with every draw reporting the same 34-row AppKit
union through `TerminalBenchmarkObserver#observeCompletedDraw`.

- Direct draw time: 2.336 ms/draw baseline median (2.309--2.399 ms batch
  range), 0.343 ms/draw candidate (0.342--0.345 ms), an 85.3% reduction.
- Whole-process CPU: 5.801 ms/draw baseline median (5.739--6.128 ms), 2.917
  ms/draw candidate (2.898--2.946 ms), a 49.7% reduction.
- Same-session control: paired `terminal-feed`, which cannot reach the AppKit
  change, was `equivalent` at +0.42% under its frozen quick rule.

This is direct performance and CPU-work evidence for the specific sustained
two-distant-row stimulus. The CPU reduction supports the expected energy
direction on that shape, but no power or battery quantity was measured, so it
is not an energy-consumption claim. The scattered run is diagnostic-only, not a
calibrated regression verdict, and the live-btop finding below proves it does
not generalize to arbitrary sparse-damage topology.

## F3 -- per-row compound clips regress live btop

Commit `d37809616517081fd851ef4022e496bd389ef1cb` preserved sparse engine
damage through `SwiftTerminalSessionView#pendingDisplayDamage`, then
`SwiftTerminalSessionView#draw` constructed one CGContext path by calling
`addRect` once per damaged row before `clip()`. A live optimized-app capture
while the user held Down in btop's process list puts a new dominant subtree on
Core Animation's replay queue:

```
CA::CG::DrawOp::render
  -> CA::CG::ClipOp::ClipOp
  -> CA::CG::ClipPath::prepare
  -> CA::Shape::new_shape
  -> PathConverter::close_rect
  -> CA::Shape::Union
  -> CA::ShapeHandle::finish
```

Artifacts are disposable `.build/` evidence, so the decision-bearing counts
are transcribed here as well as linked:

- Candidate (`d378096`):
  [raw sample](../../../.build/manual-profiles/2026-08-01-232142-2471-btop-scroll/sample.txt),
  [parsed report](../../../.build/manual-profiles/2026-08-01-232142-2471-btop-scroll/profile-report.json).
  PID 2471 ran the installed optimized `DanTerm Dev.app`; its executable SHA-256
  matched the workspace optimized app byte-for-byte
  (`4a79c0a399baf703ccfaac7730607b3be1a86fe207802737368aaa91b703442b`).
- Parent (`a94abc268f56ae96c5ed64ea87c7a7ddd96f8270`, exactly `d378096^`):
  [raw sample](../../../.build/manual-profiles/2026-08-01-233533-7994-btop-scroll-parent/sample.txt),
  [parsed report](../../../.build/manual-profiles/2026-08-01-233533-7994-btop-scroll-parent/profile-report.json).
  PID 7994 ran an optimized isolated-slot app built from detached tree
  `25026c4fce5afedb7388cfe41f7668825d1c3807`.

Both captures used `sample` for 20 seconds at 1 ms while the user held Down in
btop. The candidate was the reported full-screen 179x66 workload. The parent
window's geometry was not independently recorded before capture: whether it
also measured 179x66 is **UNVERIFIED**. Therefore the absolute cross-arm ratios
below are provisional, not a regression verdict. The stack-level mechanism is
not provisional: only the candidate contains the compound row clip in DanTerm
source, and that exact clip preparation dominates its CA queue.

Initial, geometry-confounded pair:

| Region (inclusive samples) | Parent | `d378096` | Candidate / parent |
| --- | ---: | ---: | ---: |
| Core Animation `CA::CG::Queue` thread | 1,602 | 4,969 | 3.10x |
| `CA::CG::ClipOp::ClipOp` | 108 | 3,814 | 35.3x |
| `CA::CG::ClipPath::prepare` | 99 | 3,804 | 38.4x |
| `CA::Shape::new_shape` | 56 | 3,750 | 67.0x |
| `CABackingStoreGetFrontTexture` (mostly main-thread wait) | 1,341 | 4,726 | 3.52x |
| `drawRenderFrame` | 1,118 | 717 | 0.64x |
| `PaneFramePlanner.planFrame` | 379 | 310 | 0.82x |
| `Terminal.feed` | 469 | 379 | 0.81x |

A second same-session pair removed the geometry confound. Each arm was a fresh
isolated optimized app with one pane. The harness converged each ordinary
window to 1728x1083 points, observed a 179x66 shell grid, launched btop, then
verified `stty` reported `66 179` on btop's live PTY immediately before the
20-second held-Down capture. The parent ran first and was stopped before the
candidate launched; no build ran during either sample. Targeting used each
arm's bundled CLI, explicit socket and pane id, and an unset `DANTERM_PANE` so
the controller could not escape to the originating DanTerm instance.

- Controlled parent (`a94abc268f56ae96c5ed64ea87c7a7ddd96f8270`):
  [raw sample](../../../.build/manual-profiles/2026-08-02-000525-23432-btop-scroll-controlled-parent/sample.txt),
  [parsed report](../../../.build/manual-profiles/2026-08-02-000525-23432-btop-scroll-controlled-parent/profile-report.json),
  [provenance](../../../.build/manual-profiles/2026-08-02-000525-23432-btop-scroll-controlled-parent/provenance.json).
- Controlled candidate (`d37809616517081fd851ef4022e496bd389ef1cb`):
  [raw sample](../../../.build/manual-profiles/2026-08-02-000811-25204-btop-scroll-controlled-candidate/sample.txt),
  [parsed report](../../../.build/manual-profiles/2026-08-02-000811-25204-btop-scroll-controlled-candidate/profile-report.json),
  [provenance](../../../.build/manual-profiles/2026-08-02-000811-25204-btop-scroll-controlled-candidate/provenance.json).

| Region (inclusive samples) | Controlled parent | Controlled `d378096` | Candidate / parent |
| --- | ---: | ---: | ---: |
| Core Animation `CA::CG::Queue` thread | 1,395 | 4,780 | 3.43x |
| `CA::CG::ClipOp::ClipOp` | 96 | 3,604 | 37.5x |
| `CA::CG::ClipPath::prepare` | 89 | 3,596 | 40.4x |
| `CA::Shape::new_shape` | 52 | 3,536 | 68.0x |
| `CABackingStoreGetFrontTexture` (mostly main-thread wait) | 1,151 | 4,542 | 3.95x |
| `drawRenderFrame` | 1,039 | 723 | 0.70x |
| `PaneFramePlanner.planFrame` | 361 | 337 | 0.93x |
| `Terminal.feed` | 426 | 379 | 0.89x |

The controlled pair reproduces both the direction and approximate magnitude of
the initial pair. The original pair's ratios remain provisional, but the
regression attribution no longer depends on them: at identical verified
geometry the candidate again reduces direct draw work while adding roughly
3.4x CA queue work, almost entirely under compound clip construction. This is
decision-bearing replication of the mechanism, while `sample` remains an
attribution instrument rather than a calibrated whole-process CPU benchmark.

Inside the candidate's 4,969-sample CA queue, `ClipOp` owns 3,808 samples
(76.6%), `ClipPath.prepare` 3,750 (75.5%), and the old glyph-bounds node
`CA::CG::DrawGlyphs::compute_dod_` only 423 (8.5%). Self time concentrates in
`CA::ShapeHandle::finish` (21.2% of the queue), `CA::Shape::Union` (20.4%), and
`CA::Shape::contains` (10.6%). `Terminal.feed`, planning, and DanTerm's direct
draw all shrink in the provisional comparison; they cannot explain the
reported process increase. The direct-draw optimization worked, but on this
live shape it changed the resource the draw consumes: cheap, linear glyph
overdraw became compound-clip shape construction paid by Core Animation for
recorded draw operations on every frame. It appears to have moved a larger cost
to asynchronous CA replay and made the main thread wait for that replay at
backing-store commit. The direct-draw timer is structurally blind to the
resource introduced by this change because its bracket closes before that
replay begins.

The original `d378096` path also amplifies its own input unnecessarily.
`TerminalDamage.rows` is a set, and `SwiftTerminalSessionView#draw` in that
revision emits one rectangle per row,
including adjacent rows that one taller rectangle could represent exactly. The
two-distant-row diagnostic that justified the change exercised two rectangles
and two spans. Live btop can exercise both more rectangles and more spans, so
the change was validated on the sparse topology most favorable to it.

## F4 -- live post-halo damage topology

Temporary draw-side diagnostics then measured the exact post-halo,
post-publish-union `TerminalDamage` consumed by `draw(_:)`. The activity
snapshot records a bounded joint histogram of damaged rows, maximal contiguous
spans, full damage, and dirty-rect fallback, plus a
mandatory sample count. It updates integer counters per draw and serializes
only after the draw timer has closed. This diagnostic build is suitable for
topology attribution, not CPU comparison.

At a verified 179x66 grid, a tightly bracketed run sent 200 Down events at a
requested 100 ms interval while btop's process list was selected. The 24.18 s
activity delta contains 221 draws and 221 topology samples:

| Post-union draw topology | Draws | Share |
| --- | ---: | ---: |
| 45 damaged rows, 2 maximal spans | 197 | 89.1% |
| 2 damaged rows, 1 maximal span | 12 | 5.4% |
| 66 damaged rows, 1 maximal span | 12 | 5.4% |

No draw used full damage or dirty-rect fallback. The
current implementation therefore submitted 9,681 row rectangles across the
window, while maximal-span coalescing would submit 418 rectangles for the
identical clips: 23.2x fewer, reducing the dominant 45-row shape from 45
rectangles to 2. This verifies H2's topology premise on live btop. The later
three-arm comparison verifies its performance result. Artifacts:

- [before activity snapshot](../../../.build/manual-profiles/2026-08-02-002006-33774-btop-damage-topology/activity-before.json)
- [after activity snapshot](../../../.build/manual-profiles/2026-08-02-002006-33774-btop-damage-topology/activity-after.json)
- [topology delta](../../../.build/manual-profiles/2026-08-02-002006-33774-btop-damage-topology/topology-delta.json)
- [provenance](../../../.build/manual-profiles/2026-08-02-002006-33774-btop-damage-topology/provenance.json)

## F5 -- controlled three-arm coalescing result

Maximal-span coalescing then changed the CGContext path to one rectangle per
maximal contiguous row run while preserving the same exact `TerminalDamage`
for plan clipping. A same-session three-arm run then compared the exact parent,
exact uncoalesced `d378096`, and the coalesced working tree. Each fresh optimized
app used a 1728x1083-point window and live-verified 179x66 PTY. Before each
instrument, the harness sent Home followed by 650 Down events with a requested
15 ms inter-event sleep. `sample` ran for 20 seconds, and a separate `top` run
collected 20 one-second process-CPU observations. The run order was coalesced,
parent, uncoalesced; the thermal state was nominal immediately before the third
arm. The user maintained foreground state during these runs, but the harness
did not verify it. Future Down-arrow runs must foreground the exact app arm
programmatically before measurement and record that fact in provenance.

- Coalesced:
  [raw sample](../../../.build/manual-profiles/2026-08-02-003600-39976-btop-scroll-controlled-coalesced-automated/sample.txt),
  [parsed report](../../../.build/manual-profiles/2026-08-02-003600-39976-btop-scroll-controlled-coalesced-automated/profile-report.json),
  [CPU summary](../../../.build/manual-profiles/2026-08-02-003600-39976-btop-scroll-controlled-coalesced-automated/cpu-summary.json),
  [provenance](../../../.build/manual-profiles/2026-08-02-003600-39976-btop-scroll-controlled-coalesced-automated/provenance.json).
- Exact parent:
  [raw sample](../../../.build/manual-profiles/2026-08-02-004200-54633-btop-scroll-controlled-parent-automated/sample.txt),
  [parsed report](../../../.build/manual-profiles/2026-08-02-004200-54633-btop-scroll-controlled-parent-automated/profile-report.json),
  [CPU summary](../../../.build/manual-profiles/2026-08-02-004200-54633-btop-scroll-controlled-parent-automated/cpu-summary.json),
  [provenance](../../../.build/manual-profiles/2026-08-02-004200-54633-btop-scroll-controlled-parent-automated/provenance.json).
- Exact uncoalesced `d378096`:
  [raw sample](../../../.build/manual-profiles/2026-08-02-004800-60501-btop-scroll-controlled-uncoalesced-automated/sample.txt),
  [parsed report](../../../.build/manual-profiles/2026-08-02-004800-60501-btop-scroll-controlled-uncoalesced-automated/profile-report.json),
  [CPU summary](../../../.build/manual-profiles/2026-08-02-004800-60501-btop-scroll-controlled-uncoalesced-automated/cpu-summary.json),
  [provenance](../../../.build/manual-profiles/2026-08-02-004800-60501-btop-scroll-controlled-uncoalesced-automated/provenance.json).

| Region (inclusive `sample` counts) | Parent | Uncoalesced `d378096` | Coalesced |
| --- | ---: | ---: | ---: |
| Core Animation `CA::CG::Queue` thread | 1,251 | 4,824 | 1,497 |
| `CA::CG::ClipOp::ClipOp` | 71 | 3,640 | 162 |
| `CA::CG::ClipPath::prepare` | 62 | 3,629 | 159 |
| `CA::Shape::new_shape` | 32 | 3,558 | 86 |
| `CABackingStoreGetFrontTexture` (mostly main-thread wait) | 1,037 | 4,616 | 1,273 |
| `drawRenderFrame` | 977 | 702 | 751 |
| `PaneFramePlanner.planFrame` | 394 | 382 | 380 |
| `Terminal.feed` | 324 | 348 | 328 |

| Whole-process CPU (`top`, 18 steady observations) | Parent | Uncoalesced `d378096` | Coalesced |
| --- | ---: | ---: | ---: |
| Mean | 24.17% | 44.10% | 22.94% |
| Median | 24.75% | 45.45% | 23.20% |
| Range | 18.3--25.6% | 31.7--46.8% | 19.0--24.7% |

The parent and coalesced CPU ranges overlap, so this supports only the required
"equivalent or better" conclusion, not a 5% speedup claim. The uncoalesced
range is completely separated and roughly doubles the parent/coalesced CPU,
directly reproducing the user's 40% symptom under automation. Coalescing removes
69% of the uncoalesced CA queue samples and 95.5% to 97.6% of the compound-shape
subtree under the same event count and requested cadence. The automated cadence
could in principle under-drive OS key repeat, because cost scales with draw
rate, but this run reached 44% anyway and therefore reproduced the live failure
mode rather than merely inferring it from the earlier manual profile.

The automated stimulus therefore satisfies the reproducibility precondition
for permanent sparse-topology benchmark coverage. Under one controlled cadence,
the uncoalesced arm is separated from both the parent and coalesced arms by
roughly 20 percentage points of process CPU, while its clip subtree is roughly
23x larger than coalesced. A permanent workload still needs a calibrated
whole-process CPU rule; this proves the trigger is reproducible, not that the
current auxiliary metric can already issue that verdict.

`sample` records blocked as well as running states, so the table must not be
summed into whole-process CPU. The CA queue's clip-construction subtree is
ordinary running work; the 4,417 candidate samples under
`CABackingStoreGetFrontTexture -> kevent_id` are blocked time, not CPU. They are
still important causal evidence: the main thread is waiting for the queue that
is constructing the compound clip.

## F6 -- revised implementation acceptance results

The coalesced implementation was rerun against `d378096^` on the original
two-distant-row shape. The temporary producer changed engine rows 2 and 33, so
the glyph halo produced two disjoint 3-row spans and AppKit still reported a
34-row bounding dirty rectangle. Each arm ran eight foreground-visible,
thermal-nominal, valid 200-draw batches at 179x66:

- [coalesced summary](../../../.build/manual-profiles/2026-08-02-005800-two-distant-row-coalesced-200/summary.json)
- [parent summary](../../../.build/manual-profiles/2026-08-02-005900-two-distant-row-parent-200/summary.json)

| Two-distant-row metric | Parent | Coalesced |
| --- | ---: | ---: |
| Direct draw median | 0.164 ms/draw (0.163--0.165) | 0.057 ms/draw (0.055--0.058) |
| Whole-process CPU median | 2.115 ms/draw (2.097--2.183) | 1.945 ms/draw (1.899--2.002) |

The revised implementation retains the motivating win: direct draw is about
65% lower, and whole-process CPU is about 8% lower with separated batch ranges.
This clears the low-complexity half of the keep bar without relying on the much
larger pre-revision percentage from a different harness cadence.

The adversarial endpoint was derived from the one-row glyph halo already stored
in `pendingDisplayDamage`. Writes every two rows overlap into full damage and
writes every three rows touch end-to-end; writes every four rows maximize the
number of disjoint 3-row halo runs. At 66 rows, ANSI rows 1, 5, ..., 65 produce
50 damaged rows in exactly 17 spans, with a 66-row AppKit dirty union. The
topology activity snapshot observed five measured draws at exactly 50 rows and
17 spans, and the 10-draw calibration block reported the 66-row union on every
draw:

- [17-span activity snapshot](../../../.build/manual-profiles/2026-08-02-010000-stride-four-coalesced/activity-17-spans.json)
- [17-span calibration block](../../../.build/manual-profiles/2026-08-02-010000-stride-four-coalesced/calibration-17-spans.json)

Before looking at the result, the rule was frozen: if coalesced CPU overlapped
or beat parent at this maximum-span endpoint, add no fallback; if coalesced lost
with separated ranges, activate H3 and measure midpoint span counts. Eight
foreground-visible, thermal-nominal, valid 200-draw batches per arm produced:

- [coalesced summary](../../../.build/manual-profiles/2026-08-02-010500-stride-four-coalesced-200/summary.json)
- [parent summary](../../../.build/manual-profiles/2026-08-02-010600-stride-four-parent-200/summary.json)

| Maximum-span metric | Parent | Coalesced |
| --- | ---: | ---: |
| Direct draw median | 0.274 ms/draw (0.272--0.276) | 0.242 ms/draw (0.241--0.244) |
| Whole-process CPU median | 4.835 ms/draw (4.783--4.943) | 4.695 ms/draw (4.596--4.777) |

Coalesced is no slower at the endpoint, so the frozen rule rejects a complexity
fallback. The maximum exposed span count grows with terminal height (about
`ceil(rows / 4)` for this halo geometry), but the 179x66 endpoint directly
covers the reported regression geometry.

Final 20-second `sample` profiles at the same sustained stride-four endpoint
ran at nearly identical measured draw rates: 118.62 draws/s coalesced and
118.88 draws/s parent. Coalesced necessarily retains more clip-shape work than
the parent's one bounding rectangle, but saves enough direct rendering work to
avoid a net loss:

- [coalesced sample](../../../.build/terminal-benchmark-profiles/2026-08-02-010825-86939/sample.txt)
  and [frame accounting](../../../.build/terminal-benchmark-profiles/2026-08-02-010825-86939/frame-accounting.json)
- [parent sample](../../../.build/manual-profiles/2026-08-02-010926-parent-stride-four-profile/sample.txt)
  and [frame accounting](../../../.build/manual-profiles/2026-08-02-010926-parent-stride-four-profile/frame-accounting.json)

| Maximum-span profile region (inclusive samples) | Parent | Coalesced |
| --- | ---: | ---: |
| Core Animation `CA::CG::Queue` thread | 5,124 | 4,910 |
| `CA::CG::ClipOp::ClipOp` | 56 | 784 |
| `CA::CG::ClipPath::prepare` | 46 | 779 |
| `CA::Shape::new_shape` | 51 | 730 |
| `CABackingStoreGetFrontTexture` | 4,860 | 4,671 |
| `drawRenderFrame` | 490 | 373 |
| `Terminal.feed` | 321 | 261 |

The clip subtree is larger than parent at 17 spans, as expected, but total CA
queue and backing-store-wait counts are not larger, direct draw is smaller, and
the calibrated CPU batches favor coalescing. This attribution is consistent
with the decision metric and closes H3 without a threshold sweep.

## F7 -- why the benchmark suite missed it

No frozen verdict currently covers both the trigger and the cost:

- `incremental-mixed` reaches partial damage, but
  `scripts/terminal-benchmark-producer.py#incremental_mixed_rows` changes four
  adjacent rows. The glyph halo makes six contiguous row rectangles, not the
  more complex live-btop topology. In the current 30-second Time Profiler trace,
  `ClipPath.prepare` is only 40 ms (0.51% of 7,861 ms total) and
  `CA::Shape::new_shape` 37 ms (0.47%).
- The three draw workloads decide on `drawNanosecondsPerDraw`, whose bracket in
  `SwiftTerminalSessionView#draw` ends before CA asynchronously replays the
  display list. The live capture shows exactly the failure mode that bracket
  cannot see: direct draw falls while later CA work rises.
- `processCPUNanosecondsPerDraw` can see work on all threads, but it is an
  uncalibrated auxiliary metric and cannot issue a verdict. Its existing
  schedule also carries only the simple six-row `incremental-mixed` topology.
- `content-churn` and `style-churn` publish full damage, so
  `SwiftTerminalSessionView#draw` skips the compound sparse path.
- `synchronized-frames` contains all 95 captured btop frames inside one DECSET
  2026 bracket and draws only after the final reset. It does not exercise one
  sparse clip per live btop frame and has no frozen rule anyway.
- The temporary diagnostic that justified `d378096` changed only two distant
  rows and was explicitly not retained as a workload. It proved the avoided
  bounding-gap draw cost, not the cost curve as the number and arrangement of
  row rectangles grows.

This is a real coverage gap, not merely an unlucky benchmark result: the suite
does not contain a decision-bearing workload whose independent variable is
sparse-clip topology and whose metric includes post-`draw` CA CPU.

#### Hypotheses to test

- **H1 -- rectangle count/topology causes the CA cliff.** One rectangle per row
  makes CA rebuild and union a compound shape for every recorded draw op. Cost
  grows with row rectangles or disjoint row runs, not just damaged area.
  Supported by the controlled btop triangle and maximum-span endpoint. The exact
  curve outside the measured 2-, 17-, and 45-rectangle shapes is **UNVERIFIED**.
- **H2 -- coalescing adjacent rows into maximal spans removes most of the live
  cost.** **VERIFIED.** Live btop's dominant 45-row damage collapses to 2 spans;
  the controlled three-arm run recovers essentially the entire CPU regression
  and reduces the compound-shape subtree by 95.5% to 97.6%.
- **H3 -- a complexity threshold can retain the two-distant-row win without the
  btop loss.** **NOT NEEDED at 179x66.** The frozen rule rejects a fallback
  because coalescing is no slower than parent at the halo-limited maximum of 17
  spans. Larger grids raise that bound and remain outside this measurement.
- **H4 -- separate simple rectangular draws avoid compound-shape replay.** Draw
  each maximal span under one rectangular clip instead of recording one path
  containing all spans. This may duplicate frame-level draw setup and display
  list operations. It remains **UNVERIFIED** and is not justified by the result.

#### Next experiments, in order

1. **COMPLETED 2026-08-02.** A same-session parent-then-candidate pair used fresh
   isolated apps, identical 1728x1083-point windows, and live PTY verification
   of 179x66 immediately before both samples. Reports from
   `scripts/terminal-profile-report.py` reproduce the CA queue regression at
   3.43x and compound clip construction at 37.5x to 68.0x. A future repeat
   should swap arm order to expose any remaining order bias, but geometry no
   longer blocks the next experiment.
2. **COMPLETED 2026-08-02.** Temporary activity diagnostics recorded a joint
   topology histogram plus sample count from the exact damage consumed by every
   draw. In the controlled btop interval, 197 of 221 draws contained 45 rows but
   only 2 maximal spans; every draw contained at most 2 spans, and no fallback
   fired. Coalescing would reduce the observed rectangle total 23.2x.
3. **COMPLETED 2026-08-02.** Maximal-span coalescing is implemented and
   the AppKit harness proves disjoint row halos still reach the renderer
   exactly. The controlled live profile returns CA queue work and backing-store
   wait to within 9% of `d378096^`, removes 94.9% to 97.3% of the regressed
   shape subtree, and the controlled CPU ranges overlap parent. The original
   two-distant-row diagnostic retains separated direct-draw and process-CPU wins.
4. **COMPLETED 2026-08-02; fallback rejected.** The halo-limited 17-span endpoint
   was calibrated at 179x66 and measured under a frozen rule. Coalesced CPU
   overlaps or beats parent, so no threshold sweep, separate-draw variant, or
   complexity fallback is justified.
5. **COMPLETED 2026-08-06; calibration refused.** `sparse-spans-max` promoted the
   deterministic 17-span shape into a collectable candidate whose primary
   quantity is whole-process CPU. Three valid A/A screens produced incompatible
   outcomes, so it remains descriptive rather than joining the calibrated
   workload set (F8, D3).

#### Keep, revise, or revert `d378096`

The motivating problem was overdraw, not incorrect terminal pixels. Reverting
returns to a simpler, visually correct bounding-row draw at the cost measured by
the two-distant-row diagnostic. A revert is therefore a legitimate outcome, not
a correctness failure.

Keep a revised sparse-damage implementation only if same-session evidence shows
all of the following:

- it retains a material win on distant low-complexity damage;
- it is no slower than `d378096^` on replicated 179x66 live btop scrolling;
- the CA clip-construction subtree is removed or bounded below the chosen bar;
- full damage, AppKit fallback draws, glyph halos, and merged pre-draw damage
  still pass their behavioral tests.

**Decision: keep a revised `d378096` with maximal-span coalescing.** It retains
the low-complexity win, is equivalent or better than parent on controlled btop,
and is no slower at the maximum 17-span 179x66 endpoint. No fallback or separate
draw policy is justified. `just test` passed all 60 steps and `just test-ui`
passed 207/207 after the final implementation and instrumentation cleanup. Do
not generalize this into a direct-draw-only claim: the live profile proves that
metric can improve while whole-process CPU regresses.

## F8 -- permanent CPU calibration refused

M9 screened `sparse-spans-max` three times on 2026-08-06. Each screen used the
same immutable tree (`7682facd1badf435e2588de8a8d7fbb502485804`), 12 complete
quartets, 24 A/A pairs, the existing pair-count and threshold grids, and 50,000
resampling trials per condition. All blocks passed the 50-draw CPU-coverage and
17-engine-row/17-engine-span topology contracts; no quartet was discarded.

| Series | Median | SD | Trimmed SD | Range | Selection |
| --- | ---: | ---: | ---: | ---: | --- |
| Exploratory 1 | -0.09% | 5.58% | 4.44% | -5.96%..+17.26% | no quick or confirm cell |
| Exploratory 2 | -0.31% | 2.20% | 1.86% | -4.98%..+4.04% | quick 8 pairs at 3.0%; confirm 16 pairs at 2.15% |
| Controlled low-load | -0.78% | 4.71% | 3.43% | -15.05%..+7.23% | no quick or confirm cell |

The one series that proposed rules did not replicate. Applied unchanged to
exploratory series 1, its quick cell produced 11.93% A/A false positives and
85.59%/86.21% detection; its confirm cell produced 13.32% false positives and
76.00%/76.33% detection. The gates require at most 1% false positives and at
least 90% detection on every independently collected series. Pooling the series
or discarding the noisy ones would hide the instability the protocol exists to
surface.

The controlled run began at load 1.69 across ten processors (0.17 per
processor), so closing active applications did not make the quantity stable.
Because screening selected no reproducible cell, no held-out confirmation or
synthesized known-bad sensitivity arm could legitimately run. The candidate
therefore remains useful for checking and describing exact topology, but issues
no CPU verdict and provides no automated coverage claim for the historical
per-row Core Animation regression.

## Open questions

### Q2: where does sleep/wake logic live?

The one real design decision.

- **Fifth gate inside `planIfNeeded`** -- keeps it testable without a
  WindowServer, consistent with how visibility is already handled.
- **`app/` observer driving `setVisible`-style calls into the session** -- less
  code, but the proof needs a GUI session (`just test-ui`, not `just test`).

Leaning toward the first on testability grounds, but not decided.

### Q3: system sleep only, or screen sleep too?

Doc 13 says "sleep/wake" without distinguishing, but the header shows these are
separate events. Screen sleep with the machine awake is arguably the more common
case for a terminal running a long job. Needs an owner decision; may need a doc
13 wording fix either way.

### Q4: what do idle and teardown look like as assertions?

Neither has an obvious existing seam the way the visibility gate did.

- Idle: doc 13 wants "explicit scheduling traces prove quiescence ... without
  relying only on elapsed-time assertions." So: a trace/recorder, not a sleep.
- Teardown: "cancels every owner-bound timer and scheduled callback." The
  enumeration is the hard part -- how does a test know the set is complete?
  Idea: make registration go through one place so the test can assert the
  registry empties. Unclear if that is worth the churn.

## Ideas / parking lot

- The checkpoint policy (`RecoveryCheckpointPolicyTests`) is the model to copy
  for idle: a pure policy type, tested by feeding it inputs and asserting the
  requests it emits. If idle quiescence gets the same treatment, the trace
  requirement falls out for free.
- `AppRuntime#scheduleDebouncedCheckpoint` and `#scheduleCoalescedReconcile` are
  the only two timers in `app/` found so far. If that is the complete set, the
  teardown gate is much smaller than feared. NOT YET VERIFIED as complete.

## Corrections

Kept because the same mistakes are easy to repeat.

- Claimed there was no scheduling policy and that extracting one was the
  milestone's largest remaining piece. Wrong. I grepped `app/` for scheduling
  functions, found only the two timers, and concluded the render path was
  tangled in AppKit. The policy was in `TerminalPaneSession` the whole time.
  Lesson: the seam is not always in the layer that owns the side effect.
- Stated AppKit coalescing from memory as fact. It happened to be right, but the
  WebFetch that "confirmed" it returned an empty SPA shell and the summarizer
  filled the answer in from its own memory -- so the confirmation was worthless
  and nearly got passed on as verified. Apple docs need Chrome, per the
  fetching rule in the user's global instructions.
