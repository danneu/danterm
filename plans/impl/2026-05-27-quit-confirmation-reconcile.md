# Migrate the quit-confirmation panel into a reconcile pass

## Context

DanTerm finished a migration that replaced hand-rolled imperative view-sync in
`AppRuntime.send()` with pure `desired*` projections diffed by `reconcile*`
passes (eight `refactor(reconcile):` commits; see `app/Reconcile.swift:1-14`).
One imperative line survived it:

```swift
// AppRuntime.swift:256-258, tail of send() after the reconcile-decision block
if model.pendingConfirmation == .terminate {
    quitConfirmationPanel?.configure(paneCount: model.allPaneIds.count)
}
```

It keeps the non-modal quit panel's "close N sessions" copy live as panes close
underneath it. It is the last per-dispatch imperative view-sync bolted onto the
dispatch loop, and it splits the panel's lifecycle three ways: **show** via the
`.showTerminateConfirmation` command (`AppRuntime.swift:552-558`), **refresh**
via this line, and **hide** via the panel's own button actions plus teardown.

This plan collapses all three into one `reconcileQuitConfirmation` pass on the
proven single-optional template that `reconcileSwitcher`
(`app/Reconcile.swift:268-281`) and `reconcilePreferencesPanel`
(`:286-293`) already use: a pure `desiredQuitConfirmation(in:)` projection, a
`caches.quitConfirmation` field, and a pass that diffs them. Outcome: the panel
is driven entirely by `model.pendingConfirmation`, the `.showTerminateConfirmation`
command is deleted, and `send()` has no imperative view-sync left.

## The pivot: why this is NOT a verbatim `reconcileSwitcher` copy

The switcher pass re-centers and re-`orderFront`s on *every* non-nil change, and
uses non-activating `orderFront` (it must never steal first responder from the
focused terminal). The quit panel needs the opposite on both counts, so the pass
body deliberately diverges -- this divergence is the whole point of doing it
"ideally" rather than copy-pasting the template:

1. **Use `makeKeyAndOrderFront`, not `orderFront`.** The panel's Cancel/Quit
   buttons rely on Esc/Enter key equivalents (`QuitConfirmationPanel.swift:42,46`),
   so the panel must take key focus. A verbatim switcher copy would use
   `orderFront` and silently break Esc/Enter.
2. **Center + take key only on the appear transition (nil -> non-nil).** Today
   `center` + `makeKeyAndOrderFront` fire exactly once per quit request; later
   dispatches only `configure` the label. The panel is non-modal and `.titled`
   (draggable), and the whole point is that you keep closing panes under it.
   Re-centering on every paneCount change would teleport a dragged panel back to
   center; re-`makeKeyAndOrderFront` would re-steal key focus from the terminal
   you just typed `exit` into. So the heavy show runs only when the panel
   appears; a paneCount change while open re-`configure`s only.

Document both divergences in the pass doc-comment so a future reader does not
"fix" it back to match the switcher.

## Design

### 1. Pure projection (`app/ModelOperations.swift`, next to `desiredSwitcher`, currently :2049-2060)

```swift
struct QuitConfirmationProjection: Equatable { let paneCount: Int }

func desiredQuitConfirmation(in model: AppModel) -> QuitConfirmationProjection? {
  guard model.pendingConfirmation == .terminate else { return nil }
  return QuitConfirmationProjection(paneCount: model.allPaneIds.count)
}
```

`.closeTab` (the shared `PendingConfirmation` slot, `Model.swift:176-179`) must
project `nil` -- close-tab confirmation is a separate modal `NSAlert` system and
is not touched by this change.

### 2. Cache field (`app/Reconcile.swift:54`, in `ReconcilerCaches`)

```swift
// Single-optional quit-confirmation cache. Unlike `switcher`, the panel is
// destroyed (not persisted) on teardown, so nil after ReconcilerCaches() re-init
// correctly means "no panel, nothing shown".
var quitConfirmation: QuitConfirmationProjection? = nil
```

`tearDownCurrentSession` already does `quitConfirmationPanel?.orderOut(nil);
quitConfirmationPanel = nil` (currently `AppRuntime.swift:1211-1212`) and resets
`caches = ReconcilerCaches()` (`:1230`), so panel + cache reset coherently.

