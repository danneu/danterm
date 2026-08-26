# Terminal Capability Contract

DanTerm advertises `TERM=xterm-256color` for compatibility, but does not claim
every behavior found in an xterm terminfo database. This document is the
normative contract: it records the exact terminfo claims needed by accepted
workflows, their macOS 26 ncurses 6.0 and current ncurses variants, supported
and denied protocol families, environment ownership, and numeric limits.
Applications should treat unlisted terminfo entries and protocols as
unsupported. An incompatible change will use a new versioned document section
or, should a machine-readable contract be needed again, a new artifact (v2+) --
never a revival of the retired `terminal-capabilities-v1.json`.

## Provenance

Terminfo values below were captured from the `xterm-256color` terminfo entries
of two baselines: macOS 26's `/usr/share/terminfo` entry (`infocmp` ncurses
6.0.20150808) and the official ncurses `terminfo.src` revision 1.1261 dated
2026-07-19. Through 2026-07-22 these values were also carried in a
machine-readable `terminal-capabilities-v1.json` manifest, cross-checked
byte-for-byte against two JSON terminfo fixtures and copied into the app
bundle; that manifest, its fixtures, and the build/CI byte-comparison gates
were retired in favor of this document (see
[plans/impl](../plans/impl/) for the retirement plan). The two baselines agree
on every claim below except `pairs`, which no DanTerm behavior depends on; the
old cross-ncurses "baseline matrix" byte-comparison this document replaces is
superseded by this provenance note plus the behavioral key-conformance test in
`TerminalKeyEncodingTests`.

## Terminfo claims

| id | kind | XTGETTCAP query | macOS 26 ncurses 6.0 | ncurses 1.1261 | evidence |
|---|---|---|---|---|---|
| `am` | boolean | `am` | `true` | `true` | TerminalEditingTests |
| `bce` | boolean | `bce` | `true` | `true` | TerminalEditingTests |
| `colors` | number | `colors` `Co` | `256` | `256` | TerminalStyleTests |
| `pairs` | number | -- | `32767` | `65536` | TerminalStyleTests |
| `clear` | output | `clear` | `\x1b[H\x1b[2J` | same | TerminalEditingTests |
| `cup` | output-parameterized | `cup` | `\x1b[%i%p1%d;%p2%dH` | same | TerminalEditingTests |
| `civis` | output | `civis` | `\x1b[?25l` | same | TerminalModeTests |
| `cnorm` | output | `cnorm` | `\x1b[?12l\x1b[?25h` | same | TerminalModeTests |
| `smcup` | output | `smcup` | `\x1b[?1049h` | same | TerminalModeTests |
| `rmcup` | output | `rmcup` | `\x1b[?1049l` | same | TerminalModeTests |
| `setaf` | output-parameterized | `setaf` | `\x1b[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m` | same | TerminalStyleTests |
| `setab` | output-parameterized | `setab` | `\x1b[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m` | same | TerminalStyleTests |
| `sgr0` | output | `sgr0` | `\x1b(B\x1b[m` | same | TerminalStyleTests |
| `bold` | output | `bold` | `\x1b[1m` | same | TerminalStyleTests |
| `smul` | output | `smul` | `\x1b[4m` | same | TerminalStyleTests |
| `rmul` | output | `rmul` | `\x1b[24m` | same | TerminalStyleTests |
| `el` | output | `el` | `\x1b[K` | same | TerminalEditingTests |
| `ed` | output | `ed` | `\x1b[J` | same | TerminalEditingTests |
| `kcuu1` | key | `kcuu1` | `\x1bOA` | same | TerminalKeyEncodingTests |
| `kcud1` | key | `kcud1` | `\x1bOB` | same | TerminalKeyEncodingTests |
| `kcub1` | key | `kcub1` | `\x1bOD` | same | TerminalKeyEncodingTests |
| `kcuf1` | key | `kcuf1` | `\x1bOC` | same | TerminalKeyEncodingTests |
| `khome` | key | `khome` | `\x1bOH` | same | TerminalKeyEncodingTests |
| `kend` | key | `kend` | `\x1bOF` | same | TerminalKeyEncodingTests |
| `kdch1` | key | `kdch1` | `\x1b[3~` | same | TerminalKeyEncodingTests |
| `kpp` | key | `kpp` | `\x1b[5~` | same | TerminalKeyEncodingTests |
| `knp` | key | `knp` | `\x1b[6~` | same | TerminalKeyEncodingTests |
| `kmous` | key-prefix | `kmous` | `\x1b[M` | same | TerminalMouseEncodingTests |

The nine key rows (`kcuu1` through `knp`) are pinned by an executable test:
`TerminalKeyEncodingTests` asserts that `encodeTerminalKey` produces exactly
these terminfo sequences in application-cursor-mode.

