# Plan: Make `model.preferencesDraft` the single source of truth for preferences-panel visibility

> Citations are by **symbol + file**, not line numbers: the reconcile migration is
> actively moving the tree and this plan's line numbers have gone stale three times.
> Commit SHAs and test names are stable; grep by symbol for everything else.

## Context

DanTerm is mid-migration toward "derive all AppKit/view state from the model via
reconcile passes" (migration-template comment at the top of `app/Reconcile.swift`; a long
run of sequential `refactor(reconcile)` commits). Two panels are already migrated and
serve as templates:

- `reconcileSwitcher` (`app/Reconcile.swift`) -- the MRU switcher, a *non-activating*
  overlay: nil projection -> `orderOut`, non-nil -> apply + `orderFront`.
- `reconcileQuitConfirmation` (`app/Reconcile.swift`, landed in `f668a06`) -- a
  *key-taking panel*, the **near-exact precedent** for preferences: model-gated on
  `desiredQuitConfirmation`, lazy-creates its panel in the show branch, calls
  `makeKeyAndOrderFront` **only on the nil -> non-nil transition** (later refreshes
  reconfigure content without stealing key focus), and `orderOut`s on hide.

The preferences panel was migrated **content-only** (`5d09514`). Today its visibility is
still out-of-model:

- `reconcilePreferencesPanel` (`app/Reconcile.swift`) gates on the runtime handle
  (`preferencesPanel == nil`), not the model, and only ever calls `apply()` -- it never
  shows or hides the panel.
- Show happens via an imperative `makeKeyAndOrderFront` in `showPreferencesPanel`
  (`app/AppRuntime.swift`); hide happens via scattered `close()` calls in
  `PreferencesPanel.cancelPreferences`, the `windowShouldClose` red-X path, and
  `tearDownCurrentSession`.

So `model.preferencesDraft` drives the panel's *content* but not its *visibility* -- two
sources of truth kept consistent only by the convention that opening always both sets the
draft and shows the panel. `desiredPreferencesPanel` already returns nil on a nil draft,
so the two rarely diverge today, but the divergence is structurally possible -- and
preferences is the panel closest to done: it already has a projection + cache, and
`reconcileQuitConfirmation` is now a near-identical, just-landed precedent to copy.

**Outcome:** make the draft the single source of truth for visibility too -- reconcile
owns create + show + hide + content from the model, exactly as `reconcileQuitConfirmation`
does, and `showPreferencesPanel` keeps only the impure live-config read, the dispatch, and
a re-focus raise.

This is preferences-only. The remaining out-of-model panels -- `alertsPopover` and
`themeBrowserView`, both still without a projection -- are a separate, larger effort,
explicitly out of scope. (`quitConfirmationPanel`, previously grouped with them, was
migrated in `f668a06` and is now the reference template above.)

## Control-flow facts this plan relies on (verified against HEAD)

- `send(msg)` (`AppRuntime.send`) runs `update` -> pre-reconcile commands -> a
  reconcile-scheduling decision -> post-reconcile commands. The decision
  (`reconcileDecision`, `app/ModelOperations.swift`) returns `.reconcileNow` -- a
  **synchronous** `reconcile()` -- for every message *except* the three high-frequency
  surface-metadata messages that opt into `coalescesReconcile`
  (`.surfaceTitle`/`.surfaceCwd`/`.surfaceProgress`; `Msg.coalescesReconcile` in
  `app/Msg.swift`), which defer onto a coalescing timer. The prefs messages
  (`.preferencesOpened`/`.preferencesClosed`/`.prefSet*`) are **not** coalescing, so they
  reconcile inline: `send(.preferencesOpened)` runs a full reconcile pass mid-call before
  any trailing imperative line, and `send(.preferencesClosed)` hides the panel
  synchronously. This inline-ness is load-bearing for the new hide path (§3) and is pinned
  by a test (see Tests) so a future change can't silently make a prefs message coalesce and
  leave the panel on-screen.
- Reconcile hides with `orderOut` (matching `reconcileQuitConfirmation` and
  `reconcileSwitcher`), never `close()`. So on the red-X path (§3) reconcile orders the
  panel out *inside* `windowShouldClose`, and AppKit performs the actual window close
  *after* the delegate returns `true` -- there is no `close()`-inside-`windowShouldClose`
  reentrancy.
