# OSC 10/11 Default-Color Queries

## Problem

Swift-engine panes do not answer `OSC 10;?` or `OSC 11;?`, so applications
that discover the terminal's default foreground and background cannot adapt
their presentation. Codex v0.146.0 is the observed failure: its composer uses
`codex-rs/tui/src/terminal_palette.rs#default_bg` and
`codex-rs/tui/src/style.rs#user_message_style_for` to derive a contrasting
input background only when the terminal reports its defaults. The unanswered
probe therefore makes the composer visually merge with DanTerm's background.

The renderer already has the relevant colors in its explicit `RenderTheme`,
and the terminal core already owns the bounded, ordered reply channel. What is
missing is one neutral definition of the baked defaults that both protocol and
presentation can consume without making the core depend on rendering or
ambient AppKit state.

Desired outcome: applications receive accurate default-color replies from a
Swift-engine pane, while the reported colors and the colors actually drawn for
that pane cannot drift.

## Decision

Support the read-only xterm dynamic-color query forms `OSC 10;?` and
`OSC 11;?`. They report the pane's current default foreground and background,
respectively, as canonical 7-bit replies:

```text
OSC 10;rgb:rrrr/gggg/bbbb ST
OSC 11;rgb:rrrr/gggg/bbbb ST
```

Each 8-bit sRGB component is expanded to 16 bits by repeating the byte, and
replies use 7-bit `ST` regardless of whether the accepted request ended with
BEL or `ST`. This is externally visible wire behavior and joins the capability
contract.

Define the neutral baked default foreground/background pair once in
TerminalCore as pure data. Terminal query replies use that pair, while
`RenderTheme.dark` derives its default foreground and background from the same
definition. Render planning already depends on TerminalCore, so the dependency
continues in its existing direction; TerminalCore imports no renderer policy.
The pre-frame pane fill already consumes `RenderTheme.dark`, so all three
observable uses share one definition without a new pane-boundary wiring path.

OSC 10/11 setting forms are ignored. Dynamic color mutation would require a
separate decision about application-owned theme overrides, redraw, reset, and
lifetime semantics; none of that is necessary to answer discovery queries.

The capability and its evidence are added to `docs/terminal-capabilities.md`.

## Invariants

- **I1** `OSC 10;?` and `OSC 11;?` report exactly the default foreground and
  background currently used to present that pane.
- **I2** The baked default colors have one neutral pure-data definition in
  TerminalCore. TerminalCore has no dependency on TerminalRenderPlanning,
  AppKit, or ambient theme state.
- **I3** A color query changes no grid, cursor, style, damage, semantic event,
  clipboard, or presentation state; it only appends one complete reply to the
  existing bounded reply stream.
- **I4** Replies retain terminal-stream order with other terminal-generated
  replies and travel through the existing PTY write path.
- **I5** Malformed queries, unsupported selectors, OSC 10/11 setting forms, and
  reset forms remain bounded, silent no-ops that do not block later valid
  input.
- **I6** A complete color reply is admitted or dropped atomically under the
  existing 64 KiB per-pane reply limit.

## Proof obligations

- **PO1** (I1, I3) The baked foreground and background produce the exact
  canonical OSC 10 and OSC 11 replies, with no other terminal state change
  after the replies are drained.
- **PO2** (I1, I2) One equality proof ties OSC 10/11's reported defaults to
  `RenderTheme.dark` and the planned frame defaults, so changing the shared
  source changes protocol and presentation together rather than preserving
  three independently repeated literals.
- **PO3** (I3, I4) Interleaved OSC color and existing terminal queries produce
  one correctly ordered reply stream, and a real PTY child receives that stream
  through the established reply-write path.
- **PO4** (I3, I5) BEL- and `ST`-terminated requests, arbitrary input chunk
  boundaries, malformed payloads, setting/reset forms, and recovery to a later
  valid query preserve the parser and terminal invariants.
- **PO5** (I6) Repeated color queries obey complete-reply admission at the
  existing reply bound and resume after the reply stream is drained.
- **PO6** The public capability contract names default foreground/background
  queries and their behavioral evidence without claiming dynamic color setting.
- **PO7** In the accepted Codex workflow, the current Codex TUI discovers both
  defaults and renders its composer background distinct from the pane's default
  background. This is an end-to-end compatibility check in addition to the
  deterministic protocol proofs, not a screenshot-only substitute for them.

## Non-goals

- OSC 10/11 color setting, OSC 110/111 reset, palette queries, or cursor-color
  queries.
- Multi-resource dynamic-color queries such as `OSC 10;?;?`; the supported
  forms are exactly the single-resource `OSC 10;?` and `OSC 11;?` queries.
- A user-facing theme format, preferences UI, or live theme switching.
- Matching libghostty's configurable query precision or every xterm dynamic-
  color extension.
- Changing Codex's color blending or hard-coding a Codex-specific composer
  color in DanTerm.

## Rejected ideas

- **Have the AppKit view answer the query.** PTY replies would bypass the pure,
  ordered terminal reply channel and make behavior depend on UI lifetime.
- **Keep independent baked RGB values in TerminalCore and render planning.** A
  second definition could drift; the renderer instead derives its defaults
  from the core's neutral definition.
- **Make TerminalCore depend on `RenderTheme`.** That reverses the existing
  dependency direction: render planning consumes terminal state, while terminal
  semantics remain independently testable.

## Implementation discretion

- The neutral RGB value representation and internal declaration placement for
  the shared baked defaults.

## Implementation notes

- Live acceptance on 2026-07-31 used Codex CLI 0.146.0 in a Swift-backend
  DanTerm Dev pane; the user confirmed that the composer background is now
  visually distinct from the pane's default background.
