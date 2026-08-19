# Character sets: SCS designation, locking shifts, and GL translation

BUG-01 and BUG-07 from `docs/scratch/2026-08-18-construction-audit.md`.

## Context

DanTerm has no character-set state. `ESC ( 0` (SCS, designate DEC Special
Graphics into G0) is recognized by `EscapeAbsorber` and then discarded:
`Terminal.dispatchEscape(_ sequence:)` opens with `guard
sequence.intermediates.key == 0x23, sequence.final == 0x38 else { return }`, so
every SCS designation returns immediately. `execute(_:)` has no case for SO
(0x0E) or SI (0x0F), so the locking shifts are dropped too. There is no G0-G3
slot anywhere and no charset field on `SavedCursorState`.

DanTerm launches children with `TERM=xterm-256color`
(`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneLaunch.swift:115`),
whose terminfo defines `smacs=\E(0` / `rmacs=\E(B` -- and `sgr0=\E(B\E[m`, so
the designation path is exercised by every attribute reset, not just box
drawing. Every ncurses program that draws a border (dialog, whiptail, mc, ncdu)
emits this pair; the user sees rows of literal `lqk`/`mjx` instead of a frame.
The vt100/screen terminfo family reaches the same hole via `smacs=^N` /
`rmacs=^O` with `enacs=\E(B\E)0` (GNU screen, some Emacs terminal frames).

Both probes were run, not predicted, at 10x1:

| Feed | Expected | Observed |
|---|---|---|
| `ESC ( 0 lqk ESC ( B ab` | `┌─┐ab` | `lqkab` |
| `ESC ) 0 SO lqk SI ab` | `┌─┐ab` | `lqkab` |

The second probe's output being exactly five columns shows SO/SI are already
parsed as controls and swallowed -- the parser layer is correct; only the
terminal reducer is missing. No parser change is needed anywhere in this plan.

### Prior statements this overturns

- Neither defect is pinned by a test, so no test expectation is reversed.
- `docs/design/2026-08-06-swift-terminal-engine.md` row C2 (supported surface)
  omits character sets. Amend it in the same commit as the code, per the
  register's own rule.
- `docs/scratch/wezterm-test-portage.md:255-258` and `:641` record DEC Special
  Graphics as "deliberately unsupported" (no rationale given). This work
  reverses that; add a dated supersession note there rather than silently
  disagreeing. (The audit attributes this record to
  `alacritty-test-portage.md`; it is actually in the wezterm note.)

### Audit claim corrected during verification

BUG-01 says ghostty and kitty "differ only on `h`". They differ on **seven**
entries: kitty also maps `+ , - .` to arrows, `0` to U+2588, and `_` to U+00A0
-- all inherited from Linux `consolemap.c`, per kitty's own header comment. On
six of the seven, kitty is the lone outlier: xterm's
`references/xterm/charsets.h#map_DEC_Spec_Graphic` agrees with
`references/ghostty/src/terminal/charsets.zig#dec_special` on every remapped
byte 0x60-0x7E, and vte, wezterm, foot, windows-terminal, and libvterm agree
with them on `h` = U+2424. The seventh, `_` (0x5F), splits three ways: xterm
maps it to U+2426 in UTF-8 mode (its `XXX(0x5F, UNDEF)` entry expands to a
mapping in the wide build, `references/xterm/charsets.c#xtermCharSetIn`),
ghostty leaves it identity, kitty maps it to U+00A0. xterm's `acsc` capability
advertises none of the seven bytes, so no terminfo-driven program on
`TERM=xterm-256color` ever requests them. The audit's conclusion (follow
ghostty/xterm) stands; its stated reason understated the gap.

## Decision

**Scope: the complete 7-bit GL half of ISO 2022, and nothing else.**

- Four slots G0-G3, designated by `ESC ( X`, `ESC ) X`, `ESC * X`, `ESC + X`.
- GL invocation: SI (0x0F, GL=G0), SO (0x0E, GL=G1), LS2 (`ESC n`, GL=G2),
  LS3 (`ESC o`, GL=G3).
- Single shifts: SS2 (`ESC N`) / SS3 (`ESC O`) apply G2/G3 to exactly the next
  printed graphic character.
