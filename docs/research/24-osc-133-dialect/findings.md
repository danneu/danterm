# Findings

Evidence for the OSC 133 dialect. Parser probes feed
`TerminalCore.Terminal` directly; shell probes drive a real shell binary over a
`pty.fork()` PTY.

### F1 -- the grammar the shipping parser accepts

- Status: settled.
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `3b9707e`, working tree dirty in unrelated plan
  files; `lib/TerminalCore` clean.
- Commands, inputs, or reproduction: read `Terminal.dispatchOSC133` and
  `clearPromptForResizeIfNeeded`, then confirmed each rule by feed (see F7).
- Observation:
  - Accepted actions are `A B C D I L N P`. Any other first byte applies nothing.
  - After the action byte the payload must end, or the next byte must be `;`.
    `133;Aextra` and `133;Z` apply nothing atomically.
  - `L` is the exception: it takes no options at all. `133;L` is accepted;
    `133;L;` and `133;L;aid=x` are dropped whole.
  - Options are `;`-separated `key=value` fields. Only two keys are read: `k`
    (`c` or `s` -> continuation row; anything else, including `i` -> prompt row)
    and `redraw` (`0` -> disabled, `1` -> full, `last` -> last row; any other
    value leaves the current mode). Unknown keys and valueless fields are
    ignored, never fatal.
  - `redraw` is read on `A` and `N` only. It is per-terminal state, not
    per-mark, and persists until another `A`/`N` restates it or RIS resets it to
    `full`.
  - `A`/`N` perform a fresh line (if column != 0: CR then LF) and stamp the
    cursor row. `P` stamps without the fresh line. `B` starts input; `I` starts
    input that clears at end of line; `C` and `D` start output, and `C` at
    column 0 additionally clears that row's prompt stamp.
  - On primary-screen resize, blanking is skipped entirely while content is
    `output`, or when the mode is `disabled`. In `last` mode only the cursor row
    is blanked. In `full` mode the parser walks up from the cursor row through
    `continuation` *and* unstamped rows until it finds a `prompt` row, then
    blanks from there to the bottom of the screen; if it finds none, it blanks
    nothing.
- Inference: the dialect's only mandatory mark is one `prompt`-stamped row --
  without it, `full` mode blanks nothing. Continuation stamps are not required
  for the walk to reach the top of a multi-line prompt, because the walk passes
  through unstamped rows too.
- Uncertainty: none for the parser. The reflow packer also reads the row stamps
  (`Terminal.swift`, the soft-wrap merge and packed-row paths); those were not
  probed and are not part of what the dialect chooses.
- Next action: F7 checks the authored marks against these rules end to end.

### F2 -- DanTerm's own scripts emit no OSC 133 today

- Status: settled.
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `3b9707e`.
- Commands, inputs, or reproduction: `grep -rn "133"` across `*.swift`, `*.sh`,
  `*.zsh`, `*.bash`, `*.fish`, `*.md`, excluding `.ghostty-src/`, `references/`,
  `.build/`; plus a full read of the three bundled integrations.
- Observation: `integrations/shell-integration/danterm.{zsh,bash,fish}` emit
  exactly two things -- the private `OSC 1337;DanTermShell=1;<event>` envelope
  (`command-start`, `command-end`, `remote-start`, `remote-host`) and `OSC 7`
  cwd. No OSC 133 byte sequence exists outside `Terminal.swift`, its tests, the
  in-gate fixture, and prose. The fixture
  `Fixtures/danterm/zsh-osc133-width-sweep.json` contains only bare
  `ESC ] 133 ; A BEL` and `ESC ] 133 ; B BEL`, captured from a real user zsh, not
  from a DanTerm script.
- Inference: prompt-redraw behavior in a DanTerm pane is currently decided by the
  user's prompt framework. With no marks at all the engine blanks nothing on
  resize, which is the stale-prompt behavior the OSC 133 work was built to fix --
  so today the fix is reachable only by accident of the user's config.
- Competing interpretations: none; this is a direct enumeration.
- Next action: authored in D1-D3.

### F3 -- zsh re-emits PS1, and therefore embedded marks, on every SIGWINCH

- Status: settled.
- Date and investigator: 2026-07-31, R1.
- Commands, inputs, or reproduction: `zsh -f -i` under `pty.fork()`, TERM
  `xterm-256color`, `PS1=$'%{\e]133;A;redraw=1\a%}ZZMARKZZ%{\e]133;B\a%}'`, then
  two `TIOCSWINSZ` resizes (80 -> 60 -> 70 columns) with no input in between.
- Measurements or examples: bytes emitted after the resizes, verbatim:

  ```
  \r\r\x1b[0m\x1b[27m\x1b[24m\x1b[J\x1b]133;A;redraw=1\x07ZZMARKZZ\x1b]133;B\x07
  ```

  once per resize -- marker count 2 for 2 resizes, 4 OSC 133 marks total.
- Observation: zsh repaints the entire prompt on SIGWINCH and re-emits every mark
  embedded in `PS1`.
- Inference: for zsh, marks belong inside `PS1`/`PS2` (wrapped in `%{...%}` so
  they carry zero print width), and a `redraw=` option placed there is restated
  on every repaint at no cost -- which is what makes the sticky mode (F7)
  self-correcting.
- Uncertainty: `zsh -f` loads no user config. A framework that rebuilds `PS1`
  asynchronously can strip the marks; not probed.
- Next action: D1.

### F4 -- readline repaints only the last line of a multi-line Bash prompt

- Status: settled.
- Date and investigator: 2026-07-31, R1.
- Commands, inputs, or reproduction: `bash --norc --noprofile -i` under
  `pty.fork()`, single-line `PS1` first, then
  `PS1='\[\e]133;P;k=i\a\]TOPMARK\n\[\e]133;P;k=s\a\]$ \[\e]133;B\a\]'`, then a
  `TIOCSWINSZ` resize with no input.
- Measurements or examples: the single-line prompt repainted whole:

  ```
  \r\x1b[K\r\x1b]133;P;k=i\x07ZZMARKZZ\x1b]133;B\x07
  ```

  The two-line prompt repainted only its final line -- `TOPMARK` was not
  re-emitted:

  ```
  \r\x1b[K\r\x1b]133;P;k=s\x07$ \x1b]133;B\x07
  ```

- Observation: readline's SIGWINCH redisplay covers the last prompt line only.
- Inference: `redraw=full` is wrong for Bash. Blanking from the `prompt`-stamped
  row down would erase `TOPMARK`, and nothing would ever repaint it. `redraw=last`
  blanks exactly the row readline is about to rewrite. This is a measured
  behavior, not an assumption inherited from Ghostty's integration, which reaches
  the same setting.
- Uncertainty: `--norc --noprofile`; bash 3.2 ships with macOS while Homebrew
  bash is 5.x. The probe used the shell on PATH and did not compare versions.
- Next action: D2.

### F5 -- fish 4.7.1 emits the full OSC 133 mark set natively

- Status: settled.
- Date and investigator: 2026-07-31, R1.
- Commands, inputs, or reproduction: `fish -N -i -C '<prompt function>'` under
  `pty.fork()`, answering the startup capability probes (OSC 11, XTVERSION, CPR,
  DA1, Kitty keyboard) the way DanTerm would, since fish 4.7.1 blocks on them
  before drawing a prompt.
- Measurements or examples: prompt draw and one command, verbatim excerpts:

  ```
  \x1b]133;A;click_events=1\x1b\\ZZTOPZZ\r\nZZBOTZZ> \x1b]133;B\x07
  \x1b]133;C;cmdline_url=echo%20RF%3D%24fish_handle_reflow\x07
  \x1b]133;D;0\x07
  ```

