# Coalesce the reconcile() sweep for high-frequency surface messages

## Context

`AppRuntime.send(_:)` runs `update(&model, msg)` then `reconcile()`
**unconditionally** on every message (`app/AppRuntime.swift:224-253`).
`reconcile()` is a ~9-pass whole-model sweep that recomputes every projection
(sidebar, containers, toolbars, window chrome, switcher, preferences) and diffs
each against a cache (`app/Reconcile.swift:64-78`).

Three libghostty actions dispatch their own `send()` per escape sequence with no
coalescing: `GHOSTTY_ACTION_SET_TITLE`, `_PWD`, and `PROGRESS_REPORT`
(`app/GhosttyApp.swift:232-254`, `:409-428`). libghostty does **not** throttle
these at the source — `windowTitle` emits a `.set_title` per sequence
(`.ghostty-src/src/termio/stream_handler.zig:996-1025`). So a TUI / clock /
progress bar that rewrites its title or progress at 30-60 Hz drives 30-60 full
reconcile sweeps per second: redundant projection recompute (the sidebar
projection alone is O(tabs x alerts), `app/ModelOperations.swift:1213-1235`) plus
real AppKit churn on the sidebar row, toolbar, and window title at up to 60 Hz.
Ghostty's own macOS app debounces the title precisely because this churn causes
"unpleasant flickering" (`.ghostty-src/.../SurfaceView_AppKit.swift:607-624`,
0.075 s timer).

**Why this approach, not the finding's.** The original finding proposed
coalescing the three *actions* on a per-pane timer "before they hit `send()`,"
modeled on `throttledNotification` (`app/Update.swift:2550-2571`). Investigation
found two problems with that placement:

1. `throttledNotification` is a leading-edge **drop** throttle (`guard
   shouldNotify else { return [] }`). Dropping overflow is correct for
   notifications but wrong for title/pwd/progress — it would apply the *first*
   value of a burst and discard the rest, stranding a stale final title/progress.
2. The GhosttyApp callback layer sits **before** `translateMsg`
   (`app/ModelOperations.swift:1889-1910`), which rewrites
   `__DANTERM_EVT__:`-prefixed titles into real IPC events (`.commandStarted`,
   `.remoteSessionReported`, ...). Coalescing raw titles there would delay/batch
   the IPC event channel — a correctness bug.

The pivot: **coalesce the `reconcile()` sweep, not the action.** Every message
still runs `update()` immediately, so the model is always current and the final
value is never dropped (convergence is structural, not something a throttle must
get right). Only the expensive whole-model view sweep is deferred, via one
global ~75 ms timer, and the decision is made on the **translated** message
inside `send()` — so IPC/title events and every other message still reconcile
inline. The terminal *render* path (`GHOSTTY_ACTION_RENDER` ->
`needsDisplay`, driven by CVDisplayLink) is untouched: this only throttles chrome
projections, never glyph rendering.

## Design

Model the deferred sweep on the existing `scheduleDebouncedCheckpoint`
`DispatchSourceTimer` idiom (`app/AppRuntime.swift:831-841`).

A **single global** timer is correct because `reconcile()` is whole-model and
idempotent: one sweep applies every pane's pending model changes, so there is no
per-pane state to track and nothing to clean up on pane teardown. Bursts across
any panes collapse to one sweep per ~75 ms (~13 Hz total).

The throttle uses "schedule-if-none-pending" semantics (a rate limiter with a
trailing flush), **not** Ghostty's invalidate-and-reschedule debounce. This
matters for progress bars: under *continuous* sub-75 ms updates a pure debounce
would never fire until the stream pauses (progress bar frozen), whereas
schedule-if-none-pending fires steadily every ~75 ms and always reads the latest
model.

