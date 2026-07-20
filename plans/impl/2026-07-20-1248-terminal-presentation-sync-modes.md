# Milestone 6 slice 3: core queries and presentation modes

## Context

Third implementation slice of Milestone 6, governed by
`plan-terminal-engine/04-terminal-core.md` (the core "produces ordered output
bytes" :13; "cursor style and application-requested blinking", "synchronized
updates", "device, cursor, and mode queries needed for feature detection"
:25-27; "Synchronized updates suppress intermediate presentation without
suppressing final state changes" :43-44; "Query replies report only
capabilities the engine actually implements" :54) and the slice map in
`plans/impl/2026-07-20-1014-alternate-screen-resize-semantics.md` (slice 3:
"Remaining core controls, modes, queries, and resets (pure core): cursor
visibility (25), cursor style, synchronized updates, DA/DSR/DECRQM replies
limited to implemented capabilities. After slice 1 so mode queries report
alt-screen state truthfully."). Unblocks slice 5 (input encoding needs
settled mode storage and the reply seam) and slice 7 (cursor rendering needs
presentation state).

The gap: `Terminal` (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`)
has no outbound channel of any kind -- `feed` (:232) returns `Void` and no
reply state exists anywhere -- so every query-bearing program waits on
silence. Cursor visibility and style have no representation; DECSET/DECRST 25
and DECSCUSR are bit-identical no-ops; synchronized updates (2026) are
ignored; the app renders with a hardcoded
`RenderPresentation(theme: .dark, isCursorVisible: true)`
(`TerminalPaneSession.swift:243`).

Load-bearing premises (verified against the working tree and the pinned
reference):

- CSI dispatch (`dispatchCSI` :884) branches on exact intermediates:
  `[0x21]` -> DECSTR, `[0x3F]` -> DEC private set/reset (:1017; implements
  only 6, 7, 1047, 1048, 1049; unknowns silently dropped), empty -> main
  table with `default: break` (:993). ANSI modes (:998) implement 4 and 20.
  The parser (`EscapeAbsorber.swift`) collects private markers 0x3C-0x3F
  and classic intermediates 0x20-0x2F into one `intermediates` array in
  stream order, so DECRQM `CSI ? Pd $ p` arrives as
  `intermediates == [0x3F, 0x24]`, final `0x70`; ANSI DECRQM as
  `[0x24]`/`0x70`; DECSCUSR `CSI Ps SP q` as `[0x20]`/`0x71`; DA/DSR finals
  `0x63`/`0x6E` currently fall through unhandled. `CSI > q` (XTVERSION)
  arrives as `[0x3E]`/`0x71` and stays a no-op. DCS bodies (DECRQSS) are
  absorbed and never dispatched.
- Mode state is individual stored `Bool`s (:179-182). The saved-cursor slot
  (`SavedCursorState` :103) holds position, pen, pending wrap, origin mode;
  `saveCursor`/`restoreCursor` are shared by ESC 7/8, CSI s/u, and modes
  1048/1049. Resets: `softReset` :1509, `hardReset` :1515, shared
  `resetControlState` :1529; `TerminalResetTests.swift` pins the
  preserve-vs-clear matrices, including that both resets preserve the slot.
- `Terminal` is `Equatable`; chunk invariance is proven by whole-value
  equality -- the fixture runner (`TerminalFixtureTests.swift` :10-35,
  authored/bytewise/every-split) and per-suite `dispatchChunkInvariance`
  helpers. Whatever carries replies must ride inside that equality or the
  proofs go blind to reply bytes.
- `TerminalPTYHost.applyOutput` (:545) feeds the terminal and signals
  updates only when `terminal != previousTerminal`. The pty write path
  exists: `enqueueInput` :405 -> `flushInput` :411 (guards closed master).
  Test capture: `capturedInputWrites` records only user-originated
  `.writeInput` command bytes; `recentOutput` records pty output.
- `TerminalPaneSessionController.planIfNeeded` (:239-248) plans a frame
  whenever the snapshot differs from `lastPlannedTerminal`, with the
  hardcoded presentation; `RenderFramePlanner` already consumes
  `presentation.isCursorVisible` (`RenderFramePlanner.swift:77`). No
  cursor-style concept exists in render planning.
- Fixture schema: expect-event payloads (`FixtureExpectation`,
  `TerminalFixtureTests.swift:519-530`) have no output/reply or cursor
  appearance fields; `expect` events are payload-free checkpoints in
  `NeutralTerminalRecordingEvent`, so the schema extension is test-side
  only.
- Live capture compares live state against replayed state:
  `NeutralTerminalRecording.replay()` is asserted exactly equal to the
  host's snapshot (`TerminalPTYHostTests.swift:312`), pinning the
  Milestone 4 capture invariant. Because the production host drains the
  reply buffer every feed (D9), replay must adopt the same drain
  discipline or a query-bearing capture desynchronizes (D9a).
- Manifest: `t/26state_query.test` is absent from both the manifest and the
  `expectedCases` ledger. `t/15state_mode.test` "DECRQM on DECOM" is
  out-of-scope with rationale "Query replies are deferred until the
  terminal engine has an output channel" (manifest :528) -- this slice
  flips it. `t/22state_save.test` cases are adapted with rationales
  "omitting unsupported cursor appearance properties" -- this slice
  upgrades them. DECRQSS cases in `t/12state_scroll.test` and
  `t/13state_edit.test` stay out-of-scope (DCS-carried replies).
- Pinned libvterm (`references/libvterm`, commit
  `934bc2fbf21800ac3458a499df8820ca5fb45fd3`): DA replies `CSI ? 1 ; 2 c`
  only for parameter 0; DSR 5 -> `CSI 0 n`; CPR reports the absolute
  position; DECCPR is CPR with a `?` prefix; DECRQM replies 1/2 for its
  implemented modes and 0 for everything else -- including 1048 and 1049;
  there is no ANSI DECRQM in libvterm; DECSCUSR maps 0/1 -> blinking
  block, 2 -> steady block, 3/4 -> underline, 5/6 -> bar, ignores > 6;
  `savecursor` saves and restores cursor visibility, blink, and shape
  alongside position and pen, and the adopted upstream
  `t/22state_save.test` pins that restore; `vterm_state_reset` restores
  visible + blinking block on both soft and hard reset; 2026 does not
  exist at the pinned commit.
- `t/26state_query.test` (63 lines): DA, XTVERSION, DSR, CPR (two PUSHes),
  DECCPR, six DECRQSS cases, S8C1T -- `output "..."` assertions throughout.

## Decision

Scope: pure terminal core (reply seam, queries, presentation state, resets),
one host routing change (replies -> pty), and minimal presentation wiring in
the session controller (cursor visibility + synchronized-update gating).
No renderer work: cursor shape/blink drawing is slice 7.

- **D1. Reply seam -- an append-only buffer inside the value.** `Terminal`
  gains an ordered reply-byte buffer: queries append; a single public
  mutating drain returns and clears it; a public read-only view exposes the
  undrained bytes for tests. The buffer participates in `Equatable`.
  Consequences, which are the point: every existing whole-value
  chunk-invariance proof (fixture runner, per-suite helpers, recording
  replays) automatically covers reply bytes. `feed`'s signature does not
  change. Replies are emitted only during `feed` dispatch, so buffer growth
  between drains is bounded by fed input; the production host drains after
  every feed (D9).
- **D2. Reply table (normative; every emitted byte listed).** All replies
  are 7-bit (`ESC [` ...). Nothing outside this table ever emits bytes.

  | Query | Recognized form | Reply |
  |---|---|---|
  | DA primary | `CSI c` / `CSI 0 c` | `CSI ? 1 ; 2 c` |
  | DSR 5 | `CSI 5 n` | `CSI 0 n` |
  | CPR | `CSI 6 n` | `CSI <r> ; <c> R`, 1-based, origin-relative under DECOM |
  | DECDSR 5 | `CSI ? 5 n` | `CSI ? 0 n` |
  | DECCPR | `CSI ? 6 n` | `CSI ? <r> ; <c> R`, same coordinates as CPR |
  | DECRQM (DEC) | `CSI ? Pd $ p`, exactly one parameter | `CSI ? Pd ; Ps $ y` per D3 |
  | DECRQM (ANSI) | `CSI Pd $ p`, exactly one parameter | `CSI Pd ; Ps $ y` per D3 |

  DA advertises plain VT100-with-AVO -- the pinned upstream bytes and the
  only honest identity: any richer ID string (VT220-class `?62;...c`)
  advertises feature tranches (NRCS, selective erase, printer) the engine
  does not implement, violating 04:54. DA with a nonzero parameter, DSR
  values other than 5/6, malformed DECRQM (zero or multiple parameters),
  and every other query-shaped sequence stay bit-identical no-ops.
  CPR/DECCPR report the cursor row relative to the positioning origin,
  1-based, and the 1-based column; pending wrap is not reflected (column
  stays the last column, as upstream). Origin-relative CPR is a deliberate
  deviation from pinned libvterm's absolute report, unobserved by any
  pinned case (the adopted CPR/DECCPR cases run with DECOM off): a program
  that homes inside a DECOM region must read back the coordinate system it
  is addressing in, matching DEC/xterm.
- **D3. DECRQM answer sets -- truth about implemented state, 0 for the
  rest.** DEC private: modes **6, 7, 25, 1047, 1049, 2026** answer 1 (set)
  or 2 (reset) from stored state -- 1047 and 1049 both report the single
  alt-screen-active flag. Everything else answers 0 (not recognized),
  including 1048 (a momentary save/restore action with no level; pinned
  libvterm agrees) and 2004/mouse modes until slice 5 implements them.
  ANSI: modes **4, 20** answer 1/2; everything else 0. The values 3/4
  (permanently set/reset) are never used: 0 is the honest answer for
  capabilities the engine does not implement, and it is what the pinned
  reference emits. Reporting 1049 truthfully (libvterm answers 0) is a
  deliberate unobserved deviation: DECRQM asks whether the mode is set,
  and 1049 is implemented with exactly that state. The DECRQM switch is
  the one extension point slice 5 grows (D12).
- **D4. Cursor visibility (mode 25).** New stored `Bool`, default visible.
  DECSET/DECRST 25 assign it. Like all modes it is a single copy shared
  across both screens (slice 1 I5 extends to it automatically; pinned
  libvterm keeps one `mode.cursor_visible` untouched by screen switches).
  Setting or resetting 25 does not clear pending wrap or the open cluster
  -- it is presentation-only, in the SGR class of operations.
- **D5. Cursor style (DECSCUSR, `CSI Ps SP q`).** New stored cursor
  appearance: shape (block, underline, bar) and blink, projected and
  consumed independently. Default: **steady block** -- the settled
  presentation contract (`09-renderer.md:20`), and the rule that only
  application-requested blinking creates periodic visual work. Mapping:
  omitted/0/1 -> blinking block, 2 -> steady block, 3 -> blinking
  underline, 4 -> steady underline, 5 -> blinking bar, 6 -> steady bar;
  values >= 7 and parameter counts > 1 are bit-identical no-ops.
  DECSCUSR moves nothing and clears no pending motion state. Shared
  across screens like every mode.
- **D6. Saved-cursor slot carries appearance.** `SavedCursorState` gains
  cursor visibility, shape, and blink; save (ESC 7, CSI s, 1048-set,
  1049-set) snapshots them; restore (ESC 8, CSI u, 1048-reset, 1049-reset)
  reapplies them. This pins libvterm's `savecursor` -- the already adopted
  `t/22state_save.test` asserts exactly this restore upstream; the fixture
  currently omits those assertions and this slice adds them. Deliberate
  deviation from the strict DEC DECSC list, pinned by an adopted upstream
  case. The slot default (fresh terminal, never saved) matches the live
  defaults, so a bare restore is appearance-neutral.
- **D7. Synchronized updates (2026).** New stored `Bool`, default inactive;
  DECSET/DECRST 2026 assign it; DECRQM-queryable per D3 (the query is the
  detection handshake). Set/reset clears no pending motion state and
  changes nothing else: the engine keeps applying every state change while
  active -- suppression is strictly a presentation-consumer concern
  (04:43). No timeout anywhere in the core: the core reads no clock by
  contract. Reset behavior per D10.
- **D8. Presentation projection and minimal wiring.** New public
  presentation value (`isCursorVisible`, cursor shape, cursor blink,
  `isSynchronizedOutputActive`) exposed as a computed projection on
  `Terminal`. `TerminalPaneSessionController.planIfNeeded` replaces the
  hardcoded presentation's `isCursorVisible` with the projected value and
  suppresses planning while `isSynchronizedOutputActive` is true. Because
  the last-planned snapshot stays stale during suppression, the update
  that clears the mode (or any later change) plans one complete current
  frame -- intermediate frames suppressed, final state never lost.
  **Child termination permanently releases synchronized-output
  suppression for that session:** once the child has exited, 2026 no
  longer suppresses planning, whatever the mode's stored value. A visible
  pane therefore plans its final frame at exit; a hidden pane plans
  nothing at exit (no rendering work for hidden panes, 13:27) and produces
  its complete frame on reveal (09:39). Either way a child that sets 2026,
  writes its last output, and exits without resetting still lands its
  final display (04:43). Release is permanent, not consumed by the
  exit-bearing update, precisely so a deferred reveal is not stranded.
  State reads (`readViewportText`, history, recovery) are
  never gated. Shape and blink are exposed but consumed only in slice 7;
  `RenderPresentation` itself does not change shape this slice.
- **D9. Host routing -- drain every feed, bypass the reducer, classify
  capture separately.** `applyOutput` drains the reply buffer immediately
  after `terminal.feed(bytes)` and before the `terminal != previousTerminal`
  comparison (a pure query then leaves the value unchanged and correctly
  emits no render wakeup), then hands the drained bytes straight to
  `enqueueInput`. Not via the reducer's `.sendInput` path: the reducer's
  gate is redundant (`applyOutput` only executes in running/draining
  states, and `enqueueInput`/`flushInput` already guard the closed
  master), and the reducer path would pollute `capturedInputWrites`, which
  is evidence of user-originated writes. When capture is on, drained
  replies are captured under their own classification, distinct from
  user-originated writes. Replies therefore reach the pty in feed order,
  ahead of any user input submitted later on the owner queue, and are
  dropped harmlessly once the master is closed.
- **D9a. Recording replay drains like the host.** Replaying a captured
  recording drains and discards the reply buffer after each replayed feed,
  exactly as the live host does. Recordings gain no reply payload: a
  reply's only observable downstream effect is what the child does with
  it, and that arrives as ordinary captured pty output in a later feed.
  This keeps replayed state exactly equal to live state (the Milestone 4
  capture invariant) without turning the recording format into a second
  reply channel.
- **D10. Reset matrix additions (normative).**

  | State | DECSTR (`CSI ! p`) | RIS (`ESC c`) |
  |---|---|---|
  | Cursor visibility | -> visible | -> visible |
  | Cursor shape/blink | -> steady block | -> steady block |
  | Synchronized updates (2026) | -> inactive | -> inactive |
  | Saved slot's appearance fields | preserved (whole slot preserved, as today) | preserved |
  | Undrained reply bytes | preserved (resets emit nothing and revoke nothing) | preserved |

  Resetting visibility/shape/blink unconditionally on both soft and hard
  reset pins `vterm_state_reset`; the reset *value* is DanTerm's steady
  block per D5, not libvterm's blinking block. 2026-inactive on both
  resets follows the house rule that both resets restore mode defaults;
  libvterm has no 2026 to pin.
- **D11. Fixture schema and manifest.** Fixture expectations gain the
  ability to assert the reply bytes emitted since the previous checkpoint
  -- mirroring upstream's per-PUSH `output` assertions, holding under every
  chunk strategy -- and to assert cursor visibility, shape, and blink.
  Schema changes are test-side only (checkpoint events stay payload-free in
  `NeutralTerminalRecordingEvent`). Manifest changes:
  - `t/26state_query.test` added to manifest and ledger, case-by-case:
    **adopted** -- DA, DSR, CPR (both PUSHes), DECCPR;
    **out-of-scope** -- XTVERSION (identity/version policy is Milestone 7),
    all six DECRQSS cases (DCS-carried replies), S8C1T on DSR (8-bit reply
    encoding unsupported; `ESC SP G` stays an absorbed no-op).
  - `t/15state_mode.test` "DECRQM on DECOM": out-of-scope -> **adopted**
    (reply asserted byte-for-byte).
  - `t/22state_save.test` adapted cases: stay **adapted**, but the fixture
    now asserts visibility/shape/blink and the rationales drop "omitting unsupported cursor appearance
    properties". These cases pin the save/restore round trip of explicitly
    set appearance; where an upstream assertion instead observes libvterm's
    blinking-block *default*, the case is adapted to DanTerm's steady-block
    default (D5) with that named in its rationale.
  - DECRQSS rationales in `t/12state_scroll.test`/`t/13state_edit.test`
    are refreshed to name the real boundary (DCS-carried DECRQSS replies
    deferred).
  - Recorded-deviation set: unchanged (this slice's deviations are
    unobserved by pinned cases and live in this plan, per house
    convention).
- **D12. Slice 5 seam.** No additional public API: slice 5's encoder state
  (DECCKM, keypad, 2004, 1004, mouse/Kitty) becomes stored mode state that
  D3's mode-query policy answers for, and the reply buffer is already the
  vehicle for any future core-emitted bytes (focus events, mouse reports).
  This slice's obligation is that mode-query policy stays a single
  authoritative answer set, not a second one grown alongside D3.

## Invariants

- I1 Regression: a byte stream containing none of this slice's sequences
  produces a `Terminal` bit-identical to today's, with an empty reply
  buffer throughout.
- I2 Reply determinism and chunk invariance: the cumulative reply stream is
  a pure function of fed bytes and explicit inputs; it participates in
  `Terminal ==`; identical event sequences yield identical reply bytes
  under every feed chunking, including queries split mid-sequence.
- I3 Reply honesty and closure: the engine emits exactly the D2/D3 bytes
  for exactly the D2-recognized forms and emits nothing else, ever --
  malformed or out-of-table queries (DA with nonzero parameter, DSR other
  than 5/6, DECRQM with parameter count != 1, XTVERSION, DECRQSS, DA2/DA3)
  leave the terminal bit-identical.
- I4 Query purity: a recognized query changes nothing but the reply buffer
  -- grid, cursor, pending wrap, open cluster, modes, styles, and saved
  slot are bit-identical before and after.
- I5 Presentation state semantics: visibility/shape/blink and 2026 follow
  D4/D5/D7; all are single-copy shared across screens (extending slice 1
  I5); DECSET/DECRST 25 and 2026 and DECSCUSR never clear pending wrap or
  the open cluster and never move the cursor.
- I6 Saved-cursor round trip: every save path snapshots visibility, shape,
  and blink; every restore path reapplies them; a save on one screen
  restores appearance on the other; DECSTR/RIS preserve the slot's
  appearance fields.
- I7 Synchronized updates: while 2026 is active every state change still
  applies (core) and no new frame is planned (session); the first plan
  after deactivation equals the plan of the final state; child termination
  permanently releases suppression, so a child that exits with 2026 still
  set yields its final frame at exit when visible and on reveal when
  hidden, with no rendering work while hidden -- intermediate presentation
  suppressed, final state changes never suppressed; state and history
  reads are never gated.
- I8 Resets: DECSTR and RIS behave exactly per the D10 matrix, and every
  row of the existing reset matrices is unchanged.
- I9 Host routing: reply bytes reach the pty in feed order ahead of later
  user input; they never appear in `capturedInputWrites` or
  `recentOutput`'s input side; a query that changes no other state emits
  no update signal; replies after master close are dropped without effect.
- I10 Projection fidelity: the presentation projection equals the stored
  state at every observation point; the planner emits a cursor iff the
  projected visibility is true.

## Proof obligations

Reuse the house harness: public-API unit suites, whole-value equality,
per-suite chunk-invariance helpers, the fixture replay runner, and the fuzz
sweeps. TDD per repo convention; every commit green.

- PO1 (I1) Regression: all existing suites and fixture replays pass with
  zero manifest edits beyond the D11 names; a no-query stream leaves the
  reply buffer empty.
- PO2 (I2, I3) Reply byte pinning: exact expected bytes for every D2 row,
  including DA default/zero parameter equivalence, CPR after cursor moves,
  CPR under DECOM with a scroll region (origin-relative pin), DECCPR's `?`
  prefix, and DECRQM over every D3 mode in both set and reset states --
  plus silence proofs for every I3 malformed/out-of-table form, asserted
  as whole-value bit-identity.
- PO3 (I2) Chunk invariance: query sequences split at every byte boundary
  replay to whole-value-equal terminals -- the buffer's membership in `==`
  makes this cover reply bytes; one case splits `CSI ? 2026 $ p`
  mid-parameter across feeds.
- PO4 (I4) Query purity: DSR/CPR/DECRQM issued mid-pending-wrap and
  mid-cluster leave both live (asserted through the next printed
  character) and leave the full value bit-identical modulo the buffer.
- PO5 (I5) Presentation state: the fresh-terminal steady-block default;
  25 and DECSCUSR value mapping including omitted/0/1 equivalence (blinking
  block, the one path that requests blink) and >= 7 no-ops; 2026 set/reset;
  all preserved
  across alt-screen switches in both directions; none clears pending wrap
  or moves the cursor; DECRQM 1047/1049 report 1 while alt is active and 2
  after exit (the slice-map "queries report alt-screen state truthfully"
  obligation).
- PO6 (I6) Saved cursor: hide + set steady bar, save, change everything,
  restore -- appearance returns; save-on-alt/restore-on-primary; upgraded
  `state-save` fixture assertions per D11.
- PO7 (I8) Resets: extend both `TerminalResetTests` matrices with hidden
  cursor + blinking underline + active 2026 before DECSTR and RIS,
  asserting the D10 rows (including the steady-block reset value) and slot
  preservation, plus post-reset DECRQM replies (25 -> 1, 2026 -> 2).
- PO8 (I7, I10) Session gating and wiring: with a hidden cursor the
  planned frame has no cursor; while 2026 is active successive snapshots
  plan nothing; deactivation plans exactly one frame equal to planning the
  final state directly; a child that sets 2026, writes final output, and
  exits without resetting yields one final frame matching its last state
  -- at exit when visible, and, for a pane hidden across the whole
  sequence, no frame at exit and one complete frame on reveal;
  viewport/history reads stay live during suppression. Proven at the
  planner and controller layers.
- PO9 (I9) Host routing and ordering: with a live `TerminalPTYHost`, a
  child issuing `CSI 6 n` observes the CPR reply *before* user bytes
  submitted after the query -- proving replies are not queued behind later
  input; the reply is captured under its own classification and never in
  `capturedInputWrites`; a reply-only feed emits no update signal.
- PO9a (I9) Capture/replay equality: a live capture of a query-bearing
  child replays to a terminal exactly equal to the host's snapshot,
  preserving the Milestone 4 capture invariant now that replies are part
  of `Terminal ==`.
- PO10 (I2, I3, I5) Fixtures: the adopted `26state_query` case families
  reproduce their reply bytes byte-for-byte under authored/bytewise/
  every-split chunkings; the DECRQM-on-DECOM flip
  replays inside the mode fixture; manifest coverage passes with the D11
  ledger additions and an unchanged deviation set.
- PO11 (I3, I4) Fuzz: extend the fuzz alphabet with DA/DSR/CPR/DECRQM/
  DECSCUSR/25/2026 fragments; sweep structural validity, no-trap, and a
  bounded-reply-growth assertion (reply bytes per feed bounded by a
  constant multiple of fed bytes).

Slice exit gate: `just test` green (all packages plus lint scripts), plus a
Milestone 6 slice 3 sub-bullet in `plan-terminal-engine/14-roadmap.md`
linking the promoted plan. Live sanity check, non-gating: in a Swift-engine
pane run `vim` (sends DA and waits) and confirm prompt-fast startup; run
`tput civis; sleep 2; tput cnorm` and watch the rendered cursor disappear
and return.

## Non-goals

- XTVERSION, secondary/tertiary DA, and any version/identity string
  (capability-manifest policy, Milestone 7).
- DECRQSS and all DCS-carried replies (parser absorbs DCS; the six
  `26state_query` DECRQSS cases and the 12/13 DECRQSS cases stay
  out-of-scope).
- 8-bit C1 reply encoding / S8C1T (`ESC SP F/G` remain absorbed no-ops).
- DEC modes 1 (DECCKM), 5 (DECSCNM), 12 (blink toggle), 69, 1004, 2004,
  and the mouse family -- slice 5 or later; DECRQM answers 0 for all of
  them until implemented.
- Cursor shape/blink rendering, blink scheduling, and any
  `RenderPresentation`/`RenderCursor` shape change (slice 7).
- A synchronized-update timeout anywhere (see AR2; slice 7 host policy).
- OSC-carried queries (OSC 10/11 color queries stay absorbed).

## Accepted risks

- AR1 Unanswered probes (XTVERSION, DA2, DECRQSS) stall some feature
  detection until the requester's own timeout. That is today's behavior
  for all queries; this slice removes the highest-traffic waits (DA,
  DSR/CPR, DECRQM) and the rest are policy work already assigned to later
  milestones.
- AR2 No 2026 timeout: a still-running application that sets 2026 and
  never clears it freezes the pane's presentation (state and reads stay
  live) until it deactivates the mode, issues a reset that deactivates it,
  or terminates -- further output does not thaw the pane. Termination is
  already bounded by D8's suppression release. Real emulators bound the
  live case with a clock; the core is clockless by contract and the
  session layer deliberately has no timer seam. Slice 7, which owns
  render-side clocks (blink), installs the bound.
- AR3 Deliberate deviations from pinned libvterm, none observed by a
  pinned case, all contract-level decisions recorded here rather than
  manifest deviations: origin-relative CPR (libvterm reports absolute),
  DECRQM answering truthfully for 1049 (libvterm answers 0), and the
  steady-block cursor default (libvterm defaults blinking block; DanTerm
  follows its own presentation contract, `09-renderer.md:20`).
- AR4 The reply buffer grows unboundedly for a hostless consumer that
  feeds queries and never drains. The production host drains every feed;
  fixtures are finite; PO11 bounds per-feed growth.
- AR5 Wiring visibility into the live render path can expose latent
  planner assumptions (cursor-free frames now occur under app control).
  PO8 pins the frames.

## Rejected ideas

- RI1 `feed` returning reply bytes: churns every call site, and replies
  fall out of `Terminal ==`, so every chunk-invariance and fixture
  equality proof would need a parallel accumulation channel.
- RI2 A delegate/closure output sink: breaks value semantics and
  `Sendable`/replay determinism; the core must not invoke callbacks
  mid-transition (03/04 contract).
- RI3 Routing replies through the reducer's `.sendInput` path: pollutes
  `capturedInputWrites` evidence and adds a reducer round trip for a gate
  `applyOutput`'s own execution context already provides.
- RI4 Reporting known-but-unimplemented modes as 4 (permanently reset):
  dishonest for modes slices 5-7 will implement, and diverges from the
  pinned reference's 0.
- RI5 Collapsing cursor shape and blink into one six-value DECSCUSR
  setting: the renderer and the saved slot consume shape and blink
  independently, and blink alone determines whether periodic visual work
  is scheduled.
- RI6 Excluding appearance from the saved-cursor slot (strict DEC DECSC):
  contradicts the adopted `t/22state_save.test`, whose upstream
  assertions pin appearance restore.
- RI7 A cumulative (since-start) fixture `output` assertion: diverges from
  upstream per-PUSH semantics and makes fixtures unreadable; the
  delta-since-last-checkpoint form maps one-to-one onto upstream lines.
- RI8 Gating frame suppression inside `RenderFramePlanner` instead of the
  controller: the planner is a pure frame function; suppression is a
  scheduling decision and belongs where frames are scheduled.
- RI9 Auto-draining replies inside `feed` via return value plus buffer
  (hybrid): two observation paths for one stream invite drift; one
  buffer, one drain.

## Implementation discretion

- Naming and exact API shape of the reply buffer, its drain, the
  read-only view, the presentation projection, and the host's reply
  capture accessor.
- Fixture representation and file layout for the adopted query cases --
  how reply and appearance expectations are encoded, and whether the cases
  live in one file or several -- matching sibling house style.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift`
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift`,
  `Fixtures/libvterm-manifest.json`, `Fixtures/libvterm/`
- `lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift`
- `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`
- `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalResetTests.swift`
- `plan-terminal-engine/14-roadmap.md` -- slice sub-bullet at exit

## Commit progress

- [x] 1. Add terminal presentation modes and synchronized frame gating:
  cursor visibility, shape/blink, mode 2026, saved-cursor and reset behavior,
  the presentation projection, session suppression and termination release,
  and their PO5-PO8 proofs.
- [ ] 2. Add core query replies and ordered PTY routing: the reply buffer,
  DA/DSR/CPR/DECCPR/DECRQM handling, host routing and capture classification,
  recording replay drain, and their PO2-PO4, PO9, PO9a, and PO11 proofs. The
  buffer's entry into `Terminal ==`, the host drain, and the replay drain land
  together so capture/replay equality is never broken between commits.
- [ ] 3. Adopt query and cursor-state conformance fixtures: fixture expectation
  support, adopted libvterm query/save cases, manifest and rationale updates,
  PO10, and the roadmap entry.

Every commit is green, with tests, fixtures, manifest entries, and docs
traveling with the behavior they cover.