### The table as a wire contract

XTGETTCAP answers from this table and from nothing else, so each row states the
three facts a reply needs. The **XTGETTCAP query** column lists every name the
row answers to, and `--` marks a row this document records but does not answer.
The **kind** column fixes the value kind: `boolean` rows reply with the name and
no value, `number` rows reply with decimal digits, and every other kind is a
string. The **macOS 26 ncurses 6.0** column is the one runtime value, which is
why a row is answerable only when the two baselines agree on it. `pairs` is the
single row where they do not, and DanTerm cannot break the tie: the database an
application compares the answer against is the one on the host it runs on, which
a remote shell puts outside DanTerm's platform. So `pairs` is recorded and not
answered. Every other row is baseline-independent, which is what makes one
runtime value honest for it.

A string value goes on the wire in terminfo source form when it carries a `%`
parameter, and with its escapes decoded to bytes when it does not. That split is
xterm's original interface widened by kitty, and both peers implement exactly
it, so DanTerm matches rather than picking the more consistent rule.

Two pseudo-capabilities are named by xterm's XTGETTCAP interface but belong to
no terminfo row, so they are stated here with the same three facts:

| query | kind | value | disposition |
|---|---|---|---|
| `TN` `name` | string | `xterm-256color` | answered -- the `TERM` DanTerm owns, below |
| `RGB` | number | -- | denied -- an ncurses direct-color extension absent from both `xterm-256color` baselines; DanTerm advertises direct color as `COLORTERM=truecolor` instead |

`Co` is not a third pseudo-capability: it is the termcap spelling of the
`colors` row and answers with that row's value.

## Protocols

Supported protocol families, with their evidence suite:

| id | evidence |
|---|---|
| `da1-dsr-cpr-deccpr-decrqm` | TerminalQueryTests |
| `xtversion` | TerminalQueryTests |
| `decrqss` | TerminalDECRQSSTests |
| `xtgettcap` | TerminalXTGETTCAPTests |
| `osc-10-11-default-color-queries` | TerminalQueryTests, TerminalPTYHostChildProcessTests, RenderFramePlanningTests |
| `kitty-keyboard` | TerminalKeyEncodingTests |
| `legacy-xterm-keyboard` | TerminalKeyEncodingTests |
| `legacy-and-sgr-mouse` | TerminalMouseEncodingTests |
| `focus-reporting` | TerminalModeTests |
| `alternate-screen-bracketed-paste-synchronized-updates` | TerminalModeTests |
| `pane-bell-without-audio-or-flash` | TerminalSemanticEventTests |
| `title-cwd-notifications-progress` | TerminalSemanticEventTests |
| `http-https-hyperlinks` | TerminalHyperlinkTests |
| `clipboard-write-read-denial` | TerminalOSC52Tests |
| `osc-133-semantic-prompt-redraw` | TerminalOSC133Tests, TerminalShellDialectTests, DanTermRecordingFixtureTests |
| `tokenless-shell-events` | TerminalShellEventTests |

Denied: `audible-bell`, `clipboard-read`, `da2`, `decrqcra`, `kitty-osc-99`,
`sixel`, `eight-bit-replies`.

OSC 133 support is engine-internal: semantic prompt/input state lets a shell
redraw its prompt cleanly after resize. DanTerm does not expose semantic events,
per-cell semantics, click-to-move, or prompt navigation from this protocol.

The engine accepts `A`, `B`, `C`, `D`, and `P` with the options `redraw=0|1|last`,
`k=i|s`, `aid=`, `cl=`, and `click_events=`; unknown actions and options are
ignored rather than rejected. `redraw` is the only option that changes behavior:
it declares how much of the prompt block the shell promises to repaint, and the
parser blanks exactly that much before a reflow. The mode is sticky per-pane
state reset only by RIS, so a well-behaved integration restates it on every
prompt. Absent any declaration the mode is `full`, which means a shell that
stamps a prompt row without declaring `redraw` has implicitly promised a whole-
prompt repaint.

The bundled integrations emit a deliberately small subset of that grammar, and
each one's `redraw` value is measured against how that shell actually repaints
after SIGWINCH rather than copied from another terminal:

| integration | emits | declares |
|---|---|---|
| `danterm.zsh` | `A`/`B` inside `PS1`/`PS2`, `A;k=s` per continuation line, `C` from preexec | `redraw=1` -- zsh re-renders the whole prompt |
| `danterm.bash` | `A` from `PROMPT_COMMAND`, `P;k=i`/`P;k=s`/`B` inside `PS1`/`PS2`, `C` from preexec | `redraw=last` -- readline repaints only the final prompt line |
| `danterm.fish` | the `redraw` declaration only; fish emits `A`/`B`/`C`/`D` itself | `redraw=1` -- fish re-renders the whole prompt |

