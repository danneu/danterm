# WezTerm test portage scratch

Status: working scratch document. This is a case-audit notebook and task queue,
not a formal implementation plan or a commitment to make WezTerm behavior
normative.

## Objective

Audit the 56 semantic terminal tests in the pinned WezTerm
`term/src/test/` corpus, identify scenarios that add behavioral coverage to
TerminalCore, and adapt only those scenarios through DanTerm's public,
structure-insensitive seams.

The useful outcome is not necessarily 56 new tests. A complete and defensible
result can be a small number of adapted regressions plus an explicit ledger of
cases superseded by stronger DanTerm coverage, excluded by product policy, or
coupled to WezTerm implementation details.

Pinned source:

- repository: `references/wezterm`
- commit: `d69264df66fdcc928c7a30c673df108984fda821`
- license: MIT (`references/wezterm/LICENSE.md`)
- primary scope: `references/wezterm/term/src/test/`

## Ground rules

- Adopt scenarios, never WezTerm's verdict by default. Resolve compatibility
  expectations against DanTerm's capability contract, local xterm/spec
  references where needed, and independent implementations.
- Feed bytes to `TerminalCore.Terminal` or use the public interaction policy.
  Assert public cells, logical text, wrap identity, cursor state, scrollback,
  semantic effects, replies, and `TerminalDamage`. Do not reproduce WezTerm's
  `Line`, stable-row, `seqno`, cell compression, or renderer dirty-line model.
- Prefer a native Swift test for a small semantic scenario. Use a neutral replay
  fixture only when a multi-event byte/resize transcript benefits from the
  existing whole-stream and split-feed runner.
- Do not add a test merely to duplicate a stronger native or imported proof.
  Name the exact superseding test or fixture in the final ledger.
- Practice TDD honestly. For each candidate, first write the smallest expected
  public assertion, run it, and record whether it fails for the intended reason.
  If it already passes, decide whether it adds a meaningful regression boundary;
  otherwise classify it as superseded instead of pretending it drove a fix.
- Every adapted stream must be checked at least whole, bytewise, and at every
  relevant control/UTF-8 split. The neutral fixture runner already supplies this
  where a fixture is the right shape.
- Preserve DanTerm's deliberate divergences: UTF-8-only character handling,
  no terminal graphics in the initial replacement, no DECSLRM/horizontal
  margins, DanTerm's token-selection policy, byte-budgeted scrollback, and its
  internal-only OSC 133 model.
- Cite refetchable WezTerm source as `file#identifier`, never by line number.

## Current evidence

The earlier corpus survey called WezTerm a readable semantic case mine, then
closed Milestone 6 after finding no unique behavior needed for that support
matrix. That was a scope-level judgment, not a per-case disposition ledger.
`research/26/F8` later counted the 56
tests as 27 in `mod.rs`, 13 in `csi.rs`, 5 selection, 4 C0, 4 C1, and 3 image
tests. This scratch performs the missing per-case audit.

TerminalCore now has substantially broader coverage than when that survey was
written:

- `CSICursorMovementTests`, `CSIEraseTests`, `TerminalEditingTests`,
  `TerminalRepeatTests`, `TerminalModeTests`, `TerminalScrollRegionTests`, and
  the libvterm fixtures cover the basic C0/C1/CSI cases.
- `TerminalResizeTests`, `TerminalKittyAdaptedTests`, and the libvterm flow and
  reflow fixtures cover cursor attachment, hard/soft line identity, reflow, and
  height transfer.
- `TerminalSelectionTests`, `TerminalSelectionUnitTests`, and
  `TerminalInteractionPolicyTests` expose public selection and pointer-policy
  seams stronger than WezTerm's clipboard-oriented helper assertions.
- `TerminalRegionScrollbackTests` explicitly covers top-anchored regions,
  alternate-screen exclusion, scrollback accounting, and budget eviction.
- `TerminalHyperlinkTests` covers the exact OSC 8 pen behavior in WezTerm's
  semantic case: SGR preserves a link and DECSTR clears it.
- `TerminalDamageTests` exposes bounded row damage. WezTerm's `seqno` and stable
  row dirty tracking are different implementation contracts.
- The recent kitty port already used the balanced-parenthesis behavior in
  `wezterm-surface/src/hyperlink.rs#parse_with_parentheses` as comparative
  evidence for DanTerm's URL policy. It is not one of the 56 primary cases and
  should not be counted again.

## Primary corpus census

