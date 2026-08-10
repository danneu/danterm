# Legacy Shift+Enter sends LF so composers insert a newline

## Problem

In a Swift-engine pane, Shift+Enter in Claude Code submits the message instead
of inserting a newline. In a libghostty pane it inserts a newline: ghostty
advertises `TERM_PROGRAM=ghostty`, which is on Claude Code's allowlist, so
Claude Code negotiates the kitty keyboard protocol there and the chord never
reaches the legacy encoder.

The engine encodes Shift+Enter correctly under the kitty keyboard protocol
(`CSI 13;2u`, pinned by `TerminalKittyKeyboardTests`), but Claude Code never
turns the protocol on for us: it decides from a hardcoded env allowlist that
DanTerm is not on, never sends `CSI ? u`, and exposes no override. So the pane
stays in legacy mode, where `encodeLegacyKey` drops Shift and sends bare `CR` --
which every composer reads as submit.

The fix is on our side of the wire: in legacy mode, send the byte that means
"line feed" instead of the byte that means "return".

Evidence (PTY probes against `claude` 2.1.220 and `vim`, launched with DanTerm's
current advertised env so the kitty protocol stays off; probes typed `AAAA`,
sent the candidate bytes, typed `BBBB`, and read the resulting screen/file):

| bytes for Shift+Enter | `claude` (legacy) | vim insert mode | bash / zsh |
|---|---|---|---|
| `CR` (today) | submits | newline | `accept-line` |
| `ESC CR` (meta-Enter) | newline | exits insert mode, drops following input | bash: unbound; zsh: `self-insert-unmeta` |
| `LF` | newline | newline | `accept-line` (`^J`) |

Load-bearing premises:

- `LF` is what ghostty's own users are told to bind for this
  (`keybind = shift+enter=text:\n`), so this is the conventional fix rather
  than a DanTerm invention.
- Both shells bind `^J` and `^M` to `accept-line`, so moving Shift+Enter from
  `CR` to `LF` leaves shell behavior where it is today.
- Alt+Enter already emits `ESC CR` (`TerminalInputEncoding.swift:320`), which
  already inserts a newline in Claude Code today. The bug is a wrong default,
  not a missing capability.

## Decision

In legacy mode, one complete rule governs `returnKey`:

1. Shift selects `LF` (`0x0A`); without Shift the byte is `CR`, or `CR LF`
   under LNM (mode 20), exactly as today.
2. Control does not participate -- it is ignored with or without Shift, as it
   is today.
3. Alt prefixes whatever step 1 selected with `ESC`, the same prefix rule every
   other legacy key follows.

So Shift+Enter is `LF`, Control+Shift+Enter is `LF`, Alt+Shift+Enter is
`ESC LF`, and Control+Alt+Shift+Enter is `ESC LF`, under every mode combination.

LNM applies only to non-Shift Return. Under LNM plain Enter transmits `CR LF`;
emitting that for Shift+Enter would put a `CR` on the wire first and submit,
defeating the whole point. Shift+Enter is an explicit "insert a line feed"
affordance, not the return key's newline semantics.

Kitty-mode encoding is untouched: when a program turns the protocol on it still
gets `CSI 13;2u`, so nothing changes for nvim, helix, or anything else that
negotiates.

## Invariants

- **I1** In legacy mode, any Return chord containing Shift encodes `[0x0A]`,
  prefixed by `ESC` when Alt is held, under every mode combination including
  LNM and application cursor/keypad modes.
- **I2** Kitty-mode Shift+Enter still encodes `CSI 13;2u`, and no Shift-free
  legacy key encoding moves -- unmodified, Control, and Alt Enter keep their
  current bytes.
- **I3** The normative input contract in
  `plan-terminal-engine/08-input-interaction.md` states the legacy Shift+Enter
  encoding, since it is the one place legacy key behavior is specified.

## Proof obligations