Bash uses `P` rather than `A` for its in-prompt row stamps because `P` carries no
fresh-line behavior and readline redisplays mid-line on Ctrl-L and vi-mode
switches. `D`, `L`, `I`, and `N` are parsed but no integration emits them. The
derivation of each choice is in
[docs/research/24-osc-133-dialect/dialect.md](research/24-osc-133-dialect/dialect.md).

## Child environment

DanTerm owns the following child-process environment variables. Inherited
collisions cannot override these values. The bundle version is also the
version returned by XTVERSION.

| name | ownership | visibility |
|---|---|---|
| `TERM` (`xterm-256color`) | danterm | public |
| `COLORTERM` (`truecolor`) | danterm | public |
| `TERM_PROGRAM` (`DanTerm`) | danterm | public |
| `TERM_PROGRAM_VERSION` (`<bundle-version>`) | danterm | public |
| `DANTERM_SHELL_INTEGRATION_DIR` (`<running-bundle>/Contents/Resources/shell-integration`) | danterm | public |
| `DANTERM` (`1`) | pane | public |
| `DANTERM_SOCK` (`<socket-path>`) | pane | public |
| `DANTERM_PANE` (`<pane-id>`) | pane | public |
| `LC_DANTERM` (`1`) | ssh/mosh wrapper | public |
| `DANTERM_RESTORE_SCROLLBACK_FILE` (`<recovery-file-path>`) | pane-when-restoring | private |
| `DANTERM_RESTORE_COMMAND` (`<editable-command>`) | pane-when-restoring | private |

Private shell events use `OSC 1337;DanTermShell=3;<event>[;<arg>...] ST`.
The exact field counts are two for `integration-ready`; three for
`command-start`, `command-end`, `connection;local`, and `connection;remote`;
and five for `connection;remote;<user>;<host>`. Command and identity values use
canonical padded base64 and strict UTF-8. Command-end's exit status is canonical
decimal in the range 0 through 255. Shell integrations emit when either
`DANTERM` or `LC_DANTERM` is present; ssh and mosh wrappers forward
`LC_DANTERM=1`, and a shell with `LC_DANTERM` but no `DANTERM` is remote. Every
prompt declares the shell's complete connection state. A wrapper declares an
identity-less remote before launch and emits nothing afterward, so the next
prompt restores local state or an enclosing remote identity without a paired
close or wrapper-owned state.

Direct and nested PTYs and SSH preserve the complete private envelope. Inside
tmux, the integration uses DCS passthrough; delivery requires the user's tmux
server to have `allow-passthrough` enabled already. The integration does not
change that policy. Mosh filters far-side private OSC, so only the near-side
identity-less remote declaration and the owning shell's later prompt declaration
are available for a mosh session.
`DANTERM_SHELL_INTEGRATION_DIR` is persistent discovery state: shell hooks read
it but the integration does not consume or rewrite it, so nested and re-exec'd
shells continue to find the running bundle's assets. Remote shells have no
local app bundle and use their packaged or copied assets when `LC_DANTERM` is
present instead.

## Queries and semantic protocols

DanTerm supports the query, mode, keyboard, mouse, focus, title, cwd, hyperlink,
clipboard-write, shell-event, notification, progress, and bell families listed
under "Protocols" above. The denied list is explicit, including DA2, DECRQCRA,
clipboard reads, Kitty OSC 99, 8-bit replies, and audible or visual bell
effects.

DECRQSS answers `DCS $ q <setting> ST` for exactly these four settings, and for
no other request:

| request | setting | status string |
|---|---|---|
| `m` | SGR | the complete rendition, always led by `0` |
| `r` | DECSTBM | the active scroll region as one-based inclusive rows |
| ` q` | DECSCUSR | the cursor shape and blink as one parameter |
| `"q` | DECSCA | whether the pen arms protection |

A reported setting replies `DCS 1 $ r <status> ST`; every other request --
including DECSLRM and DECSACE, which DanTerm does not model, and any `$ q`
header carrying a parameter -- replies `DCS 0 $ r ST`. The invalid reply never
echoes the request, so an attacker-supplied query cannot be reflected into the
stream (CVE-2008-2383). Prefixing a status string with CSI is the sequence that
re-establishes the setting it reports; the reply itself is DCS-framed and is
inert when fed back verbatim. A request body is matched byte for byte, so any
byte outside a listed request makes it invalid, and a body over the
`pending-control-string` limit draws no reply at all rather than a reply to a
truncated request.

XTGETTCAP answers `DCS + q <name>[;<name>...] ST`, where each name is its
capability name in hexadecimal, two uppercase or lowercase digits per character.
The answerable set is exactly the "XTGETTCAP query" column of the terminfo
claims table plus the `TN`/`name` pseudo-capability; every other name, and every
body that is not well-formed hexadecimal, misses.

