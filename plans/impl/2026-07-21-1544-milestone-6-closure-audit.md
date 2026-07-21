# Milestone 6 Closure Audit and Remaining Slices

## Problem

Milestone 6's roadmap still has unchecked component gates even though much of
their behavior is already proven. Choosing another large feature from those
stale bullets would obscure the few real gaps: complete underline presentation,
event-driven Swift recovery freshness, characterization replay, one named IME
scenario, and external-fixture classification and adoption.

## Desired outcome

Reconcile the roadmap with existing behavioral evidence, implement every genuine
Milestone 6 gap revealed by the audit, and leave Milestone 6 open only for the
separately deferred renderer cursor-blinking work.

The final roadmap state is:

- terminal core checked after full underline shapes and colors land
- Unicode/grid/scrollback checked from existing behavioral evidence
- inspection/recovery checked after event-driven scheduling and Ghostty-corpus
  replay land
- external dispositions checked after the libvterm and Alacritty ledgers close
- input/renderer left unchecked with an explicit blinking-only remainder
- the Milestone 6 header left unchecked for that same blinking-only remainder

## Audit judgment

| Roadmap gate | Evidence and remaining work |
|---|---|
| Terminal core | Controls, screens, modes, queries, parser recovery, resets, synchronized output, and cursor presentation state are covered by the existing terminal, CSI, mode, query, presentation, reset, saved-cursor, and Kitty suites. Keep open only for dotted/dashed underlines and semantic SGR 58/59 color. |
| Unicode/grid/scrollback | Selection, search, viewport, alternate-screen, reflow, and the fixed 10 MiB budget are covered by their named suites. Check immediately. |
| Inspection/recovery | Logical projection, invalidation, pane reads, persistence limits, and primary-history capture while alternate screen is active are covered. Keep open for event-driven enriched-checkpoint freshness and headless replay of the Ghostty characterization corpus. |
| Input/renderer | Keyboard, mouse, paste, OSC 52, links, colors, cursor shapes, damage, font fallback, scaling, and the native composition seam are covered. Add the named multi-stage Chinese IME proof, then leave open only for blinking. |
| External dispositions | The named Milestone 6 libvterm families are covered, but five files need final dispositions. All Alacritty recordings need classification and every Milestone 6 recording must enter the neutral fixture portfolio. |

## Decision

### Roadmap ledger

- Add the missing checked Slice 11 cursor-shape entry and link its implemented
  plan.
- Check the Unicode/grid/scrollback gate with named behavioral evidence.
- Annotate each other open gate with only its verified remaining work.
- Record that active-alternate recovery already exposes primary history, so it
  is evidence rather than another implementation gap.
- Add checked roadmap entries as the remaining slices land. Do not check the
  combined input/renderer gate or Milestone 6 header in this plan.

### Semantic and rendered underlines

- Extend the public underline model with dotted and dashed shapes alongside
  none, single, double, and curly.
- Add semantic underline color to `TerminalStyle`. It travels with cells, saved
  cursor state, resets, reflow, snapshots, render plans, and pixel execution.
- Support `SGR 4:0` through `4:5`, indexed and RGB `SGR 58` in colon and
  semicolon forms, and `SGR 59` color reset. `SGR 24` disables the underline
  shape without discarding its selected color; `SGR 0` resets both.
- An unset underline color follows the final effective foreground. An explicit
  underline color resolves independently through the palette. Strikethrough
  continues to use the foreground.
- Dotted and dashed pixels are visibly distinct, remain inside the decoration
  band, preserve cell geometry, and behave identically under partial and full
  redraw.

### Event-driven Swift enriched recovery

- Use a deterministic scheduling policy driven by explicit primary-history
  mutations, write completions, deadlines, and termination. Runtime code keeps
  timer and disk ownership.
- Only a change to the primary enriched-recovery projection marks Swift
  recovery dirty. Cursor-only, presentation-only, and transient
  alternate-screen changes do not.
- The first uncovered mutation establishes a covering write attempt within the
  existing 10-minute window. Later output cannot slide that deadline, and there
  is no faster quiet flush.
- A mutation arriving during a write remains dirty until a later checkpoint
  covers it. Successful coverage cancels scheduled work; a failed write keeps
  recovery dirty and schedules retries until a covering write succeeds.
- Clean termination first fences the terminal mutation source and drains
  already-accepted output, then synchronously captures and writes the final
  enriched checkpoint. No primary-history mutation can arrive after that
  capture.