- **PO1** (I1) Behavioral coverage of the legacy Return chords: Shift alone and
  Shift+Control encode `LF`; Shift+Alt and Shift+Control+Alt encode `ESC LF`;
  Shift under LNM combined with application cursor/keypad modes still encodes
  `LF`. LNM is the case that would silently regress to `CR LF`
  and resume submitting; the Control and Alt chords are what pin the precedence
  rule rather than one implementer's reading of it.
- **PO2** (I2) The existing legacy Return/Tab/Backspace matrix and the kitty
  flag-1 matrix in `TerminalKeyEncodingTests` still pass unchanged.
- **PO3** End-to-end, manual: run `claude` in a Swift-backend pane, press
  Shift+Enter, confirm a newline; press Enter, confirm it still submits.

## Files

- `lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift` -- the
  legacy key encoder.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalKeyEncodingTests.swift` --
  PO1 coverage.
- `plan-terminal-engine/08-input-interaction.md` -- the keyboard subsection.

## Non-goals

- Changing any advertised environment variable, `TERM`, or the XTVERSION
  identity.
- A config surface for terminal key bindings.
- Branching key encoding on which program a pane is running.
- Mirroring the behavior into the shipping libghostty backend.

## Accepted risks

- **AR1** Shift+Enter changes for every legacy-mode program, not just Claude
  Code. Shells and vim are probe-verified unaffected, but a program doing raw
  byte reads that distinguishes `CR` from `LF` would see the difference.
  Accepted: `LF` is the conventional binding for this key, and any program that
  cares about the distinction can negotiate the kitty protocol and get
  `CSI 13;2u`.
- **AR2** The two backends diverge for legacy-mode programs: a libghostty pane
  sends `CR` on Shift+Enter to anything that has not negotiated the kitty
  protocol, where the Swift engine will send `LF`. For Claude Code specifically
  they converge on inserting a newline, by different routes. Accepted: the
  Swift engine is replacing that backend, and the divergence is in the better
  direction.

## Rejected ideas

- **RI1** Advertise `TERM_PROGRAM=ghostty` from the Swift engine's pane launch
  (the originally planned fix, superseded by this one). It works -- probes
  confirm Claude Code enables the kitty protocol for any `ghostty` version --
  but it fixes the symptom by lying about DanTerm's identity to every program
  that reads `TERM_PROGRAM`, buys a README `## Hacks` entry, two accepted risks
  about capability sniffing, and a deletion condition that waits on an upstream
  change. The LF encoding fixes the same symptom with no identity claim and no
  removal condition.
- **RI2** `ESC CR` for Shift+Enter. Also makes Claude Code insert a newline,
  but the vim probe is disqualifying: it drops out of insert mode and executes
  the following keystrokes as normal-mode commands. `LF` is strictly better on
  every measured axis.
- **RI3** `TERM=xterm-kitty` or `TERM=xterm-ghostty`. Claims terminfo capability
  sets the engine has not been tested against and requires that terminfo to
  exist on every SSH target.
- **RI4** A config key (`shift-enter = ...`) so users can choose the bytes.
  There is no terminal-keybinding config surface today (`DanTermConfig` holds
  two app-level keys), and inventing one to hold a single value whose correct
  setting is known is more mechanism than the problem carries. Revisit if a
  second binding wants the same surface.
- **RI5** Document Alt+Enter and change nothing. It already works, so this is
  the zero-code answer, but it leaves the muscle-memory key doing the wrong
  thing and every user pays the discovery cost forever.
- **RI6** Wait for Claude Code to probe `CSI ? u` or allowlist DanTerm. Correct
  fix, wrong timescale, and unlike RI1 this plan does not need it to land --
  the LF encoding is right on its own terms and stays right afterward.

## Verification

- `swift test --package-path lib/TerminalCore --filter TerminalKeyEncodingTests`
  for PO1/PO2, then `just test`.
- Build the Swift-backend dev app, open a pane, run `claude`: Shift+Enter
  inserts a newline, Enter still submits (PO3). In the same pane, `vim` in
  insert mode still inserts a newline on Shift+Enter.
