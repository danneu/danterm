# Milestone 6 slice 1: alternate screen and its resize semantics

## Context

First implementation slice of Milestone 6, governed by
`plan-terminal-engine/04-terminal-core.md` (primary and alternate screens;
alt content never enters normal scrollback; full-screen entry/exit restores
primary state), `plan-terminal-engine/05-unicode-grid-scrollback.md` (the
alternate-screen resize contract: no reflow, coordinate retention,
whole-grapheme clipping, active *and saved* cursor clamping, margin reset,
independent primary reflow), `plan-terminal-engine/06-inspection-recovery.md`
(full-history text follows the active screen; export/recovery capture primary
history only), the neutral-fixture mandate in
`docs/research/1-external-tests.md`, and the Milestone 5 decision record
`docs/design/2026-07-20-terminal-engine-experiment-decision.md`, whose risk
list names the alternate screen as the top deferred behavior: `less` and
every full-screen TUI currently run on the primary screen and pollute
history.

The gap: `Terminal` has exactly one screen. Modes 47/1047/1049 are silently
ignored, so full-screen programs scroll their transient frames into
scrollback and leave them in recovery text. There is no per-screen state
anywhere, and the projection boundary has the same shape: `fullHistoryText`
serializes scrollback plus the only viewport, and the app's recovery
checkpoint path reads it, so without a projection split alt-screen frames
would enter saved history in violation of the 06 invariant.

Load-bearing premises (verified against the code and the pinned reference):

- `Terminal` holds one grid, one primary-only scrollback, one scroll region,
  shared mode flags, one saved-cursor slot (position, pen, pending wrap,
  origin mode), a shared pen with BCE from its fg/bg, and one last-printed
  cluster (REP memory). Private-mode dispatch implements exactly DECOM,
  DECAWM, and save/restore cursor (1048); unknown private modes are
  bit-identical no-ops.
- Cursor restore clamps into the positioning range, restores pen and origin
  mode, clears cluster context, and re-derives pending wrap (kept iff
  auto-wrap on and at the last column). It does not yet step off a wide-cell
  tail.
- `resize` resets the scroll region, then runs height resize (scrollback
  push/pull) and width resize (full logical-line reflow over scrollback plus
  active rows with a cursor anchor). Nothing is parameterized per screen.
- There is a single control-driven scrollback push site; settled policy is
  push iff full-screen upward scroll. ED 3 clears scrollback.
- Side-state is **not** uniformly cleared by every recognized operation --
  SGR and save-cursor leave pending wrap and the open cluster intact.
  Clearing is per-operation policy, decided per operation.
- RIS and DECSTR already exist. RIS erases the active grid and homes the
  cursor; DECSTR resets control state. Neither has any notion of a second
  screen, so both will operate on whatever new screen state this slice adds.
- Projections: viewport views plus `fullHistoryText` (scrollback + active
  rows). The session layer exposes viewport and full-history reads; pane-read
  IPC chooses between them, and the recovery/export path reads full history.
  Render planning consumes the viewport views, so the renderer follows
  whatever screen those views project with no wiring change.
- Pinned libvterm (`references/libvterm`) implements 1047/1048/1049 and not
  47; the alt switch swaps per-buffer line info and BCE-erases the full
  screen on entry only, with no already-active guard; scrollback push is
  gated on the primary buffer being active; ED 3 clears scrollback
  unconditionally; cursor, pen, modes, tab stops, and margins are
  single-copy across switches; the saved-cursor storage for ESC 7 and modes
  1048/1049 is shared; and both soft and hard reset clear the alt-screen
  mode.
- Fixture harness: neutral JSON fixtures replay under
  authored/bytewise/exhaustive-split chunkings with whole-value `Terminal`
  equality, against a pinned manifest with per-case dispositions and a fixed
  recorded-deviation set. The `expectedCases` ledger already lists both
  altscreen headings; only their dispositions are currently out-of-scope
  "deferred to Milestone 6": `t/60screen_ascii.test` "Altscreen" and
  `t/63screen_resize.test` "Resize can operate on altscreen".
- The terminal-wide structural assertion concatenates scrollback rows with
  the active viewport and checks seams across that join. That join is invalid
  while alt is active: the last scrollback row and the first alt row belong
  to different screens.

## Milestone 6 slice map

Sequencing preamble for the whole milestone; only slice 1 is planned here.
Each later slice gets its own plan when it starts. The roadmap's Direction
section requires proving behavior at its lowest layer first, which is why
the pure-core slices lead and interaction/renderer work follows.