The counts below are exact for `term/src/test/`: 56 `#[test]` functions in six
files. Every one is now adjudicated; the census is frozen. All six tests that
entered the queue as candidates were adapted, into three Swift tests -- the
counts differ because upstream splits by transition where DanTerm's resize is
order-canonical, so several upstream cases collapse into one walk.

| File | Tests | Adapted | Superseded or policy-covered | Unsupported / implementation-coupled |
| --- | ---: | ---: | ---: | ---: |
| `c0.rs` | 4 | 0 | 4 | 0 |
| `c1.rs` | 4 | 0 | 4 | 0 |
| `csi.rs` | 13 | 0 | 13 | 0 |
| `selection.rs` | 5 | 1 | 4 | 0 |
| `image.rs` | 3 | 0 | 0 | 3 |
| `mod.rs` | 27 | 5 | 16 | 6 |
| Total | 56 | 6 | 41 | 9 |

The six adapted cases and where they landed, all in
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalWezTermAdaptedTests.swift`:

| Upstream test | DanTerm test |
| --- | --- |
| `mod.rs#test_resize_wrap_dectcm_issue_978` | `exactWidthHardBoundarySurvivesInterveningControl` |
| `mod.rs#test_resize_wrap_escape_code_issue_978` | same, second leg |
| `mod.rs#test_resize_2162` | `cursorAnchorSurvivesNarrowAndRewidenWalk` |
| `mod.rs#test_resize_2162_by_2` | same walk |
| `mod.rs#test_resize_2162_by_2_then_up_1` | same walk |
| `selection.rs#drag_selection` | `characterDragSnapsWideCellsAndClampsOutOfBounds` |

Yield: one live engine bug, fixed in `Terminal.swift`'s trailing-padding reflow
anchor and pinned natively by
`TerminalResizeTests#trailingBlankAnchorDefersWrapWhenContentFillsRow`. The
other two adapted tests are compositional regression boundaries that passed on
first run; each says so in its own preamble.

### `c0.rs` -- 4 tests, all likely superseded

- `test_bs`: column-zero clamp and ordinary backspace are covered by
  `TerminalTests#backspaceClampsAtZero`, the wide-tail case, and libvterm's
  state movement fixture.
- `test_lf`: LF moving vertically without carriage return is covered by the
  ground-control and scroll-region suites.
- `test_cr`: CR returning to column zero is covered natively and in libvterm.
- `test_tab`: default 8-column stops and right-edge clamp are covered more
  strongly by `TerminalTabStopTests`, including custom stops and pending-wrap
  behavior.

### `c1.rs` -- 4 tests, all likely superseded

These are 7-bit ESC forms despite the file name.

- `test_ind`, `test_nel`, and `test_ri`: public cursor, grid, margins, and
  scrollback outcomes are covered by `TerminalScrollRegionTests` and the
  libvterm scroll fixtures.
- `test_hts`: custom stop retention across width growth is covered directly by
  `TerminalTabStopTests#tabStopsAcrossResize`, with the additional shrink/grow
  case WezTerm does not exercise.

### `csi.rs` -- 13 tests, all likely superseded

- `test_789`: DCH vacated cells use the current background color. This is an
  exact subset of `TerminalEditingTests#characterEditingMovesAndClamps`.
- `test_vpa`: VPA default/one-based handling is in
  `CSICursorMovementTests#axisPositioning`. Its negative-parameter recovery is
  also subsumed by `CSIParserTests#malformedParameterAfterIntermediateRecovery`
  and the movement invalid-input matrix. Confirm the exact `CSI -2 d` stream is
  swallowed rather than adding a redundant test. **Confirmed swallowed**; see
  candidate 4 below for the arm-by-arm coverage argument.
- `test_rep`: REP count behavior is covered by `TerminalRepeatTests` and the
  libvterm REP fixtures.
- `test_irm`: insert mode is covered by `TerminalModeTests` and libvterm's
  insert/replace fixture.
- `test_ich`, `test_ech`, and `test_dch`: count defaulting/clamping, BCE,
  cursor retention, and wide-cell repair are all stronger in
  `TerminalEditingTests` and `CSIEraseTests`.
- `test_cup`, `test_hvp`, and `test_cha`: defaults, one-based coordinates,
  aliases, invalid forms, and clamping are covered by
  `CSICursorMovementTests`.
- `test_dl`: cursor retention, clipping to a region, overlarge counts, and no
  history push are covered by `TerminalEditingTests#lineEditingRegionSemantics`.
