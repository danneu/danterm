# Plan: remove the login-environment snapshot from app startup

## Context

At launch, `app/main.swift` runs `$SHELL -l -c env` and `setenv()`s every line
into the app process so panes (spawned by GhosttyKit via `/usr/bin/login -p`,
which preserves the app's env) inherit a rich user environment instead of
launchd's bare one.

The snapshot is a login-session capture, so it includes once-per-session
guards -- `__HM_SESS_VARS_SOURCED=1` (home-manager) and
`__NIX_DARWIN_SET_ENVIRONMENT_DONE=1` (nix-darwin). Every pane therefore gets
an environment frozen at app-launch time *plus* the guard that tells fish to
skip rebuilding it. Verified failure mode on the author's machine: after a nix
rebuild added a PATH entry, brand-new tabs in a still-running DanTerm showed
`fish: Unknown command: createdb` until the app was relaunched. Any rebuild
that changes session vars repeats this.

The prerequisite that made the snapshot necessary is now shipped in the
author's nix config (`~/world`, out of scope here): nix-darwin
`programs.fish.enable = true` installs `/etc/fish/nixos-env-preinit.fish`, so
a login fish spawned from a completely bare launchd env rebuilds the full nix
PATH and `home.sessionPath` entries by itself. Verified end-to-end with
`env -i HOME=... SHELL=.../fish fish -l -c 'command -v createdb'`.

Goal: panes derive a fresh, current environment at spawn from shell init,
never replayed from a cache. Delete the snapshot block; the app keeps the bare
launchd env (which still carries genuinely session-owned vars like
`SSH_AUTH_SOCK` -- correct), and the pane's login shell builds the rest.

Side benefit: startup no longer blocks synchronously on spawning a login
shell.

## Consumer audit (why the deletion is safe)

Every reader of the process environment / PATH in this repo, and its
post-deletion behavior:

| Consumer | Post-deletion behavior |
|---|---|
| `app/main.swift` snapshot block | The deletion target. Its `SHELL` read (`ProcessInfo` + `getpwuid` fallback) exists only to run the capture; it goes with the block. Only `Process`/`executableURL` launch in `app/`. |
| Pane default shell | Resolved by Ghostty, not this repo. `.ghostty-src/src/config/Config.zig` `finalize()` (~line 4537): when desktop-launched (not "probable CLI"), it deliberately ignores `$SHELL` and reads the passwd entry via Directory Services. Unaffected. |
| Pane spawn env | `/usr/bin/login -q -flp <user> /bin/bash --noprofile --norc -c "exec -l <shell>"` (`.ghostty-src/src/termio/Exec.zig` ~1500). `-p` preserves the app env: post-deletion that is bare launchd + the explicit `DANTERM_*` vars. The `exec -l` makes the pane shell a login shell, which rebuilds the full env. This is the fix working as intended. |
| `terminalLaunchEnvironment()` / `restoreLaunchEnvironment()` (`lib/DanTermCore/Sources/DanTermCore/TerminalLaunchEnvironment.swift`) | Pure constructors; only *add* `DANTERM_*` vars on top of the inherited base. Unaffected; existing tests in `TerminalLaunchEnvironmentTests.swift` keep passing. |
| `launchCommand` (direct Ghostty command, `app/TerminalView.swift`) | Ghostty runs it via `bash -c "exec -l <command>"`, so a bare name would PATH-resolve against the pane's exec-time (bare) env. **Currently every construction site passes `launchCommand: nil`** (`Update.swift:98,197`, `AppRuntime.swift:1151`), so this is latent, not live. Mitigation: doc-comment the parameter (Change 2). |
| `command` / restore commands (`app/TerminalView.swift:97`) | Becomes `initial_input` -- text typed into the already-running pane shell, resolved by that shell's fresh login env. Fine. |
| `DoctorProber` (`lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift`) | `gatherDoctorFacts()` is called only from `cli/main.swift` (`danterm doctor`), a separate process that inherits the *invoking shell's* env -- never the app's snapshot. Unaffected. Bonus: run inside a DanTerm pane, doctor now sees exactly what panes see. |
| `cli/main.swift:102` env read | Reads `DANTERM_SOCK`/`DANTERM_PANE` from the CLI process env (set per-pane by the app). Unaffected. |
| `CLIPathInstaller` | Absolute `/usr/bin/osascript`; no PATH lookup. Unaffected. |
| HOME readers (`NSHomeDirectory()`, `liveHomeDirectory`) | launchd sets `HOME`. Unaffected. |
| libghostty's own in-app env reads | `ghostty_init` -> `ensureLocale()` reads `LANG` (`.ghostty-src/src/global.zig:164`, `os/locale.zig`); `ghostty_config_load_default_files` (`app/GhosttyApp.swift:68`) resolves config paths via `XDG_CONFIG_HOME` (`os/xdg.zig:25,185`). Both fall back by design on a bare env: `ensureLocale` populates `LANG` from macOS system preferences when unset, XDG defaults to `~/.config` -- exactly stock Ghostty.app behavior when Finder-launched. Verified the author's setup does not set `XDG_CONFIG_HOME` (unset in the session; nothing in `~/world` exports it), so the config-load location is unchanged post-deletion. |

Nothing besides the latent `launchCommand` path depends on the snapshot.

## Change 1: delete the snapshot block (`app/main.swift`)

Remove the comment ("Resolve the user's login shell environment...") and the
entire `do { }` block immediately after `import GhosttyKit` -- the
`ProcessInfo`/`getpwuid` shell lookup, the `Process` running
`["-l", "-c", "env"]`, and the `setenv` loop (currently lines 4-28).
`ghostty_init` becomes the first statement after the imports.

No replacement of any kind -- no filtered/denylisted variant, no re-capture
(see Rejected alternatives).

## Change 2: doc-comment the latent `launchCommand` PATH hazard (`app/TerminalView.swift`)

Extend the existing comment at `app/TerminalView.swift:94` ("Direct Ghostty
commands use `launchCommand`...") with one line stating the constraint: the
command is exec'd by bash in the pane's exec-time environment (bare launchd
post-deletion), so future non-nil callers must pass an absolute path, not a
bare name. This is a constraint the code can't show; today every caller passes
nil.

## Note for other machines (do not skip)

The deletion assumes the login shell can rebuild its environment from a bare
spawn. On the author's machine that prerequisite (nix-darwin
`programs.fish.enable`) is live, so there is no sequencing hazard. Anyone else
running DanTerm from Dock/Finder needs the equivalent for their shell (a
login-shell init that builds PATH without inherited state) or panes will see a
minimal PATH. Decided in the hand-off: delete outright anyway -- personal app,
prerequisite shipped. A doctor probe ("does a clean `env -i` login shell
resolve basic tools?") was considered to diagnose this and deferred as a
follow-up (deletion-only scope confirmed with the user 2026-06-11).

## Files to modify

- `app/main.swift` -- delete the env-snapshot `do { }` block (~25 lines)
- `app/TerminalView.swift` -- one comment line on the `launchCommand` hazard

No test changes: the deleted block lives in the untestable app-target
`main.swift` and had no unit coverage; no covered behavior changes.

## Verification

Unit/build gate:

1. `just test` -- all suites pass unchanged (notably
   `TerminalLaunchEnvironmentTests`)
2. `just build` -- compiles

Manual freshness gate -- launch the dev build from **Finder/Dock, not from a
terminal** (a terminal parent would hand the app a rich env and mask the bug).
Caveats: `ps eww` shows exec-time env only, so verify inside panes, not via
`ps` on the app process. Do NOT check `echo $__HM_SESS_VARS_SOURCED` -- it
prints `1` even when the fix works, because the pane's fresh login fish
sources `hm-session-vars.sh` itself and sets the guard as its own
once-per-session sentinel; the discriminating observables are the PATH
checks below, not the guard.

1. New pane: `command -v createdb` resolves;
   `string match -q '*/run/current-system/sw/bin*' "$PATH"; and echo ok`
   (or visually: `string join \n $PATH`) shows the nix dirs.
2. Freshness: change `home.sessionPath` in the nix config, rebuild, open a
   **new tab without relaunching DanTerm** -- the change is visible in
   `$PATH`. (Revert the nix change afterward.)
3. Session vars survive: `echo $SSH_AUTH_SOCK` is non-empty in a new pane.

## Rejected alternatives (do not re-propose)

- **Guard-stripping** -- keep the snapshot but skip `__HM_SESS_VARS_SOURCED`
  etc. when `setenv`ing. Rejected: the env stays half-stale (base PATH frozen,
  removed vars linger, duplicate PATH entries), and the denylist couples
  DanTerm to private home-manager/nix-darwin sentinel names.
- **Per-pane or TTL-based re-capture** -- re-run `$SHELL -l -c env` per tab or
  on `/run/current-system` change. Rejected: latency plus machinery to
  maintain a cache whose only correct TTL is zero.
- **Doctor remediation for the bare app env** -- the hand-off flagged
  `DoctorProber` as a snapshot consumer needing a login-shell probe. Audit
  showed it never runs in the app process (CLI-only), so its premise is void;
  the clean-login-shell diagnostic probe is deferred as an optional follow-up.

## After this lands (out of scope)

Implement, release, then bump the `danterm` flake input in `~/world`.