- Observation: fish emits `A` (with `click_events=1` and an ST terminator), `B`,
  `C` (with a `cmdline_url` option), and `D;<status>` with no integration
  loaded. Every one of these parses under F1's rules: unknown options are
  ignored, `C;<opts>` is a valid action-plus-options form, and ST is equivalent
  to BEL.
- Inference: a DanTerm fish integration must not emit `A`/`B`/`C`/`D` -- fish
  already does, and a pane running fish is therefore already in the parser's
  default `full` redraw mode without anyone choosing it. The only thing DanTerm
  has to contribute for fish is the `redraw=` declaration.
- Competing interpretations: fish 3.x may not emit these; the probe covers 4.7.1
  only. The dialect's fish entry should tolerate their absence, which it does --
  it adds a mode declaration, not a dependency on fish's marks.
- Next action: F6, then D3.

### F6 -- fish 4.7.1 emitted nothing at all on SIGWINCH, and has no `fish_handle_reflow`

- Status: **superseded by F8 and F9.** The observation stands only for `fish -N`;
  both inferences drawn from it are wrong, because `-N` (`--no-config`) skips
  `__fish_config_interactive.fish`, the file that installs fish's WINCH handler
  and sets `fish_handle_reflow`. Retained for the audit trail; do not cite it.
- Date and investigator: 2026-07-31, R1.
- Commands, inputs, or reproduction: the F5 harness, with a two-line synthetic
  prompt (`ZZTOPZZ` / `ZZBOTZZ> `), resized 80 -> 60 -> 70 columns with no input.
  Run twice: once as-is, once with `set -g fish_handle_reflow 1` at startup.
  Separately: `fish -N -c 'echo "[$fish_handle_reflow]"; set -S fish_handle_reflow'`
  and a grep for `handle_reflow` across the installed fish share tree.
- Measurements or examples: both resizes produced zero bytes in both runs.
  `$fish_handle_reflow` printed `[]` and `set -S` reported nothing -- the
  variable is unset and appears in no shipped share file.
- Observation: fish did not repaint its prompt on SIGWINCH, and the variable
  Ghostty's integration sets to request that behavior does not exist in 4.7.1.
  The same harness and the same `TIOCSWINSZ` call did produce repaints from zsh
  (F3) and Bash (F4), so the signal was delivered.
- Inference: if DanTerm leaves fish in `full` mode, a resize blanks the prompt
  block and nothing rewrites it -- strictly worse than emitting no marks at all.
- Competing interpretations: fish may skip a repaint it judges unnecessary; the
  probe's prompt was 9 columns wide and never needed to rewrap. This is exactly
  what H1 must settle before the fish emitter ships.
- Uncertainty: high on the *why*, low on the *what*. The observation is
  reproducible; its cause is not established.
- Next action: H1's task in the Phase 2 ledger.

### F7 -- the authored dialect, checked end to end against the parser

- Status: settled.
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `3b9707e`, probe run against `lib/TerminalCore`.
- Commands, inputs, or reproduction: a scratch Swift Testing suite added to
  `lib/TerminalCore/Tests/TerminalCoreTests/`, run with
  `swift test --package-path lib/TerminalCore --filter ScratchDialectProbe`, then
  deleted. It fed each shell's authored byte stream to a `Terminal`, resized, and
  asserted the resulting grid. Six cases, all passing:
  1. **zsh** -- `A;redraw=1` + `PROMPT-TOP` + `A;k=s` + `> ` + `B`, then four
     resize-and-repaint cycles at widths 11, 10, 11, 12. `PROMPT-TOP` appears
     exactly once in full history: no staircase.
  2. **Bash** -- `A;redraw=last` + `P;k=i` + `TOPLINE` + newline + `P;k=s` +
     `$ ` + `B`, then one resize. Screen after:
     `"TOPLINE       \n              \n..."` -- the top line survives, only the
     cursor row is blanked.
  3. **fish under `full`** -- `A;redraw=1` + a three-row prompt whose middle and
     last rows carry no stamp, then one resize. Every row blanked, including the
     unstamped ones: the upward walk passes through unstamped rows (F1) and
     blanks from the stamped row down.
  4. **Output phase** -- `A` + prompt + `B` + `cmd` + `C` + `OUTPUT`, then a
     resize. Both the prompt and `OUTPUT` survive: `C` suppresses blanking for
     the whole command.
  5. **Sticky mode** -- `A;redraw=last`, then a later `A` with no `redraw`
     option: the later prompt still blanks only its cursor row, so a nested
     shell's mode outlives it. Restating `A;redraw=1` on the next prompt restores
     full-block blanking.
  6. **Grammar edges** -- bare `133;L` advanced the cursor row, `133;L;aid=1` did
     not (dropped whole). `A;aid=9;cl=line` + `C;` produced a terminal exactly
     equal to canonical `A` + `C`: unknown options and the trailing-semicolon
     action form are inert. An ST-terminated stream equalled the BEL-terminated
     one byte for byte.
- Inference: every mark the dialect authors is accepted, and every degenerate
  form it avoids is confirmed harmful or inert for the stated reason. Case 3 also
  shows why fish's mode declaration is the whole decision for fish: with fish's
  native `A` and no declaration, a multi-row prompt is fully blanked.
- Uncertainty: the probe replays authored bytes, not bytes captured from a shell
  running the emitters -- those do not exist yet. The Phase 3 ledger task closes
  that gap.
- Next action: D1-D4, then the emitters.

### F8 -- fish 4.7.1 does repaint on SIGWINCH; F6 disabled the machinery it was testing

- Status: settled. Refutes H1 and supersedes F6's inference.
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `3b9707e`, `lib/TerminalCore` clean.
- Commands, inputs, or reproduction: the F5/F6 harness, extended. Three steps:
  1. A harness control -- `zsh -f -i` with the F3 `PS1`, driven through the same
     `set_size`/`drain` path, repainted on both resizes. The harness delivers
     SIGWINCH and captures the result.
  2. Widened the fish prompt to 69 columns (`P`*62 + `ZZEND> `) so that 80 -> 60
     *forces* a rewrap, and separately typed a 95-column command line so the
     input wrapped. Under `fish -N` both still produced zero bytes across
     80 -> 60 -> 70 -> 100.
  3. Dropped `-N` and ran `fish -i` with `XDG_CONFIG_HOME`/`XDG_DATA_HOME`
     pointed at an empty directory (system config loads, no user config).
- Measurements or examples: with config loaded, the 80 -> 60 resize emitted a
  full prompt repaint, marks included:

  ```
  \x1b[?2004l\x1b[?2031l\x1b[=0u\x1b]0;...\x07\x1b[m\x1b[?2004h\x1b[?2031h\x1b[=5u
  \r\r\x1b]133;A;click_events=1\x07PPPP...ZZEND> \x1b]133;B\x07\r\n\x1b[J
  ```

  A three-way split isolated the cause exactly:

  | run | `fish_handle_reflow` | bytes on resize |
  | --- | --- | --- |
  | config loaded, DanTerm XTVERSION | `1` | full prompt repaint |
  | config loaded, `set -g fish_handle_reflow 0` | `0` | none |
  | config loaded, `TERM=alacritty` | `0` | none |

  Read back from inside a `fish_prompt` handler: `rf=[1] term=[ DanTerm(1.0) ]`
  for the default case, `rf=[0]` under `TERM=alacritty`.
- Observation: fish repaints its whole prompt on SIGWINCH -- re-emitting `133;A`
  and `133;B` -- exactly when `fish_handle_reflow` is `1`, and emits nothing when
  it is `0`. Under a DanTerm-like terminal identity, fish auto-detects `1`.
