# External terminal test research

Research date: 2026-07-17.

**Status: SURVEY COMPLETE, RECOMMENDATIONS STILL LIVE. This is the one research
file that is not closed, and deliberately so.** Reviewed 2026-07-28.

The survey itself needs no further work -- the candidate corpora are enumerated,
the shared fixture seam is chosen, the libvterm coverage is broken down, and the
licensing rules are set. What keeps it open is that its **roadmap injection
points for Milestones 8, 9, and 10 have not been consumed yet**: those three
milestones are unchecked in
[plan-terminal-engine/14-roadmap.md](../../plan-terminal-engine/14-roadmap.md),
and this file is what they are supposed to read when they start.

Consumed so far: Milestones 2-7 (all checked on the roadmap). The pinned
libvterm and Alacritty portfolios landed, and the 2026-07-21 adjudication below
closed out the WezTerm/xterm.js/Contour question for Milestone 6 -- **as a scope
judgment for that milestone only**, explicitly deferring those corpora to
Milestones 7 and 8.

Still pending, and what each needs:
- **M8** -- Alacritty tmux/Vim/htop recordings as starting points, plus
  DanTerm-owned workflow captures; Kitty tests mined only for supported
  protocols.
- **M9** -- the pinned, reproducible evidence package, including the
  classification manifest with its four outcomes (adopted / adapted /
  superseded / out of scope).
- **M10** -- no new suite; re-run M9's package with the Ghostty backend absent.

Two standing constraints that outlive any milestone: **do not vendor wraptest
until its reuse terms are clear** (see
[2-wraptest-coverage.md](2-wraptest-coverage.md), which declined it on that
ground *and* on redundant coverage), and never regenerate-and-auto-accept
another emulator's output as DanTerm truth.

**Close this file when Milestone 9's evidence package is assembled** -- that is
the point at which its recommendations have all been either taken or explicitly
declined.

## Purpose

DanTerm should reuse the strongest public terminal-emulator test work where it
can improve coverage without making another emulator's storage model or quirks
normative. This note surveys reusable fixture corpora, semantic test cases,
black-box conformance programs, and official Unicode data, then maps them onto
the [terminal-engine roadmap](../../plan-terminal-engine/14-roadmap.md).

The central finding is that there is no single authoritative terminal test
suite. The useful portfolio has four layers:

1. Native DanTerm unit and property tests for the product contract.
2. Imported or translated byte-stream fixtures from established engines.
3. Differential replay against multiple independent engines to expose
   disagreements.
4. External black-box conformance and real-application workflows once a PTY,
   replies, interaction, and protocol integration exist.

External behavior is evidence, not authority. Unicode standards, terminal
protocol specifications, DanTerm's declared support matrix, and recorded
product decisions adjudicate disagreements.

## 2026-07-21 Milestone 6 closure adjudication

The completed native suites and the pinned libvterm and Alacritty portfolios
now cover every behavior in DanTerm's Milestone 6 support matrix. A closure
review of the previously recommended WezTerm, xterm.js, and Contour case mines
found no remaining Milestone 6 behavior uniquely evidenced by those sources.
This is a scope judgment, not a claim that their corpora are redundant: revisit
them for the protocol, shell-integration, application, and advanced-TUI work in
Milestones 7 and 8.

Differential replay is dropped from the Milestone 6 gate. The native suite and
neutral fixtures already provide deterministic, product-owned expectations,
while backend consensus would not decide whether a disagreement is a DanTerm
bug or an intentional contract difference. Reconsider differential replay when
an actual backend disagreement demonstrates diagnostic value; adjudicate any
result against DanTerm's support matrix and behavioral contracts rather than
automatically accepting the majority behavior.

## Candidate summary

