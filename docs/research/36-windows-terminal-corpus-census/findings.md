# Findings -- the unweighed windows-terminal corpus

Append-only. One entry per stable ID. See
[README.md](README.md) for the doc's purpose, rules, and task ledger.

Cross-doc IDs are qualified: `F1` is this doc's, `26/F9` is doc 26's.

### F1 -- `adapterTest.cpp` classified: 53 cases, zero survive the mutation bar

- Status: complete.
- Date and investigator: 2026-08-25.
- Commit and worktree state: `f016f5b6`, corpus pinned at `1cea42d4`.
- Commands, inputs, or reproduction: all 53 `TEST_METHOD`s in
  `references/windows-terminal/src/terminal/adapter/ut_adapter/adapterTest.cpp`
  read against `lib/TerminalCore/Sources/TerminalCore/` and the native suite,
  split across two independent readers.
- Result: 22 `superseded`, 28 `out-of-scope`, 3 proposed novel, of which the
  first was falsified (below) and two remain under test in F7.
- Observation: the out-of-scope set is dominated by DCS-carried reports --
  DECTABSR, DECCIR, DECRQSS, DECDLD soft fonts, DECAUPSS, DECRQUPSS, DECDMAC --
  all blocked by the same fact: `Terminal.swift` has no DCS dispatch at all.
  `EscapeAbsorber.swift:479-530` absorbs DCS bodies and retains nothing. A
  second cluster (DECRQDE, PPA/PPR/PPB/NP/PP, DECPCCM, the page field in
  DECXCPR) is blocked by DanTerm having a single page with no page memory.
- Inference: one capability decision -- implement DCS dispatch -- unblocks
  seven upstream cases at once. That is the same shape as the DECRQCRA finding
  from the esctest2 work: a single missing capability gating a large block of
  external coverage. It is a support-matrix decision, not a test decision.
- **Falsified novel candidate.** The first reader proposed
  `GraphicsPersistBrightnessTests` as `adapted`, on the reasoning that intensity
  and indexed-color selection cross in no native test: `TerminalStyleTests`
  `attributes` never sets a color, and `semanticPaletteColors` walks 30-37 and
  90-97 without ever reading `bold`. Both statements are true. The conclusion is
  still wrong. Two mutations settle it:
  - `case 90...97` additionally setting `currentStyle.bold = true` (the classic
    bright-is-bold aliasing bug): **caught**, 1768 issues, by the adopted
    libvterm `state-pen` fixture at `TerminalFixtureTests.swift:743`.
  - `case 30...37` additionally clearing `bold`: **caught**, by
    `TerminalStyleTests:256`, `:399`, `TerminalCellStyleTests:89`, `:96`, `:97`,
    `:263`, `TerminalSavedCursorTests:22`, `:30`,
    `RenderColorResolutionTests:216`, and `TerminalFixtureTests:56`.
  So the crossing is pinned, just not by the test whose name suggests it. The
  disposition is `superseded`, and the evidence is the libvterm fixture plus the
  cell-style suite rather than any single style test.
- Competing interpretations: none survive. A reading-based census cannot see
  coverage that arrives through a replayed fixture, because the fixture asserts
  a whole pen at once rather than naming the attribute in a test title.
- Uncertainty: none on this case.
- Next action: this is the second time in two sessions that the mutation bar has
  overturned a reading-based verdict (the first was the charset re-adjudication
  in `06e158b4`). Recorded as `F8`.

### F2 -- input encoding: 29 cases, four novel candidates, one specification disagreement

- Status: complete; candidates under test in F7.
- Date and investigator: 2026-08-25.
- Commands, inputs, or reproduction: all 25 `TEST_METHOD`s in
  `InputEngineTest.cpp` and all 4 in `kittyKeyboardProtocol.cpp`, read against
  `TerminalInputEncoding.swift`.