- Inference: H1 is refuted, and F6's inference ("if DanTerm leaves fish in `full`
  mode, a resize blanks the prompt block and nothing rewrites it") is wrong.
  F6 ran `fish -N`, i.e. `--no-config`, which skips
  `__fish_config_interactive.fish` -- the file that both computes
  `fish_handle_reflow` and installs the WINCH handler (F9). The probe disabled
  the exact machinery it concluded was absent. The prompt width was never the
  variable; step 2 rules it out independently.
- Competing interpretations: none for the mechanism -- the three-way split tracks
  `fish_handle_reflow` with no residual. What remains open is which value DanTerm
  should *want*, which is a design question, not an observation (H3).
- Uncertainty: the terminal identity fish sees here is the harness's synthetic
  `DanTerm(1.0)` XTVERSION reply, not whatever DanTerm actually reports. If
  DanTerm's real reply ever began `VTE`, `Konsole `, or `WezTerm `, or if `TERM`
  were set to `alacritty*`, fish would auto-detect `0` instead (F9). Not verified
  against the shipping DanTerm.
- Next action: D3 reopens; H3 decides the value.

### F9 -- `fish_handle_reflow` exists in fish 4.7.1 and is the repaint lever

- Status: settled. Refutes H2.
- Date and investigator: 2026-07-31, R1.
- Commands, inputs, or reproduction: `grep -rn handle_reflow` across the
  installed fish share tree (`.../fish-4.7.1/share/fish`), then a read of
  `share/fish/functions/__fish_config_interactive.fish`. Now citable in the
  pinned checkout instead: `references/fish-shell/` at fish 4.7.1, whose
  `share/functions/__fish_config_interactive.fish#__fish_config_interactive` was
  verified byte-identical to the installed copy quoted below.
- Measurements or examples: the variable appears in `completions/set.fish`
  ("if fish should repaint prompt when the term resizes"), in the man pages, and
  live in `__fish_config_interactive.fish#__fish_config_interactive`, which ends
  with:

  ```fish
  function __fish_winch_handler --on-signal WINCH -d "Repaint screen when window changes size"
      if test "$fish_handle_reflow" = 1 2>/dev/null
          commandline -f repaint >/dev/null 2>/dev/null
      end
  end
  ```

  Immediately above it, the auto-detection: `fish_handle_reflow` is set to `0`
  when `status terminal` matches `^(?:VTE\b|Konsole |WezTerm )`, when
  `KONSOLE_VERSION >= 210400`, or when `TERM` matches `alacritty*` -- and to `1`
  otherwise. It is only computed `if not set -q fish_handle_reflow`, so a value
  set before interactive config wins.
- Observation: the variable is live in 4.7.1, user-overridable, and gates a real
  `--on-signal WINCH` handler that issues `commandline -f repaint`.
- Inference: H2 is refuted. Ghostty's `fish_handle_reflow 1` is not a fish-3.x
  fossil; it is the supported lever, and it works by pre-setting the variable so
  the auto-detection skips. F6's "the variable is unset and appears in no shipped
  share file" was measured under `-N`, where the file that sets it never runs;
  the grep that missed it searched an incomplete tree.
- Competing interpretations: none. This is a direct read of shipped source
  corroborated by the F8 behavior split.
- Uncertainty: fish's own comment states the intent of the `0` branch --
  "Detect whether the terminal reflows on its own. If it does we shouldn't do it
  ... us doing it inevitably races against it." Whether DanTerm belongs in that
  category is H3, and it is not answered here.
- Next action: H3.

### F10 -- fish left-truncates its own prompt to fit the width; a fish prompt never soft-wraps

- Status: settled.
- Date and investigator: 2026-07-31, R1.
- Commands, inputs, or reproduction: a fixed 41-column prompt
  (`HEAD` + 34 `=` + `> `) drawn by `fish -i` under `pty.fork()` at two widths,
  plus the same `printf` run as an ordinary command as a control.
- Measurements or examples:

  | context | width | emitted |
  | --- | --- | --- |
  | `printf "WIDE%s> "` as a command | 80 | `WIDE====...>` -- intact |
  | 41-col prompt | 80 | `HEAD==================================> ` -- intact |
  | 41-col prompt | 30 | `===========================> ` -- **head gone**, 29 cols |

- Observation: when a prompt exceeds the terminal width, fish drops characters
  from the *front* until it fits on one row. The same bytes printed as ordinary
  output are untouched, so this is fish's prompt-rendering path, not `printf`.
- Inference: two consequences for this research.
  1. **A fish prompt is always <= one row wide.** Multi-row fish prompt blocks
     arise only from explicit newlines, never from soft wrap. The `full`-mode
     upward walk (F1) therefore only ever traverses explicitly multi-line fish
     prompts.
  2. **It retroactively explains the unattributed dev-app anomaly.** A real-pane
     branch-(a) run used a 94-column prompt in an 89-column pane; its `ZZP`
     marker was absent from the rendered window. That loss happened inside fish
     before DanTerm saw the bytes. It is not evidence of a blanking or reflow
     defect, and must not be counted against `redraw=1`.
- Competing interpretations: none for the truncation itself -- the command-vs-prompt
  control isolates it to fish's prompt path.
- Uncertainty: the leading `…` glyph observed on those dev-app rows is *not*
  explained by this finding; fish emitted no ellipsis at any width. That glyph is
  DanTerm-side rendering and is still unexplained. It is cosmetic to H3 but
  should not be assumed benign.
- Next action: H3's probe must use explicitly multi-row prompts (or a wrapped
  *command line*), never an over-wide prompt.

### F11 -- the redraw declaration makes no observable difference for fish

- Status: settled.
- Date and investigator: 2026-07-31, R1 (manual, in DanTerm Dev.app).
- Commit and worktree state: dev build of the working tree, 2026-07-31 14:34.
- Commands, inputs, or reproduction: three tabs of one Dev.app window, each
  running fish 4.7.1 via a fixture that varies only the two H3 variables:

  | tab | `fish_handle_reflow` | DanTerm declares |
  | --- | --- | --- |
  | 1 | `1` | `A;redraw=1` (branch a) |
  | 2 | `0` | `A;redraw=0` (branch b) |
  | 3 | `1` | nothing -- fish's native marks only, parser default `full` |

  Prompt was three explicit rows (`TOP1`/`MID2`/`BOT3> `). Each tab ran
  `string repeat -n 300 x` several times to fill the screen with content that
  re-wraps at every width, then the window was drag-resized slowly, both
  narrow -> wide and wide -> narrow, ending at widths not previously visited.
  Observed by screen capture; `danterm pane read` is unusable here (see README).
- Measurements or examples: all three tabs ended byte-identical in layout --
  each prompt block intact and appearing exactly once per command, all command
  output preserved, no duplicated or partially-erased prompt anywhere.
- Observation: the `redraw` declaration changed nothing observable for fish, in
  either direction, at any width, including against the do-nothing control.
- Inference: this is what F10 predicts. Fish left-truncates its prompt to fit, so
  a fish prompt row never soft-wraps; a row that never wraps never *re*-wraps on
  resize; so a width change cannot produce the stale-prompt staircase that
  prompt-blanking exists to fix. Blanking has nothing to act on. Tab 2 adds the
  converse: with fish emitting nothing on resize, DanTerm's own reflow left the
  prompt correct unaided.
  This also explains why zsh needed the feature and fish does not -- zsh does not
  truncate, so a wide zsh prompt genuinely wraps, re-wraps, and staircases.