The scheduling *decision* (reconcile now / schedule a sweep / coalesce into a
pending sweep) is a pure function, `reconcileDecision`, so the coalescing policy
is unit-tested independent of the `DispatchSourceTimer` glue. `send()` becomes a
thin switch over that decision — the same pure-helper / thin-executor split the
reconcile passes already use (`computeContainerOps`, `computeSidebarRowOps` are
pure and tested; the executors are manual-QA-only).

**Why deferring the sweep is safe.** The coalesced path defers only *cosmetic*
projections (tab title/subtitle, toolbar, window title, progress). Surface
occlusion is not sweep-gated: `syncSurfaceVisibility()` runs as reconcile()'s last
pass but is *also* called directly from `windowDidChangeOcclusionState`
(`app/AppDelegate.swift:691-693`), so a deferred sweep during title spam cannot
strand a surface rendering when it should be hidden. Every structural change
(split / close / focus / search / bell) arrives as a non-coalesced message that
hits `.reconcileNow`, flushing any pending cosmetic sweep first.

### Touch points

**`app/AppRuntime.swift`**

- New properties beside the checkpoint timers (`:60-68`):

  ```swift
  private var coalescedReconcileTimer: DispatchSourceTimer?
  // ~13 Hz; matches Ghostty's title-coalesce interval.
  private static let reconcileCoalesceInterval: TimeInterval = 0.075
  ```

- `send(_:)` (`:235`): wrap the single `reconcile()` call in a branch on the
  **translated** message. Everything else (command-phase split, terminate
  confirm, `appResignedActive` tail) is unchanged.

  ```swift
  let commands = update(&model, translatedMsg)
  for command in commands where !command.isPostReconcile { perform(command) }
  // Pure, tested policy decides; this switch is the thin glue. Threading
  // emitsPostReconcile makes the deferral correct-by-construction: any message
  // that emits a post-reconcile command reconciles inline, so the trailing loop
  // below always runs after a real reconcile() -- no precondition/assert needed.
  let emitsPostReconcile = commands.contains { $0.isPostReconcile }
  switch reconcileDecision(for: translatedMsg,
                           coalescedSweepPending: coalescedReconcileTimer != nil,
                           emitsPostReconcile: emitsPostReconcile) {
  case .reconcileNow:
      // Flush any pending sweep for free (the inline whole-model reconcile()
      // subsumes the deferred one), then reconcile now.
      cancelCoalescedReconcile()
      reconcile()
  case .scheduleCoalesced:
      // Model already updated above; defer the expensive sweep, coalescing bursts.
      scheduleCoalescedReconcile()
  case .coalesceIntoPending:
      // A coalesced sweep is already scheduled; it will read the latest model.
      break
  }
  for command in commands where command.isPostReconcile { perform(command) }
  ```

- New helpers beside `scheduleDebouncedCheckpoint` (`:831`):

  ```swift
  // Defer the whole-model reconcile() sweep, coalescing bursts of high-frequency
  // surface messages (title/pwd/progress) to ~13 Hz. When the timer fires it reads
  // the latest model, so a burst collapses to one sweep. (reconcileDecision already
  // gates this call on "no sweep pending"; the guard is a defensive backstop so the
  // executor stays idempotent.)
  private func scheduleCoalescedReconcile() {
      guard coalescedReconcileTimer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now() + Self.reconcileCoalesceInterval)
      timer.setEventHandler { [weak self] in
          guard let self else { return }
          self.coalescedReconcileTimer = nil
          self.reconcile()
      }
      timer.resume()
      coalescedReconcileTimer = timer
  }

  private func cancelCoalescedReconcile() {
      coalescedReconcileTimer?.cancel()
      coalescedReconcileTimer = nil
  }
  ```

- `.terminate` perform arm (`:576-585`): add `cancelCoalescedReconcile()`
  alongside the existing checkpoint-timer cleanup.

- `commitRestoreSession` (`:1218`): call `cancelCoalescedReconcile()` before its
  direct `reconcile()` (defensive; a stale timer would otherwise fire a harmless
  extra sweep against the freshly restored model).