- Retain the periodic 10-minute fallback only while the temporary Ghostty
  backend is present. Swift-only operation becomes quiescent after the latest
  mutation is durable.

### Recovery characterization equivalence

- Replay the checked-in Ghostty inspection/recovery characterization corpus
  headlessly through TerminalCore rather than creating a duplicate corpus.
- Compare viewport and primary full-history projections at the recorded
  56/90/56 widths, while alternate screen is active, and after returning to
  primary.
- Preserve the corpus's exact inputs, resize sequence, and provenance.

### Chinese IME composition

- Add an AppKit UI scenario with multiple successive marked-text updates
  followed by committed Chinese text.
- Prove the commit uses the native text-input path and emits no terminal
  key-encoded bytes.
- Retain the existing dead-key composition coverage.

### libvterm Milestone 6 ledger

- Add final dispositions for the five unclassified Milestone 6 files:
  - `28state_dbl_wh` and `67screen_dbl_wh`: out of scope because DEC
    double-width/double-height lines are not promised.
  - `29state_fallback`: superseded by native unknown/malformed-sequence
    recovery tests.
  - `65screen_protect`: out of scope with DECSCA/selective erase.
  - `66screen_extent`: out of scope as a libvterm attribute-extent API;
    DanTerm's cell-style behavior remains covered through public seams.
- Refresh the stale `10state_putglyph` DECSCA rationale to the same
  support-matrix decision.
- Keep `18state_termprops` and `68screen_termprops` explicitly assigned to
  Milestone 7.
- Make manifest inventory and expected-case validation cover the added entries.

### Alacritty classification and adoption

- Inventory all 45 pinned recording directories in a validated classification
  manifest. Upstream additions or removals fail validation.
- Ingest all 15 Milestone 6 recordings through neutral public seams:
  - adopted: `zsh_tab_completion`, `fish_cc`, `sgr`, `underline`,
    `clear_underline`, `colored_reset`, `history`, `alt_reset`, and
    `wrapline_alt_toggle`
  - adapted: `colored_underline`, `scroll_in_region_up_preserves_history`,
    `saved_cursor`, `saved_cursor_alt`, `tab_rendering`, and `hyperlinks`
- Adaptations may normalize Alacritty's serialized wide-tail/tab
  representation, ignore its unpromised legacy G0 charset behavior, and retain
  the documented hyperlink deviations. They still prove the recording's
  assigned Milestone 6 behavior.
- Mark these recordings superseded by native/libvterm behavioral coverage:
  `csi_rep`, `delete_chars_reset`, `delete_lines`, `erase_chars_reset`,
  `erase_in_line`, `grid_reset`, `indexed_256_colors`, `insert_blank_reset`,
  `issue_855`, `ll`, `newline_with_cursor_beyond_scroll_region`, `origin_goto`,
  `region_scroll_down`, `row_reset`, `scroll_up_reset`, and `zerowidth`.
- Every superseded entry identifies the existing native test or neutral fixture
  that proves its relevant terminal outcome. The external gate cannot close
  until each mapping has been audited against that evidence.
- Mark `decaln_reset`, `deccolm_reset`, and `selective_erasure` out of scope.
- Leave the six `vttest_*` recordings visibly pending for Milestone 7 and the
  two `tmux_*` plus three `vim_*` recordings pending for Milestone 8.
- Validate pinned provenance for every imported fixture. Run every application
  recording at authored chunking; retain exhaustive chunk-boundary proof in
  the smaller parser/state corpus rather than multiplying large recordings
  across every byte split.

### External research adjudication

- Add a dated research note that no Milestone 6 support-matrix behavior remains
  uniquely available from WezTerm, xterm.js, or Contour beyond the adopted
  native/libvterm/Alacritty evidence. Revisit those sources for Milestones 7
  and 8.
- Record that differential replay is dropped for Milestone 6 and should be
  reconsidered only when an actual backend disagreement demonstrates
  diagnostic value.
- Check the external-dispositions gate after the manifests, fixtures,
  provenance validation, and research note pass.
- Leave the input/renderer gate and Milestone 6 header unchecked with one
  explicit remainder: renderer cursor blinking.

## Invariants

- Core terminal state remains deterministic and independent of renderer color
  and pixel policy.
- Underline shape and color survive every existing style-carrying seam without
  changing text or grid geometry.
- Every Swift primary-history mutation receives a covering write attempt within
  10 minutes and remains dirty, with retries scheduled after failure, until a
  covering write succeeds.
