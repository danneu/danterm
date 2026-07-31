# The OSC 133 dialect DanTerm's shell integrations emit

Research started: 2026-07-31.

- [findings.md](findings.md) -- the append-only evidence chain: what the parser
  accepts, what the bundled scripts emit today, and how each shell behaves on
  SIGWINCH.
- [decisions.md](decisions.md) -- the auditable decision log: the authored
  per-shell mark set, the redraw mode each shell declares, and what is
  deliberately not emitted.
- [dialect.md](dialect.md) -- the authored dialect itself: the exact bytes each
  bundled integration emits, at which hook, with the parser rule each one relies
  on.

## Purpose

This doc owns task R1 of
[Live pane semantic model](../../../plan-terminal-engine/16-semantic-model.md):
author the OSC 133 dialect DanTerm's own zsh, Bash, and fish integrations emit,
and check every mark in it against the parser that already ships.

The boundary it must preserve is the one that plan draws: **OSC 133 is an
engine-internal row-classification and prompt-redraw protocol, never a semantic
input.** Nothing here may feed the live semantic reducer, create command state,
or become an app-facing event. The private `OSC 1337;DanTermShell=1` envelope
stays the sole authority for command, remote, and integration facts. A mark
earns its place in this dialect only by changing how a row is classified for
reflow or how the prompt block is treated on resize.

## Investigation rules

- A claim about the parser is checked by feeding bytes to `TerminalCore.Terminal`,
  not by reading `dispatchOSC133`. Reading the code picks the probe; the probe is
  the evidence.
- A claim about a shell is checked in a real PTY with a real shell binary, and
  records the shell version and how much user config was loaded. A shell behavior
  quoted from Ghostty's integration is a lead, not evidence.
- The dialect may only use marks the shipping parser already accepts. If a mark
  the dialect wants is not accepted, that is a parser change with its own plan --
  record it here and stop, rather than authoring bytes nothing consumes.
- R1 authors and records the dialect. It does not ship script changes; the
  emitters are a separate implementation task (see the ledger).
- **A null result must argue that its stimulus could have produced a positive
  one.** Added after F13: F11 measured no difference between three redraw modes
  and was wrong, because its prompt was narrower than the pane and so no row
  could re-wrap. A probe that reports "no effect" states what shape the effect
  would have taken and why the stimulus would have exhibited it.

## Trigger and current evidence

`plan-terminal-engine/16-semantic-model.md` R1 asks for the marks "DanTerm's
scripts emit" -- and the answer, at commit `3b9707e`, is **none**. The three
bundled integrations (`integrations/shell-integration/danterm.{zsh,bash,fish}`)
emit only the private OSC 1337 envelope and OSC 7 cwd. No `133` byte sequence
appears anywhere in the repo outside `Terminal.swift`, its tests, and prose (F2).

Meanwhile the engine has a complete OSC 133 consumer: prompt/continuation row
stamping, three redraw modes, and prompt-block blanking before reflow, shipped
by `plans/impl/2026-07-22-1422-osc-133-prompt-redraw.md` and pinned by
`TerminalOSC133Tests`. It exists because a real shell -- the maintainer's, not
DanTerm's -- emits marks, and split-open resizes were leaving a staircase of
stale prompts.

That incident is worth naming precisely, because this doc got it wrong twice.
The shell was **fish**, not zsh: the maintainer's `~/.zshrc` exec'd fish on its
third line, so every pane ran fish under a zsh-shaped `$SHELL` (removed
2026-07-31, in favor of fish as the account shell). The marks were fish's own
native `133;A;click_events=1` / `133;B` (F5), and the prompt was Starship's --
two rows, right-aligned segment padded to the full pane width. The in-gate
fixture `Fixtures/danterm/zsh-osc133-width-sweep.json` is **not** that capture:
its provenance records `author: DanTerm, source: danterm`, and it is a 12-column
synthetic minimization emitting bare `133;A` (F2). The real bytes were used to
diagnose and were not committed; F13 re-captures them.

So the consumer's behavior on a DanTerm-integrated pane is currently decided
entirely by whatever the user's own prompt framework emits: everything from
nothing at all (no blanking, stale prompts on resize) to a full mark set with a
redraw mode DanTerm never chose.

