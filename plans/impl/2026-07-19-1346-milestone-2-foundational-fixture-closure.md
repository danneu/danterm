# Milestone 2 slice 8: foundational fixture closure and exit audit

## Problem

Milestone 2 has three open roadmap boxes (`plan-terminal-engine/14-roadmap.md`
lines 62-77). The fixture-tranche gate's Slice 7 judgment names the remaining
work: the provenance ledger covers sixteen libvterm files, but the early
parser/encoding/Unicode families (`02parser`, `03encoding_utf8`,
`10state_putglyph`, `11state_movecursor`, `61screen_unicode`) and the
vttest-derived families still lack explicit dispositions. The two
Unicode/reflow gates have never been audited against the test suite that now
exists. This slice closes the fixture-tranche gate and the foundational Unicode
gate (Gate A); the reflow gate (Gate B) and the Milestone 2 header stay open
because Gate B's scrolled-viewport-anchor clause has no engine-side behavior to
prove until Milestone 6 (see below).

Evidence gathered during planning:

- The neutral replay runner and machine-checked ledger already exist
  (`lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift`,
  `Fixtures/libvterm-manifest.json`, 30 fixtures, pinned commit `934bc2f`).
- Adopting `11state_movecursor` exposes four real dispatch gaps: CSI `a`
  (HPR), `e` (VPR), `I` (CHT), `Z` (CBT) are missing from
  `Terminal.dispatchCSI` while every neighboring final is implemented.
- `02parser` cannot be adopted verbatim: DanTerm has no public parser-event
  surface, treats raw ground C1 bytes as malformed UTF-8, absorbs C0 inside
  OSC/DCS/SOS strings (VT500 rule; upstream executes them), and terminates
  only OSC at BEL (upstream also ends DCS at BEL).
- `03encoding_utf8` accepts U+1FFFFF; DanTerm caps at U+10FFFF with
  maximal-subpart U+FFFD replacement (pinned by `TerminalInputStreamTests`).
- libvterm truncates combining marks at five; DanTerm is scalar-exact.
- Gate B's "scrolled viewport anchors" clause is not representable in
  TerminalCore's public API (no viewport-offset concept; doc 05 delegates
  browsing anchors to `08-input-interaction.md`, a Milestone 6 seam).

## Decision

Advance Milestone 2 by finishing the fixture ledger, fixing the gaps adoption
exposes, closing the two gates whose behavior is provable now, and leaving Gate
B and the Milestone 2 header open — fixture/test/docs work plus four tiny CSI
dispatch additions. A checked box must name proven behavior (roadmap rule; I6);
Gate B's scrolled-anchor clause cannot, so it does not close this slice.

1. **Implement HPR, VPR, CHT, CBT** in `Terminal.dispatchCSI`, TDD-first.
   HPR/VPR alias the existing CUF/CUD motion (no horizontal margins exist);
   CHT/CBT walk the existing tab-stop set and route through positioned-cursor
   movement so they clear pending wrap and cluster attachment like other CSI
   motion (unlike raw HT, whose pending-wrap preservation is already pinned).
2. **Author neutral fixtures** adopting/adapting the five target files, in
   the existing JSON replay format with provenance, asserted through public
   state only: parser CSI/escape/cancel behavior, string-sequence (OSC/DCS/
   APC/PM/SOS) absorption, UTF-8 boundary/malformed handling, putglyph
   placement, the full movecursor sweep (including the four new finals), and
   screen-unicode cases. Adapted expectations follow DanTerm's recorded
   deviations, authored from actual engine output test-first.
3. **Extend the ledger to 31 files** with a disposition and rationale for
   every upstream case heading: the five target files, `14state_encoding`
   (11 charset cases out-of-scope — legacy character-set translation is
   outside the composed-UTF-8 support matrix; its "Mixed US-ASCII and UTF-8"
   and "Default" cases are adoptable), the eight `90vttest_*` files
   (out-of-scope: full-session vttest recordings staged as Milestone 4
   acceptance evidence, whose supported movement/wrapping/tab/origin behavior is
   already covered by the adopted libvterm state fixtures; each file's rationale
   must be true of that file — only `90vttest_01-movement-1` opens with DECALN,
   so the DECALN rationale is reserved to it), and `92lp1640917` (out-of-scope:
   mouse reporting is Milestone 6). The manifest-coverage test's hardcoded
   expectations grow in lockstep.
4. **Record three new deviations** in the manifest and its pinning test:
   raw C1/beyond-U+10FFFF input replaced by U+FFFD; scalar-exact combining
   retention (no five-mark truncation); VT500 string states (C0 absorbed
   inside strings, only OSC terminates at BEL).
5. **Audit the two Unicode/reflow gates** against existing suites. Planning
   already mapped every clause to named evidence; the only candidate gap is
   whether width-reflow round-trips a decomposed combining cluster —
   `widthWalkConservesFullHistory` already width-walks one (`espan` + U+0303
   with wide and ZWJ-emoji cells), so the audit is expected to conclude no new
   test is needed. Gate B stays open: its scrolled-viewport-anchor clause has
   no engine-side behavior to prove (no viewport-offset concept; doc 05
   delegates browsing anchors to `08-input-interaction.md`, a Milestone 6
   seam), and I6 forbids checking a box on an unproven clause.
