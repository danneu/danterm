# Milestone 7, Slice 4: Protocol and Capability Contract

## Summary

Publish and bundle a machine-readable DanTerm capability manifest v1 as the normative terminal contract. Keep `TERM=xterm-256color` as a compatibility selector, but claim only the exact capabilities required by accepted workflows and proven against both supported terminfo baselines.

Complete missing Swift-backend notification, progress, and XTVERSION behavior; reconcile cross-component limits; finish the Milestone 7 libvterm classifications; and close the roadmap checkbox. External real-pane probes remain Slice 5.

## Contract and Implementation Changes

- Add `terminal-capabilities-v1.json` and copy it byte-for-byte to `Contents/Resources/terminal-capabilities-v1.json`. The versioned schema records:
  - child environment and private integration variables
  - claimed terminfo capabilities and baseline-specific sequence variants
  - supported queries, modes, keyboard, mouse, focus, and semantic protocols
  - explicit denials and unsupported protocol families
  - externally meaningful limits and evidence identifiers
- Pin two normalized `xterm-256color` fixtures:
  - macOS 26's shipped ncurses 6.0 entry
  - the [official ncurses `terminfo.src`](https://invisible-island.net/ncurses/terminfo.src.html) revision 1.1261 dated 2026-07-19
- Limit terminfo claims to capabilities required by the accepted Milestone 7 workflows. Every claimed capability must have executable evidence against both fixtures; differing values must list and prove each required variant. Unclaimed database entries are not DanTerm promises.
- Preserve the fixed identity environment:
  - `TERM=xterm-256color`
  - `COLORTERM=truecolor`
  - `TERM_PROGRAM=DanTerm`
  - `TERM_PROGRAM_VERSION=<bundle version>`
  - documented `DANTERM`, `DANTERM_SOCK`, `DANTERM_PANE`, private `DANTERM_TOKEN`, forwarded `LC_DANTERM_TOKEN`, and conditional recovery-file semantics
- Make DanTerm-owned identity and pane variables override inherited collisions. The bundle version supplied to TerminalCore must be the same value used by `TERM_PROGRAM_VERSION`.
- Add XTVERSION support for `CSI > q` and `CSI > 0 q`, replying exactly `DCS >|DanTerm <version> ST`. Retain existing DA1, DSR, CPR/DECCPR, DECRQM, and Kitty-keyboard queries. Do not add DA2, DECRQSS, XTGETTCAP, or 8-bit reply modes.
- Extend the terminal semantic boundary with:
  - desktop notification events carrying title and body
  - progress events for set, indeterminate, error, pause, and removal
- Support only these existing notification/progress forms:
  - `OSC 9;<body>` -- notification with an empty title when the first field is not a reserved canonical numeric selector
  - `OSC 777;notify;<title>;<body>` -- body may contain later semicolons
  - `OSC 9;4;0` -- remove
  - `OSC 9;4;1;<0...100>` -- determinate
  - `OSC 9;4;2[;<0...100>]` -- error
  - `OSC 9;4;3` -- indeterminate
  - `OSC 9;4;4[;<0...100>]` -- pause
- Reserve the exact canonical first-field tokens `1` through `12` for ConEmu before considering OSC 9 notification fallback. Selector `4` is progress only when the complete payload matches one of the forms above; malformed selector-4 payloads are ignored. Every other reserved selector is ignored whether it appears alone or is followed by `;...`. Numeric-only or numeric-leading bodies outside the canonical `1` through `12` tokens remain ordinary notification bodies. Unknown notification variants and Kitty OSC 99 are ignored.
- Preserve current pane-scoped product behavior: focused active-pane suppression, background alerts, notification throttling and click navigation, progress chrome, title/cwd persistence, shell-event authentication, HTTP(S)-only links, write-only OSC 52, and BEL alerts without audio or visual flashing.

## Limits and Classifications

- Enforce the existing resource policy as one contract:
  - 2 MiB maximum pending encoded control string
  - 1 MiB maximum decoded OSC 52 write; reads denied
  - 64 KiB per title, cwd, link target, shell payload, or complete notification title-plus-body
  - 100 shared discrete pending bell, shell, and notification events
  - newest-value coalescing for title, cwd, and progress
  - 256 KiB engine metadata, 256 KiB handoff, and 512 KiB model retention shares
  - 64 KiB pending query replies, dropping a reply as a complete unit if it cannot fit
  - 10 MiB scrollback and bounded damage state
- Oversized or malformed input applies no partial effect, does not create a second unbounded copy, and cannot prevent later valid input from being processed.
- Resolve the remaining libvterm cases:
  - adapt XTVERSION to DanTerm's version reply
  - supersede cursor visibility and shape callback cases with public presentation and query evidence
  - adapt complete and split title writes to DanTerm's complete semantic-event contract
  - keep cursor blinking out of scope under the existing post-milestone deferral
  - supersede duplicate screen terminal-property cases with the same public evidence
- Update [Protocols and shell integration](/Users/dan/Code/danterm-terminal-engine/plan-terminal-engine/10-protocols-shell-integration.md), the open-question ledger, user-facing protocol documentation, and dated evidence. Check the Slice 4 roadmap item in [14-roadmap.md](/Users/dan/Code/danterm-terminal-engine/plan-terminal-engine/14-roadmap.md), leaving the external black-box item unchecked.

## Public Interfaces

- `TerminalSemanticEvent` gains desktop-notification and typed progress cases; TerminalPTY and the AppKit adapter preserve their order and map them into the existing backend-neutral session events.
- Terminal construction receives the injected DanTerm program version needed for the sent XTVERSION reply.
- The bundled `terminal-capabilities-v1.json` path and schema become a public, versioned artifact. Future incompatible contract changes create a new manifest version; no runtime lookup environment variable or CLI command is added.

## Test Plan

- Manifest validation proves schema/version correctness, unique claims, pinned fixture provenance, byte-identical bundle installation, and executable evidence for every claimed capability and limit.
- Terminfo conformance tests exercise output/state behavior, parameterized sequence expansions, key encodings, and every baseline-specific variant named by the manifest.
- Launch tests prove hostile inherited collisions cannot override DanTerm identity or private pane variables, and that `TERM_PROGRAM_VERSION` matches XTVERSION.
- TerminalCore tests cover exact notification/progress grammars, precedence for every reserved selector `1` through `12`, numeric-only and numeric-leading bodies, malformed selector-4 payloads, all terminators and chunk boundaries, UTF-8 validation, ordering, coalescing, count/byte overload, teardown, and recovery.
- Query tests cover exact XTVERSION bytes, existing query claims, unknown-query silence, the 64 KiB reply boundary, complete-reply dropping, drain recovery, and chunk invariance.
- Cross-layer tests include notification and progress in the existing engine/handoff/model overload proof and verify pane isolation through two concurrent sessions.
- Existing-behavior coverage remains gating for authenticated shell events, title, cwd, BEL, OSC 8 links, OSC 52 writes/read denial, alert routing, progress presentation, and post-teardown callback suppression.
- Run the targeted TerminalCore, TerminalPTY, DanTermCore, build-resource, and UI harnesses, followed by `just test` and `just test-ui`.

## Assumptions and Non-goals

- `xterm-256color` remains an intentionally partial compatibility identity; the manifest, not generic xterm behavior, is normative.
- No custom terminfo entry, OSC 133, OSC 99, clipboard-read permission, audible/visual bell, or new notification/progress protocol is introduced.
- esctest2, Termless, vttest/wraptest expansion, terminfo.dev, and other real-pane black-box probes remain Milestone 7 Slice 5.

## Commit progress

- [x] 1. Add bounded notification, progress, and XTVERSION semantics
- [x] 2. Publish and verify the terminal capability manifest
- [ ] 3. Close protocol documentation and fixture classifications