- No handling needed for `appResignedActive`: that message is not in the coalesce
  set, so its decision is `.reconcileNow` — it flushes the pending sweep inline
  before `flushPendingCheckpoint()`.

**`app/ModelOperations.swift`** — new pure decision helper (AppKit-free,
unit-tested; sits beside `translateMsg`, which it complements — `translateMsg`
normalizes the message, `reconcileDecision` then classifies how to reconcile it):

```swift
/// How send() should drive reconcile() for a (translated) message. Pure so the
/// coalescing policy is unit-tested independent of the DispatchSourceTimer glue.
enum ReconcileDecision: Equatable {
    case reconcileNow         // run reconcile() inline (cancelling any pending sweep)
    case scheduleCoalesced    // no sweep pending: start the coalesce timer
    case coalesceIntoPending  // a sweep is already pending: leave it; it reads the latest model
}

func reconcileDecision(
    for msg: Msg, coalescedSweepPending: Bool, emitsPostReconcile: Bool
) -> ReconcileDecision {
    // Correct-by-construction: a message whose update() emitted a post-reconcile
    // command must reconcile inline (that command needs reconcile() to have run
    // first), so it never takes the deferred path -- no precondition or assert, and
    // a future coalesce opt-in with such a command is safe by default.
    guard msg.coalescesReconcile, !emitsPostReconcile else { return .reconcileNow }
    return coalescedSweepPending ? .coalesceIntoPending : .scheduleCoalesced
}
```

**`app/Msg.swift`** — new extension (mirrors the `Command.isPostReconcile`
pattern at `app/Command.swift:92-120`):

```swift
extension Msg {
    /// Whether this message is *eligible* to defer its reconcile() sweep so bursts
    /// coalesce (see AppRuntime.scheduleCoalescedReconcile). Only the high-frequency
    /// surface projections a TUI can spam at 30-60 Hz: title, pwd, progress.
    /// update() still runs immediately for these, so the model stays current and
    /// the final value is never dropped; only the whole-model view sweep is
    /// throttled. Default false: a message reconciles inline unless it opts in here.
    ///
    /// Eligibility is necessary but not sufficient: send() still reconciles inline
    /// when the message's update() emitted a post-reconcile command, so opting a
    /// message in here is always safe -- at worst it just doesn't coalesce.
    /// Evaluated on the *translated* message, so a __DANTERM_EVT__ title (rewritten
    /// to .commandStarted/.remoteSessionReported/... by translateMsg) falls to the
    /// default and reconciles inline.
    var coalescesReconcile: Bool {
        switch self {
        case .surfaceTitle, .surfaceCwd, .surfaceProgress:
            return true
        default:
            return false
        }
    }
}
```

The update arms for these three (`app/Update.swift:736-763`) are **unchanged**:
they already mutate the model and return only `.scheduleCheckpoint` / `[]`
(verified non-post-reconcile via `Command.isPostReconcile`). `.scheduleCheckpoint`
runs in the pre-reconcile loop as before and is itself debounced
(`scheduleDebouncedCheckpoint`, 2 s), so checkpoint cadence is unaffected.

## Tests

Add to `tests/UpdateGhosttyTests.swift` (the natural home for surface-message
behavior; no `TestRunner` wiring change). All pure — no clock/scheduler injection
needed, since `reconcileDecision` takes `coalescedSweepPending` and
`emitsPostReconcile` as plain `Bool`s.