- Competing interpretations: none that survive the control. Tab 3 is today's
  shipping behavior and is indistinguishable from both authored branches.
- Uncertainty: equality of *end state* does not prove blanking never fired in
  tab 1 -- a blank immediately repainted over is invisible. So branch (a) is
  shown unnecessary, not shown harmful. A pathological case (resize mid-output,
  wrapped pending input) was not exercised.
- Next action: D3.

### F12 -- DanTerm's real XTVERSION identity puts fish in the repainting branch

- Status: settled.
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `c2ec7a4`, working tree clean of engine changes.
- Result or artifact paths: [xtversion-probe.py](xtversion-probe.py), promoted
  out of the scratchpad so this finding stays reproducible.
- Commands, inputs, or reproduction: that script -- interactive
  fish 4.7.1 (`fish -i`, config loaded; **not** `-N`, the F6 artifact) over a
  `pty.fork()` PTY with `XDG_CONFIG_HOME` pointed at a nonexistent directory and
  `VTE_VERSION`/`KONSOLE_VERSION` cleared. The harness answers fish's startup
  handshake with a caller-chosen XTVERSION reply, then asks fish itself:
  `echo "ZZ|$(status terminal)|$fish_handle_reflow|ZZ"`.
  DanTerm's real reply string was read from the engine, not invented:
  `Terminal.swift#dispatchCSI` emits `DCS >|DanTerm <programVersion> ST`, and
  `SwiftTerminalBackend.swift#launchFacts` injects `CFBundleShortVersionString`
  (falling back to `dev`), so the wire form is `DanTerm 0.1.0`.
- Measurements or examples:

  | XTVERSION reply | `TERM` | `status terminal` | `fish_handle_reflow` |
  | --- | --- | --- | --- |
  | `DanTerm 0.1.0` (real) | `xterm-256color` | `DanTerm 0.1.0` | `1` |
  | `DanTerm(1.0)` (F8's synthetic) | `xterm-256color` | `DanTerm(1.0)` | `1` |
  | none | `xterm-256color` | `` (empty) | `1` |
  | `WezTerm 20240203` (control) | `xterm-256color` | `WezTerm 20240203` | `0` |
  | `DanTerm 0.1.0` (control) | `alacritty` | `DanTerm 0.1.0` | `0` |
- Observation: fish reports `status terminal` as the XTVERSION payload verbatim.
  DanTerm's identity matches none of the `^(?:VTE\b|Konsole |WezTerm )`
  alternatives in `__fish_config_interactive.fish` (F9), so auto-detection takes
  the `else` branch and sets `fish_handle_reflow 1`.
- Inference: an unintegrated fish pane in DanTerm repaints its whole prompt on
  SIGWINCH. F8's conclusion holds on the real identity, not just the synthetic
  one it was measured with -- the open question that motivated this probe is
  closed with the same answer.
- Competing interpretations: none the controls leave open. Both control rows flip
  the variable to `0` -- one through the terminal-name regex, one through the
  `$TERM` check -- so the detection is live and the DanTerm rows are genuine
  misses rather than a dead code path.
- Uncertainty: `0.1.0` is whatever the dev bundle carries today. Nothing in
  fish's detection is version-sensitive, and the empty-reply row shows even a
  total absence of XTVERSION lands in the same branch, so no plausible version
  string changes this. Renaming the terminal to start with `VTE`, `Konsole `, or
  `WezTerm ` would -- a constraint worth remembering, not one worth guarding.
- Next action: none. D3 stands unchanged; the ledger item is closed.

### F13 -- `redraw=0` reproduces the original staircase in a real fish prompt

- Status: settled. **Refutes the inference F11 drew, and reopens D3.**
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `c4434ff`, scratch replay harness deleted after use.
- Result or artifact paths: [capture-fish-sweep.py](capture-fish-sweep.py),
  promoted out of the scratchpad so this finding stays reproducible. It writes
  the capture plus the three replay variants and documents the expected counts.
  The replay side was a throwaway `TerminalCore` test (feed events in order,
  count the `repo:` token in `fullHistoryText`); making it permanent is a Phase
  3 ledger item.
- Commands, inputs, or reproduction: two stages.
  1. Capture: real interactive fish 4.7.1 with the user's own config (Starship
     prompt, two rows, right-aligned segment) in a `pty.fork()` PTY, cwd set to
     this repo so the prompt renders its real content. Gradual one-column shrink
     from 100 to 70 columns, draining fish's repaint after each step -- the
     stimulus a split open/close produces (one resize per AppKit layout pass).
  2. Replay: the captured bytes and resizes fed to `TerminalCore.Terminal` in
     three variants, differing only in the option appended to fish's own `A`.
- Measurements or examples: occurrences of the prompt's `repo:` token after the
  sweep.

  | variant | in full history | on screen | result |
  | --- | --- | --- | --- |
  | as captured (fish's marks, parser default `full`) | 1 | 1 | clean |
  | `A;click_events=1;redraw=1` | 1 | 1 | clean |
  | `A;click_events=1;redraw=0` | 31 | 10 | **staircase** |

  The `redraw=0` screen is the incident verbatim: ten stale prompt copies, each
  shifted one further column, the live prompt driven to the last row.
- Observation: fish repainted on **all 30** resize steps, re-emitting
  `133;A;click_events=1` and `133;B` every time (0 steps produced no bytes),
  which independently reconfirms F8/F12 on the user's real configuration.
  Prompt blanking is what keeps that repaint from stranding its predecessor.
- Inference: **D3's selected value is wrong.** `redraw=0` would ship the exact
  defect the OSC 133 consumer exists to fix, in the maintainer's daily
  configuration. Today's unmarked behavior is already correct because the parser
  default is `full`.
- Competing interpretations: none survive the two clean variants. The only
  difference between the staircase and the clean runs is the `redraw` option;
  bytes, widths, and order are byte-identical.
- Uncertainty: why F11 saw no difference is now explained, not mysterious -- its
  prompt (`TOP1`/`MID2`/`BOT3> `) was far narrower than the pane, so no row was
  ever full-width and nothing re-wrapped. F10 stands as written but its
  inference was over-generalized: fish truncates at **draw** time, which says
  nothing about a row already drawn at full width when the grid reflows beneath
  it. A right-aligned segment padded to the terminal width -- Starship's default,
  and common in fish prompts -- produces exactly such a row.
- Next action: reopen D3 and re-decide between `redraw=1` and emitting nothing.

### F14 -- a prompt framework decides whether zsh's marks exist at all, and the mechanism is source order, not asynchronous rebuilding

- Status: settled. **Amends D1's emitter mechanism; changes no selected mark or
  redraw value.**
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `3cb5472`, scratch `TerminalCore` test deleted
  after use (its case table is reproduced below).
- Result or artifact paths:
  [probe-zsh-prompt-frameworks.py](probe-zsh-prompt-frameworks.py), promoted out
  of the scratchpad so this finding stays reproducible. Three stages (`native`,
  `order`, `hostile`) and the expected numbers are documented in its docstring.
- Commands, inputs, or reproduction: real zsh 5.9.1 under `pty.fork()`, four
  stages.
  1. `native`: the maintainer's own `~/.zshrc` (Starship 1.25.1, atuin, fzf,
     zoxide, direnv) with DanTerm's env triggers stripped.
  2. `order`: a synthetic `ZDOTDIR` that sources the "integration" **before** the
     framework's init -- the order the real `~/.zshrc` uses, where the DanTerm
     block sits well above the `starship init zsh` line -- crossed with three
     emitter strategies and with the framework present or absent.
  3. `hostile`: a synthetic framework that rebuilds `PS1` on every precmd, with
     its hook registered before and after the emitter's.
  4. Parser: the two-`A` conflict fed to `TerminalCore.Terminal` directly, over a
     20 -> 12 column sweep with a full-width first prompt row.