1. **Alternate screen + resize semantics** (this plan; pure core,
   projection split, minimal recovery-read routing). No dependencies;
   retires the top Milestone 5 risk.
2. **10 MiB scrollback budget and eviction** (pure core). Independent of
   slice 1. Must precede slices 4 and 6, whose anchor contracts include
   eviction clamping and eviction-driven invalidation.
3. **Remaining core controls, modes, queries, and resets** (pure core):
   cursor visibility (25), cursor style, synchronized updates, DA/DSR/DECRQM
   replies limited to implemented capabilities. After slice 1 so mode
   queries report alt-screen state truthfully.
4. **Selection and search over the logical projection** (pure core policy):
   linear selection serialization, literal full-history search, anchors
   that stay attached to logical content across reflow and invalidate on
   overwrite/eviction. Needs the inspection projection (exists) and
   slice 2.
5. **Input encoding policy** (deterministic policy): terminal key encoder
   (legacy, application cursor/keypad, focus, bracketed paste, Kitty),
   paste sanitization. Needs slice 3's mode state. **Mouse reporting**
   (SGR encoding, capture-vs-local-selection precedence, Shift overrides)
   follows inside or immediately after this slice: it needs the input
   encoding seam and slice 4's local selection for precedence proofs.
6. **Viewport-offset and interaction state + anchored reflow** (core +
   session): local viewport offset, bottom-follow, stable top anchor
   across output and reflow, eviction clamp; then the AppKit
   wheel/scrollbar riding it. Needs slice 2; discharges the roadmap's
   "viewport anchoring once 08 provides interaction state" bullet.
7. **Renderer and interaction completion + damage equivalence**: selection
   rendering, cursor style/blink, font-fallback and scaling gaps, OSC 52
   bounded clipboard writes, OSC 8 + detected links, and the logical
   damage seam with the "damage redraw equals full redraw" gate. Needs
   slices 4-6; alt-screen switches (slice 1) become a full-area damage
   case here.
8. **Milestone 6 fixture closure and exit audit** (like Milestone 2 slice
   8): every external case family assigned through Milestone 6 gets a
   disposition, the Termless differential evaluate-or-drop decision is
   recorded, and the milestone gate bullets are judged. Depends on all.

OSC title/cwd/notification events are Milestone 7 (protocols) despite
appearing in the Milestone 5 risk list; they stay out of every Milestone 6
slice.

## Decision

Scope: pure terminal core plus the projection split and a one-call-site
recovery-read routing change. No renderer, input, or mouse work -- the
renderer reads the viewport views and follows the active screen
automatically.

- **Mode matrix** (normative; pin = libvterm at the pinned commit):

  | Mode | DECSET (`CSI ? n h`) | DECRST (`CSI ? n l`) | Issued while already in the target state |
  |---|---|---|---|
  | 47 | Ignored (bit-identical no-op, like every unknown mode today; user-settled) | Ignored | -- |
  | 1047 | Switch to the alt screen; BCE-clear the entire alt grid with the pen's fg/bg; all alt rows start not-soft-wrapped; cursor position, pen, modes, tab stops, and scroll region carry over unchanged | Switch to primary; no clearing of either buffer; no cursor restore -- the live cursor carries back; primary rows reappear exactly as retained | Set-while-alt re-clears the alt grid. Reset-while-primary changes no screen or buffer, but is still a recognized switch and so clears switch side-state |
  | 1048 | Save cursor into the one shared slot (existing behavior, unchanged) | Clamped restore (existing behavior) | Unconditional save/restore, as today |
  | 1049 | Save cursor into the shared slot, then behave as DECSET 1047 | Behave as DECRST 1047, then clamped restore from the shared slot | Set-while-alt re-saves the current (alt) cursor into the shared slot and re-clears the alt grid -- pinned libvterm sharp edge. Reset-while-primary still performs the restore |

  Ordering for 1049-set is save, then switch, then clear -- observably
  identical to libvterm's order (the entry erase never moves the cursor)
  and easier to state and test. The switch itself never homes or moves the
  cursor.
- **Per-screen vs shared state.** Per-screen: grid content only. Shared,
  single copy across both screens: cursor position, pen, all modes, tab
  stops, scroll region, REP memory, the saved-cursor slot (user-settled:
  shared, pinning libvterm), and scrollback (primary-only by construction).
  A switch alters none of these except the cursor save/restore the matrix
  specifies and the switch side-state clear below.
