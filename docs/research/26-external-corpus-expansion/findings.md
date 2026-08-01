# Findings -- external test corpus expansion

Append-only. Every finding below was taken at commit `593ce4a` with a dirty
worktree unrelated to `lib/TerminalCore` (config font-family work, a fetch
script edit). No finding depends on the uncommitted files.

### F1 -- both pinned corpora are fully classified; "skipped" means out-of-scope

- Status: complete.
- Date and investigator: 2026-07-31, Claude.
- Commit and worktree state: `593ce4a`, dirty in `app/`, `plans/`, `scripts/`.
- Commands, inputs, or reproduction:
  - `comm -23 <(ls references/libvterm/t/*.test | sed 's|references/libvterm/||' | sort) <(jq -r '.files[].path' lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/libvterm-manifest.json | sort)`
  - the same `comm` against `references/alacritty/alacritty_terminal/tests/ref`
    and `.recordings[].name`
  - `jq -r '[.files[].cases[].disposition] | group_by(.) | map("\(.[0])=\(length)") | join("  ")'`
- Measurements or examples: both `comm` invocations returned empty. Disposition
  totals:

  | Corpus | adopted | adapted | superseded | out-of-scope | total |
  | --- | --- | --- | --- | --- | --- |
  | libvterm, 43 files | 171 | 105 | 26 | 86 | 388 |
  | Alacritty, 45 recordings | 11 | 9 | 22 | 3 | 45 |

- Observation: no upstream test file or recording in either pinned corpus lacks
  a manifest entry, and no manifest entry names a file absent upstream.
- Inference: the question "which third-party tests are we skipping?" has exactly
  one answer -- the 89 out-of-scope cases. There is no unclassified backlog and
  no drift between the pins and the manifests.
- Competing interpretations: a manifest entry can be present but assert less
  than the upstream case does; classification completeness is not assertion
  completeness. F1 does not measure the latter.
- Uncertainty: low on the diff itself.
- Next action: group the 89 by rationale (F2).

### F2 -- ~81 of the 89 out-of-scope cases are feature- or policy-blocked

- Status: complete.
- Date and investigator: 2026-07-31, Claude.
- Commit and worktree state: `593ce4a`.
- Commands, inputs, or reproduction:
  - `jq -r '.files[] | .path as $p | .cases[] | select(.disposition=="out-of-scope") | "\($p)\t\(.rationale)"' ... | sort | uniq -c | sort -rn`
  - `grep -rn "DECRQSS\|DECSLRM\|DECSCA\|leftMargin\|selectiveErase\|DECIC\|DECDC\|DECALN\|charset\|DECSCNM" lib/TerminalCore/Sources/TerminalCore/`
- Measurements or examples: the rationale groups, largest first:

  | Family | Cases | Blocker |
  | --- | --- | --- |
  | Horizontal margins, DECSLRM/DECLRMM, DECIC/DECDC | ~13 | unimplemented |
  | Legacy SCS charsets, locking and single shifts | 11 | deliberate UTF-8-only |
  | DEC double-width / double-height lines | 9 | unpromised |
  | DCS-carried DECRQSS replies | 8 | parser absorbs DCS bodies |
  | DECSCA / selective erase | 6 + Alacritty `selective_erasure` | deferred |
  | OSC 52 reads | 5 | deliberate denial |
  | 8-bit ST / raw C1 | 5 | deliberate |
  | SGR blink, alt font, super/subscript, DECSCNM, bold-highbright | 5 | declared contract omissions |
  | Damage merge modes, `moverect`, attribute extent | 5 | libvterm architecture |
  | Mouse encodings 1005 / 1015 | 2 | deliberate, SGR only |
  | DECALN, DECCOLM (Alacritty `decaln_reset`, `deccolm_reset`) | 2 | unpromised |
  | Application-requested cursor blinking | 1 | on the deferred post-milestone list |

  The source grep returned exactly one hit across the whole family list:
  `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:5369`, a comment stating
  there are no DECSLRM left/right margins.

- Observation: none of the sequence families named in the out-of-scope
  rationales has an implementation in `TerminalCore`, under those names.
- Inference: these rationales are accurate, not stale. Adopting any of these
  cases requires implementing a sequence family first, so they are support-matrix
  decisions rather than test-coverage decisions. This supports H1.
- Competing interpretations: the grep is name-based. A family implemented under
  a different internal vocabulary would be missed -- though the deliberate-policy
  entries (OSC 52 reads, 1005/1015, 8-bit ST, the SGR omissions) are independently
  confirmed by the manifest's `recordedDeviations` list, which states each as an
  intentional DanTerm difference.
- Uncertainty: low for the policy families, moderate for the "unimplemented"
  families pending a semantic rather than name-based check.
- Next action: none for these. Examine the residue that did not fit these
  families (F3, F4).

### F3 -- `t/92lp1640917.test` is blocked only on a resolved milestone