- Result: 24 of the 25 `InputEngineTest.cpp` cases are
  `implementation-coupled`. windows-terminal's InputEngine runs in the reverse
  direction -- it parses key sequences back into Win32 `INPUT_RECORD` values for
  ConPTY -- and DanTerm has no such path. The cases assert `wVirtualKeyCode`,
  `dwControlKeyState`, `ENHANCED_KEY`, `MOUSE_EVENT` records, and private
  `VTStates` values. One case, `AltIntermediateTest`, has an encoder half that
  is DanTerm behavior.
- `kittyKeyboardProtocol.cpp`'s `KeyPressTests` is a 130-row data table. Rows
  whose flag set is `D` (disambiguate, kitty flag 1) are the adoptable subset;
  rows using flags `E`, `A`, `K`, or `T` need capabilities DanTerm masks off at
  `Terminal.swift:7541` and `:7554`. The three `KeyRepeat*` cases are all
  `out-of-scope` on kitty flag 2 (report event types), which DanTerm does not
  implement -- `encodeTerminalKey` has no event-type parameter
  (`TerminalInputEncoding.swift:133`).
- Observation, and the sharpest result in this doc: **DanTerm and
  windows-terminal disagree byte for byte on nine rows**, the unmodified keypad
  keys under kitty flag 1. windows-terminal expects the functional code always
  (`ESC [ 57399 u` for Numpad0). DanTerm emits the key's printable text (`"0"`)
  and reserves the functional code for the modified case
  (`TerminalInputEncoding.swift:457-466`, gated by `isPrintableKeyText` at
  `:474`).
- Inference: **the specification supports DanTerm.**
  `references/kitty/kitty/key_encoding.c:435-446` computes
  `has_text = e->text && !startswith_ascii_control_char(e->text)` and, with only
  flag 1 set, returns `SEND_TEXT_TO_CHILD` before any CSI u encoding runs.
  DanTerm's `isPrintableKeyText` is the same test.
  `references/kitty/docs/keyboard-protocol.rst:354` states the matching narrow
  rule: "all **non text** keypad keys will be reported as separate keys with
  `CSI u` encoding".
- Competing interpretation, and why it loses: `keyboard-protocol.rst:540-541`
  says "All keypad keys are reported as their equivalent non-keypad keys. To
  distinguish these, use the disambiguate flag", which reads as windows-terminal
  implemented it. But that sentence describes the legacy table, and kitty's own
  encoder does not behave that way. Where prose and reference implementation
  disagree, the reference implementation is the stronger evidence about what
  applications actually see.
- Uncertainty: this was adjudicated by reading kitty's C, not by running kitty.
  A live capture would be stronger. It is not worth taking on unless someone
  proposes changing DanTerm's behavior to match windows-terminal.
- Next action: the four novel candidates go to F7's mutation bar. The keypad
  disagreement becomes a `recordedDeviations` entry if any kitty row is adopted.

### F3 -- `inputTest.cpp` and `StateMachineTest.cpp`: 16 cases, four novel candidates

- Status: complete; candidates under test in F7.
- Date and investigator: 2026-08-25.
- Result: 2 `superseded`, 4 `out-of-scope`, 6 `implementation-coupled`,
  4 proposed `adapted`.
- Observation: `StateMachineTest.cpp`'s pass-through cases assert ConPTY's
  `pfnFlushToTerminal` callback topology, which DanTerm deliberately does not
  have -- `EscapeEvent` (`EscapeAbsorber.swift:4-10`) has no pass-through case.
  Their behavioral residue is covered by
  `TerminalInputStreamTests:chunkBoundaryInvariance`, whose fixture list already
  includes the GH#3080 OSC-split byte string at every 2- and 3-way split.
- Observation: the four `out-of-scope` cases name four absent input modes --
  DECBKM (backarrow key), DECARM (auto-repeat), 8-bit C1 key output, and
  Ctrl+digit control bytes. The first three are deliberate;
  the fourth is a defect, recorded as F4.
- Inference: `DcsDataStringsReceivedByHandler` is the most interesting of the
  four candidates, because `TerminalInputStreamTests:payloadControlsAreDiscarded`
  proves NUL and BEL are *swallowed* inside a DCS, which makes CAN/SUB aborting
  it precisely the untested asymmetry. `cancellationAbortsSequence` fires CAN
  and SUB inside a CSI, never inside a DCS.