- Measurements or examples:

  Stage 1. Real zsh + Starship emits **no OSC 133 at all** -- unlike fish, which
  emits the full set natively (F5). Its SIGWINCH repaint covers the whole
  two-row prompt (`\r\r\x1b[A ... \x1b[J`), and the first row is padded to the
  full width by a right-aligned segment:

  ```
  \r\r\x1b[A\x1b[0m\x1b[27m\x1b[24m\x1b[J\x1b[90m╭\x1b[0m \x1b[90mrepo:...
      \x1b[1;30m<38 spaces>\x1b[0m\x1b[90mk8s:\x1b[1;34morbstack\x1b[0m\r\n...
  ```

  Stage 2, marks reaching the terminal (`startup` / per prompt cycle / SIGWINCH):

  | emitter | framework | startup | per cycle | SIGWINCH | user prompt |
  | --- | --- | --- | --- | --- | --- |
  | `ps1-assign` (D1 as written) | none | 2 | 2,2,2,2 | 2 | n/a |
  | `ps1-assign` | starship | **0** | 0,0,0,0 | **0** | intact |
  | `precmd-naive` | none | 2 | **4,6,8,10** | 10 | n/a |
  | `precmd-naive` | starship | 2 | **4,6,8,10** | 10 | intact |
  | `precmd-guarded` | none | 2 | 2,2,2,2 | 2 | n/a |
  | `precmd-guarded` | starship | 2 | 2,2,2,2 | 2 | intact |

  `precmd-naive` also renders its marker text once per accumulated wrap, so the
  duplication is visible in the prompt, not just on the wire.

  Stage 3, against a framework that rebuilds `PS1` every precmd:

  | hook order | marks per cycle | on SIGWINCH |
  | --- | --- | --- |
  | framework's hook, then ours | 2,2,2,2 | 2 |
  | ours, then the framework's | **0,0,0,0** | **0** |

  Stage 4, parser. Prompt copies surviving the sweep; **1 is clean, 9 is the
  staircase**, and both outcomes are exhibited, so the nulls are meaningful:

  | opener on the prompt | in history | on screen |
  | --- | --- | --- |
  | `A;redraw=1` alone | 1 | 1 |
  | `A;redraw=0` alone | 9 | 3 |
  | `A;redraw=1` then `A;redraw=0` | 9 | 3 |
  | `A;redraw=0` then `A;redraw=1` | 1 | 1 |
  | `A;redraw=1` then bare `A` | 1 | 1 |
  | bare `A` then `A;redraw=1` | 1 | 1 |
  | `A;redraw=1` twice | 1 | 1 |
  | `A;click_events=1` then `A;redraw=1` | 1 | 1 |
  | `A;redraw=1` then `A;click_events=1` | 1 | 1 |

  Separately, a nested shell's `redraw=0` inherited by a later bare `A` across a
  command produced 9 copies -- D0's failure mode, measured as a staircase rather
  than argued from F7 case 5.
- Observation: for zsh the marks' existence is decided by **assignment order**,
  not by asynchronous rebuilding. Starship-zsh assigns `PROMPT` exactly once, at
  init (`starship init zsh --print-full-init` sets `PROMPT`, `RPROMPT`, and
  `PROMPT2` under `setopt promptsubst`, and its `prompt_starship_precmd` collects
  only status/duration/jobs). It never rewrites `PS1` afterwards. So a `PS1=`
  assignment at source time is not *stripped* by an async rebuild -- it is
  overwritten wholesale by the framework's own init, which in a real `~/.zshrc`
  runs later. Running the assignment the other way round is worse: it clobbers
  the user's prompt entirely.
- Inference: D1's selected marks and `redraw=1` all stand -- stage 4 confirms
  DanTerm's declaration survives every optionless neighbor, in either order, and
  stage 1 confirms zsh's real prompt has the full-width re-wrapping row that
  makes `redraw=1` necessary. What does not stand is D1's mechanism as phrased.
  A source-time `PS1=` assignment is silently a no-op under the maintainer's own
  configuration. The emitter must wrap `PS1` from a `precmd` hook, and that hook
  must be idempotent -- keeping a pristine copy and rebuilding from it, because
  the obvious "wrap whatever `PS1` is now" grows two marks and one visible
  marker per prompt, forever.
- Competing interpretations: that the `ps1-assign` zero is a probe artifact of
  the synthetic `ZDOTDIR` rather than of source order. Ruled out by the
  framework=none row of the same table: the identical rc file, minus the
  `starship init` line, yields 2 marks on every cycle. The only difference is the
  framework's later assignment. That the parser rows are a false null is ruled
  out by the two exhibited outcomes (1 vs 9) in the same sweep.
- Uncertainty: the `hostile` framework is synthetic. Powerlevel10k is not
  installed here and was not measured; it is the real-world instance of the
  rebuild-every-precmd shape, and its instant-prompt path may differ again. The
  guarded emitter is also only proven against hooks registered *before* it --
  when the framework's hook runs last, DanTerm loses completely and silently
  (0 marks, no diagnostic), and nothing in the dialect detects that. Bash's
  `PROMPT_COMMAND` has the same ordering hazard and was not probed.
- Next action: amend D1 with the mechanism; carry the hook-ordering hazard into
  Phase 3 as an emitter requirement, not a dialect change.

### F15 -- the hook-order hazard is defensible in zsh and only half-defensible in Bash

- Status: settled. **Closes F14's open hazard for zsh; adds a Bash requirement
  D2 did not state.**
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `2f13e0b`, scratch `TerminalCore` test deleted
  after use (its case table is reproduced below).
- Result or artifact paths: [probe-hook-order.py](probe-hook-order.py), two
  stages (`zsh-defense`, `bash-order`), expected numbers in its docstring.
- Commands, inputs, or reproduction: real zsh 5.9.1 and Bash 5.3.9 under
  `pty.fork()`, plus two zsh source facts that pick the candidates rather than
  guessing at them.
  1. `references/zsh/Src/utils.c#callhookfunc` copies the hook array
     (`arrptr = arrdup(arrptr)`) before iterating it, so re-ordering
     `precmd_functions` from inside a hook cannot affect the cycle in progress.
  2. `references/zsh/Src/Zle/zle_main.c#zleread` expands the prompt on entry,
     before `zle-line-init` runs; `reset-prompt` re-expands from the saved
     `raw_lp`, which is the live `PS1` slot (`Src/input.c#ingetc` passes
     `&prompt`). So a `zle-line-init` wrap lands only if it also resets.
  3. `zsh-defense`: five emitters against no framework, against F14's
     rebuild-every-precmd framework registered **after** ours, and against real
     Starship. Four `true` cycles then a SIGWINCH; startup counted separately
     because it is the one prompt drawn before any hook can re-order itself.
  4. `bash-order`: real `starship init bash` crossed with four emitters and both
     source orders.
  5. Parser: a doubled `A` fed to `TerminalCore.Terminal` over a 20 -> 12 sweep,
     under both repaint shapes.