- Status: complete; adopted in Phase 2.
- Date and investigator: 2026-07-31, Claude.
- Commit and worktree state: `593ce4a`.
- Commands, inputs, or reproduction:
  - manifest rationale: "Mouse reporting is a Milestone 6 input-interaction
    seam."
  - `cat references/libvterm/t/92lp1640917.test`
  - `grep -n "case 1002" lib/TerminalCore/Sources/TerminalCore/Terminal.swift`
  - `grep -rn "1002" lib/TerminalCore/Tests/TerminalCoreTests/TerminalMouseModeTests.swift`
  - `jq -r '.files[] | select(.path=="t/17state_mouse.test") | .cases[] | "\(.disposition)\t\(.name)"' ...`
- Measurements or examples: the upstream case sets `\e[?1002h`, reports a press
  and a motion, then sets `\e[?1002h` a second time while the mode is already
  active and requires the following motion to still report. Milestone 6 is
  checked in the roadmap. Mode 1002 is handled at `Terminal.swift:4338`; X10
  legacy report bytes are produced by the `legacyCode` path in
  `TerminalInputEncoding.swift`, gated on `sgrMouseEncoding`. The 23
  `17state_mouse` cases cover encoding shape, DECRQM reporting, bounds, and
  multi-mode DECSET, but none re-sets an already-active mode.
  `TerminalMouseModeTests` sets 1002 once.
- Observation: the stated blocker (Milestone 6) has resolved, the mechanism the
  case needs is implemented, and the specific behavior it pins -- idempotent
  re-set of an active mouse mode -- is not covered natively or by any adopted
  case.
- Inference: reclassifiable today, and it covers a genuine hole rather than
  duplicating adopted coverage. This is the clearest support for H2.
- Competing interpretations: it may land as `adapted` rather than `adopted` if
  DanTerm's X10 byte sequence differs from upstream's in any respect; the
  behavioral point (report survives the redundant DECSET) is what matters and is
  disposition-independent.
- Uncertainty: low on the gap, moderate on adopted-vs-adapted.
- Phase 2 result: `Fixtures/libvterm/state-mouse-idempotent-1002.json` replays
  the upstream press and both drag-motion reports under authored, bytewise, and
  every feed split. DanTerm's X10 bytes match upstream exactly, so the case is
  `adopted`, not `adapted`; the manifest rationale now names the fixture and
  behavior instead of Milestone 6.
- Next action: none for this case. Continue the seven per-file F4 adjudications.

### F4 -- seven of eight `90vttest_*` recordings are blocked only on stale staging

- Status: complete; all seven supported recordings adopted in Phase 2.
- Date and investigator: 2026-07-31, Claude.
- Commit and worktree state: `593ce4a`.
- Commands, inputs, or reproduction:
  - all eight manifest rationales are variants of "staged as Milestone 4
    acceptance evidence"
  - `grep -l '\\e#\|\\e(\|\\e)' references/libvterm/t/90vttest_*.test`
  - `grep -o 'PUSH "[^"]*"' <each file> | head -3`
- Measurements or examples: Milestone 4 is checked, and Milestone 8 Slice 1
  already "finalizes the six stale Milestone 7 vttest ledger entries" -- but for
  the *Alacritty* corpus; the 25 Alacritty recordings including `vttest_*` are
  dispositioned `superseded`, while the libvterm eight kept the Milestone 4
  wording. The DECALN/charset grep matched exactly one file,
  `90vttest_01-movement-1.test`, which opens `PUSH "\e#8"`. The other seven use
  DECSTBM (`\e[3;21r`), origin mode (`\e[?6h` / `\e[?6l`), DECAWM (`\e[?7h` /
  `\e[?7l`), tab stops (`\e[3g`, `\eH`), BS inside CSI (`\e[2\bC`), and
  leading-zero parameters (`\e[00000000004;000000001H`) -- all supported.
- Observation: the staging rationale that blocked all eight has resolved, and
  only one file has an independent, still-valid blocker.
- Inference: seven full-session recordings are adoptable now. They are worth
  more than their case count suggests, because each is a multi-hundred-byte
  session that exercises sequence *interleaving* -- margins interacting with
  origin mode interacting with wrap -- which the 43 isolated neutral fixtures do
  not. `01-movement-1` stays out-of-scope but needs its rationale rewritten to
  cite DECALN.
- Competing interpretations: the per-file expectations may partially restate
  what `state-mode.json`, `state-movecursor.json`, and the tab-stop fixtures
  already assert, in which case some belong as `superseded` rather than
  `adopted` -- which is how the Alacritty vttest entries were resolved. That the
  Alacritty ones all landed `superseded` is a real prior against these being
  novel, and Phase 2 must check rather than assume the interleaving argument.