- `.preferencesOpened` (`Update.update`, `app/Update.swift`) sets the draft only on the
  closed->open transition (idempotent); `.preferencesClosed` nils both `preferencesDraft`
  and `committedGhosttyPrefs`. No other handler creates the draft. `.prefSave` does not nil
  the draft (panel stays open after Save).
- `preferencesDraft` / `committedGhosttyPrefs` are ephemeral (`AppModel`, `app/Model.swift`)
  -- absent from every snapshot/Codable path. A restore always yields a nil draft.
- `PreferencesPanel`: style `[.titled, .closable, .utilityWindow]`,
  `isReleasedWhenClosed = false` (handle survives hide/close), `level = .normal`
  (occludable by the main window -> re-raise is a real need).

## The change

### 1. `reconcilePreferencesPanel()` -- own create/show/hide/content from the model

Replace the handle-gated, apply-only body with a model-gated one that mirrors
`reconcileQuitConfirmation` almost verbatim. Structurally -- model gate, `wasOpen`
transition detection, lazy creation in the show branch, `makeKeyAndOrderFront` gated to
the open transition, `orderOut` on hide -- it is identical; the only content difference is
`apply(projection)` (the full form render) where the quit panel calls
`configure(paneCount:)`.

```swift
/// Create/show, render, or hide the preferences panel from one diffed
/// `PreferencesPanelProjection?`. Mirrors reconcileQuitConfirmation (the key-taking-panel
/// precedent): nil (no `model.preferencesDraft`) orders the panel out; a non-nil
/// projection lazily creates the panel on first need, renders the form, and brings it
/// key+front -- but only on the open transition, so a per-keystroke projection change
/// re-renders without re-keying. The draft is the single source of truth for visibility;
/// show/hide are no longer imperative side calls. makeKeyAndOrderFront (not orderFront)
/// because the form's text fields must take first responder.
func reconcilePreferencesPanel() {
    let new = desiredPreferencesPanel(in: model)
    guard caches.preferencesPanel != new else { return }
    let wasOpen = caches.preferencesPanel != nil   // transition detection via the cache
    if let proj = new {
        if preferencesPanel == nil {
            preferencesPanel = PreferencesPanel(runtime: self)
        }
        preferencesPanel?.apply(proj)
        if !wasOpen { preferencesPanel?.makeKeyAndOrderFront(nil) }  // show on open transition
    } else {
        preferencesPanel?.orderOut(nil)  // hide on close (handle survives; isReleasedWhenClosed = false)
    }
    caches.preferencesPanel = new
}
```

The `caches.preferencesPanel` field and the `reconcilePreferencesPanel()` call inside
`reconcile()` already exist -- no change needed there. (Unlike the quit panel, this pass
does **not** re-center on show: `PreferencesPanel.init` centers once, and a user-movable
utility window should reopen where the user left it.)

### 2. `showPreferencesPanel()` -- shrink to read + dispatch + re-focus

Creation moves into reconcile (single creation site). The trailing call becomes the
re-focus action, expressed with optional chaining since reconcile now owns the handle.
Edit `showPreferencesPanel` (`app/AppRuntime.swift`):

```swift
/// Show or re-focus the preferences panel (Cmd-,). Reads the live Ghostty config to
/// seed the draft (impure -- cannot live in a pure projection), then dispatches.
/// Visibility is reconcile-owned: reconcilePreferencesPanel creates + shows the panel
/// on the draft's nil -> non-nil transition. The trailing makeKeyAndOrderFront is the
/// re-focus action -- on a repeat Cmd-, (draft already non-nil, no projection change,
/// reconcile early-returns) it re-raises an occluded panel and restores key focus.
func showPreferencesPanel() {
    let ghostty = GhosttyPrefs(
        theme: ghosttyApp.readConfigString(key: "theme"),
        fontSize: ghosttyApp.readConfigFloatString(key: "font-size")
    )
    send(.preferencesOpened(ghostty: ghostty))   // reconcile creates + shows on the open transition
    preferencesPanel?.makeKeyAndOrderFront(nil)  // re-focus action (idempotent no-op if already key+front)
}
```

