# Coalesce ghostty_app_tick wakeups

## Context

Ghostty's wakeup callback fires once per message pushed to the app mailbox
(`App.Mailbox.push` -> `rt_app.wakeup()`), and can fire from any thread (IO /
renderer). DanTerm's `wakeup_cb` currently schedules a fresh
`DispatchQueue.main.async { ghostty_app_tick(app) }` for **every** wakeup
(`app/GhosttyApp.swift:138-145`), with no coalescing.

`ghostty_app_tick` drains the *entire* mailbox in one pass
(`App.tick` -> `drainMailbox`, a `while mailbox.pop()` loop). `drainMailbox`'s
only early-return is on `App.Message.quit` (`App.zig:258-262`); every other
variant (`.surface_message`, `.redraw_surface`, `.new_window`, `.close`,
`.open_config`) is handled without breaking the loop. The embedded runtime never
enqueues `.quit`, verified by auditing both ends: (a) `.quit` has no
`App.Mailbox.push` site — the in-tree `.quit` constructions are the keybind
*action* enum, not the mailbox message; and (b) the embedded push paths that do
fire carry non-early-returning messages — the renderer's `.redraw_surface`
(`renderer/Thread.zig:503`) and the high-volume IO/surface-thread
`.surface_message` envelopes pushed via the `apprt.surface.Mailbox.push` wrapper
(`apprt/surface.zig:140-154`, wired to the app mailbox by `Surface.surfaceMailbox()`
at `Surface.zig:832`). So in v1.3.0 a tick always fully drains. When N wakeups
stack up before the main run loop turns, the first scheduled tick drains all N
messages and the remaining N-1 ticks run against an empty mailbox — bounded,
cheap no-ops, but real main-queue churn (one heap-allocated block + one empty
drain each) on the latency-sensitive path under heavy terminal output.

This is **not a bug** — DanTerm's `wakeup_cb` follows the same non-coalescing
shape as upstream Ghostty's own `wakeup`
(`.ghostty-src/macos/Sources/Ghostty/Ghostty.App.swift:423-431`): schedule one
main-queue tick per wakeup. Upstream's author explicitly judged coalescing
immaterial. It is a **low-severity,
low-effort** hardening that matches cmux's coalescing
(`.refs/cmux/Sources/GhosttyTerminalView.swift:3189-3217`): collapse redundant
wakeups so at most one tick is scheduled per main-loop turn, trimming main-queue
churn when the terminal is busy.

Outcome: at most one `ghostty_app_tick` scheduled per main-loop turn, no lost
wakeups for the reachable full-drain behavior (see **Assumption** below), and the
coalescing logic covered by unit tests.

**Assumption (documented, not defended in code):** the coalescer relies on
`ghostty_app_tick` fully draining the mailbox. This holds as long as no embedded
`App.Mailbox.push` path can enqueue a message that makes `drainMailbox` return
early — today the only early-returning message is `.quit`, and no push path
produces it (per the both-ends audit above). If a future ghostty upgrade adds an
early-returning message, or a push path that enqueues one (e.g. starts enqueuing
`.quit`), a wakeup whose message was pushed *before* such a partial drain — and
therefore coalesced away — could be stranded until the next unrelated wakeup. This
is a latent, currently-unreachable risk; we document it (code comment + the
ghostty-upgrade checklist) rather than add follow-up-tick machinery to guard dead
code. Revisit if the assumption breaks.

## Approach

Extract the coalescing state machine into a pure, dual-compiled helper (the
`ScrollbarMath.swift` seam pattern) so it is unit-testable — `GhosttyApp.swift`
imports Cocoa/GhosttyKit and is excluded from the pure test build. `GhosttyApp`
holds the helper and routes the wakeup through it; the helper itself owns no
Cocoa/GhosttyKit/dispatch dependency.

### 1. New pure helper: `app/TickCoalescer.swift`

A small `final class` guarding a `Bool` with an `NSLock` (house style — matches
`app/IpcConnection.swift:41,46` which is also `@unchecked Sendable` and already
compiles in the test build). Mirror `ScrollbarMath.swift`'s top comment noting it
has no AppKit/GhosttyKit dependency so it compiles in both builds.

The coalescer **owns the tick lifecycle**: it exposes `runTick(_ drain:)` rather
than a bare `beginTick()`, so the correctness-critical "clear the flag before
draining" ordering lives inside the tested unit and cannot be misplaced by the
(untestable) `GhosttyApp` caller.

```swift
final class TickCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    /// Call on every wakeup (any thread). Returns true if the caller should
    /// enqueue a runTick on the main queue; false if a tick is already pending
    /// — coalesce, do nothing.
    func noteWakeup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if scheduled { return false }
        scheduled = true
        return true
    }

    /// Call on the main queue to run one tick. Releases the pending slot BEFORE
    /// running `drain`, so a wakeup arriving during the drain re-arms via
    /// noteWakeup() and schedules a fresh tick — no lost wakeups.
    ///
    /// Assumes `drain` (ghostty_app_tick) fully drains the app mailbox. True for
    /// the embedded runtime as of Ghostty v1.3.0: drainMailbox's only early-return
    /// is on App.Message.quit, and no embedded App.Mailbox.push path enqueues it
    /// (surface IO and renderer pushes carry .surface_message / .redraw_surface).
    /// If a future upgrade adds an early-returning message or a push path that
    /// enqueues one, a coalesced wakeup pushed before such a drain could be
    /// stranded — revisit then (see docs/upgrading-ghostty.md).
    func runTick(_ drain: () -> Void) {
        lock.lock(); scheduled = false; lock.unlock()
        drain()
    }
}
```