- Phase 2 result: all seven are `adopted` at their authored 80x25 dimensions and
  replay under authored chunks, bytewise input, and the neutral runner's feed
  split strategies:
  - `90vttest_01-movement-2` -> `vttest-movement-2.json`: origin mode, margins,
    wrap, control characters, and boundary cursor motion in one session.
  - `90vttest_01-movement-3` -> `vttest-movement-3.json`: BS, CR, and VT inside
    CSI sequences across four rendered rows.
  - `90vttest_01-movement-4` -> `vttest-movement-4.json`: 26 long
    leading-zero CUP sequences composing one screen result.
  - `90vttest_02-screen-1` -> `vttest-screen-1.json`: enabled and disabled
    autowrap across long runs and cursor repositioning.
  - `90vttest_02-screen-2` -> `vttest-screen-2.json`: custom tab-stop clear,
    set, and traversal in one session.
  - `90vttest_02-screen-3` -> `vttest-screen-3.json`: enabled origin mode with
    margins, line feed, and CUP.
  - `90vttest_02-screen-4` -> `vttest-screen-4.json`: disabled origin mode with
    margins and absolute CUP.
- Adjudication: isolated fixtures cover each sequence family, but none asserts
  these complete interleavings and final public screen/cursor outcomes. The
  sessions therefore add behavioral coverage and are not `superseded`.
- Uncertainty: low after neutral replay; no engine disagreement was found.
- Next action: none for these cases. Phase 2 is complete.

### F5 -- Ghostty's own test suite is the largest corpus doc 1 never surveyed

- Status: complete; Phase 3 measured novelty in F9.
- Date and investigator: 2026-07-31, Claude.
- Commit and worktree state: `593ce4a`; `.ghostty-src/` at its pinned checkout.
- Commands, inputs, or reproduction:
  - `grep -rho '^test "' .ghostty-src/src/terminal/ | wc -l`
  - per-file counts via `grep -c '^test "'`
  - `grep -rn "ghostty" docs/research/1-external-tests.md`
- Measurements or examples: 1689 `test` blocks under `.ghostty-src/src/terminal/`.
  Largest files: `Terminal.zig` 372, `PageList.zig` 202, `Screen.zig` 184,
  `formatter.zig` 100, `page.zig` 46, `style.zig` 37, `stream.zig` 37,
  `stream_readonly.zig` 33, `sgr.zig` 31, `Parser.zig` 24, `color.zig` 20,
  `Selection.zig` 18, `render.zig` 15, `dcs.zig` 8. Doc 1 mentions Ghostty only
  under "Milestone 10: remove libghostty" and in the differential-replay
  discussion -- it appears nowhere in the candidate-summary table.
- Observation: an MIT-licensed corpus larger than every surveyed source
  combined, already checked out locally, from the exact emulator being replaced,
  was never evaluated as a case mine.
- Inference: this is the most likely remaining source of coverage for
  scrollback/`PageList`, selection, and SGR -- areas where libvterm's cases are
  either architecture-coupled or thin. Supports H3.
- Competing interpretations: block count is a size signal only. Much of
  `PageList.zig` and `page.zig` tests Ghostty's paged storage model directly and
  would violate the no-private-structures rule; `formatter.zig`'s 100 blocks are
  likely irrelevant to DanTerm entirely. The genuinely portable fraction could
  be small. Separately, Milestone 8's Slice 18 adjudication found no unique
  support-matrix behavior in the other researched sources, which is weak
  evidence the same could hold here.
- Uncertainty: resolved for the three scoped files; the other 1,438 terminal
  test blocks remain a size signal only.
- Next action: none for this scoped mine. D2 declines Ghostty as a maintained
  external corpus because F9 found no novel public behavior in the three files.

### F6 -- two Unicode fixture gaps sit outside doc 1's table

- Status: complete; Phase 4 audited and closed the gaps in D3.
- Date and investigator: 2026-07-31, Claude.
- Commit and worktree state: `593ce4a`.
- Commands, inputs, or reproduction:
  - `ls lib/TerminalCore/Tests/TerminalCoreTests/` and
    `grep -n "Unicode 17" .../GraphemeBreakTests.swift`
  - `jq` disposition counts for `t/03encoding_utf8.test`
- Measurements or examples: `GraphemeBreakCorpus.generated.swift` pins the
  official Unicode 17.0.0 `GraphemeBreakTest` corpus unfiltered. There is no
  `WordBreakTest` equivalent, though `TerminalSelectionTests` and
  `TerminalSelectionUnitTests` exist. The only imported decoder coverage is
  libvterm's `03encoding_utf8`: 9 cases (6 adopted, 3 adapted), against a
  hand-rolled `UTF8Decoder.swift` with a maximal-subpart recovery contract and a
  recorded deviation about U+10FFFF and U+FFFD replacement.
