# Milestone 2 slice 6: scrolling regions and editing operations

## Context

Sixth implementation slice of Milestone 2, governed by
`plan-terminal-engine/04-terminal-core.md` (scroll regions, line/character
editing, background-color erase),
`plan-terminal-engine/05-unicode-grid-scrollback.md` (wide-cell invariants,
soft/hard line identity, scrollback semantics), the neutral-fixture mandate in
`docs/research/1-external-tests.md`, and the slice 5 precedent
`plans/impl/2026-07-18-0235-terminal-presentation-sgr.md`.

The gap: the engine has exactly one scroll behavior -- a hard-coded
full-screen scroll-up inside `advanceToNextRow` -- and no editing operations.
The screen-oriented programs in the Milestone 4 viability slice (`less`,
`vim`, shells with sticky status lines) drive DECSTBM regions, IND/NEL/RI,
SU/SD, and ICH/DCH/IL/DL constantly. This slice adds all of them around one
shared clipped move-and-fill primitive, plus ED 3 (clear scrollback), and
completes the scroll/edit tranche of the libvterm adoption ledger.

Load-bearing premises (verified against the code):

- `lib/TerminalCore` is a pure Swift package; the purity lint forbids all
  imports in `Sources` (Foundation appears only in tests).
- `public struct Terminal: Equatable, Sendable` has synthesized `==` over
  stored state; the fixture runner asserts final whole-value equality across
  chunkings, so new region state participates in equality automatically --
  and must, or chunk-invariance goes blind.
- `advanceToNextRow()` (Terminal.swift:1129-1136) is the only scroll site: at
  the bottom row it appends `rows.removeFirst()` to `scrollbackRows` and
  appends a `backgroundEraseStyle` blank row. Callers: `lineFeed()`
  (1125-1127, reached from LF/VT/FF), `softWrap()` (1117-1123), `printWide`
  (1078), `upgradeClusterToWide` (1014). The wrap paths set
  `isSoftWrapped = true` and (for wide wraps) write a `spacerHead` before
  advancing.
- BCE machinery exists and is wide-safe: `backgroundEraseStyle` (84-89),
  `eraseCells(row:columns:)` (219-238) expanding across intersected wide
  pairs, `clearCellAndPair` (1163-1192), and `clearPreviousSpacer`
  (1194-1208), which already mutates `scrollbackRows.last` -- precedent for
  seam repair touching retained history.
- `dispatchCSI` (588-638) early-returns on non-empty intermediates and drops
  unknown finals via `default: break`; ED mode 3 is currently a no-op. New
  CSI finals slot in: `r` 0x72, `S` 0x53, `T` 0x54, `@` 0x40, `P` 0x50,
  `L` 0x4C, `M` 0x4D. The existing `movementAmount` helper already enforces
  "at most one parameter, 0 -> 1".
- `EscapeAbsorber.swift` swallows bare ESC finals: in state `.escape` the
  range at line 117 clears and returns to ground with no event. IND (ESC D),
  NEL (ESC E), RI (ESC M) need a new absorber event, a matching stream
  action (`TerminalInputStream.swift`), and routing in `Terminal.feed`
  (102-113). The absorber buffers inside `inputStream`, a stored `Terminal`
  property, so split ESC sequences are chunk-invariant with no extra work.
- `moveCursor(row:column:)` (211-216) clamps absolutely to the viewport and
  clears pending wrap -- CUP/CHA/VPA/HVP are region-blind today and stay so
  (no DECOM).
- `resize` (116-127) early-returns when dimensions are unchanged;
  `resizeHeight` (240-279) pushes displaced rows to scrollback and pulls rows
  back when growing; `resizeWidth` (281-377) rebuilds one logical stream from
  `scrollbackRows + rows` and re-splits it.
- `expectValidGrid`/`expectValidRow` (`TerminalGridAssertions.swift`)
  machine-check wideHead/wideTail adjacency and that spacerHead appears only
  at the last column of a soft-wrapped row whose successor row begins with a
  wideHead. Any seam policy that clears a wrap flag but leaves a spacer (or
  vice versa) fails these assertions.
- Fixture infrastructure: versioned JSON fixtures under
  `Tests/TerminalCoreTests/Fixtures/libvterm/`, replayed under
  authored/bytewise/exhaustive-split chunkings; `libvtermManifestCoverage`
  pins `libvterm-manifest.json` against a hardcoded `expectedCases`
  dictionary and an exact `recordedDeviations` set
  (`TerminalFixtureTests.swift`) -- new files require updating manifest JSON,
  dictionary, and deviation set together.