- **No GR bank.** DanTerm is UTF-8-only: every byte >= 0x80 is consumed by the
  UTF-8 decoder before charset logic could see it, so GR state could never be
  observed -- it would be dead state carried through DECSC, alt-screen, and
  reset for zero behavior. LS1R/LS2R/LS3R (`ESC ~ } |`) remain what they are
  today (recognized escape finals that fall through `default:`); a test pins
  that they print nothing and do not disturb GL.
- 96-character designators (`ESC - . /`) and C1 SS2/SS3 (raw 0x8E/0x8F) stay
  out, consistent with the existing UTF-8/C1 policy.

**Tables: three charsets.** `ascii` (identity), `decSpecialGraphics`, `british`
(identity except 0x23 `#` -> U+00A3). The DEC Special table is ghostty's
`references/ghostty/src/terminal/charsets.zig#dec_special`: identity except
0x60-0x7E remapped, with `h` = U+2424. xterm's
`references/xterm/charsets.h#map_DEC_Spec_Graphic` agrees on all of 0x60-0x7E;
the two diverge only on 0x5F, which xterm maps to U+2426 (its "undefined"
glyph) and ghostty leaves identity. DanTerm keeps 0x5F identity, deliberately.
Do not adopt kitty's seven Linux-console divergences or libvterm's slanted
`y`/`z` (U+2A7D/U+2A7E where everyone else has U+2264/U+2265).