The cache reset is *not* itself the safety net: it zeroes `caches.quitConfirmation`
to nil, so a restored model that somehow carried `.terminate` would face a nil
cache against a non-nil projection -- the **appear path** -- and would pop the
panel on launch. The sole guard is that `pendingConfirmation` is ephemeral and
never serialized: it is declared at `Model.swift:195` but has no counterpart in
`AppModelSnapshot` (`:289`), so the post-restore projection is nil and the pass
no-ops. That premise is load-bearing, so the test plan pins it (see Test changes).

### 3. The pass (`app/Reconcile.swift`, added near `reconcileSwitcher`)

```swift
func reconcileQuitConfirmation() {
    let new = desiredQuitConfirmation(in: model)
    guard caches.quitConfirmation != new else { return }
    let wasShowing = caches.quitConfirmation != nil   // read BEFORE the write below
    if let proj = new {
        if quitConfirmationPanel == nil {
            quitConfirmationPanel = QuitConfirmationPanel(runtime: self)
        }
        quitConfirmationPanel?.configure(paneCount: proj.paneCount)
        if !wasShowing {                              // appear transition only
            quitConfirmationPanel?.center(on: window)
            quitConfirmationPanel?.makeKeyAndOrderFront(nil)
        }
    } else {
        quitConfirmationPanel?.orderOut(nil)
    }
    caches.quitConfirmation = new
}
```

