# Tokenless shell events, buffer-seeded restore prefill, restore-execute removal

Target: `/Users/dan/Code/danterm-terminal-engine`, branch `experiment/swift-terminal-engine`.

## 1. Problem

On restore, `PaneLaunchSnapshot.command` (persisted `pane.lastCommand`, which
originates from terminal-reported shell events) is typed into the PTY as raw
input: Ghostty via `restoreInitialInput` -> `config.initial_input`
(`app/TerminalView.swift:134-136`), Swift backend via `resolvedInitialInput` ->
`.writeInput` (`lib/TerminalPTY/Sources/PaneLifecycle/LaunchPolicy.swift:231-246`).
Because nothing rejects control characters in the decoded `command-start`
payload, a forged event containing an embedded newline makes even `.prefill`
mode self-executing, and `--restore-commands execute` auto-runs it outright.
The per-pane shell-integration token defends this channel, but incoherently:
it is forwarded to every ssh host (so remote hosts are trusted anyway), it
guards only OSC 1337 while title/cwd/notification channels are tokenless, and
it costs a UUID mint at two sites, a five-hop `shellIntegrationToken` thread,
an env-var + `SendEnv` forwarding contract, and token machinery across the
three shell scripts and their tests.

Evidence: `dispatchDanTermShell` validates token/base64/UTF-8/size but not
control characters (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:633-665`);
the token is not used for IPC auth (IPC trusts socket reachability only);
`lastCommand`'s only consumer is restore input (`Persistence.swift:140-141`,
no projection reads it).

Desired outcome: restored commands can never execute without the user
pressing Enter; the token system and restore-execute mode are removed; the
CLI/IPC `--cmd` launch feature is unchanged.

## 2. Decision

Three coupled changes:

- **A. Buffer-seeded prefill (zsh + fish).** Restore stops passing the saved
  command as PTY input in both backends. Instead `restoreLaunchEnvironment`
  sets `DANTERM_RESTORE_COMMAND=<command>` (mirroring
  `DANTERM_RESTORE_SCROLLBACK_FILE`), and the bundled zsh and fish
  integrations seed the shell's editable line buffer so the command is
  waiting, unexecuted, at the first prompt (constraint: fish's line buffer
  is writable only from inside its interactive reader, so fish seeding must
  defer to the first prompt). bash consumes and unsets the var without
  seeding. Because the value crosses an environment-variable boundary,
  which cannot represent NUL, `command-start` values containing U+0000 are
  rejected at shell-event admission, before persistence.
- **B. Restore-execute removal.** The `--restore-commands` flag and both
  `RestoreCommandBehavior` enums (DanTermCore `Model.swift:278`, PaneLifecycle
  `LaunchPolicy.swift:35`, bridge in `SwiftTerminalBackend`) are deleted. The
  `command` field on the launch seam survives with always-execute semantics
  (input terminated with exactly one newline); its only remaining producer is
  user-authored CLI/IPC `LaunchSpec.cmd`. Restore passes `command: nil`. The
  `launchCommand` direct-exec arm is untouched.
- **C. Token removal.** OSC 1337 becomes
  `ESC ] 1337 ; DanTermShell=1 ; <event> [; <base64 arg>...] ST` (token field
  deleted, argument indices shift down one, per-event field-count guards
  tighten accordingly). All `shellIntegrationToken` threading, the
  `DANTERM_TOKEN` / `LC_DANTERM_TOKEN` env vars, and the scripts' token
  capture/forwarding machinery are deleted. The scripts' incidental uses of
  the token become explicit markers: emission gates on `DANTERM` (already set
  locally) or `LC_DANTERM`; the ssh/mosh wrappers forward `LC_DANTERM=1` via
  `SendEnv`; remote detection is `LC_DANTERM` present and `DANTERM` absent.
  Markers are not unset (nested remote shells keep integration). The workflow
  harness sshd config (`scripts/terminal-workflows.sh:111,135`) switches its
  `SendEnv`/`AcceptEnv` to `LC_DANTERM`.

Decisive ordering constraint: A/B (terminal-reported text can no longer become
PTY input) must land before or together with C (removing the auth that
guarded that path). Never ship C alone.

Consequential rework: the screenshot recipe (`justfile:147-282`) loses
`--restore-commands execute`. It launches with the init snapshot for
structure/cwds only, then populates the panes through the `danterm` CLI
(`danterm pane input`), which flows through the surviving always-execute
CLI path. `docs/screenshot/init.json` must be regenerated: it is a stale v1
file the current loader rejects (`appInitFileVersion = 2`), so the recipe is
already broken on this branch. The regenerated snapshot drops per-pane
`launch.command` so prefill cannot race the CLI-typed input.

## 3. Invariants

- I1: Terminal-reported text (shell-event payloads, persisted `lastCommand`)
  never reaches a PTY as input bytes. A restored command appears only as
  editable line-buffer content in zsh and fish; executing it requires the
  user's accept-line. bash and non-integrated shells get no prefill.
- I2: CLI/IPC `--cmd` launches behave byte-identically: the command is typed
  into the new shell terminated with exactly one newline (no double newline
  when the command already ends in one); `launchCommand` precedence over
  `command` is unchanged.
- I3: Tokenless wire format: field[0] `DanTermShell=1`, field[1] event name,
  args from field[2]. Exact field counts per event (`command-start` 3,
  `command-end` 2, `remote-start` 2, `remote-host` 4); wrong counts are
  rejected. Existing `maximumShellOSCBytes`, canonical-base64, strict-UTF-8,
  and value-size bounds are unchanged. Additionally, `command-start` values
  containing NUL are rejected at admission, so every admitted command is
  representable across the environment boundary I4 relies on.
- I4: Env contract: `DANTERM_TOKEN` and `LC_DANTERM_TOKEN` no longer exist
  anywhere (env, code, scripts, manifest). `LC_DANTERM=1` is set only by the
  ssh/mosh wrappers and forwarded via `SendEnv`. `DANTERM_RESTORE_COMMAND` is
  set only on restore, only when the saved command is non-empty, carries the
  value verbatim (including newlines; NUL is unrepresentable and excluded by
  I3), and is consumed-and-unset by all three bundled scripts. DanTerm scrubs
  the reserved restore variables (`DANTERM_RESTORE_COMMAND`,
  `DANTERM_RESTORE_SCROLLBACK_FILE`) from its own process environment at
  startup, before any pane launches; restore values are injected per-pane as
  overrides. This holds on both backends -- it must not depend on removing
  entries from a per-surface environment, because Ghostty's surface env API
  can only add overrides on top of the inherited process environment, never
  unset -- so a non-restore launch (and an empty-command restore) never
  passes a hostile inherited value to the child.
- I5: Remote behavior is preserved under marker detection: remote shells
  emit `remote-host` and suppress OSC 7 cwd, exactly as today.
- I6: The capability manifest and its pin test agree with the new env set and
  protocol identity in the same change (the manifest test pins exact names).
- I7: Recovery restore has exactly one behavior (prefill); no flag, mode, or
  code path can auto-execute a restored command.

## 4. Proof obligations

- PO1 (I1, I2): launch-seam tests prove `command` alone yields
  newline-terminated input, restore yields no input, empty/nil yields none,
  and `launchCommand` precedence holds — respec
  `LaunchPolicyTests`, the `TerminalPTYHostTests` initial-input seam test,
  and the `ExportTests` restore block (delete flag/execute cases).
- PO2 (I4): `TerminalLaunchEnvironmentTests` prove `DANTERM_RESTORE_COMMAND`
  presence, absence when nil/empty, and verbatim multi-line value; token
  assertions deleted. The startup scrub is proven with a hostile value
  present in the app's own environment across the three launch shapes --
  normal launch, empty-command restore, non-empty restore -- showing only
  the last delivers the variable to the pane, with the restore's own value
  (test seam at implementer's discretion; end-to-end confirmation rides the
  PO6 smoke).
- PO3 (I1, I4, I5): `scripts/tests/shell-integration_test.sh` (rewritten)
  proves per shell: tokenless emission bytes under `DANTERM=1`; silence with
  no marker; remote mode under `LC_DANTERM=1` only (remote-host emitted, OSC 7
  suppressed); markers survive sourcing; `DANTERM_RESTORE_COMMAND` consumed
  (including a multi-line value) with exit 0. Plus an interactive-PTY leg
  per seeded shell (zsh, fish): drive the shell to its first prompt with
  the variable set and assert the command text appears in the rendered line
  buffer without having executed, and that it runs only after an explicit
  Enter. Skips cleanly where the shell binary is unavailable.
- PO4 (I3): `TerminalShellEventTests` rewritten for the tokenless layout:
  accepted events, per-event field-count rejections, NUL-in-command
  rejection, and the retained framing/bounds/base64 rejections. Frames in `TerminalSemanticEventTests`,
  `TerminalMetadataIntegrationTests`, `TerminalPaneSessionControllerTests`
  updated; the cross-pane token-isolation test is deleted with its subject.
- PO5 (I6): `TerminalCapabilityManifestTests` pins the new env-name set
  (remove both token vars; add `LC_DANTERM`, `DANTERM_RESTORE_COMMAND`) and
  the renamed shell-events protocol entry.
- PO6 (I1, I7, recipe): manual smoke — crash-restore a zsh pane and a fish
  pane: the last command appears prefilled, not executed; bash pane: no
  prefill, var absent; `danterm tab new --cmd 'echo hi'` still auto-executes;
  ssh to a host with the integration installed: remote badge appears;
  `just screenshot` produces the populated capture.
- PO7: full gates green — `just test` (includes shell-integration and
  retirement script tests, purity lint), `swift test` for DanTermCore,
  TerminalCore, TerminalPTY; one opt-in workflow-harness run after the script
  and harness changes land (its ssh leg exercises the `LC_DANTERM`
  forwarding).

## 5. Non-goals / accepted risks / rejected ideas

- NG1: No change to IPC authentication (it never used the token).
- NG2: No authentication added to title/cwd/notification OSC channels.
- NG3: No bash prefill.
- AR1: Shell events become forgeable by anything writing to the pane's PTY.
  Accepted: the forgeable payloads only feed pane metadata (title chrome,
  remote badge, a `lastCommand` that I1 keeps Enter-gated), matching the
  trust model of iTerm2/kitty equivalents.
- AR2: `DANTERM_RESTORE_COMMAND` lingers in the environment of shells without
  the integration. Accepted: the value is the user's own last command; same
  exposure class as `DANTERM_RESTORE_SCROLLBACK_FILE`.
- RI1: Bracketed-paste delivery of prefill — startup race (bytes arriving
  before the line editor enables paste guards execute raw).
- RI2: Keeping raw `initial_input` prefill with control-character
  sanitization — sanitizes an unsafe channel instead of using a safe one and
  caps prefill at one line.
- RI3: Keeping the token — once prefill is Enter-gated, the token guards only
  cosmetic metadata while trusting every ssh host with the secret.
- RI4: A snapshot `launchCommand` field so screenshots keep auto-executing
  from JSON — re-couples restore to auto-execution, which this plan removes.

## 6. Implementation discretion

- Commit slicing within the ordering constraint (A/B before or with C), and
  whether manifest/doc edits ride the code slice that their pin tests cover.
- Exact script blocks, helper names, and guard-count mechanics.
- Per-shell buffer-seeding mechanics (which zsh builtin, the shape of the
  fish first-prompt handler), within A's behavioral requirement and fish's
  interactive-reader constraint.
- Interactive-PTY test harness choice for PO3's seeded-buffer leg.

## Critical files

`lib/TerminalPTY/Sources/PaneLifecycle/LaunchPolicy.swift`,
`app/AppRuntime.swift`, `app/TerminalView.swift`, `app/main.swift`,
`app/AppDelegate.swift`, `app/TerminalBackend.swift`,
`app/SwiftTerminalBackend.swift`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`,
`lib/DanTermCore/Sources/DanTermCore/{TerminalLaunchEnvironment,Persistence,Model}.swift`,
`lib/TerminalPTY/Sources/{TerminalPaneSession/TerminalPaneSession,TerminalPTYHost/TerminalPTYHost}.swift`,
`integrations/shell-integration/danterm.{zsh,fish,bash}`,
`scripts/terminal-workflows.sh`, `scripts/tests/shell-integration_test.sh`,
`lib/TerminalPTY/TestSupport/TerminalWorkflowRunner/main.swift`,
`terminal-capabilities-v1.json`, `justfile` (screenshot recipe),
`docs/screenshot/init.json` (regenerate v2). Docs sweep:
`docs/terminal-capabilities.md`,
`plan-terminal-engine/10-protocols-shell-integration.md`,
`integrations/danterm/SKILL.md`, `README.md`,
`docs/evidence/2026-07-21-terminal-workflow-compatibility.md`.