| Source | Test shape and useful coverage | Recommended roadmap insertion | License and adoption guidance |
|---|---|---|---|
| [libvterm](https://github.com/neovim/libvterm/tree/nvim/t) | Plaintext parser/state/screen DSL covering parsing, UTF-8, cursor movement, editing, modes, styles, wrapping, resize, reflow, input, mouse, selection, queries, damage, and vttest captures | Start selectively in Milestone 2; reach nearly all applicable coverage in Milestone 6; finish protocol-policy classifications in Milestone 7 | MIT. Pin a commit because the repository is archived. Import only expectations compatible with DanTerm's contract. |
| [Alacritty reference recordings](https://github.com/alacritty/alacritty/tree/master/alacritty_terminal/tests/ref) | Raw terminal byte recordings plus size/configuration and expected whole-grid state; includes zsh, fish, Vim, tmux, htop, styles, history, hyperlinks, wrapping, and vttest sessions | Add the neutral replay runner in Milestone 2; begin recordings late in Milestone 2 or at Milestone 4; expand through Milestones 6 and 8 | Apache-2.0. Convert to a DanTerm-neutral fixture format rather than depending on Alacritty's serialized Rust grid. |
| [WezTerm terminal tests](https://github.com/wezterm/wezterm/tree/main/term/src/test) | Readable semantic cases for C0/C1 controls, CSI mutations, cursor behavior, scroll/history, selection, images, and regressions | Mine basic control cases in Milestone 2; use state and selection cases in Milestone 6; retain image cases only if graphics enter scope | MIT. Translate scenarios and public outcomes, not private Rust structures. |
| [xterm.js tests](https://github.com/xtermjs/xterm.js/blob/master/src/common/InputHandler.test.ts) | A large, actively maintained input-handler corpus plus a supported headless terminal implementation | Use as a case mine in Milestones 2 and 6; use its headless backend for later differential replay | MIT. Its large internal test harness is less portable than libvterm's DSL. |
| [Contour VT backend tests](https://github.com/contour-terminal/contour/tree/master/src/vtbackend) | Headless parser, sequence, grid, screen, selection, input, checksum, shell-integration, and advanced-protocol cases | Mine grid/parser cases in Milestone 2 and selection/input/damage cases in Milestone 6; use advanced cases in Milestones 7-8 as supported | Apache-2.0. Port behavioral cases rather than the Catch2/C++ harness. |
| [Termless](https://github.com/beorn/termless) and [terminfo.dev](https://www.terminfo.dev/) | Common structured API across Ghostty, Alacritty, WezTerm, xterm.js, libvterm, and other backends; recordings, PTY execution, cell/mode assertions, and a terminal capability census | Evaluate in Milestone 4; use differential tests in Milestone 6; consider a DanTerm backend and census runs in Milestones 7-9 | MIT. Promising infrastructure, but keep it optional until its maturity and maintenance fit are proven. |
| [esctest2](https://github.com/ThomasDickey/esctest2/blob/master/README.txt) | Automated black-box VT/xterm tests for cursor state, editing, DEC modes, SGR, colors, DCS/APC/PM/SOS, device queries, checksums, and window operations | Begin a supported subset in Milestone 7; broaden it for the Milestone 9 replacement gate | GPL-2.0. Prefer running a separately fetched, pinned external tool over copying its implementation into DanTerm. |
| [vttest](https://invisible-island.net/vttest/vttest.html) | Classic menu-driven VT100/VT220/xterm visual and keyboard acceptance tests, with command replay support | Record selected sessions in Milestones 4 and 7; run the relevant manual/replay suite in Milestone 9 | Permissive license described by the upstream project. Best used as acceptance evidence and a source of deterministic recordings, not as the only compatibility claim. |
| [wraptest](https://github.com/mattiase/wraptest) | Focused tests of the hidden last-column/deferred-wrap flag and the operations that set or clear it | Translate its behavioral matrix into DanTerm-authored tests in Milestone 2; run the external program in Milestones 7 or 9 | No clear license declaration was found. Do not vendor its source without clarification. |
| [Unicode Consortium test data](https://www.unicode.org/reports/tr44/) | Normative property and segmentation fixtures, including the UAX #29 grapheme-break corpus | Width/property data belongs in the first Milestone 2 slice; pinned UAX #29 fixtures belong in the later segmentation slice | Unicode data license. Pin an explicit Unicode version rather than following `latest`. |

Secondary sources include [Kitty's tests](https://github.com/kovidgoyal/kitty/tree/master/kitty_tests), which are valuable for Kitty keyboard, graphics, shell integration, and advanced protocol work but are GPL-3.0, and [Pyte's captured application fixtures](https://github.com/selectel/pyte/tree/master/tests), which include raw output and expected screens for programs such as `htop`, `top`, `vi`, and `mc` but are LGPL-3.0. Alacritty is the stronger first application-recording source.

## Recommended shared fixture seam

The highest-leverage investment is a DanTerm-owned, neutral byte-replay runner.
It should be introduced as part of Milestone 2 rather than waiting for PTY or
renderer integration. A fixture should be able to record:

- source project, source URL, pinned commit/version, upstream test name, and
  license
- terminal dimensions and explicit configuration inputs
- exact input bytes and explicit resize or interaction inputs
- expected public cell geometry, written-space state, logical text, hard/soft
  line identity, cursor, pending-wrap state, modes, scrollback, ordered output
  bytes, semantic effects, and damage where applicable
- intentional DanTerm deviations and the contract or specification that
  justifies each deviation

The same byte stream should be runnable as one chunk, byte-by-byte, and at all
significant or exhaustive split points. Expectations must use TerminalCore's
public inspection views, not imported private buffer layouts. Differential
backends may produce comparison reports, but their consensus must never
automatically bless DanTerm output.

Alacritty already demonstrates the basic recording shape in its
[reference runner](https://github.com/alacritty/alacritty/blob/master/alacritty_terminal/tests/ref.rs): it loads a raw recording, dimensions,
configuration, and expected grid, feeds the recording through a headless
terminal, and compares the complete result. DanTerm should preserve that useful
shape while defining its own structure-insensitive expected state.

## Roadmap injection points

### Milestone 2: foundational headless terminal core and Unicode model

Milestone 2 is where the reusable test infrastructure and the largest body of
semantic fixtures should begin. The work remains pure and headless, consistent
with the roadmap's requirement that terminal behavior be deterministic without
a PTY, AppKit, or renderer.

Recommended injections by slice:

- **Current headless-foundation slice:** adapt compatible portions of
  libvterm's [`02parser.test`](https://github.com/neovim/libvterm/blob/nvim/t/02parser.test),
  [`03encoding_utf8.test`](https://github.com/neovim/libvterm/blob/nvim/t/03encoding_utf8.test),
  `10state_putglyph`, ground-control portions of `11state_movecursor`, basic
  `20state_wrapping`, and [`61screen_unicode.test`](https://github.com/neovim/libvterm/blob/nvim/t/61screen_unicode.test). Compare the pending-wrap control matrix with wraptest. Keep the current plan's stronger exhaustive Unicode property proof and Ghostty decoder fixtures.
- **VT interpretation slices:** add compatible parser dispatch, cursor movement,
  scrolling, insertion/deletion/erase, mode, tab-stop, save/restore, reset, SGR,
  REP, selective erase, and vttest-derived fixtures from libvterm, WezTerm,
  xterm.js, and Contour. Port tests before adding each supported behavior.
- **Segmentation slice:** ingest the pinned official
  [UAX #29](https://www.unicode.org/reports/tr29/) `GraphemeBreakTest.txt`
  corpus. Retain compatible libvterm combining/wide cases as regressions, but do
  not use libvterm's combining-mark storage limits as the contract.
- **Scrollback and reflow slices:** adapt libvterm `16state_resize`,
  `32state_flow`, `63screen_resize`, `69screen_pushline`, and
  [`69screen_reflow.test`](https://github.com/neovim/libvterm/blob/nvim/t/69screen_reflow.test).
  Add Alacritty's simpler history, wrap, and resize recordings after the neutral
  runner can express logical lines and cursor attachment.
- **Damage seam:** define neutral logical-damage expectations when damage first
  becomes observable. Use libvterm `62screen_damage` and Contour as case sources,
  but do not copy their rectangle merging or callback topology as DanTerm's
  required representation.

Milestone 2's exit criteria cover only the behavior required by the viability
slice, not the entire accepted terminal baseline. It is therefore the point to
start and grow the corpus, not a promise that every parser/state file already
passes.

### Milestone 3: PTY process lifecycle

Libvterm fixtures do not require a PTY, so Milestone 3 should not block or
substantially expand them. Add controlled-child recordings that prove PTY byte
ordering, resize ordering, EOF, exit, and teardown. Preserve raw PTY output in a
form the neutral replay runner can feed directly into TerminalCore; this lets a
failed system test be reduced to a deterministic core fixture.

Termless's PTY recording support may be evaluated as an external comparison,
but DanTerm's lifecycle tests should continue exercising the native Swift PTY
owner directly.

### Milestone 4: interactive viability slice

Use the first complete Swift pane to capture DanTerm-owned recordings for the
required zsh, `ls`, `cat`, and `less` viability workflow. Replay the captured
output headlessly as a regression fixture and retain a narrow end-to-end test
for the PTY/renderer/input seams.

This is also a reasonable point for a non-gating Termless experiment and a
small selected vttest session. Neither should become a viability dependency
unless it materially improves diagnosis over the native fixtures.

### Milestone 5: experiment decision

Include testability in the experiment evidence:

- whether real failures reduce cleanly to the byte-replay runner
- whether public logical snapshots diagnose grid failures without pixel output
- whether imported cases exposed ambiguities or forced private implementation
  coupling
- whether Termless or another differential runner adds enough value to maintain

No new external compatibility claim is required solely for this decision.

### Milestone 6: complete terminal behavior and interaction

This is the natural "nearly all applicable libvterm coverage" threshold. Add:

- remaining control, screen, alternate-screen, style, mode, query, reset, and
  recovery cases
- libvterm `17state_mouse` cases for the SGR modes DanTerm supports
- compatible `25state_input` legacy/application cursor and keypad, focus, and
  bracketed-paste cases, supplemented by DanTerm-native Kitty and macOS
  composition tests
- the write-only portion of `40state_selection` for bounded OSC 52 clipboard
  writes, plus DanTerm-native denial tests for reads
- structure-insensitive cases derived from `62screen_damage`, screen resize,
  selection, protection, scrollback, and reflow files
- broader Alacritty recordings for shell completion, styles, history, saved
  cursor, tabs, links, and alternate-screen behavior
- translated WezTerm, xterm.js, and Contour cases wherever they cover a support
  matrix behavior absent from libvterm

If Termless proved useful during Milestone 4, run the neutral DanTerm cases
against selected independent backends to identify disagreements. Keep the
DanTerm-native Swift suite as the required gate.

### Milestone 7: shell and baseline application compatibility

Finish classifying the libvterm protocol/event cases, especially
`18state_termprops`, `26state_query`, `40state_selection`, and
`68screen_termprops`. Adapt title, cursor property, mode-query, device-query,
and clipboard-write expectations to DanTerm's advertised identity and security
policy rather than libvterm's replies.

Begin a pinned, supported esctest2 subset once DanTerm has a real PTY, the
necessary terminal-to-host replies, and a documented capability contract. Add
Termless/terminfo.dev census probes for capabilities DanTerm actually
advertises. Record selected vttest sessions and run wraptest externally against
the real pane. Failures from these programs should be reduced to native
byte-stream fixtures when possible.

### Milestone 8: tmux, editor, and advanced TUI compatibility

Use Alacritty's tmux, Vim, htop, and shell-completion recordings as starting
points, then capture DanTerm-owned workflows for tmux, Vim, Neovim, btop, htop,
lazygit, Claude Code, and Codex. Keep both direct and tmux/ssh variants where the
roadmap requires them.

Mine Kitty tests only for supported protocols, such as Kitty keyboard behavior;
graphics tests remain deferred unless terminal graphics enter DanTerm's support
matrix.

### Milestone 9: replacement quality gates

The external portfolio should become a pinned, reproducible evidence package:

- all native TerminalCore, Unicode, interaction, policy, PTY, renderer, and
  lifecycle tests
- every imported fixture classified and attributed
- the supported esctest2 subset
- selected automated/replayable vttest and wraptest coverage
- Termless or equivalent differential and capability reports, if retained
- full application workflow recordings and end-to-end tests
- fuzz seeds promoted from every externally discovered parser or state failure

External suites should be version-pinned and should not silently change the
replacement gate when upstream updates.

### Milestone 10: remove libghostty

No new external suite is needed specifically for removal. Re-run the complete
Milestone 9 evidence package with the Ghostty backend absent. Historical
Ghostty differential fixtures remain provenance-bearing regression data, not a
runtime or build dependency.

## Libvterm coverage breakdown

The practical threshold depends on what "play the tests" means:

- Feeding the bytes is possible early, but proves little while sequences are
  only absorbed.
- Meaningfully asserting equivalent public behavior grows throughout Milestone
  2 and Milestone 6.
- Running the DSL verbatim would require reproducing libvterm callback and
  storage APIs. That is neither necessary nor desirable.

| Roadmap point | Meaningful libvterm-derived coverage |
|---|---|
| Current foundation slice | Compatible subsets of parser absorption, UTF-8, ground controls, printing, wide cells, combining attachment, pending wrap, and chunking |
| End of Milestone 2 | Most applicable parser, grid, cursor, scroll, editing, modes, tabs, save/restore, SGR, reset, resize/reflow, Unicode, and vttest-derived screen behavior required by the viability scope |
| End of Milestone 6 | Nearly all applicable alternate-screen, query/reply, input encoding, mouse, selection, scrollback, damage, and interaction-state behavior |
| End of Milestone 7 | Final title, clipboard, terminal-property, advertised-capability, and semantic-protocol classifications |

The end of Milestone 6 is the useful "nearly all" target. The end of Milestone
7 is the conservative checkpoint at which every libvterm file should have an
explicit adopted, adapted, superseded, or out-of-scope disposition. Milestones
8-10 are unnecessary for the headless libvterm corpus itself.

### Test-family mapping

- **Milestone 2 core/grid families:** `02parser`, `03encoding_utf8`,
  `10state_putglyph` through the applicable state movement/scroll/edit/encoding/
  mode/resize files, `20state_wrapping`, `21state_tabstops`, `22state_save`,
  `27state_reset`, `30state_pen` through `32state_flow`, `60screen_ascii`,
  `61screen_unicode`, applicable screen resize/pen/protect/extent cases,
  `69screen_pushline`, `69screen_reflow`, the `90vttest_*` files, and the
  regression fixture.
- **Milestone 6 interaction/effects families:** supported portions of
  `17state_mouse`, `25state_input`, `26state_query`, `40state_selection`,
  `62screen_damage`, and remaining alternate-screen, scrollback, mode, and
  terminal-property cases.
- **Milestone 7 protocol families:** remaining `18state_termprops`,
  `26state_query`, `40state_selection`, and `68screen_termprops` expectations,
  adapted to DanTerm's capability and security policies.

### Known libvterm incompatibilities and non-goals

Literal 100% compatibility with upstream expectations should not be a goal:

- `02parser` treats raw ground-state C1 bytes as controls. DanTerm's composed
  stream treats them as malformed UTF-8 and emits U+FFFD.
- `03encoding_utf8` accepts U+1FFFFF, beyond modern Unicode's U+10FFFF maximum.
- Some Unicode cases reflect libvterm's combining-mark storage limit rather
  than DanTerm's scalar-exact and eventual extended-grapheme-cluster contract.
- `14state_encoding` includes legacy non-UTF-8 character-set and raw C1 cases;
  DanTerm's UTF-8 mode explicitly excludes raw C1 introducers, 8-bit ST, and
  S8C1T rather than treating those cases as supported parser behavior;
  only the character-set behavior admitted by DanTerm's support matrix should
  be retained.
- `17state_mouse` tests legacy UTF-8 and rxvt encodings, while DanTerm currently
  promises SGR mouse reporting.
- `25state_input` assumes libvterm's Alt behavior. DanTerm preserves native
  macOS Option composition and initially has no Option-as-Alt mode.
- `26state_query` advertises libvterm's identity and capability replies.
  DanTerm must reply only with its implemented capability contract.
- `28state_dbl_wh` and `67screen_dbl_wh` cover DEC double-width/double-height
  lines, which the current DanTerm roadmap does not promise.
- `29state_fallback` verifies a libvterm-specific callback API. DanTerm instead
  needs bounded ignore-and-recovery behavior for unknown sequences.
- `40state_selection` expects OSC 52 reads and responses. DanTerm permits
  bounded writes and explicitly denies reads.
- Exact damage merging, attribute-extent, `sb_pushline`, and callback-order
  assertions test libvterm's architecture. Translate their terminal behavior
  and assert through DanTerm's public views.

The corpus should therefore have a checked-in classification manifest with one
of four outcomes for every upstream test or coherent case group:

- **adopted:** the upstream input and public expectation match DanTerm
- **adapted:** the input is valuable but the expectation follows an explicit
  DanTerm policy or capability difference
- **superseded:** a stronger native property, fuzz, Unicode, or workflow test
  covers the behavior
- **out of scope:** the behavior is not in the declared support matrix

## Maintenance and licensing rules

- Pin every imported corpus to an explicit commit or data version.
- Preserve source path, upstream test name, license, and any required notice in
  fixture metadata or an adjacent manifest.
- Review obligations before copying or translating GPL/LGPL test code. Running
  an external pinned program is often a cleaner boundary than vendoring it.
- Do not vendor wraptest until its reuse terms are clear.
- Update imported expectations intentionally. Never regenerate and auto-accept
  a new emulator's output as DanTerm truth.
- When an external case discovers a bug, first add the smallest failing native
  DanTerm test, verify the expected failure, then fix it under the repository's
  TDD rule.
