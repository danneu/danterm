# Refactor: centralize the action-dispatch ladder in `GhosttyApp.handleAction`

## Context

`GhosttyApp.handleAction(target:action:)` (app/GhosttyApp.swift:243-513) is a big
switch over libghostty action tags. Thirteen of its cases repeat the identical
ladder: `Self.targetSurface(target)` -> `Self.surfaceBridge(from:)` ->
`DispatchQueue.main.async { [weak ...] ... }`. Each site independently re-derives
the weak-capture discipline that `docs/design/2026-06-09-appkit-lifetime-safety.md`
requires (the ADR written after the 2026-06-09 Cmd-Z SIGSEGV: async hops must
capture `[weak self]`/`[weak view]`, never strong refs, and must resolve
surface/bridge/view values *before* the hop, never read them after).

Today there is no live bug -- all 13 sites get the discipline right. The problem
is that the discipline is copy-pasted 13 times, so the *next* added action can
silently omit it, and one case (MOUSE_SHAPE) already reads the C `action` struct
*after* the hop, technically violating the ADR's resolve-before-dispatch rule.

This refactor extracts the ladder into two helpers so the weak-capture discipline
lives in one audited place instead of being copy-pasted 13 times. It is
behavior-preserving (with one intended, behavior-identical fix to MOUSE_SHAPE).

The strength of the guarantee differs by family, and the plan is honest about it
(Swift does *not* make a cross-hop capture a compile error -- a non-escaping
closure's class-typed parameter is freely capturable by an inner escaping
`DispatchQueue.main.async` closure, verified by `swiftc -typecheck`):

- **Family A (`sendForPane`) is structurally safe.** Its call sites contain no
  async block at all -- they pass a *synchronous, non-escaping* `make` closure
  that only builds a `Msg` from a `PaneId`. The single hop lives entirely inside
  `sendForPane` and captures only the prebuilt `Msg` value plus `[weak self]`. A
  call site therefore *cannot* introduce a bad cross-hop capture, because it never
  writes async code.
- **Family B (`withSurfaceView`) centralizes the common mistake, not all of
  them.** Its `body` does run post-hop (it must, to touch the view on main), so
  the helper guarantees the view is weakly captured and unwrapped -- the one thing
  every site used to hand-roll and could forget -- but it cannot bar a `body` from
  capturing some *other* ref strongly across the hop. That residual is reviewed at
  the call site, not enforced by the compiler.

Outcome: each of the 13 cases collapses to 1-4 lines; the `[weak self]` and
`[weak view]` discipline lives in two reviewed helpers; Family A call sites can no
longer get the async hop wrong, and Family B sites can no longer forget the view
weak-capture.

## The two families

**Family A -- pane -> runtime sends (8 cases).** Resolve `bridge.paneId`, then
`DispatchQueue.main.async { [weak self] in self?.runtime?.send(.someMsg(paneId:, ...)) }`:
RING_BELL, SET_TITLE, PWD, DESKTOP_NOTIFICATION, START_SEARCH, SEARCH_TOTAL,
SEARCH_SELECTED, PROGRESS_REPORT.

**Family B -- view/window manipulation (5 cases).** Resolve `bridge.view`
(a `TerminalView`), then `DispatchQueue.main.async { [weak view = bridge.view] in ... }`:
RENDER, MOUSE_SHAPE, CLOSE_WINDOW, SIZE_LIMIT, INITIAL_SIZE.

**Excluded (left textually unchanged).** CELL_SIZE / SCROLLBAR are deliberately
synchronous (comments at lines 339, 352 explain: avoid scrollbar thumb lag /
already on main). QUIT, RELOAD_CONFIG, CONFIG_CHANGE use `[weak self]` but have
no single-pane/single-view shape (app-vs-surface targets, fan-out). None fit the
helpers; do not touch them.

## Design