## Commit progress

If a slice doesn't survive contact with the code, re-slice and update this
list -- the invariants and ordering constraints are the contract, the list
is the route. Sliced to respect the ordering constraint (A/B land before C).
Slices need not each leave every recipe working (`just screenshot` is
already broken on this branch and stays broken until slice 3), but together
they must cover all of the plan's work, and each slice carries the tests
and docs for the behavior it changes.

- [x] 1. A+B: buffer-seeded restore prefill via `DANTERM_RESTORE_COMMAND`
      (zsh/fish seeding, bash consume-and-unset, startup scrub, NUL admission
      rejection), delete `--restore-commands` and both `RestoreCommandBehavior`
      enums -- PO1, PO2, NUL leg of PO4, restore-var and seeded-PTY legs of
      PO3
- [x] 2. C: tokenless OSC 1337 wire format, delete token threading and
      `DANTERM_TOKEN`/`LC_DANTERM_TOKEN`, marker-based emission/remote
      detection (`DANTERM`/`LC_DANTERM`), workflow-harness sshd `SendEnv`
      switch, manifest + pin test, wire-format/env-contract docs
      (`docs/terminal-capabilities.md`,
      `plan-terminal-engine/10-protocols-shell-integration.md`) -- PO4
      (remainder), PO5, emission/remote legs of PO3
- [ ] 3. Screenshot recipe rework (CLI-populated panes), regenerate
      `docs/screenshot/init.json` as v2 without `launch.command`, remaining
      docs sweep (`integrations/danterm/SKILL.md` if the CLI surface moved,
      `README.md`, the workflow-compatibility evidence doc) -- PO6 smoke,
      PO7 gates

## Implementation notes

- Commit 2 does not recreate `terminal-capabilities-v1.json` or its pin test:
  commit `dcfd162` intentionally retired that artifact immediately before this
  plan began. The normative `docs/terminal-capabilities.md` contract and
  behavioral protocol/environment tests carry the updated claims instead.