- **Switch side-state.** Every recognized 1047/1049 set or reset -- including
  the redundant ones, which are real operations upstream -- clears live
  pending wrap and any open grapheme-cluster attachment. This is a
  switch-specific policy chosen so a switch never leaves a phantom
  wrap or a half-formed cluster pointing at a grid the sequence just
  replaced; it is not a house-wide rule (SGR and save-cursor deliberately
  preserve both). The clear precedes any restore the matrix specifies, so
  1047 operations and 1049-set finish with pending wrap cleared, while
  1049-reset clears and then re-derives pending wrap through the existing
  restore rule and may finish re-armed. For 1049-set the save happens before
  the clear, so the slot captures the pre-switch pending-wrap state.
- **Resets while alt is active.** Both RIS and DECSTR clear the alt-screen
  mode and leave the primary screen active, discarding the alt grid. RIS
  then erases the (now primary) grid and homes the cursor as today; DECSTR
  resets control state as today. Neither reset may strand the primary grid
  behind an active alt screen or lose it. The pinned reference clears its
  alt-screen mode flag on both hard and soft reset but does not re-select the
  screen buffer, leaving flag and buffer inconsistent; DanTerm deliberately
  keeps the two consistent.
- **No retained alt buffer.** The alt grid exists only while the alt
  screen is active and is discarded on exit. This is unobservable because
  both implemented entry paths BCE-clear on entry -- and it is coupled to
  the 47-ignored decision: adopting 47 (the only no-clear entry path)
  later forces revisiting this storage direction. While alt is active, the
  primary grid is stashed together with a snapshot of the entry cursor and
  pending-wrap state; that snapshot is a reflow anchor only and is never
  restored as the live cursor.
- **Scrollback policy.** The single push site gains the conjunct "and the
  primary screen is active"; a full-screen upward scroll on the alt screen
  discards its top row and pushes nothing. ED 3 clears retained scrollback
  regardless of the active screen (pinned). ED 2 and every erase/edit
  operate on the active grid only. Height-resize push/pull and width reflow
  run only against the primary grid.
- **Alt-screen resize (rectangle semantics, per 05).** Cells keep their
  coordinates; shrink discards rows and cells outside the new rectangle.
  When the new right edge would split a wide cell or its grapheme (a wide
  head whose tail falls outside, or an orphaned tail/spacer at the edge),
  the whole cell clears to a blank preserving that cell's background,
  consistent with the existing spacer-replacement convention. Growth adds
  default-styled blank cells and rows (matching the primary resize blank
  convention -- deliberately not BCE). Printing on the alt screen soft-wraps
  normally within the grid; a width resize clears the soft-wrap flag on all
  alt rows (non-reflow resize drops continuation, as upstream). Margins
  reset to the full resized grid.
- **Cursor clamping on resize.** Every effective resize clamps both the live
  cursor and the saved-cursor slot into the new grid, and neither may land
  on a wide-cell tail (05 requires this of both, so lazy clamp-at-restore is
  rejected: it would leave the slot out of range between resize and restore
  and would restore a stale column after shrink-then-grow). Tail avoidance
  for the saved slot is evaluated against the grid that is active at resize
  time, since that is the grid whose layout the resize just fixed. Restore
  gains the same step-left-off-a-tail rule, re-evaluated against the grid
  active at restore time, which also covers the underlying cell changing
  without a resize.
- **Inactive-primary resize (equivalence contract, per 05).** While alt is
  active, a resize also runs the full primary contract over scrollback plus
  the stashed primary rows, anchored on the stashed cursor snapshot exactly
  as if it were live; the snapshot is updated by the resize so consecutive
  resizes compose. Mechanics (grid swapping vs parameterized machinery) are
  implementation discretion. Note this is content equivalence only: the
  *live* cursor is shared and follows alt rectangle-clamping while alt is
  active, so it legitimately differs from the reflow-anchored outcome of
  resizing before entry. Live and saved cursor outcomes are pinned by the
  mode matrix and the clamping rule above, not by the equivalence contract.