- Upstream corpus verified locally at `references/libvterm/t/` (pinned commit
  `934bc2fbf21800ac3458a499df8820ca5fb45fd3`): `12state_scroll.test` titles
  "Scroll Down"/"Scroll Up" are inverted relative to the SU/SD mnemonics
  (bytes are `\e[S` / `\e[T`); its "Index in DECSTBM" case actually exercises
  RI in a 9;10 region and its "Reverse Index in DECSTBM" case actually pins
  LF at the physical bottom below a region as a no-op; `13state_edit.test`
  "IL" carries the upstream TODO pinning xterm's keep-cursor-column behavior;
  `\e[100S` pins clamp-to-full scroll.

## Decision

- **One shared clipped move-and-fill primitive is the architectural center.**
  Mirroring libvterm's `vterm_scroll_rect` shape, a single contract that:
  (a) clamps the delta to the range extent; (b) degenerates to pure BCE erase
  when |delta| >= extent -- with the scrollback hook still receiving the
  vacated source rows in the one path that pushes, so `\e[100S` on a full
  screen pushes exactly `rows` rows; (c) moves the surviving sub-range intact
  (scalars, kinds, styles, wrap flags travel); (d) BCE-fills the vacated
  strip; (e) repairs wide-cell pairs severed at either boundary of a
  horizontal move (severed half becomes BCE padding); (f) applies the
  wrap-flag seam policy for vertical moves; (g) exposes a scrollback hook
  used only by the full-screen upward scroll path, preserving a single push
  site. Vertical users: line advance at the bottom margin (LF/VT/FF, IND,
  NEL, soft wrap, wide-wrap), RI, SU, SD, IL, DL. Horizontal users: ICH,
  DCH. Duplicated cell-shifting logic anywhere is a plan violation.
- **Region state and DECSTBM (CSI r).** `Terminal` gains private vertical
  margin state ("no region" is equivalent to full screen). Arguments are
  1-based inclusive, defaults top=1, bottom=rows; `top==1 && bottom==rows`
  normalizes to "no region", so a region of height 1 cannot exist. DECSTBM
  homes the cursor to absolute (0,0) -- no DECOM -- which also clears pending
  wrap. The cursor may afterwards legally sit outside the region (e.g. home
  above a region whose top > 1); line advance and RI walk it in and pin it at
  the margins; absolute positioning stays region-blind.
- **Clamping matrix** (normative; strict arity per house convention; a
  no-op row leaves the whole terminal bit-identical, side state included):

  | Sequence | Params | Normalization |
  |---|---|---|
  | CSI r | none / 0s / missing | top=1, bottom=rows -> full (region cleared) |
  | CSI r | one param `t` | top=t, bottom=rows |
  | CSI r | `t;b` | clamp t to >= 1, b to <= rows; if b <= t after clamping -> full (covers inverted `5;2` and out-of-range `100;105`) |
  | CSI r | more than 2 params | no-op |
  | CSI S / CSI T | 0 or missing -> 1; more than 1 param -> no-op (also avoids the xterm highlight-tracking `CSI Ps;...;Ps T` collision) | count clamped to region height; >= height -> whole-region BCE erase (full-screen SU still pushes `height` rows) |
  | CSI @ / CSI P | 0 or missing -> 1 | count clamped to `columns - cursor.column`; >= remainder -> BCE erase of `[cursor.column, columns)` |
  | CSI L / CSI M | 0 or missing -> 1 | count clamped to rows remaining through the bottom margin; >= extent -> BCE erase of that strip |
  | CSI 3 J | exactly `3` (ED arity guard unchanged) | clear scrollback only |