- `test_ed`: ED regions and BCE fills are covered by `CSIEraseTests`.
- `test_ed_erase_scrollback`: ED 3 preserving the viewport and clearing only
  retained history is covered by `CSIEraseTests#eraseDisplayScrollback` and the
  libvterm erase-scrollback fixture.

### `selection.rs` -- 5 tests, one composite candidate

- `drag_selection` = **adapted** as
  `TerminalWezTermAdaptedTests#characterDragSnapsWideCellsAndClampsOutOfBounds`,
  with two policy divergences (wide-tail snapping, off-grid clamping) recorded in
  its preamble. It was a candidate only for its combined pointer-policy shape:
  reverse drag, a start on a wide tail, multi-line serialization, and a drag
  beyond the viewport. The individual text behaviors are already covered by
  `TerminalSelectionTests`; use the public pointer-decision seam so the adapted
  test retains the upstream interaction scenario. Adapting it as direct
  `setSelection` calls would discard most of its value.
- `double_click_selection` is superseded by DanTerm's explicit terminal-token
  contract. WezTerm's word predicate is not DanTerm policy.
- `triple_click_selection` is superseded by trimmed logical-line range tests.
- `double_click_wrapped_selection` is superseded by the native token-across-soft-
  wrap and round-trip tests.
- `selection_in_scrollback` is superseded by deep-scrollback point-local range
  tests and viewport/selection attachment tests. DanTerm deliberately keeps
  selection coordinates in the retained stream rather than re-coordinating them
  to the browsed viewport.

### `image.rs` -- 3 tests, all out of scope

`kitty_zero_dimension_image_does_not_panic`, `kitty_valid_image_is_accepted`,
and `kitty_image_with_zero_pixel_dimensions_does_not_panic` exercise Kitty
graphics decoding and placement. Terminal graphics are an explicit initial
replacement non-goal in `plan-terminal-engine/04-terminal-core.md`. DanTerm's
generic parser fuzz/recovery contract still requires an unsupported APC payload
not to crash and later text to survive, but these PNG and pixel-geometry cases
should not be ported unless graphics enters the product scope.

### `mod.rs` -- 27 tests

Semantic/presentation cases, likely superseded or deliberately different:

- `test_semantic_1539` and `test_semantic`: WezTerm exposes per-cell semantic
  zones. DanTerm intentionally keeps OSC 133 engine-internal and does not expose
  per-cell semantics or prompt navigation. Its prompt redraw and event behavior
  is already tested in `TerminalOSC133Tests`, `TerminalKittyAdaptedTests`, and
  shell-dialect recordings.
- `issue_1161`: U+3000 must remain a double-width scalar rather than blank
  padding. The generated width corpus plus the native selection test that feeds
  and selects U+3000 already prove this through public state.
- `basic_output`: autowrap, ED/EL, and cursor-positioning composition is covered
  by the dedicated native suites and neutral fixtures.
- `cursor_movement_damage`: WezTerm's `seqno` dirty-line decisions are private
  renderer machinery. DanTerm's public row damage tests cover printing and
  cursor motion, including clamped/no-op motion.
- `test_delete_lines`: DL with full and partial regions is covered more strongly
  by the line-editing and damage suites.

Unsupported cases:

- `scroll_up_within_left_and_right_margins` and
  `scroll_down_within_left_and_right_margins`: require DECLRMM/DECSLRM, which
  TerminalCore does not implement.
- `test_dec_special_graphics`: legacy SCS designation is deliberately absorbed
  without changing DanTerm's UTF-8-only character model. Parser recovery is
  already covered; the glyph mapping should not be ported.
- `test_dec_double_width`: DEC double-width/double-height line attributes are
  unpromised and absent from TerminalCore.

Resize and reflow cases:

- `test_resize_2162_by_2_then_up_1`, `test_resize_2162_by_2`, and
  `test_resize_2162` are candidates for an exact public-state probe. The
  interesting scenario is cursor attachment at the end of `some long long
  text` while shrinking and widening by one or two columns, sometimes with a
  height change. `TerminalResizeTests` appears stronger in the abstract, but an
  exact replay will determine whether the issue's boundary walk is already
  pinned. Translate WezTerm's one-past-end cursor into DanTerm's last-cell plus
  `isPendingWrap` representation rather than copying coordinates literally.
- `test_resize_wrap` is superseded by native width-walk tests, kitty-adapted
  row split tests, and libvterm reflow fixtures.
