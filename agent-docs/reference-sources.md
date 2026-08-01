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

Pinned source trees under `references/`. They are gitignored and absent from a
fresh clone: run `just fetch-references [name]` (`--list` shows names and pinned
commits) and read locally instead of fetching files over the web. Do not edit
them -- a refetch replaces an entry wholesale.

Terminals -- reach for these when the question is "how does a real terminal
handle this": an ambiguous sequence, a resize/reflow corner, a protocol DanTerm
has not implemented yet. Two or three independent implementations agreeing is
the closest thing to a spec for behavior `ctlseqs` leaves undefined; where they
disagree, that disagreement is itself the finding.

| Tree | Read it for |
| --- | --- |
| `libvterm` | Parser, state, scrollback, resize/reflow for neutral fixtures. |
| `alacritty` | Terminal recordings and replay-runner cases for neutral fixtures. |
| `kitty` | The graphics/keyboard/shell-integration protocols kitty authored (`docs/`), the C parser and screen implementing them, and `kitty_tests/` where their edge cases are written down (`kitty_tests/screen.py#test_prompt_marking` for OSC 133 regions, `kitty_tests/shell_integration.py` for real shells in a PTY). |
| `wezterm` | Escape parsing (`vtparse`, `wezterm-escape-parser`), cell/surface model, and reflow in an engine split from its renderer the way DanTerm's is. |
| `iterm2` | The other macOS terminal: AppKit surface, PTY handling, and the OSC 133/1337 dialects it originated. |
| `vte` | GNOME's widget, the most conformance-driven of the set: sequence tables, ring buffer, test corpus. |
| `foot` | A small, fast C terminal whose grid, scrollback, and damage tracking are readable end to end. |
| `tmux` | Screen model, resize/reflow, and capability negotiation from the layer that both drives and emulates a terminal. |
| `xterm` | `ctlseqs.ms`, the de facto sequence specification, beside the implementation everything else is measured against. |
| `windows-terminal` | State-machine VT parser with an unusually complete conformance suite (`src/terminal/parser`, `src/terminal/adapter`) and written specs in `doc/`. |

Shells -- pinned at the versions DanTerm's shell-integration research measured
(fish 4.7.1, zsh 5.9, bash 5.3). A shell's *behavior* is still established by
probing a real binary in a real PTY; these explain a measurement or pick the
next probe, and never substitute for one.

| Tree | Read it for |
| --- | --- |
| `fish-shell` | Prompt repaint on SIGWINCH, `fish_handle_reflow` auto-detection, and the OSC 133 marks fish emits with no integration loaded. |
| `zsh` | Prompt redisplay and expansion, which decide whether marks embedded in `PS1` survive a repaint. |
| `bash` | Readline redisplay after SIGWINCH, which decides how much of a Bash prompt may be blanked. |
| `starship` | The cross-shell prompt a large share of users actually run: multi-line and right prompts, transient prompts, and the per-shell init hooks (`src/init/`) it wraps the shells' own marks in. |

Darwin -- `xnu` (kernel process, signal, tty, Mach), `Libc` (C runtime, process,
signal, terminal interfaces), `libdispatch` (queues, continuations, work items),
`libpthread` (thread lifecycle, cancellation, synchronization), `libplatform`
(primitives below dispatch and pthread), `objc4` (runtime ownership, teardown,
message dispatch).

Swift -- `swift-collections`, at the release SwiftPM would resolve today
(1.6.0). Taking it as a real dependency is encouraged wherever one of its
containers fits: reach for `Deque` (`Sources/DequeModule`),
`OrderedSet`/`OrderedDictionary`, `BitSet`/`BitArray`, `Heap`, or `BigString`
(`Sources/RopeModule`) in preference to a hand-rolled equivalent, and pin the
version `references/` pins so the source you read matches the code you build.
Read the checkout when picking a container and while using one: API and
complexity guarantees, and how it stays fast (`@inlinable`, unsafe buffer
access, COW).

Also worth a web lookup, not checked out: `github:manaflow-ai/cmux`, another
macOS terminal built on libghostty (vertical tabs, AI agent notifications).

## Citing reference source

Cite refetchable source as `file#identifier`, using the nearest enclosing named
identifier when the point itself has no name. Not `file:line`: line numbers rot
when a pin advances, while named identifiers usually survive. DanTerm's own
tracked files still use `file:line`, because Git preserves the version a
citation describes.

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

## Don't-guess rule

Don't guess at API signatures, delegate protocols, enum cases, or framework
behavior. Check the local sources above first; if they're insufficient, search
online and read official docs before writing code.
