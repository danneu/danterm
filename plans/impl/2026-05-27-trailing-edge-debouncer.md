# Plan: pivot the checkpoint debounce off per-event timer churn

## Context

A performance audit (LOW severity) flagged that `.surfaceTitle` / `.surfaceCwd`
cancel-and-recreate a `DispatchSourceTimer` on every raw Ghostty event:

- `app/Update.swift:696-706` -- both messages return `[.scheduleCheckpoint]`.
- `app/AppRuntime.swift:578-579` -- `.scheduleCheckpoint` calls
  `scheduleDebouncedCheckpoint()`.
- `app/AppRuntime.swift:841-851` -- that method does
  `checkpointTimer?.cancel()` + `makeTimerSource` + `setEventHandler` +
  `resume()` on every call. A title-spamming TUI (progress/clock in the title)
  churns a fresh GCD timer object per raw event. The disk write itself is
  correctly debounced (2s) and off-main, so only timer-object allocation is
  wasted.

The audit proposed adopting the `guard timer == nil` pattern from
`scheduleCoalescedReconcile()` (`app/AppRuntime.swift:855-866`). **We are not
doing that** -- that pattern is a *fixed-window coalescer* (fires `interval`
after the *first* call in a burst), whereas the checkpoint debounce is
*trailing-edge* (fires `interval` after the *last* call). The trailing-edge
behavior is intentional and documented (`app/AppRuntime.swift:838-840`: "Each
call resets the timer so rapid-fire model changes e.g. dragging a split
divider coalesce into a single disk write") and is relied on by ~45
`.scheduleCheckpoint` emit sites. Swapping to fixed-window would regress that,
unguarded by any test.

**The pivot:** keep trailing-edge semantics *exactly* (identical
`now + interval` deadline math) but stop churning timer objects, by holding a
long-lived timer and *rescheduling* it. The identical cancel-and-recreate
pattern also exists in the search-needle debounce (`app/AppRuntime.swift:621-645`),
so we extract one small AppKit-free `Debouncer` helper and use it for both,
centralizing the subtle GCD lifecycle in a single tested-by-construction place.

Intended outcome: timer-object allocation drops from per-raw-event to per-fire
(negligible); the two hand-rolled copies of the debounce lifecycle collapse to
one; behavior is unchanged.

## Out of scope (deliberately not converted)

- `coalescedReconcileTimer` (`scheduleCoalescedReconcile`, `:855-866`) -- a
  genuinely different *fixed-window* pattern. Leave as-is.
- `enrichedCheckpointTimer` (`startEnrichedCheckpointTimer`, `:888-897`) -- a
  plain *repeating* timer, not a debouncer. Leave as-is.

## GCD lifecycle rules the helper enforces by construction

These are the load-bearing `DispatchSourceTimer` semantics; getting them wrong
either crashes libdispatch (`EXC_BAD_INSTRUCTION`) or leaks the source, so the
helper makes the lifecycle correct structurally rather than via tests:

1. A new source starts **suspended**; it delivers nothing until `resume()`.
   Call `resume()` **exactly once**, immediately after the first `schedule`,
   and **never `suspend()`**. This sidesteps the "release of a suspended object"
   crash entirely (that crash fires when the last reference to a *suspended*
   source is dropped -- e.g. a created-but-never-resumed source).
2. A fired non-repeating source stays **live and resumed** -- firing neither
   suspends nor cancels it. Calling `schedule(deadline:)` again re-arms the
   **same** source to fire at the new deadline, with **no second `resume()`**.
   This is what makes "reschedule-many" real: the source is reused across both
   rapid reschedules *and* across fires.
3. **A fired source is NOT retired by firing, and must not be dropped
   un-cancelled.** Releasing a resumed-but-un-cancelled source leaves teardown
   to undocumented release behavior; the safe, documented disposal is to
   `cancel()` it (which runs its cancel handling and releases it) *before*
   dropping the reference. So the source is **owned for the Debouncer's
   lifetime** and cancelled in exactly two places: `cancel()` and `deinit`.
   Verified against GCD docs (sources are reference-counted; suspend retains /
   resume releases, so a fully-resumed source is safe to cancel-then-drop)
   plus the SR-15133 never-resumed-crash report; the Ghostty macOS app avoids
   the question altogether by debouncing with `DispatchWorkItem` + `cancel()`
   (see Alternatives).
4. Therefore: **create-once, resume-once, reschedule-many (across fires too),
   cancel-and-drop only in `cancel()`/`deinit`.** A fire clears a separate
   `pending` flag but leaves the source intact; a later `schedule` re-arms it.
   After an explicit `cancel()`, the next `schedule` builds a fresh source, so
   resume and cancel are always paired -- one resume, one cancel, per source.

## The `Debouncer` helper (new file `app/Debouncer.swift`)

Mirror the standalone Foundation-only convention of `app/TickCoalescer.swift`
and `app/ScrollbarMath.swift` (file-level `//` header explaining intent + why it
earns its own file; `///` doc on the type capturing the invariant). AppKit-free
so it compiles into both the app build and the unit-test build.

```swift
// Generic trailing-edge debouncer over a long-lived DispatchSourceTimer. Create
// once, reschedule many: each schedule(after:) re-arms the same timer to fire
// `delay` after the LAST call, coalescing a burst into one trailing fire. The
// reschedule-instead-of-recreate shape eliminates per-call timer-object churn
// while preserving trailing-edge timing exactly. (Contrast the fixed-window
// `guard timer == nil` coalescer in AppRuntime.scheduleCoalescedReconcile, which
// fires after the FIRST call -- deliberately a different tool.) No AppKit/
// GhosttyKit dependency so it can be compiled in both the app build and the
// unit-test build.

import Foundation

/// A trailing-edge debouncer bound to a serial dispatch queue.
///
/// Lifecycle (correct by construction, not relying on tests): the timer is
/// created lazily on the first `schedule(after:)` and `resume()`d exactly once,
/// then **owned for the Debouncer's lifetime** -- later calls *and* fires reuse
/// the same source via `schedule(deadline:)`, never recreating it. A fire clears
/// the `pending` flag but leaves the source intact. The source is cancelled and
/// dropped in only two places, `cancel()` and `deinit`, so it is never released
/// un-cancelled and resume/cancel always pair one-to-one.
///
/// Not thread-safe: call every method on `queue` (here always `.main`), matching
/// the @MainActor AppRuntime that owns it.
final class Debouncer {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?      // created once, owned until cancel()/deinit
    private var pendingAction: (() -> Void)?
    private var pending = false                  // armed state, separate from source ownership

    init(queue: DispatchQueue) { self.queue = queue }

    /// True while a trailing fire is armed. Distinct from whether the underlying
    /// source exists -- the source outlives individual fires.
    var isPending: Bool { pending }

    /// Re-arm to run `action` once, `delay` after this call, superseding any
    /// earlier pending fire (trailing-edge). The newest `action` wins, so callers
    /// may capture fresh per-call state (e.g. the latest search needle).
    func schedule(after delay: TimeInterval, perform action: @escaping () -> Void) {
        pendingAction = action
        pending = true
        if let timer {
            timer.schedule(deadline: .now() + delay)   // re-arm the SAME live source; no resume()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in          // installed once, never replaced
            guard let self else { return }
            self.pending = false                        // clear armed flag; leave the source intact
            let action = self.pendingAction             // capture before clearing so a
            self.pendingAction = nil                    // re-entrant schedule isn't clobbered
            action?()
        }
        timer.resume()                                  // exactly-once resume; never suspended
        self.timer = timer                              // owned for the Debouncer's lifetime
    }

    /// Disarm any pending fire and retire the underlying source. Safe when idle or
    /// never scheduled. A later `schedule(after:)` builds a fresh source.
    func cancel() {
        timer?.cancel()                                 // cancel before dropping (never drop un-cancelled)
        timer = nil
        pendingAction = nil
        pending = false
    }

    deinit {
        // Non-nil timer is always resumed, so cancel-then-drop is safe (no
        // "release of a suspended object") and avoids leaking the source.
        timer?.cancel()
    }
}
```

Design notes:
- **Single fixed event handler dispatching a stored `pendingAction`** -- not
  re-`setEventHandler` per call. This serves search's changing needle and
  checkpoint's constant action through one API, and never touches the live
  source's handler slot after creation.
- **The fire clears `pending` but leaves the source alone.** The source is
  reused across reschedules *and* across fires, so in steady state exactly one
  timer object exists per Debouncer for its whole life -- zero per-event *and*
  zero per-fire churn. (This is the source-ownership correction: an earlier draft
  nil'd the source inside the handler, mirroring `scheduleCoalescedReconcile`'s
  ivar-nil idiom (its handler nils `coalescedReconcileTimer` without cancelling);
  that drops a resumed source un-cancelled on every fire -- exactly what rule 3
  forbids. We deliberately do **not** mirror that
  idiom. The reconcile timer's own version likely leaks one source per fire (it
  drops a resumed source without `cancel()`); tracked separately, out of scope
  here -- see the doc touch below.)