- Next action: F7.

### F4 -- Ctrl plus `/` or a digit sends the literal character, not its C0 byte

- Status: confirmed defect, unfixed.
- Date and investigator: 2026-08-25.
- Commit and worktree state: `f016f5b6`.
- Provenance: found independently by two readers working different files
  (`kittyKeyboardProtocol.cpp` and `inputTest.cpp`), then verified directly.
- Result or artifact paths:
  `lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift:400-409`.
- Measurements or examples: `legacyControlBytes` handles `0x20`/`0x40` (NUL),
  `A-Z`, `a-z`, `0x5B...0x5F`, and `0x3F` (DEL). Everything else falls to
  `default: Array(String(scalar).utf8)` and returns the character unchanged.
- Observation: `/` (0x2F) and the digits `2`-`8` (0x32-0x38) are missing.
  kitty's authoritative table, copied verbatim into
  `references/ghostty/src/input/key_encode.zig:762-775`, maps `'/' => 31`,
  `'2' => 0`, `'3' => 27`, `'4' => 28`, `'5' => 29`, `'6' => 30`, `'7' => 31`,
  `'8' => 127`. windows-terminal agrees: `inputTest.cpp:666` expects
  Ctrl+`/` -> 0x1F and `:721-736` expects the same digit row.
  DanTerm already gets `?` -> 127, `@` -> 0, space -> 0, and `\ ] ^ _` right,
  so the table is right in every case except these nine scalars.
- Inference: this reaches users. `app/SwiftTerminalSessionView.swift:930-937`
  routes an unhandled Ctrl chord into `encodeTerminalKey` as `.character`, so
  Ctrl+`/` sends `"/"` today. Ctrl+`/` is 0x1F, which is `C-_`, which is undo in
  readline and in Emacs. The digits are less used but equally wrong.
- Competing interpretations: none. Three independent sources (kitty's encoder,
  ghostty's copy of it, windows-terminal's test) agree on the same table, and
  DanTerm implements most of that table already -- so this is an incomplete
  case list, not a deliberate policy.
- Uncertainty: not verified against a live shell. The fix is a nine-scalar
  addition to one switch, so a failing native test can be written first and will
  settle it without a live capture.
- Next action: fix under TDD -- the failing test first, per the repository rule.
  Not part of this doc's corpus work; it is a defect this doc found.

### F5 -- style and color policy: 12 cases, zero novel, two recorded deviations

- Status: complete.
- Date and investigator: 2026-08-25.
- Result: 8 `superseded`, 4 `implementation-coupled`, zero adoptable.
- Observation: `H3` is confirmed as a *method* and rejected as a *yield*.
  Judging these cases by the policy they encode rather than the C++ API they use
  was the right call -- 8 of 12 turned out to encode a real policy question
  reachable from a byte stream, where a naive reading would have called all 12
  coupled. But every one of those 8 policies is already pinned natively, so the
  yield is zero.
- The six policy questions, with both answers:
  1. Does reverse video swap resolved or stored colors? Both swap resolved.
     Agree. Pinned by `RenderColorResolutionTests:reverseDimAndHiddenPipeline`.
  2. What does a default color resolve to under reverse? Both resolve first,
     then swap. Agree. Same test. This is the corner where an implementation
     that swapped stored `.default` values would silently no-op.
  3. Does bold brighten an indexed color? Upstream yes (its `IntenseIsBright`
     default); DanTerm never. **Disagree, defensibly** --
     `references/xterm/ctlseqs.txt:1191` defines SGR 1 as Bold with no color
     effect, and brightening is an opt-in resource in xterm. DanTerm's answer is
     the spec-literal one. Pinned by
     `RenderColorResolutionTests:rgbAndBoldColorIndependence`.
  4. Where does dim apply relative to the reverse swap? Upstream applies faint
     to the stored foreground *before* the swap, so under reverse the faint
     color lands in the background slot. DanTerm applies dim *after* the swap,
     so it always darkens the color actually drawn as text
     (`RenderColorResolution.swift:325-334`). **Disagree.** DanTerm matches
     ghostty (`references/ghostty/src/renderer/generic.zig:2878`). Recorded
     deviation, not a bug.
  5. What does hidden do? Upstream forces resolved foreground := background.
     DanTerm keeps `hidden` as a flag and emits no text and no decoration run
     (`RenderFramePlanner.swift:479`, `:502`). Same output, stronger form --
     DanTerm also suppresses underline and strikethrough, which the fg:=bg trick
     does not.
  6. What does a stored color resolve to per slot? Agree, and DanTerm covers
     more (the xterm 6x6x6 cube and the 24-step gray ramp).