## Current hypotheses

### H1 -- REFUTED: fish repaints on SIGWINCH after all

Hypothesis was that fish must declare `redraw=0` because nothing repaints a
blanked fish prompt. **Refuted by F8.** fish 4.7.1 repaints its whole prompt on
SIGWINCH -- re-emitting `133;A` and `133;B` -- whenever `fish_handle_reflow` is
`1`. F6's zero-byte observation came from `fish -N`, which skips the config file
that installs the WINCH handler (F9). The prompt-width competing explanation was
independently ruled out: a 69-column prompt forced to 60 columns still emitted
nothing under `-N`, and a harness control (zsh through the identical resize path)
repainted normally, so the signal was always being delivered.

F8 measured this with a synthetic `DanTerm(1.0)` XTVERSION identity, which left
open whether the real one lands in the same branch. F12 confirms it does: fish
sees `DanTerm <bundle version>`, matches none of its alternatives, and auto-sets
`fish_handle_reflow 1`. The refutation holds on the shipping identity.

### H2 -- REFUTED: `fish_handle_reflow` is live in fish 4.7.1

Hypothesis was that the variable is a fish-3.x fossil. **Refuted by F9.** It is
shipped in `__fish_config_interactive.fish`, documented in `completions/set.fish`
("if fish should repaint prompt when the term resizes"), and gates a real
`--on-signal WINCH` handler that runs `commandline -f repaint`. F6 measured it as
unset for the same `-N` reason. Ghostty's `fish_handle_reflow 1` is the supported
lever, and it works by pre-setting the variable so fish's auto-detection skips.

### H3 -- SETTLED, then REOPENED and RE-SETTLED: fish needs `redraw=1`

Asked whether DanTerm should ask fish to repaint (`redraw=1`) or leave the
prompt alone (`redraw=0`).

The first answer was `redraw=0`, on F10 and F11: fish left-truncates an
over-wide prompt, so a fish prompt row never soft-wraps, so there is no
staircase for blanking to fix -- and F11 measured all three configurations as
observationally identical in a real pane.

**F13 refutes that.** F11's prompt was far narrower than the pane, so no row was
ever full width and nothing re-wrapped; it could not have observed the failure.
F10 is true but was over-applied: fish truncates at *draw* time, which says
nothing about a row already drawn at full width when the grid reflows beneath
it. A right-aligned segment padded to the terminal width -- Starship's default --
is exactly such a row. Replaying a real fish + Starship prompt through a
one-column-at-a-time sweep leaves 31 prompt copies in history and 10 on screen
under `redraw=0`, and exactly one under `redraw=1`.

So fish gets the same answer as zsh, for the same reason: it repaints its whole
prompt (F8, F12), so the whole block may be blanked. D3 now selects `redraw=1`.

## The dialect, in one paragraph

Recorded in full in [dialect.md](dialect.md): each shell
declares its own redraw mode on every prompt rather than inheriting the parser
default, because the mode is sticky per-pane and a nested foreign shell can leave
it wrong (F7). zsh declares `redraw=1` and marks continuation lines; Bash
declares `redraw=last` because readline repaints only the final prompt line (F4);
fish declares `redraw=1` and does not touch `fish_handle_reflow` (D3, settled by
F13 -- fish repaints its whole prompt, and a full-width fish prompt row does
re-wrap). No integration emits `D`, `L`, `I`, or `N`.

## Task ledger

### Phase 1 -- establish what exists

- [x] Enumerate the accepted grammar from the shipping parser by probe, not by
  reading. Recorded in F1.
- [x] Establish what the bundled scripts emit today and what the in-gate zsh
  capture contains. Recorded in F2.
- [x] Probe zsh, Bash, and fish for what they re-emit on SIGWINCH. Recorded in
  F3, F4, F5, F6.

### Phase 2 -- author the dialect

- [x] Decide the per-shell mark set and redraw mode against that evidence.
  Recorded in D1 (zsh), D2 (Bash), D3 (fish), D4 (what is not emitted).
  D3 was reopened by F8/F9 and re-decided by H3; all four now stand.