**Unrecognized designations designate ASCII.** A program cannot query charset
state (no report exists, and DanTerm rejects DECRQSS -- register I5), so the
only observable is rendered glyphs. Designating ASCII degrades an unsupported
set to deterministic plain text; leaving the slot unchanged (ghostty's choice)
lets a stale DEC Special designation turn later text into history-dependent
line-drawing garbage. Deterministic beats stale. This covers the whole
designation family, not just unknown finals: any escape sequence whose *first*
intermediate is 0x28-0x2B and whose full form is unrecognized -- an unknown
final, or extra intermediates such as `ESC ( % 5` (DEC Supplemental, which
xterm accepts) -- designates ASCII into that slot, because a stale slot after
`ESC ( % 5` is exactly the history-dependent garbage this policy exists to
prevent. Documented as a DanTerm contract in the register row.

## Reference facts the semantics rest on

- **DECSC saves charset state.** `references/xterm/cursor.c#CursorSave2` quotes
  the VT420 manual: DECSC saves the designations, which set is invoked in
  GL/GR, and any pending single shift. Ghostty does the same
  (`Terminal.zig#saveCursor`).
- **RIS resets it** (xterm `charproc.c#ReallyReset`, ghostty `Screen.zig#reset`).
- **DECSTR resets it too**: `ReallyReset` calls `resetCharsets` unconditionally,
  outside its `if (full)` branch. Ghostty is silent here only because it does
  not implement DECSTR at all -- follow xterm.
- **The alt-screen switch does not change it.** Ghostty stores charset state on
  `Screen` but `Terminal.zig#switchScreen` explicitly copies it across ("Bring
  our charset state with us"); xterm's is terminal-scoped. Only the
  saved-cursor slot is genuinely per-screen.
- **SO/SI as locking shifts have no dissent** across xterm, ghostty, kitty,
  libvterm (ECMA-48 8.3.75/76), and wezterm.

## Design

### State

The three charsets, the one translation table, and the charset state value
live in a new `lib/TerminalCore/Sources/TerminalCore/TerminalCharset.swift`
(the audit already flags Terminal.swift, 7,600 lines, for hand-enumerating
protocol tables inline). The state value carries exactly the VT420 DECSC list:
the four slot designations, which slot is invoked into GL (default G0), and
the pending single shift (default none). Its default value is the reset state.
Translation applies to GL bytes 0x20-0x7E only.

Ownership, mirroring the references' observable behavior with the simplest
structure:

- **Live state is terminal-scoped** (a `Terminal` field beside `modes`). The
  alt-screen switch then carries it with no code at all -- ghostty needs an
  explicit copy only because it chose per-screen storage.
- **`SavedCursorState` gains a copy of the whole struct** (designations + GL +
  pending shift, the full VT420 list). `saveCursor()`/`restoreCursor()` copy it
  like every other field; the 1048/1049 paths already route through those two
  functions, so vim entering and leaving the alt screen restores the shell's
  charset with no extra work -- and each screen keeps its own saved slot, as
  today.
- **`resetControlState()` resets it** -- that one line covers both RIS and
  DECSTR, matching xterm, because both resets already call it.

### Dispatch (all in Terminal.swift; zero parser changes)

- `dispatchEscape(_ sequence:)`: a *first* intermediate of 0x28/0x29/0x2A/0x2B
  designates G0-G3 (the intermediates key packs multiple bytes, so match the
  first byte, not the whole key); final 0x30 -> DEC Special, 0x41 -> UK,
  0x42 -> ASCII; any other final, and any multi-intermediate form such as
  `ESC ( % 5`, -> ASCII. The existing DECALN arm (key 0x23) is untouched.
- `dispatchEscape(_ final:)`: 0x6E/0x6F (LS2/LS3) set GL; 0x4E/0x4F (SS2/SS3)
  set the pending single shift.
- `execute(_:)`: 0x0E sets GL=G1, 0x0F sets GL=G0.
- Designations and shifts touch no grid or motion state: no
  `clearPendingMotionState()`, no cluster invalidation. The probes confirm
  they consume no cell; a combining mark after SO must still join the open
  cluster; and a latched pending wrap must survive `ESC ( B` -- xterm's
  `sgr0=\E(B\E[m` emits a designation on every attribute reset, so clearing
  the latch there would break wrapping in ordinary ncurses traffic.

### Print path -- the part that must not be fumbled

Translation lives **only** where raw GL stream bytes become scalars, which
after checking the stream layer is exactly one place: `printASCIIRun`. All
bytes 0x20-0x7E reach the reducer as `.printASCIIRun` (the parser's ground+idle
gate guarantees it; a lone ASCII byte is a run of one), and `.print(scalar)`
only ever carries decoded non-ASCII scalars, which GL translation never
touches. Two consequences, both load-bearing:

- **REP is safe by construction.** `repeatLastPrintedCluster` re-feeds
  already-translated *cell* scalars through `print(scalar)`; had translation
  lived in `print`, REP would double-translate. It doesn't, so `ESC ( 0` `q`
  `CSI b` repeats `─`, and a test pins that.
- **The bulk fast path stays eligible under a locking shift.** A run of GL
  bytes under DEC Special (ncurses borders are long strings of `q`) must not
  fall to the per-character path wholesale; translation belongs inside the
  run. A pending single shift is the one new cut: it applies to exactly one
  character, so the bulk path declines and the per-character path consumes
  it. How the run translates internally is implementation discretion -- the
  chunk sweep proves whatever shape is chosen means the same as the
  per-character path.
- The soundness premise extends: every scalar the DEC Special and UK tables
  can emit must be narrow and grapheme-break-class `.other` (box drawing is
  East Asian Ambiguous = one cell per register D2). Pin it with a premise test
  exactly like `TerminalASCIIRunTests.printableASCIIIsNarrowAndBreaksOther`,
  looping the tables' outputs through `terminalUnicodeClassification`.
- Pending-shift consumption contract: **any** printed graphic character
  consumes it; non-GL scalars translate as identity (matches "next graphic
  character" semantics in the references). REP's re-fed characters are
  printed graphic characters, so they consume a pending shift too (as
  identity -- they are already-translated cell scalars, not GL bytes).
- Amend `printASCIIRun`/`TerminalStreamAction` doc comments: a run is
  semantically one *GL print* per byte (translation included), not one raw
  `.print` per byte.

Everything downstream -- projection, selection, search, recovery, damage --
sees ordinary Unicode scalars in cells and needs no changes.

### State synchronization (the touchpoint the audit brief missed)

Charset state joins the class of state that cannot ride standard sequences
exactly: a pending single shift has no cancel sequence (only printing a
graphic character consumes one), and the saved slot cannot be written without
routing through live state. The encoder already owns the seam for exactly
this class -- the private `OSC 133;S` key-value forms that carry REP memory
(`repeat-add`), the open cluster (`cluster`), and row wrap state
(`mark`/`wrap`), decoded in `applySemanticPromptOptions` -- so charset state
rides it too, leaving the existing row and control-state ordering completely
untouched:

- **One saved-slot value per screen**, emitted alongside that screen's
  existing saved-cursor capture and written directly into the active screen's
  saved slot on decode. Full fidelity: designations, GL invocation, and the
  saved pending single shift. It must land *after* the replayed `ESC 7` that
  closes the saved-cursor capture: `ESC 7` recaptures the replica's live
  charset -- reset-default at that point -- into the slot, so a form decoded
  earlier would be silently clobbered back to ASCII.
- **One live value at the end of the encode**, before
  `inputStream.synchronizationPrefix`. Ordering matters only here: the
  leading `ESC c` keeps the replica all-ASCII while rows replay (stored cell
  scalars are post-translation, so they re-encode safely by construction),
  and the live assignment must land after the last graphic byte of the
  encode so nothing in the encode itself gets translated.

Rejected: capturing the saved slot with real sequences (a saved-state block
before the row replay, closed by `ESC 7`, with a disposable graphic character
to consume the pending shift). Refuted in review: `appendRows` skips
default-style padding with cursor motion rather than overwriting it, so the
consumption character can survive replay in a padding cell and corrupt
reconstructed content.

## Tests (TDD -- the probes are the first failing tests)

New `lib/TerminalCore/Tests/TerminalCoreTests/TerminalCharsetTests.swift`,
style-matched to `TerminalSavedCursorTests` (feed bytes, assert `screenText` /
`cell(row:column:)`, end with `expectValidGrid`):

1. **BUG-01 probe**: `ESC ( 0 lqk ESC ( B ab` at 10x1 -> `┌─┐ab`. Fails today
   with `lqkab`.
2. **BUG-07 probe**: `ESC ) 0 SO lqk SI ab` -> `┌─┐ab`. Proves the locking
   shifts, not just designation.
3. **Full-table pin**: all of 0x20-0x7E under DEC Special asserts the exact
   95-scalar expected string (anchors: `` ` ``->◆, h->U+2424, q->─, x->│,
   ~->·; 0x5F stays `_`); UK pins `#`->£ and identity elsewhere.
4. **Fast-path premise**: every table output scalar is narrow and `.other`.
5. **Chunk invariance**: add charset scenarios (designation mid-run, SO/SI
   mid-run, SS2 mid-run) to `TerminalASCIIRunTests.equivalenceScenarios` --
   the existing 7-chunking sweep then proves bulk == per-character under
   translation.
6. **LS2/LS3 + SS2/SS3**: `ESC * 0` `ESC n` q -> ─; `ESC + 0` `ESC O` qq ->
   `─q` (exactly one character shifted); a non-GL scalar also consumes a
   pending shift.
7. **DECSC/DECRC**: designate + invoke, `ESC 7`, redesignate ASCII, `ESC 8`,
   print -> translated; the 1049 round trip restores the primary charset
   (the "vim leaves the terminal drawing lines" regression, prevented).
   A raw `CSI ?1047h`/`?1047l` pair -- which saves and restores nothing --
   must instead carry live state across both switches: invoke DEC Special
   before entry, verify translation inside the alternate screen, redesignate
   ASCII there, exit, verify ASCII is still active. This is what
   distinguishes terminal-scoped live state from a per-screen or
   reset-on-switch implementation, which the 1049 test alone cannot.
8. **Resets**: after `ESC c` and after `CSI ! p`, `q` prints literally.
9. **Unrecognized designation**: `ESC ( 0` then `ESC ( K` -> `q` prints
   literally (ASCII, not stale DEC Special); same for the multi-intermediate
   form `ESC ( 0` then `ESC ( % 5` -> `q` prints literally.
10. **GR invocations are inert**: `ESC ~ } |` print nothing and leave GL alone.
11. **REP**: `ESC ( 0` q `CSI b` -> `──`.
12. **State sync** (in `TerminalStateSynchronizationTests`): snapshot a
    terminal with a non-default live charset *and* a different saved-slot
    charset; replay; then feed a continuation of bare `lqk` and a
    `ESC 8` + `q` continuation to both source and replica and compare --
    `expectObservableState` compares no charset field directly, so the
    continuation feed is what makes a lost designation visible. Include an
    alt-screen-active variant, and both pending-shift fidelity cases: a
    snapshot taken with a *live* pending shift (continuation `q` must
    translate once in both terminals) and a snapshot taken inside a
    DECSC-with-pending-shift window (continuation `ESC 8` then `q` must
    apply the restored shift in both terminals).
13. **Pending wrap survives charset traffic**: with the wrap latched at the
    right margin under DEC Special, `ESC ( 0`-family traffic and SO/SI must
    not clear the latch, and the next printed character is a GL byte that
    must both wrap *and* translate. The translation half matters because a
    latched wrap makes the bulk path decline, and the chunk sweep cannot
    catch a per-character path that consistently skips translation -- every
    chunking takes the same path and agrees on the same wrong grid. Guards
    the `sgr0=\E(B\E[m` reality named in the dispatch contract.

## Implementation discretion

Free to decide during implementation; changing them changes no observable
behavior or invariant:

- Type, field, and file-internal naming; table representation and lookup
  shape.
- How the bulk run translates internally (supplier mechanics, where the
  per-run charset check sits) -- bounded by the print-path invariants above
  and proven equivalent by the chunk sweep.
- The `OSC 133;S` key names and value encoding for the charset forms,
  following the existing forms' style (`repeat-add`, `cluster`).

## Documentation

- Amend register row C2 (`docs/design/2026-08-06-swift-terminal-engine.md`) to
  add the charset surface, and add one new C-row (next free id) stating the
  contract: 7-bit GL charset switching in full (three sets, G0-G3, SI/SO,
  LS2/LS3, SS2/SS3); no GR bank because there is no 8-bit byte path;
  unrecognized designations (unknown final or extra intermediates) designate
  ASCII; table matches xterm on 0x60-0x7E and keeps 0x5F identity (ghostty's
  choice; xterm maps it to U+2426). Same commit as the code.
- Dated supersession note in `docs/scratch/wezterm-test-portage.md` where it
  records DEC Special Graphics as deliberately unsupported.
- Porting wezterm's `test_resize_wrap_sgc_issue_978` becomes possible; named
  follow-up, not in scope.

## Verification

- `swift test --package-path lib/TerminalCore` -- new suite plus the touched
  suites (`TerminalASCIIRunTests`, `TerminalSavedCursorTests`,
  `TerminalResetTests`, `TerminalStateSynchronizationTests`, `TerminalRepeatTests`).
- `just test` for the full gate.
- Live, by eye and remotely: `just launch-slot`, then in the pane run
  `dialog --msgbox hi 10 30` -- the frame must be box glyphs, and
  `danterm pane read` shows `┌─┐` characters in the projected text, so the
  fix is verifiable without a human looking at the window. `tput smacs; echo
  lqk; tput rmacs` is the one-liner variant.

## Commit progress
- [x] 1. Character-set designation, locking shifts, and GL translation
- [ ] 2. Carry charset state through state synchronization

## Implementation notes

- The plan's claim that "neither defect is pinned by a test, so no test
  expectation is reversed" was wrong on both counts, and slice 1 reverses two.
  `TerminalTests.pendingWrapControlMatrix` listed SO and SI among controls that
  leave the whole terminal value unchanged; they now move the GL invocation, so
  they moved to a pending-wrap-only assertion. The two adapted alacritty
  fixtures `saved_cursor` and `saved_cursor_alt` recorded the deviation "DanTerm
  ignores unpromised legacy G0 character-set state during cursor restore" and
  excluded box glyphs from the viewport. Their expectations now match
  alacritty's own `grid.json` cell for cell, with 0x5F the single divergence --
  which is the deliberate one from the Decision, and is what their recorded
  deviation says now.
- The bulk run keeps a separate identity supplier for `ascii`, so the
  overwhelmingly common case pays no charset branch per character, and the
  translating supplier is used only under a non-identity set. The chunk sweep
  proves the two mean the same thing as the per-character path.
- The pending single shift is spent inside `print(_:)`, after the zero-width
  guard and after the cluster-join return. That is where a cell is actually
  written, so a combining mark that joins an open cluster leaves the shift
  armed while any character that occupies a cell spends it. It matches where
  ghostty spends it (`Terminal.zig#printCell`).

## Follow Up

- Port wezterm's `test_resize_wrap_sgc_issue_978`. `docs/scratch/wezterm-test-portage.md`
  declined it only because DEC Special Graphics was unimplemented, and that
  entry now carries a supersession note.
