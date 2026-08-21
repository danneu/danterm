# Sever history's row-0 claim from what the display erase actually blanked

Source: BUG-21 in `docs/scratch/2026-08-18-construction-audit.md`, verified
2026-08-21 against `f9d4417a`. This is a pivot from the finding's proposal.

## 1. Problem, evidence, premises

History's open tail record is its claim that the last retained row continues
into live row 0. The recorded rule (`docs/research/31-logical-line-scrollback/decisions.md`,
D2 operation 2, 2026-08-05 amendment) is that a display erase (ED / DECSED)
or DECALN that blanks the whole of row 0 closes that record, so the next text
printed on row 0 does not fuse onto the retained line and a width change
cannot pull pre-clear text back onto the cleared screen.

`Terminal.eraseDisplay` implements the rule as three hand-enumerated
per-mode sites plus a pre-erase `rowIsFullyErasable` check. The enumeration
misses cases the rule covers:

- ED 1 with the cursor on the last column of row 0 blanks exactly row 0 and
  does not sever. Probe (10x2, `AAAAAAAAAA` in history wrapping into row 0,
  then `ESC[1;10H ESC[1J ESC[H cccc`, scroll off): `primaryHistoryText` is
  `"AAAAAAAAAAcccc"` with the tail record still open; ED 2 in the same
  stream gives `"AAAAAAAAAA\ncccc"`.
- DECSED 1 at the last column, same shape.
- Wide-pair expansion: ED 0 with the cursor on the tail half of a wide pair
  at columns 0-1 blanks all of row 0 once `eraseCells` widens the range, but
  the predicate reads the cursor column and says no.

The finding also asked for EL 0 at column 0, EL 2, and full-width ECH to
sever. That is rejected (RI1): D2 deliberately keeps the claim across a line
rewrite, `CR ESC[K` is the archetypal rewrite-in-place idiom, every reference
and DanTerm's own live seam keep the predecessor's claim across a line erase,
and severing would split real continuations (zle redrawing the tail row of a
wrapped prompt whose head is in scrollback). What is wrong in that area is the
prose: the funnel's doc comment says "every erase that blanks all of row 0",
and D2 says "EL modes 1 and 2 touch no wrap flag" (EL 0 does reset the row's
own flag). Both misstate a rule that is family-based, and the family boundary
is what keeps line rewrites continuing.

Premise checked: closing the open record (`LogicalLineStore.closeOpenRecord`)
reads no live cell, so the sever does not have to run before the erase; the
pre-erase ordering exists only to ask the selective-erase question that
`eraseCells` partly answers with its return value. That value says whether
selective erase left a survivor in the effective, wide-expanded range. It does
not say whether that range covered every column of the row.

## 2. Decision

`eraseDisplay` decides the sever once, after its erases, from whether row 0
was actually blanked in full. The propagated result combines whether the
effective erase range covered every column of row 0, including wide-pair
expansion, with whether selective erase left any survivor. The three enumerated
sites and `rowIsFullyErasable` go away. The funnel
`severHistoryWrapClaimForRowZeroErase` stays the single entry point; DECALN's
call is unchanged.

Scope: primary screen, ED and DECSED modes 0/1/2. EL, DECSEL, ECH, and ED 3
are untouched in behavior. Docs move with the code: the funnel's comment, the
`eraseLine` comment's "EL 2 rewrite-in-place" sentence, and the D2 amendment
state the family rule, name EL 0 as considered-and-kept, say the sever is a
history-seam-only rule justified by the width-change pull-back, and record
that the live seam keeps the predecessor's claim across the same ED (a known
asymmetry, not changed here).

## 3. Invariants

- I1. After any ED/DECSED on the primary screen, history's open tail record
  is closed iff every cell of live row 0 was blanked by that erase (wide-pair
  expansion and protected survivors included).
- I2. A display erase that leaves any cell of row 0 standing leaves the
  record open; the surviving prefix is a real continuation.
- I3. EL 0/1/2, DECSEL, and ECH at row 0 never close the record, whatever
  they blank.
- I4. DECALN closes the record on the primary screen; nothing closes it on
  the alternate screen.
- I5. `isSoftWrapped` of live rows and of retained rows is unchanged by this
  work except through I1; in particular the history text after ED 1 at the
  last column of row 0 equals the history text after ED 2 in the same stream.

## 4. Proof obligations

- PO1 (I1, I5): the byte-level A/B test from the finding -- ED 1 at the last
  column vs ED 2, identical retained text; plus the seam fixture's
  `scrollbackRow(at:)?.isSoftWrapped` observable for ED 1 at the last column
  and for the wide-pair-expansion case.
- PO2 (I2): existing preserving cases in
  `CSIEraseTests#wholeRowZeroErasesSeverTheScrollbackWrapClaim` keep passing;
  DECSED 1 at the last column with a protected cell on row 0 preserves.
- PO3 (I3): EL 0 at column 0 and full-width ECH on row 0 are pinned as
  preserving beside the existing EL 2 case.
- PO4 (I4): the existing primary-screen DECALN severing case keeps passing. A
  byte-level alternate-screen seam test establishes an open primary tail
  record, enters the alternate screen, applies ED and DECSED modes 0/1/2 and
  DECALN, returns to the primary screen, and proves that the primary record
  stayed open.
- PO5 (existing behavior): `CSIEraseTests`, `TerminalStaleWrapClaimTests`,
  `TerminalScrollbackTests`, `TerminalLogicalLineFoldTests` stay green.

## 5. Non-goals / accepted risks / rejected ideas

- NG1. Changing what EL, DECSEL, or ECH do to any wrap claim.
- NG2. Resolving the live-seam/history-seam ED asymmetry (live ED 0 at row
  N>0, column 0 keeps row N-1's claim). Recorded in D2 as an observation.
- RI1. The finding's rule -- sever on every erase that blanks all of row 0,
  implemented in `eraseCells`. Reverses D2's EL 2 decision, splits
  rewrite-in-place continuations, widens the seam asymmetry.
- RI2. Reference parity -- remove the ED sever. Reopens the width-change
  pull-back resurrection after `clear` that finding 13 fixed.
- RI3. A fourth enumerated site for ED 1 at the last column. Keeps the
  enumeration that produced this bug.

## 6. Implementation discretion

- How the "row 0 fully blanked" fact travels from `eraseCells` through
  `eraseLine` / `eraseEntireRow` to the single sever in `eraseDisplay`.

## Files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` --
  `eraseDisplay`, `eraseLine`, `eraseEntireRow`, `rowIsFullyErasable`,
  `severHistoryWrapClaimForRowZeroErase` (code and comments).
- `lib/TerminalCore/Tests/TerminalCoreTests/CSIEraseTests.swift` -- seam
  fixture `makeSeamTerminal`, `wholeRowZeroErasesSeverTheScrollbackWrapClaim`.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalAlternateScreenTests.swift`
  -- alternate-screen seam coverage for display erase and DECALN.
- `docs/research/31-logical-line-scrollback/decisions.md` -- the 2026-08-05
  amendment paragraph for D2 operation 2.

## Verification

- TDD: add PO1-PO4 cases first; ED 1 at the last column and the wide-pair
  case must fail on the current tree, while the EL/ECH pins and alternate-screen
  seam cases must pass before and after.
- Run `swift test --package-path lib/TerminalCore --filter CSIEraseTests` and
  `swift test --package-path lib/TerminalCore --filter TerminalAlternateScreenTests`
  into logs, then run the full `just test`.
- `scripts/docs-lint.py` after the D2 edit.
