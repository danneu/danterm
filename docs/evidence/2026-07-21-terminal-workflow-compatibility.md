# Terminal Workflow Compatibility Evidence - 2026-07-21

## Judgment

DanTerm's real TerminalPTY/TerminalPaneSession boundary completes the minimum
zsh, Bash, fish, ssh, fzf, more, and less workflows in
[Testing and conformance](../../plan-terminal-engine/12-testing-conformance.md).
This closes only the baseline application workflow item in Milestone 7. It does
not claim the protocol/capability or external black-box tranches.

## Reproduction

The deterministic gate and the flake-pinned live gate passed on 2026-07-21:

```sh
just test
nix develop .#terminal-workflows -c just test-terminal-workflows
```

The successful live run is preserved at
`.build/terminal-workflow-runs/20260722T022229Z-12432/` (the run id is UTC).
Each application directory contains `result.txt`, `recording.json`,
`snapshots.txt`, `semantic-events.txt`, and `ownership.txt`. The run root also
contains the environment manifest, isolated home and SSH configuration, runner
output, and SSH server log. These build artifacts are local and intentionally
not checked in.

## Environment

The run used macOS 26.5.2 on arm64 with Apple Swift 6.3.3. The pinned workflow
shell supplied fish 4.5.0 and fzf 0.70.0. System applications were zsh 5.9,
Bash 3.2.57, OpenSSH 10.2p1 with LibreSSL 3.3.6, and more/less 668. Exact paths
and full first-line version output are in `environment.txt`.

The initial terminal geometry was 80 columns by 24 rows. Shell workflows
resized to 47 by 13, SSH propagated 43 by 12 and then 101 by 37 to the remote
helper, fzf resized to 52 by 16, and each pager resized to 49 by 14.

## Results

| Application | Result | Observed contract |
|---|---|---|
| zsh | Pass | Exact cursor-edited pipeline output, Unicode completion, stop/bg/fg/interrupt job control, 47x13 child geometry, prompt recovery |
| Bash | Pass | Exact cursor-edited pipeline output, Unicode completion, stop/bg/fg/interrupt job control, 47x13 child geometry, prompt recovery |
| fish | Pass | Exact cursor-edited pipeline output, Unicode completion, stop/bg/fg/interrupt job control, 47x13 child geometry, prompt recovery |
| ssh | Pass | Marker-enabled remote shell events, magenta Unicode output, 43x12 and 101x37 remote geometry, normal disconnect and local prompt recovery |
| fzf | Pass | Unicode filtering, navigation to the non-default Greek-beta-plus-`ravo` candidate, resize, accept, alternate-screen and prompt recovery |
| more | Pass | Long Unicode corpus search, forward/backward navigation across resize, quit and prompt recovery |
| less | Pass | Long Unicode corpus search, forward/backward navigation across resize, quit and prompt recovery |

The shell event captures show `cwd`, `command-start`, and `command-end` for all
three shells. SSH additionally records `remote-start` and
`remote-host=dan@macbook`, followed by the local command end and cwd event after
disconnect.

The SSH workflow used a generated per-run host key and client key, an
unprivileged loopback sshd, an isolated known-hosts file, no agent or password
authentication, no user SSH configuration, and only the `LC_DANTERM=1` marker
via `AcceptEnv`. After every workflow, the ownership census reported the pane
session, PTY owner, descriptors, and dispatch sources released. The sshd trap
also waited for the per-run server during harness exit.

## Deterministic coverage and regressions

`just test` covers diagnostic capture replay and the rule that ordinary
characterization capture appears only after child-originated completion, via
the TerminalPTY controller/lifecycle suites under
[`lib/TerminalPTY/Tests`](../../lib/TerminalPTY/Tests). Prerequisite refusal,
isolated home and SSH configuration, failure artifact preservation, and
bounded lifecycle cleanup are exercised by the opt-in recipe
`just test-terminal-workflows`, not by `just test`.

No live failure exposed a terminal parsing, state, resize, reflow, style, or
screen defect, so this slice promoted no new TerminalCore fixture. The evidence
run did tighten deterministic harness coverage for recording a usable OpenSSH
version in the environment manifest.
