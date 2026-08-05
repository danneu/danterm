# Worktree development

Use this workflow when building or running DanTerm from a linked Git worktree.
It provisions shared prerequisites and launches an isolated development app
without quitting, replacing, or focusing the user's canonical app.

## Provision the worktree

Run this once before the first build in a fresh linked worktree:

```sh
just provision-worktree
```

The command links the primary checkout's cached
`lib/GhosttyKit.xcframework`, themes, and reference sources into the worktree.
It is safe to repeat and writes only inside the worktree being provisioned. The
primary checkout must already contain those inputs; provisioning never fetches
or rebuilds them.

## Launch an isolated slot

Use `just launch`, not `just build-run`. The latter quits and replaces the
user's canonical dev app. The isolated launcher claims an unattended slot from
1 through 8 without replacing or focusing the canonical app.

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

Use `just launch-optimized` for an optimized isolated build. Use
`just launch-prime` only when granting a slot notification permission in the
foreground for the first time.

## Pass an allowed environment value

The launcher does not inherit the launching shell's environment wholesale. To
exercise an environment-gated path, name each allowed DanTerm-owned variable:

```sh
SWIFT_SLOT_HANDLE="$(mktemp /tmp/danterm-swift-slot.XXXXXX)"
DANTERM_TERMINAL_BACKEND=swift ./scripts/dev-slot-launcher.py \
  --pass-env DANTERM_TERMINAL_BACKEND > "$SWIFT_SLOT_HANDLE" &
```

See `./scripts/dev-slot-launcher.py --help` for the accepted flags and
`integrations/danterm/SKILL.md` for the source-of-truth `danterm` CLI surface.