### 3. `PreferencesPanel` -- route hide through the model

- `cancelPreferences` (`PreferencesPanel.cancelPreferences`): drop the imperative
  `close()`. `send(.preferencesClosed)` clears the draft; reconcile (synchronous in
  `send`) orders the panel out.

  ```swift
  @objc private func cancelPreferences(_ sender: Any?) {
      runtime?.send(.preferencesClosed)   // clears draft; reconcile orders the panel out
  }
  ```

- `windowShouldClose` (`PreferencesPanel.windowShouldClose`): **keep returning `true`**.
  It already sends `.preferencesClosed`. Execution order on red-X (prefs messages reconcile
  inline -- see Control-flow facts): `windowShouldClose` -> `send(.preferencesClosed)` ->
  reconcile `orderOut`s the panel (hides it) -> `windowShouldClose` returns `true` ->
  AppKit performs its native window close *after* the delegate returns. Because reconcile
  uses `orderOut` (not `close()`), nothing closes the window from inside the delegate --
  the `close()`-inside-`windowShouldClose` reentrancy a prior draft worried about does not
  arise. Returning `true` is the backstop that guarantees the physical close even if the
  model ever failed to clear the draft -- the right failure mode for a daily driver.
  (Considered and rejected: returning `false` to make reconcile the sole hide -- it trades
  the guaranteed close for a dependency on the model always clearing the draft.)

  ```swift
  // NSWindowDelegate: red-X / performClose. Translate the gesture to a model intent;
  // reconcile orders the panel out. We still return true so AppKit performs its native
  // window close after we return -- it converges with reconcile's orderOut.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
      runtime?.send(.preferencesClosed)
      return true
  }
  ```

### 4. `tearDownCurrentSession()` -- no functional change, document the invariant

`tearDownCurrentSession` (`app/AppRuntime.swift`) already closes + nils the handle *before*
`caches = ReconcilerCaches()`. That ordering is the same invariant commit `28dc243`
established for the switcher (hide before cache reset so nil keeps meaning "already
hidden"). Add a clarifying comment; the restored model carries a nil draft, so the first
post-restore reconcile sees a nil projection and the hide branch no-ops on the
(already-nil) handle.

### 5. No change to the pure layer

`desiredPreferencesPanel` (`app/ModelOperations.swift`) and the `.preferences*` / `.pref*`
update handlers are already correct and tested -- the fix relies on, but does not modify,
them.

## Tests

The two load-bearing pure claims are already covered in `tests/UpdatePreferencesTests.swift`
and need no additions:

- **nil draft -> nil projection** (test "returns nil when no draft is open") -- the
  contract that drives reconcile's hide branch.
- **`.preferencesClosed` clears the draft**, and **`.preferencesOpened` is idempotent**
  (creates the draft only on the closed->open transition) -- these underpin "every hide
  trigger nils the draft -> reconcile hides" and "re-invoke does not re-project -> the
  re-raise is a pure focus action."

`reconcilePreferencesPanel` is an impure AppKit executor (constructs an `NSPanel`, calls
`makeKeyAndOrderFront`/`orderOut`). Per the file's stated manual-QA-only discipline (the
header comment in `app/Reconcile.swift`) and the precedent of the other reconcile passes
(including `reconcileQuitConfirmation`, which ships no unit test for its AppKit calls), its
visibility behavior is verified by manual QA, not unit tests. Do **not** add tests that pin
the impure AppKit calls.

**Add one regression test** (`tests/SnapshotTests.swift`). The fix makes `preferencesDraft`
drive *visibility*, so the premise "a restore yields a nil draft" is now load-bearing: if a
snapshot ever started persisting the draft, restore/import would reopen stale, unsaved
preferences. The plan only asserts this structurally (the fields are ephemeral, absent from
`AppModelSnapshot`) -- pin it with a round-trip that mirrors the existing
`toSnapshot` -> `validateAndBuild` tests in that file:

- Build a valid model with an open, edited draft -- e.g.
  `update(&model, .preferencesOpened(ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14")))`
  then a `.prefSet*` edit (or set `preferencesDraft` / `committedGhosttyPrefs` directly);
  reuse a round-trip test's model setup so `validateAndBuild` succeeds.