- **`cancel()` and `deinit` are the only places the source is cancelled and
  dropped**, so resume/cancel pair one-to-one for every source created.
- **Capture-then-clear-then-run** order makes a re-entrant `schedule()` from
  inside the action safe (does not happen today, but is the robust form).

Alternatives considered:
- **`DispatchWorkItem` + `asyncAfter`** (a common debounce idiom): sidesteps the
  suspend/resume crash class, but allocates a fresh work item per call and cannot
  *move* an existing deadline -- each reschedule is a brand-new scheduled item, so
  a high-frequency title-spam burst no longer collapses onto a single armed timer
  the way moving one source's deadline does. The source-reschedule shape keeps
  exactly one armed timer regardless of event rate, which is the property the
  finding is about, so we keep it. (Ghostty's own macOS app, for reference,
  debounces with *neither* pattern: a next-run-loop-tick `DispatchWorkItem` +
  `DispatchQueue.main.async(execute:)` -- not `asyncAfter` -- for tab rename, and
  Combine `.delay(...).switchToLatest()` for the search needle. Neither moves a
  single timer's deadline, which is what our checkpoint case needs.)

## Call-site changes (`app/AppRuntime.swift`)

> Line numbers below are approximate hints only -- `app/AppRuntime.swift` drifts
> a few lines between edits. Anchor every change on the **symbol name + quoted
> content**, not the absolute line.

### Fields (near the other timer ivars)

- Replace `private var checkpointTimer: DispatchSourceTimer?` with
  `private let checkpointDebouncer = Debouncer(queue: .main)`.
- Replace `private var searchDebounceTimers: [PaneId: DispatchSourceTimer] = [:]`
  with `private var searchDebouncers: [PaneId: Debouncer] = [:]`.
- **Keep `checkpointPending` exactly as-is.** It is a separate flag with distinct
  semantics from "timer armed" -- `performLightCheckpoint` clears it and the
  flush reads it independently. Do not fold it into `isPending`.

### `scheduleDebouncedCheckpoint()`

Keep its existing doc comment ("Schedule a light checkpoint after a debounce
delay. Each call resets the timer ... into a single disk write.") unchanged.
Body becomes:

```swift
private func scheduleDebouncedCheckpoint() {
    checkpointPending = true
    checkpointDebouncer.schedule(after: Self.checkpointDebounceInterval) { [weak self] in
        self?.performLightCheckpoint(async: true)
    }
}
```

### `flushPendingCheckpoint()` (`:876-884`)

Swap the teardown to the helper; keep the `checkpointPending` gate verbatim:

```swift
func flushPendingCheckpoint() {
    checkpointDebouncer.cancel()
    if checkpointPending {
        performLightCheckpoint(async: false)
    } else {
        Self.checkpointIOQueue.sync {}
    }
}
```

### `.terminate` command arm (`:583-584`)

Replace `checkpointTimer?.cancel(); checkpointTimer = nil` with
`checkpointDebouncer.cancel()`. (Leave the `enrichedCheckpointTimer` lines.)

### `.sendSearchNeedle` (`:621-645`)

Keep the `delay == 0` immediate-bypass at the call site (it must stay
synchronous and create no timer), including cancelling any pending 1-2 char fire
before an immediate send (the original cancels at the top; preserve that):

```swift
case .sendSearchNeedle(let paneId, let needle):
    // Debounce: immediate for empty or 3+ chars, 300ms for 1-2 chars
    let delay: TimeInterval = (needle.isEmpty || needle.count >= 3) ? 0 : 0.3
    let sendNeedle = { [weak self] in
        guard let self = self,
              let view = self.surfaces[paneId],
              let surface = view.surface else { return }
        let action = "search:\(needle)"
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }
    if delay == 0 {
        searchDebouncers[paneId]?.cancel()   // drop any pending 1-2 char fire
        sendNeedle()                          // synchronous, no timer object
    } else {
        let debouncer = searchDebouncers[paneId] ?? {
            let d = Debouncer(queue: .main)
            searchDebouncers[paneId] = d
            return d
        }()
        debouncer.schedule(after: delay, perform: sendNeedle)
    }
```

The per-pane `Debouncer` is reused across keystrokes (the create-once win;
`cancel()` retires only the underlying source, leaving the object reusable).

### `.sendEndSearch` (`:655-657`) and `tearDownSurface()` (`:822-823`)

Mechanical rename, shape unchanged:
`searchDebouncers[paneId]?.cancel(); searchDebouncers.removeValue(forKey: paneId)`.

### Optional docs touch (recommended)

Add one line to `scheduleCoalescedReconcile`'s doc comment noting it is the
*fixed-window* coalescer and pointing to `Debouncer` for the *trailing-edge*
variant. This resolves the "two debounce patterns" confusion that produced the
original finding, so it does not recur.

Separately, track (do **not** fix here, and do **not** plant a speculative inline
`// TODO`): `scheduleCoalescedReconcile` nils its own timer ivar in the handler
without `cancel()` -- the shape `Debouncer` deliberately avoids (rule 3). Dropping
a *resumed* source without `cancel()` leaves its **event-registration** retain
dangling (Apple: a source "remains attached to its dispatch queue until you cancel
it explicitly"), so it likely leaks one fired source per fire (up to ~13/s under
75ms-coalesce title spam). That registration retain is a *separate* refcount edge
from the suspend-count retain behind the "release of a suspended object" trap --
the source is resumed, so it does not crash; it just never deallocates. **Action:**
open a tracked issue, out of scope for this change, characterizing it as a
*likely* per-fire source leak on the registration edge -- confirm before fixing
(this reasons from the documented model, not an Instruments run); do not leave it
as an inline TODO that lingers as noise-if-wrong or unactioned-bug-if-right.

## Build integration

- **`test.sh`**: add `"$SCRIPT_DIR/app/Debouncer.swift" \` to the `swiftc`
  source list (next to the `TickCoalescer.swift` line, ~`:38`). The app build
  (`swift build` via `Package.swift`) globs `app/` and picks it up
  automatically; only `test.sh` enumerates sources explicitly. The new test file
  is auto-included via the existing `tests/*.swift` glob.

## Tests

`tests/CheckpointTests.swift`'s 31 reducer tests already pin the
`.scheduleCheckpoint` emit contract (the 43 emit sites in `Update.swift`), which
this change does not touch. New coverage lives in `tests/DebouncerTests.swift` (defining `func debouncerTests()`,
registered in `TestRunner.main()` at `tests/TestHarness.swift:25` next to
`tickCoalescerTests()`). Follow the AGENTS.md test-preamble convention
(Intent / Why it exists / Scenario; spec-first, no invented incident).

**Group A -- lifecycle (synchronous, no fire).** Construct on `.main` with a long
delay (e.g. 30s) so nothing fires during the synchronous run; each asserts the
GCD state machine holds without ever waiting. These guard the resume/cancel
balance that rules 1-4 make correct by construction:

1. **cancel before any schedule is a safe no-op** -- guards releasing a
   never-resumed source; `isPending` stays false.
2. **schedule arms, cancel disarms, stays reusable** -- `schedule` ->
   `isPending` true; `cancel` -> false; a second `schedule` re-arms without
   crashing (the Debouncer survives `cancel()` and rebuilds its source).
3. **rapid reschedule re-arms one source without over-resuming** -- three
   back-to-back `schedule` calls then `cancel`; crashes here if a stray second
   `resume()` were ever introduced.

**Group B -- behavior / fire path (the trailing-edge contract).** Group A never
lets the timer fire, and a *near-simultaneous* A-then-B schedule cannot
distinguish trailing-edge from fixed-window (both yield "fires == [B]"). Since
"preserve trailing-edge, do not regress to a fixed-window `guard timer == nil`"
is this plan's central, thrice-stated contract -- and is otherwise *unguarded by
any test even after this lands* -- the fire-path test must **stagger** the two
schedules so the second one *moves* the deadline, and assert the fire lands
relative to the **last** call. Construct the Debouncer on a **private serial
queue** (`DispatchQueue(label:)`) so it fires off the test thread without the main
run loop, and drive *all* Debouncer access (both `schedule` calls, `isPending`,
`cancel`) through `queue.sync { ... }` to honor the "call on its queue" contract.
The test thread blocks on a `DispatchSemaphore`; the fired action records its
wall-clock fire time and signals.

4. **a reschedule moves the deadline -- the single fire lands after the LAST
   schedule, runs only the newest action, and clears pending.** With `D = 0.4s`:
   schedule A (delay `D`), sleep ~`0.5*D`, schedule B (delay `D`), then wait on
   the semaphore (generous 3s timeout) and measure `elapsed` from the **B** call
   to the fire. Assert: it fired (no timeout); `elapsed >= 0.75*D` -- trailing-edge
   fires ~`D` after B, whereas a fixed-window impl would fire ~`0.5*D` *after* B
   (margin ~`0.25*D` ≈ 0.1s each side); fires are exactly `[B]` (catches the
   `guard`-at-top variant that drops the newer action); and
   `queue.sync { d.isPending }` is false afterward. The `elapsed` check catches
   the variant that keeps the action but doesn't move the deadline; the `[B]`
   check catches the variant that drops it -- together they pin trailing-edge.

   This is the first wall-clock-sensitive test in an otherwise deterministic
   harness; the ~0.1s margins match the slack the smoke tests already accept, so
   keep CI timeouts generous. (If maintainers later judge the timing-sensitivity
   not worth it, the by-construction argument -- `schedule` reschedules
   *unconditionally*, so regressing requires deliberately *adding* a guard -- is a
   defensible reason to drop test 4; but that call should be stated here, not left
   silent.)

## Verification

1. **Unit tests:** run `just test`. Expect the 4 new `Debouncer` tests (3
   lifecycle + 1 fire-path) green and all existing checkpoint/search reducer
   tests unchanged/green. Confirm `Debouncer.swift` actually links into the test
   binary (it won't run the tests if the `test.sh` source-list edit was missed).
2. **Compile the app:** `just build`.
3. **Checkpoint debounce smoke test** (run `just build-run`):
   - Drag a split divider continuously ~3s, then stop. Confirm
     `~/Library/.../Recovery/last-light.json` (path from
     `lightCheckpointURL()`, `app/Persistence.swift:238-239`) is written **once
     ~2s after you stop**, not repeatedly during the drag. Poll the mtime with
     `stat -f '%Sm' <file>` (BSD/stock-macOS; `ls --time-style` is GNU-only).
   - Trigger title spam (e.g. `while :; do printf '\033]0;%s\007' $RANDOM; sleep 0.05; done`)
     and confirm a single trailing write ~2s after it stops, and no crash.
   - Background the app mid-debounce: confirm `flushPendingCheckpoint` wrote the
     latest state (no lost 2s window). Quit (`.terminate`): no crash, final
     checkpoint present.
4. **Search debounce smoke test:** open search in a pane; type a 1-2 char needle
   and confirm the highlight applies ~0.3s after you stop typing; type a 3+ char
   needle and confirm it applies immediately; clear the field -> immediate
   clear; close search -> no late highlight fires.
5. **Balance/crash check (debug build):** repeat the bursts in 3-4; absence of an
   `EXC_BAD_INSTRUCTION` from libdispatch confirms the resume/cancel balance. The
   lifecycle unit tests are the primary guard; this is belt-and-suspenders.

## Critical files

- `app/Debouncer.swift` -- **new**; the helper. Mirror `app/TickCoalescer.swift`
  for header/`///` conventions.
- `app/AppRuntime.swift` -- fields (`:63`, `:69`); `scheduleDebouncedCheckpoint`
  (`:841-851`); `flushPendingCheckpoint` (`:876-884`); `.terminate` (`:583-584`);
  `.sendSearchNeedle` (`:621-645`); `.sendEndSearch` (`:655-657`);
  `tearDownSurface` (`:822-823`); optional doc line on `scheduleCoalescedReconcile`
  (`:853-854`).
- `tests/DebouncerTests.swift` -- **new**; 4 tests (3 synchronous lifecycle + 1
  private-queue fire-path behavior test).
- `tests/TestHarness.swift` -- register `debouncerTests()` in `main()` (`:25`).
- `test.sh` -- add `app/Debouncer.swift` to the `swiftc` source list (~`:38`).

## Edge cases swept

- **Re-entrancy:** `performLightCheckpoint` / `sendNeedle` never re-enter
  `schedule`; even if they did, the capture-then-clear handler order is safe.
- **Retain cycle:** AppRuntime strongly owns each Debouncer; the Debouncer's
  event handler captures `[weak self]` (the Debouncer) and the stored action
  closures capture `[weak self]` (the AppRuntime). No strong cycle; the owned
  source is cancelled in the Debouncer's `deinit`.
- **Post-teardown fire:** `.terminate` / `sendEndSearch` / `tearDownSurface`
  cancel before AppRuntime goes away; any stray fire's `[weak self]` no-ops.
- **Thread affinity:** all `@MainActor`, all timers `queue: .main`; the
  helper's "call on `queue`" contract is satisfied.
- **Reconcile coalescer:** independent -- `reconcileDecision` reads
  `coalescedReconcileTimer != nil`, never the checkpoint timer.

## Follow Up

- Open a tracked issue for `app/AppRuntime.swift`'s `scheduleCoalescedReconcile()` to confirm whether clearing `coalescedReconcileTimer` without `cancel()` leaks a fired dispatch source, then fix it separately if confirmed.