- Rejected candidate, and why: upstream's `TestReverseDefaultColors` covers the
  *mixed* case, one side explicit and one side default, under reverse. DanTerm
  pins default-plus-default and explicit-plus-explicit but not one of each. It
  was rejected because the bug it would guard -- resolving after swapping
  instead of before -- already fails the default-plus-default assertion. A
  fixture there adds a passing test and no new failure mode.
- Inference: this file pair is the clean confirmation of `H2`'s sharp form. Four
  cases are claims about *windows-terminal's* `TextAttribute` class storage
  (the legacy Win32 attribute word, `COMMON_LVB_*` meta bits) and can never go
  stale, because nothing about DanTerm makes them true or false. Filing them as
  `out-of-scope` would have manufactured four standing claims about DanTerm that
  a future engine change could silently invalidate.

### F6 -- reflow scenarios, `ut_types`, and the ICU adapter

- Status: complete; candidates under test in F7.
- Date and investigator: 2026-08-25.
- Commands, inputs, or reproduction: `ReflowTests.cpp`'s single `TEST_METHOD`
  (`TestReflowCases`, `:683`) is driven by a 15-entry `testCases[]` table, each
  entry a chain of one to four successive resizes. All 15 classified
  individually, plus `UtilsTests.cpp` (10), `CodepointWidthDetectorTests.cpp`
  (4), `UuidTests.cpp` (2), and `UTextAdapterTests.cpp` (1).
- Result: of the 15 reflow scenarios, 4 `superseded`, 1 `out-of-scope`,
  7 `implementation-coupled`, 3 proposed novel. Of the other 17 cases, 3
  `superseded`, 4 `out-of-scope`, 9 `implementation-coupled`, 1 proposed novel.
- Observation: the seven coupled reflow scenarios are coupled for **one shared
  reason**, and it is a model difference rather than a capability gap.
  windows-terminal builds its reflow buffer with zero scrollback
  (`ReflowTests.cpp:614`), so a row pushed above the viewport by a narrowing is
  destroyed and its content is gone. DanTerm has no discard path at all: reflow
  displaced rows enter the one history stream (`Terminal.swift:5764`) and come
  back when the width grows again (`:5716`). Six of the seven also assert
  upstream's `REFLOW_JANK_CURSOR_WRAP` behavior -- padding rows synthesized and
  marked force-wrapped purely to preserve the cursor's column across a later
  widening. DanTerm clamps a padding cursor to the right margin instead
  (`Terminal.swift:6213`) and has no forced-wrap provenance to set
  (`MarginProvenance` at `:279` carries only `.content`, `.erase`, `.wideWrap`).
- Inference: this is the strongest evidence in the doc for `H2`'s sharp form.
  These scenarios are not "DanTerm cannot do this" -- they are "windows-terminal
  compensates for a buffer model DanTerm does not have." Filing them
  `out-of-scope` would record seven standing claims about DanTerm that are not
  about DanTerm at all. Doc 31's logical-line scrollback is what makes the
  compensation unnecessary.
- Observation, Unicode: `CodepointWidthDetectorTests` asserts exactly one
  width-policy codepoint (`U+2192` at ambiguous width 1 and 2), and DanTerm
  agrees with upstream's default. **No width disagreement is asserted by these
  tests.** Two disagreements do exist outside them, in upstream's
  `unicode_width_overrides.xml`, and are recorded here so a future adoption in
  this area does not rediscover them: `U+4DC0..U+4DFF` Yijing hexagrams are 2 in
  DanTerm (EAW=W) and overridden to 1 upstream; `U+FE20..U+FE2F` combining half
  marks are 0 in DanTerm (nonspacing mark) and 1 upstream. DanTerm pins Unicode
  17.0.0 (`UnicodeWidthTests:unicodeVersionIsPinned`); windows-terminal
  generates from 16.0.0 (`CodepointWidthDetector.cpp:46`).
