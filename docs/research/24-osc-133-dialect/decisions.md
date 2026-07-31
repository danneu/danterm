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

- Status: selected. **Mechanism amended by F14; marks and redraw value
  unchanged.**
- Evidence used: F3 (zsh re-emits `PS1` whole on SIGWINCH and repaints the whole
  prompt), F1, F7 case 1, F14 (how the marks get *into* `PS1`, and that the
  declaration survives a framework's optionless neighbors).
- Candidate solutions: (a) print marks from `precmd`; (b) embed them in
  `PS1`/`PS2` inside `%{...%}`.
- Tradeoffs and correctness risks: (a) emits once per prompt *creation*, so a
  SIGWINCH repaint or `reset-prompt` redraws prompt text with no marks in front
  of it -- the row loses its stamp and the next resize blanks nothing (or blanks
  from a stale stamp further up). (b) is re-emitted on every redisplay, which is
  precisely what F3 measured, and `%{...%}` keeps the marks out of zsh's prompt
  width accounting. The risk originally recorded here -- a framework that
  rebuilds `PS1` asynchronously drops the marks -- **is not the one that bites
  for Starship** (F14): Starship-zsh assigns `PROMPT` once at init and never
  again, so what kills a source-time `PS1=` assignment is simply that the
  framework's init runs later in `~/.zshrc` and overwrites it. Measured: 0 marks,
  silently, in the maintainer's own configuration.
- Selected direction: (b), with `A;redraw=1` opening `PS1`, `B` closing it,
  `A;k=s` opening each continuation line of a multi-line `PS1` and opening `PS2`.
  `C` is printed from `preexec`, after the existing `command-start` envelope
  event. **The wrapping happens in a `precmd` hook, not at source time**, and the
  hook is idempotent: it keeps a pristine copy of `PS1`, rebuilds from that copy
  every prompt, and re-captures whenever a third party has changed `PS1`
  underneath it. F14 measured the unguarded "wrap whatever `PS1` is now" variant
  growing two marks and one visible marker per prompt cycle without bound.
- Behavioral verification: F7 case 1 -- four resize/repaint cycles leave exactly
  one prompt in history. F7 case 4 -- `C` protects command output from blanking.
  F14 stage 2 -- the guarded hook holds at two marks per prompt across four
  cycles and a SIGWINCH, with the user's Starship prompt intact.
- Decision and rationale: zsh is the one shell that repaints everything, so it is
  the one shell that can safely ask for everything to be blanked. `A` is correct
  inside zsh's `PS1` (unlike Bash's, per the rejected idea in README) because
  zsh's redisplay starts at column 0, where `A`'s fresh line is a no-op. F14
  confirms the need as well as the safety: the maintainer's real zsh prompt has a
  right-aligned segment padded to the full width, the same re-wrapping row shape
  that produced fish's staircase in F13.
- Known gap carried to Phase 3: the guarded hook is only proven against
  framework hooks registered *before* it. A framework whose `precmd` is
  registered after DanTerm's overwrites the wrapped `PS1` and the dialect goes
  silent -- 0 marks, no diagnostic (F14 stage 3). Emitter-level problem, not a
  dialect change.

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

### D3 -- fish: declare `redraw=1`, emit nothing else

- Status: selected. **Reversed on 2026-07-31 by F13; the previous value
  (`redraw=0`) was wrong.** This decision has now been decided three times. The
  first version chose `redraw=0` because fish supposedly never repaints (H1) and
  had no lever to make it (H2); F8/F9 refuted both. The second kept `redraw=0` on
  F10/F11, reasoning that fish prompts never wrap so blanking has nothing to fix.
  F13 refutes that too: replaying a real fish + Starship prompt through a
  one-column-at-a-time width sweep reproduces the original staircase under
  `redraw=0` (31 prompt copies in history, 10 on screen) and stays clean under
  `redraw=1`. Do not cite either earlier version.
- Evidence used: F13 (the decisive replay), F8/F12 (fish repaints on SIGWINCH,
  and DanTerm's real XTVERSION identity is what puts it in that branch), F5
  (fish emits `A`/`B`/`C`/`D` itself), F1 and F7 case 5 (the mode is sticky
  per-pane state). ~~F6~~ retracted; F10 stands but its inference does not; F11
  stands only for prompts narrower than the pane.
- Candidate solutions: (a) `redraw=1` -- fish repaints, DanTerm blanks the block
  first; (b) `redraw=0` -- nobody blanks; (c) emit nothing and inherit the parser
  default (`full`).
- Tradeoffs and correctness risks: (b) is now measured as defective -- it ships
  the exact staircase the OSC 133 consumer was built to fix, in the maintainer's
  own daily fish + Starship configuration. (a) and (c) both render correctly
  today, because the parser default is already `full`; they differ only in what
  happens after a nested shell sets a different mode, which is sticky for the
  life of the pane and unrecoverable without a restatement (D0). (a) additionally
  costs a handful of bytes per prompt.
- Selected direction: (a). Emit `A;redraw=1` from a `fish_prompt` event handler,
  once per prompt. DanTerm adds no other mark; `A`/`B`/`C`/`D` are fish's own.
  **Do not set `fish_handle_reflow`** -- fish's auto-detection already resolves
  to `1` for DanTerm's terminal identity (F12), and F13 confirms it repaints on
  every resize step, so there is nothing to force.
- Behavioral verification: F13's three-variant replay -- `redraw=1` and the
  unmarked control both leave exactly one prompt after a 30-step sweep, while
  `redraw=0` leaves ten on screen. F7 case 1 is the equivalent proof for zsh.
- Decision and rationale: fish repaints its whole prompt, so fish can safely ask
  for the whole prompt to be blanked -- the same reasoning D1 applies to zsh, and
  the same reasoning the first two versions of this decision talked themselves
  out of. The declaration earns its bytes by pinning the mode against a nested
  shell that sets `redraw=0` or `redraw=last` and exits (D0); without it, fish
  panes inherit whatever the last shell left behind.
- What would change my mind: a prompt that fish repaints only partially after
  SIGWINCH. Blanking is scoped to what the shell promises to rewrite, so a
  partial repaint under `redraw=1` erases the difference permanently. F13
  exercised one prompt shape (two rows, right-aligned, full width); a prompt
  whose upper rows fish leaves untouched would be the counterexample.

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
