# DECSCA character protection and selective erase (DECSED / DECSEL)

Source: BUG-10 in `docs/scratch/2026-08-18-construction-audit.md`, widened from
"dispatch the `?` forms as ED/EL" to the ideal: the DEC protection family the
`?` forms exist for.

## Problem

`CSI ? Ps J` (DECSED) and `CSI ? Ps K` (DECSEL) are dropped: `Terminal.swift#dispatchCSI`
handles only `h l n u` under the `?` intermediate, so the selective erases touch
nothing -- not the grid, not pending wrap, not history. `CSI Ps " q` (DECSCA),
the control that makes them "selective", is dropped too (`"` falls to the
dispatcher's default arm). A program that protects a field and clears around it
sees stale text; vttest's erase tests fail.

Evidence:

- Reproduced on `549fbf64`: `"ABC\e[1;1H\e[?0K"` leaves `A` in cell (0,0);
  the same bytes without `?` produce padding.
- `CSIEraseTests#invalidEraseIsNoOp` lists `ESC [ ? K` among sequences that must
  leave the terminal bit-identical, so today's no-op is pinned on purpose. It
  was a recorded deferral ("deferred to protected attributes", 2026-07-17 erase
  plan), never a decision that the family is unwanted. The audit's "unpinned"
  status is wrong.
- Registry: `docs/design/2026-08-06-swift-terminal-engine.md` C2 names neither
  DECSCA nor selective erase; A8 authorizes growth from measured need;
  `docs/research/26-external-corpus-expansion/README.md` says reopening the
  family is a support-matrix decision that precedes any test change. This plan
  is that decision.
- References on the semantics (compatibility is the requirement, per AGENTS.md):
  xterm, ghostty, libvterm, iTerm2 and Windows Terminal implement DECSCA with
  DECSED/DECSEL honoring it; vte aliases DECSED/DECSEL to ED/EL; foot, tmux,
  wezterm and alacritty ignore all three; kitty repurposes `?` as "keep
  attributes". Where the implementers disagree, this plan follows the majority
  and the VT420/VT520 manuals, and names each choice in **Decision**.

## Decision

Implement the DEC protection family in full, with no extra mode state:

- Protection is one more attribute of the pen, carried per cell exactly like an
  SGR attribute (`TerminalStyle` gains `protected`). It therefore rides every
  existing path for free -- print including wide pairs, reflow, retained
  history (the style id is already stored per cell), DECSC/DECRC (the saved
  cursor carries the pen), DECSTR/RIS (the pen is reset), the public
  `TerminalCell.style`, and value equality of `Terminal`.
- The `?` prefix on `J`/`K` is a flag on the existing erase path, not a new
  branch: same region, same arity and mode guards, same pending-wrap and
  soft-wrap effects, plus "skip protected cells". There is no per-screen
  "last protection mode used" (xterm's `protected_mode`) because that state
  exists only for ISO protection and DECRQSS, both out of scope.
- Semantics, one line each, with the reference that settles it:
  - DECSCA `Ps` missing, 0, or 2 clears the pen's protection; 1 sets it; any
    other value changes nothing (xterm, libvterm, Windows Terminal).
  - SGR never touches protection, SGR 0 included (xterm `resetRendition`,
    ghostty, libvterm, Windows Terminal `SetDefaultRenditionAttributes`).
  - Every character cell a print writes while the pen is protected is
    protected: narrow, wide head, wide tail (xterm `ScrnWriteText`, ghostty
    `Screen.print`; libvterm's unprotected tail is the outlier and would let
    DECSEL split a wide pair). The spacer head a wrapped wide char leaves at
    the margin is a wrap artifact, not a character: a selective erase whose
    region covers the spacer cell always blanks it, protected pen or not, so no
    erase can produce a grid shape (a spacer on a hard-wrapped row) that ED/EL
    cannot. Retiring a spacer because the wide head below it was blanked is a
    different rule over a different row (I6).
  - DECSED/DECSEL 0/1/2 blank the ED/EL region except protected cells, and keep
    erasing past a protected run; DECSED 3 clears history exactly like ED 3
    (xterm, ghostty, libvterm; Windows Terminal and vte make `?3J` a no-op).
  - Every erase -- ED, EL, ECH, DECSED, DECSEL -- writes unprotected blank cells
    (xterm `ClearCells`, ghostty `blankCell`, libvterm `erase_internal`).
  - ED, EL, ECH, ICH, DCH, IL, DL, scrolling, DECALN, and resize ignore
    protection (every implementing reference; xterm's changelog records "ECH
    should not be masked by DECSCA").
  - DECALN fills unprotected `E` cells and leaves the pen's protection as it
    was (xterm `resetRendition` keeps the bit; ghostty test "DECALN ... with
    protected mode").
  - DECSTR and RIS clear the pen's protection (xterm `ReallyReset`, libvterm
    `vterm_state_reset`, Windows Terminal `SoftReset`). DECSC/DECRC save and
    restore it (xterm `DECSC_FLAGS`, ghostty `saveCursor`, Windows Terminal;
    VT420 manual p.270 lists "selective erase attribute").
  - Pending wrap: DECSED/DECSEL clear it the way ED/EL do, whether or not the
    margin cell survived (ghostty `eraseLine`, Windows Terminal). DECSEL 0
    clears the row's soft wrap unconditionally like EL 0 (xterm `ClearRight`).
  - Every other row-level side effect of an erase follows from which cells
    were actually blanked, so the bare and `?` forms coincide whenever nothing
    is protected (I6).
- State synchronization (`Terminal.stateSynchronization`, consumed by
  `TerminalPTYHost` replication and pane snapshots) carries protection for
  every cell run, the live pen, and the saved pen. DECSCA is its own CSI, so
  the 24-parameter SGR budget is untouched.
- Support matrix: row C2 of `docs/design/2026-08-06-swift-terminal-engine.md`
  is amended in the same commit as the code to name DECSCA and selective
  erase. The libvterm and Alacritty manifest dispositions for the family are
  re-adjudicated (PO9).

Scope: `lib/TerminalCore` (dispatch, erase, style, state synchronization, the
fixture decoder), its tests and fixtures, the design register row, the audit
row. No renderer change: render planning reads named style fields and never
sees the new one.

## Invariants

- I1. DECSCA: after `CSI 1 " q` every printed character cell -- narrow, wide
  head, wide tail -- reports `style.protected == true`; after `CSI " q`,
  `CSI 0 " q`, or `CSI 2 " q` printed cells report false; an unrecognized
  parameter leaves the pen's protection unchanged; SGR sequences, SGR 0
  included, leave it unchanged and it leaves them unchanged.
- I2. Selective erase: DECSED 0/1/2 and DECSEL 0/1/2 blank exactly the cells
  ED/EL 0/1/2 would blank minus the protected ones; cells after a protected
  run are still blanked; the blanks are unprotected; DECSED 3 empties history
  like ED 3.
- I3. Parity: with no protected cell in the region, a `?`-prefixed erase leaves
  the terminal value-identical to the bare form fed from the same state
  (grid, styles, cursor, pending wrap, soft-wrap flags, history, wrap claims).
  This includes the malformed forms: `CSI ? 1;2 K`, `CSI ? 3 K`, `CSI ? 4 J`,
  `CSI ? 22 J` are no-ops exactly as their bare forms are.
- I4. Non-selective operations ignore protection: ED, EL, ECH blank protected
  cells; ICH/DCH/IL/DL/scroll move them like any other cell; DECALN overwrites
  them with unprotected `E`s and leaves the pen's protection bit as it was.
- I5. Pen lifecycle: DECSTR and RIS clear the pen's protection; DECSC/DECRC
  round-trip it; the pen's protection is never changed by an erase.
- I6. Row side effects follow the cells actually blanked. DECSEL 0 clears the
  row's soft-wrap flag and pending wrap exactly as EL 0 does, even when the
  margin cell is protected and survives. Everything else is conditional on
  blanking: the margin counts as erased (`GridRow.marginErased`) only if the
  margin cell was blanked; the spacer on the row above a column-0 wide head
  (live or at the history seam) is retired only if that head was blanked -- the
  erased region there is the head's row, not the spacer's row; a row's
  soft-wrap flag (outside the EL-0 rule) and prompt marking reset only if the
  row was fully blanked; history's wrap claim into row 0 is severed only if
  row 0 was fully blanked -- the rule the sever already states ("call only for
  erases that blank all of row 0"). A spacer inside the erased region is always
  blanked (see Decision), so every post-erase grid shape is one ED/EL already
  produce.
- I7. State synchronization round-trips protection: protected cells (in the
  viewport and in retained history), a protected live pen, and a protected
  saved pen survive `stateSynchronization` -> fresh terminal -> `feed`. Because
  SGR 0 no longer resets the whole pen, the stream states protection
  explicitly on every style run it emits, not only when it changes: the
  encoder is stateless per run and the saved-cursor and pending-wrap emitters
  call it directly.
- I8. Everything outside the family is unchanged: render output for a protected
  cell equals the render output for the same cell unprotected; blank-cell
  classification in retained history (`isFillBlank`) is unaffected because
  erases never write protected blanks; combining marks printed after the pen
  changes keep the base cell's protection (cluster growth keeps the base
  style, as today).

## Proof obligations

- PO1 (I1): DECSCA parameter matrix and the print paths -- narrow, wide
  head+tail, a wide char wrapped off the margin -- each read back through
  `Terminal.cell(row:column:)?.style.protected`; SGR 0 / SGR 1 before and
  after leave protection as set and vice versa; a DECSEL 0 over the wrapped
  wide char's spacer blanks the spacer (Decision: spacers are not characters).
- PO2 (I2): mirror the ghostty `eraseLine ... protected requested` and
  `eraseDisplay protected below/above/complete` cases (protected island mid-row,
  island at the margin, two islands in one row, protected wide pair straddling
  the cursor) plus `?3J` clearing history; assert blanks are unprotected.
- PO3 (I3): parameterized whole-`Terminal` equality: `?J ?0J ?1J ?2J ?3J ?K ?0K
  ?1K ?2K` vs bare forms from a seeded state (text in several rows, cursor
  mid-row, pending wrap armed, rows in history); `CSIEraseTests#invalidEraseIsNoOp`
  drops `ESC [ ? K` and gains the malformed `?` forms.
- PO4 (I4): ED/EL/ECH blank a protected cell; DECALN over protected cells then
  a print still protected. Cell-moving paths keep protection on the cells they
  move and leave newly created cells unprotected: ICH and DCH (horizontal), IL
  and DL (vertical row movement), a scroll that pushes a protected row into
  history and reads it back, and a width resize that reflows a protected run
  (including a protected wide pair) across the new margin.
- PO5 (I5): extend `TerminalResetTests#softResetMatrix` / `#hardResetMatrix`
  with a protection probe; extend `TerminalSavedCursorTests` round-trip with a
  protected pen.
- PO6 (I6): DECSEL 0 with a protected margin cell: pending wrap cleared,
  soft-wrap flag cleared, margin not marked erased (observable through
  `TerminalStaleWrapClaimTests`' existing readers: a later print joins or
  does not join the way the flag dictates). A protected wide head at column 0
  under a spacer (live row above, and the history-seam variant from
  `CSIEraseTests#eraseAtTopRowClearsScrollbackSpacer`): DECSEL 2 leaves head,
  tail, and spacer, `expectValidGrid` passes. DECSED 2 with a protected cell
  in row 0 over an open history tail record: the claim is not severed; the
  same feed without the protected cell: it is (pattern of
  `CSIEraseTests#wholeRowZeroErasesSeverTheScrollbackWrapClaim`). A row
  keeping a protected cell keeps its soft-wrap flag and prompt marking under
  DECSED 2; a fully blanked row resets them (bare-form parity, PO3).
- PO7 (I7): `TerminalStateSynchronizationTests`: protected cells in viewport
  and history, protected pen, protected saved pen (DECRC then print in both
  terminals before comparing -- the saved pen is only observable that way);
  the existing fully-loaded style case gains protection.
- PO8 (I8): a render-planning test that a protected and unprotected cell
  produce identical resolved style; a combining mark printed after `CSI 0 " q`
  leaves its protected base cell protected; `TerminalMemoryCensusTests`
  unchanged.
- PO9 (fixtures/docs): libvterm `t/65screen_protect.test` both cases adopted
  via a new hand-authored `Fixtures/libvterm/screen-protect.json` (recording
  count bumps); `t/13state_edit.test` SEL/SED adopted citing `CSIEraseTests`;
  `t/10state_putglyph.test` "DECSCA protected" adapted as a `cellStyles`
  expectation (the putglyph `prot` flag becomes the public protected style);
  "DECRQSS on DECSCA" rationale narrowed to the DECRQSS half; Alacritty
  `selective_erasure` stays out-of-scope with a corrected rationale (its golden
  grid pins the ignore behavior DanTerm deliberately does not follow); the
  design register C2 row amended; `docs/scratch` audit row BUG-10 marked done
  in the follow-up docs commit with the "pinned by a test" correction noted.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: ISO 6429 protection (SPA/EPA, `CSI ... "` forms other than `q`).
  No per-screen protection mode is introduced; if ISO ever lands it adds the
  mode, not the other way round.
- Non-goal: DECRQSS `" q` reply. DCS bodies are absorbed and `decrqss` is a
  denied protocol in `docs/terminal-capabilities.md`.
- Non-goal: DECSERA / rectangular operations; DA1 stays `?1;2c` (claiming the
  VT220 "selective erase" bit would imply a VT220 feature set DanTerm does not
  have).
- Non-goal: kitty's "`?` means keep attributes" reading. DanTerm follows DEC.
- AR1: the style intern table gains protected variants of every style in use.
  Bounded by the existing sweep (`reclaimDeadStyleEntries`); a protected pen is
  rare and short-lived in practice.
- AR2: `style == TerminalStyle()` "is plain" checks (tests, and the
  `TerminalWorkflowRunner` pen guard) now see a protected pen or cell as
  styled. Correct -- it is -- and no production blank-classification depends
  on it because erases never write protected blanks (I2, I8). No workflow
  uses DECSCA, so the runner needs no change.
- RI1: a separate per-cell bit outside `TerminalStyle` (ghostty's
  `Cell.protected`). Rejected: it would need its own plumbing at every print,
  reflow, history-store, saved-cursor, reset, snapshot and inspection seam
  that the style id already crosses, and the history store would need a spare
  `CellWord` bit. xterm and Windows Terminal keep the bit in the attribute
  word; so does this plan.
- RI2: the cheap fix alone (`?J`/`?K` == `J`/`K`, no DECSCA). It is exactly
  right until a program protects something, and then it erases the field the
  program asked to keep -- a silent wrong answer where today's is a silent
  no-op. Chosen against.
- RI3: carry `?3J` as a no-op (Windows Terminal, vte). Rejected: xterm,
  ghostty and libvterm clear scrollback, and the xterm doc line names it
  "Selective Erase Saved Lines".

## Implementation discretion

- How the selective fill is expressed inside the existing bulk erase (skip
  loop vs. run splitting), as long as the skip decision is made per wide pair
  and the fill reports what it blanked so I6 derives from one fact.
- How DECALN keeps the pen's protection while writing unprotected `E`s
  (today it assigns the pen first and stamps cells from it; the two must be
  derived separately).
- Whether the spacer head is stamped with the pen's protection at print time;
  only the erase predicate matters (Decision).
- Where the fixture decoder's new `protected` style token lives.

## Verification

- `swift test --package-path lib/TerminalCore --filter CSIEraseTests`
- `swift test --package-path lib/TerminalCore --filter TerminalStyleTests`
- `swift test --package-path lib/TerminalCore --filter TerminalResetTests`
- `swift test --package-path lib/TerminalCore --filter TerminalSavedCursorTests`
- `swift test --package-path lib/TerminalCore --filter TerminalStateSynchronizationTests`
- `swift test --package-path lib/TerminalCore --filter TerminalFixtureTests`
- `just test` before commit.
- Live: `just launch-slot`, then in the pane
  `printf 'A\e[1"qB\e["qC\e[G\e[?J\n'` shows ` B`; `danterm pane tape` replay
  of the same bytes into `TerminalCore` agrees.

## Commit progress
- [x] 1. carry DECSCA protection on the pen and every cell
- [x] 2. honor protection in DECSED and DECSEL
- [ ] 3. adopt the libvterm protection fixtures and re-adjudicate the manifests

## Implementation notes

- Commit boundaries. The plan carries two things a reviewer reads differently:
  a new pen attribute that crosses every cell path, and a new erase mode that
  consults it. They are split so the attribute lands with its own propagation
  proofs and the selective erases land against an attribute already proven to
  ride print, reflow, history, the saved cursor, and state synchronization. The
  fixtures and the manifest re-adjudication follow as a third commit because
  they record a decision the code must already implement. The design register's
  C2 row is amended with the second commit, which is the one that completes the
  family.
- DECALN derives its fill style and its pen apart, as the plan's discretion
  clause allows: the `E`s intern `backgroundEraseStyle` directly, and the pen is
  rebuilt from its colors plus the protection bit it already had. Assigning the
  pen first and stamping from it would have stamped protected `E`s.
- The selective fill is a per-column survivor mask computed before the write, as
  the plan's discretion clause allows. It decides per wide pair, always blanks a
  spacer head, and is the single fact `eraseCells` reports back, so the margin
  flag, the spacer retirement and the row-level resets all read the same answer.
- The history sever runs *before* the erase does, so it cannot consult what the
  fill blanked. `rowIsFullyErasable` asks the mask the same question ahead of
  time instead. Reordering the sever after the fill would change the bare
  erases' behavior, which is out of this plan's scope.
- `styleSequence` appends an unconditional `CSI 0 " q` or `CSI 1 " q` after
  every SGR it writes. That is what keeps the encoder stateless per run now that
  the leading SGR 0 no longer clears protection, and it costs 5 bytes per style
  change rather than per cell.