- Observation: upstream's `GraphemeBreakTest` is `superseded` in the strong
  direction -- DanTerm replays the whole official UAX #29 corpus at 17.0.0,
  where upstream's table is 16.0.0 and omits GB3, GB9c, GB11, and GB12/13, all
  of which DanTerm implements.
- Uncertainty: the three reflow candidates are the least certain in the doc.
  They assert row-split positions and wrap flags, which DanTerm's existing
  resize tests mostly do not -- `widthWalkConservesFullHistory` asserts only
  `fullHistoryText`, which is blind to where a split falls. That makes them look
  novel on reading, and reading is exactly what `F8` says cannot settle it.
- Next action: F7.

### F9 -- dead store pair in the widening history pull-back

- Status: confirmed, unfixed, not a live defect.
- Date and investigator: 2026-08-25.
- Result or artifact paths:
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:5723-5724`.
- Measurements or examples: inside `if deficit > 0, historyRowCount > 0`, two
  consecutive unconditional writes to the same stored property with no read
  between them:

  ```swift
  columnCount = newColumnCount
  columnCount = oldColumnCount
  ```

- Observation: the net effect is zero. `mutateHistory` has already run above,
  and the next statement's `materialized(to: newColumnCount)` takes the width
  explicitly, so nothing between or after the writes reads `columnCount`. It is
  set for real at `:5748`.
- Inference: a leftover from a version where the code between the two lines read
  `columnCount`. Harmless today and a trap tomorrow: anyone inserting a
  width-sensitive call between those lines silently gets `oldColumnCount`.
- Uncertainty: none on the observation. Whether to delete both lines or keep one
  is a judgment about what the author intended; deleting both is the behavior
  the code has now.
- Next action: delete both lines. Not part of this doc's corpus work.

### F7 -- the mutation bar applied to every surviving candidate

- Status: in progress.
- Date and investigator: 2026-08-25.
- Commands, inputs, or reproduction: for each candidate, break the engine
  behavior it asserts in an isolated worktree, run `swift test --package-path
  lib/TerminalCore` in full (no `--filter`, since the question is whether *any*
  existing test catches it), and record which tests fail.
- Result, batch one (7 candidates, full suite of 1404 tests in 151 suites each):

  | Candidate | Result | Caught by | Verdict |
  | --- | --- | --- | --- |
  | Extended color, zero operands, pen unchanged (F1) | CAUGHT | `TerminalStyleTests:221`, `:236` | decline |
  | kitty flag 1: F1/F2/F4 take the CSI form (F2) | SURVIVED | -- | **adopt** |
  | Alt plus a printable character emits ESC (F3) | CAUGHT | `TerminalFixtureTests:725`, fixture `libvterm/state-input` | decline |
  | Ctrl+`@` emits NUL (F3) | SURVIVED | -- | **adopt** |
  | Ctrl+`?` emits DEL (F3) | SURVIVED | -- | **adopt** |
  | CAN/SUB abort a DCS data string (F3) | SURVIVED | -- | **adopt** |
  | kitty flag 1: Shift-only text key stays text (F2) | SURVIVED | -- | **adopt** |

- Observation: two more reading verdicts fell, and one of the two fell to a
  replayed fixture again (`libvterm/state-input`). That is three fixture-caught
  falsifications across two sessions, which moves `F8` from an anecdote to the
  doc's most reusable result.
- Observation: the surviving five each have a specific shape the test must take,
  and in every case the obvious test would *miss* the regression:
  - kitty F1/F2/F4 must be asserted **unmodified**. The modified path goes
    through `modifiedCSI` in both the legacy and kitty branches, so a Shift+F1
    test passes against the mutant.
  - Ctrl+`@` must be asserted on `@` specifically. Ctrl+Space shares the switch
    case and passes independently.
  - kitty Shift+`a` must be asserted with Shift **alone**. Adding Control or Alt
    puts it back on the CSI u path in both the mutant and the original.
- Inference: this is a second, narrower lesson beside `F8`. A test written from
  the case's title rather than from the mutation that would break it is a test
  that passes for the wrong reason. The mutation does not only decide *whether*
  to adopt; it dictates the shape of the test.
- Result, batch two (the four F6 reflow and grapheme candidates). Baseline
  verified green first, so every failure is attributable to its mutation:

  | Candidate | Result | Caught by | Verdict |
  | --- | --- | --- | --- |
  | Printed spaces on a soft-wrapped row are content | CAUGHT, 86 issues | `TerminalResizeTests:660` (resize fuzz, 83 hits), `:263`, `TerminalSelectionTests:166` | decline |
  | Widening by one with a wide cluster next inserts a spacer | CAUGHT both ways, 79 and 2800+ issues | `TerminalResizeTests:660`, `:68`, `:591`, `TerminalFixtureTests:808`, `TerminalLogicalLineFoldTests:65` | decline |
  | Trailing-padding cursor survives a viewport overflow | CAUGHT, 138 issues | `TerminalScrollbackBudgetTests:610` (121 hits), `TerminalFixtureTests:820`, `TerminalSavedCursorTests:118` | decline |
  | Emoji cluster split across three feeds | CAUGHT, 25 issues | `TerminalTests:358`, `:360`, `:367` -- the chunk-split-invariance fixture test | decline |

- Inference: reflow is the best-covered area in the census, and `F6`'s stated
  uncertainty was correct to flag itself. All three reflow candidates looked
  novel because DanTerm's resize tests mostly assert `fullHistoryText` rather
  than row splits -- but the resize *fuzz* test at `TerminalResizeTests:660`
  catches all of them anyway, by walking widths and checking history invariance
  across the whole walk. A property test covers what no titled test names.
- Inference: `H1` is **rejected**. The unweighed files did not yield at a higher
  rate than doc 26's three chosen files, and the areas H1 predicted would be
  richest -- reflow and style, the two the engine changed most this summer --
  yielded exactly zero. Every surviving candidate came from input encoding.
  Recorded in full in `F11`.

### F10 -- two of four mutations were inert before the third reproduced the regression

- Status: complete, and a correction to this doc's own method.
- Date and investigator: 2026-08-25.
- Provenance: reported by the reflow mutation runner against its own work,
  unprompted.
- Observation: the emoji-cluster candidate assumed some code "carries an open
  cluster's width upgrade across a feed boundary." No such code exists.
  `clusterContext` is plain instance state that persists across `feed` calls,
  and when it is missing,
  `recoverClusterContextFromGridIfNeeded` (`Terminal.swift:7867`) rebuilds the
  segmentation state from the scalars already in the grid cell. Clearing
  `clusterContext` at every feed boundary changed nothing, because grid recovery
  covered it. Denying grid recovery changed nothing, because the context never
  went away. Only cutting **both** paths reproduced the intended regression.
- Inference: a mutation that fails to reproduce the regression it was meant to
  reproduce is indistinguishable, from the outside, from a mutation the suite
  did not catch. Both look like "suite green." Reporting either single-site run
  would have recorded a survived mutation that was in fact inert, and this doc
  would have adopted a test for a behavior no engine change can break.
- Competing interpretations: none. The runner confirmed the two-site version
  reproduced the regression with a temporary probe -- output went from one
  cluster `[1f3f3, fe0f, 200d, 1f308]` plus `a` to two separate wide clusters --
  before running the full suite, then deleted the probe.
- Uncertainty: the same failure mode may be latent in any mutation in this doc
  that reported SURVIVED. The five adopted candidates are lower risk because
  each targets a single named switch case or branch whose deletion has an
  obvious local effect, but none of them was probe-verified the way the emoji
  candidate was.
- Next action: **probe-verify before trusting a survived mutation.** The rule is
  cheap: confirm the mutant actually changes the behavior under test before
  concluding the suite failed to notice. Added to `D3`'s lesson, and applied to
  the five adoptions before they land.

### F11 -- the yield, and the verdict on H1, H2, and H3

- Status: complete.
- Date and investigator: 2026-08-25.
- Result: 128 cases across twelve files, classified.

  | Disposition | Count | Share |
  | --- | --- | --- |
  | `implementation-coupled` | 46 | 36% |
  | `out-of-scope` | 45 | 35% |
  | `superseded` | 32 | 25% |
  | adopted or adapted | 5 | 4% |

  Eleven candidates reached the mutation bar; six were falsified there.
- **`H1` is rejected.** The prediction was that the unweighed files would yield
  more than doc 26's three chosen files, because the engine changed under them.
  It did not. Reflow, style, and color -- the three areas the engine changed most
  and where H1 expected the most -- produced zero adoptions between them. All
  five survivors came from input encoding, which is the one area where DanTerm
  has a large hand-written table that external suites also tabulate.
- Inference from the rejection, which is more useful than the hypothesis was:
  novelty does not track *how recently the engine changed*. It tracks *whether
  DanTerm's coverage in that area is example-based or property-based*. Reflow is
  covered by a fuzz walk (`TerminalResizeTests:660`) and grapheme handling by a
  chunk-split invariance test (`TerminalTests:358`); both generate cases nobody
  wrote down, so an external example lands inside coverage that already exists.
  Key encoding is covered by hand-written matrices, and a matrix has exactly the
  rows someone thought of -- which is why every survivor is a missing row.
- **`H2` is confirmed, including its sharp form.** At 36%,
  `implementation-coupled` is the single largest bucket, and the libvterm and
  Alacritty ledgers never needed it. Filing those 46 as `out-of-scope` would
  have created 46 standing claims about DanTerm's capabilities, each able to go
  stale, in place of 46 permanent facts about windows-terminal's test design.
  `F6`'s seven zero-scrollback reflow scenarios are the clearest instance:
  they are not capabilities DanTerm lacks, they are compensations for a buffer
  model DanTerm does not have.
- **`H3` is confirmed as a method and rejected as a yield.** Judging
  `TextAttributeTests` and `TextColorTests` by the policy each encodes rather
  than the C++ API it uses moved 8 of 12 cases out of the coupled bucket, which
  is the right classification. It produced zero adoptions, because every one of
  those policies is already pinned. The method matters even at zero yield: the 8
  are now `superseded` with named evidence, which is a claim a future engine
  change can falsify, instead of being dismissed as somebody else's class tests.
- Uncertainty: the comparison against `26/F9` that the ledger asked for cannot
  be made honestly. `26/F9` measured two novel cases from 4,315 lines in three
  files chosen for expected yield. This doc found five from roughly 10,600 lines
  across twelve files chosen only by "not yet read." The rates (0.46 vs 0.47 per
  thousand lines) are close enough to look like agreement, and that is a
  coincidence of two small numerators. Neither figure should be used to predict
  a third corpus.

### F8 -- reading cannot see fixture coverage

- Status: complete, and a cross-cutting lesson.
- Date and investigator: 2026-08-25.
- Evidence: `F1`'s falsified `GraphicsPersistBrightnessTests`, plus the charset
  re-adjudication in commit `06e158b4`, where a reader proposed `superseded` for
  three cases that the mutation bar showed were genuinely uncovered -- the same
  error in the opposite direction.
- Observation: a census performed by reading test files has a systematic blind
  spot. It finds coverage that is *named* -- a test whose title or body mentions
  the behavior -- and misses coverage that arrives through a replayed fixture,
  which asserts a whole projection at once and names nothing. It also
  over-credits a test whose title matches but whose assertions do not reach the
  case.
- Inference: the mutation bar is not a final check on a census. It is the census
  instrument, and reading is the cheap filter that decides what to mutate. Both
  directions of error have now been observed within two sessions, which is why
  this doc's Phase 2 puts mutation before landing rather than after.
- Next action: this belongs in whichever guide owns external corpus work, not
  only in this doc. Destination: D3.
