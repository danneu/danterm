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
  `share/fish/functions/__fish_config_interactive.fish`.
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
- Commands, inputs, or reproduction: `scratchpad/xtversion_probe.py` -- interactive
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
- Commands, inputs, or reproduction: two stages, both in
  `scratchpad/capture_fish_sweep.py` and a temporary `TerminalCore` test.
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