- `test_resize_wrap_issue_971` is superseded by libvterm's adopted
  `flow-hard-boundary.json`: CRLF at the right margin produces a hard boundary
  that widening must not join.
- `test_resize_wrap_dectcm_issue_978` and
  `test_resize_wrap_escape_code_issue_978` are candidates as a paired
  extension: cursor-visibility or SGR controls between exact-width text and
  CRLF must not turn the hard boundary into a reflow join. Keep them only if
  existing pending-wrap/control coverage does not already prove the whole
  resize outcome.
- `test_resize_wrap_sgc_issue_978` remains out of scope because DEC Special
  Graphics designation is deliberately unsupported. Its general "an absorbed
  escape does not corrupt a later hard boundary" idea may inform the supported
  control variants, but do not adopt the line-drawing verdict.

Scrollback, Unicode, region, and hyperlink cases, likely superseded or policy-
different:

- `test_scrollup`: WezTerm uses a line-count history limit; DanTerm uses a fixed
  byte budget and has direct accounting/eviction tests.
- `test_ri`: sends U+008D/C1 RI. DanTerm's raw/C1 policy deliberately differs;
  the supported 7-bit `ESC M` behavior is already covered.
- `test_scroll_margins`, `test_region_scroll`,
  `test_alt_screen_region_scroll`, and `test_region_scrollback_limit`: the
  public behavior is covered more strongly by `TerminalRegionScrollbackTests`,
  including the DanTerm-specific byte budget and alternate-screen rule. Ignore
  WezTerm stable-row indexes and `seqno` dirty sets.
- `test_emoji_with_modifier` and `test_1573`: the unfiltered UAX #29 corpus and
  native terminal grapheme tests cover emoji modifiers and Hangul composition
  without making WezTerm's segmentation libraries normative.
- `test_hyperlinks`: OSC 8 link carry, SGR preservation, wrapping, link switch,
  and DECSTR clearing are direct subsets of `TerminalHyperlinkTests`.

## Candidate queue, ranked by expected value / cost

### 1. Exact-width hard boundary with intervening supported controls

Sources:

- `term/src/test/mod.rs#test_resize_wrap_dectcm_issue_978`
- `term/src/test/mod.rs#test_resize_wrap_escape_code_issue_978`

Why first: two tiny streams probe an integration seam between deferred wrap,
mode/style dispatch, CRLF, and later reflow. The individual behaviors are all
covered, but their ordering may not be. A single parameterized Swift test can
express both without a fixture.

Public assertions: hard line identity before and after widening, logical text,
viewport rows, and cursor attachment. Run whole, bytewise, and with splits
around the CSI, CR, LF, and resize event.

Likely result: either one compact adapted regression, or a named
`flow-hard-boundary.json`/pending-wrap proof that supersedes both.

### 2. Composite local drag normalization

Source: `term/src/test/selection.rs#drag_selection`.

Why second: it combines four selection risks that the native suite mostly
tests separately. Route press/move/release through the deterministic pointer
policy and apply its `TerminalSelectionMutation`; assert selected public text.
Include reverse direction, a start on a wide tail, a hard-line crossing, and a
point beyond the viewport. Do not reproduce clipboard ownership or WezTerm's
mouse helper.

Likely result: one adapted pointer-policy regression if the exact combined
gesture is absent; otherwise superseded by named interaction-policy tests.

### 3. WezTerm issue 2162 cursor walk

Sources:

- `term/src/test/mod.rs#test_resize_2162`
- `term/src/test/mod.rs#test_resize_2162_by_2`
- `term/src/test/mod.rs#test_resize_2162_by_2_then_up_1`

Why third: the regression is public and cheap to replay, but current cursor-
anchor tests probably already prove a stronger matrix. First run the exact
three event walks in a temporary/local test. If all pass and their boundary
states are already represented by `TerminalResizeTests`, classify them
superseded. If a distinct transition is missing, retain only the smallest case
that distinguishes it.

### 4. Negative CSI parameter recovery spot-check -- **superseded, nothing added**

Source: `term/src/test/csi.rs#test_vpa`.

This is not currently counted among the six candidates because the recent
kitty-derived malformed-CSI test appears stronger. Still run `CSI -2 d` once
while adjudicating the CSI group. Add nothing unless it exposes a different
recovery boundary.

Run, and it does not. DanTerm reproduces all four of WezTerm's VPA legs exactly
-- `CSI d` -> row 0, `CSI 2 d` -> row 1, and `CSI -2 d` leaving the cursor
untouched with following text intact -- so there is no behavioral gap.

