# tmux

tmux works in DanTerm with no setup. Two of its defaults are worth changing,
because a multiplexer sits between your programs and DanTerm and rewrites what
DanTerm is allowed to see.

## Settings worth changing

tmux runs in DanTerm with no configuration. These defaults are worth changing
anyway, because each one hides something DanTerm supports.

```tmux
set -g default-terminal "tmux-256color"
set -g set-titles on
set -g mouse on
set -g set-clipboard on
set -g focus-events on
set -s extended-keys on
set -as terminal-features 'xterm*:extkeys'
set -g activity-action none
set -g allow-passthrough all
```

| Setting | tmux default | What the default costs you |
| --- | --- | --- |
| `default-terminal` | `screen` | The `screen` entry declares `colors#8` and carries no `sitm`, so every program inside tmux drops to 8 colors and loses italics. `tmux-256color` declares 256 and both italic capabilities. |
| `set-titles` | `off` | tmux never reports a title, so a DanTerm pane running tmux keeps whatever label it had. |
| `mouse` | `off` | The scroll wheel does not reach tmux's scrollback and a click does not select a pane. Programs inside a pane can still use the mouse either way. |
| `set-clipboard` | `external` | `external` refuses `OSC 52` from programs inside a pane, so a yank in a remote editor never reaches your Mac clipboard. `on` forwards it. |
| `focus-events` | `off` | tmux swallows focus reporting, so an editor's `FocusGained` and a shell's focus hooks never fire. Read the activity section below before turning this on -- it is one half of the notification problem. |
| `extended-keys` | `off` | tmux ignores a pane's request for extended keys outright, so a program cannot tell Shift+Enter from Enter. |
| `activity-action` | `other` | Background window output arrives as a bell, and DanTerm turns that into a notification. See below. |
| `allow-passthrough` | `off` | The shell integration's marks and every desktop notification are dropped. See below. |

Three of these have a detail worth knowing.

**Clipboard is one-way.** `set-clipboard on` lets a program inside tmux write
your Mac clipboard. It does not let one read it: DanTerm answers an `OSC 52`
write and denies a read, which is the `clipboard-write-read-denial` row of the
[terminal capability contract](../terminal-capabilities.md).

**Truecolor needs no override.** Guides tell you to add
`terminal-features ...:RGB`. You do not need it here. DanTerm sets
`COLORTERM=truecolor`, and tmux turns that into the `RGB` feature on its own
(`references/tmux/tty-term.c`). `default-terminal` is about the terminfo
entry programs read, not about what reaches DanTerm.

**`extended-keys on` may not be enough.** The three values are not on/off:
`off` makes tmux ignore a pane's `CSI > 4 ; m m` request, `on` honors a request
the program makes, and `always` forces the mode on for a program that never
asks (`references/tmux/input.c`). A program that submits on Shift+Enter instead
of inserting a newline is usually one that never asks, so it needs `always`.

`tmux-256color` has to exist in the terminfo database on the host running the
tmux *server* -- for an SSH session that is the remote box, not your Mac. Check
with `infocmp tmux-256color`.

Home Manager users: `programs.tmux.terminal` defaults to `"screen"`, so the
first line above is `terminal = "tmux-256color";` in Nix, not `extraConfig`.

## Window activity arrives as a notification

DanTerm turns a terminal bell in an unfocused pane into a macOS notification.
tmux, with `monitor-activity on`, turns *any output at all* from a background
window into a terminal bell. Put those together and switching tmux windows
notifies you about a window where nothing happened.

The chain, in full:

1. `focus-events on` makes tmux forward focus changes into each pane.
2. You leave a window. tmux sends focus-out to the pane you left.
3. The shell there repaints its prompt in response. fish does this in
   `reader.rs` (`FocusOut => { ...; self.save_screen_state(); }`); other
   shells and prompts behave similarly.
4. That repaint is output on a window that is no longer current, so
   `monitor-activity` raises an activity alert.
5. `activity-action` defaults to `other`, which the window qualifies for, and
   `visual-activity` defaults to `off`. For `off`, tmux's entire response is
   `tty_putcode(&c->tty, TTYC_BEL)` -- a literal `\a` to DanTerm
   (`references/tmux/alerts.c`).
6. DanTerm rings the bell and, because the pane is not focused, shows a
   notification.

The notification also names the wrong thing. Its body is the pane title, which
tmux has just rewritten to whichever window is now current, so you get a banner
naming the window you switched *to* about output from the window you switched
*from*:

```
DanTerm
1:2:fish - "~"
```

Keep the alert flag in the status line and drop the bell:

```tmux
set -g activity-action none
```

`activity-action none` still sets the window's `#` flag and still fills
`#{session_alerts}`, because tmux marks the window before it consults the
action. It just stops turning the mark into a bell or a status message.

Two alternatives, if you want something different:

| Setting | Effect |
| --- | --- |
| `set -g activity-action none` | Keeps the `#` flag. No bell, no message. |
| `set -g visual-activity on` | Keeps the `#` flag. No bell, adds a status message for `display-time` ms (default 750). |
| `setw -g monitor-activity off` | No flag, no bell, no message. |

Real bells route through the same code with `bell-action` and `visual-bell`, so
leave those alone unless you also want to silence a program that genuinely
rings.

## Shell integration and notifications need passthrough

tmux does not forward a sequence it does not understand. A program inside tmux
that emits one is talking to tmux, and tmux throws the request away. Two things
DanTerm relies on are in that category:

- **The shell integration's own marks.** They ride `OSC 1337;DanTermShell=`,
  which tmux has no case for. The integration knows this: when `$TMUX` is set
  it wraps every mark in tmux's passthrough escape instead
  (`integrations/shell-integration/danterm.zsh`, and the same in the bash and
  fish scripts).
- **Desktop notifications.** tmux parses `OSC 9` and drops everything that is
  not the `9;4;` progress form, and it has no case for `OSC 777` at all --
  `input_osc_9` and the `default:` branch of its OSC dispatch in
  `references/tmux/input.c`. That covers the Claude Code hook, which emits
  `OSC 777`, and Codex's `notification_method = "osc9"`.

Passthrough is off by default, so turn it on:

```tmux
set -g allow-passthrough all
```

Use `all`, not `on`. `on` permits passthrough only while the pane is visible,
which discards exactly what you wanted most -- the marks and notifications from
a window you are not looking at.

The emitter still has to do the wrapping. DanTerm's shell integration does it
for you. Claude Code v2.1.141+ emits its sequence itself and handles tmux
passthrough, so [claude-code.md](claude-code.md) works once passthrough is on.
Confirm your other tools wrap their sequences before assuming they get through.

## What comes through without passthrough

Titles, working directories, and prompt marks: tmux consumes `OSC 0`, `OSC 2`,
`OSC 7`, and `OSC 133` from the pane and speaks them to DanTerm itself. The
pane title you see is tmux's `set-titles-string`, not the shell's, which is why
a DanTerm pane running tmux is labelled `1:2:fish - "~"` rather than by cwd.
