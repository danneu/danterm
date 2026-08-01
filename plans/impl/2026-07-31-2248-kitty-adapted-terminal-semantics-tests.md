# Track kitty's terminal-semantics tests as adapted DanTerm cases

## Context

`references/kitty` now includes `kitty_tests/` (widened cone, this session). That
suite is where kitty wrote down the edge cases for protocols it authored -- OSC
133 among them -- and it is the closest thing to an external conformance suite
for the semantics `TerminalCore` implements.

Two facts motivate adapting a slice of it now:

- **Reflow-plus-prompt is where DanTerm's real defects have lived.** F16 and F17
  in [docs/research/24-osc-133-dialect/](../../docs/research/24-osc-133-dialect/README.md)
  are four rounds of live-pane bugs, all in the blanking anchor and the reflow
  beneath it. kitty exercises the same intersection from a different angle.
- **kitty is not authority here, and we can prove it.** Its own reflow test
  (`kitty_tests/shell_integration.py#test_fish_integration`) uses an 11-character
  prompt, a single 80->40 jump, and asserts `count(ps1) == 2` -- it *expects* the
  stale copy. That test passes identically under `redraw=0` and `redraw=1`, so it
  is exactly the non-discriminating stimulus F11 fell for and F13 refuted. We
  adopt kitty's *scenarios*, never its assertions, and never its verdict on
  redraw.

So the goal is compatibility coverage with an audit trail: each adapted test says
which kitty test it tracks, and a lint tells us when that upstream test changes.

**Non-goal:** this does not substitute for the doc's two open TODOs (a fish
recording that discriminates the redraw value; rendering the Bash dialect in a
real pane). Those need recorded live-pane stimuli. Per F16's rule, a synthetic
suite cannot close them, and this plan must not be read as having done so.

## Scope

Tier A+B only: prompt semantics and reflow. Concretely, 8-11 tests.

### Tier A -- from `kitty_tests/screen.py#test_prompt_marking`

Only a minority of that 330-line test is applicable; the rest drives
`scroll_to_prompt`, `cmd_output`, `set_last_visited_prompt`, and
`erase_last_command`. See "Deliberately out of scope".

| # | Scenario | Why it is worth pinning |
| --- | --- | --- |
| A1 | Prompt marked, then alt-screen entered, resized, and exited | Resize while the primary screen is parked; the prompt row must leave no debris on the cursor row. Adjacent to `lineAndAlternateScreenState` -- check for overlap before writing. |
| A2 | A prompt wide enough to wrap scrolls into scrollback, then the grid narrows | Prompt identity and its continuation stamps must survive reflow (`Terminal.swift:4159-4190`). This is the F16 anchor's input. Contract below. |
| A3 | The prompt head is out of the walk's reach, then a resize | The upward walk has no anchor. kitty's `clear_scrollback` cases cover the same degradation; ours arrive via `scrollbackBudgetBytes`. Highest-value case in Tier A. Contract below. |

#### Observable contract for A2 and A3

`GridRow.semanticPrompt` is unreachable by design, so both cases are defined by
what the text does. These are the verdicts; DanTerm disagreeing with one is a
defect to file (see Risks), not a `Divergence:` to record.

**A2.** Mark a prompt with `OSC 133;A`, print a prompt string longer than the
width so it soft-wraps, emit output until the whole block is in scrollback, narrow,
then widen back to the original width.

1. The logical lines of `fullHistoryText` are byte-identical before the narrowing,
   after it, and after widening back. This is the width-independent-logical-lines
   invariant already pinned by `76e85c2`, applied to a marked prompt.
2. The prompt is one logical line at every width -- the reflow neither splits it
   into two logical lines nor joins it with the line below.
3. The prompt's distinctive text occurs exactly once in `fullHistoryText` at every
   width. No stale copy is ever added.
4. At the original width the rows split exactly as they did originally.

A2 claims nothing about the stamps themselves: they are not observable, and the
test must not reach for them. Round-trip fidelity plus non-duplication is the
whole proof obligation.

**A3.** Put the grid in the state where `clearPromptForResizeIfNeeded` walks up
from the cursor and finds neither `.prompt`/`.vacated` nor `.output` before the
top of the screen -- the prompt head has scrolled out of the visible grid, and a
tight `scrollbackBudgetBytes` has evicted it from history too. Then resize
narrower and back.