The recovery path is also fully covered by decomposition rather than by luck.
`-` is 0x2D, an *intermediate* byte, so `CSI -2 d` is not a negative parameter
at all: it is `csiEntry -> csiIntermediate` (on `-`), then `csiIntermediate ->
csiIgnore` (on the param byte `2`). Both arms are already pinned, and the state
on arrival at the second arm is identical no matter which arm reached it:

- `csiEntry`'s `0x20...0x2F` arm is exercised by DECSTR (`CSI ! p`) in
  `TerminalQueryTests`, `TerminalSelectionTests`, and `TerminalHyperlinkTests`.
- `csiIntermediate`'s `0x30...0x3F` arm is exercised by
  `CSIParserTests#malformedParameterAfterIntermediateRecovery` (`CSI 2-3 @`),
  which additionally proves the following printable byte survives.

So no single-arm mutation exists that `CSI -2 d` would catch and the current
suite would miss. VPA itself is covered by `CSICursorMovementTests` and
`Fixtures/libvterm/state-movecursor.json`. This closes the `csi.rs` group.

## Ruled-out and superseded groupings

- Basic controls and supported CSI: 21 cases (`c0.rs`, `c1.rs`, `csi.rs`) map
  directly to stronger native and libvterm cases.
- Selection units: four of five cases are direct subsets of DanTerm's explicit
  token/logical-line policy and deep-scrollback tests.
- Graphics: three cases require a product feature explicitly outside the
  initial replacement.
- Horizontal margins and DEC line/charset presentation: four cases require
  unimplemented or deliberately rejected families.
- Internal semantic zones and dirty tracking: three cases assert WezTerm-owned
  representations rather than portable public behavior; DanTerm's corresponding
  public contracts are already tested.
- Unicode segmentation/width: three cases are covered by normative generated
  corpora plus terminal-level tests.
- Region scrollback and alternate behavior: four cases are superseded by a
  stronger DanTerm-specific contract, especially byte-budget eviction.
- Hyperlinks: one case is an exact subset of the native OSC 8 suite.
- Plain reflow and hard-boundary cases: two cases are already covered by native,
  kitty-adapted, and libvterm proofs.

These group totals overlap the candidate discussion only where a candidate is
expected to resolve to `superseded`; the per-file census table is the count of
record.

## Provenance plan

The kitty lint does not cover WezTerm and must not be cited as if it does.

For every retained adaptation, place provenance beside the test preamble:

```swift
// Adapted from term/src/test/mod.rs#test_resize_wrap_dectcm_issue_978
//   (WezTerm d69264d, body sha256:<12 hex>).
//   Divergence: asserts DanTerm hard-line identity and pending-wrap cursor state,
//   not WezTerm Line/seqno storage or one-past-end cursor coordinates.
```

If any case is retained, add a WezTerm-specific parity lint rather than
weakening or overloading `scripts/kitty-parity-lint.py`. It should:

1. recognize `// Adapted from <path>#<rust_fn>` citations;
2. require the current pin from `scripts/fetch-references.py`;
3. hash the Rust function from its `fn` signature through its brace-matched body
   with string/comment-aware scanning;
4. require an explicit `Divergence:` line, including `Divergence: none`;
5. exit successfully with a clear skip message when `references/wezterm` is
   absent; and
6. run as an independent step from `scripts/run-test-suite.sh`.

Use the shortest unambiguous commit (`d69264d`) in comments while verifying the
full pin. Preserve the MIT notice if a neutral fixture copies substantial source
material; translated byte scenarios with independently authored assertions
still carry the inline citation. Do not create a side manifest solely for
adopted Swift tests: the inline citation remains the single source of truth.

## Open decisions -- all resolved

- **Does a supported CSI between a full final cell and CRLF preserve enough
  deferred-wrap state for the subsequent CR/LF to establish a hard boundary,
  and is that whole ordering already pinned by existing tests?**
  Yes it preserves it, and no the ordering was not pinned. DanTerm flags a row
  soft-wrapped lazily at the next print rather than eagerly at fill time, which
  removes the bug class structurally; the composition is now pinned end to end.
- **Does the public pointer-policy suite already combine reverse,
  out-of-bounds, wide-tail, and multi-line drag behavior, or only prove each
  mechanism in isolation?** Reverse, wide-tail, and multi-line were each proven
  and are jointly safe. Out-of-bounds was not proven at all: no
  interaction-policy test drags to a coordinate outside the grid, and the
  selection arm has no viewport guard. That gap is what the adapted test holds.
