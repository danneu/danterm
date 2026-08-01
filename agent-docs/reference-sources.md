# Reference sources

External sources to consult when implementing against the libghostty C API
or referencing other terminals' approaches.

## Ghostty source

The Ghostty source is cloned locally at `.ghostty-src/` (by `build-lib.sh`).
When you need to reference the libghostty C API, read these files directly
instead of making web requests:

- `.ghostty-src/include/ghostty.h` -- full C API header (types, structs,
  functions).
- `.ghostty-src/macos/Sources/Ghostty/` -- Ghostty's own macOS Swift app
  (reference implementation).
- `.ghostty-src/src/apprt/embedded.zig` -- embedded runtime (implements the
  C API).

For any other external library, clone it locally first so you can read it
directly. Never use web requests to read source code when a local clone is
available.

## Local reference checkouts

The following pinned source trees are materialized under `references/`:

- [`references/libvterm/`](../references/libvterm/) -- Parser, state,
  scrollback, and resize/reflow behavior for neutral fixtures.
- [`references/alacritty/`](../references/alacritty/) -- Terminal recordings
  and replay-runner cases for neutral fixtures.
- [`references/kitty/`](../references/kitty/) -- The graphics, keyboard, and
  shell-integration protocols kitty authored (`docs/`), beside the C parser
  and screen that implement them, and `kitty_tests/` -- the suite that
  exercises the author's own protocols, which is where their edge cases are
  written down (`kitty_tests/screen.py#test_prompt_marking` for OSC 133
  regions, `kitty_tests/shell_integration.py` for real shells in a PTY).
- [`references/wezterm/`](../references/wezterm/) -- Escape parsing
  (`vtparse`, `wezterm-escape-parser`), the cell/surface model, and reflow in
  an engine split from its renderer the way DanTerm's is.
- [`references/iterm2/`](../references/iterm2/) -- The other macOS terminal:
  AppKit surface, PTY handling, and the OSC 133/1337 dialects iTerm2
  originated.
- [`references/vte/`](../references/vte/) -- GNOME's terminal widget, the most
  conformance-driven of the set: sequence tables, ring buffer, test corpus.
- [`references/foot/`](../references/foot/) -- A small, fast C terminal whose
  grid, scrollback, and damage tracking are readable end to end.
- [`references/tmux/`](../references/tmux/) -- Screen model, resize/reflow, and
  capability negotiation from the layer that both drives and emulates a
  terminal.
- [`references/xterm/`](../references/xterm/) -- `ctlseqs.ms`, the de facto
  sequence specification, beside the implementation everything else is
  measured against.
- [`references/windows-terminal/`](../references/windows-terminal/) -- A
  state-machine VT parser with an unusually complete conformance suite
  (`src/terminal/parser`, `src/terminal/adapter`) and written specs in `doc/`.
- [`references/xnu/`](../references/xnu/) -- Darwin kernel process, signal,
  tty, and Mach behavior.
- [`references/libdispatch/`](../references/libdispatch/) -- Dispatch queue,
  continuation, and work-item implementation details.
- [`references/libpthread/`](../references/libpthread/) -- Darwin pthread
  lifecycle, cancellation, and synchronization behavior.
- [`references/libplatform/`](../references/libplatform/) -- Apple platform
  primitives used below dispatch and pthread.
- [`references/Libc/`](../references/Libc/) -- Darwin C runtime, process,
  signal, and terminal interfaces.
- [`references/objc4/`](../references/objc4/) -- Objective-C runtime ownership,
  teardown, and message dispatch behavior.
- [`references/fish-shell/`](../references/fish-shell/) -- prompt repaint on
  SIGWINCH, `fish_handle_reflow` auto-detection, and the OSC 133 marks fish
  emits with no integration loaded.
- [`references/zsh/`](../references/zsh/) -- prompt redisplay and expansion,
  which decide whether marks embedded in `PS1` survive a repaint.
- [`references/bash/`](../references/bash/) -- readline redisplay after
  SIGWINCH, which decides how much of a Bash prompt may be blanked.
- [`references/starship/`](../references/starship/) -- the cross-shell prompt a
  large share of users actually run: multi-line and right prompts, transient
  prompts, and the per-shell init hooks (`src/init/`) it wraps the shells' own
  marks in.

The three shells are pinned at the versions DanTerm's shell-integration
research measured (fish 4.7.1, zsh 5.9, bash 5.3). A shell's *behavior* is
still established by probing a real binary in a real PTY -- these checkouts
explain a measurement or pick the next probe, and are not a substitute for one.

These directories are gitignored and absent from a fresh clone. If a source
tree is missing, run `just fetch-references [name]` and read it locally instead
of fetching individual files over the web. Run `just fetch-references --list`
to see the available names and their pinned commits.

Do not edit these checkouts. A refetch replaces an entry wholesale, so local
changes are lost.

Cite refetchable source as `file#identifier`, using the nearest enclosing named
identifier when the point itself has no name. Do not cite it as `file:line`:
line numbers rot when a pin advances, while named identifiers usually survive.
DanTerm's own tracked files still use `file:line`, because Git preserves the
version that a citation describes.

### Adapting an upstream test

A test adapted from a pinned suite carries its citation in the preamble, as the
section after the AGENTS.md `Intent / Why it exists / Scenario` block:

```swift
// Adapted from kitty_tests/datatypes.py#test_rewrap_narrower
//   (kitty v0.48.2 2cb1d95, body sha256:ab12cd34ef56).
//   Divergence: asserts logical text and `isSoftWrapped`, not LineBuf.is_continued.
```

The hash covers the upstream test's body -- its `def` line down to the next
same-or-lower-indented `def`/`class` -- so a pin bump surfaces upstream revisions
as a lint failure instead of as silent compatibility drift. It lives in the
comment rather than a side manifest, so there is exactly one source of truth and
nothing to desync.

`Divergence:` is required, `Divergence: none` included. We adopt an upstream
suite's *scenarios*, never its assertions: it asserts through APIs DanTerm does
not have, and its verdict on a behavior is not automatically ours. A citation
with no `Divergence:` line is an unstated claim of assertion-level parity.

`scripts/kitty-parity-lint.py` enforces all of that in the `just test` gate: the
citation resolves to a real `def`, the commit is the current pin, the hash
matches, and the `Divergence:` line exists. It exits 0 with a printed reason when
`references/kitty` is absent, since a fresh clone has no checkout.

## Other terminals

Nine terminal emulators are pinned above (`kitty`, `wezterm`, `iterm2`, `vte`,
`foot`, `xterm`, `tmux`, `windows-terminal`, `alacritty`) alongside `libvterm`
and `.ghostty-src/`. Reach for them when the question is "how does a real
terminal handle this" -- an ambiguous sequence, a resize/reflow corner, a
protocol DanTerm has not implemented yet. Two or three independent
implementations agreeing is the closest thing to a spec for behavior `ctlseqs`
leaves undefined; where they disagree, that disagreement is itself the finding.

Not checked out, but worth a web lookup for feature work:

- `github:manaflow-ai/cmux` -- another macOS terminal built on libghostty
  (vertical tabs, AI agent notifications).

## Don't-guess rule

Don't guess at API signatures, delegate protocols, enum cases, or framework
behavior. Check local sources first; if insufficient, search online and read
official docs before writing code. AGENTS.md surfaces this rule in
`## Boundaries` so the agent sees it before diving in -- this file holds
the full context.