- [x] Check every authored mark against the parser end to end, including the
  degenerate cases the dialect must avoid. Recorded in F7.
- [x] RESEARCH: settle H1 with a wide prompt. Refuted -- fish does repaint;
  F6 was a `-N` artifact. Recorded in F8.
- [x] RESEARCH: settle H2 -- whether any fish 4.x lever forces a prompt repaint
  on SIGWINCH. Refuted -- `fish_handle_reflow` is that lever and is live.
  Recorded in F9.
- [x] RESEARCH: settle H3. First closed on `redraw=0` from a real-pane sweep
  (F10, F11), then **reopened and reversed**: F13 replayed a real fish + Starship
  prompt and reproduced the original staircase under `redraw=0`. D3 now selects
  `redraw=1`. F11's prompt was too narrow to expose it.
- [x] RESEARCH: confirm what XTVERSION identity DanTerm actually reports to
  fish. It is `DanTerm <bundle version>`, which matches none of fish's
  alternatives, so an unintegrated fish pane auto-sets `fish_handle_reflow 1`
  and repaints. F8's conclusion survives the switch from its synthetic identity
  to the real one. Recorded in F12.

### Phase 3 -- ship the emitters

- [ ] TODO: implement the dialect in `danterm.zsh`, `danterm.bash`, and
  `danterm.fish`, preserving the existing prompt hooks the integrations already
  promise not to disturb.
- [ ] TODO: cover the emitted dialect behaviorally -- a resize over each shell's
  authored byte stream leaves exactly one prompt, and a resize during command
  output leaves the output intact. `TerminalOSC133Tests` covers the parser side;
  the emitters need their own bytes replayed, plus a
  `scripts/tests/shell-integration_test.sh` check that each script actually
  emits them.
- [ ] TODO: promote F13's replay into a permanent test. The capture script is
  [capture-fish-sweep.py](capture-fish-sweep.py); commit one variant's events as
  a fixture and assert one prompt survives the sweep under the authored marks.
  This is the test that would have caught D3's two wrong versions automatically,
  and it is the fish half of the behavioral-coverage item above.
- [ ] TODO: fold the shipped dialect into `docs/terminal-capabilities.md` and
  `plan-terminal-engine/10-protocols-shell-integration.md`, which today record
  only the OSC 1337 envelope on the emitting side.

## Rejected

### Emitting `D;<status>` alongside the envelope's exit status

`D` is accepted by the parser, and both Ghostty and fish emit it with a status.
DanTerm will not: the parser treats `D` exactly like `C` apart from a row-stamp
clear that only `C` performs at column 0, so after a `C` has been emitted a
following `D` changes no parser state that the next `A` does not restore anyway
(F7). Its only other content -- the exit status -- is what slice 1 of the
semantic-model plan adds to `command-end` in the private envelope, which is the
authority the reducer actually reads. Emitting it in both places creates a second
status channel with no consumer. Reopen if a future consumer needs output-end
distinct from prompt-start.

### Using `A` inside Bash's `PS1`

`A` performs a fresh line (column != 0 -> CR + LF). readline redisplays `PS1`
mid-line on Ctrl-L and vi-mode switches, so an `A` in `PS1` would inject a
spurious newline on each. `P` sets the same row stamp with no fresh-line
behavior, which is why the dialect uses `A` once per prompt from the precmd hook
and `P;k=i` inside `PS1`. Ghostty's Bash integration reaches the same split for
the same stated reason.

### Emitting `L` to force a fresh line

`L` is accepted only bare: `133;L;` and `133;L;aid=x` are dropped whole (F1).
Nothing in the dialect needs a fresh line that `A` does not already provide, and
a mark whose only safe form is optionless is a trap for a future author who adds
an `aid=`.

## Open questions and caveats

- Config-disabled probing burned us once already: `fish -N` suppressed the very
  handler F6 concluded was missing, and two hypotheses were built on the artifact
  (F8, F9). The zsh and Bash findings (F3, F4) still rest on `zsh -f` and
  `bash --norc --noprofile` and have not been re-run with system config loaded.
  Neither shell keeps its resize behavior in a config file the way fish does, so
  the risk is lower -- but it is the same untested assumption.
