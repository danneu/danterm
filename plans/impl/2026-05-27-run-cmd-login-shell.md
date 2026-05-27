# Run `--cmd` launches inside the login shell

## Context

`danterm tab new --cmd <X>` (and `pane split --cmd <X>`) currently launches `<X>`
as the surface's **direct command** (`config.command` in libghostty). On macOS
libghostty runs that as:

```
/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <X>"
```

so `<X>` runs **without an interactive login shell**. Two consequences, both
reported by the user when launching `claude` via the API:

1. **No cwd in the sidebar.** Ghostty injects shell integration only when it
   detects a known shell (`shell_integration.detectShell`, `Exec.zig:788`).
   `claude` isn't a shell, so no integration -> no OSC 7 -> the `GHOSTTY_ACTION_PWD`
   callback (`GhosttyApp.swift:244`) never fires -> `.surfaceCwd` (`Update.swift:748`)
   never runs. That handler is what writes `pane.cwd` *and* derives the tab
   `subtitle = abbreviateHome(cwd)` (`Update.swift:756`); the sidebar renders that
   subtitle via the `reconcileSidebar()` projection pass (`Reconcile.swift:216`).
   The `--cwd` value only sets Ghostty's initial dir.

2. **Unreliable Claude notifications.** Because no interactive login shell runs,
   `~/.zshrc` / `~/.zprofile` are never sourced. The process inherits only
   `login(1)`'s default PATH plus whatever DanTerm itself was launched with — not
   the user's Homebrew/nix/`~/.local/bin` additions. The user's Claude Code
   notification hook shells out to tooling that may be missing from that PATH, and
   whether it works depends on how DanTerm was launched (Finder vs terminal) —
   hence "not reliable."

When the user instead types `claude` manually in a tab, it runs as a child of
the interactive login shell (full env + shell integration), so both work.

**Goal:** make API-launched commands run inside the user's login shell, matching
manual launch — fixing both symptoms. This is a global change to `--cmd`
semantics (decided with the user).

The mechanism already exists: the `command` param of the `createSurface` command
feeds `restoreInitialInput(command, .execute)` (`ModelOperations.swift:971`) ->
`config.initial_input`, typed into the surface as `"<X>\n"`. The restore path
already uses exactly this (`AppRuntime.swift:1104`), and `initial_input` is
buffered into the pty as typeahead at `threadEnter` (`Termio.zig:367`), so it
does **not** race shell startup. Switching `--cmd` from `launchCommand`
(`config.command`) to `command` (`initial_input`) means Ghostty launches the
normal login shell (full env + shell integration -> OSC 7 cwd) and types the
command into it.

Trade-off (accepted): for *all* `--cmd` uses the pane now returns to a live shell
prompt when the command exits (instead of a stable `wait-after-command` "process
exited" pane), a shell prompt is briefly visible before the command starts, and
`pane read` output includes a prompt + the typed command line.

## Changes

### 1. Flip the launch channel — `app/Update.swift`

In the `.createTab` case (~line 89) and the `.splitPane` case (~line 189), the
`createSurface` command currently passes:

```swift
command: nil,
launchCommand: launch?.cmd,
```

Change both to:

```swift
command: launch?.cmd,
launchCommand: nil,
```

`waitAfterCommand` becomes a no-op (only applied when `launchCommand` is set,
`TerminalView.swift:122`); leave the argument as-is to minimize the diff. This
also makes the live launch path consistent with the restore path, which already
uses `command:`/`launchCommand: nil`.

This is the **only** change needed for both symptoms. The cwd fix falls out of
it: once a real login shell with shell integration runs, OSC 7 fires on the
shell's first prompt (before `claude` execs), so `.surfaceCwd` runs through its
normal path — writing `pane.cwd` and the tab `subtitle`, then returning
`[.scheduleCheckpoint]` (`Update.swift:748`). The sidebar row and window/content
title then update from the model projection via `reconcileSidebar()`
(`Reconcile.swift:216`) and `reconcileWindowChrome()` (`Reconcile.swift:249`) —
not via emitted commands. No separate cwd seeding is needed (seeding `pane.cwd`
alone wouldn't help, since the sidebar renders `tab.subtitle`).

Note: after this change `launchCommand`/`config.command` is no longer populated
anywhere in the live path. Leave the `Command.createSurface` `launchCommand`
parameter and the `TerminalView` `config.command` plumbing in place (dead but
harmless; removing it would churn every `case .createSurface(_,_,_,_,_)` pattern
in the tests for no behavioral gain).

### 2. Fix the now-stale launch comment — `app/TerminalView.swift`

The comment at ~line 83 currently says "IPC launches use Ghostty's command field
and must not also seed shell input" — which becomes false after step 1 (IPC
launches now flow through `command` -> `initial_input`). Update it to describe
the real split that the `initialInput = launchCommand == nil ? ... : nil` logic
encodes: `launchCommand` is the direct Ghostty command path (no seeded shell
input); when it's absent, `command` is seeded as initial shell input — used by
restore and now by IPC `--cmd` launches.

### 3. Update the agent skill docs — `integrations/danterm/SKILL.md`

AGENTS.md requires SKILL.md stay in sync with `--cmd` semantics. Revise the two
spots that describe the old behavior:

- ~lines 135-137: replace "launches the program directly via libghostty, not by
  typing into a shell prompt, so it does not race shell startup. The pane stays
  open after the command exits" with the new contract: the command runs inside
  your login shell (sources your shell config, full PATH, shell integration so
  cwd is reported), and the pane returns to a shell prompt when the command
  exits.
- ~lines 153-154 and 256-259: the "prefer `--cmd` ... avoids the shell-prompt
  race" guidance is still valid (`--cmd` still beats async `pane input`
  send-keys, which races); keep the recommendation but drop any "direct
  exec / stays open" wording.

## Tests (TDD — write/adjust first, confirm they fail, then implement)

Pure `update`-level tests in `tests/UpdateIpcTests.swift`. Invert the three
existing assertions that pin the old behavior (they become the failing-first
tests):

- `tab.new` launch test (~line 636): assert
  `command == "date" && launchCommand == nil` (was the inverse).
- `tab.new with explicit group id` (~line 666): assert
  `command == "make test" && launchCommand == nil`.
- `pane.split with launch` (~line 825): assert
  `command == "cargo --version" && launchCommand == nil`.

No new cwd tests are needed: the change doesn't touch `.surfaceCwd` or the
`reconcileSidebar()` / `reconcileWindowChrome()` projections, so the existing
cwd -> `tab.subtitle` -> sidebar behavior is unchanged and already covered. cwd
now reaches the sidebar through that same path once OSC 7 fires.

Run with `just test`.

## Verification (end-to-end)

1. `just build-run` to install + launch the dev app.
2. From a DanTerm pane: `danterm tab new --cmd claude --cwd ~/some/dir --title claude`.
   - Sidebar shows the cwd for the new tab.
   - In that tab, `echo "$PATH"` includes your Homebrew/nix/`~/.local/bin`
     entries, and `env | grep GHOSTTY_` shows shell-integration vars present.
3. PATH parity check (was the root cause of the flaky hook):
   ```
   danterm tab new --cmd 'echo "$PATH"'        # API tab
   # vs a normal tab:
   echo "$PATH"
   ```
   The two should now match.
4. Let Claude idle/await input in that tab while it's unfocused and confirm a
   DanTerm notification fires (matches behavior of a manually-launched `claude`).
5. Regression: `danterm tab new --cmd 'just test'` runs the command and its
   output is readable via `danterm pane read --pane <id>` (now with a shell prompt
   line in the output — expected).
