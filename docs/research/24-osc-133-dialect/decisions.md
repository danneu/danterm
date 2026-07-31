# Decisions

The authored dialect, decision by decision. The bytes themselves are in
[dialect.md](dialect.md); this file records why each shell got what it got.

### D0 -- every prompt restates its redraw mode

- Status: selected.
- Evidence used: F1 (the mode is per-terminal state, reset only by RIS), F7 case
  5 (an `A` with no `redraw` option inherits whatever a previous shell set).
- Candidate solutions: (a) declare the mode once when the integration loads;
  (b) declare it on every prompt.
- Tradeoffs and correctness risks: (a) is one byte sequence per session, but the
  mode is pane state, not shell state. A nested `bash` that declares `last` and
  exits leaves the outer zsh in `last` mode for the rest of the pane's life,
  silently downgrading it to blanking one row of a multi-line prompt. Nothing
  detects this. (b) costs a handful of bytes per prompt -- and for zsh and Bash
  the mark carrying it is already emitted per prompt, so the real cost is the
  option field only.
- Selected direction: (b). Each integration states its mode on the prompt-start
  mark of every prompt.
- Behavioral verification: F7 case 5 shows the inherited-mode failure and the
  restatement fixing it.
- Decision and rationale: a sticky global that no participant owns needs a
  writer on every cycle, not an initializer. This is what makes D1-D3 composable
  across nested shells at all.

### D1 -- zsh: marks in `PS1`/`PS2`, `redraw=1`, continuation lines stamped

- Status: selected.
- Evidence used: F3 (zsh re-emits `PS1` whole on SIGWINCH and repaints the whole
  prompt), F1, F7 case 1.
- Candidate solutions: (a) print marks from `precmd`; (b) embed them in
  `PS1`/`PS2` inside `%{...%}`.
- Tradeoffs and correctness risks: (a) emits once per prompt *creation*, so a
  SIGWINCH repaint or `reset-prompt` redraws prompt text with no marks in front
  of it -- the row loses its stamp and the next resize blanks nothing (or blanks
  from a stale stamp further up). (b) is re-emitted on every redisplay, which is
  precisely what F3 measured, and `%{...%}` keeps the marks out of zsh's prompt
  width accounting. Risk: a prompt framework that rebuilds `PS1` asynchronously
  drops the marks; Ghostty carries real machinery for this (saving and restoring
  a clean `PS1`, detecting third-party modification), and DanTerm's emitter will
  need the same care.
- Selected direction: (b), with `A;redraw=1` opening `PS1`, `B` closing it,
  `A;k=s` opening each continuation line of a multi-line `PS1` and opening `PS2`.
  `C` is printed from `preexec`, after the existing `command-start` envelope
  event.
- Behavioral verification: F7 case 1 -- four resize/repaint cycles leave exactly
  one prompt in history. F7 case 4 -- `C` protects command output from blanking.
- Decision and rationale: zsh is the one shell that repaints everything, so it is
  the one shell that can safely ask for everything to be blanked. `A` is correct
  inside zsh's `PS1` (unlike Bash's, per the rejected idea in README) because
  zsh's redisplay starts at column 0, where `A`'s fresh line is a no-op.

### D2 -- Bash: `A;redraw=last` from precmd, `P` inside `PS1`/`PS2`

- Status: selected.
- Evidence used: F4 (readline repaints only the final prompt line), F1, F7 case 2.
- Candidate solutions: (a) `redraw=1` like zsh; (b) `redraw=last`; (c) no marks
  for Bash.
- Tradeoffs and correctness risks: (a) blanks the whole prompt block and readline
  rewrites only its last line -- the upper lines are erased permanently. That is
  a data-destroying default, and it is destructive in exactly the multi-line-prompt
  case users are most likely to have. (b) blanks the one row readline is about to
  rewrite, which is the row-for-row match to the measured behavior. (c) forfeits
  the resize fix for Bash entirely.
- Selected direction: (b). `A;redraw=last` printed once per prompt from the
  precmd hook (fresh line + mode declaration + row stamp); `P;k=i` opening `PS1`
  and `P;k=s` opening `PS2` and each continuation line, each closed by `B`; `C`
  from preexec.
- Behavioral verification: F7 case 2 -- after a resize the top prompt line
  survives and only the cursor row is blanked.
- Decision and rationale: the redraw mode is a promise about what the shell will
  repaint. Bash promises one line, so DanTerm may blank one line. `P` rather than
  `A` inside `PS1` because readline redisplays mid-line (README, rejected ideas).

### D3 -- fish: declare `redraw=0`, emit nothing else

- Status: selected. **The value is unchanged from the original draft, but every
  reason for it has been replaced.** The first version argued `redraw=0` because
  fish supposedly never repaints (H1) and had no lever to make it (H2). F8 and
  F9 refuted both: fish repaints its whole prompt on SIGWINCH whenever
  `fish_handle_reflow` is `1`, which is what a DanTerm-identified terminal
  auto-detects, and that variable is live and settable. D3 was reopened, and H3
  re-decided it on new evidence. Do not cite the old reasoning.