All confirmed against the source: `app/GhosttyApp.swift` is compiled same-module
with DanTermCore via the `app/DanTermCore` symlink, so `PaneId`, `Msg`,
`ProgressState`, `TerminalView` are referenceable **by name with no import**
(`let state: ProgressState?` already appears at line 442). `SurfaceBridge`
(app/TerminalView.swift:6) has `weak var view: TerminalView?` and
`var paneId: PaneId?`. `AppRuntime.send(_ msg: Msg)` is app/AppRuntime.swift:231.

### A value-returning resolver + two bridge-hiding helpers

`SurfaceBridge` is never handed to a caller closure. A small value-returning
resolver collapses the existing `targetSurface` + `surfaceBridge(from:)` lookup,
and the two helpers each own their own async hop so call sites only ever supply a
synchronous `make` (Family A) or a post-hop view `body` (Family B). Keeping the
bridge internal to the helpers is what removes the cross-hop-capture footgun from
the 13 call sites -- not any non-escaping trick (Swift does not enforce that;
see Context).

```swift
/// Resolve a target to its SurfaceBridge in one step (targetSurface +
/// surfaceBridge). Returns nil if the target isn't a live surface. Kept private
/// so the bridge stays internal to the dispatch helpers and never crosses an
/// async hop at a call site.
private static func surfaceBridge(forTarget target: ghostty_target_s) -> SurfaceBridge? {
    guard let surface = targetSurface(target) else { return nil }
    return surfaceBridge(from: surface)
}

/// Family A: resolve the target's pane id, build the Msg SYNCHRONOUSLY via `make`,
/// then send the prebuilt message on the main queue with [weak self]. `make` is
/// non-escaping (runs before the hop), so only the finished Msg value and
/// [weak self] cross into the async block -- the bridge/paneId never do, and a
/// call site has no async block in which to get capture wrong. No-op if the
/// target isn't a live surface with a pane id.
private func sendForPane(
    _ target: ghostty_target_s,
    _ make: (PaneId) -> Msg
) {
    guard let bridge = Self.surfaceBridge(forTarget: target),
          let paneId = bridge.paneId else { return }
    let msg = make(paneId)
    DispatchQueue.main.async { [weak self] in
        self?.runtime?.send(msg)
    }
}

/// Family B: resolve the target's TerminalView, then run `body` on the main queue
/// with the view weakly captured and unwrapped (nil view => body is not called).
/// The helper owns the [weak view] capture so no call site hand-rolls it; the
/// caller extracts any `action` payload into a local BEFORE calling this and
/// captures that local in `body`. No `[weak self]` -- Family B touches only the
/// view/window.
private func withSurfaceView(
    _ target: ghostty_target_s,
    _ body: @escaping (TerminalView) -> Void
) {
    guard let bridge = Self.surfaceBridge(forTarget: target) else { return }
    DispatchQueue.main.async { [weak view = bridge.view] in
        guard let view = view else { return }
        body(view)
    }
}
```

`sendForPane` builds the `Msg` synchronously before dispatch; this is equivalent
to today (the only inputs are `paneId` and payload locals the caller already
extracted by value), and it is strictly closer to the ADR's resolve-before-dispatch
rule than building it inside the hop. `withSurfaceView` reads `bridge.view` at
capture time into `[weak view = bridge.view]`, so the async block captures only the
weak view -- never `bridge` itself. Note `surfaceBridge(forTarget:)` overloads the
existing `surfaceBridge(from:)`; the `forTarget:` label keeps the two distinct.

### Per-case conversion shapes

**Family A.** Payload extraction + guards stay in the case body (outside
`sendForPane`); the closure captures the resulting locals by value.

