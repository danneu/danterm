# Scratch: M9 criterion 2 -- power and performance

Working notes, not a plan. Freeform on purpose: open questions, findings with
citations, and half-formed ideas all live here so they stop evaporating between
sessions. A real plan gets derived from this later and goes in `plans/wip/`.

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

## Established facts

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

### Scattered damage over-draws (verified)

Implementation record:
[Preserve sparse terminal damage through AppKit](../../plans/impl/2026-08-01-2219-preserve-sparse-appkit-terminal-damage.md).

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

This is direct performance and CPU-work evidence for sustained scattered
visible output. The CPU reduction supports the expected energy direction, but
no power or battery quantity was measured, so it is not an energy-consumption
claim. The scattered run is diagnostic-only, not a calibrated regression
verdict.

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