- Evidence used: F5 (fish emits `A`/`B`/`C`/`D` itself), F8/F9 (fish *does*
  repaint; `fish_handle_reflow` is the lever), F10 (fish left-truncates its
  prompt, so a fish prompt row never soft-wraps), F11 (all three configurations
  are observationally identical in a real pane). ~~F6~~ retracted.
- Candidate solutions: (a) `fish_handle_reflow 1` + `redraw=1` -- fish repaints,
  DanTerm blanks the block first; (b) `redraw=0` -- nobody blanks; (c) emit
  nothing and inherit the parser default (`full`).
- Tradeoffs and correctness risks: F11 measured all three as indistinguishable,
  so this is not a choice between outcomes -- it is a choice between mechanisms
  that produce the same outcome. F10 says why: a fish prompt row never wraps, so
  it never re-wraps on resize, so there is no stale-prompt staircase for blanking
  to fix. That makes (a) a destructive operation with nothing to act on -- if
  fish's repaint is ever incomplete, blanking upgrades a cosmetic artifact into
  an erased prompt. (c) has (a)'s risk and additionally leaves the mode at
  whatever a nested shell last set (D0).
- Selected direction: (b). Emit `A;redraw=0` from a `fish_prompt` event handler,
  once per prompt. **Do not set `fish_handle_reflow`** -- leave fish's own
  detection alone; F11 shows its value does not matter to the rendered result,
  and not touching it is one less thing to keep correct.
- Behavioral verification: F11 (real pane, three configurations, both resize
  directions, re-wrapping content). F7 case 3 shows what `full` mode would do to
  a multi-row prompt, which is the failure `redraw=0` forecloses.
- Decision and rationale: prefer the mechanism that cannot destroy the user's
  prompt when the outcome is otherwise identical. The declaration still earns its
  bytes even though blanking is unnecessary -- it is what stops a nested shell's
  `redraw=1` from persisting into the fish pane and blanking a prompt block that
  nothing needs blanked (D0).
- Candidate solutions: (a) `redraw=1`, matching zsh; (b) `redraw=0`; (c) emit
  nothing at all and inherit the parser default.
- Tradeoffs and correctness risks: (a) and (c) are the same outcome, since the
  parser's default is `full` -- and on F6's evidence that outcome is a blanked
  prompt that never comes back, which is strictly worse than the stale prompt
  DanTerm has today. (b) reproduces today's behavior exactly (no blanking) while
  making it an explicit, pane-scoped declaration rather than an accident, and it
  cannot be flipped by a nested shell (D0). Its cost: fish panes get no prompt
  redraw benefit.
- Selected direction: (b), emitted as `A;redraw=0` from a `fish_prompt` event
  handler. DanTerm adds no other mark for fish; `A`/`B`/`C`/`D` are fish's own.
  Emitting a second `A` at column 0 is idempotent for the row stamp and its fresh
  line is a no-op, so ordering against fish's native mark does not matter -- only
  DanTerm's carries a `redraw` option, and an option-less `A` never clears the
  mode (F1).
- Behavioral verification: F7 case 3 demonstrates the failure `redraw=0` avoids.
  A positive verification of fish under `redraw=0` is trivial (nothing is
  blanked) and is the same code path as a pane with no marks at all.
- Decision and rationale: prefer the degradation that loses a feature over the
  one that erases the user's prompt. Reopen the moment H1 shows fish repaints:
  the change is one option value, and the rest of the fish entry is unaffected.

### D4 -- what the dialect does not emit

- Status: selected.
- Evidence used: F1, F7 case 6, and the semantic-model plan's boundary.
- Decision and rationale, mark by mark:
  - **`D` / `D;<status>`** -- not emitted. After a `C`, `D` changes no parser
    state the next `A` does not restore, and the exit status it would carry is
    what slice 1 adds to the private envelope's `command-end`, which is the
    authority the reducer reads. Two status channels, one consumer. (README,
    rejected ideas.)
  - **`L`** -- not emitted. `A` already performs the fresh line the dialect
    needs, and `L` is accepted only in its bare form (F1, F7 case 6), so it is a
    trap for a later author who adds an option to it.
  - **`I`** -- not emitted. `I` marks input that clears at end of line; the
    dialect uses `B`, matching what the in-gate zsh capture and every reference
    integration emit, and keeping input classification stable across the newline
    a submitted command produces.
  - **`N`** -- not emitted. It is a second spelling of `A` in this parser, and
    two spellings of one mark in one dialect is a maintenance hazard with no
    payoff.
  - **`aid=`, `cl=`, `click_events=`** -- not emitted by DanTerm. All are inert
    for this parser (F7 case 6). Emitting inert options invites a reader to
    believe they do something.
  - **Any semantic use of these marks** -- refused by the plan this doc serves.
    Marks classify rows and drive prompt redraw. Command, remote, integration,
    and agent facts come from `OSC 1337;DanTermShell=1` and nothing else.