- **Projection split.** The viewport views and `fullHistoryText` follow the
  active screen: while alt is active, `fullHistoryText` is primary scrollback
  plus the alt viewport (mandated by 06; pane-read IPC keeps consuming it).
  That junction is always a hard line boundary, whatever the last scrollback
  row's wrap flag says, because the two sides belong to different screens and
  merging them would emit a logical line that exists nowhere. One new public
  view always serializes scrollback plus primary rows with the same
  logical-line join rules -- there the junction is genuinely continuous and
  the wrap flag governs -- and equals `fullHistoryText` whenever primary is
  active.
- **App seam (recovery/export reads primary).** The session/backend boundary
  gains a primary-history read alongside the full-history read, and exactly
  one call site switches to it: the recovery/export scrollback read that
  feeds enriched checkpoints and export. The Ghostty backend implements the
  new read as its existing full-history read (it cannot distinguish screens).
  Pane-read IPC is unchanged.
- **Recorded deviations:** none added; the manifest's deviation set is
  unchanged. Both altscreen cases reproduce their upstream assertions.
  DanTerm-vs-libvterm differences unobserved by any pinned case (mode 47
  ignored, alt never reflows, rectangle clip vs upstream's content walk,
  pending wrap cleared on switch, eager saved-cursor clamping, no physically
  retained alt buffer, reset re-selecting the primary screen) are
  contract-level decisions recorded here, not manifest deviations.

## Invariants

- I1 Screen isolation: while the alt screen is active, primary rows and
  scrollback change only through three permitted operations -- resize of the
  inactive primary (I7), ED 3, which empties scrollback from either screen
  (I2), and the reset effects governed by I12. Absent all three, exiting
  reveals primary rows and scrollback bit-identical to entry.
- I2 Scrollback gate: control-driven pushes happen only while the primary
  screen is active (the existing full-screen-upward policy gains that
  conjunct); ED 3 empties scrollback from either screen; no other alt
  operation and no alt resize ever pushes to or pulls from scrollback.
- I3 Mode conformance: 1047/1048/1049 set/reset and redundant re-issue behave
  exactly per the mode matrix; 47 and all other unrecognized private modes
  remain bit-identical no-ops.
- I4 Entry clear: 1047/1049 entry leaves the alt grid fully BCE-cleared
  (pen fg/bg, attributes reset) with no soft-wrap flags; stale alt content
  from a previous visit is never observable.
- I5 Shared state: cursor position, pen, all modes, tab stops, scroll region,
  REP memory, and the single saved-cursor slot are one copy across both
  screens; a switch changes none of them beyond the matrix's cursor
  save/restore; a save issued on one screen is restorable on the other.
- I6 Alt resize contract: surviving cells retain coordinates; a wide cell or
  grapheme split by the new edge clears as a whole while preserving that
  cell's background; growth is default-styled blank regardless of the pen;
  no reflow; margins reset to the full grid.
- I7 Primary content equivalence: enter-alt, resize(s), exit is
  indistinguishable from resize(s), enter-alt, exit for primary rows and
  scrollback. Cursor outcomes are governed by I3 and I11, not by this
  invariant.
- I8 Projection split: `fullHistoryText` follows the active screen and never
  joins a scrollback row to an alt row into one logical line; the
  primary-history projection always serializes scrollback plus primary rows
  and equals `fullHistoryText` while primary is active; the recovery and
  export read path consumes the primary projection, so saved history can
  never contain alt content.
- I9 Structural validity, equality, and chunk invariance: the grid contract
  holds after every operation, validated per screen -- the active alt grid on
  its own, and scrollback plus primary rows as one continuous stream (never
  scrollback joined to an alt row). All new state participates in `Terminal
  ==`; every new sequence replays chunk-invariantly to whole-value-equal
  terminals.
- I10 Side-state: every recognized screen switch finishes with open cluster
  attachment cleared, and clears live pending wrap before any restore the
  matrix specifies -- so 1047 operations and 1049-set finish with pending wrap
  cleared, while 1049-reset may finish re-armed from the restored slot. A
  syntactically invalid or unsupported dispatch leaves the terminal
  bit-identical.
- I11 Cursor validity: after any effective resize, both the live cursor and
  the saved-cursor slot are inside the grid and not on a wide-cell tail of
  the grid active at resize time; restore never lands on a wide-cell tail of
  the grid active at restore time.
- I12 Reset screen selection: after RIS or DECSTR the primary screen is
  active and the primary grid is the one the terminal exposes; no reset can
  leave the alt screen active or discard the primary grid in its place.

## Proof obligations

Reuse the house harness: public-API unit suites, structural grid assertions,
whole-value equality, the fixture replay runner, and the existing fuzz
sweeps. TDD per repo convention: every change lands failing-test-first and
every commit stays green.