- `toSnapshot(model)` (`app/ModelOperations.swift`) -> `validateAndBuild(snapshot)`
  (`app/Model.swift`).
- Assert the rebuilt model's `preferencesDraft == nil` **and** `committedGhosttyPrefs == nil`.

Behavioral and structure-insensitive: it fails exactly when someone adds these ephemeral
fields to `AppModelSnapshot` -- the regression that would silently reintroduce "stale prefs
reopen on restore."

**Guard the inline-reconcile contract** (`tests/UpdateGhosttyTests.swift`). The new hide
path (§3) depends on `.preferencesClosed` reconciling *synchronously* -- i.e. not opting
into `coalescesReconcile`. Pin it by adding `.preferencesClosed` and `.preferencesOpened(...)`
to the existing `inlineMessages` list in the `reconcileDecision` test (the test named
"reconcileDecision coalesces only eligible surface metadata"), which already asserts each
listed message yields `.reconcileNow` for both `coalescedSweepPending` values.
Structure-insensitive: it fails exactly when a future change makes a prefs message coalesce
-- the regression that would leave the panel on-screen after Cancel/Escape/red-X until the
coalesce timer fires.

Run `just test` to confirm the suite (including both added tests) passes.

## Verification

1. `just test` -- pure suite still green.
2. `just build` -- compiles; launch `.build/DanTerm Dev.app`.
3. Manual QA (the panel is `level = .normal`, so occlusion is part of the test):
   - **Cold open** (Cmd-,): panel appears, becomes key (cursor in a field), centered.
     Exercises reconcile create + show branch.
   - **Edit live**: type in Theme / Font Size / Remote Theme; toggle Alert Clear Mode.
     Dirty rows + Save enable; fields stay editable; **no flicker/re-key per keystroke**
     (confirms show is gated to the open transition).
   - **Cancel / Escape**: panel hides; draft cleared (reconcile `orderOut` via the
     removed-`close()` path).
   - **Red-X**: open, click the window close button -> closes cleanly, no crash. (Because
     reconcile uses `orderOut`, no `close()` runs inside `windowShouldClose`; a quick
     console glance for responder warnings is sufficient, not a worry.)
   - **Save keeps open**: open, change, Save -> config saves (theme/font reload if Ghostty
     keys changed), **panel stays open**, dirty rows clear, Save disables.
   - **Re-invoke while occluded** (the payoff): open prefs, click the main terminal so it
     covers the panel, press Cmd-, again -> panel **re-raises and regains key**.
   - **Re-invoke while frontmost**: Cmd-, again with prefs key -> no flicker, no draft reset.
   - **Restore/import with panel open**: open prefs (dirty, unsaved), trigger a session
     swap (import/restore) -> panel disappears in teardown; restored session has no stale
     panel; Cmd-, afterward opens a fresh draft from the restored config.
   - **Browse sheet**: open prefs, click Browse... on a theme field, pick a theme -> sheet
     dismisses, field updates, dirty row appears, panel still open + key.

## Critical files

- `app/Reconcile.swift` -- new `reconcilePreferencesPanel` body (the core change);
  `reconcileQuitConfirmation` is the near-exact reference template (`reconcileSwitcher` the
  secondary one).
- `app/AppRuntime.swift` -- `showPreferencesPanel` (shrink); `tearDownCurrentSession`
  (comment only).
- `app/PreferencesPanel.swift` -- drop `close()` in `cancelPreferences`; keep
  `windowShouldClose` returning true (comment).
- `app/ModelOperations.swift`, `app/Update.swift`, `app/Model.swift` -- unchanged (the
  pure contract the fix relies on; `toSnapshot` and `validateAndBuild` are reused by the
  new regression test).
- `tests/SnapshotTests.swift` -- add the restore-yields-nil-draft round-trip test (mirrors
  the file's existing `toSnapshot` -> `validateAndBuild` tests).
- `tests/UpdateGhosttyTests.swift` -- add the prefs messages to the `inlineMessages` list
  in the `reconcileDecision` test to guard the synchronous-hide contract.
- `tests/UpdatePreferencesTests.swift` -- existing coverage; no additions required.
