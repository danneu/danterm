# Terminal Capability Contract

DanTerm advertises `TERM=xterm-256color` for compatibility, but does not claim
every behavior found in an xterm terminfo database. The normative contract is
[`terminal-capabilities-v1.json`](../terminal-capabilities-v1.json), also
installed byte-for-byte at
`DanTerm.app/Contents/Resources/terminal-capabilities-v1.json`.

The manifest records the exact terminfo claims needed by accepted workflows,
their macOS 26 ncurses 6.0 and current ncurses 1.1261 variants, supported and
denied protocol families, environment ownership, evidence suites, and numeric
limits. Applications should treat unlisted terminfo entries and protocols as
unsupported. An incompatible change will use a new manifest version.

## Child environment

DanTerm owns `TERM=xterm-256color`, `COLORTERM=truecolor`,
`TERM_PROGRAM=DanTerm`, and `TERM_PROGRAM_VERSION=<bundle-version>`. Pane launch
also owns `DANTERM`, `DANTERM_SOCK`, `DANTERM_PANE`, private `DANTERM_TOKEN`,
forwarded private `LC_DANTERM_TOKEN`, and the conditional private recovery-file
variable. Inherited collisions cannot override these values. The bundle version
is also the version returned by XTVERSION.

## Queries and semantic protocols

DanTerm supports the query, mode, keyboard, mouse, focus, title, cwd, hyperlink,
clipboard-write, shell-event, notification, progress, and bell families listed
under `protocols.supported`. The `protocols.denied` list is explicit, including
DA2, DECRQSS, XTGETTCAP, clipboard reads, Kitty OSC 99, OSC 133, 8-bit replies,
and audible or visual bell effects.

`CSI > q` and `CSI > 0 q` return `DCS >|DanTerm <version> ST`. The accepted
desktop notification forms are `OSC 9;<body>` and
`OSC 777;notify;<title>;<body>`. The OSC 777 body may contain semicolons.

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

The manifest's numeric limits are part of the public contract. In particular,
control strings retain at most 2 MiB encoded input; decoded clipboard writes
are limited to 1 MiB; a title, cwd, link, shell payload, or complete notification
title-plus-body is limited to 64 KiB; and pending query replies are limited to
64 KiB. Bell, shell, and notification events share a 100-event discrete queue.
Title, cwd, and progress coalesce to the newest complete value.

Metadata retention is split into 256 KiB engine, 256 KiB handoff, and 512 KiB
model shares. Scrollback is limited to 10 MiB and damage is bounded by current
grid state. Oversized or malformed input has no partial effect, does not retain
a second unbounded copy, and cannot prevent later valid input from being
processed. A query reply that cannot fit is dropped as one complete unit.
