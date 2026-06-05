# Timer leeway for low-frequency checkpoint timers

## Context

DanTerm's session persistence runs two low-frequency background timers that
currently schedule with **zero leeway**, forcing the OS to wake the process at
an exact instant even though nothing observes the precise firing time:

- The **enriched checkpoint timer** — a 600s (10 min) repeating
  `DispatchSourceTimer` that reads scrollback from live Ghostty surfaces
  (`app/AppRuntime.swift:884-893`, interval const at line 78).
- The **light checkpoint debounce** — a 2s trailing-edge debounce over the
  shared `Debouncer` that writes a model-only snapshot after state changes
  settle (`app/AppRuntime.swift:842-847`, interval const at line 72;
  `Debouncer` at `lib/DanTermSupport/Sources/DanTermSupport/Debouncer.swift`).

Apple's `DispatchSourceTimer` guidance is to give low-frequency timers
generous leeway (rule of thumb: >=10% of the interval) so the kernel can align
these wakeups with other scheduled work and keep the CPU idle longer — a real
battery/efficiency win for timers whose exact deadline is irrelevant. Neither
of these checkpoints is latency-sensitive: a checkpoint written a few hundred
ms (or even tens of seconds) late is indistinguishable to the user.

**Intended outcome:** add leeway to exactly these two slow timers, while
leaving latency-sensitive timers (search-needle debounce, coalesced reconcile)
tight. No behavior change beyond when the OS chooses to fire; backward compatible.

## Changes

### 1. `Debouncer.schedule` — add an optional `leeway` parameter

`lib/DanTermSupport/Sources/DanTermSupport/Debouncer.swift`

Add a `leeway:` parameter to `schedule(after:perform:)`, defaulting to
`.nanoseconds(0)` (the exact current `DispatchSourceTimer.schedule` default, so
existing callers are byte-for-byte unchanged). Thread it through to **both**
`timer.schedule(...)` calls — the reschedule path (line 37) and the
lazy-create path (line 42).

```swift
/// Re-arm the trailing fire, keeping only the newest action. `leeway` is passed
/// straight to the dispatch source: give slow debounces (the light checkpoint)
/// a generous window so the OS can coalesce wakeups; leave latency-sensitive
/// callers (search) at the default zero.
func schedule(after delay: TimeInterval,
              leeway: DispatchTimeInterval = .nanoseconds(0),
              perform action: @escaping () -> Void) {
    pendingAction = action
    pending = true

    if let timer {
        timer.schedule(deadline: .now() + delay, leeway: leeway)
        return
    }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + delay, leeway: leeway)
    // ... unchanged ...
}
```

Also update the file-level contract to stop over-promising. The current header
(lines 1-6) says the reschedule shape preserves "trailing-edge timing exactly";
that is now true only at the default zero leeway. Reword the header (and the
matching phrase if it recurs in the class doc) to: preserves the trailing
deadline by default, with an optional `leeway` that hands the OS a coalescing
window for callers that can tolerate delayed delivery (the checkpoint timers) —
so a future latency-sensitive caller reading the header isn't misled.

Notes:
- `leeway` sits *before* `perform:`, so the existing trailing-closure call site
  and the explicit `perform: sendNeedle` search call site both keep compiling.
- `DispatchTimeInterval` is already in scope (`Foundation`/Dispatch); no new
  import, and no `DanTermCore`/purity concern — `Debouncer` already lives in the
  portable `DanTermSupport` layer and already uses `DispatchSourceTimer`.

### 2. Light checkpoint call site — pass `.milliseconds(200)`

`app/AppRuntime.swift:844` (inside `scheduleDebouncedCheckpoint()`)

```swift
checkpointDebouncer.schedule(after: Self.checkpointDebounceInterval,
                             leeway: .milliseconds(200)) { [weak self] in
    self?.performLightCheckpoint(async: true)
}
```

200ms is 10% of the 2s debounce — matches Apple's rule of thumb.

### 3. Enriched checkpoint timer — pass `leeway: .seconds(30)`

`app/AppRuntime.swift:887` (inside `startEnrichedCheckpointTimer()`)

```swift
timer.schedule(deadline: .now() + Self.enrichedCheckpointInterval,
               repeating: Self.enrichedCheckpointInterval,
               leeway: .seconds(30))
```

Decided: `.seconds(30)`, the value from the request. This is intentionally
tighter than the 10% rule-of-thumb (which would be 60s) because it doubles as a
staleness bound — it caps how late a periodic enriched checkpoint can land — and
30s is already a large coalescing window for a 600s timer. Implement `.seconds(30)`.

### 4. Deliberately left tight (no change)

- **Search-needle debounce** (`app/AppRuntime.swift:642`, 300ms for 1-2 char
  queries via `searchDebouncers`): user-facing search latency — must stay tight,
  so it keeps the default `.nanoseconds(0)`.
- **Coalesced reconcile timer** (`app/AppRuntime.swift:852-863`, 75ms one-shot
  `DispatchSourceTimer`): high-frequency UI coalescing, latency-sensitive —
  left untouched.

## Tests

Existing `DebouncerTests` stay green: leeway only ever *defers* a fire past the
deadline, never advances it, so the trailing-edge lower-bound assertion
(`elapsed >= delay * 0.75` in "reschedule moves deadline and keeps newest
action") is unaffected, and search callers pass no leeway.

Add **one** lightweight spec test to
`lib/DanTermSupport/Tests/DanTermSupportTests/DebouncerTests.swift` pinning the
only behavioral guarantee worth asserting (leeway is an OS power hint —
whether coalescing actually happens is not deterministically observable, so do
not assert an upper time bound):

- `@Test("Debouncer: schedule with a leeway still fires the trailing action")`
  — schedule once with `leeway: .milliseconds(200)` on the serial test queue,
  poll until the fire is recorded (generous timeout), then assert the action
  ran, `isPending` is false afterward, and elapsed `>= delay * 0.75` (fires no
  earlier than the deadline). Follow the existing serial-queue +
  `DispatchTime.uptimeNanoseconds` pattern already in that file.

  What this test does and does not cover: it covers **API compatibility** (the
  new signature compiles and accepts a nonzero `leeway` argument) and that the
  debouncer **still fires the trailing action with a nonzero leeway** (the new
  param doesn't suppress firing). It does **not** prove `leeway` was forwarded
  to `DispatchSourceTimer.schedule` — leeway only ever defers firing and is a
  best-effort OS hint, so an implementation that accepted the argument and
  dropped it would still pass. That propagation to **both** `timer.schedule`
  calls (reschedule path and lazy-create path) is verified by implementation
  review + the build, not by this test.

The two `app/AppRuntime.swift` edits are in the AppKit/GhosttyKit runtime layer
(not unit-testable per the architecture) and are single-line leeway additions;
they're covered by the build + manual verification below.

## Verification

1. `just test` — runs DanTermSupport Swift Testing (incl. the new + existing
   Debouncer tests), core tests, protocol tests, and the core-purity lint.
   Confirm all green.
2. `just build` — confirm `app/AppRuntime.swift` compiles with the two leeway
   args (verifies the `Debouncer` signature change is call-site compatible).
3. Smoke: `just build-run`, mutate state (open/close panes, rename a tab),
   confirm a light checkpoint still lands on disk shortly after activity
   settles (the 200ms leeway shouldn't be perceptible), and that the app
   continues to checkpoint/restore normally — i.e. no functional regression,
   only when-the-OS-fires changes.
