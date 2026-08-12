# Worktree development

Use this workflow when building or running DanTerm from a linked Git worktree.
It provisions shared prerequisites and launches an isolated development app
without quitting, replacing, or focusing the user's canonical app.

## Provision the worktree

Run this once before the first build in a fresh linked worktree:

```sh
just provision-worktree
```

The command symlinks one shared prerequisite -- the primary checkout's
`references/` tree -- into the worktree. Nothing else needs provisioning: the
build compiles from Swift source with no prebuilt library to share. It is safe
to repeat and writes only inside the worktree being provisioned. The primary
checkout must already contain a non-empty `references/`; provisioning never
fetches it, so run `just fetch-references` in the primary checkout first if the
command reports it missing.

## Launch an isolated slot

Use `just launch-slot`, not `just replace-dev`. The latter quits and replaces
the user's canonical dev app. The isolated launcher claims an unattended slot
from 1 through 8 without replacing or focusing the canonical app.

This rule is not worktree-specific -- the primary checkout builds the same
canonical app, so an agent running the app from anywhere in this repo wants a
slot. Provisioning is the only part of this document a worktree adds.

Capture the launcher's JSON handle and pass its socket explicitly on every CLI
call. The launcher starts the app detached, waits for its control socket, and
then exits, so it is a plain command: build output goes to stderr, and the
handle on the last stdout line names a socket that already accepts connections.

```sh
SLOT_SOCKET="$(just launch-slot | tail -1 | jq -er '.socketPath')"
danterm --socket "$SLOT_SOCKET" ls
```

Do not export `DANTERM_SOCK` for a slot. Keeping
`--socket "$SLOT_SOCKET"` at each call site prevents a command from silently
falling back to the user's app.

The handle also contains the slot number, bundle ID, and the detached app's PID.
The app runs in its own session and writes its stdout and stderr to
`~/Library/Caches/com.danneu.danterm-dev-slots/logs/slot-<n>.log`. If all slots
are occupied, the launcher exits with status 75 without launching another app.

Use `just launch-slot-optimized` for an optimized isolated build. Use
`just launch-slot-prime` only when granting a slot notification permission for
the first time; it launches the same way and only lets the app activate and
prompt.

## Share the pool with the other worktrees

The eight slots live in one user-global pool, not in the worktree, so every
checkout and every agent on the machine draws from the same eight. Each launcher
claims one slot for itself and stages its own signed clone of that checkout's
build, so parallel agents test their own changes without seeing each other.

Give the slot back when you are done with it, or the next agent finds the pool
full:

```sh
just slots            # every slot as JSON, with the checkout holding each busy one
just stop-slot 3      # kill slot 3's app and return that slot to the pool
```

`just stop-slots` empties the pool, which takes the slots other agents are
working in. It is the user's command, not an agent's.

A slot stays claimed for its launcher's whole build, so `just slots` reports one
as `"state": "building"` with its checkout and no pid. That slot is not stuck; it
is compiling. Occupancy comes from the slot's lock file, so a killed app frees
its slot without leaving anything to clean up.

## Pass an allowed environment value

The launcher does not inherit the launching shell's environment wholesale. To
exercise an environment-gated path, name each allowed DanTerm-owned variable.
The allowlist currently holds `DANTERM_PTY_RECORDING_DIR` and
`DANTERM_FRAME_RATE_LOG` (a file each pane appends one publish/draw rate sample
to per second):

```sh
RECORDING_HANDLE="$(DANTERM_PTY_RECORDING_DIR="$(mktemp -d)" \
  ./scripts/dev-slot-launcher.py --pass-env DANTERM_PTY_RECORDING_DIR | tail -1)"
```

There is no backend-selection variable: the Swift engine is the only backend.

See `./scripts/dev-slot-launcher.py --help` for the accepted flags and
`integrations/danterm/SKILL.md` for the source-of-truth `danterm` CLI surface.