- **Are the three issue 2162 walks observably stronger than the current
  cursor-anchor matrix, or merely concrete examples of it?** Stronger. They
  exposed a live reflow-anchor bug that destroyed a committed character, which
  the existing matrix missed because its narrow legs start from a pending-wrap
  cursor or clamp onto a blank.
- **If only one or two cases survive, is a dedicated parity lint worth its gate
  cost?** No, and body hashes were correspondingly not written. The plan's own
  default governs: hashes are the maintained contract a lint would enforce, and
  a Rust brace-matched body hasher plus a self-test is most of a second
  274-line script for six citations. Without hashes the lint would reduce to
  "the cited `fn` still exists at the pin" and "a `Divergence:` line is
  present" -- worth having, but not worth a duplicated gate step at this scale.
  **WezTerm pin drift is reviewed manually**, the same standing rule as every
  other `references/` citation in AGENTS.md. Two consequences to honor: no
  `body sha256:` comment may be written for a WezTerm citation while this holds,
  and a `just fetch-references wezterm` pin bump must re-read the six cited
  functions. Revisit if the corpus grows past roughly a dozen citations, or if
  the adjacent `vtparse` / `wezterm-escape-parser` clusters are ever mined --
  at that point generalize `kitty-parity-lint.py` over an upstream-config table
  rather than forking it.
- **Should the final 56-case disposition remain only in this scratch document,
  or become a small tracked ledger?** It has become the ledger, so it stays.
  The three adapted tests carry their own provenance and divergences inline, but
  the 41 superseded and 9 unsupported dispositions -- and the reasoning that
  produced them -- have no other home, and without them a future portage repeats
  the whole audit. Open question for the owner: whether it should move out of
  `docs/scratch/` (which implies disposable) to sit beside
  `agent-docs/reference-sources.md`. Left in place rather than restructured
  unilaterally.

## Concrete task plan

1. Freeze the census by recording all 56 identifiers and the pinned commit in
   the final ledger; correct any preliminary grouping discovered during probes.
2. Audit existing native test bodies for each of the six candidates, not just
   test names. Record the nearest stronger proof for every superseded result.
3. TDD-probe the two supported issue 978 streams. First add the smallest
   parameterized public-state test and confirm whether it fails for the expected
   hard-boundary/reflow reason.
4. TDD-probe the composite drag through public pointer policy. Retain only the
   scenario dimensions not already covered in combination.
5. Replay the three issue 2162 event walks. Translate cursor representation and
   compare them with the existing anchor tests before deciding whether any test
   stays.
6. Spot-check `CSI -2 d` recovery and close the CSI group as superseded unless
   it finds a genuinely different parser transition.
7. For every retained test, add Intent / Why it exists / Scenario and WezTerm
   provenance with an honest `Divergence:` statement. Implement the dedicated
   lint in the same change if hashes are used.
8. Run targeted TerminalCore tests after each TDD slice, then
   `swift test --package-path lib/TerminalCore`, `just test`, the provenance
   lint, and `git diff --check`.
9. Replace every `candidate` entry in this scratch with `adapted`,
   `superseded`, `unsupported`, or `policy-divergence`, naming the test/fixture
   or contract that supports the disposition.
10. Once every case is adjudicated and verification passes, remove this scratch
    document if the implementation change carries all durable provenance and
    disposition evidence. Keep it only if it has become the chosen permanent
    ledger.

## Other sparse-checkout tests worth noting, not yet in scope

The sparse WezTerm checkout contains substantially more Rust tests than the 56
semantic cases: 23 in `vtparse`, 58 in `wezterm-escape-parser`, 39 in
`wezterm-surface`, 52 in `termwiz`, 8 in `wezterm-cell`, and 3 in `pty` by the
current simple `#[test]` census. Do not quietly roll them into this portage.

Only three clusters are materially adjacent:

- `vtparse/src/lib.rs` has parser transition/recovery cases. Mine it in a
  separate parser audit only if the semantic CSI spot-check exposes a gap or a
  later fuzz failure needs a minimized source.
- `wezterm-escape-parser/src/parser/mod.rs` has OSC termination, SGR, ESC,
  DECSET, and malformed-protocol cases. Most assert parser ASTs DanTerm does not
  expose; use it as a targeted case mine, not a parity corpus.