- Sustained output cannot postpone a covering recovery checkpoint, and clean
  Swift sessions schedule no recurring recovery work.
- Termination fences and drains terminal mutations before the final enriched
  checkpoint, so output racing quit is either included or rejected before
  capture.
- Alternate-screen content never enters enriched primary recovery.
- Every external fixture is pinned, attributed, classified honestly, and
  asserted through a DanTerm public behavioral seam.
- Future-milestone recordings remain visibly pending rather than being
  mislabeled out of scope.

## Proof obligations

- Core style tests cover all underline shapes, both SGR 58 color forms, SGR 59,
  SGR 24, SGR 0, malformed recovery, saved state, and reflow retention.
- Render-plan and executor tests cover independent underline color resolution,
  dotted/dashed pixels, containment at 1.0/1.5/2.0 scales, and damage/full
  redraw equivalence.
- Deterministic recovery traces cover isolated output, sustained output,
  mutation during a write, clean idle, and transient failure through retry,
  successful coverage, and quiescence.
- Boundary-level tests prove primary projection changes schedule recovery while
  cursor-only, presentation-only, and active-alternate changes schedule
  nothing.
- A runtime/owner integration test races output with quit and proves the
  mutation source is fenced and drained before the final enriched checkpoint.
- The Ghostty characterization replay proves identical Swift viewport and
  primary-history text across resize and alternate-screen transitions.
- The AppKit UI suite proves multi-stage Chinese marked text commits through
  the text path without encoded key bytes.
- Fixture tests prove exact libvterm and Alacritty inventory, pinned provenance,
  behavioral replay of all 15 Milestone 6 Alacritty recordings, and a valid
  behavioral-evidence mapping for every superseded recording.
- Each slice passes its targeted tests; the completed plan passes `just test`,
  `just test-ui`, and `just build`.

## Non-goals and accepted risks

- DECSCA/selective erase, DEC double-width/double-height lines, DECALN,
  DECCOLM, and legacy G0 character-set emulation are not Milestone 6 features.
- Cursor blinking is not implemented here. Its dedicated future plan must
  cover focus, visibility, app activation, teardown, redraw equivalence, and
  quiescent timer ownership.
- The Ghostty 10-minute periodic checkpoint is an accepted temporary
  coexistence exception and disappears with that backend; the libghostty API
  boundary is not widened.
- Dotted/dashed raster geometry and the exact classification-manifest schema
  are implementation discretion provided the behavioral, inventory, and
  provenance contracts above hold.

## Commit progress

- [x] **Commit 1 -- `docs(plan): audit milestone 6 closure gates`**: add the
  checked Slice 11 entry, check the already-proven Unicode gate, cite named
  existing evidence, and annotate every remaining gate with its exact gaps.
- [ ] **Commit 2 -- `feat(terminal): render semantic underline styles and colors`**:
  add dotted/dashed shapes and SGR 58/59 color through semantic state, saved
  state, cells, render planning, pixels, and behavioral tests; then check the
  terminal-core gate.
- [ ] **Commit 3 -- `feat(recovery): schedule Swift checkpoints from mutations`**:
  replace periodic Swift enriched checkpoints with the deterministic 10-minute
  attempt bound and retry-to-success policy, retain the scoped Ghostty fallback,
  prove mutation classification, and fence output before the final checkpoint.
- [ ] **Commit 4 -- `test(recovery): replay Ghostty characterization in Swift`**:
  make the checked-in characterization corpus replayable headlessly, prove
  viewport/primary-history equivalence across resize and alternate screen, and
  check the inspection/recovery gate.
- [ ] **Commit 5 -- `test(ui): cover multi-stage Chinese IME composition`**: add
  the marked-text/commit UI scenario and update the input/renderer judgment so
  blinking is its only remaining item.
- [ ] **Commit 6 -- `test(fixtures): complete libvterm milestone 6 dispositions`**:
  add the five file dispositions, refresh DECSCA rationale, and extend manifest
  inventory validation.
- [ ] **Commit 7 -- `test(fixtures): adopt milestone 6 Alacritty recordings`**:
  classify all 45 recordings, ingest and validate all 15 Milestone 6 cases,
  map every superseded case to existing behavioral evidence, preserve future
  milestone assignments, and expand provenance validation.
- [ ] **Commit 8 -- `docs(plan): finalize milestone 6 external audit`**: record
  the conditional-source and differential-replay adjudications, check the
  external-dispositions gate, add the completed roadmap slice entries, and
  leave Milestone 6 explicitly open only for renderer cursor blinking.