**Correctness invariant (non-negotiable):** `runTick` clears the flag *before*
calling `drain`. Clearing after the drain would drop a wakeup that arrives during
the drain (its `noteWakeup()` would coalesce against the still-set flag, then the
flag clears, losing it), hanging the UI until the next unrelated wakeup. Because
`runTick` owns both the clear and the `drain` call, this ordering is exercised by
test #3 below — a reordered "drain then clear" implementation makes that test red.

### 2. Wire into `app/GhosttyApp.swift`

Add a stored property on the `GhosttyApp` class:

```swift
let tickCoalescer = TickCoalescer()
```

Replace the `wakeup_cb` body (`app/GhosttyApp.swift:138-145`):

```swift
wakeup_cb: { userdata in
    guard let userdata = userdata else { return }
    let ghosttyApp = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
    guard ghosttyApp.tickCoalescer.noteWakeup() else { return }
    DispatchQueue.main.async {
        ghosttyApp.tickCoalescer.runTick {
            guard let app = ghosttyApp.app else { return }
            ghostty_app_tick(app)
        }
    }
},
```

If `app` is nil during teardown, `runTick` still clears the flag before the drain
closure returns early, so later wakeups re-arm correctly. No `Package.swift`
change — the app target globs `app/*.swift` (`path: "app"`), so the new file is
picked up automatically.

**Scope guard:** Touch only the wakeup path. The sibling
`DispatchQueue.main.async` callbacks in this file (`action_cb` handlers like
RENDER/SET_TITLE/PWD, and `close_surface_cb`) each carry distinct per-event
payloads and must **not** be coalesced.

### 3. Test wiring

- New file `tests/TickCoalescerTests.swift` with `func tickCoalescerTests()`,
  using the custom harness (`test("...") { try expect(...) }`; not XCTest).
- Register `tickCoalescerTests()` in `TestRunner.main()`
  (`tests/TestHarness.swift:6-40`).
- Add `"$SCRIPT_DIR/app/TickCoalescer.swift" \` to the explicit app-file list in
  `test.sh:23-38`. (`tests/*.swift` is already globbed at `test.sh:39`, so the
  test file needs no script edit.)

Tests (behavioral, structure-insensitive — assert only on the public return
contract):

1. **first wakeup schedules** — fresh coalescer: `noteWakeup() == true`.
2. **extra wakeups coalesce** — after one `true`, further `noteWakeup()` calls
   return `false`.
3. **runTick clears before draining** — after a `noteWakeup()`, call `runTick`
   with a drain closure that itself calls `noteWakeup()` and captures the result;
   assert that inner call returned `true`. Proves the flag is cleared before the
   drain (a wakeup mid-drain re-arms); a "drain then clear" reordering makes the
   inner call return `false` and the test fails. *Ordering guard — the F2 fix.*
4. **clean tick releases the slot** — after `noteWakeup()` then `runTick { }`
   (no mid-drain wakeup), the next `noteWakeup() == true`.
5. **concurrent: exactly one schedules** — hammer `noteWakeup()` via
   `DispatchQueue.concurrentPerform(iterations: 1000)`, counting `true` returns
   with an `NSLock`-guarded counter; assert exactly one. Proves the lock makes
   check-and-set atomic.

## TDD sequence (per repo practice: red for the expected reason, then green)

1. Write `tests/TickCoalescerTests.swift` (the five cases above); register
   `tickCoalescerTests()` in the harness; add `app/TickCoalescer.swift` to
   `test.sh`.
2. Create `app/TickCoalescer.swift` with a correct `noteWakeup()` but a
   deliberately wrong `runTick` that drains *then* clears
   (`drain(); lock.lock(); scheduled = false; lock.unlock()`).
3. `just test` -> test #3 (ordering guard) **fails** for the expected reason (the
   mid-drain `noteWakeup()` coalesces against the still-set flag); the others pass.
4. Fix `runTick` to clear *before* `drain()`.
5. `just test` -> all green.
6. Wire `GhosttyApp.swift` (property + `wakeup_cb` rewrite).

## Verification

- `just test` — all suites pass, including the five new `TickCoalescer` cases.
- `just build` — confirms `GhosttyApp.swift` + new file compile in the app target
  (Cocoa/GhosttyKit present).
- `just build-run`, then exercise a busy surface (e.g. `yes`, or a large
  `cat`/build log) and confirm output renders, scrolls, and input stays
  responsive — i.e. coalescing did not drop wakeups or stall rendering. The
  ordering-guard test (#3) is the automated guard against the lost-wakeup failure
  mode; this manual check confirms end-to-end behavior under load.

## Files

- `app/TickCoalescer.swift` — new pure helper.
- `tests/TickCoalescerTests.swift` — new test suite.
- `app/GhosttyApp.swift` — add `tickCoalescer` property; rewrite `wakeup_cb`
  (lines 138-145).
- `tests/TestHarness.swift` — register `tickCoalescerTests()`.
- `test.sh` — add `app/TickCoalescer.swift` to the test-build file list.
- `docs/upgrading-ghostty.md` — add a checklist item under **Steps** (near the
  step 1 "Check Ghostty release notes" item): re-audit `App.drainMailbox`'s
  early-returns and every embedded `App.Mailbox.push` path (including the
  `.surface_message` wrapper in `apprt/surface.zig`), and verify none can enqueue
  an early-returning `App.Message` such as `.quit` — `TickCoalescer` assumes
  `ghostty_app_tick` fully drains the mailbox.