- Measurements or examples:

  Stage 1, zsh. Marks per prompt; 2 is correct, 0 is the silent loss:

  | defense | fw=none | fw=hostile | fw=starship |
  | --- | --- | --- | --- |
  | guarded precmd (F14's) | 2 startup, 2/cycle | **0 startup, 0/cycle** | 2, 2/cycle |
  | + re-tail each run | 2, 2/cycle | **0 startup**, 2/cycle | 2, 2/cycle |
  | `zle-line-init` + `reset-prompt` | 2, **4/cycle** | 2, 2/cycle | 2, **4/cycle** |
  | `zle-line-init`, no reset | **0**, 2/cycle | 0, 0/cycle | 0, 2/cycle |
  | **re-tail + heal** | 2, 2/cycle | 2, 2/cycle | 2, 2/cycle |

  The no-reset row is the discriminator for source fact 2: its wrap lands one
  prompt late (0 at startup, 2 thereafter) and never lands at all when the
  framework rewrites `PS1` each cycle. The `reset-prompt` row works but paints
  every prompt twice -- 4 marks and two visible copies of the prompt per cycle,
  even with no framework present. "Heal" is that same widget made conditional:
  it repaints only when it finds `PS1` unmarked, which after the re-tail has
  taken effect is only the very first prompt.

  Stage 2, Bash. Marks per prompt, `A` + `P;k=i` + `B`; the second `B` is
  readline redrawing the final prompt row:

  | emitter | ours sourced first | ours sourced last |
  | --- | --- | --- |
  | `PS1=` at source time | 1 (`A` only) | **1 (`A` only)** |
  | re-wrap from `PROMPT_COMMAND`, unguarded | 1 (`A` only) | 4 |
  | re-wrap, guarded | 1 (`A` only) | 4 |
  | guarded + re-tail | 1 startup, then 5 | 4 |

  Stage 3, parser. Prompt copies surviving the sweep, by repaint shape:

  | opener | zsh shape (whole prompt repainted) | readline shape (last row only) |
  | --- | --- | --- |
  | `A;redraw=last` | 9 | **1** |
  | `A;redraw=last` twice | 9 | **1** |
  | `A;redraw=1` | 1 | **0** |
  | nothing (parser default `full`) | 1 | **0** |

- Observation: zsh has a defense and Bash has half of one. In zsh, re-appending
  the hook to `precmd_functions` on every run recovers every prompt but the
  first -- exactly what the `arrdup` snapshot predicts -- and a conditional
  `zle-line-init` repaint recovers that first prompt too, at the cost of one
  extra paint per pane rather than one per prompt. In Bash, `A` is immune to
  ordering because it is *printed*, not stored in `PS1`; the `P`/`B` pair is
  not, and Starship's bash init is the async-rebuild shape D1 originally
  feared -- `PS1="$(starship prompt ...)"` on every `starship_precmd` -- so a
  source-time `PS1=` assignment fails in **both** orders, not just ours-first.
  Bash's re-tail works from cycle 2 but costs a doubled `A`, because Starship
  swallows a pre-existing `PROMPT_COMMAND` into `STARSHIP_PROMPT_COMMAND` and
  runs it before its own assignment, so the re-tailed emitter runs twice per
  prompt. Stage 3 says that doubling is inert: a doubled `A` is byte-for-byte
  equivalent to one in every regime measured, including the one that strands.
- Inference: adopt re-tail + heal for zsh; D1's known gap closes. For Bash,
  adopt guarded + re-tail and accept both the doubled `A` and one unmarked first
  prompt, which has no `zle-line-init` analogue to heal it -- Bash offers no
  hook that runs after `PROMPT_COMMAND`. Stage 3 also sharpens D2: under
  readline's real repaint shape, `redraw=1` and emitting *nothing* both destroy
  the prompt's upper row (0 copies survive), because the parser default is
  `full` and readline never rewrites that row. For Bash the declaration is
  load-bearing, not merely a hedge against a nested shell -- the opposite of
  fish, where D3's declaration only pins the mode.
- Competing interpretations: that the 9 under the zsh repaint shape indicts
  `redraw=last` for Bash. It does not -- that stimulus repaints the whole
  two-row prompt, which is zsh's behavior (F3), not readline's (F4). Under the
  readline shape the same opener is the only one of the four that survives. That
  the zsh startup zeros are a probe artifact is ruled out by the fw=none column
  of the same table, where the identical rc file yields 2 at startup.
- Uncertainty: the doubled `A` was measured as inert at the parser and as
  adjacent bytes at column 0 on the wire, but never rendered in a real DanTerm
  pane. Powerlevel10k is still not installed and still not measured; its
  instant-prompt path re-enters prompt drawing before `~/.zshrc` finishes and
  may defeat a `zle-line-init` heal that assumes one line-init per prompt.
  Neither defense was measured against a framework that *also* re-tails itself,
  which would be an unbounded ordering fight; nothing in either shell detects
  that, and this probe would not have shown it.
- Next action: amend D1 with the re-tail + heal mechanism and D2 with the
  `PROMPT_COMMAND` requirement and its residual first-prompt gap; drop the
  Phase 3 blocker to an emitter task.

### F16 -- a stale-width repaint strands a prompt head above the newest stamp, and the resize blanking never looked there

- Status: settled and fixed, over four rounds against three separate reports
  from the same drag. **Closes Phase 3's "never rendered in a real pane" gap by
  rendering them and finding a bug; refutes the leading hypothesis about
  reflow's wrap flags.**
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: `e97345e` (round one), `62c5e4b` (round two and
  the one-row-prompt regression it caused), `8a0a982` (round three),
  `d2fffbf` (review guards). The recording instrument was removed before
  `e97345e` and then restored for rounds two and three, which is what settled
  the ledger's open question about keeping it.
- Result or artifact paths: two live-pane fixtures under
  `lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/` --
  `zsh-stale-width-repaint.json` (390 events, 240 resizes) and
  `zsh-stale-width-prompt-drift.json` (90 events, 36 resizes, narrowing 81 to
  46) -- asserted by `TerminalShellDialectTests`'
  `staleWidthRepaintLeavesNoDebris`, `staleWidthDebrisSurvivesNoFollowingResize`,
  `staleWidthRepaintDoesNotAccumulateBlankRows`, and
  `oneRowPromptsAreNotTreatedAsDebris`.
- Commands, inputs, or reproduction: the maintainer opened a fish pane in
  DanTerm Dev, typed `zsh`, and dragged the window narrower. A temporary
  env-gated tape in `TerminalPTYHost` appended every `feed` chunk (at its real
  PTY read boundaries) and every `resize` to a JSONL file in the neutral fixture
  schema; replaying that tape against a bare `Terminal` reproduced the
  maintainer's screenshot row for row.
- Result: the stranding step contains **no resize at all**. Two consecutive
  repaints do it:

  ```
  211: ESC[J OSC133;A;redraw=1 <prompt padded to 49 cols> \r\n <lower row>
  212: \r\r ESC[A ESC[J OSC133;A;redraw=1 <prompt padded to 46 cols> ...
  ```

  Feed 211 paints a prompt string Starship rendered for the *previous* width, so
  it overflows the 46-column pane and soft-wraps onto two rows. Feed 212 repaints
  at the correct width but moves up only one row before erasing, so the wrapped
  head one row higher survives. That under-erase is zsh's, and `redraw=1` exists
  precisely so DanTerm's blanking makes it moot. It did not, because
  `clearPromptForResizeIfNeeded` anchored on the *first* `.prompt` row found
  walking up from the cursor: after 212 there are two stamped heads, it anchored
  on the lower one, and no later resize ever looked above it. The debris was
  permanent.
- Fix, round one: climb through prompt heads stacked directly on one another
  before blanking. Which stamps may be crossed is the whole content of the fix,
  and the instrumented state settled it rather than reasoning:

  ```
  CLIMB from 2 to 0;  0:prompt/46  1:continuation/7  2:prompt/46   <- harmful
  CLIMB from 5 to 4;  4:prompt/46  5:prompt/46                     <- correct
  ```

  Two heads with nothing between them is the stale-repaint signature; a
  genuinely earlier prompt is always separated from the current one by its own
  continuation row. So the climb crosses `.prompt` only. The first version
  crossed any non-`.none` row, passed the debris assertion, and silently erased
  the `zsh` command line the maintainer had typed at the fish prompt above --
  which is why the test asserts that line survives as well as that the fragment
  is gone.
- Fix, round two -- the drag that ends on the stranding repaint. The maintainer
  reported the identical fragment on a build carrying round one. Round one ran
  from the resize path alone, so it depended on the drag *continuing* past the
  repaint that stranded the head; a drag that ends on that repaint -- the
  ordinary case, since the last repaint is the one rendered at a stale width --
  left the fragment with nothing scheduled to remove it. Clearing also runs
  where the new head is stamped (`Terminal.swift#setSemanticPrompt`), which is
  the earliest point the row above is identifiable as a stale copy: it takes the
  arrival of a *newer* head to make the older one dangling.
- Regression from round two, and the third condition it forced. Adjacency alone
  ate real history: a one-row prompt entered repeatedly with no output between
  commands (`$ cmd1` / `$ cmd2` / `$ cmd3`) stacks legitimate heads directly on
  one another, and resizing erased them all. Debris exists only because it
  overflowed the width, so it is always soft-wrapped -- requiring
  `isSoftWrapped` separates the two cases exactly. `oneRowPromptsAreNotTreatedAsDebris`
  pins it.
- Fix, round three -- blanking traded the fragment for a growing gap. The
  maintainer's third report: blank lines accumulating between the prompt and the
  previous one, eight rows over a single narrowing drag. The cause is not the
  blanking but what the blanking left addressable. Every stale-width overflow
  costs the prompt one row permanently -- the shell repaints one row lower and
  never reclaims the row above -- so blanking in place converts each fragment
  into a blank line and the prompt walks down the pane. Remove the rows instead
  (`moveAndFillRows` by the removed count, `cursor.row` up by the same), which
  keeps the shell's relative cursor arithmetic valid exactly as an ordinary
  scroll does. Rows the resize path had already emptied are reclaimed too; they
  are stamped but hold nothing, and leaving them is what actually held the gap
  open. Verified pre-existing rather than introduced by rounds one and two
  before fixing.
- Review guards, round four. A Fable review of the accumulated fix raised two
  failure modes, neither of which could be constructed -- in both attempts the
  reclaim never fired -- so they stand as code-reading arguments, not
  demonstrated defects. Applied anyway in `d2fffbf` because they cost nothing:
  the reclaim ran under `.last` as well as `.full`, where Bash's `P;k=i`
  re-stamp arrives as a `.prompt` kind and could delete rows readline will never
  restore (F4); and it shifted rows and cursor together without checking both
  sit in the same scroll region, and ran on the alt screen.
- Prior art, and where DanTerm now stands relative to it. **No surveyed terminal
  reclaims the vacated rows, and one argues against it.**
  `references/kitty/kitty/screen.c#prevent_current_prompt_from_rewrapping`
  anchors on the first stamped head walking up -- DanTerm's pre-`e97345e`
  anchor -- so kitty strands the identical fragment;
  `.ghostty-src/src/terminal/Screen.zig#resizeInternal` inherits the same anchor
  and carries an explicit comment against physically erasing rows, on the
  grounds that the shell expects the space to remain available. foot, wezterm,
  vte and Windows Terminal use OSC 133 marks for navigation only and do no
  resize blanking at all. That comment targets *resize-time* clearing, whereas
  the round-three deletion fires at `A`-time after the shell has committed a new
  head, which is a materially different moment -- but the deletion is novel and
  should be treated as such.
- Competing interpretations, and what killed them: a Fable review proposed that
  `clearPromptCells` blanks cells without clearing `isSoftWrapped`, so a blanked
  row still carrying a wrap flag contributes `oldColumnCount` blank cells into
  the next row's logical line under a resize burst. **All of its code claims are
  true** -- `Terminal.swift#clearPromptCells` does leave the flag,
  `Terminal.swift#pack` does set it on rows it splits, the re-flatten loop does
  read `iterationEnd = row.isSoftWrapped ? oldColumnCount : retainedEnd`, and
  (uncited by the review, and the link that would make the chain fire) the loop's
  `case .narrow, .padding` appends real units for padding cells. The chain is
  live in source; it is simply not what happened. Splicing the feeds out of the
  real zsh sweep -- resizes in pairs, in fours, and all 52 back-to-back followed
  by the repaints -- replayed clean at one prompt every time. The review's
  mechanism was right and its stimulus was wrong: the chain fires on a cursor
  parked mid-line at a resize, not on a burst of them, and once probed that way
  it reproduced immediately. Fixed in round five.
  The maintainer's own hypothesis, that nesting zsh inside fish was the cause,
  was also wrong, but explains why the artifact was zsh-only in a useful way:
  fish's prompt supplied the `.continuation` row that made the over-blanking
  version of the fix visible.
- Uncertainty, narrowed by the review. Round one read as pattern-matching on a
  signature: two adjacent heads mean a stale repaint. The stronger statement is
  that conditions one and two are **a dangling-wrap invariant**, not a
  heuristic. A row carrying `isSoftWrapped` must be followed by the continuation
  of its own logical line; when a fresh `.prompt` head is stamped at row N, a
  row N-1 that is `.prompt` and `isSoftWrapped` has had its continuation
  overwritten, so it is provably a fragment. What survives as genuine
  uncertainty is narrower than F16 first claimed: a shell would have to strand a
  head that both soft-wrapped *and* is content it intends to keep. The third
  condition (retained content) is not part of that invariant -- it is
  bookkeeping debt, see the next action.
- Round five, and the review's two structural follow-ups. Both were taken, and
  both turned out to be real defects rather than cleanups -- each reproduced
  once the right variable was varied, which is the same lesson round one taught.
  1. **Representable blanking** (`c6c476c`). `clearPromptCells` emptied a row's
     cells and left its stamp and wrap flag, so "a row we vacated" was not a
     state anything could read; it had to be re-derived by asking whether a
     still-stamped row had content left. Two walks answered that question in
     opposite directions -- the stale-head climb refused to cross emptied rows,
     the reclaim loop directly below existed to cross exactly those rows. A
     `.vacated` case replaces both inferences. The climb keeps only the
     dangling-wrap invariant; the reclaim names `.vacated` and keeps the
     emptiness check as what it always was, the reason taking a row is free
     rather than the reason it is ours.
     Clearing the wrap flag with the cells fixed the "latent" re-flatten hazard
     below, which is not latent: reflow measures a soft-wrapped row to its full
     old width, so an emptied row still claiming a wrap flattens `oldColumnCount`
     blank cells into the middle of its logical line. Under `redraw=last`, a
     cursor parked mid-line at a resize shifted everything after it right by a
     full row and pushed the tail down. The resize bursts a review proposed never
     reproduced it because the burst was never the variable -- the cursor was.
     Pinned by `TerminalOSC133Tests.blankedPromptRowDoesNotWidenTheLineBelow`.
  2. **Output stamps** (`d1eb808`), closing the gap below. Worse than the review
     described: one resize inside the window cleared the entire pane, not just
     the anchor row. `C` now marks the row output starts on and every
     prompt-block search stops there. The first attempt to reproduce it failed
     and nearly retired the report -- `ESC[J` at column 0 leaves the cursor row's
     stamp intact, so the walk stopped harmlessly. It reproduces immediately with
     the cursor-up form a real shell emits (`\r ESC[A ESC[J`), which is the shape
     already recorded in this finding. Pinned by
     `TerminalOSC133Tests.resizeDuringARepaintEraseKeepsFinishedOutput`.
- The gap the output stamps closed: a resize landing between the shell's `ESC[J`
  and its `A`. The erase clears the head's stamp, so the upward walk in
  `clearPromptForResizeIfNeeded` crossed the now-`.none` rows and anchored on the
  *previous* prompt, blanking the last command's output and everything below it.
  Kitty was immune because its walk stops at an `OUTPUT_START` stamp
  (`references/kitty/kitty/screen.c#shell_prompt_marking`); DanTerm stamped no
  output rows -- `C` only un-stamped the cursor row, which says "not a prompt"
  and is precisely what let a walk pass through -- and so shared ghostty's
  exposure.
- Next action: none outstanding for this finding. The remaining Phase 4 work is
  rendering the Bash dialect in a real pane.

### F17 -- a shell advances a line by overflowing one, and padding sized for a width the drag already took away glues the prompt to the row above it

- Status: settled and fixed. **Second live-pane defect class, found in fish
  rather than zsh, and reached by a stimulus no earlier round had run: entering
  and leaving subshells mid-drag.**
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: this finding's commit; core suite 747 to 750.
- Result or artifact paths:
  `lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/fish-prompt-sp-overflow.json`
  (359 events, 165 resizes, 135 down to 52 and back to 84), asserted by
  `TerminalShellDialectTests.promptSPOverflowSurvivesAShellTransitionDrag`;
  parser-level case in
  `TerminalOSC133Tests.promptStartBreaksTheWrapClaimAboveIt`.
- Commands, inputs, or reproduction: the maintainer ran DanTerm Dev under
  `DANTERM_TAPE_PATH`, opened a fish pane, entered and exited `bash`, entered
  and exited `zsh`, and dragged the width throughout. The fish prompt above the
  `zsh` command came back indented three columns with its right-aligned segment
  re-wrapped onto a row of its own, and stayed that way. The tape converts and
  replays with
  `scripts/terminal-tape-to-fixture.py <tape> <fixture> --replace orbstack=cluster1`.
- Result: reproduced against a bare `Terminal` on the first replay, and the
  stepped replay named the exact event -- the resize from 118 to 115 columns,
  120 events after the bytes that caused it.
- Mechanism, and it is not DanTerm's invention. fish and zsh advance a line by
  *overflowing* one: the PROMPT_SP hack writes a marker and pads with spaces to
  `screen_width`, letting the terminal's own autowrap perform the newline, then
  returns and erases the landing row
  (`references/fish-shell/src/screen.rs#abandon_line_string`, whose comment
  notes zsh omits only the final erase). The padding is composed from a width
  the shell holds, and a drag takes that width away between the composing and
  the writing: here fish padded 135 cells into a pane already narrowed to 118.
  The overflow is then real -- 17 cells landed on the next row -- so the padded
  row is genuinely soft-wrapped, and after fish erases and repaints, what it is
  wrapped *into* is the prompt. Reflow measures a soft-wrapped row to its full
  old width, so every later resize spliced 118 cells of padding in front of the
  prompt and offset it by the overflow. Permanent, and re-derived at each new
  width.
- Fix: a `.prompt` head stamped at column 0 clears `isSoftWrapped` on the row
  above it. A prompt begins a logical line by definition, so nothing above it
  may claim it as a continuation.
- Ordering is load-bearing, and getting it wrong is silent. The stale-head
  reclaim from F16 recognizes a fragment *by* the wrap claim it still makes, so
  clearing the claim first destroys the evidence: the intermediate version fixed
  the indent and left a truncated head stranded above the final prompt. The
  synthetic case did not see it; the recording did, on the same replay. That is
  the second time in two findings that a recording caught what a reconstruction
  built from the same understanding could not.
- Why the fix keys on the prompt mark and not on the erase: zsh runs the same
  pad-and-wrap without the trailing `ESC[K`, so a rule keyed on "the
  continuation row was erased" would have fixed fish and missed zsh. The prompt
  mark is the one signal both dialects emit, and it states the invariant
  directly rather than approximating it.
- Accepted residual: the padded row's trailing spaces are cells the shell really
  wrote, so `retainedContentEnd` counts them and narrowing past them costs one
  blank row above the prompt. That is geometry-dependent rather than permanent
  -- widening back re-absorbs it, unlike the indent, which was baked in -- and
  the alternative, trimming trailing blanks during reflow, cannot distinguish
  padding from an echoed trailing space and would change selection and copy. Not
  taken.
- Next action: none. Bash in a real pane remains the open Phase 4 item; this
  round covered fish and zsh transitions but never rendered a Bash prompt of its
  own.

### F18 -- what strands a row is shell-specific: fish needs a settled sweep where zsh needed a fast drag

- Status: settled. **Closes the last Phase 3 gap: fish's declared `redraw` value
  is now pinned by a recording made against the shipped emitter.**
- Date and investigator: 2026-07-31, R1.
- Commit and worktree state: this finding's commit; core suite 750 to 751.
- Result or artifact paths:
  [capture-fish-drag.py](capture-fish-drag.py), and
  `lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/fish-redraw-discriminator.json`
  (61 events, 30 resizes, 100 down to 70 in a 12-row pane), asserted by
  `TerminalShellDialectTests.fishRequiresTheDeclaredValue`.
- Commands, inputs, or reproduction: `capture-fish-drag.py <tape>` runs real fish
  under `pty.fork()` with the maintainer's own config plus
  `-C 'source integrations/shell-integration/danterm.fish'` and `DANTERM=1`, so
  the stream carries both fish's native `A;click_events=1` and DanTerm's
  `A;redraw=1`. The tape converts with
  `scripts/terminal-tape-to-fixture.py <tape> <fixture> --replace orbstack=cluster1`.
- Result: replayed as recorded, 1 prompt. Forced to `redraw=0`, 31. Forced to
  `redraw=last`, 31. Only DanTerm's mark carries a redraw option, so the override
  moves exactly the byte under test.
- What the first attempt got wrong, and it is the finding. The fast drag that
  discriminated for zsh (F15's stimulus: one SIGWINCH per column, a 20ms drain,
  the next resize landing mid-repaint) discriminates nothing for fish -- it left
  1 prompt as recorded and 1 at `redraw=0`. Two shell behaviors cause that.
  fish diffs its repaint against its own model of the screen instead of
  rewriting the prompt, so a repaint that is interrupted and re-entered emits
  only the changed cells; and once the prompt no longer fits the pane fish
  truncates it with a leading ellipsis
  (`references/fish-shell/src/screen.rs#truncate_run`), so from the first
  narrowing step on there was no full prompt on screen to strand copies of. The
  settled sweep -- SIGWINCH, pause, drain the repaint in full -- is what strands
  rows for fish, which is the opposite of what zsh needed. "Reproduce the
  stimulus that worked last time" is not transferable across shells; what has to
  transfer is the question, *what leaves a whole old prompt on screen*.
- What the recording does and does not pin. It pins the *value*: `redraw=1` is
  correct and both other values staircase. It does not pin the mark's presence,
  because the parser defaults to `full` -- deleting the line from `danterm.fish`
  renders identically on this stream. The declaration still earns its place, and
  the `redraw=last` column is the evidence: `last` is Bash's value, so a nested
  Bash leaves it behind on exit, and re-declaring on every prompt is what takes
  it back. That is the hazard D3 asserted from reasoning and this measures.
- Next action: none. Bash in a real pane remains the one open item.