- `wezterm-surface/src/hyperlink.rs#parse_with_parentheses` and
  `wezterm-surface/src/line/test.rs#double_click_range_bounds` overlap recent
  DanTerm URL and selection-boundary work. The former already informed the
  kitty port's balanced-parenthesis policy, and the latter appears superseded by
  native out-of-range selection queries.

The remaining `termwiz`, cell/surface storage, and PTY tests primarily exercise
WezTerm libraries, widgets, terminfo, compression, and command construction.
They are not evidence for TerminalCore behavior without a separately justified
mapping.

## Working log

- 2026-08-01: read the terminal-engine overview, reference-source rules,
  external-test survey, and corpus-expansion findings/decisions.
- 2026-08-01: verified WezTerm pin `d69264d` and MIT license locally.
- 2026-08-01: enumerated all 56 `term/src/test/` functions: 4 C0, 4 C1, 13
  CSI, 5 selection, 3 image, 27 aggregate semantic terminal cases.
- 2026-08-01: compared the cases against current TerminalCore suite names,
  relevant test bodies, fixture manifests, product non-goals, selection policy,
  region-scrollback behavior, resize proofs, and OSC 8/133 contracts.
- 2026-08-01: reduced the preliminary candidate queue to six tests in three
  themes. No code or tests were changed during this research pass.
- 2026-08-03: opened worktree `wezterm-test-portage` (branched from the
  experiment HEAD, not origin/master) and began adjudicating candidate 1.
- 2026-08-03: audited the DanTerm seams. Confirmed the issue 978 composition
  (exactly-full row -> supported control -> CRLF -> widen) is unpinned: the
  only exact-width hard-boundary proof, `Fixtures/libvterm/flow-hard-boundary.json`,
  has no resize event, and `rewrapDoesNotJoinUnwrappedRows` widens a grid whose
  first line is *not* full width -- the exact distinction 971/978 turns on.
- 2026-08-03: **candidate 1 = adapted (passing coverage addition, not a fix).**
  Added `TerminalWezTermAdaptedTests#exactWidthHardBoundarySurvivesInterveningControl`,
  three legs (no control / DECTCM / SGR), each run whole, bytewise, and at every
  single split point, asserting `screenText`, per-row `isSoftWrapped`, cursor,
  and `scrollbackRowCount` before and after a widen to 6 columns.
  It passed on first run: DanTerm sets a row's wrap flag lazily at the next
  print, so WezTerm's eager-flag bug class is structurally absent here.
  Non-tautology was established by mutation rather than by assertion: injected
  (a) eager wrap-flagging in `printNarrow`, (b) `dispatchCSI` committing a
  deferred wrap, and (c) reflow inferring a join from row fullness. The test
  failed under all three; the engine source was restored after each.
  Each individual link is superseded as noted above, so this is retained only
  for the end-to-end ordering, and the preamble says so.
- 2026-08-03: **candidate 3 (issue 2162) = adapted, and it found a live bug.**
  `TerminalWezTermAdaptedTests#cursorAnchorSurvivesNarrowAndRewidenWalk` is
  currently RED for the intended reason, with all grid text assertions passing.
  Feed `some long long text` (19 chars) at 20x4, leaving the cursor on the
  trailing blank at (0,19). Narrow to 19 columns and that blank ceases to exist;
  DanTerm anchors the cursor backward onto the final `t` -- `(0,18,false)` --
  instead of one-past-the-text. The drift then propagates: at 18 columns the
  cursor is `(1,0)` (on the `t`) rather than `(1,1)`, and rewidening to 20 never
  recovers, leaving `(0,18,false)` where it started at `(0,19,false)`.
  This is data loss, not a representation quibble, and it is confirmed by a
  DanTerm-native oracle rather than by WezTerm's verdict: after the narrow,
  feeding one `X` yields `some long long texX` -- the `t` is destroyed --
  where the unresized control correctly yields `some long long textX`.
  WezTerm's one-past-end `(19, 0)` is only what pointed at where to look; the
  bug reproduces entirely against DanTerm's own contract that printing must not
  overwrite committed output.
  Not covered by `boundaryAnchorFollowsReflowBoundary`, whose narrow leg starts
  from a *pending-wrap* cursor rather than a cursor resting on a trailing blank,
  nor by `trailingPaddingAnchorPreservesDistance`, which only ever narrows.
  Fix not yet attempted -- reflow anchoring is engine behavior, so it is being
  raised before any change is made.