- The shell probes ran with config disabled (`zsh -f`, `bash --norc --noprofile`,
  `fish -N`) and synthetic prompts. Real user frameworks (Powerlevel10k, Starship,
  Pure) rewrite `PS1` asynchronously and may strip injected marks; Ghostty's zsh
  integration carries substantial machinery to survive that. The dialect says
  what to emit, not yet how to survive a hostile prompt framework.
- A user's own framework may already emit OSC 133. Duplicate `A` marks on the
  same row are idempotent at column 0 (F7), but a framework that emits
  `A;redraw=0` and DanTerm's `A;redraw=1` on the same prompt leaves the mode
  decided by whichever lands last. Not yet probed.
- The redraw mode is per-pane parser state that survives the shell that set it,
  and is reset only by RIS (F7). The per-prompt restatement in D1-D3 is what
  makes a nested shell's mode recoverable; nothing else does.
- **`danterm pane read` cannot measure this.** It returns width-independent
  *logical* lines with `…` continuation markers, not physical grid rows -- an
  89-column pane returned a 196-character row. OSC 133 blanking operates on
  physical prompt rows, so the reader abstracts away exactly the thing under
  test. A real-pane probe must observe the rendered window (screen capture) or
  feed bytes to `TerminalCore.Terminal` and inspect the grid. Driving the pane
  over the control socket is fine; only the observation is unsuitable.
- **The probe environment changed on 2026-07-31, mid-investigation.** Until
  then the maintainer's `~/.zshrc` exec'd fish on line 3, so every probe of
  "the user's zsh" -- and every DanTerm pane -- was silently running fish under
  a zsh-shaped `$SHELL`. fish is now the account shell and the exec is gone, so
  `zsh -i` is a real zsh and panes launch fish directly. Any measurement in this
  doc dated before that, or in the originating plan, must be read with the
  substitution in mind; F3's zsh findings used `zsh -f` and are unaffected.
- Targeting the dev app means `DANTERM_SOCK=~/Library/Caches/com.danneu.danterm-dev/control.sock`.
  The CLI binary has no bundle identifier, so `controlSocketPath()` falls back to
  `com.danneu.danterm` -- an unguarded `danterm` drives the *production* app.
  Panes launched by the app export the right `DANTERM_SOCK` themselves
  (`TerminalLaunchEnvironment`), so this only bites when driving one app's pane
  from another app's shell, which is the normal case when probing.
- Only the fish question (F11) was observed in a real DanTerm pane. Every
  authored mark is checked against `TerminalCore.Terminal` directly, so the zsh
  and Bash dialects have never been rendered by the app that will consume them.

## Outcome

Dialect authored, parser-checked, and settled: D1 (zsh), D2 (Bash), D3 (fish),
D4 (what is not emitted) all stand, and every hypothesis is closed.

D3 was decided three times and is the cautionary tale of this doc. It chose
`redraw=0` twice -- first on H1/H2, which F8/F9 refuted, then on F10/F11, which
F13 refuted -- before landing on `redraw=1`. Each wrong version was internally
consistent with the evidence available; what broke both was a probe whose
stimulus could not exhibit the failure. F11 in particular ran in a real pane,
in both resize directions, against a do-nothing control, and still measured
nothing, because its prompt was narrower than the pane. **A null result is only
as strong as the stimulus that produced it**, and this doc's investigation rules
did not require a probe to argue that its stimulus could have shown the effect.

The net finding for fish is the opposite of what this section said for most of
the doc's life: fish is the shell where the protocol matters most for the
maintainer, because it is the shell the original incident occurred in.

Phase 2 is closed: its last open item -- which XTVERSION identity fish actually
sees -- resolved to `DanTerm <bundle version>`, which matches none of fish's
special cases, so an unintegrated fish pane repaints (F12). The answer changes
no decision; it confirms F8 was not an artifact of its synthetic identity.

Remaining work is Phase 3 -- writing the emitters -- which is now unblocked for
all three shells. The one design question R1 deliberately did not answer is
waiting there: D1 puts marks inside zsh's `PS1`, and a prompt framework that
rebuilds `PS1` asynchronously can strip them. Decide that before writing the
zsh emitter, not during.
