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
- Pass `--tailnet` only when you need the slot to open the configured tailnet
  listener on its own derived port. The handle then carries a `tailnet` object
  saying what that listener is doing.

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

## The gate

`just test` steps live in `scripts/run-test-suite.sh`, not the justfile. Add new
ones there, and only steps independent of every other one: no shared temp path,
build directory, port, or socket.

The gate's core budget is machine-wide, shared by every checkout. When other
agents are testing, your steps queue rather than fighting them for cores, and
each queued step reports how long it waited. A slower run beside other runs is
the pool working, not a hang. Use `just test-serial` when parallel interleaving
is in the way.

`just test-ui` is excluded from the gate because it needs a WindowServer
connection: it fails headless but runs fine from any shell in a logged-in GUI
session, including an agent's.

Codex only: run `just test` with [sandbox escalation](https://learn.chatgpt.com/docs/agent-approvals-security).
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
