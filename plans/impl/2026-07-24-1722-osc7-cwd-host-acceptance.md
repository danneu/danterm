# Accept the OSC 7 cwd reports the shells already send

## Context

In the Swift terminal engine, a new tab or split opens in `$HOME` instead of
inheriting the focused pane's directory. Production (libghostty) inherits
correctly, so this is a migration regression, not a missing feature.

Load-bearing premises, all measured on the current branch:

- Interactive shells report cwd via OSC 7 with no DanTerm shell integration
  involved. fish 4.7.1 does it natively (`__fish_update_cwd_osc`, on every
  `PWD` change and prompt); zsh and bash report the same value. All three send
  the POSIX hostname (`$hostname` / `$HOST` / `$HOSTNAME`), e.g. `macbook`.
- libghostty compares that host against `gethostname()`
  (`.ghostty-src/src/os/hostname.zig:97`) and accepts. Production panes carry
  real cwds.
- The Swift engine compares against `ProcessInfo.processInfo.hostName`, which
  returns the mDNS form `macbook.local`. Every OSC 7 report is therefore
  dropped by `Terminal.localFilePath`, `pane.cwd` stays nil, and
  `currentCwd(in:)` has nothing to inherit. `danterm pane info` on a Dev.app
  pane reports `"cwd": null`.
- Nothing else feeds `pane.cwd` in either backend: libghostty's C API exposes
  pwd only as an action payload (no getter), and its internal spawn-time
  `setPwd` never reaches an embedder.
- The end-to-end harness could not catch this: `scripts/terminal-workflows.sh`
  injects `DANTERM_MACHINE_HOSTNAME="$(hostname)"`, handing the runner exactly
  the value the shell will emit, so the acceptance path is only ever exercised
  against a hand-matched hostname.

Desired outcome: a pane's cwd tracks the shell's reports again, so tab and
split creation inherit it, and the toolbar label, sidebar subtitle, "Copy cwd",
persistence, and `danterm pane info` stop reading empty.

## Decision

Fix the comparison, not the shells. Two changes:

1. Read the machine hostname from one shared seam that returns the POSIX
   hostname -- the same value the shells report -- and default every
   production and harness path to it. The app stops choosing its own ambient
   source.
2. Accept a narrow set of host spellings as local rather than requiring byte
   equality, so a future divergence between our source and the shell's does
   not silently kill cwd again.

The tolerance is deliberately scoped to the divergence macOS manufactures (the
`.local` suffix that `ProcessInfo.hostName`, `Host.current()`, and
`scutil --get LocalHostName` all return), not a general "first label matches"
rule, which would accept `macbook.evil.com`. The result is a strict superset of
libghostty's rule: everything production accepts, the engine accepts.

Critical files: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (host
acceptance), the hostname seam under `lib/TerminalPTY/Sources/` threaded through
`TerminalPaneSession`, `app/SwiftTerminalBackend.swift` (drops its own ambient
read), `lib/TerminalPTY/TestSupport/TerminalWorkflowRunner/` plus
`scripts/terminal-workflows.sh` (stop injecting a hostname), and
`docs/terminal-capabilities.md` (state the rule).

## Invariants

- **I1.** An OSC 7 report is accepted when its URI host is `localhost`, or
  names this machine ignoring ASCII case, one trailing dot, and a trailing
  `.local` label. Any other host is rejected and leaves the pane's cwd
  unchanged. Existing rejections (non-`file` scheme, malformed
  percent-encoding, oversized value) are unaffected.
- **I2.** The hostname the engine compares against is the machine's POSIX
  hostname, obtained through a single seam that production and the workflow
  harness both reach by default. Tests can still inject an explicit value. The
  default lives in the PTY/session layer, not in `TerminalCore` -- the core stays
  free of ambient reads, and no machine host at the core boundary means "accept
  `localhost` only", a deliberate value rather than an accident.
- **I3.** A pane's cwd follows the shell's OSC 7 reports, so creating a tab or
  split inherits the focused pane's directory.