- **`reconcileDecision` policy — the central regression guard.** A pure 3-axis
  truth table (`coalescesReconcile` x `coalescedSweepPending` x
  `emitsPostReconcile`); pass `emitsPostReconcile: false` unless noted:
  - `.surfaceTitle` / `.surfaceCwd` / `.surfaceProgress` with `pending: false`
    -> `.scheduleCoalesced` (first coalesced message schedules a sweep).
  - the same three with `pending: true` -> `.coalesceIntoPending` (additional
    coalesced messages do not reschedule).
  - any of the three with `emitsPostReconcile: true` -> `.reconcileNow`. This is
    the correct-by-construction safety property: a post-reconcile command forces an
    inline reconcile, so the opt-in path is safe even for a future message — and it
    runs in CI (unlike the deleted `assert`, which `just test` never reached and
    release `-O` strips).
  - a non-coalesced message with `pending: true` -> `.reconcileNow` (flushes the
    pending sweep, reconciles inline). Cover both `.surfaceBell` and
    `.commandStarted` — the latter is the post-translation form of a
    `__DANTERM_EVT__` title, pinning the IPC channel to inline reconcile.
  - any non-coalesced message with `pending: false` -> `.reconcileNow`.
  This folds in the `Msg.coalescesReconcile` classification (the helper calls it),
  so policy regressions in classification, pending-state, or post-reconcile
  handling fail here; the `send()` switch/timer wiring stays manual-QA-only (steps
  3-4 and the optional sweep counter).
- **The three scoped arms stay coalesce-eligible.** For each of `.surfaceTitle` /
  `.surfaceCwd` / `.surfaceProgress` (focused *and* unfocused pane, since the arms
  branch on focus), assert `update(&model, msg)` returns
  `commands.allSatisfy { !$0.isPostReconcile }`. With correct-by-construction this
  is no longer a *correctness* precondition (a post-reconcile command would just
  force inline reconcile) — it guards the *optimization*: if one of these arms
  began emitting a post-reconcile command it would silently stop coalescing.
- **Existing convergence coverage stands.** `testSurfaceTitleFocusedPane`,
  `testSurfacePwdUnfocusedPane`, `testSurfaceProgressSetStoresState` already assert
  the model converges to the latest value and emits the right commands; `update()`
  is untouched, so they still pass and keep guaranteeing the no-dropped-value
  property.

Residual untested glue: the ~6-line `switch` in `send()` mapping each
`ReconcileDecision` to a timer/`reconcile()` call (and reading
`coalescedReconcileTimer != nil`). This stays manual-QA-only, consistent with the
reconcile executors (`tests/ReconcileTests.swift:1-4`); verification steps 3-4 and
the optional sweep counter (step 7) exercise it end-to-end.

## Verification

1. `just test` — `reconcileDecision` policy + invariant tests + existing
   update-arm tests green.
2. `just build-run` — launch the dev app.
3. **Title spam** in a pane: `while true; do printf '\e]0;%s\a' "$RANDOM"; done`.
   Expect the sidebar tab title / window title / toolbar to update smoothly
   without 60 Hz flicker, and to settle on the last value when stopped. (Compare
   against current `DanTerm.app`: visibly flickery.)
4. **Progress spam**: `while true; do for p in 0 25 50 75 100; do printf
   '\e]9;4;1;%s\e\\' $p; sleep 0.02; done; done`. Expect the progress indicator to
   animate at ~13 Hz (not frozen, not flickering).
5. **Render unaffected**: typing/scrolling in a busy pane stays smooth (render is
   the separate CVDisplayLink path).
6. **IPC still prompt** (guards the translateMsg ordering): run a danterm shell
   integration command (CMD_START/CMD_END) or open a remote session; the
   command/remote badge must update immediately, not lag ~75 ms.
7. *Optional, remove after:* a temporary `os_signpost`/log counter in
   `reconcile()` to confirm sweeps drop to ~13/s under the spam loops above.

## Non-goals

- Making `reconcile()` itself cheaper (memoizing projections) — orthogonal and
  unnecessary once sweeps are bounded to ~13 Hz.
- Coalescing any other messages — this change is scoped to title/pwd/progress.
  Adding a future high-frequency message to `coalescesReconcile` is safe by
  construction (one that emits a post-reconcile command reconciles inline anyway),
  but confirming the perf win for it is out of scope here.
