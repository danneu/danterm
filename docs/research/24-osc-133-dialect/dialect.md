# The DanTerm OSC 133 dialect

The exact marks each bundled integration emits, where it emits them, and the
parser rule each one relies on. Authored by R1 and checked against the shipping
parser in `F7`; the emitters are not written yet, so this is a specification, not
a description of `integrations/shell-integration/` as it stands today (`F2`).

Every mark below is `ESC ] 133 ; <action> [ ; <option> ... ] BEL`. BEL and ST are
interchangeable (`F7` case 6); the dialect writes BEL (`\a`, `0x07`), matching the
in-gate zsh capture and every reference integration.

**This dialect is engine-internal.** No mark here is a semantic input. Command,
remote, integration-ready, and agent facts travel only on
`OSC 1337;DanTermShell=1`, and the live semantic reducer consumes no marks --
which is why the dialect can be chosen purely for row classification and prompt
redraw, and revised without touching the semantic model.

## The whole dialect

| mark | emitted by | parser effect relied on |
| --- | --- | --- |
| `133;A;redraw=1` | zsh, once per `PS1` render | fresh line, stamp row `prompt`, set mode `full` |
| `133;A;k=s` | zsh, per continuation line and per `PS2` render | stamp row `continuation` |
| `133;A;redraw=last` | Bash, once per prompt from precmd | fresh line, stamp row `prompt`, set mode `last` |
| `133;A;redraw=0` | fish, once per `fish_prompt` event | stamp row `prompt` (fresh line is a no-op at column 0), set mode `disabled` |
| `133;P;k=i` | Bash, opening `PS1` | stamp row `prompt` with no fresh line |
| `133;P;k=s` | Bash, opening `PS2` and each continuation line | stamp row `continuation` with no fresh line |
| `133;B` | zsh and Bash, closing `PS1`/`PS2` | end prompt, begin input |
| `133;C` | zsh and Bash, from preexec | begin output -- suppresses resize blanking for the command's lifetime |

fish emits none of `A`(bare)/`B`/`C`/`D` from DanTerm: it emits them itself
(`F5`). DanTerm contributes only the `redraw` declaration.

Not emitted, by decision `D4`: `D`, `L`, `I`, `N`, and the inert `aid=`, `cl=`,
`click_events=` options.

## zsh (`danterm.zsh`)

Marks live inside the prompt strings, wrapped in `%{...%}` so they carry no
print width, because zsh re-emits `PS1` on every redisplay including SIGWINCH
(`F3`) -- which is what keeps the row stamp and the mode declaration alive across
repaints (`D1`, `D0`).

```
PS1 = %{ESC]133;A;redraw=1 BEL%}  <user PS1>  %{ESC]133;B BEL%}
PS2 = %{ESC]133;A;k=s BEL%}       <user PS2>  %{ESC]133;B BEL%}
```

Each embedded newline inside a multi-line `PS1` is followed by
`%{ESC]133;A;k=s BEL%}`, except one immediately after the opening mark -- `A`'s
fresh line would otherwise double it.

`preexec` prints `ESC]133;C BEL` after the existing `DanTermShell=1;command-start`
envelope event, so the mark sits adjacent to the command's own output.

`precmd` prints no mark. The next `PS1` render carries `A`.

## Bash (`danterm.bash`)

`A` is printed once per prompt from the precmd hook rather than embedded, and the
in-prompt stamps use `P`, which has no fresh-line behavior -- readline redisplays
mid-line on Ctrl-L and vi-mode switches (`D2`, and README's rejected ideas).

```
precmd:  printf 'ESC]133;A;redraw=last BEL'
PS1   =  \[ESC]133;P;k=i BEL\]  <user PS1>  \[ESC]133;B BEL\]
PS2   =  \[ESC]133;P;k=s BEL\]  <user PS2>  \[ESC]133;B BEL\]
preexec: printf 'ESC]133;C BEL'
```

Each `\n` prompt escape inside `PS1` is followed by `\[ESC]133;P;k=s BEL\]`.
Substitute only the `\n` escape, not a literal newline: a literal one can appear
inside a `$(...)` substitution, where injecting an escape breaks shell syntax.

`redraw=last` is measured, not inherited: readline repaints only the final line
of a multi-line prompt after SIGWINCH (`F4`), so only that row may be blanked.

The marks must be wrapped in `\[...\]` so readline excludes them from its width
calculation.

## fish (`danterm.fish`)

fish 4.7.1 already emits `133;A;click_events=1`, `133;B`, `133;C;cmdline_url=...`,
and `133;D;<status>` with no integration loaded, and all of them parse cleanly
under DanTerm's grammar (`F5`). DanTerm adds exactly one mark:

```
--on-event fish_prompt:  printf 'ESC]133;A;redraw=0 BEL'
```

`redraw=0` disables prompt blanking for the pane. DanTerm does **not** set
`fish_handle_reflow`; fish's own detection is left alone (`D3`).

Why blanking is switched off here, when zsh asks for the opposite (`D1`): fish
left-truncates any prompt too wide for the pane (`F10`), so a fish prompt row
never soft-wraps, never re-wraps on resize, and therefore never leaves the stale
prompt that blanking exists to clear. A real-pane sweep found `redraw=0`,
`redraw=1`, and no declaration at all to be observationally identical (`F11`);
`redraw=0` is chosen because it is the one that cannot erase a prompt if fish's
repaint is ever incomplete. The declaration is still emitted every prompt so a
nested shell's `redraw=1` cannot persist into the fish pane (`D0`).

Ordering against fish's own `A` does not matter: a second `A` at column 0 is an
idempotent re-stamp with a no-op fresh line, and an option-less `A` never clears
the mode (`F1`).

## What each mark buys

- **The `prompt` stamp is mandatory.** In `full` mode the parser walks up from
  the cursor row looking for a `prompt`-stamped row and blanks from there down;
  finding none, it blanks nothing (`F1`). One stamped row per prompt is the
  entire contract.
- **Continuation stamps are not what makes multi-line prompts work.** The upward
  walk passes through unstamped rows too, so a multi-line prompt is blanked whole
  even without them (`F7` case 3). They are emitted for the reflow packer, which
  reads the same row stamps when merging soft-wrapped lines, and to keep `PS2`
  input rows classified during multi-line entry.
- **`C` is what protects command output.** Blanking is skipped entirely while the
  content state is `output`, so without `C` a resize during a long-running
  command would blank the prompt block under the running program (`F7` case 4).
- **`redraw` is a promise about repaint.** `1` means "I repaint the whole
  prompt", `last` means "I repaint its final line", `0` means "I repaint
  nothing -- do not blank". The parser blanks exactly what the shell promises to
  rewrite, and each integration restates its promise on every prompt because the
  mode is pane state that outlives the shell that set it (`D0`, `F7` case 5).