```swift
case GHOSTTY_ACTION_RING_BELL:                       // no payload
    sendForPane(target) { .surfaceBell(paneId: $0) }
    return true

case GHOSTTY_ACTION_SET_TITLE:                       // guard-extract a String
    if let titlePtr = action.action.set_title.title {
        let title = String(cString: titlePtr)
        sendForPane(target) { .surfaceTitle(paneId: $0, title: title) }
    }
    return true

case GHOSTTY_ACTION_SEARCH_TOTAL:                    // Int? sign check preserved
    let raw = action.action.search_total.total
    let total: Int? = raw >= 0 ? Int(raw) : nil
    sendForPane(target) { .ghosttySearchTotal(paneId: $0, total: total) }
    return true
```

PWD mirrors SET_TITLE. DESKTOP_NOTIFICATION extracts title/body then one call.
START_SEARCH keeps its `if let ptr { } else { needle = "" }` nil->"" default
outside the helper. SEARCH_SELECTED mirrors SEARCH_TOTAL.

PROGRESS_REPORT keeps all its branching; both send sites become `sendForPane`:

```swift
case GHOSTTY_ACTION_PROGRESS_REPORT:
    guard progressStyleEnabled else {                // read sync, in case body
        sendForPane(target) { .surfaceProgress(paneId: $0, state: nil) }
        return true
    }
    let raw = action.action.progress_report
    let progress: UInt8? = raw.progress >= 0 ? UInt8(raw.progress) : nil
    let state: ProgressState?
    switch raw.state { /* ... unchanged C-enum -> ProgressState? switch ... */ }
    sendForPane(target) { .surfaceProgress(paneId: $0, state: state) }
    return true
```

**Family B.** `view` arrives non-optional, so `view?.` becomes `view.` and
`guard let window = view?.window` becomes `guard let window = view.window`.
Payloads are extracted synchronously before the call.

```swift
case GHOSTTY_ACTION_RENDER:
    withSurfaceView(target) { $0.needsDisplay = true }
    return true

case GHOSTTY_ACTION_MOUSE_SHAPE:                     // payload now extracted SYNC
    let shape = action.action.mouse_shape
    withSurfaceView(target) { $0.updateMouseCursor(shape) }
    return true

case GHOSTTY_ACTION_SIZE_LIMIT:
    let limits = action.action.size_limit
    withSurfaceView(target) { view in
        guard let window = view.window else { return }
        // ... existing min/max + AppDelegate floor logic, byte-for-byte ...
    }
    return true
```

CLOSE_WINDOW -> `withSurfaceView(target) { $0.window?.close() }`. INITIAL_SIZE
mirrors SIZE_LIMIT (`let size = action.action.initial_size`, then set content
size + center).

## Invariants to preserve exactly

- **Every case still ends in its own `return true`**, even when a guard fails and
  nothing dispatches. Both helpers return `Void`; do NOT try to derive the case's
  return from whether a bridge resolved -- a case must return `true` even when
  `surfaceBridge(forTarget:)` returns nil, because the contract is "I handled this
  tag", not "a surface existed". Keep `return true` literally in each case body.
- **MOUSE_SHAPE change is intended and behavior-identical.** Moving the
  `action.action.mouse_shape` read before the hop aligns it with
  SIZE_LIMIT/INITIAL_SIZE and the ADR's resolve-before-dispatch rule; the same
  enum value crosses the hop either way.
- **No timing/ordering change.** Both helpers dispatch via
  `DispatchQueue.main.async` exactly as before; resolution stays synchronous on
  the callback thread. The only thing that moves is *where* the Family-A `Msg` is
  constructed (now synchronously before the hop, over already-extracted value
  locals, instead of inside the hop) -- send order and payloads are identical.
- `progressStyleEnabled` stays read in the case body (action-callback time), not
  inside `make`. nil->"" (START_SEARCH), `raw >= 0 ? ... : nil` (SEARCH_*),
  `UInt8?` check (PROGRESS) all stay synchronous and captured by value.

## Files