- PO1 (I1-I3) Regression: all existing suites pass unchanged; a terminal
  that never enters the alt screen behaves bit-identically to today.
- PO2 (I3, I10) Mode matrix: every cell of the matrix including the redundant
  re-issues -- the 1049 set-while-alt re-save/re-clear sharp edge, the 1049
  reset-while-primary restore side effect, the 1047 reset-while-primary
  side-state clear, and 1047 exit carrying the live cursor -- plus 47 and
  unknown-mode no-ops, issued mid-pending-wrap and mid-cluster. The pending-wrap
  postconditions are asserted through the next printed character, separating
  the switches that finish cleared from a 1049-reset that finishes re-armed
  from the slot.
- PO3 (I1, I4) Entry/exit: BCE clear on entry under a styled pen, printing
  and erasing on alt, exit revealing primary content -- adopting the libvterm
  "Altscreen" case as a neutral fixture.
- PO4 (I1, I2) Scrollback isolation: full-screen scroll on alt pushes
  nothing; exit shows scrollback bit-identical; ED 3 issued from alt empties
  primary scrollback.
- PO5 (I5) Shared state across switches: every member I5 names -- cursor,
  pen, each mode, tab stops, scroll region, REP memory, and the saved slot --
  is observably unchanged across a switch in both directions, and a save
  issued inside alt restores onto primary (pinning the shared-slot decision).
- PO6 (I6, I9, I11) Alt resize: width/height shrink and growth cover
  coordinate retention, whole-wide-cell and whole-grapheme clearing at the
  split edge with the clipped cell's background preserved, default-styled
  growth under a non-default pen, soft-wrap flag clearing on width resize,
  margin reset, and live- and saved-cursor clamping off tails including a
  saved column whose tail status differs between the primary and alt grids --
  adapting the
  libvterm "Resize can operate on altscreen" case plus DanTerm-authored cases
  (no upstream analog for the clipping and clamping rules).
- PO7 (I7) Primary equivalence: width reflow and height shrink/growth while
  alt is active, including consecutive resizes, compared against the
  resize-before-entry ordering for primary rows and scrollback.
- PO8 (I8) Projections and seam: `fullHistoryText` equals scrollback plus the
  alt viewport while alt is active, asserted with an exact expected string for
  the case where the last scrollback row is soft-wrapped and alt content
  follows it (the two must not merge into one line); the primary projection
  equals scrollback
  plus primary rows throughout and equals `fullHistoryText` on primary; the
  session-layer primary read and the recovery/export call site return
  primary-only text while a pane's alt screen is active, proven at the lowest
  practical layer.
- PO9 (I12) Resets while alt is active: RIS and DECSTR each leave the primary
  screen active with the primary grid exposed, and their existing effects on
  grid content, cursor, scrollback, and the saved slot are pinned in that
  state.
- PO10 (I3-I7, I9) The new neutral fixtures replay under
  authored/bytewise/exhaustive-split chunkings, and manifest coverage passes
  with the two disposition flips and an unchanged deviation set.
- PO11 (I9) Fuzz: extend the fuzz alphabet with 1047/1048/1049 set/reset and
  resize-while-alt; sweep structural validity and no-trap over the extended
  alphabet.

Slice exit gate: `just test` green (all packages plus lint scripts), plus a
Milestone 6 slice sub-bullet in `plan-terminal-engine/14-roadmap.md` linking
the promoted plan (following the Milestone 2 slice convention). Live sanity
check, non-gating: run `less` in a Swift-engine pane, quit, and confirm the
prompt-history text contains no pager frame.

## Non-goals

- Mode 47 (user-settled: ignored; the no-retained-alt-buffer storage
  direction depends on this and is revisited together with it).
- Cursor visibility (25), DECRQM/query replies -- including reporting mode
  1047 -- and other remaining modes (slice 3).
- Renderer, input, mouse, and damage work. The full-area damage on switch is
  pinned upstream behavior to adopt when the damage seam lands (slice 7); its
  upstream file stays outside the selected manifest set.
- Recovery-freshness suppression for alt-only mutations: checkpoints may
  rewrite identical primary text while a TUI runs; correctness is unaffected
  and the power-contract tuning belongs to later work.
- A public alt-screen state flag: behavior is asserted through projections
  and whole-value equality.
- Alacritty alternate-screen recordings (later interaction slices).