## Proof obligations

- **PO1** (I1): the accept/reject matrix -- `localhost`, exact match, and the
  case / trailing-dot / `.local` variants in both directions are accepted; a
  different host and a same-first-label host such as `macbook.evil.com` are
  rejected. Extends the existing suite covering OSC 7 policy.
- **PO2a** (I2): the seam's value is the POSIX hostname and not the
  mDNS/`ProcessInfo` spelling -- asserted against the value obtained by an
  independent route (the `hostname` the shells read), not against the string's
  shape, so a legitimately fully-qualified POSIX hostname does not fail it. This
  is the assertion that fails if the ambient source is ever swapped back; PO2b
  cannot catch that, since I1's tolerance would accept `macbook.local` anyway.
- **PO2b** (I2): a pane constructed the way production constructs it -- without
  anyone passing a hostname -- accepts an OSC 7 report naming that value.
- **PO3** (I3): the workflow harness, running real zsh/bash/fish under a PTY,
  still observes working-directory events, now without injecting a hostname of
  its own.

## Non-goals

- Seeding `pane.cwd` at spawn, or probing the child process for its cwd
  (iTerm2-style). Production does neither; parity does not need it.
- Changing DanTerm's shipped shell integrations, or anything in the user's
  shell config. fish already reports cwd natively; the earlier `~/world` OSC 7
  edit was reverted as redundant.

## Accepted risks

- **AR1.** The `.local` tolerance accepts a cwd from a host whose name differs
  from this machine's only by the mDNS suffix. Exploiting it requires an ssh
  session into a host named `<this-host>.local`, and the payload only sets a
  local path used for display and the next pane's spawn directory. Accepted for
  the robustness it buys.
- **AR2.** PO3 runs in a nix devShell and is not part of `just test`, so the
  always-on guard against this class of regression is PO1 plus PO2a/PO2b.

## Rejected ideas

- **RI1.** Byte-exact hostname equality (libghostty parity). After the seam fix
  it works, but it leaves the silent-failure mode intact: a future divergence
  produces no cwd and no error, which is what made this cost hours to diagnose.
- **RI2.** Exposing a rejected-report counter or log so mismatches are visible.
  No consumer surfaces it today, so it would be dead weight; revisit if this
  class recurs.

## Implementation discretion

- Where the shared hostname read lives, and whether the tolerant comparison is
  a free function or a method on the terminal.

## Verification

- `swift test --package-path lib/TerminalCore` for PO1; `just test` for
  PO2a/PO2b, whose seam and default live in the PTY/session layer.
- `nix develop .#terminal-workflows -c just test-terminal-workflows` for PO3.
- In the real app: launch the Dev build on the Swift backend, `cd` in a pane,
  then confirm `danterm pane info` reports that directory and that a new tab
  and a split both open there. Before the fix both report nothing and open in
  `$HOME`.

## Implementation notes

- The seam is `MachineHostname.posix` in the `TerminalPTYHost` target, not a new
  target: `TerminalPaneSession` already depends on `TerminalPTYHost`, so both the
  host and session default parameters reach it without a new module, and it stays
  out of `PaneLifecycle`, which the purity lint holds to pure code.
- `NeutralTerminalRecording.replay` gained a `machineHostname:` parameter
  (defaulting to nil). `machineHostname` is a stored property of `Terminal` and so
  participates in its synthesized equality; once PTY hosts default to the real
  host, the four replay-vs-live-snapshot assertions in the PTY suites compared two
  terminals that differed on configuration alone. Neutral fixtures, which carry no
  host-specific bytes, still replay with no machine identity.
- The plan's real-app check (launch the Dev build on the Swift backend, `cd`, read
  `danterm pane info`) was not run: driving the GUI app would contend with the
  user's running DanTerm for the IPC socket. PO1, PO2a, PO2b, and PO3 all pass,
  and PO2b exercises the same OSC 7 acceptance path a production pane uses.