- **Per-operation semantics** (all match libvterm at the pinned commit unless
  a deviation is recorded; a guard suppresses only the grid effect -- the
  side-state policy still applies):

  | Op | Guard | Effect | Cursor | Scrollback |
  |---|---|---|---|---|
  | LF/VT/FF, IND | -- | at bottom margin: region scrolls up 1; else below `rows-1`: row+1; at physical bottom outside region: no movement | column unchanged | pushes only if region is full screen |
  | NEL | -- | as LF, then column 0 | column 0 | as LF |
  | RI | -- | at top margin: region scrolls down 1; else row-1 floored at 0 | column unchanged | never |
  | SU (CSI S) | none -- cursor-independent | region scrolls up n | unchanged | pushes only if region is full screen |
  | SD (CSI T) | none -- cursor-independent | region scrolls down n | unchanged | never |
  | ICH (CSI @) | cursor row within region, else no grid effect | cells `[cursor.column, columns)` shift right n, BCE fill at cursor | unchanged | never |
  | DCH (CSI P) | cursor row within region, else no grid effect | cells shift left n, BCE fill at right edge | unchanged | never |
  | IL (CSI L) | cursor row within region, else no grid effect | rows from cursor through bottom margin scroll down n | row AND column unchanged (D4) | never |
  | DL (CSI M) | cursor row within region, else no grid effect | rows from cursor through bottom margin scroll up n | row AND column unchanged | never (D1: even at row 0) |
  | ED 3 (CSI 3 J) | -- | scrollback cleared; viewport, region untouched | unchanged | -> 0 |

- **Strict full-screen scrollback policy (user-settled -- do not revisit).**
  Among control-driven scroll and edit operations, rows enter scrollback if
  and only if the scroll region equals the full screen AND content scrolls
  upward (line advance at the bottom margin, or SU). Region-bounded scrolls
  -- including top-anchored regions -- and IL, DL, RI, SD never push. The
  primitive's scrollback hook is the single decision site for those
  operations. `resizeHeight`'s history transfers are the separate, preserved
  resize mechanism, outside this policy.
- **Dispatch side-state policy (one gate, recorded as D2).** A syntactically
  invalid or unsupported dispatch (an arity-violating clamping-matrix row, an
  unknown final, a non-D/E/M ESC final) leaves the whole terminal
  bit-identical -- no grid, cursor, or side-state change. Every recognized
  valid slice-6 operation (DECSTBM, SU, SD, ICH, DCH, IL, DL, ED 3, IND,
  NEL, RI) clears both pending wrap and any open grapheme cluster
  attachment, uniform with the house convention (EL/ED/ECH already clear
  both via `clearPendingMotionState`), including when a region guard
  suppresses the grid effect.
- **Wrap-flag seam policy (observable level).** Soft-wrap claims travel with
  their rows; vacated rows are never soft-wrapped. A claim survives an
  operation iff the claiming row and its continuation row remain adjacent in
  the scrollback+viewport stream afterwards; a claim whose continuation row
  was destroyed or displaced is severed. A wrap in progress at a scroll
  margin (soft wrap or wide-wrap that itself triggers the scroll) establishes
  its claim on the row that ends up immediately above the cursor, so wrapped
  printing across a scrolling margin always projects as one logical line in
  `fullHistoryText`. Concrete seams covered: the row above the region top
  when the region's top row is destroyed (scroll-up); the moved former-bottom
  row that claimed continuation into a below-region row (scroll-up); the row
  above an inserted blank strip (scroll-down/IL); the last surviving row of a
  scroll-down whose continuation was destroyed; and `scrollbackRows.last`
  when viewport row 0 is destroyed without being pushed or is displaced by
  inserted blanks -- severing there mutates retained history (flag and any
  trailing spacerHead together), following the `clearPreviousSpacer`
  precedent. When row 0 is pushed (full-screen scroll), adjacency is
  preserved and nothing is severed.
- **Wide-cell and spacer repair.** Vertical moves shift whole rows -- wide
  pairs never split. Horizontal shifts reduce any wide pair severed at the
  cursor-column boundary or the row edge to BCE padding on the surviving
  half; ICH/DCH additionally sever the row's continuation claim (flag false,
  trailing spacerHead to padding -- house EL0/ECH precedent). After every
  operation the structural grid contract holds: no dangling halves, ever.
- **ED 3.** Clears retained scrollback only; viewport, cursor, and region
  untouched (side state cleared per D2). A viewport row 0 that was a
  continuation of cleared history simply becomes the start of
  `fullHistoryText`; `clearPreviousSpacer`'s scrollback guard already
  tolerates the empty array.
- **ESC dispatch surface.** The absorber gains an event for bare ESC finals
  reaching ground (syntax only -- it still interprets nothing); the stream
  action enum and `Terminal.feed` route it; `Terminal` handles D/E/M and
  drops all other ESC finals as today. ESC-with-intermediates remains
  swallowed.