## Accepted risks

- AR1 The saved-cursor slot clamps geometrically on resize rather than
  re-anchoring to logical content, so a 1049 exit after a width reflow can
  restore onto different logical content than at entry. Re-anchoring the
  saved slot has no upstream analog and no consumer demand; PO6 pins the
  clamping rule so the behavior is deliberate.
- AR2 The Ghostty backend cannot distinguish primary history, so its primary
  read falls back to full history; I8 is fully honored only on the Swift
  backend. Acceptable during coexistence.
- AR3 Clearing pending wrap on switches diverges from libvterm, which carries
  its phantom state across; no pinned case observes the difference.
- AR4 `fullHistoryText` while alt is active interleaves primary history with
  a transient alt frame for IPC pane-read consumers; mandated by 06. Any
  future consumer of the full-history read must consciously choose a
  projection.
- AR5 DECSTR returning to the primary screen is a DanTerm policy, not an
  inherited one: the pinned reference clears its alt-screen mode flag on soft
  reset without re-selecting the screen buffer, and other emulators leave the
  screen selection alone entirely. No pinned case observes the difference, and
  leaving the alt screen active (or flag and screen inconsistent) across a
  soft reset is the riskier direction for I12.

## Rejected ideas

- RI1 Per-screen saved cursors (xterm-style): rejected by user decision; the
  shared slot pins libvterm and matches the existing single-slot code.
- RI2 Physically retaining the alt buffer while primary is active (libvterm's
  storage model): unobservable while 47 stays ignored, and it would force
  inactive-alt resize bookkeeping for no behavioral gain.
- RI3 Clear-on-exit for 1047 (xterm rmcup): pinned libvterm clears on entry
  only; observably convergent for well-behaved apps.
- RI4 Reflowing the alt screen on resize: forbidden by 05.
- RI5 Guarding recovery by skipping checkpoints while alt is active instead
  of splitting the projection: leaves export wrong and races crash windows;
  the projection split is the correct seam and matches 06's layering.
- RI6 Clamping the saved cursor lazily at restore instead of on resize:
  contradicts 05's requirement that saved cursors clamp within the new grid,
  and restores a stale column after shrink-then-grow.

## Implementation discretion

- Storage shape of the stashed inactive-primary screen and whether the
  resize/reflow machinery temporarily swaps grids or is parameterized by
  screen.
- Naming and placement of the primary-history projection and the
  session/backend read method.
- Whether the entry clear reuses the ED 2 internals or a dedicated path,
  provided I4 holds.

## Fixtures and manifest

Provenance is pinned to the libvterm commit already recorded in the manifest.
Two dispositions flip and their fixture files are added; the `expectedCases`
ledger and the recorded-deviation set already cover these cases and do not
change.

- `t/60screen_ascii.test` "Altscreen" -- out-of-scope -> **adopted**;
  assertions reproduce byte-for-byte under the mode matrix. The upstream
  harness's alt-buffer opt-in flag has no DanTerm analog (alt is always
  available); note that in provenance.
- `t/63screen_resize.test` "Resize can operate on altscreen" -- out-of-scope
  -> **adapted** (dimensions reduced per the sibling resize fixtures' house
  style; upstream runs reflow-off and scrollback callbacks off, so nothing
  pinned conflicts with alt-never-reflows).

Wide-cell/grapheme clipping, cursor clamping, switch side-state, reset screen
selection, shared-slot, scrollback-isolation, and primary-equivalence cases
have no upstream analog and live in unit suites, not fixtures (provenance
requires an upstream case).

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- mode dispatch,
  screen switch, alt grid, push-site gate, alt resize, inactive-primary
  resize, reset screen selection, cursor clamping, primary projection.
- The core fixture suite, its manifest JSON, and the new fixture files.
- New/extended core unit suites (alt-screen semantics, alt resize,
  equivalence, fuzz alphabet), plus the shared structural grid assertion,
  which needs a per-screen form.
- `lib/TerminalPTY/.../TerminalPaneSession.swift` -- primary-history read.
- `app/TerminalBackend.swift` and both backend implementations.
- `app/AppRuntime.swift` -- the recovery/export scrollback read call site.

## Commit progress

- [x] 1. Route recovery and export through a primary-history read
- [x] 2. Implement alternate-screen state, resize semantics, projections, and native proofs
- [x] 3. Adopt alternate-screen fixtures and record the roadmap slice
