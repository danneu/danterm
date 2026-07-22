# Asciinema Nested-PTY Compatibility Evidence - 2026-07-21

## Judgment

DanTerm's real `TerminalPaneSession` boundary records and locally replays an
interactive shell through asciinema's intermediate PTY. This Slice 3b evidence
adds nested-PTY confidence to Milestone 7 but closes no protocol, capability,
or black-box checkbox.

## Reproduction

Both required gates passed on 2026-07-21:

```sh
just test
nix develop .#terminal-workflows -c just test-terminal-workflows
```

The successful live run is preserved at
`.build/terminal-workflow-runs/20260722T024439Z-30416/` (the run id is UTC).
The asciinema directory contains `result.txt`, DanTerm's `recording.json`,
`snapshots.txt`, `semantic-events.txt`, `ownership.txt`, the generated
`session.cast`, and `cast-validation.txt`. The run remains a local diagnostic
artifact and is intentionally not checked in.

## Environment and cast contract

The run used macOS 26.5.2 on arm64 and asciinema 2.4.0 from the flake-locked
nixpkgs at
`/nix/store/b2p46smx00h26svnvds15kgn9gf97mvg-asciinema-2.4.0/bin/asciinema`.
The manifest records that path and `asciinema 2.4.0` version output.

The v2 cast validator accepted a version 2 header with 80x24 geometry,
`SHELL=/bin/zsh`, and `TERM=xterm-256color`. It observed 56 output events, 8
captured input events, and one resize event. The output stream contained the
exact `__ASCIINEMA_UTF8__=café-λ` marker inside cyan SGR 36/reset bytes, and
the resize payload was exactly `53x17`.

## Nested workflow observations

The outer isolated zsh launched quiet, overwriting, stdin-capturing recording
of `/bin/zsh -f`. The inner shell used the fixed `ASCIINEMA-INNER>` prompt and
did not load user configuration or DanTerm shell integration. Its foreground
job stopped on Ctrl-Z, resumed through `bg` and `fg`, terminated on Ctrl-C, and
returned the inner prompt after each transition. After the outer pane resized
from 80x24 to 53x17, `stty size` inside asciinema's PTY reported `17 53`.
Normal inner exit restored `DANTERM-WORKFLOW>`.

The outer pane then returned to 80x24 and played the cast locally with a
one-second idle bound and 20x timing. Playback reproduced the UTF-8 marker and
its recorded color semantics, completed normally, and restored the fixed outer
prompt with no stale style, cursor, or alternate-screen state.

## Ownership and deterministic coverage

The final census reports the asciinema recorder, inner shell, foreground job,
pane session, PTY owner, descriptors, and dispatch sources released. Failure
capture remains before teardown, so the same artifact family survives a live
failure.

`just test` covers missing-asciinema refusal, required version recording,
missing workflow artifacts, and synthetic valid and malformed v2 streams. The
cast tests separately reject missing output, input, and resize evidence. No
live failure exposed a terminal or lifecycle defect, so this slice promoted no
TerminalCore fixture.
