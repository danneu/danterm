# Fix: guard the remote-accessory constraint swap in PaneWrapperView.updateToolbar

## Context

DanTerm's reconcile architecture diffs a pure `PaneToolbarRender` per pane and
calls `PaneWrapperView.updateToolbar(...)` only when that render value changes
(`reconcilePaneChrome` -> `applyDiff`, `app/Reconcile.swift:217-229`,
`app/Projections.swift:278-285`). The render struct includes `title` and `cwd`
(`app/Projections.swift:196-205`), and terminal title spam fires the coalesced
reconcile at ~13Hz (0.075s interval, `app/AppRuntime.swift:75`). So every
title/cwd edit reaches `updateToolbar`.

Inside `updateToolbar`, the remote-accessory layout swap at
`app/PaneWrapperView.swift:256-262` runs `NSLayoutConstraint.deactivate(...)` +
`activate(...)` unconditionally, keyed only on `remoteSession == nil` -- with no
check against the last-applied mode. So a title burst re-toggles the constraint
sets on every tick even when the compact-vs-expanded mode is unchanged.

This is the one sub-effect in `updateToolbar` that violates the reconcile
design's stated contract -- documented on `reconcileWindowChrome`
(`app/Reconcile.swift:~280`): executor sub-setters are expected to be idempotent
"so applying all of them on any change is fine." Every other effect in
`updateToolbar` already honors it: the two `isHidden` sets no-op on unchanged
input, `alertBadge.updateBadge` (`app/BadgeLabel.swift:25`) and
`todoButton.update` (`app/TodoToolbarButton.swift:62`) just set text/colors, and
`applyProgressState` (`app/PaneWrapperView.swift:270-272`) already guards itself
with `guard state != currentProgress else { return }`.

Intended outcome: bring the constraint swap into line with that contract and the
in-file `applyProgressState` precedent. The honest value is hygiene and
contract-conformance, not measurable perf -- it is ~2 vs ~6 constraints on a tiny
accessory view, well below anything visible in a trace. Do not oversell perf.

## Approach

Track the active remote layout mode on the instance and early-skip the toggle
when it has not changed -- a structural copy of the `applyProgressState` guard.

### Change (only file: `app/PaneWrapperView.swift`)

1. Add a stored field next to the constraint-array decls (near line 27):

   ```swift
   // Active remote layout mode, so updateToolbar only re-toggles the constraint
   // sets on an actual compact<->expanded change. Starts false because init
   // activates compactRemoteConstraints (line 137). Mirrors the currentProgress
   // guard in applyProgressState and the reconcile executor-idempotency contract.
   private var remoteExpanded = false
   ```

2. Replace the unconditional toggle (current lines 256-262) with a guarded swap:

   ```swift
   let expanded = remoteSession != nil
   if expanded != remoteExpanded {
       remoteExpanded = expanded
       if expanded {
           NSLayoutConstraint.deactivate(compactRemoteConstraints)
           NSLayoutConstraint.activate(expandedRemoteConstraints)
       } else {
           NSLayoutConstraint.deactivate(expandedRemoteConstraints)
           NSLayoutConstraint.activate(compactRemoteConstraints)
       }
   }
   ```

Leave everything else in `updateToolbar` untouched -- the `isHidden` sets and
`remoteSessionLabel.stringValue` (lines 253-255), `applyProgressState`,
`updateBadge`, and `todoButton.update`.

### Why a Bool, and why not guard the rest

- **Bool, not the full `RemoteSession`.** The constraint set depends solely on
  `remoteSession == nil`. Keying the guard on the full session would re-run the
  toggle when a remote session's `displayString` changes (user@host edit) but
  stays non-nil -- reintroducing a milder version of the same redundancy. The
  high-cardinality value already flows to `remoteSessionLabel.stringValue`, which
  is the correct place for it.
- **Don't add a second guard for the `isHidden`/`stringValue` sets.** They are
  already idempotent (same-value `isHidden` is an AppKit no-op; the projection
  diff means `isRemote` is unchanged during a pure title burst, so the arranged
  `remoteAccessory` does not re-lay-out the stack). Only the explicit
  activate/deactivate ran imperatively without a value check -- that asymmetry is
  the whole bug.

### Rejected alternative

Restructuring `remoteAccessory` into an `NSStackView` and driving compact vs
expanded by toggling the label's `isHidden` (the finding's option 2) is tidier in
the abstract but a real refactor: the accessory's hand-tuned constraints (fixed
22pt compact width, leading/trailing insets at lines 125-135) do not map 1:1 onto
stack spacing/hugging, and it changes the visual layout risk surface for the same
net behavior. Larger blast radius, no added correctness. Take the guard.

## Drift safety (no test needed -- reasoning)

The constraint arrays are mutated in exactly three places and nowhere else: the
decls (26-27), init (125-137, compact activated), and this toggle (256-262). So
`remoteExpanded` cannot desync:

- Init activates compact and only compact, so the `false` default matches the
  real initial state.
- A container rebuild destroys and recreates the wrapper (fresh init -> compact +
  `remoteExpanded = false`); the chrome cache is invalidated for rebuilt panes
  (`app/Reconcile.swift` `chromeInvalidation`), so the full render is re-pushed
  and a remote pane re-expands through the guard from a clean base. No stale
  state survives, because the flag lives on the instance, not the cache.

**No new test.** The behavioral output (rendered layout) is identical before and
after; the only difference is eliminated redundant work, which is observable only
by spying on `NSLayoutConstraint` activation -- a structure-sensitive assertion
the repo's test bar rejects (behavioral and structure-insensitive only). The
behavioral contract ("remote -> expanded, non-remote -> compact, and a title
change does not alter that") is already covered by the pure projection diff
(`PaneToolbarRender` only changes on a real input delta; `applyDiff` only applies
on a delta). This matches how the sibling `applyProgressState` guard shipped --
no executor-level test, same rationale.

## Verification

1. `just test` -- confirm the pure suite still passes (this change does not touch
   the projection layer, so it should be green and unchanged).
2. `just build` -- confirm the app compiles.
3. Manual smoke (`just build-run`):
   - Open a normal local pane; run a command that spams the title rapidly (e.g.
     a loop that prints `printf '\e]0;%s\a' $i`). The toolbar title updates live
     and the layout stays stable -- no remote pill appears, no flicker.
   - Open a remote session (ssh) so the purple globe pill shows; confirm it
     renders expanded with user@host, then have the remote shell spam its title
     and confirm the pill stays expanded and stable (no per-tick relayout
     artifacts).
   - Toggle remote on/off (start/exit ssh) and confirm the pill correctly
     switches between compact (icon only) and expanded (icon + label).
