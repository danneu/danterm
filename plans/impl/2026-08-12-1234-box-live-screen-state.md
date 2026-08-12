# Box the live screen as ScreenState (S14)

## Context

Audit finding S14 (docs/scratch/2026-08-11-simplification-audit.md, line 409).
Per-screen state in `Terminal` (lib/TerminalCore/Sources/TerminalCore/Terminal.swift)
exists in two shapes at once: the live screen's seven fields (`rows`, `cursor`,
`isPendingWrap`, `savedCursor`, `semanticContent`,
`semanticContentClearsAtEndOfLine`, `kittyKeyboardStack`) are loose stored
properties, while the inactive screen is a boxed `ScreenState`. A computed
`liveScreenState` marshals between them with a hand-maintained get list and set
list: adding an eighth per-screen field and forgetting either half compiles fine
and silently drops that field on every screen switch. Every both-screens
operation is written twice (`clampCursorStateToActiveGrid` vs
`clampScreenCursorState`; the loose-then-unbox/rebox kitty clear in
`resetControlState`), and resize marshals the primary through the loose fields
three times. The drift cost is not hypothetical: commit 42f37d02 is a past
incident of a per-screen field (`savedCursor`) living loose and having to be
moved into the box.

Desired outcome: per-screen state has exactly one representation, so a future
per-screen field is added by editing `ScreenState` alone, and every
both-screens operation has one implementation.

Sequencing: lands after the in-flight S16 search lift cuts over (the audit's
"Settle these first" ordering; both rewrite overlapping regions of
Terminal.swift).

## Decision

Store the live screen as one stored `ScreenState` alongside the existing
`inactiveScreen: ScreenState?` and `activeScreen` enum. Delete the seven loose
properties and `liveScreenState`. The change is compiler-checked: deleting the
properties makes every stale bare reference fail to compile.

- `ScreenState` gets default values for every field except `rows`, so a new
  per-screen field is declared, with its reset default, in exactly one place.
- `swapActiveScreen` becomes a whole-state exchange: carry the live cursor into
  the incoming screen, clear its pending wrap, exchange the boxes, flip the
  enum. No field marshalling.
- `resize` has one code path: the primary is reflowed by the ambient reflow
  routines, and the inactive screen, if present, gets the rectangle resize plus
  clamp. When the alternate is live, putting the primary in the live slot for
  the duration is a plain exchange, not `swapActiveScreen` -- no cursor carry,
  no pending-wrap reset, no enum flip, matching today's stash semantics.
- One cursor-state clamp serves both screens; `clampCursorStateToActiveGrid`
  is deleted.
- `resetControlState` clears both kitty stacks symmetrically, in place, with no
  unbox/rebox.

## Invariants

- I1: Every per-screen field is a `ScreenState` member; `Terminal` holds
  exactly two screen boxes (live plus optional inactive) and no
  field-marshalling list exists anywhere.
- I2: `activeScreen == .alternate` implies `inactiveScreen != nil` (only
  `swapActiveScreen` flips the enum, and it always boxes the outgoing screen).
- I3: A screen switch carries the live cursor into the incoming screen and
  clears its pending wrap; all other per-screen state round-trips unchanged --
  now guaranteed by whole-struct exchange rather than by two lists kept in
  sync by hand.
- I4: Returning from the alternate screen restores the primary's semantic
  prompt state: a prompt marked before entering the alternate screen is still
  vacated by a later width resize taken after exit.
- I5: An alternate-live resize reflows the primary under the primary's own
  cursor and semantic state; the alternate screen only ever gets the rectangle
  resize plus clamp.
- I6: DECSTR/RIS clears the kitty keyboard stacks of both screens.
- I7: `Terminal` equality covers the same state as before the refactor.
- I8: Feed/render hot-path performance is unchanged, measured on the final
  state of the change, not asserted (agent-docs/measurement-discipline.md).

## Proof obligations

- PO1 (I4): the one coverage gap found -- new behavioral test, written first
  and green against current code: mark a prompt (OSC 133), enter and exit the
  alternate screen, then width-resize; expect the prompt vacated. Existing
  `lineAndAlternateScreenState` pins only the stash direction (resize while
  the alternate is live). Home: TerminalOSC133Tests or
  TerminalAlternateScreenTests.
- PO2 (I1-I3, I5-I7): existing suites are the gate --
  TerminalAlternateScreenTests (cursor carry, nested 1049 saves,
  screen-scoped saved-cursor slots, inactive-side resize equivalence,
  `primaryScreenRows` projections), TerminalKittyKeyboardTests (independent
  per-screen stacks; DECSTR/RIS clears both), TerminalSavedCursorTests
  (equality participation), TerminalResizeTests, TerminalResetTests,
  TerminalMemoryCensusTests (census counts both screens). `just test`.
- PO3 (I8): `just benchmark-confirm baseline=<pre-change revision>` run against
  the final state of the change -- after the resize collapse, not against an
  intermediate revision. A regression stops the land.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: S15 (mode registry), S34 (anchors), S53 (file split) -- ordered
  behind this change by the audit, not part of it.
- Non-goal: changing which state is per-screen. `scrollRegion` stays shared
  even though ghostty scopes it per screen; that is a behavior change to raise
  separately if wanted.
- AR1: the unreachable state (alternate live with nil `inactiveScreen`) now
  traps in resize instead of silently reflowing the alternate as the primary.
  Deliberate: consistent with `primaryScreenRows`'s existing precondition, and
  a trap beats garbage.
- AR2: resize cost is not paired-measured. The resize probe deliberately has no
  second arm, threshold, or verdict, and the documented gate for admitting a
  paired resize workload is a change *expected* to move resize cost (justfile,
  `terminal-resize-probe`). This change replaces three field marshallings with
  one whole-state exchange on a copy-on-write rows array, so it is not that
  change; building a calibrated resize arm for it is a separate decision.
  I5's behavioral tests cover resize correctness.
- RI1: the audit's literal shape -- `primary`/`alternate` fixed slots with a
  computed live accessor -- rejected. A get/set computed property CoW-copies
  the rows array on every hot-path read-modify-write, and the `_read`/`_modify`
  escape hatch is an unofficial idiom absent from this codebase. The stored
  live box reaches the same invariant (I1) with plain fixed-offset access.
  Carry this rationale into the commit message so the audit's phrasing does
  not get "re-fixed" later.
- RI2: the audit's cheaper fallback (derive `liveScreenState` from one
  keypath-pair list) -- rejected: it keeps the two-shape substrate that lets a
  new per-screen field be added loose and never boxed.

## Implementation discretion

- The clamp's exact shape (mutating method on `ScreenState` with copied
  context arguments, or a non-mutating `Terminal` method taking
  `inout ScreenState`) -- both are exclusivity-clean; today's
  `clampPosition(&cursor, in: rows)` already compiles in the second shape.
- The live box's property name. `live` collides with locals the style/hyperlink
  GC collectors already bind.
- How the change is split into commits.

## Critical files

- lib/TerminalCore/Sources/TerminalCore/Terminal.swift
- lib/TerminalCore/Tests/TerminalCoreTests/TerminalOSC133Tests.swift or
  TerminalAlternateScreenTests.swift (PO1)

## Verification

1. PO1 test passes before and after.
2. `just test` (full gate); targeted:
   `swift test --package-path lib/TerminalCore --filter "AlternateScreen|Resize|KittyKeyboard|SavedCursor|OSC133|Reset|MemoryCensus"`.
3. `just benchmark-confirm baseline=<pre-change revision>` on the final state --
   neutral result expected; a regression stops the land per measurement
   discipline.
