# Terminal Capability Contract Evidence - 2026-07-21

## Judgment

DanTerm's Milestone 7 protocol and capability tranche is closed at the native,
deterministic boundary. The versioned manifest is bundled byte-for-byte, every
claimed terminfo capability is checked against both pinned baselines, and the
advertised environment, queries, semantic protocols, and cross-component limits
have executable evidence. The separate real-pane external black-box tranche
remains open.

## Contract and provenance

[`terminal-capabilities-v1.json`](../../terminal-capabilities-v1.json) is the
normative artifact. Its fixtures capture macOS 26's ncurses 6.0
`xterm-256color` entry and official ncurses `terminfo.src` revision 1.1261 dated
2026-07-19. `TerminalCapabilityManifestTests` validates schema version,
provenance, unique claims, fixture coverage, baseline variants, evidence names,
environment ownership, key encodings, and numeric limits.

The dev and release build contracts copy the repository artifact unchanged and
verify the bundled or archived copy with `cmp`. Launch-policy tests prove that
hostile inherited values cannot replace the fixed terminal identity or private
pane variables, and that the version used for `TERM_PROGRAM_VERSION` is the
version injected into TerminalCore for XTVERSION.

## Behavioral evidence

TerminalCore suites cover DA1, DSR, CPR/DECCPR, DECRQM, Kitty keyboard queries,
and the exact DanTerm XTVERSION reply while keeping DA2, DECRQSS, XTGETTCAP, and
8-bit replies silent. Notification and progress tests cover the accepted OSC 9
and OSC 777 grammar, reserved-selector precedence, all terminators, chunking,
UTF-8 rejection, ordering, coalescing, overload, teardown, and recovery.

The metadata integration suites carry notification and progress events through
the engine, handoff, and model shares under byte and count pressure. TerminalPTY
tests prove ordering and isolation across concurrent sessions. Existing suites
continue to gate authenticated shell events, title, cwd, BEL, HTTP(S) links,
OSC 52 writes and read denial, pane alert routing, progress presentation, and
post-teardown callback suppression.

The libvterm ledger now adapts XTVERSION and complete or split title writes,
supersedes callback-only cursor presentation and duplicate screen-property
cases with public evidence, and retains timed cursor blinking as the explicit
post-milestone deferral.

## Reproduction

The closing gate is:

```sh
swift test --package-path lib/TerminalCore
swift test --package-path lib/TerminalPTY
just test
just test-ui
```

The external real-pane probes in the next roadmap item are not evidence for
this judgment and remain unchecked.