1. **Nothing is blanked.** The concatenated logical text of the visible screen is
   unchanged by the resize (re-split across rows is expected; lost characters are
   not). An anchorless walk is entitled to blank nothing -- that is what the
   `case .output: return` arm and the fall-through past row 0 both mean.
2. The evicted head does not reappear in `fullHistoryText`, at any width.
3. No text is duplicated: the occurrence count of every surviving marker string is
   the same before and after each resize.
4. **The next cycle is clean.** Feed a fresh `OSC 133;A` and prompt on a new line,
   then resize again. That resize blanks exactly the new prompt block and leaves
   every row above it intact. This is the assertion that distinguishes "the stamp
   was safely lost" from "stale prompt debris survived and now anchors the walk",
   and it is why A3 is the highest-value case here.

### Tier B -- from `kitty_tests/datatypes.py#test_rewrap_{simple,wider,narrower}`

| # | Upstream case | Expected |
| --- | --- | --- |
| B1 | `'0123 '` + `'56789'` continued, widen to 6 | `'0123 5'`, `'6789'` -- a trailing space *inside* a continued line is content and must shift, not be trimmed |
| B2 | `'12'`, `'abc'` not continued, rewrap | stay two lines; reflow must not join unwrapped rows |
| B3 | `'123'`, `'abcde'`, narrow to 3 | `'123'`, `'abc'`, `'de'`; wrap flags `[false, false, true]` |
| B4 | `'123  '`, `'abcde'`, narrow to 3 | `'123'`, `'  a'`, `'bcd'`, `'e'`; flags `[false, true, true, true]` |
| B5 | same-width rewrap; row growth; row shrink | identity; content preserved with blank padding; rows dropped from the top |

`TerminalResizeTests` already has "width reflow preserves logical text across
narrow, wide, emoji, and spaces", which may subsume B1/B4. **Check before
writing.** If a case is genuinely covered, add the citation comment to the
existing test rather than duplicating it, and note that in the commit.

### Deliberately out of scope

Not adapted, because adapting them means *building features*, not tests -- and
features `plan-terminal-engine/16-semantic-model.md` rules out:

- `scroll_to_prompt`, `cmd_output`, `set_last_visited_prompt`,
  `erase_last_command`. DanTerm has no equivalent, and 16's boundary is explicit:
  OSC 133 is an engine-internal row-classification and prompt-redraw protocol,
  never a semantic input. Command state is the OSC 1337 envelope's job, and the
  command journal (`17-command-journal.md`) is deferred.
- `pagerhist`, `user_marking`, `graphics_command`, multicell scaling,
  `pointer_shapes`, `multi_cursors`, `color_profile`/oklch, `text_cache`
  garbage collection, `parser_threading` -- features or internals DanTerm does
  not have.
- kitty's shell-integration PTY suite. It tests kitty's own shell scripts; ours
  are already covered by `scripts/tests/shell-integration_test.sh` plus replayed
  recordings, and its resize assertions are the non-discriminating ones above.

## Traceability

Each adapted test carries its citation in the preamble, as the fourth section
after the AGENTS.md `Intent / Why it exists / Scenario` block:

```swift
// Adapted from kitty_tests/datatypes.py#test_rewrap_narrower
//   (kitty v0.48.2 2cb1d95, body sha256:ab12cd34ef56).
//   Divergence: asserts logical text and `isSoftWrapped`, not LineBuf.is_continued.
```

The hash lives in the comment rather than a side manifest, so there is exactly
one source of truth and nothing to desync. `Divergence:` is required whenever the
assertion differs from upstream's -- which is most of them, since kitty asserts
through APIs we do not have.

Citation form follows the AGENTS.md rule for refetchable trees: `file#identifier`,
never `file:line`.

### `scripts/kitty-parity-lint.py`

Mirrors `scripts/fetch-references.py` in style and `scripts/research-index-lint.sh`
in role. Invariants:

- **I1** Every `Adapted from kitty_tests/...` citation resolves to a real
  `def <name>` in that file inside `references/kitty`.
- **I2** The cited commit matches the `kitty` pin in `scripts/fetch-references.py`.
  A citation left behind by a pin bump is an error, not a warning.