- Observation: doc 1's candidate table lists "Unicode Consortium test data"
  generically and names only UAX #29 grapheme segmentation and width properties.
  It does not name the standard UTF-8 decoder stress corpus
  (Markus Kuhn's `UTF-8-test.txt`), nor `WordBreakTest`.
- Inference: nine imported cases is thin for a hand-rolled decoder whose
  overlong, surrogate, truncation, and boundary behavior is a stated contract.
  Kuhn's corpus is the standard instrument for exactly that and is freely
  redistributable. `WordBreakTest` is only warranted if word selection claims
  UAX #29 semantics -- that is a contract question, not yet answered.
- Competing interpretations: native decoder tests may already cover the boundary
  space; F6 counted imported cases, not native ones. The gap could be smaller
  than it looks.
- Resolution: an all-source-byte probe over the pinned 22,781-byte Kuhn file
  matched Swift's maximal-subpart decoding. The maintained fixture compactly
  covers its valid boundaries, every continuation and legacy lead class,
  incomplete sequences, impossible bytes, overlong forms, surrogate forms,
  out-of-range encodings, and valid noncharacters. The selection audit found
  DanTerm's existing terminal-oriented separator policy, not UAX #29 word
  boundaries; D3 records why `WordBreakTest.txt` and vte's cases are declined.
- Uncertainty: resolved for the decoder and double-click selection contracts.
- Next action: none for Phase 4.

### F7 -- Milestone 9's two named external legs are unstarted

- Status: complete.
- Date and investigator: 2026-07-31, Claude.
- Commit and worktree state: `593ce4a`.
- Commands, inputs, or reproduction:
  - `just fetch-references --list`
  - roadmap Milestone 9 criteria; doc 1's Milestone 9 section
- Measurements or examples: `fetch-references` listed 11 pins when first read --
  libvterm, alacritty, xnu, libdispatch, libpthread, libplatform, Libc, objc4,
  fish-shell, zsh, bash. It listed 19 an hour later, after the 2026-07-31
  terminal-reference expansion recorded in F8; the eight added pins are all
  terminal source trees and none is esctest2 or vttest. Neither is pinned under
  either reading, and there is no esctest2 or vttest runner in the repository.
  Doc 1 names both as Milestone 9 evidence-package contents; Milestone 9's
  fourth criterion is that package being reproducible and gating.
- Observation: the two external black-box legs doc 1 assigns to Milestone 9 have
  not been started, while their prerequisites -- a real PTY, terminal-to-host
  replies, a documented capability contract -- all landed in Milestones 3-7.
- Inference: fixture mining is not what blocks Milestone 9. The esctest2 subset
  and the replayable vttest sessions are. Phases 2-4 of this doc improve coverage
  but do not advance the milestone; Phase 5 does.
- Competing interpretations: an owner decision could waive either leg the way
  Milestone 8 waived scripted workflow automation and DanTerm-owned recordings.
  If so, doc 1's close condition needs restating rather than satisfying.
- Uncertainty: low on the facts, open on whether a waiver is intended.
- Next action: scope the esctest2 subset against the advertised capability
  contract (Phase 5), or record a waiver decision.

### F8 -- eight terminal source trees were pinned mid-investigation; two carry test corpora doc 1 never surveyed

- Status: complete as a census; Phase 3 measured the scoped novelty in F9.
- Date and investigator: 2026-07-31, Claude. Recorded after F1-F7, during the
  same session.
- Commit and worktree state: observed at `593ce4a` plus a then-uncommitted
  expansion of `scripts/fetch-references.py` and `AGENTS.md`; that expansion
  landed later the same day as `4f1f325`, so F8 now describes committed state.
- Commands, inputs, or reproduction: `just fetch-references --list`;
  `ls references/`; `grep -c 'TEST_METHOD('` and `grep -c '#\[test\]'` over the
  test directories named below.
- Measurements or examples: `references/` gained kitty, wezterm, iterm2, vte,
  foot, tmux, xterm, and windows-terminal, all materialized. Of these:

  | Tree | License | Test corpus found | Size |
  | --- | --- | --- | --- |
  | windows-terminal | MIT | `src/terminal/parser/ut_parser`, `src/terminal/adapter/ut_adapter`, `src/buffer/out/ut_textbuffer` | ~183 `TEST_METHOD` |
  | vte | LGPL-3.0 / GPL-3.0 | `src/parser-test.cc`, `utf8-test.cc`, `modes-test.cc`, `tabstops-test.cc`, `unicode-width-test.cc`, `base16-test.cc` | not counted |
  | wezterm | MIT | `term/src/test/` | 56 `#[test]` |
  | tmux | ISC | `regress/` | 46 scripts |
  | xterm | X11/MIT | none -- but `ctlseqs.ms` / `ctlseqs.txt` | spec, not tests |
  | foot | MIT | `tests/test-config.c` only | no terminal corpus |
  | kitty | GPL-3.0 | `kitty_tests/` | previously adjudicated |
  | iterm2 | GPL-2.0 | not censused | -- |

  windows-terminal's breakdown: `OutputEngineTest.cpp` 64, `adapterTest.cpp` 53,
  `InputEngineTest.cpp` 25, `inputTest.cpp` 9, `StateMachineTest.cpp` 7,
  `TextAttributeTests.cpp` 7, `TextColorTests.cpp` 5, `MouseInputTest.cpp` 5,
  `kittyKeyboardProtocol.cpp` 4, `Base64Test.cpp` 2, `ReflowTests.cpp` 1.
  wezterm's: `mod.rs` 27, `csi.rs` 13, `selection.rs` 5, `c0.rs` 4, `c1.rs` 4,
  `image.rs` 3.
- Observation: doc 1's candidate table contains none of these eight. Its
  2026-07-21 adjudication covered WezTerm, xterm.js, and Contour -- not
  windows-terminal, vte, foot, tmux, or xterm.
- Inference, three parts:
  1. **windows-terminal is now a top candidate alongside Ghostty (F5)**: MIT,
     locally pinned, and a purpose-built VT conformance suite rather than an
     engine's incidental unit tests. Three of its files map onto known DanTerm
     gaps -- `Base64Test.cpp` onto the OSC 52 write-decode path,
     `MouseInputTest.cpp` onto the mouse-mode hole F3 identified, and
     `kittyKeyboardProtocol.cpp` onto the native Kitty keyboard tests.
  2. **xterm's `ctlseqs` resolves an instrument problem this doc raised.** The
     investigation rules require a Ghostty-derived expectation be justified
     against the spec rather than against Ghostty. `ctlseqs.txt` is that spec,
     now local. It is not a corpus and should not be counted as one.
  3. **vte is the license-constrained near-miss.** `utf8-test.cc` sits exactly
     on F6's decoder gap and `unicode-width-test.cc` on the width contract, but
     LGPL-3.0/GPL-3.0 triggers doc 1's "review obligations before copying or
     translating" rule -- the same constraint that shelved pyte.
- Competing interpretations: doc 1's Milestone 6 closure found no unique
  support-matrix behavior in three previously-surveyed engines. That result is
  weak evidence the same holds here, and is weaker for windows-terminal than for
  the others, because a conformance suite is organized around the specification
  rather than around one engine's implementation choices. Separately, these
  trees were pinned to be *read* for how other emulators solve a problem; that
  they also contain corpora is an opportunity this doc noticed, not the stated
  purpose of the pins.
- Uncertainty: resolved for windows-terminal's three scoped files; the other
  files and trees remain census-only.
- Next action: windows-terminal is complete in F9; route vte through a license
  review before any translation.

### F9 -- windows-terminal paid as a narrow OSC 52 mine; Ghostty did not

- Status: complete; selected fixture work landed.
- Date and investigator: 2026-07-31, Codex.
- Commit and worktree state: `5cbac16`; unrelated research changes were present
  outside this doc and were not read or modified.
- Commands, inputs, or reproduction:
  - read `references/windows-terminal/src/terminal/parser/ut_parser/Base64Test.cpp`,
    `references/windows-terminal/src/terminal/adapter/ut_adapter/MouseInputTest.cpp`,
    and `references/windows-terminal/src/terminal/parser/ut_parser/OutputEngineTest.cpp`
  - read `.ghostty-src/src/terminal/Selection.zig`,
    `.ghostty-src/src/terminal/PageList.zig`, and
    `.ghostty-src/src/terminal/sgr.zig` test blocks
  - cross-checked `TerminalOSC52Tests`, `TerminalMouseEncodingTests`,
    `TerminalMouseModeTests`, `TerminalInputStreamTests`, `CSIParserTests`,
    `TerminalStyleTests`, `TerminalSelectionTests`,
    `TerminalSelectionUnitTests`, `TerminalViewportTests`, and the resize,
    scrollback, hyperlink, and cell-style suites
  - adjudicated protocol expectations against
    `references/xterm/ctlseqs.txt#OSC Ps ; Pt ST`,
    `references/xterm/ctlseqs.txt#Extended coordinates`, and
    `references/xterm/ctlseqs.txt#CSI Pm m`, plus DanTerm's recorded contracts
- Measurements or examples: the windows-terminal files contain 71 methods over
  4,315 lines (2 Base64, 5 mouse, 64 output/parser). Ghostty's three files
  contain 251 test blocks; their test sections occupy 10,777 lines (18
  selection, 202 page-list, 31 SGR). The novelty result was two cases versus
  zero: about 0.46 novel cases per 1,000 lines for windows-terminal and zero for
  Ghostty.
- windows-terminal classification:

  | File | Portable and reachable through TerminalCore | Already covered natively | Coupled or outside DanTerm's contract | Novel shortlist |
  | --- | --- | --- | --- | --- |
  | `Base64Test.cpp` | padded RFC 4648 data decoded to strict UTF-8 through OSC 52 | ASCII payloads, malformed encodings, invalid UTF-8, decoded-size bounds, and chunk splits | the fuzz harness uses Windows CryptoAPI as its encoder; accepting omitted padding conflicts with DanTerm's canonical-Base64 policy | `DecodeUTF8`'s multilingual BMP payload and non-BMP emoji-plus-modifier payload |
  | `MouseInputTest.cpp` | X10/SGR buttons, releases, modifiers, motion modes, wheels, and coordinate encoding | the native mouse encoding/mode matrices plus the adopted redundant-1002 recording | `WM_*` event translation is a Windows input seam; 1005 and alternate-scroll mode are deliberately unsupported; Windows' X10 cutoff is not DanTerm's xterm-compatible bound | none |
  | `OutputEngineTest.cpp` | ESC/CSI/OSC/DCS/string recovery and the supported cursor, erase, SGR, query, title, OSC 8, and OSC 52 dispatch families | native parser, terminal, query, semantic-event, hyperlink, style, and chunk-invariance suites | private `_state`, `DummyDispatch`, parameter limits, and callback topology are implementation details; VT52, raw-C1 mode, palette mutation, printer/locator reports, and other unsupported families are outside the contract | the same two OSC 52 Unicode payloads; no additional case |

- Ghostty classification:

  | File | Publicly analogous behavior | Already covered natively | Ghostty-coupled or unsupported behavior | Novel shortlist |
  | --- | --- | --- | --- | --- |
  | `Selection.zig` | linear endpoint ordering, clamping, and containment | projection serialization, reversed endpoints, wide/grapheme atomicity, stream-edge clamping, select-all, reflow, and eviction | page pins and directional adjustment are private API shapes; rectangular selection is unsupported | none |
  | `PageList.zig` | viewport clamping/stickiness, history clearing, resize/reflow text and cursor preservation, and whole grapheme/style/link movement | viewport, scrollback, resize, selection, cell-style, hyperlink, wide-cell, and history-budget suites | page allocation, capacities, caches, iterators, tracked pins, clone/compact/split, style maps, and string arenas are private; prompt jumping/highlighting and Kitty placeholders are not public TerminalCore features | none |
  | `sgr.zig` | supported attributes, underline styles/colors, indexed/direct colors, and malformed-group recovery | the native style and CSI parser matrices include the two Kakoune sequences, missing color components, optional color-space forms, later-parameter recovery, and stricter effect-free malformed groups | `Attribute.C` and parser-union shape are private; blink is deliberately unsupported | none |

- Observation: the only uncovered supported path is OSC 52 converting valid
  Base64 bytes into non-ASCII Swift text. The multilingual BMP and
  emoji-plus-modifier payloads exercise distinct UTF-8 widths even though both
  occur in `Base64Test.cpp#DecodeUTF8` and are repeated by
  `OutputEngineTest.cpp#TestSetClipboard`.
- Inference: H3's sharp form is confirmed for this scope. The conformance suite
  produced a small actionable shortlist; the much larger incumbent-engine mine
  mostly restated DanTerm's stronger public tests or Ghostty's storage design.
- Competing interpretations: Ghostty's `sgr.zig#test "sgr: underline colon with
  trailing separator and short slice"` is a useful parser-crash seed, but it is
  not a new DanTerm expectation: DanTerm already requires malformed SGR groups
  to be effect-free, later valid groups to recover, arbitrary input not to trap,
  and parsing to resume after cancellation. Importing the exact seed would add
  implementation history rather than a missing behavior claim.
- Neutrality justification: xterm defines OSC 52 data as RFC 4648 Base64, while
  DanTerm's contract requires canonical padded Base64, strict decoded UTF-8,
  atomic rejection, and a 1 MiB decoded limit. The selected cases assert valid
  UTF-8 under that existing contract. Unpadded Base64, raw C1 parsing, and
  malformed-SGR interpretations were declined where the sources differ from or
  merely duplicate DanTerm's contract.
- Uncertainty: low for the scoped files. This is not an exhaustive decision on
  every Ghostty or windows-terminal test file.
- Implementation result: `Fixtures/windows-terminal/osc52-unicode.json` carries
  both selected payloads, `windows-terminal-manifest.json` classifies all 71
  scoped methods, and `LICENSE.windows-terminal.txt` carries the MIT notice.
  The shared fixture runner validates provenance and replays the fixture whole,
  bytewise, and at every split point.
- Next action: none for Phase 3.

### F10 -- the esctest2 gate already exists; its Milestone 9 scope is 14 query-observable cases

- Status: complete; the scoped 14-case gate passes.
- Date and investigator: 2026-07-31, Codex.
- Commit and worktree state: `7c01ec2`; unrelated untracked plan files and
  `TODO.md` were present and were not read or modified.
- Commands, inputs, or reproduction:
  - verified that commit `593ce4a`, F7's own census point, already contains
    `scripts/terminal-protocol-probes.sh`, its allowlist, and
    `docs/evidence/2026-07-21-real-pane-protocol-probes.md`
  - materialized esctest2 revision
    `664be3cf2c1e3f06bc93a8bafb48a0db83c607db` in the existing ignored
    `.build/terminal-protocol-probe-sources/` cache and inventoried
    `esctest/tests/`
  - read `esctest/tests/cup.py#CUPTests`,
    `esctest/tests/decrqm.py#DECRQMTests`, `esctest/tests/da.py#DATests`,
    `esctest/tests/decdsr.py#DECDSRTests`, and the observation helpers in
    `esctest/escutil.py`
  - cross-checked the candidates against `docs/terminal-capabilities.md`,
    `TerminalQueryTests`, and the runner's fixed VT level and dimensions
  - ran `just test-terminal-protocol-probes`; all 11 selected cases passed
- Measurements or examples: the pin contains 560 test methods in 80 Python
  files under `esctest/tests/`. The current gate already selects five CUP cases
  observed through CPR and six implemented ANSI/DEC modes observed through
  DECRQM. It is version-pinned, separately fetched, bounded by a timeout, and
  retains a recording plus failure artifacts.
- Scope result:

  | Disposition | Cases or families | Rationale |
  | --- | --- | --- |
  | retain unchanged | five CUP/CPR cases; ANSI IRM/LNM; DEC DECCKM/DECOM/DECAWM/DECTCEM | advertised, stateful, query-observable behavior already passing through the production PTY path |
  | add with a narrow DanTerm adapter | `DATests.test_DA_NoParameter`, `DATests.test_DA_0` | DA1 is advertised, but upstream's xterm identity expectation must become DanTerm's exact `CSI ? 1 ; 2 c` contract |
  | add with a narrow DanTerm adapter | `DECDSRTests.test_DECDSR_DECXCPR` | DECCPR is advertised; the upstream test must use the runner's fixed VT3 profile instead of probing the deliberately denied DA2 first |
  | decline for this gate | screen, editing, SGR, reset, tab, and alternate-screen families | their assertions use DECRQCRA or xterm window reports, neither of which DanTerm advertises; adding a protocol only to let an external suite inspect the screen would expand the product contract for the test |
  | decline as contract mismatches | DA2, DECRQSS, window operations, color mutation, OSC 52 reads, raw C1/8-bit replies, horizontal margins, and other VT4+ families | explicitly denied or absent from DanTerm's capability contract |
  | no compatible upstream case | DSR status, XTVERSION, query-only OSC 10/11, keyboard, mouse, focus, and bracketed paste | esctest2 has no isolated case matching DanTerm's contract; its color cases mutate before querying, while its input cases require user interaction |

- Observation: F7's claim that no esctest2 pin or runner existed was false at
  its stated commit. The infrastructure and passing 11-case Milestone 7 evidence
  had landed ten days earlier. What remained unstarted was the Milestone 9 scope
  audit and any justified expansion, plus the external vttest leg.
- Inference: the supported Milestone 9 esctest2 subset should contain 14 cases:
  retain the existing 11 and add only the two DA1 forms and one DECCPR form.
  This broadens independent black-box coverage of the advertised query contract
  without importing xterm identity claims or creating test-only terminal
  protocols. The native suite remains the right oracle for behavior esctest2
  cannot observe through DanTerm's public protocol.
- Competing interpretations: Milestone 9 could declare the already-passing 11
  cases sufficient because DA1 and DECCPR are covered natively. That would miss
  the purpose of the external leg: verifying terminal-to-host replies through
  the real pane and PTY path. The three adaptations are small and exercise two
  advertised reply families the current gate omits.
- Uncertainty: low. The inventory, adapter mechanics, expected failure, and
  passing 14-case result were all observed at the pinned revision.
- Implementation result: the expanded allowlist first produced the predicted
  TDD failure: the original 11 cases passed, both DA1 cases rejected DanTerm's
  two-parameter identity against xterm's eight expected features, and DECCPR
  timed out waiting for DA2. The adapter now checks exact `CSI ? 1 ; 2 c` for
  DanTerm and uses esctest2's runner-supplied VT3 level for DECCPR. All 14 cases
  then passed through `just test-terminal-protocol-probes`.
- Next action: completed by F11's external vttest scope audit.

### F11 -- vttest's replay is suitable for three response-driven sessions, not visual verdicts

- Status: complete as a scope audit; the external runner remains to land.
- Date and investigator: 2026-07-31, Codex.
- Commit and worktree state: `7c01ec2`; the same unrelated untracked files
  recorded by F10 remained untouched.
- Commands, inputs, or reproduction:
  - materialized the canonical `ThomasDickey/vttest-snapshots` tag
    `t20251205`, commit `0229d7171a8574a2bf406c6ce14549f65d810e51`, in
    the existing ignored `.build/` research cache
  - read `vttest.1#OPTIONS`, `replay.c#setup_replay`,
    `replay.c#replay_string`, `main.c#menu2`, `reports.c#tst_reports`,
    `reports.c#tst_DSR`, `reports.c#tst_DA`,
    `vt320.c#tst_vt320_device_status`, and
    `vt320.c#tst_DSR_cursor`
  - configured and built the pin successfully on macOS arm64
  - cross-checked every candidate sequence and expected reply against
    `docs/terminal-capabilities.md` and `TerminalQueryTests`
- Measurements or examples: vttest's `-c` option replays menu choices and
  next-page/hold responses recorded by `-l`. Replay pauses while the program
  waits for a terminal reply or unpredictable keyboard/mouse input. Report
  tests decode replies and write `show_result` judgments into the log; visual
  tests only print prose such as "should look the same" and never produce a
  machine verdict.
- Selected sessions, all at fixed `24x80.80` geometry with UTF-8 retained:

  | Session | Menu path | Contract checked | Gate evidence |
  | --- | --- | --- | --- |
  | VT100 DSR/CPR | `6.3` | DSR 5, CPR in absolute mode, CPR relative to a DECOM margin | terminal-OK result plus both cursor reports accepted, with no unknown/failure result |
  | VT100 DA1 | `6.4` | exact primary identity `CSI ? 1 ; 2 c` | vttest recognizes the reply as its VT100-with-AVO form rather than unknown |
  | VT320 DECCPR | `11.2.5.2.6` | private DSR 6 / extended cursor-position reply | decoded nonzero line and column, with no failure result |

- Declined session families:
  - the complete cursor-movement session includes unsupported DECALN
  - the complete screen session includes DECCOLM, DECSCNM, blink, and legacy
    character-set behavior outside DanTerm's contract
  - the insert/delete session includes DECCOLM and double-width lines
  - keyboard, mouse, focus, and similar sessions deliberately suspend replay
    for real user input and are not unattended evidence
  - accepting captured visual output as truth would violate the neutrality
    rule; vttest supplies stimuli and decoded replies, not DanTerm's expected
    screen model
- Observation: the seven adopted `90vttest_*` neutral fixtures remain the
  deterministic evidence for supported movement, wrapping, tab, and screen
  interactions. The external vttest program adds independent real-PTY query
  evidence; it should not duplicate those fixtures with unjudged screenshots.
- Inference: the three selected sessions are the smallest honest replayable
  vttest gate. The runner should separately fetch and pin the permissively
  licensed program, build it in ignored storage, execute checked-in DanTerm-
  authored replay command files through the production pane/PTY path, retain
  byte recordings and logs, require the named positive results, reject failure
  or unknown markers, and enforce bounded timeout and complete teardown.
- Competing interpretations: a smoke gate could merely require vttest to exit.
  That proves process integration but not terminal conformance. Conversely,
  snapshotting visual screens would appear broader but would turn upstream
  prose and captured output into an unaudited oracle. Parsing the three report
  sessions is both narrower and stronger.
- Uncertainty: low on source provenance, buildability, menu paths, and contract
  fit; moderate on orchestration details until replay command files run through
  `TerminalPaneSessionController`.
- Next action: implement the pinned three-session vttest runner and prove its
  log parser failing-first before assembling the final evidence package.

### F12 -- the pinned external gate passes and closes the evidence package

- Status: complete.
- Date and investigator: 2026-07-31, Codex.
- Commit and worktree state: implementation based on `1ba113e`; unrelated
  concurrent Unicode/case-folding and pre-existing untracked work remained
  untouched.
- Commands, inputs, or reproduction:
  - added `VttestReportParserTests` first and observed the expected compile
    failure because the parser and session types did not exist
  - implemented the parser and observed all four focused tests pass
  - ran `just test-terminal-protocol-probes` against esctest2 commit
    `664be3cf2c1e3f06bc93a8bafb48a0db83c607db` and vttest commit
    `0229d7171a8574a2bf406c6ce14549f65d810e51`
- Measurements or examples:
  - the first live vttest run failed before selecting `6.3`: vttest's startup
    DA1 query consumed the first replay wait marker, so the menu read an empty
    choice and exited
  - the replay files now model that startup handshake before their menu reads
  - the final run at
    `.build/terminal-protocol-probe-runs/20260731T233736Z-82863` passed all 14
    esctest2 cases and all three vttest sessions
  - VT100 DSR/CPR produced terminal OK plus two accepted cursor reports; DA1
    decoded exact `CSI ? 1 ; 2 c` as VT100 with AVO; DECCPR decoded line 2,
    column 1
- Observation: the pinned `tst_vt320_device_status` menu assigns DECXCPR to
  choice 7, so the executable replay path is `11.2.5.2.7`; F11's `.6` path was
  an audit transcription error. The parser asserts `.7`, and its negative test
  rejects `.6`.
- Inference: a passing process exit is insufficient evidence. The maintained
  gate instead requires the source-defined menu path and positive judgment for
  each session, rejects negative or incomplete reports, records byte streams
  and logs, applies a bounded timeout, and waits for full pane/PTY teardown.
- Competing interpretations: the vttest sessions could be folded into one
  process. Independent processes make each report and byte recording
  attributable, prevent one session's terminal state from affecting another,
  and retain the smallest useful failure artifact.
- Uncertainty: none on the selected scope or current result. Future scope
  changes still require adjudication against DanTerm's capability contract.
- Implementation result: the external source and build trees remain ignored;
  full commit hashes, DanTerm-authored replay files, exact result semantics,
  and the vttest license artifact define the reproducible boundary. Neither
  program exposed a DanTerm behavior failure, so no native byte-stream fixture
  was promoted.
- Next action: none for doc 26. The evidence package is recorded in
  `docs/evidence/2026-07-31-external-terminal-gate.md`; the remaining Milestone
  9 work is outside this research doc's external leg.