- `app/GhosttyApp.swift` -- the only file changed: add `surfaceBridge(forTarget:)`
  (private static resolver), `sendForPane`, `withSurfaceView` (private methods)
  near the existing `targetSurface`/`surfaceBridge(from:)` statics (lines 232-241);
  rewrite the 13 Family A+B cases; leave the 5 excluded cases textually untouched.
- Reference only (no edits): `app/TerminalView.swift` (`SurfaceBridge`:6,
  `updateMouseCursor`:480), `app/AppRuntime.swift` (`send`:231),
  `lib/DanTermCore/Sources/DanTermCore/Msg.swift` (case labels at 97-101, 148-150),
  `docs/design/2026-06-09-appkit-lifetime-safety.md` (the ADR this aligns with).

## Verification

No unit-test seam exists for `handleAction` (needs GhosttyKit + a live surface;
the `app/` target has no unit test target -- only the `tests-ui/` harness and the
three `lib/` suites). Confidence comes from type-check + harness + manual smoke.

1. **`just build`** -- the primary gate for the *mechanical* correctness of the
   extraction: it catches wrong `Msg` labels, optional/non-optional `view`
   mismatches in Family B bodies, and ordinary type errors. It does NOT catch
   lifetime/async-capture mistakes -- Swift does not make a cross-hop capture a
   compile error (a non-escaping closure's class-typed parameter is freely
   capturable by an inner escaping closure; verified by `swiftc -typecheck`). The
   lifetime invariant is protected by *design*, not the compiler: Family A call
   sites contain no async block (only `sendForPane` does, capturing just the
   prebuilt `Msg` + `[weak self]`), and `withSurfaceView` owns the sole
   `[weak view]` capture. Confidence that no new cross-hop capture slipped in comes
   from the step-4 diff audit.
2. **`just test-ui`** -- regression backstop that nothing else in the app broke.
   First grep `tests-ui/` for `surfaceTitle`/`surfaceProgress`/`ghosttySearch`/
   `surfaceBell` to see which (if any) cases it actually exercises; treat green as
   "wider app intact", not proof these cases work (they're libghostty-driven).
3. **Manual smoke** -- `just build-run`, then from a shell in a pane trigger each
   case and confirm the user-visible effect:

   | Case | Trigger | Expect |
   |---|---|---|
   | RING_BELL | `printf '\a'` | bell indicator/sound |
   | SET_TITLE | `printf '\e]0;hello\a'` | title -> "hello" |
   | PWD | `cd /tmp` (OSC 7 shell) | pane cwd updates |
   | DESKTOP_NOTIFICATION | `printf '\e]9;hi\a'` | macOS notification |
   | START_SEARCH | Cmd-F | search overlay opens |
   | SEARCH_TOTAL/SELECTED | Cmd-F, query w/ multiple hits | "n/m" count updates on next/prev |
   | PROGRESS_REPORT | `printf '\e]9;4;1;50\a'` then `\e]9;4;0\a`; also `;3`/`;2`/`;4`; and re-test with `progress-style = false` in config | meter shows/updates/clears per state; with style off, set shows nothing + prior progress clears |
   | RENDER | any screen output (`ls`) | redraws |
   | MOUSE_SHAPE | hover a TUI requesting pointer/text cursor (vim/pager) | cursor shape changes -- **priority check** (capture semantics changed) |
   | CLOSE_WINDOW | program requesting window close | window closes |
   | SIZE_LIMIT | resize toward extremes | min/max + 600x300 floor enforced |
   | INITIAL_SIZE | window from a size-setting sequence / relaunch | opens at requested content size, centered |

   Priority manual checks: **MOUSE_SHAPE** (only case whose capture changed) and
   **PROGRESS_REPORT** (two send sites; verify both `progress-style` true/false).
4. **Diff audit** -- confirm every `case` still ends in `return true` and the five
   excluded cases (CELL_SIZE, SCROLLBAR, QUIT, RELOAD_CONFIG, CONFIG_CHANGE) are
   textually unchanged.
