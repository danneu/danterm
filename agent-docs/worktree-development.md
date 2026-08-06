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
call:

```sh
SLOT_HANDLE="$(mktemp /tmp/danterm-slot.XXXXXX)"
./scripts/dev-slot-launcher.py > "$SLOT_HANDLE" &
DANTERM_SLOT_PID=$!
while ! SLOT_SOCKET="$(jq -er '.socketPath' "$SLOT_HANDLE" 2>/dev/null)" \
    && kill -0 "$DANTERM_SLOT_PID" 2>/dev/null; do sleep 0.1; done
test -n "${SLOT_SOCKET:-}" && danterm --socket "$SLOT_SOCKET" ls
```

Do not export `DANTERM_SOCK` for a slot. Keeping
`--socket "$SLOT_SOCKET"` at each call site prevents a command from silently
falling back to the user's app.

The handle also contains the slot number, bundle ID, and app PID. The launcher
uses direct exec, so the background PID is the launched app. If all slots are
occupied, the launcher exits with status 75 without launching another app.

Use `just launch-slot-optimized` for an optimized isolated build. Use
`just launch-slot-prime` only when granting a slot notification permission in
the foreground for the first time.

## Pass an allowed environment value

The launcher does not inherit the launching shell's environment wholesale. To
exercise an environment-gated path, name each allowed DanTerm-owned variable.
The allowlist is currently one entry, `DANTERM_PTY_RECORDING_DIR`:

```sh
RECORDING_SLOT_HANDLE="$(mktemp /tmp/danterm-recording-slot.XXXXXX)"
DANTERM_PTY_RECORDING_DIR="$(mktemp -d)" ./scripts/dev-slot-launcher.py \
  --pass-env DANTERM_PTY_RECORDING_DIR > "$RECORDING_SLOT_HANDLE" &
```

There is no backend-selection variable: the Swift engine is the only backend.

See `./scripts/dev-slot-launcher.py --help` for the accepted flags and
`integrations/danterm/SKILL.md` for the source-of-truth `danterm` CLI surface.
