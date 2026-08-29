# Dev loop

How an agent builds, runs, and tests DanTerm. `AGENTS.md` carries the command
list; this file carries the reasons behind it and the etiquette that keeps
several agents working on one machine at the same time.

## Running the app in a slot

`just launch-slot` builds without installing, claims an isolated slot from 1
through 8, starts the app detached, waits for its control socket to accept
connections, prints one JSON handle on stdout, and exits. So
`just launch-slot | tail -1` returns the handle, and the app's own output goes
to the slot log under
`~/Library/Caches/com.danneu.danterm-dev-slots/logs/`.

- Suffix `-optimized` for a release-configuration build.
- Suffix `-prime` only when a human is granting a slot notification permission.
  It launches the same way and activates the app.
- Drive the slot with an explicit `danterm --socket` argument every time; do not
  rely on ambient `DANTERM_SOCK`.
- A slot reads and writes a config file of its own, under
  `~/Library/Caches/com.danneu.danterm-dev-slots/config/slot-<n>.json`. It starts
  from defaults, so it does not look like the user's terminal, and Preferences
  and `Open Config` in a slot reach that file rather than
  `~/.config/danterm/config.json`. There is no opt-out: a slot's config path is
  the launcher's. Every launch clears the slot's file first, because a slot number
  is an allocation nobody chose and its last occupant's settings are another
  agent's. A harness that wants the app on a chosen config file itself, outside the
  pool, launches the bundle directly with `--config <path>`, as
  `scripts/terminal-benchmark.sh` does.
- Pass `--seed-config <path>` to start a pooled slot on chosen settings: the
  slot's own file begins as a copy of that document, so a theme, a font size, a
  keybinding, or a config someone reported as broken can be seen in a real app
  without giving up the slot. The named file is only ever read, and the slot still
  reads and writes its own -- Preferences and `Open Config` in a seeded slot reach
  the slot's file. A path the app would refuse (absent, unparseable, or naming
  another `schemaVersion`) fails the command before a slot is claimed and before
  the build runs.
- Pass `--init <path>` to start a pooled slot from a chosen app init file. The
  app reads the named document through its normal `--init` path, while the slot
  still owns its config, socket, checkpoints, bundle, and lock. This makes
  hand-authored restore cases reproducible without launching the bundle outside
  the shared pool.
- Pass `--tailnet` only when you need the slot to open the configured tailnet
  listener on its own derived port. The launcher then copies the tailnet endpoint
  and admitted nodes out of the user's config into the slot's own file, and the
  handle carries a `tailnet` object saying what that listener is doing. It
  composes with `--seed-config`: the seeded document is the base, and the tailnet
  block goes on top. Unlike a seed, an absent or unconfigured endpoint means
  "nothing to copy" rather than a refusal. The copy is a snapshot taken at launch:
  editing the real config does not reach a running slot.
- Pass `--recover` to launch on the checkpoints the slot's previous instance
  left, instead of a new session. This is how the crash-restore path is driven:
  set the slot up, `kill -9` its pid to leave the session lock behind, then
  `just launch-slot --recover`. The slot restores the tabs, panes, cwds, and
  scrollback it last held. Without the flag every launch starts fresh and the
  checkpoints are ignored. A slot's checkpoints belong to whatever ran in that
  slot last, which may be another agent's work -- launch once without the flag
  first if you want a known starting point.

Each slot carries its own app icon: the dev mark, its "dev" badge, and a coloured
disc holding the slot number. That is how a human tells two running slots apart
in the Dock and the Cmd-Tab switcher. The icons are derived from
`icon/raw-dev.svg` by `icon/gen-slot-icon.sh` and compiled into `.build/icons`,
never committed -- eight asset catalogs would add about 13 MB to the repository
and as much again on every change to the mark. The launcher builds the one it
needs before staging, so the first launch after the mark changes pays for one
`actool` run. `just build-slot-icons` compiles all eight, for looking at them.

## Releasing a slot

The pool holds eight slots and every checkout on the machine shares them, so a
slot you abandon is one another agent cannot have. Run `just stop-slot <n>` when
you are done.

`just slots` prints the pool as JSON, naming the checkout holding each busy
slot. `just stop-slots` empties the whole pool, so it belongs to the user, not
to an agent working beside others.

`danterm --socket <slot-socket> quit` is the graceful sibling of
`just stop-slot`: it exits the app the way Cmd-Q does, so the final recovery
checkpoint is written and the session lock is released. Prefer it when you care
about shutdown behavior, and keep `just stop-slot <n>` for a slot that is wedged
or still building.

## The user's build commands

`just build` and `just replace-dev` both overwrite
`~/Applications/DanTerm Dev.app`, and `replace-dev` also quits the running
instance the user may be working in. Do not run either unless asked.
`bash ./dev-build.sh --no-install` is the compile-only form that touches nothing
outside `.build/`. Dev bundle ID `com.danneu.danterm-dev` runs side-by-side with
production `DanTerm.app`. Suffix `-optimized` for a release-configuration dev
build (still not a release or publish operation).

## Test tiers

All tier steps live in `scripts/run-test-suite.sh`, not the justfile. `just test`
runs shipped product estates, `just test-tooling` runs repository-maintenance
contracts, `just test-portability` runs cold and external-platform checks, and
`just test-full` runs their exhaustive union. Product and portability steps carry
their category on the step string; an unmarked step belongs to tooling. Add new
steps to exactly one tier, and only when independent of every other one: no shared
temp path, build directory, port, or socket.

The gate's core budget is machine-wide, shared by every checkout. When other
agents are testing, your steps queue rather than fighting them for cores, and
each queued step reports how long it waited. A slower run beside other runs is
the pool working, not a hang. Use `just test-serial` for the product tier or
`just test-full-serial` for the exhaustive tier when parallel interleaving is in
the way. A benchmark run is the one thing that must not share the pool: it takes
the cores it is measuring with, so a gate run beside it times out on wall-clock
guards it would otherwise pass, and the benchmark's own numbers are unusable --
wait for one to finish before starting the other.

`just test-ui` is excluded from the gate because it needs a WindowServer
connection: it fails headless but runs fine from any shell in a logged-in GUI
session, including an agent's.

Codex only: run SwiftPM-backed test tiers with
[sandbox escalation](https://learn.chatgpt.com/docs/agent-approvals-security).
SwiftPM cannot nest its macOS sandbox inside Codex's.

## Reading test output

Run a suite once, into a file, and grep the file: `just test-ui > .build/ui.log
2>&1`. Re-running a minute-long suite to try a different grep wastes the minute,
and a filter that hides the failing line invites you to blame the wrong test.
Keep it one command; a `;` chain fails the worktree check.

## Worktrees

Run `just provision-worktree` before the first build, then use the same
`just launch-slot` path. See
[worktree-development.md](worktree-development.md).
