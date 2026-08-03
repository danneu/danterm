# Alacritty inline-test portage scratch

Status: closed. The durable artifacts landed; what follows is the notebook that
produced them, kept for its reasoning rather than as live work.

## Outcome

Three adapted tests, not four. The ranked queue below predicted four
candidates; the fourth did not survive the adoption bar.

| Rank | Scenario | Predicted | Actual |
| ---: | --- | --- | --- |
| 1 | ED 2 while browsing retained history | adapt/probe | **adapted** |
| 2 | literal wide-cell search range | adapt/probe | **adapted** |
| 3 | literal search across a soft wrap by a wide cell | adapt/probe | **adapted** |
| 4 | reflow with an unwritten interior gap | compare, then adapt if distinct | **superseded** |

None of the probes found a bug -- all three adopted cases record correct
existing behavior -- so the deciding question became non-redundancy rather than
correctness. The bar applied: mutate DanTerm to break the behavior, and adopt
only if no existing test already caught the mutation.

- ED 2 resetting the viewport to following: caught by 1 test of 821, the
  adapted one.
- Wide projection units narrowed to one column: caught by 2 of 821, both
  adapted.
- Reflow dropping unwritten cells, and trailing padding counting as content
  (candidate 4's two directions): already caught by 3 and by 20+ existing tests
  respectively, so candidate 4 became `superseded` with that evidence recorded.

Answers to the open decisions below, as resolved in practice:

1. ED 2 preserves the whole projection, anchor included -- it never evicts,
   scrolls, or changes the retained row count, so there is nothing to re-anchor.
2. Chinese (U+754C), with the stimulus divergence recorded in the citation.
3. Yes, entailed -- see candidate 4 above.
4. Yes, the 135-entry ledger was worth it and exists as
   `alacritty-inline-manifest.json`, machine-checked in both directions.
5. Raw bytes of the balance-matched `fn` body, truncated to 12 hex characters.

Landed: `TerminalAlacrittyAdaptedTests.swift`,
`Fixtures/alacritty-inline-manifest.json`, `scripts/alacritty-parity-lint.py`
plus its self-test and two `just test` gate steps, and the Alacritty section of
`agent-docs/reference-sources.md`.

Re-verified after rebasing onto the reflow trailing-blank-cursor fix
(`cd57eb8`) and the WezTerm adaptations: all mutation results held unchanged.

## Objective

Mine the pinned Alacritty unit tests for behavioral scenarios that improve
DanTerm's public `TerminalCore` coverage, using the same discipline as the kitty
portage: adopt scenarios, not Alacritty's verdicts or data structures; assert
through DanTerm's public, structure-insensitive seams; and write a genuinely
failing test before changing production code when a scenario exposes a bug.

The first outcome should be a complete disposition ledger and a small ranked
queue, not a commitment to translate every Rust test.

## Scope and ground rules

- Source pin: Alacritty commit
  `852e971cddfabe222d2d5bcda466e130f53af207` under
  `references/alacritty` (Apache-2.0).
- Do not edit `references/alacritty`; it is a refetchable input.
- Keep two source populations separate:
  - The 45 directories under `alacritty_terminal/tests/ref/` are recordings.
    They are already fully classified in `Fixtures/alacritty-manifest.json`:
    11 adopted, 9 adapted, 22 superseded, and 3 out of scope. Twenty neutral
    fixtures already replay through `TerminalFixtureTests`. This audit must not
    reopen or recount that completed portfolio.
  - The informal "roughly 136 inline tests" is a different population. At the
    current pin there are exactly 135 literal `#[test]` annotations under
    `alacritty_terminal/src/`. The `#[test]` written inside `tests/ref.rs` is a
    macro template that expands once per recording and belongs to the 45-case
    recording portfolio, not this inline semantic census.
- A source test is useful only if its scenario reaches current DanTerm behavior
  through byte feed, resize, viewport navigation, selection/search, public
  geometry, semantic events, replies, or damage. Alacritty row rings, occupancy
  counters, iterators, cursor structs, serde shapes, and regex engine failures
  are not portable behavior.
- Translate the stimulus to the narrowest real DanTerm seam. Prefer bytes fed
  to `Terminal`; use direct public interaction calls where the behavior is
  local UI policy rather than escape interpretation. Do not construct invalid
  private grid states to imitate an upstream fixture.
- Assertions should target public text/ranges, cursor geometry, modes, events,
  replies, history/viewport projections, and row damage. They must not encode
  Alacritty's `Grid`, `Storage`, `Flags`, inclusive `SelectionRange`, or vi-mode
  cursor representation.
- DanTerm's contracts adjudicate differences. In particular, search is literal
  canonical-caseless rather than regex; selection is linear and follows
  DanTerm's fixed terminal-token/trimmed-line policy; resize always reflows;
  local browsing remains non-following when history is evicted; SCS line
  drawing, block selection, and emulator vi mode are not current features.
- TDD remains honest: add the smallest adapted test, run it and observe the
  expected failure if it discovers missing behavior, then fix the code. If it
  passes, record it as pre-existing coverage and decide whether the new
  regression adds a distinct behavioral boundary or should be dropped.
- Port only scenarios whose coverage is behavioral and structure-insensitive.
  A ledger disposition is a successful result; test count is not the goal.

## Current evidence

### Census

The 135 inline tests break down as follows:

| Upstream file | Count | Initial character |
| --- | ---: | --- |
| `src/grid/storage.rs` | 14 | storage ring mechanics |
| `src/grid/tests.rs` | 12 | scrolling, reflow, iterator mechanics |
| `src/index.rs` | 11 | coordinate arithmetic helpers |
| `src/selection.rs` | 16 | endpoint-side and selection-shape mechanics |
| `src/vi_mode.rs` | 19 | Alacritty emulator vi-mode navigation |
| `src/term/search.rs` | 33 | regex, wide cells, wraps, semantic boundaries |
| `src/term/mod.rs` | 23 | viewport, selection, resize, damage, title, utilities |
| `src/term/cell.rs` | 3 | cell size and occupied-row length |
| `src/tty/**` | 4 | Unix account lookup and Windows process/quoting behavior |

That is 131 tests in terminal/grid/interaction modules plus 4 platform TTY
tests. The earlier approximate count of 136 is close but not the pinned
inventory; a future ledger and its audit should pin 135 explicitly.

### Existing DanTerm seams already cover most portable families

- Reflow and history: `TerminalResizeTests`, `TerminalScrollbackTests`,
  `TerminalRegionScrollbackTests`, and the neutral libvterm fixtures already
  cover narrow/wide/emoji/spaces, repeated width walks, height transfer,
  history pull/push, alternate resize, and structural spacer repair.
- Scrolling and local browsing: `TerminalViewportTests` covers clamping,
  follow/non-follow state, stable anchors under output and reflow, eviction,
  search reveal, and logical viewport projection.
- Selection: `TerminalSelectionTests` covers cell/grapheme atomicity, soft/hard
  boundaries, written and padding spaces, empty lines, reflow attachment,
  overwrite invalidation, eviction, alternate-screen lifetime, and fuzzed
  valid ranges. `TerminalSelectionUnitTests` covers DanTerm's own terminal-token
  and trimmed-line policies.
- Search: `TerminalSearchTests` covers literal canonical-caseless matching,
  compatibility exclusions, overlap/navigation/wraparound, soft-wrap and
  explicit hard-boundary matching, live mutations, eviction, alternate-screen
  suppression, and damage. It intentionally does not implement Alacritty's
  regex API.
- Damage: `TerminalDamageTests` and
  `TerminalInspectionInvalidationTests` assert DanTerm's row-granular public
  vocabulary, accumulation/drain behavior, cursor changes, selection/search,
  scroll/edit confinement, full escalation, and chunk invariance. These are a
  stronger public contract than Alacritty's internal left/right line bounds.
- Alternate screens and resize: `TerminalAlternateScreenTests` already covers
  active and inactive grids, cursor clamping, scrollback isolation, and resize
  equivalence.
- Titles: `TerminalSemanticEventTests` covers decoded OSC title events,
  coalescing, limits, UTF-8, and chunking. Alacritty's internal title value and
  title-stack storage are not DanTerm's event seam.
- Erase: `CSIEraseTests` covers ED 0/1/2/3 geometry, scrollback deletion,
  wrap/spacer repair, cursor/style preservation, malformed dispatch, and
  pending-state cleanup. It does not visibly combine ED 2 with a user-browsed
  viewport.

### Likely novel behavioral candidates

1. `src/term/mod.rs#clearing_viewport_keeps_history_position`.
   Adapt the scenario to a primary terminal with retained history, navigate to
   the oldest rows, feed ED 2, and assert that the local viewport remains
   non-following and attached/clamped rather than snapping to the live bottom.
   Existing erase tests prove grid mutation; existing viewport tests prove
   stability under output/reflow and ED 3 eviction. Their intersection is not
   explicit. This is high value and low cost.

2. `src/term/search.rs#singlecell_fullwidth` plus the portable edge from
   `#wrapping_into_fullwidth`.
   Adapt these to literal search for a real wide grapheme, including one at a
   soft-wrap boundary, and assert the public half-open range covers the complete
   wide unit. Existing selection tests prove wide atomicity, and search tests
   prove narrow soft-wrap matching, but search itself does not visibly pin a
   wide match range. High value, low-to-medium cost.

3. `src/grid/tests.rs#shrink_reflow_empty_cell_inside_line`.
   Recreate the scenario through public terminal operations: write separated
   content using cursor movement so an unwritten interior gap exists, shrink
   across several widths, and assert logical text, geometry validity, and the
   distinction between interior spacing and trailing padding. Existing resize
   walks cover explicit spaces, and selection attachment covers interior
   padding round trips; this one may still add the one-way projection boundary.
   Medium value; first prove it is not already entailed by an existing test.

4. `src/term/mod.rs#clearing_viewport_with_vi_mode_keeps_history_position` has
   one portable half: viewport preservation under ED 2. Fold only that half
   into candidate 1. Do not port its vi cursor assertion.

No inline Alacritty case currently looks like a necessary neutral recording.
These are small semantic boundaries and should be native Swift tests with
source citations.

## Candidate queue by value and cost

| Rank | Scenario | Expected destination | Value | Cost | Initial disposition |
| ---: | --- | --- | --- | --- | --- |
| 1 | ED 2 while browsing retained history | `TerminalViewportTests` or `CSIEraseTests` | high: crosses two public subsystems | low | adapt/probe |
| 2 | literal wide-cell search range | `TerminalSearchTests` | high: proof obligation names Chinese/wide search but current visible case is absent | low | adapt/probe |
| 3 | literal search spanning a soft wrap adjacent to a wide cell/spacer | `TerminalSearchTests` | high: protects projection-to-cell mapping | medium | adapt/probe |
| 4 | reflow with an unwritten interior gap and stripped trailing padding | `TerminalResizeTests` | medium: subtle projection boundary | medium | compare, then adapt if distinct |
| 5 | ED 3 from a browsed viewport | existing `TerminalViewportTests#evictionClampsBrowsingAnchor` | low: already exact and deliberately diverges from Alacritty's snap-to-bottom result | none | annotate only if provenance is useful |
| 6 | page navigation clamps at both ends | existing `TerminalViewportTests#navigationAndFollowingProjection` | low: stronger generic distance coverage exists | none | superseded |

Recommended implementation order is 1, 2, 3, then 4. Stop after each probe to
classify it; do not manufacture a failing result or retain a redundant test.

## Ruled out, superseded, and policy-divergent groups

### Implementation-coupled: rule out (at least 28)

- All 14 `src/grid/storage.rs` cases (`with_capacity`, indexing above logical
  length, rotations around zero, grow/shrink before/after zero, invisible-line
  truncation, initialization) specify Alacritty's rotating storage vector.
- All 11 `src/index.rs` cases specify Rust operator overloads for wrapped and
  clamped `Point` arithmetic.
- All 3 `src/term/cell.rs` cases specify Alacritty cell memory size and its
  private occupied-line scan. DanTerm's analogous observable claims are
  viewport/full-history projection and memory census, already tested without
  adopting Alacritty's representation.
- `src/grid/tests.rs#test_iter` and `#accurate_size_hint` are iterator API
  contracts, not terminal behavior.
- `src/term/mod.rs#grid_serde` and `#parse_cargo_version` are private
  serialization/build utilities.

### Unsupported or outside TerminalCore: rule out (at least 27)

- All 19 `src/vi_mode.rs` cases and the vi-only halves of `src/term/mod.rs`
  cases require Alacritty's emulator vi mode. DanTerm does not offer that mode;
  AppKit/local selection and browsing are its interaction model.
- All 4 `src/tty/**` tests concern Unix passwd lookup or Windows process,
  quoting, and child-exit machinery. They are outside the requested
  `TerminalCore` scope and mostly outside this macOS-only product.
- `src/term/mod.rs#input_line_drawing_character` requires unsupported legacy
  SCS line drawing. DanTerm deliberately swallows the designation without
  leaking bytes, as tested in `TerminalInputStreamTests`.
- Block-selection cases in `src/selection.rs#block_selection`,
  `#block_is_empty`, `#rotate_in_region_up_block`, and
  `src/term/mod.rs#block_selection_works` require a feature DanTerm does not
  currently promise.

### Deliberate policy divergences

- The 33 search cases use Alacritty's regex machinery. Regex compilation,
  empty-match behavior, greed, NFA/cache errors, bounded forward/reverse DFA
  traversal, and regex newlines are non-goals. Only literal stimulus ideas such
  as wide-cell and wrap boundaries are eligible.
- `src/term/search.rs#newline_breaking_semantic`, `#fullwidth_semantic`, and
  semantic-selection cases use configurable Alacritty separator characters.
  DanTerm has a fixed shell-oriented separator contract and already tests it.
- Alacritty line selection appends a newline; DanTerm's shared logical
  projection never adds a final newline merely because a selection ended.
- Alacritty `clearing_scrollback_resets_display_offset` snaps the display to
  bottom. DanTerm's explicit eviction contract clamps a browsing anchor and
  keeps `isFollowing == false`; the current ED 3 viewport test already pins
  that choice.
- `grow_reflow_disabled` and `shrink_reflow_disabled` require a no-reflow
  configuration. Reflow is a required DanTerm behavior and there is no public
  switch to disable it.
- Alacritty's title-stack cap and reset are not automatically a DanTerm
  requirement. Basic OSC title events are covered; adding CSI title-stack
  support would be a capability decision before a test-port decision.

### Superseded portable groups

- `src/grid/tests.rs`: basic scroll up/down, scroll-down with history, ordinary
  shrink/grow/repeated/multiline reflow are covered more broadly by native
  scrolling, scroll-region, scrollback, and resize tests.
- `src/selection.rs`: single-cell direction, adjacent endpoints, selection
  growth/shrink, simple/line/semantic shape, rotations, and intersection are
  either private endpoint mechanics or covered through DanTerm's public
  selected text/range attachment and invalidation. Do not translate inclusive
  endpoint-side arithmetic.
- `src/term/mod.rs`: simple selection serialization, scroll page clamping,
  saved-line clearing, active/inactive cursor resize, damage, and basic title
  setting all have stronger public DanTerm coverage. The alternate/inactive
  resize equivalence test is especially stronger than copying Alacritty cursor
  coordinates.
- `src/term/search.rs`: no-match, navigation wraparound, narrow soft-wrap,
  Unicode scalar handling, and hard/soft line traversal are already covered
  under DanTerm's literal-search contract. Reuse only the missing wide-cell
  projection scenarios named above.

These are grouping dispositions for planning. The implementation pass should
still create a machine-checked 135-entry ledger so no name disappears inside a
group summary.

## Provenance and maintenance approach

Native adapted tests should follow the existing kitty citation shape, adjusted
for Alacritty:

```swift
// Adapted from alacritty_terminal/src/term/search.rs#singlecell_fullwidth
//   (Alacritty 852e971c, body sha256:0123456789ab).
//   Divergence: feeds a real wide grapheme through Terminal and asserts DanTerm's
//   public half-open literal-search range, not Alacritty's inclusive regex range.
```

Use the nearest named Rust function as the refetchable identifier, never a line
number. Hash the complete function body (signature through its balanced closing
brace, with a documented normalization) at the pinned commit. `Divergence:` is
mandatory, including `Divergence: none`.

Before landing more than one or two cases, add an Alacritty parity lint modeled
on `scripts/kitty-parity-lint.py`. It should:

- resolve `file#function` against `references/alacritty`;
- require the manifest/current citation pin to match the fetched pin;
- recompute the body hash;
- require a divergence line;
- exit successfully with a clear skip when the reference checkout is absent;
- be covered by script self-tests and added to `scripts/run-test-suite.sh` only
  as an independent gate step.

Do not extend `alacritty-manifest.json` for inline tests: that manifest's schema
and coverage assertion deliberately describe the 45 recording directories.
Use a sibling `alacritty-inline-manifest.json` if a machine-readable complete
ledger is selected. Give every one of the 135 names a disposition and rationale,
and have a Swift or script audit compare the exact pinned inventory. Recording
fixtures retain `LICENSE.alacritty.txt`; translated native tests retain inline
source attribution. Confirm whether the existing Apache notice is sufficient
for translated snippets or add a narrowly named notice if repository license
practice requires it.

## Open decisions

1. Does ED 2 while browsing preserve the current logical top anchor, or only
   preserve the numeric top row? The DanTerm interaction contract favors the
   logical anchor; the test should state that outcome before implementation.
2. Should the wide search probe use a Chinese character (the product proof
   obligation explicitly names Chinese) or Alacritty's bat emoji? Prefer
   Chinese for the DanTerm contract, and record that stimulus divergence.
3. Is `shrink_reflow_empty_cell_inside_line` already fully entailed by the
   interior-padding selection round trip? If a one-way public-text assertion
   passes and cannot fail independently, classify it superseded.
4. Is a 135-entry inline manifest worth maintaining if only 2-4 cases survive?
   Recommendation: yes, if this is called an exhaustive portage. Otherwise
   explicitly title the work a scoped mine and keep the census in this scratch
   document. Do not imply exhaustive coverage without a checked ledger.
5. Should the lint hash Rust functions by raw bytes or normalized LF text?
   Recommendation: raw bytes from the pinned checkout, truncated to 12 hex
   characters in comments, matching kitty's drift-detection intent.

## Concrete task sketch

- [x] Generate an exact inventory of the 135 `src/**` tests as
  `file#function`; handle attributes between `#[test]` and `fn` and cfg-gated
  functions.
- [x] Create `alacritty-inline-manifest.json` with one disposition per exact
  name, grouped rationales allowed but no missing entries.
- [x] Add the inventory/manifest parity assertion before changing any terminal
  behavior.
- [x] Probe `clearing_viewport_keeps_history_position` with a failing-first
  public test combining retained history, non-following viewport state, and ED
  2. Record whether it passes already.
- [x] Probe `singlecell_fullwidth` using literal Chinese search and assert the
  exact public half-open range includes both display columns.
- [x] Probe a literal match crossing a soft wrap next to a wide-cell spacer,
  using only bytes that can create the state publicly.
- [x] Compare `shrink_reflow_empty_cell_inside_line` against existing resize
  and selection tests; add it only if it protects an independently observable
  boundary.
- [x] For each failing probe, verify the failure is for the intended behavioral
  reason before changing production code; then run the targeted suite after
  the fix.
- [x] Add Alacritty source citations and body hashes to every retained adapted
  test.
- [x] Add the Alacritty parity lint and its self-tests if two or more inline
  adaptations are retained.
- [x] Run targeted `TerminalCore` tests, the parity lint, full
  `swift test --package-path lib/TerminalCore`, `just test`, and
  `git diff --check`.
- [x] Update each manifest disposition/evidence after the probes. A passing
  pre-existing behavior should be `superseded` unless the retained test pins a
  genuinely missing boundary.

## Working log

- 2026-08-01: Confirmed the reference pin matches the existing recording
  manifest (`852e971c...`).
- 2026-08-01: Reconfirmed all 45 recordings are already classified and 20 have
  neutral fixtures; this scratch does not reopen them.
- 2026-08-01: Counted 135 literal inline tests under `alacritty_terminal/src/`.
  The old rough 136 figure likely mixed the direct unit census with the
  `tests/ref.rs` macro template.
- 2026-08-01: Read the eight core test families plus the four platform TTY
  tests and compared their behavior families against the current Swift test
  inventory.
- 2026-08-01: Shortlisted the ED-while-browsing intersection and wide literal
  search as the best apparent gaps. Kept interior-padding reflow as a lower
  confidence probe.
- 2026-08-01: Ruled out blanket translation of storage, coordinates, regex,
  vi mode, block selection, SCS, no-reflow configuration, and platform TTY
  tests.

## Done condition

This portage is done when:

- the 45 recording portfolio remains unchanged and clearly separate;
- every one of the pinned 135 inline `#[test]` functions has a checked
  disposition, rationale, and evidence/candidate destination where relevant;
- every retained adaptation asserts a DanTerm-owned public behavior, carries a
  pin/hash/divergence citation, and was handled with honest TDD;
- unsupported features and policy divergences are named rather than silently
  translated or treated as failures;
- source-pin drift cannot silently invalidate the citations or inventory; and
- targeted and full TerminalCore tests, repository gates, provenance lint, and
  whitespace checks pass.

The scratch document can then be deleted after its tasks and durable ledger are
landed, following the same completion practice as the kitty portage scratch.