- **Resize resets the region.** Any actual dimension change resets the region
  to full screen before the existing height/width machinery runs, so all
  reflow (including `resizeHeight`'s scrollback pull and `resizeWidth`'s
  one-stream rebuild) operates region-free, exactly as today. The
  equal-dimensions early return does not reset (pinned by test). Ordering is
  normative: reset first, then reflow.
- **Recorded deviations:**
  - **D1** Strict full-screen scrollback push. libvterm and Alacritty push
    for any scroll strip anchored at absolute row 0 full width (top-anchored
    regions; DL at row 0); Ghostty (the incumbent) pushes for top-anchored
    full-width regions. DanTerm never pushes from a bounded region. Enters
    the manifest `recordedDeviations` set and each affected fixture's
    provenance.
  - **D2** Uniform side-state clearing on valid operations. libvterm clears
    `at_phantom` only when an operation actually moves the cursor
    (`updatecursor` early-returns on unchanged coordinates, state.c:33), so
    cursor-stationary ICH/DCH/IL/DL/SU/SD/ED 3 preserve it there, while
    DECSTBM's homing normally clears it; Ghostty's scrollUp also preserves
    it. DanTerm clears pending wrap and cluster attachment on every
    recognized valid slice-6 operation, cursor-stationary or not. Enters the
    manifest set.
  - **D3** Strict CSI arity: DECSTBM with more than 2 params and S/T with
    more than 1 param are no-ops where libvterm ignores extras (continuation
    of the slice 5 strictness precedent). Plan-level record; no upstream case
    exercises it.
  - **D4** IL/DL keep the cursor column (xterm/libvterm behavior, pinned by
    the upstream IL case's TODO), deviating from ECMA-48 line-home.

## Invariants

- I1 Locality: an operation modifies only its affected range (region rows, or
  the cursor-to-edge cell run), the defined seam repairs on the immediately
  preceding row or `scrollbackRows.last`, and the adjacent surviving half of
  any wide pair intersected by a horizontal operation boundary (e.g. the
  `wideHead` at `cursor.column - 1` when the operation starts on its
  `wideTail`); all other cells, rows, and scrollback content are
  bit-untouched.
- I2 Single push site: among slice-6 scroll/edit operations, `scrollbackRows`
  grows only via full-screen upward scroll (line advance at the bottom margin
  or SU with no region in effect); every other slice-6 operation leaves
  `scrollbackRowCount` unchanged; ED 3 sets it to zero; `resizeHeight`'s
  preserved shrink transfers sit outside this invariant. Pushed rows are
  bit-identical to the rows that left the viewport.
- I3 BCE fill: every cell vacated by a slice-6 operation is padding carrying
  the pen's foreground/background with attributes cleared, including both
  halves of any severed wide pair.
- I4 Move fidelity: cells and rows that survive a move are bit-identical to
  their sources -- scalars, kinds, styles, and (for rows) wrap flags travel.
- I5 Structural validity: the grid contract checked by `expectValidGrid`
  passes after every operation -- wide pairs adjacent, spacerHead only at the
  last column of a soft-wrapped row whose successor row begins with a
  wideHead -- in viewport and scrollback.
- I6 Logical-line coherence: `fullHistoryText` never joins content across an
  operation-created seam, and never loses the join of a wrap in progress at a
  scrolling margin; `softWraps`/`scrollbackRow` flags agree with the
  projection.
- I7 Cursor and side-state policy: DECSTBM homes to absolute (0,0);
  SU/SD/ICH/DCH/IL/DL/ED 3 leave the cursor position unchanged; every
  recognized valid slice-6 operation clears pending wrap and open cluster
  attachment (even when its region guard suppresses the grid effect);
  syntactically invalid or unsupported dispatches leave the terminal
  bit-identical; LF/IND/NEL/RI move per the semantics table; CUP/CHA/VPA/HVP
  remain region-blind.
- I8 Chunk invariance and equality: region state participates in
  `Terminal ==`; every new sequence -- including two-byte ESC finals split
  across feeds -- replays chunk-invariantly to whole-value-equal terminals.
- I9 Degenerate safety: every row of the clamping matrix terminates in the
  clamped effect or a pure BCE erase; no parameter combination traps or
  corrupts state; deferred sequences (DECSLRM, DECIC/DECDC, SEL/SED, DECRQSS)
  remain inert.

## Proof obligations

Reuse the house harness: public-API unit suites, `expectValidGrid`,
whole-value equality, the fixture replay runner, and the existing fuzz
sweeps. TDD per repo convention: every change lands failing-test-first and
every commit stays green.

- PO1 (I1, I2) Regression: all existing suites pass unchanged; with no region
  set, LF/soft-wrap/wide-wrap at the bottom produce terminals bit-identical
  to slice 5 behavior (the refactor through the primitive is
  observation-free).
- PO2 (I7, I8, I9) DECSTBM: every clamping-matrix row; homing including
  pending-wrap clear; cursor legally outside the region afterwards; resize
  resets the region while equal-dimension resize does not; chunk-split
  DECSTBM and ESC sequences replay chunk-invariantly; two terminals
  identical except for the active region compare unequal (direct `==`
  assertion, independent of chunking).
- PO3 (I1, I2, I6, I7) Region line advance and RI: LF/IND/NEL/RI at, above,
  below, and outside margins; the top-anchored-region no-push D1 pin; soft
  wrap and wide-wrap (both `printWide` and `upgradeClusterToWide` right-edge
  paths) at the region bottom, asserting the spacer row lands adjacent above
  the freshly vacated row and the wrapped cluster projects as one logical
  line; seam severing above the region top, at the moved bottom row, and on
  `scrollbackRows.last` when row 0 is destroyed (region top 0, not full) or
  displaced (RI/SD/IL at top 0).
- PO4 (I2, I3, I9) SU/SD: cursor independence (cursor outside the region
  still scrolls it); count clamping including `\e[100S` full-screen push of
  exactly `rows` rows, asserting through public scrollback views that the
  pushed rows are the pre-scroll viewport rows in order -- cells, styles,
  and wrap identity preserved, not BCE blanks; region-bounded SU/SD never
  push; BCE styles on vacated strips.
- PO5 (I3, I4, I5) ICH/DCH: shifts with style travel; clamp to remaining
  width; in-region row guard; wide pairs severed at the cursor boundary and
  the right edge reduced to BCE padding (including DCH starting on a
  wideTail); continuation claim severed (flag + spacer) without violating the
  structural contract.
- PO6 (I1-I5, I7) IL/DL: counts >= region extent degenerate to BCE erase;
  cursor row and column pinned (D4); DL at row 0 with full region does not
  push (D1 pin); seam severing at both edges of the moved strip.
- PO7 (I2) ED 3: scrollback emptied, viewport/cursor/region untouched;
  idempotent; printing at (0,0) immediately afterwards is safe
  (`clearPreviousSpacer` empty-scrollback path).
- PO8 (I5, I9) Fuzz: extend the fuzz alphabet with DECSTBM, SU/SD,
  ICH/DCH/IL/DL, ED 3, and ESC D/E/M forms; sweep structural validity and
  no-trap over the extended alphabet.
- PO9 (I6, I8) The new neutral fixtures replay under
  authored/bytewise/exhaustive-split chunkings with all expectations;
  `libvtermManifestCoverage` passes with the three new upstream files fully
  dispositioned.
- PO10 (I7, I9) Dispatch side-state gate: an arity-invalid slice-6 dispatch
  issued mid-pending-wrap and mid-cluster leaves the terminal
  whole-value-identical (a following printable still wraps; a following
  combining mark still attaches); each recognized valid operation clears
  both -- including when its region guard suppresses grid movement -- so a
  combining mark fed after DL cannot attach to content shifted into the old
  coordinate.

Slice exit gate: `just test` green (all four packages plus lint scripts) +
checked roadmap entry for slice 6 in `plan-terminal-engine/14-roadmap.md`
linking the promoted plan.

Left open for later slices: horizontal margins (DECSLRM/DECLRMM) and
DECIC/DECDC; origin mode (DECOM); insert mode (IRM); selective erase
(DECSCA/SEL/SED); DECRQSS and query replies; alternate screen (and its
no-scrollback interaction); RIS/DECSTR resetting the region when terminal
resets arrive; scrollback size limits/trimming; highlight mouse tracking's
multi-parameter CSI T form.

## Non-goals

- DECSLRM/DECLRMM/CSI s horizontal margins and every upstream case depending
  on them; DECIC/DECDC.
- Selective erase (DECSCA, SEL, SED); DECRQSS replies; alternate screen
  (Milestone 6); insert mode (IRM); origin mode (DECOM).
- Public inspection of region state (no `TerminalGeometry` change; behavior
  is asserted through existing views).
- Any scrollback push from bounded regions (settled policy, not an open
  question).

## Accepted risks

- AR1 Ghostty divergence (migration-visible): sticky-footer tools that set a
  top-anchored region (`CSI 1;N r`) accumulate scrollback history under
  Ghostty but not under DanTerm's strict policy. Accepted by explicit user
  decision; the single push-decision site in the primitive makes a future
  policy change one-line-shaped; revisit with Milestone 4 differential traces
  if real tools regress.
- AR2 Seam repair mutates retained history: severing `scrollbackRows.last`'s
  wrap claim (flag + spacer) changes an already-retained row. Follows the
  `clearPreviousSpacer` precedent and is required for I5/I6; observable only
  through `fullHistoryText`/`scrollbackRow`, pinned by test.
- AR3 Uniform side-state clearing (D2) may differ from incumbent behavior
  in exotic interactive traces (e.g. SU issued mid-pending-wrap);
  deterministic, recorded, low blast radius.
- AR4 The libvterm in-region row guard for ICH/DCH (no-op when the cursor row
  is outside the region) may not match every xterm build; no upstream case
  exercises the divergence, and libvterm is the pinned reference. Revisit via
  differential traces.

## Rejected ideas

- RI1 libvterm/Alacritty geometric push policy (push whenever the scroll
  strip is anchored at absolute row 0, full width -- including top-anchored
  regions and DL at row 0): rejected by settled user policy; it pollutes
  history with TUI region repaints and makes "scrollback = lines that left
  the primary screen" conditional on region geometry.
- RI2 Per-operation bespoke cell shifting (each handler moves cells itself):
  rejected -- the shared primitive is the architectural center; divergent
  wide-repair/BCE/seam handling across seven operations is the failure mode
  this plan exists to prevent.
- RI3 Implementing DECOM now "since we're touching cursor homing": rejected
  -- nothing in the adopted tranche needs it; absolute homing is simpler and
  libvterm-conformant without it.
- RI4 Preserving/clamping the region across resize: rejected -- xterm-like
  reset avoids any interaction between region state and `resizeWidth`'s
  whole-history rebuild or `resizeHeight`'s scrollback transfers.
- RI5 Exposing the region through `TerminalGeometry`: rejected -- no consumer
  exists; fixtures assert behavior, and whole-value equality covers the
  state.
- RI6 Emitting absorber events for ESC-with-intermediates finals (DECALN
  etc.): rejected -- out of slice scope; the absorber change is confined to
  bare ESC finals.

## Implementation discretion

- Primitive shape: one rect-based function vs. a vertical/horizontal pair
  behind one documented contract; naming; file placement.
- Region storage representation, provided it participates in synthesized
  equality and "no region == full screen" normalization holds.
- Seam-severing mechanics: operation ordering (e.g. establishing the wrap
  flag after the margin scroll in wrap paths) vs. explicit repair passes --
  only the I5/I6 observables are normative.

## Fixtures and manifest

New fixture files under `Tests/TerminalCoreTests/Fixtures/libvterm/` (house
naming; grouping and names at implementation discretion; all
provenance-pinned to commit `934bc2fbf21800ac3458a499df8820ca5fb45fd3`,
reduced dimensions where noted, scrollrect/moverect/sb callback assertions
translated to viewportText/cursor/scrollbackCount expectations per
`docs/research/1-external-tests.md`), covering:

- Linefeed, Index, Reverse Index (full-screen).
- Linefeed in DECSTBM (asserts `scrollbackCount` stays 0; D1 in provenance),
  Linefeed outside DECSTBM, Index in DECSTBM (actually RI in a region --
  cite bytes in provenance), Reverse Index in DECSTBM (actually
  LF-below-region no-op), Invalid boundaries, DECSTBM resets cursor
  position.
- Scroll Down (= SU, `\e[S`; including `\e[100S` clamp-to-full with full
  push), Scroll Up (= SD, `\e[T`), SD/SU in DECSTBM, the in-scope full-width
  half of SD/SU in DECSTBM+DECSLRM.
- ICH, DCH, plus the 60screen_ascii Copycell events.
- IL, IL with/outside DECSTBM, DL, DL with/outside DECSTBM, plus a
  DanTerm-authored DL-at-row-0 event pinning no push (D1 in provenance).
- ED 3 after content has scrolled into scrollback; asserts scrollback 0,
  viewport/cursor untouched.

Wide-cell severing, wrap-seam, and scrollback-seam cases have no upstream
analog and live in unit suites, not fixtures (provenance requires an upstream
case).

Manifest additions (every case dispositioned; `expectedCases` dictionary and
`recordedDeviations` set in `TerminalFixtureTests.swift` updated together
with the manifest JSON):

- `t/12state_scroll.test`: Linefeed, Index, Reverse Index -- adopted;
  Linefeed in DECSTBM -- adapted (D1: no push from top-anchored region);
  Linefeed outside DECSTBM -- adopted; Index in DECSTBM -- adopted (upstream
  title/content mismatch noted; bytes are `\eM`); Reverse Index in DECSTBM --
  adopted (pins LF-below-region no-op); Linefeed in DECSTBM+DECSLRM, IND/RI
  in DECSTBM+DECSLRM -- out-of-scope (horizontal margins deferred); DECRQSS
  on DECSTBM, DECRQSS on DECSLRM -- out-of-scope (query replies); "Setting
  invalid DECSLRM with !DECVSSM is still rejected" -- out-of-scope; Scroll
  Down, Scroll Up -- adopted (title inversion vs. mnemonics noted); SD/SU in
  DECSTBM -- adopted; SD/SU in DECSTBM+DECSLRM -- adapted (DECSLRM half
  dropped, full-width half retained); Invalid boundaries -- adopted; Scroll
  Down/Up move+erase emulation -- superseded (callback-decomposition variants
  of the base cases); DECSTBM resets cursor position -- adopted.
- `t/13state_edit.test`: ICH, DCH -- adopted; ICH/DCH with/outside DECSLRM --
  out-of-scope; ECH, EL 0/1/2, ED 0/1/2 -- adopted (already implemented in
  earlier slices; covered by existing suites); IL -- adopted (upstream TODO
  pins D4 cursor behavior); IL with DECSTBM, IL outside DECSTBM -- adopted;
  IL with DECSTBM+DECSLRM -- out-of-scope; DL -- adapted (extended with the
  DL-at-row-0 D1 pin); DL with DECSTBM, DL outside DECSTBM -- adopted; DL
  with DECSTBM+DECSLRM -- out-of-scope; DECIC/DECDC and their margin
  variants -- out-of-scope; SEL, SED -- out-of-scope (selective erase); ED 3
  -- adopted (new this slice); DECRQSS on DECSCA -- out-of-scope; "ICH
  move+erase emuation" (upstream sic), DCH move+erase emulation --
  superseded.
- `t/60screen_ascii.test`: Get, Erase, Space padding, Linefeed padding --
  adopted (print/erase/projection behavior proven by existing slices);
  Copycell -- adopted (cell-layer ICH/DCH); Altscreen -- out-of-scope
  (Milestone 6).

Manifest `recordedDeviations` set gains two strings (exact wording at
implementation discretion, content normative): the strict full-screen-only
scrollback push policy (D1), and uniform side-state (pending wrap + cluster
attachment) clearing on valid scroll/edit operations (D2).

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- region state,
  primitive, all handlers, region-aware line advance, ED 3, resize reset.
- `lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift` -- ESC final
  event surface.
- `lib/TerminalCore/Sources/TerminalCore/TerminalInputStream.swift` -- new
  stream action routing.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift` --
  `expectedCases` + deviation pins.
- `lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/libvterm/` (new
  fixtures) and `Fixtures/libvterm-manifest.json`.
- New/extended unit suites in `lib/TerminalCore/Tests/TerminalCoreTests/`
  (scroll-region, editing, seam, fuzz), leaning on
  `TerminalGridAssertions.swift`.

## Verification

- Per change: `swift test --package-path lib/TerminalCore`, with targeted
  `--filter` runs during development (e.g. `--filter TerminalFixtureTests`
  and the new scroll/edit suites).
- Fixture replay exercises authored/bytewise/exhaustive-split chunking and
  final whole-value equality automatically.
- Slice exit: `just test` green (DanTermProtocol, DanTermCore, TerminalCore,
  DanTermSupport, lint scripts), then check the slice 6 entry in
  `plan-terminal-engine/14-roadmap.md` linking the promoted plan.

## Commit progress

- [x] 1. Add region-aware scrolling and index controls
- [x] 2. Add terminal editing operations and scrollback erase
- [x] 3. Adopt scroll/edit fixtures and complete the slice gate