Lazy-create inside the pass (the old perform arm's behavior). Unlike the switcher
there is no first-frame-latency reason to create it eagerly -- quit confirmation
is infrequent. Add the call inside `reconcile()` (at `app/Reconcile.swift:64`; its
late-pass list `reconcileSwitcher()` / `reconcilePreferencesPanel()` is currently
`:75-76`), next to those two -- no surface/container dependency, so placement among
the late passes is fine.

**Access level (required to compile):** `quitConfirmationPanel` is currently
`private` (`AppRuntime.swift:47`). This pass lives in `Reconcile.swift` -- a
cross-file `AppRuntime` extension -- which cannot see a `private` member, so drop
`private` to internal, exactly as its immediate neighbors `preferencesPanel`
(:46) and `switcherPanel` (:49) already are. Add the matching comment they carry:
`// internal (not private): the cross-file reconcileQuitConfirmation extension reads it.`

**Interaction with reconcile coalescing.** Since `perf(runtime): coalesce surface
reconcile sweeps`, `reconcile()` runs inline only when `reconcileDecision`
(`ModelOperations.swift:1894`) returns `.reconcileNow` -- which it does for every
message except the three surface-metadata ones that opt into coalescing
(`Msg.swift:192-199`), and even those reconcile now if they emit a post-reconcile
command. Moving the refresh into the pass is safe: paneCount changes only via pane
add/remove (`closePane`, `surfaceClosed`, `splitPane`, `createTab`, `deleteGroup`),
all non-coalescing, so the "close N sessions" copy still updates inline. A deferred
surface-metadata sweep never changes paneCount, so the pass can only no-op on it --
identical to today's redundant per-dispatch `configure`.

### 4. `emitTerminateConfirmation` sets the flag and emits nothing

`app/ModelOperations.swift:551-555` -- keep the `guard pendingConfirmation == nil`,
set `.terminate`, and `return []`. The reconcile pass is now the sole driver
(matching how the MRU cycle handlers set `mruCycle` and emit no show/hide). The
four callers each already `return emitTerminateConfirmation(&model)` and need no
change: `.closeTab` (`Update.swift:140`), `.closePane` (`:219`), `.requestQuit`
(`:884`), `.deleteGroup` (`:1003`).

### 5. Deletions

Anchor these to the named symbols, not raw line numbers: the
`perf(runtime): coalesce surface reconcile sweeps` commit shifted every
`AppRuntime.swift` number since this plan's first draft. Numbers below are
current-tree hints; confirm with the greps before cutting.

- The refresh line in `send()`: `if model.pendingConfirmation == .terminate {
  quitConfirmationPanel?.configure(...) }` (currently `AppRuntime.swift:256-258`).
- The `.showTerminateConfirmation` perform arm (currently `:552-558`; its
  lazy-create moves into the pass). It now sits directly below the
  `.showCloseTabsConfirmation` arm (`:530`) -- do not cut the wrong one; land it
  with `rg -n 'case .showTerminateConfirmation' app/AppRuntime.swift`.
- In `app/Command.swift`: the `case showTerminateConfirmation(paneCount: Int)`
  declaration and its entry in the exhaustive `isPostReconcile` switch (no
  `default`, so removal is required to compile). Find both with
  `rg -n showTerminateConfirmation app/Command.swift`.

Backstop: after the edits, `rg -rn showTerminateConfirmation app/ tests/` must
return nothing -- the migrated tests assert `pendingConfirmation`, not the command.

### 6. Consolidation finish (`app/QuitConfirmationPanel.swift`)

Delete the imperative `orderOut(nil)` from `confirmQuit`
(`QuitConfirmationPanel.swift:106`) and `cancelQuit` (:111); the nil projection now
owns hide. `.confirmTerminate` / `.cancelTerminate` are non-coalescing, so
`reconcileDecision` returns `.reconcileNow` and `reconcile()` runs inline in their
`send()` (only the coalescing exceptions defer) -- the panel hides in the same
runloop turn as the click, no visible lag (the trade-off the switcher migration
accepted). Keep `windowShouldClose` (:98-101) sending `.cancelTerminate` and
returning `true` (AppKit closes the window; the reconcile `orderOut` is then a
no-op). Keep `configure` / `center` -- the pass calls them.

## Test changes

We practice TDD; these are pure-model/projection tests (no Cocoa). The pure
`desiredQuitConfirmation` projection carries the behavioral coverage; the thin
AppKit pass is manual-QA-only (consistent with `reconcileSwitcher` /
`reconcilePreferencesPanel`, which have no pass-level tests).

**New projection test** -- `tests/ModelOperationsTests.swift`, after the
`desiredSwitcher` test (locate by name; ~:935 today), mirroring its disappearance-net shape. Asserts:
nil when nothing pending; nil for `.closeTab` (the shared-slot guard); non-nil
`QuitConfirmationProjection(paneCount: 1)` for a single-pane `.terminate`;
`paneCount: 3` for a 3-pane model (`makeMruModel(tabCount: 3)`); nil once
cleared. This recovers the count==1 / count==3 coverage the deleted command
assertions carried, and adds the `.closeTab`-ignored property.

**Live-decrement regression test** -- same file. The feature's whole premise is
that the count decrements as panes close *under the open panel*; the static
projection test above never exercises that, because it sets `pendingConfirmation`
by hand rather than driving the `closePane` path. Add a test that:

- builds a two-pane tab: `createTab(&model)` then
  `update(&model, .splitPane(direction: .horizontal))` (now `allPaneIds.count == 2`);
- sets `model.pendingConfirmation = .terminate`, asserts
  `desiredQuitConfirmation(in: model)?.paneCount == 2`;
- closes a non-last pane:
  `update(&model, .closePane(paneId: model.groups[0].tabs[0].focusedPaneId))`
  (the `focusedPaneId` + `.closePane` convention used throughout `UpdateTabTests`);
- asserts the pane is gone (`allPaneIds.count == 1`), `pendingConfirmation` is
  still `.terminate` (the non-last `closePane` path at `Update.swift:222-225`
  does not touch it), and `desiredQuitConfirmation(in: model)?.paneCount == 1`.

A regression that made a non-last `closePane` a no-op while terminating, or that
cleared `pendingConfirmation` on pane close, fails here -- the static count tests
would not catch either.

**Ephemeral-field round-trip test** -- `tests/SnapshotTests.swift`. This change
makes non-serialization of `pendingConfirmation` the sole guard against a spurious
panel on launch (Design section 2), and no existing snapshot test pins it. Mirror
the `loadValidatedInitFile returns validated restore` test (`SnapshotTests.swift:128`):
build a model, set `pendingConfirmation = .terminate`, round-trip it
(`toInitFile(model)` -> `JSONEncoder().encode` -> `loadValidatedInitFile(from:)`),
and assert the reconstructed model's `pendingConfirmation == nil`. Fails the day a
future change adds the field to `AppModelSnapshot`.

**Migrate existing assertions.** Because all four producers `return
emitTerminateConfirmation(&model)` (now `[]`), every cited command list becomes
empty. The transform:

- `expectEqual(commands.count, 1)` + a `hasEffect { .showTerminateConfirmation }`
  / `if case .showTerminateConfirmation = commands[0]` block
  -> `expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")`.
- Lean on the `model.pendingConfirmation == .terminate` assertion (already present
  in most) as the behavioral net; **add** it where absent.

Per-test specifics:

- `tests/UpdateLifecycleTests.swift`:
  - `testRequestQuitWithOnePane`, `testRequestQuitWithMultiplePanes`,
    `testRequestQuitSetsPending` -- replace the count+command block with
    `commands.isEmpty`; keep the existing pending assertion.
  - `testRequestQuitAgainAfterCancel` -- replace with `commands.isEmpty` and
    **add** `pendingConfirmation == .terminate` (currently absent; it is now the
    only signal the second request re-armed the panel).
  - `testRequestQuitWhileCloseTabPendingIsNoOp` -- **delete** the negative
    `hasEffect { .showTerminateConfirmation }` block (won't compile once the case
    is gone); keep the `commands.count == 0` assertion, which already proves it.
  - `testRequestQuitWhileQuitPendingIsNoOp` -- unaffected (no command reference);
    leave as is.
- `tests/UpdateTabTests.swift`:
  - `testCloseLastPaneShowsConfirmation`, `testCloseLastTabShowsConfirmation` --
    replace with `commands.isEmpty`; keep pending assertion.
  - `testConfirmCloseTabLastMultiPaneRoutesToTerminate` -- replace with
    `commands.isEmpty`; keep the `pendingConfirmation == .terminate` transition
    assertion and the `surfacesToTearDown(...).isEmpty` check (the regression net
    for the closeTab -> terminate routing in one `update()`).
  - `testRequestCloseTabSinglePaneLastTabShowsTerminateConfirmation` -- delete the
    `hasEffect` block; keep the pending assertion (now the sole signal).
- `tests/UpdateGhosttyTests.swift`:
  - `testSurfaceClosed` -- replace the `hasEffect` block with `commands.isEmpty`
    and **add** `pendingConfirmation == .terminate` (currently absent).

After editing, grep `tests/` for any remaining `showTerminateConfirmation` to
confirm none survive (the deleted `Command` case turns leftovers into compile
errors).

## Critical files

- `app/ModelOperations.swift` -- projection + `emitTerminateConfirmation`.
- `app/Reconcile.swift` -- cache field + pass + `reconcile()` wiring.
- `app/AppRuntime.swift` -- delete refresh line + perform arm; make
  `quitConfirmationPanel` internal (:47).
- `app/Command.swift` -- delete command case + `isPostReconcile` entry.
- `app/QuitConfirmationPanel.swift` -- drop in-view `orderOut`.
- `tests/ModelOperationsTests.swift`, `tests/UpdateLifecycleTests.swift`,
  `tests/UpdateTabTests.swift`, `tests/UpdateGhosttyTests.swift`,
  `tests/SnapshotTests.swift`.

## Verification

- `just test` -- all suites green; confirm the four test files compile (no
  stray `.showTerminateConfirmation` reference remains).
- `just build-run` smoke check:
  1. Open 3+ panes, trigger quit (Cmd-Q / `requestQuit`). Panel appears centered
     over the window and takes key (Esc/Enter work on its buttons).
  2. With the panel open, close a pane underneath it (Cmd-W in a terminal). The
     "close N sessions" copy decrements **without** the panel re-centering and
     **without** key focus being yanked from the terminal -- the proof of the
     appear-only-center divergence.
  3. Drag the panel off-center, close another pane -- it stays where dragged
     (copy still updates).
  4. Cancel -- panel hides, app keeps running, terminals usable.
  5. Trigger quit again, click Quit -- app terminates.
  6. Trigger quit, click the panel's red close button -- treated as cancel, app
     keeps running.