- 2026-08-03: **candidate 3 fixed** in `Terminal.swift`'s trailing-padding anchor
  branch, using DanTerm's existing deferred-wrap spelling rather than adopting
  WezTerm's one-past-end cursor: when the reflowed content fills the row exactly
  and the squeezed-out blank was the cursor's own cell, the clamped column now
  carries `isPendingWrap: true`. A native regression test
  (`TerminalResizeTests#trailingBlankAnchorDefersWrapWhenContentFillsRow`) pins
  the `some long long textX` oracle directly, and was confirmed to fail without
  the fix. Full gate green afterward.
- 2026-08-03: **candidate 2 (`drag_selection`) = adapted, no bug.** Replayed the
  whole upstream composite through `decideTerminalPointer` (down / move / up at
  character granularity), asserting both the policy range and `selectedText`.
  Two legs diverge from WezTerm, both deliberately:
  (a) a drag anchored on a wide cell's second column selects the whole cluster
  (`"\u{1F480}skul"`), where WezTerm drops the emoji and yields `"skul"`. Ours is
  the rule `clusterAtomicity` already pins for every other entry point, and
  WezTerm's makes a wide character unselectable from its right half.
  (b) a drag past the last row clamps to the last retained content, where WezTerm
  picks up the blank row and copies a trailing `"\n"`. Ours is the rule
  `a stripped trailing blank endpoint clamps to retained content` already states.
  Neither panics, which is what the upstream case is actually guarding.
  Non-tautology: the off-grid legs discriminate -- dropping the row clamp in
  `normalizedCellPosition` traps on "Index out of range" here while all of
  TerminalInteractionPolicyTests, TerminalSelectionTests,
  TerminalSelectionUnitTests, and TerminalHyperlinkInteractionTests still pass.
  The wide-cell legs do **not** discriminate and the preamble says so: snapping
  is enforced independently at `normalizedCellPosition`, at the drag anchor's
  pin/resolve round trip, and at `setSelection`, so no single mutation moves
  them. They are retained as the executable statement of divergence (a).

- 2026-08-03: **candidate 4 (`CSI -2 d`) = superseded, nothing added.** DanTerm
  reproduces all four VPA legs exactly. `-` is 0x2D, an intermediate byte, so
  the stream is `csiEntry -> csiIntermediate -> csiIgnore`; both arms are
  already pinned (DECSTR `CSI ! p` and the kitty `CSI 2-3 @` case) and the
  second arm cannot tell which arm reached it. This closes `csi.rs`.
- 2026-08-03: **census frozen, all open decisions resolved, done condition met.**
  Six adapted upstream cases across three Swift tests, one engine bug fixed,
  no parity lint (manual pin review, so no body hashes were written). Gate green.

## Done condition

This portage is done when:

- all 56 primary tests have one explicit, evidence-backed disposition;
- every retained scenario asserts only DanTerm public behavior and documents
  its divergence from WezTerm's assertion surface;
- every retained scenario was introduced with an honest failing test, or is
  explicitly recorded as a passing coverage addition with a reason it is not
  redundant;
- whole/chunked input behavior is verified where bytes are involved;
- provenance is pinned and mechanically checked if body hashes are claimed;
- targeted and full TerminalCore tests, `just test`, and formatting/diff checks
  pass; and
- unsupported features and deliberate policy differences remain explicit
  rather than being silently normalized to WezTerm.

### Status: met, 2026-08-03

Each clause, with its evidence:

- all 56 dispositions are recorded, and the census table above is frozen;
- the three adapted tests assert only public DanTerm state (`screenText`,
  `geometry`, `selectedText`, the pointer decision), and each carries an
  explicit `Divergence:` paragraph;
- one test was introduced red for the intended reason (issue 2162) and led to
  an engine fix; the other two are recorded as passing coverage additions with
  their non-redundancy argued by injected mutation, including the honest note
  that the wide-cell legs of `drag_selection` do *not* discriminate;
- `exactWidthHardBoundarySurvivesInterveningControl` runs its stream whole,
  bytewise, and at every single split point;
- no body hashes are claimed, so nothing mechanical is owed -- see the parity
  lint decision above for the standing manual-review rule this commits to;
- `bash scripts/run-test-suite.sh` passes all 61 steps, `swift test
  --package-path lib/TerminalCore` passes 813 tests, `git diff --check` clean;
- the policy differences that survive are named in the tests themselves: wide
  cells snap outward, off-grid drag ends clamp to retained content, selection
  coordinates stay in the retained stream, DEC Special Graphics is not
  implemented, and terminal graphics stay out of scope.
