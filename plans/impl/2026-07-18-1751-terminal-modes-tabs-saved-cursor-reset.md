# Milestone 2 slice 7: terminal modes, tab stops, saved cursor, and reset behavior

## Context

Seventh implementation slice of Milestone 2, governed by
`plan-terminal-engine/04-terminal-core.md` ("cursor movement, wrapping, tabs,
margins", "saved cursor and terminal modes"), the neutral-fixture mandate in
`docs/research/1-external-tests.md` (whose Milestone 2 families name
`15state_mode`, `20state_wrapping`, `21state_tabstops`, `22state_save`,
`27state_reset`), and the slice 6 precedent
`plans/impl/2026-07-18-0425-terminal-scroll-regions.md`, whose "Left open"
list this slice consumes (DECOM, IRM, RIS/DECSTR resetting the region).

The gap: with grid, Unicode, reflow, styles, regions, and editing primitives
in place, the remaining viability hole is persistent terminal control state
that shells, less, and vim exercise constantly. Today the engine has
hardcoded every-8 tab stops, no terminal modes, no saved cursor, no reset,
and no REP.

Load-bearing premises (verified against the code and the pinned libvterm at
`934bc2fbf21800ac3458a499df8820ca5fb45fd3`):

- **No parser change is needed.** The absorber already emits ESC `7`/`8`/
  `H`/`c` as `.escape(final)` (EscapeAbsorber.swift:118-121) and already
  collects private markers `< = > ?` (0x3C-0x3F) and real intermediates
  (0x20-0x2F) into `CSISequence.intermediates`. This slice is dispatch- and
  state-layer only.
- `dispatchCSI` (Terminal.swift:592-662) drops every sequence with
  intermediates at line 593, so DEC private modes (`CSI ? 6 h`) and DECSTR
  (`CSI ! p`) cannot reach a handler today. The guard must become
  intermediate-aware routing; everything not explicitly routed stays a
  strict no-op.
- House convention (slice 6 D2): a recognized valid dispatch clears pending
  wrap + open cluster (`clearPendingMotionState`, Terminal.swift:948-951);
  an invalid/unsupported dispatch leaves the Terminal bit-identical.
- HT is hardcoded (Terminal.swift:930-936): next multiple of 8, capped at
  the last column. `moveCursor` (:215-220) clamps absolutely and is
  region-blind; `setScrollRegion` (:1192-1207) homes to absolute (0,0);
  `resize` (:119-131) resets the region before reflowing. The print path
  arms/consumes `isPendingWrap` unconditionally -- DECAWM must gate it.
- Reusable primitives: the print path (`print`/`printNarrow`/`printWide`)
  handles width, pending wrap, and BCE; `moveAndFillCells` is exactly the
  IRM insert-shift (BCE fill, severed-wide-pair repair, claim severing);
  the slice-6 seam machinery covers the RIS erase.
- libvterm reference semantics (src/state.c): DECOM set *and* reset home the
  cursor to the effective origin; `?1048` aliases save/restore-cursor; one
  shared reset routine serves RIS (hard) and DECSTR (soft) -- soft resets
  region, modes, tabs, and pen but keeps cursor, screen, and pending wrap;
  hard additionally homes, clears pending wrap, and erases in place; neither
  touches scrollback or the saved slot. Resize preserves tab stops in
  retained columns and defaults every-8 in new ones. REP re-emits the last
  printed cluster capped at the row end, arming pending wrap only under
  autowrap.
- The manifest already holds a placeholder this slice un-defers:
  30state_pen's "DECSTR resets pen attributes" is dispositioned
  out-of-scope with rationale "deferred beyond this Milestone 2 slice".

## Decision

### Dispatch surface

`dispatchCSI` routes on `(intermediates, final)`:

| Intermediates | Finals | Routing |
|---|---|---|
| `[]` | existing set + `h l g s u b` | ANSI handlers (SM/RM, TBC, save, restore, REP) |
| `[0x3F]` (`?`) | `h l` | DEC private set/reset |
| `[0x21]` (`!`) | `p` | DECSTR |
| anything else | anything | strict no-op, bit-identical (`\e[4 q`, `\e[?6$p` stay inert) |

`dispatchEscape` gains bare finals `7` (DECSC), `8` (DECRC), `H` (HTS),
`c` (RIS). All other ESC finals stay dropped bit-identically;
ESC-with-intermediate (DECALN `\e#8`) remains swallowed by the absorber.

### Normalization matrix (normative; a no-op row leaves the whole terminal bit-identical, side state included)

| Sequence | Params | Normalization |
|---|---|---|
| CSI h / l (SM/RM) | any list | per-param, left-to-right: `4` -> IRM, `20` -> LNM; every other value inert; zero recognized params (incl. empty list) => whole dispatch bit-identical; >=1 recognized => apply them + clear side state once |
| CSI ? h / l | any list | per-param, left-to-right: `6` -> DECOM, `7` -> DECAWM, `1048` -> save/restore-cursor; all others (`25`, `2004`, `1049`, mouse, ...) inert; zero recognized => bit-identical |
| CSI g (TBC) | none / `0` | clear stop at cursor column |
| CSI g | `3` | clear all stops |
| CSI g | any other value, or >1 param | no-op |
| ESC H (HTS) | -- | set stop at cursor column |
| ESC 7 / CSI s | CSI s with params => no-op | overwrite the single slot |
| ESC 8 / CSI u | CSI u with params => no-op | restore from the slot |
| CSI ? 1048 h / l | -- | exact aliases of DECSC / DECRC |
| CSI b (REP) | 0/missing -> 1; >1 param => no-op | repeat last printed cluster, capped at line end; huge counts terminate (loop bounded by line width) |
| CSI b | no previously printed cluster | bit-identical no-op |
| ESC c (RIS) | -- | hard reset per matrix |
| CSI ! p (DECSTR) | params present => no-op | soft reset per matrix |

### Mode semantics

- **IRM (SM/RM 4).** With insert on, each printed *cluster start* (narrow or
  wide, and each REP repeat) first shifts `[cursor.column, columns)` right by
  the cluster width through the existing horizontal move-and-fill primitive,
  then writes normally. Combining-mark appendage to an open cluster never
  shifts (fixture-pinned); cluster width upgrades never shift. Pending wrap
  resolves first: wrap, then shift on the new row. IRM does not alter
  ICH/DCH/erase.
- **LNM (SM/RM 20).** LF, VT, FF also carry the cursor to column 0. IND
  (ESC D) is unaffected (libvterm-conformant).
- **DECOM (CSI ? 6 h/l).** Origin flag; effective origin = active region top
  (region nil => row 0). Complete observable surface:
  - Set *and* reset home the cursor to the effective origin, clearing side
    state; redundant re-set still homes.
  - CUP/HVP/VPA: row parameter maps region-relative (`top + n - 1`) and
    clamps to `[top, bottom-1]`; columns map absolutely, clamped as today.
  - CUU/CUD/CNL/CPL/VPB: rows clamp to `[top, bottom-1]`.
  - CUF/CUB/CHA/HPB and HT: columns unaffected.
  - DECSTBM homes to the effective origin of the *new* region; with origin
    off, behavior is bit-identical to slice 6.
  - LF/IND/NEL/RI, scrolling, erase extents, IL/DL: unaffected.
  - Clamping is scoped to cursor-positioning operations rather than
    libvterm's global post-CSI clamp; given I3 the two are
    observation-equivalent.
- **DECAWM (CSI ? 7 h/l).** Default on. With autowrap off:
  - `isPendingWrap` is never armed; `?7l` clears an already-armed pending
    wrap.
  - A narrow cluster printed at the last column writes in place; the cursor
    stays pinned there; subsequent prints keep overwriting (fixture-pinned).
  - A wide cluster (including a width upgrade) that does not fit never
    wraps: it clamps to fit at `(cols-2, cols-1)`, overwriting, cursor on
    the head column (D4).
  - Re-enabling autowrap does not retroactively arm anything.

### Tab stops

Stored stop set, default at every column divisible by 8, participating in
equality. HT moves to the nearest stop strictly right of the cursor, else
the last column; it never wraps or scrolls, and keeps its existing
side-state behavior (clears the open cluster only when it moves; pending
wrap untouched). HTS sets a stop at the cursor column. Resize preserves
stops for retained columns, drops stops beyond a shrink, and defaults
every-8 stops in newly added columns (libvterm-conformant). RIS and DECSTR
both restore the every-8 default.

### Saved cursor (single slot; user-fixed superset)

Slot contents: absolute position, pen (`currentStyle`), pending wrap, origin
flag. Not saved: cluster attachment, DECAWM/IRM/LNM, tab stops, region.

| Operation | Semantics |
|---|---|
| DECSC / CSI s / ?1048h | Overwrite the slot with current values. Pure snapshot: mutates nothing but the slot -- pending wrap and open cluster survive, so save-then-print still wraps/attaches (recorded exception to the D2 gate) |
| DECRC / CSI u / ?1048l | Restore origin flag, then position (clamped to current geometry; additionally clamped into the active region when the restored origin flag is on), then pen; then `isPendingWrap := saved && DECAWM-on && restored column == cols-1`. Open cluster cleared. Non-destructive: restoring twice returns to the same point (fixture-pinned) |
| initial slot | (0,0), default pen, no pending wrap, origin off -- restore-before-save homes with a default pen |
| RIS / DECSTR / resize | never touch the slot (libvterm-conformant; AR2) |

Left-to-right param application makes `\e[?6;1048h` observable: home first,
then save the homed state.

### REP (CSI b)

Repeats the most recently printed grapheme cluster -- including combining
marks appended after the base landed, and any width upgrade -- as if the
cluster's scalars were fed again N times through the print path, with no
edge of its own: the count goes through `print` untouched, so it wraps,
scrolls and arms pending wrap exactly where the same characters typed by
hand would (`references/xterm/charproc.c:6152` loops the raw count through
`dotext`; ghostty pins the wrapping case in `test "Terminal: printRepeat
wrap"`). vte and tmux instead cap the count at the row's remaining columns;
DanTerm follows xterm. Print-path membership means REP honors IRM shifting
and BCE/wide conventions and leaves the last repeat as the open cluster
(D5). The last-cluster memory is stored state (participates in equality);
it survives movement and DECSTR; RIS clears it.

### Reset matrices (normative; nothing outside the table changes)

| State | RIS (ESC c) | DECSTR (CSI ! p) |
|---|---|---|
| cursor | home (0,0) | unchanged |
| pending wrap + open cluster | cleared | cleared (D2) |
| scroll region | cleared | cleared |
| IRM, LNM, DECOM | off | off |
| DECAWM | on | on |
| tab stops | default every-8 | default every-8 (AR1) |
| pen | default | default |
| viewport | erased in place with the freshly reset pen (reset pen first, then erase); soft-wrap flags cleared; no scrollback push | untouched |
| scrollback | count unchanged; byte-identical except the final row's wrap claim into erased row 0 is severed (slice-6 seam policy, the sole RIS exception to scrollback preservation) | untouched |
| saved slot | untouched | untouched |
| REP last-cluster memory | cleared | kept |

Ordering for RIS is normative: reset modes/tabs/region/pen -> home + clear
side state -> erase with the reset pen.

### Recorded deviations (from pinned libvterm)

- **D1** Saved-cursor superset: DanTerm saves/restores pending wrap and
  origin state (user-fixed); libvterm saves only position, cursor
  appearance, pen. Restore-time re-arming is triple-gated.
- **D2** Extension of the house side-state gate: every recognized valid
  slice-7 non-print operation clears pending wrap + cluster (including
  DECSTR, where libvterm preserves the phantom, and HTS/TBC/SM/RM, where
  libvterm clears only on movement). Three principled exceptions (the same
  set as I9): snapshot saves (DECSC/CSI s/?1048h, pure snapshot), REP
  (print-path member), and HT (retains its pre-slice side-state behavior).
- **D3** Plain SM/RM applies every parameter independently (xterm/ECMA-48);
  pinned libvterm applies only the first. No upstream case exercises it.
- **D4** DECAWM off never wraps anything, including wide clusters at the
  line edge (clamp-to-fit); libvterm accidentally wraps a non-fitting wide
  glyph with autowrap off. Upstream-unpinned edge.
- **D5** REP replays through the print path: honors IRM and opens cluster
  attachment on the last repeat; libvterm bypasses insert mode. No upstream
  case exercises it.
- **D6** TBC accepts only 0 and 3; all other values are bit-identical
  no-ops (xterm-aligned); libvterm treats 5 as clear-all and 1/2/4 as
  accepted-but-inert.

None of D1-D6 is exercised by an adopted upstream expectation, so the
manifest `recordedDeviations` set is unchanged; new fixtures carry empty
per-fixture deviation lists.

## Invariants

- I1 Param independence and inertness: SM/RM/DECSET/DECRST apply recognized
  parameters left-to-right, each independent of unrecognized neighbors; a
  dispatch whose entire parameter list is unrecognized -- and any dispatch
  with unrouted intermediates -- leaves the terminal bit-identical, side
  state included.
- I2 Autowrap gate: `isPendingWrap` is armed only while DECAWM is on; no
  print, wrap-upgrade, or REP path ever wraps while DECAWM is off; `?7l`
  clears an armed pending wrap.
- I3 Origin confinement: while DECOM is on, the cursor row remains within
  the active region after every operation; DECOM never affects columns and
  never affects erase or scroll extents.
- I4 Tab model: HT targets the nearest stop strictly right of the cursor,
  else the last column, never wrapping or scrolling; stops participate in
  equality; resize preserves retained stops and defaults new columns;
  RIS/DECSTR restore the every-8 default; with default stops HT is
  bit-identical to pre-slice behavior.
- I5 Slot fidelity: exactly one slot holding {absolute position, pen,
  pending wrap, origin flag}; save overwrites without disturbing any other
  state; restore is repeatable, re-clamps against current geometry (and
  region when restored origin is on), and re-arms pending wrap only under
  the triple gate; nothing but save operations mutates the slot.
- I6 Reset totality and locality: RIS and DECSTR change exactly the state
  named in the reset matrix; scrollback count and the saved slot are
  unchanged across both; RIS's erase pushes nothing and uses the freshly
  reset pen, and its only scrollback mutation is severing the final row's
  wrap claim into erased row 0; DECSTR leaves scrollback fully untouched.
- I7 IRM locality: each insert-shift affects only `[cursor.column, cols)`
  of the cursor row, severed wide pairs become BCE padding, the row's
  continuation claim severs, and combining appendage never shifts; the
  structural grid contract holds afterwards.
- I8 REP fidelity: REP reproduces the last printed cluster (scalars, width,
  current pen at repeat time) exactly N times capped at the line end; with
  no prior cluster (fresh terminal or post-RIS) it is bit-identical.
- I9 Side-state gate: every recognized valid slice-7 non-print operation
  clears pending wrap and open cluster (restore reapplies the saved pending
  wrap after positioning); the exceptions are snapshot saves, REP, and HT
  (which retains its pre-slice side-state behavior -- pending wrap untouched,
  open cluster cleared only when it moves); invalid dispatches are
  bit-identical (I1).
- I10 Equality and chunk invariance: all new state (mode flags, tab stops,
  saved slot, REP memory) participates in `Terminal ==`; every new sequence
  -- including split ESC 7/8/H/c and marker-bearing CSI -- replays
  chunk-invariantly to whole-value-equal terminals; `expectValidGrid`
  passes after every operation.

## Proof obligations

Reuse the house harness (public-API suites, `expectValidGrid`, whole-value
equality, fixture replay, fuzz sweeps, the bit-identical no-op patterns).
TDD per repo convention: failing test first, every commit green.

- PO1 (I1, I4) Regression: all existing suites pass unchanged; with default
  stops, modes at defaults, and no saves, every pre-slice behavior is
  bit-identical.
- PO2 (I1, I9) Mode param matrix: `\e[4;20h` sets both; recognized+unknown
  mixes apply the recognized ones; empty lists, wholly-unknown lists
  (`\e[?25h`, `\e[?2004h`), and unrouted intermediates (`\e[4 q`,
  `\e[?6$p`, `\e[1!p`) are bit-identical mid-pending-wrap and mid-cluster;
  a >=1-recognized dispatch clears both unless it is an I9 exception --
  in particular a snapshot save (`?1048h`) issued mid-pending-wrap and
  mid-cluster preserves both.
- PO3 (I7) IRM: shift-on-print with style travel; combining-once
  (fixture-pinned); a narrow cluster upgrading to wide (VS16) beside
  sentinel content performs no second insert-shift; wide pair severed at
  the right edge; pending-wrap wrap-then-insert ordering; no structural
  violations.
- PO4 (I9) LNM: LF, VT, FF each gain carriage return when set; IND does
  not; reset restores plain behavior.
- PO5 (I3) DECOM: the fixture positions (region 5..15: `\e[H` -> (4,0),
  `\e[3;3H` -> (6,2), `\e[10A` -> (4,0), `\e[20B` -> (14,0)); set/reset
  homing incl. region-nil; DECSTBM homing to the new origin; columns
  unaffected; confinement sweep across LF/RI/print/restore under an active
  region.
- PO6 (I2) DECAWM: off pins narrow overwrite at the last column with
  pendingWrap false; `?7l` mid-pending clears it and the next print
  overwrites instead of wrapping; wide clamp-to-fit at the edge (D4);
  re-enabling restores normal arm/wrap.
- PO7 (I4, I10) Tabs: HT walks custom stops; HT at the last column with
  pending wrap armed leaves pending wrap set and does not overwrite (its
  pre-slice side-state exception, I9); HTS at arbitrary columns; TBC 0 at
  the cursor only; TBC 3 then HT lands on the last column; junk TBC values
  bit-identical; resize preserve/extend/shrink; two terminals differing
  only in stops compare unequal.
- PO8 (I5, I10) Saved cursor: full-slot round trip; overwrite-on-second-save
  and repeatable restore (fixture-pinned); restore-before-save applies
  defaults; restore clamps after region shrink and after resize; the
  pending triple gate; `s`/`u` and `?1048` aliases; `\e[?6;1048h` ordering.
- PO9 (I6) Resets: the full RIS matrix including in-place erase with the
  reset pen, unchanged scrollback count with only the final-row seam into
  erased row 0 severed, tab/mode/region/pen restoration; the full DECSTR
  matrix including kept cursor, kept screen, kept slot, fully-untouched
  scrollback, reset tabs; REP-after-RIS bit-identical.
- PO10 (I8) REP: all seven upstream cases (default/zero counts, combining
  cluster repeats as one unit, wide advances two columns, fill-to-line-end
  arms pending and the next glyph wraps); REP after cursor movement still
  repeats; huge counts terminate; REP with pending armed; REP with DECAWM
  off; REP under IRM (D5).
- PO11 (I10) Fuzz: extend both fuzz alphabets with slice-7 bytes
  (`! b g h l p s u`) and fragments (`\e[4h`, `\e[20h`, `\e[?6h\e[?6l`,
  `\e[?7l\e[?7h`, `\e[?1048h\e[?1048l`, `\eH`, `\e[3g`, `\e7\e8`,
  `\e[s\e[u`, `\e[5b`, `\ec`, `\e[!p`); sentinel visibility and
  `expectValidGrid` hold across all seeds.
- PO12 (I10) The six new upstream source families replay through
  provenance-bearing fixtures under all chunk strategies with all
  expectations; `libvtermManifestCoverage` passes with those six families
  fully dispositioned and the 30state_pen DECSTR upgrade.

Left open for later slices: alternate screen (?47/?1047/?1049 including
1049's save half), DECRQM/DECRPM/DA and every reply channel, DECSLRM/?69
horizontal margins, cursor appearance (?25/?12/DECSCUSR), DECSCNM, DECCKM
and keypad modes, mouse modes, bracketed paste (2004), CHT/CBT, DECALN,
scrollback limits.

## Non-goals

- Query replies of any kind (DECRQM `$p`, DECRQSS, DA) -- the engine has no
  output channel yet; the sequences stay bit-identical no-ops.
- DECSLRM/DECLRMM and the two upstream cases depending on them; CSI s is
  save-cursor here, unconditionally.
- Cursor visibility/blink/shape (?25/?12/DECSCUSR) and their save/restore
  -- the 22state_save termprop assertions are dropped in translation.
- Altscreen: ?47/?1047/?1049 are unrecognized-inert, including 1049's
  save-cursor half.
- CHT/CBT (CSI I / Z): absent from user scope and from the six upstream
  files; the stop set makes them trivial later.
- Public exposure of modes/tabs/slot through `TerminalGeometry` -- behavior
  is asserted through existing views; equality covers the state.

## Accepted risks

- AR1 DECSTR resets tab stops (libvterm-following, contra DEC spec). Real
  applications essentially never rely on tabs surviving soft reset.
- AR2 RIS/DECSTR preserve the saved slot (libvterm-following; xterm's RIS
  clears it). A stale restore after RIS lands on a clamped valid position.
- AR3 D2-uniform clearing on HTS/TBC/SM/RM mid-pending-wrap differs from
  libvterm's movement-gated clearing (same class as slice-6 precedent).
- AR4 Plain-SM multi-param application (D3) diverges from the pinned
  reference; xterm/ECMA conformance is preferred deliberately.
- AR5 REP-through-print-path (D5) and the DECAWM-off wide clamp (D4) are
  upstream-unpinned edges; deterministic, unit-pinned, easy to flip if
  incumbent-behavior traces disagree.
- AR6 The saved-cursor superset (D1) can re-arm pending wrap where no
  reference terminal would; the triple gate confines it to the exact
  geometry where wrapping is meaningful.

## Rejected ideas

- RI1 libvterm's global post-CSI origin clamp: scoped clamping plus I3 is
  observation-equivalent and keeps positioning logic in one place.
- RI2 Storing the saved position origin-relative: absolute storage with
  restore-time clamping survives region changes between save and restore
  and avoids a second coordinate system.
- RI3 Clearing pending motion state on DECSC (full D2 uniformity): a
  snapshot that disarms the wrap it just saved would make save-then-print
  overwrite where every reference wraps.
- RI4 Matching libvterm's plain-SM first-param-only quirk: ECMA-48/xterm
  apply all parameters; the quirk buys no fixture.
- RI5 Implementing ?1049's save half now: altscreen semantics are a later
  milestone; partial 1049 would change observable behavior again.
- RI6 A saved-cursor stack: single slot is the universal contract and the
  fixture pins overwrite semantics.
- RI7 Deriving REP's cluster from the grid cell behind the cursor as the
  normative mechanism: explicit last-cluster state keeps REP correct after
  the source cell is scrolled or erased (the mechanism itself remains
  discretion so long as I8 holds).

## Implementation discretion

- Representation of mode flags, tab stops, the saved-slot struct, and REP's
  last-cluster memory -- provided all participate in synthesized equality.
- Whether SM/RM and DECSET/DECRST share a param loop; where origin-mapping
  lives.
- Fixture file grouping, and whether RESET-separated upstream cases become
  `\ec` feeds inside one fixture or separate fixture files.

## Fixtures and manifest

New provenance-pinned fixtures under
`Tests/TerminalCoreTests/Fixtures/libvterm/` (pinned to
`934bc2fbf21800ac3458a499df8820ca5fb45fd3`, empty per-fixture deviation
lists, callback assertions translated to
viewportText/cursor/scrollbackCount/currentStyle expectations) cover the six
new upstream source families -- 15state_mode, 20state_wrapping,
21state_tabstops, 22state_save, 27state_reset, 31state_rep -- plus the
existing `state-pen.json` extended with 30state_pen's DECSTR pen-reset
events. File grouping is discretion (see below).

Dispositions (every upstream case name enters the manifest and the runner's
`expectedCases`, kept in lockstep):

- `t/15state_mode.test`: Insert/Replace Mode -- adopted; Insert mode only
  happens once for UTF-8 combining -- adopted; Newline/Linefeed mode --
  adopted; DEC origin mode -- adopted; DECRQM on DECOM -- out-of-scope
  (query replies); Origin mode with DECSLRM -- out-of-scope (horizontal
  margins); Origin mode bounds cursor to scrolling region -- adapted
  (upstream inherits region+DECOM through the skipped DECSLRM case; the
  fixture re-establishes `\e[5;15r` + `\e[?6h` directly); Origin mode
  without scroll region -- adopted.
- `t/20state_wrapping.test`: 79th Column; 80th Column Phantom; Line
  Wraparound; Line Wraparound during combined write -- adopted (re-pins
  slice 3/4 phantom behavior through the neutral pipeline); DEC Auto Wrap
  Mode -- adopted; 80th column causes linefeed on wraparound -- adopted
  (bottom wrap on the full screen scrolls with a scrollback push, per the
  settled slice-6 policy); 80th column phantom linefeed phantom cancelled
  by explicit cursor move -- adopted.
- `t/21state_tabstops.test`: Initial; HTS; TBC 0; TBC 3 -- adopted;
  Tabstops after resize -- adopted (upstream RESET+RESIZE 30,100 becomes a
  fresh fixture with a resize event to 100x30; passes under the
  preserve-retained stop policy).
- `t/22state_save.test`: Set up state -- adopted; Save -- adopted (?1048h);
  Change state -- adapted (`\e[4 q` DECSCUSR bytes still fed and required
  bit-identical; termprop expectations dropped); Restore -- adapted
  (cursor + pen retained; visibility/blink/shape termprops dropped);
  Save/restore using DECSC/DECRC -- adapted (termprops dropped); Save
  twice, restore twice happens on both edge transitions -- adapted
  (termprops dropped; pins single-slot overwrite and repeatable restore).
- `t/27state_reset.test`: RIS homes cursor -- adopted; RIS cancels
  scrolling region -- adopted (scrollrect callback translates to
  post-`\e[25H\n` viewport/scrollback state); RIS erases screen -- adopted
  (blank viewport with unchanged scrollbackCount pins in-place erase); RIS
  clears tabstops -- adopted.
- `t/31state_rep.test`: all seven cases -- adopted.
- `t/30state_pen.test`: "DECSTR resets pen attributes" flips out-of-scope
  -> adopted; all other entries unchanged.

Cases with no upstream analog (DECAWM-off wide clamp, `?7l` mid-pending,
restore clamping, REP x IRM, the DECSTR matrix beyond the pen) live in unit
suites, not fixtures (provenance requires an upstream case).

## Verification

- Fixture replay provides authored/bytewise/exhaustive-split chunk
  invariance and whole-value equality automatically; split-ESC (`\e` / `7`)
  cases ride the existing invariance sweeps.
- Slice exit: `just test` green (all packages + lint scripts), then update
  `plan-terminal-engine/14-roadmap.md`: add the checked slice 7 entry
  linking the promoted plan, and review the Milestone 2 core gates -- the
  control/screen/mode/style gate and the determinism gate are expected to
  close with this slice; the external-tests tranche gate closes only if the
  remaining Milestone 2 families are judged already dispositioned or
  explicitly deferred -- record the judgement either way.

## Commit progress

- [x] 1. Add terminal mode semantics
- [x] 2. Add tab stops and saved cursor
- [x] 3. Add REP and terminal reset semantics
- [x] 4. Adopt terminal-state fixtures and complete the slice gate