6. **Update the roadmap**: add the Slice 8 entry, check Gate A and the
   fixture-tranche gate with their evidence, and rewrite the fixture gate's
   judgment for Slice 8. Leave Gate B and the Milestone 2 header unchecked,
   with a judgment recording that the scrolled-anchor clause is Milestone 6
   proof debt.

## Invariants

- I1: Every fixture passes identically under authored, bytewise, and the
  runner's split chunking (exhaustive at every offset for feed events at or
  under 64 bytes, representative quartile offsets above) — chunk boundaries
  never change the asserted state.
- I2: Every case heading in all 31 classified libvterm files has a
  disposition in {adopted, adapted, superseded, out-of-scope} with a
  non-empty rationale, machine-checked by the manifest-coverage test.
- I3: Each upstream case's disposition and rationale is the authoritative
  record of whether DanTerm's output diverges — a divergence is dispositioned
  `adapted` or `superseded` with a rationale that names it; an `adopted` case
  asserts upstream-identical output. That adopted claim is checked by the
  recorded eye cross-check (Verification), which covers every case, not by an
  automated oracle. The manifest's global `recordedDeviations` pins the
  headline deviations as declared metadata; it is not an exhaustive divergence
  index.
- I4: HPR/VPR/CHT/CBT clear pending wrap and cluster attachment exactly like
  existing CSI cursor movement; raw HT behavior is unchanged.
- I5: Fixture assertions use only public inspection views (no `@testable`
  internals in fixture expectations).
- I6: A roadmap box closes only with its behavioral evidence named in the
  adjacent judgment text; unprovable clauses are recorded as explicit
  later-milestone debt, not silently dropped.

## Proof obligations

- PO1 (I1): `TerminalFixtureTests.replayFixtures` over the new fixtures.
- PO2 (I2, I3): `libvtermManifestCoverage` updated to pin all 31 files, their
  case sets, and the seven recorded deviations, and to assert that every case
  carries a valid disposition with a non-empty rationale. This pins the
  declared ledger metadata; it does not by itself detect divergence — an
  `adopted` case's upstream conformance is established by the eye cross-check
  (Verification), which covers every case including adopted.
- PO3 (I4): failing-first tests in `CSICursorMovementTests` (HPR/VPR beside
  the CUF/CUD cases) and `TerminalTabStopTests` (CHT walking and clamping at
  the right edge, CBT walking and clamping at column 0, count 0→1) that assert
  all four finals clear pending wrap and open cluster attachment — the
  combining-mark scenario exercises a last-column CHT (clamped at the right
  edge) and a last-column CBT (walking back to the preceding tab stop).
- PO4 (gate A): the audit cites `widthWalkConservesFullHistory` as the
  decomposed-cluster reflow round-trip evidence; a new test is added only if
  the audit finds that citation does not in fact cover the clause.
- PO5: `just test` green (all four packages + purity lints) before the docs
  commit that closes the boxes.

## Non-goals

- Charset translation (G0-G3 designation, SS2/SS3, LS*R) — out-of-scope
  dispositions, no implementation.
- DECALN, DECSCA/selective erase, DA2/DECRQSS replies, mouse reporting,
  horizontal margins — stay deferred as already recorded.
- A public parser-event or viewport-offset API — adaptations assert through
  existing public state.
- vttest replay infrastructure — classification only this slice.

## Accepted risks

- No differential oracle this slice: `adopted` cases' conformance to upstream
  is verified by the recorded eye cross-check against `references/libvterm/t/`,
  not by replaying libvterm. Automated differential replay is not scheduled
  here; a differential runner (Termless or equivalent) is evaluated
  non-gating in Milestone 4 and used conditionally in Milestone 6 if retained
  (`docs/research/1-external-tests.md`).
- Fixture-provenance `recordedDeviations` is free-form authoring provenance,
  not a machine cross-link to the manifest's global deviation list; the
  machine-checked record of divergence is the manifest case disposition (PO2).

## Implementation discretion

- Fixture file count/naming (planning sketched six: parser-csi,
  parser-strings, encoding-utf8, state-putglyph, state-movecursor,
  screen-unicode) and per-case rationale wording.
- Commit slicing, provided each commit is green and the manifest and its
  pinning test change together.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (dispatchCSI)
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift`
- `lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/libvterm-manifest.json`
- `lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/libvterm/*.json` (new)
- `lib/TerminalCore/Tests/TerminalCoreTests/{CSICursorMovementTests,TerminalTabStopTests,TerminalResizeTests}.swift`
- `plan-terminal-engine/14-roadmap.md`

## Verification

- Targeted: `swift test --package-path lib/TerminalCore` (optionally
  `--filter TerminalFixtureTests`).
- Full gate: `just test` before closing roadmap boxes.
- Reference cross-check: every adopted and adapted case compared by eye
  against the upstream case blocks in `references/libvterm/t/` during
  authoring — adopted cases to confirm upstream-identical output,
  adapted/superseded cases to confirm the recorded rationale.

## Commit progress

- [x] 1. Complete the foundational fixture tranche and cursor dispatch coverage
- [x] 2. Audit and record the Milestone 2 gate status