A reply is `DCS 1 + r <pair>[;<pair>...] ST`, where a pair is the requested
name's own request bytes, then `=`, then the value in uppercase hexadecimal. A
boolean capability replies with the name and no `=`. The **first** name alone
decides the digit: if it misses, the reply is `DCS 0 + r ST` and carries
nothing. Otherwise pairs stream in request order and processing stops at the
first name that misses, so a request whose Nth name misses draws the valid reply
carrying the first N-1 pairs and nothing after them. `Co;<unknown>;TN` answers
`Co` and never reaches `TN`. The name that missed is not echoed: xterm emits its
request bytes before it stops, and DanTerm does not, because reflecting an
attacker-supplied query into the stream is CVE-2008-2383. An empty body misses.
A body over the `pending-control-string` limit draws no reply at all.

Every other DCS family -- tmux control mode, sixel, DECDLD soft fonts,
DECRQUPSS, and DECDMAC among them -- is absorbed and answered with nothing, and
retains none of its body. The VT420 sequences whose reply is DCS-framed but
whose request is CSI -- DECRQCRA, DECCIR, DECTABSR, and DECRQPSR -- are
unimplemented and their requests stay silent.

`OSC 7` accepts a `file://` URI whose host is `localhost`, or names this machine
ignoring ASCII case, one trailing dot, and a trailing `.local` label; any other
host leaves the pane's directory unchanged. The machine's name is its POSIX
hostname -- the value the shells themselves interpolate -- so the `.local`
tolerance covers only the mDNS spelling macOS manufactures, not a general
first-label match (`mac.evil.com` stays rejected).

`CSI > q` and `CSI > 0 q` return `DCS >|DanTerm <version> ST`. The accepted
desktop notification forms are `OSC 9;<body>` and
`OSC 777;notify;<title>;<body>`. The OSC 777 body may contain semicolons.

`OSC 10;?` and `OSC 11;?` report the pane's baked default foreground and
background as `rgb:rrrr/gggg/bbbb` using 7-bit `ST`. Each eight-bit sRGB
component is expanded by repeating its byte. Setting forms, reset forms, and
multi-resource queries are unsupported and ignored.

Progress uses only:

- `OSC 9;4;0` to remove progress
- `OSC 9;4;1;<0...100>` for determinate progress
- `OSC 9;4;2[;<0...100>]` for error progress
- `OSC 9;4;3` for indeterminate progress
- `OSC 9;4;4[;<0...100>]` for paused progress

Exact first fields `1` through `12` are reserved ConEmu selectors. They are
ignored instead of becoming notification bodies; selector 4 is progress only
when its complete payload matches a form above. Other numeric-only or
numeric-leading text remains an ordinary OSC 9 notification body. Malformed and
unknown forms are ignored.

## Resource behavior

These numeric limits are part of the public contract:

| id | value | unit | evidence |
|---|---|---|---|
| `pending-control-string` | 2097152 | bytes | TerminalInputStreamTests |
| `decoded-clipboard-write` | 1048576 | bytes | TerminalOSC52Tests |
| `semantic-value` | 65536 | bytes | TerminalSemanticEventTests |
| `discrete-semantic-events` | 100 | events | TerminalSemanticEventTests |
| `engine-metadata` | 262144 | bytes | TerminalMetadataIntegrationTests |
| `handoff-metadata` | 262144 | bytes | TerminalMetadataIntegrationTests |
| `model-metadata` | 524288 | bytes | TerminalMetadataIntegrationTests |
| `pending-query-replies` | 65536 | bytes | TerminalQueryTests |
| `scrollback` | 16777216 | bytes | TerminalScrollbackBudgetTests |

In particular, control strings retain at most 2 MiB encoded input; decoded
clipboard writes are limited to 1 MiB; a title, cwd, link, shell payload, or
complete notification title-plus-body is limited to 64 KiB; and pending query
replies are limited to 64 KiB. Bell, shell, and notification events share a
100-event discrete queue. Title, cwd, and progress coalesce to the newest
complete value.

Metadata retention is bounded independently at each layer rather than by one
cross-layer sum: the engine caps its own retention at 256 KiB. DanTerm then
bounds terminal-originated command text at 64 KiB and remote identity at 64 KiB
for the combined user-plus-host bytes before either enters pane-owned semantic
state. The model separately caps title, cwd, and notification fields at 64 KiB
per value and retains at most 100 alerts, so its total metadata scales with live
pane count rather than a fixed app-wide byte bound. Scrollback is limited to 16
MiB and damage is bounded by current grid state. Oversized or malformed input
has no partial effect, does not retain a second unbounded copy, and cannot
prevent later valid input from being processed. A query reply that cannot fit
is dropped as one complete unit.
