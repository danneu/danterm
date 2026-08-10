# Milestone 8, Slice 1: Alacritty tmux and Vim Recordings

## Problem and evidence

Milestone 7's roadmap children are complete, including the native shell-event,
capability, real-pane protocol, and UTF-8 control-string work, but its parent
checkbox remains stale. Milestone 8 has five pinned Alacritty application
recordings that are already classified as pending and assigned to this
milestone:

- `tmux_git_log`
- `tmux_htop`
- `vim_24bitcolors_bce`
- `vim_large_window_scroll`
- `vim_simple_edit`

The neutral fixture runner currently replays only the 15 adopted or adapted
Milestone 6 Alacritty recordings. Leaving these five pending postpones bounded,
deterministic evidence that tmux and Vim output compose correctly through the
headless core, while beginning with a broad live-application harness would mix
terminal-state defects with PTY, environment, and orchestration failures.

## Desired outcome

Adopt all five recordings into the neutral replay portfolio with honest,
DanTerm-owned public expectations. Any incompatibility they expose is first
preserved as a focused native regression and then fixed against DanTerm's
terminal contracts. Update the Alacritty ledger and roadmap so this completed
slice is visible, Milestone 7 is closed, and the exact remaining Milestone 8
work is explicit.

## Decision

- Convert the five pinned recordings into provenance-bearing neutral fixtures
  and replay them through the existing public, structure-insensitive runner at
  their authored dimensions and byte chunking.
- Compare the relevant final terminal behavior, including visible text, cell
  presentation, cursor and modes, primary history, and alternate-screen state
  where the recording exercises them. Imported Alacritty grid layout is
  evidence for deriving expectations, not a normative private data model.
- Classify each manifest entry as `adopted` when its full applicable public
  outcome is retained or `adapted` when DanTerm intentionally expresses or
  differs from part of that outcome. Every adaptation records the behavioral
  rationale and remains strong enough to prove the recording's tmux or Vim
  behavior.
- When replay fails, reduce the first distinct behavioral defect to the
  smallest native regression at the lowest public seam that demonstrates it.
  Verify that regression fails for the same reason before changing behavior,
  then make both the native regression and application recording pass. Reuse a
  single regression when multiple recordings expose the same defect.
- Mark the Milestone 7 parent checkbox complete. Add a checked Milestone 8
  Slice 1 entry, but do not close any Milestone 8 parent criterion solely from
  these imported headless recordings.
- Before closing Milestone 7, replace the stale `pending` dispositions for its
  six `vttest_*` recordings with honest final dispositions and rationales
  consistent with the completed Milestone 7 scope. A superseded disposition
  identifies executable behavioral evidence for the recording's applicable
  outcome; unsupported behavior is classified out of scope rather than
  silently carried into Milestone 8.
- Record the remaining Milestone 8 gaps in the roadmap after this slice:
  DanTerm-owned workflows for tmux, Vim, Neovim, btop, htop, lazygit, Claude
  Code, and Codex; direct and tmux or ssh variants wherever those layers change
  behavior; and the live pane, PTY, input, renderer, teardown, and recording
  evidence needed to support those workflows. The five imported recordings
  cease to be listed as pending.

## Invariants

1. External recordings remain pinned evidence rather than authority: DanTerm's
   declared terminal behavior adjudicates every mismatch.
2. All five recordings replay deterministically through neutral public seams
   without depending on Alacritty's serialized grid representation.
3. A recording-discovered defect cannot be fixed only at application scale; a
   focused failing-then-passing native regression preserves its behavioral
   cause.
4. Manifest disposition, fixture inventory, provenance, and executable replay
   cannot drift independently.
5. Roadmap completion claims distinguish headless imported-recording evidence
   from the live application workflows still required by Milestone 8.
6. A closed milestone has no manifest recording still marked `pending` for
   that milestone.

## Proof obligations

1. Manifest coverage proves the exact 45-recording pinned inventory, requires
   these five Milestone 8 entries to be adopted or adapted with non-empty
   rationales, requires their neutral fixtures to exist alongside the 15
   Milestone 6 application fixtures, and rejects every `pending` Milestone 7
   entry. The six finalized `vttest_*` entries have non-empty rationales and
   executable evidence for every superseded behavioral claim.
2. Neutral replay proves each tmux and Vim recording's applicable final public
   state under authored chunking. Provenance validation pins the upstream
   commit, case name, URL, and Apache-2.0 notice.
3. Each distinct failure found during adoption has a focused native test that
   fails before its behavior change and passes with the corresponding imported
   fixture afterward. Existing behavior claims used to dismiss or adapt a
   mismatch are backed by an executable behavioral test, not rationale alone.
4. The completed TerminalCore fixture and native suites pass, followed by
   `just test` and `just build`.
5. The roadmap shows Milestone 7 complete, Slice 1 complete, and the remaining
   Milestone 8 application, layered-workflow, and live-boundary gaps without
   claiming that the milestone itself is complete.

## Non-goals and accepted risks

- This slice does not build the broad live application harness or claim that
  tmux, Vim, htop, or any other advanced TUI completes its minimum workflow.
- It does not add DanTerm-owned application recordings, real-pane tmux or ssh
  variants, renderer screenshots, or pixel comparisons.
- It does not replay or adopt the six Alacritty `vttest_*` recordings as
  fixtures; it closes their stale Milestone 7 ledger entries against existing
  scope and executable evidence.
- Authored chunking is sufficient for these large application recordings. The
  smaller native parser and state regressions retain exhaustive split coverage
  for any defect discovered here.

## Implementation discretion

- The neutral expectation shape and importer organization may follow existing
  fixture conventions as long as the public behavioral assertions and ledger
  invariants above hold.
- The number and grouping of native regressions follows the distinct defects
  actually exposed by replay rather than the number of source recordings.

## Implementation notes

- The five viewport replays exposed no TerminalCore defect. The three Vim
  fixtures are adapted because DanTerm retains explicit RGB foregrounds that
  Alacritty resolves to its configured default color.
- The five large application fixtures run as independently reported Swift
  Testing arguments so they can execute concurrently and failures remain
  bounded to one named recording.

## Follow Up

- Investigate the existing TerminalPTY suite hanging without output or CPU in
  `scripts/test-terminal-pty.sh`; this implementation's `just test` run passed
  TerminalCore, including all five new recordings, then was stopped after the
  TerminalPTY phase remained idle for more than nine minutes alongside older
  stale TerminalPTY test helpers.
