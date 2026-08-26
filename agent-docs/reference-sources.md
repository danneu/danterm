# Reference sources

External sources to consult when referencing another terminal's approach, the
engine DanTerm used to run on, or a platform library's real behavior.

For any external library not listed here, clone it locally first so you can read
it directly. Never use web requests to read source code when a local clone is
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
| `ghostty` | The engine DanTerm ran on before its own, pinned at the last version it shipped (v1.3.1): `src/terminal/` for the grid, parser, and reflow the Swift engine replaced, `include/ghostty.h` and `src/apprt/embedded.zig` for the embedding API, `macos/Sources/Ghostty/` for its AppKit surface. |
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
signal, terminal interfaces), `libinfo` (`getaddrinfo` itself: address-family
selection, sort order, and the NAT64 synthesis that rewrites IPv4 literals on
IPv6-only networks -- `lookup.subproj/si_getaddrinfo.c`), `libdispatch` (queues,
continuations, work items), `libpthread` (thread lifecycle, cancellation,
synchronization), `libplatform` (primitives below dispatch and pthread), `objc4`
(runtime ownership, teardown, message dispatch).

Linux -- `glibc`, the C library the GTK4 port targets. Read it to settle how a
POSIX type or constant differs from Darwin's at the same call site, rather than
assuming the spelling carries over: `struct addrinfo` orders `ai_addr` and
`ai_canonname` the opposite way (`resolv/netdb.h`), and `SOCK_STREAM` is an
enum member, not an int macro (`sysdeps/unix/sysv/linux/bits/socket_type.h`).

Swift -- `swift-collections`, at the release SwiftPM would resolve today
(1.6.0). Taking it as a real dependency is encouraged wherever one of its
containers fits: reach for `Deque` (`Sources/DequeModule`),
`OrderedSet`/`OrderedDictionary`, `BitSet`/`BitArray`, `Heap`, or `BigString`
(`Sources/RopeModule`) in preference to a hand-rolled equivalent, and pin the
version `references/` pins so the source you read matches the code you build.
Read the checkout when picking a container and while using one: API and
complexity guarantees, and how it stays fast (`@inlinable`, unsafe buffer
access, COW).

Also worth a web lookup, not checked out: `github:manaflow-ai/cmux`, a macOS
terminal built on libghostty with the closest feature overlap to DanTerm
(vertical tabs, AI agent notifications).

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

Alacritty has the same arrangement in `scripts/alacritty-parity-lint.py`, with
two differences. The citation has no release tag, because the pin is not a
release -- `(alacritty 852e971c, body sha256:...)`. And the hash covers the `fn`
line through its *balance-matched* closing brace, so edits to neighbouring tests
and to the attributes between them do not churn it.

That lint also checks a second artifact kitty has no counterpart for:
`lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/alacritty-inline-manifest.json`
gives every one of the 135 inline `#[test]` functions under
`alacritty_terminal/src` a disposition and a rationale. Its whole value is being
complete -- a grouped rationale like "the storage cases are all internal" is fine,
but it must not hide a name -- so the lint compares it name-by-name against the
pinned checkout in both directions, and requires the `adapted` entries and the
Swift citations to agree about what was ported. Do not confuse it with
`alacritty-manifest.json`, which classifies the 45 `tests/ref/` *recording*
directories: different population, different schema.

### The mutation bar

Adoption requires more than "the scenario is reachable". Each retained case must
fail independently: mutate DanTerm to break the behavior the case asserts, run
the package suite in full, and confirm no existing test already caught the
mutation. A case an existing test catches is `superseded`, not `adapted`. Prefer
this method over counting ported tests -- the Alacritty inline manifest's
`method` field states it, and three of its four probed candidates survived the
check while the fourth did not.

Three rules make the bar reliable, and all three were paid for (`research/36/D3`).

- **Reading cannot settle a census.** Reading test titles against engine source
  is the cheap filter that decides what to mutate, never the verdict. Six of
  eleven candidates in one census were falsified at the mutation bar, and three
  of those fell to *replayed fixtures*: a fixture asserts a whole projection at
  once and names nothing, so no amount of reading finds it. The error runs both
  ways -- an earlier charset pass read three cases as covered when they were not.
- **Probe-verify before you trust a SURVIVED result.** An inert mutation and an
  uncaught mutation both present as "suite green". Confirm the mutation actually
  changes the behavior -- a direct probe of the mutant -- before you credit the
  green. One candidate needed a two-site mutation before its regression
  reproduced at all, because a recovery path rebuilt the state the single-site
  mutation cleared. Reporting the single-site run would have adopted a test for
  an unbreakable behavior.
- **Let the mutation dictate the test's shape.** Write the test from the
  regression it must catch, not from the upstream case's title. For all five
  survivors of that census the obvious test passed against the mutant: the
  affected keys had to be asserted unmodified, Ctrl+`@` on `@` rather than on
  Space, and a Shift-only row with Shift alone. A test that passes for the wrong
  reason is worse than no test.

Run mutation probes in an isolated worktree
([worktree-development.md](worktree-development.md)). Two probes in one tree can
revert each other's mutation and produce a false green.

## Don't-guess rule

Don't guess at API signatures, delegate protocols, enum cases, or framework
behavior. Check the local sources above first; if they're insufficient, search
online and read official docs before writing code.

## Citing a reference tree

Cite refetchable source trees as `file#identifier`, never `file:line`; use the
nearest enclosing named identifier when the point itself is unnamed. This form
is for external trees under `references/`. DanTerm's own documents use the forms
in [citing-docs.md](citing-docs.md).

## How much weight source carries

Rules for how much weight source carries, and how you turn a probe into a
finding:

- **Source picks the probe; it does not replace running one.** A shell's
  behavior is established by a real binary in a real PTY, and a terminal's by
  feeding bytes to `TerminalCore.Terminal`. Reading the code tells you which
  experiment to run.
- **Reproduce from bytes, not from the GUI.** When an application misbehaves in
  a pane, capture its byte stream and replay it into `TerminalCore` headlessly:
  `danterm pane tape` for anything reproducible live, or a `pty.fork()` harness
  when the stimulus is one the GUI cannot issue -- a synthetic `SIGWINCH`, a
  specific `TIOCSWINSZ` geometry. Mark the byte offset of the stimulus so the
  capture splits into before and after halves, then confirm the cause by
  ablation: strip one sequence from the replay and show the symptom disappears.
  A cause you have not ablated is a hypothesis.
- **References are input, not authority.** On compatibility -- what a sequence
  does, what a shell emits -- match them; that's the requirement. On design --
  data model, where state lives, API shape -- they are only ideas: take the edge
  cases they found, then build the simplest ideal solution for DanTerm. Their
  structure encodes their history, not our constraints. "Ghostty does X" is not
  a rationale.