- **I3** The recorded body hash matches the upstream body, where "body" is from
  the `def <name>(` line to the next line at the same or lower indentation
  beginning `def ` or `class `. A mismatch means upstream revised the behavior --
  a review prompt, which is the entire point of tracking.
- **I4** Every citation includes a `Divergence:` line or an explicit
  `Divergence: none`.

**Skips cleanly with exit 0 and a printed reason when `references/kitty` is
absent** -- `references/` is gitignored, so a fresh clone and CI have no
checkout. This is the one thing that will break the gate if missed.

The lint and its self-test both run in the full gate, each independent of every
other step. The self-test drives the lint over fixture trees for each invariant,
including the references-absent skip.

### Deliverables

- Tier A and Tier B tests in `lib/TerminalCore/Tests/`, against the public
  `Terminal` surface only.
- The lint and its self-test, as scripts.
- `agent-docs/reference-sources.md` gains the citation format and a note that the
  lint enforces it, so the next agent finds the convention from the reference doc
  rather than by pattern-matching a test file.

Assert behaviorally. `GridRow.semanticPrompt` is `private`, so `@testable` cannot
reach it -- which is the right constraint anyway, per the repo's structure-
insensitive test bar. Pin what a resize *does* to the text, not what a row is
stamped.

## Verification

Both new gate steps and the two affected test suites pass, and `just test` is
green with the new steps colliding with nothing.

TDD applies where there is something to drive: a scenario that exposes a real
defect gets a genuine red-green cycle (and the fix leaves this tests-only plan,
per Risks). An adapted case that DanTerm already satisfies is characterization
coverage and may pass on first run -- do not manufacture a failure for it, and do
not change production code to create one.

The lint must be shown to bite before it is trusted: a corrupted hash fails I3, a
renamed upstream test fails I1, and a missing `references/kitty` exits 0 with a
printed reason. Those three are the self-test's core cases, not manual steps.

## Risks

- **Duplicate coverage.** Tier B overlaps `TerminalResizeTests`'s existing reflow
  tests. Mitigated by the check-before-writing rule above; the failure mode is
  wasted tests, not wrong ones.
- **A genuine divergence surfaces.** If DanTerm disagrees with kitty on a rewrap
  case, that is a finding, not a test to force green. Record it as a `Divergence:`
  with the reason, and if it looks like a real defect, stop and file it rather
  than encoding our current behavior as intent.
- **Hash churn.** I3 fires on any upstream whitespace change. Acceptable because
  the pin only moves deliberately, and the whole value is a prompt to re-read on
  bump. If it proves noisy, normalize whitespace before hashing -- do not delete
  the check.

## Commit progress
- [x] 1. test(terminal): adapt kitty's prompt-marking and rewrap cases
- [ ] 2. build(scripts): lint adapted-kitty citations against the pinned checkout

## Implementation notes

- **Commit 1 -- B5 was already covered; annotated instead of duplicated.** The
  three legs of `test_rewrap_simple` (same-width identity, row growth with blank
  padding, rows dropped from the top) map exactly onto
  `invalidAndSameSizeResizeAreNoOps`, `heightGrowthEligibility`, and
  `heightShrinkTransfersRows`. Each got the citation block per the plan's
  check-before-writing rule.
- **Commit 1 -- B1-B4 were not covered.** `widthWalkConservesFullHistory` and its
  siblings assert `fullHistoryText` invariance across widths; they say nothing
  about the exact row split or the wrap flags, which is the whole content of the
  rewrap cases. Written fresh.
- **Commit 1 -- A3 uses short output lines.** The anchorless state needs eviction
  (`scrollbackBudgetBytes: 256`), but narrowing a *long* row would evict more and
  confound the "nothing was lost" claim with budget pressure. Two-character output
  lines re-split at no width in the range, so the only thing the resize can change
  is what blanking does -- which is what A3 is about.
- **Commit 1 -- citation hashes are 12-hex sha256 prefixes**, matching the plan's
  worked example rather than the full digest, which does not fit a comment line.
- All eight adapted cases passed on first run. Per the plan's Verification
  section that is characterization coverage, not a missing red step: no defect
  surfaced and no behavioral divergence from kitty was found.
