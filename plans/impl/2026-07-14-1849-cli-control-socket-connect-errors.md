# Correct CLI control-socket connection errors

## Summary

Distinguish an unavailable DanTerm instance from sandbox/permission failures
and other connection errors. This changes only CLI stderr; commands, JSON-RPC,
stdout, and exit status remain unchanged.

## Implementation Changes

- In `connectSocket`, capture `errno` immediately after failed `connect(2)` and
  before closing the descriptor, then map it through a private CLI error helper.
- Keep the exact stderr contract below; the existing top-level handler supplies
  the `danterm: ` prefix.

| `connect` error | Stderr |
|---|---|
| `ENOENT`, `ECONNREFUSED` | `danterm: DanTerm is not running` |
| `EACCES`, `EPERM` | `danterm: cannot access control socket (sandbox or permissions): <path>` |
| Any other errno | `danterm: cannot connect to control socket (<POSIX reason>): <path>` |

- Close the socket exactly once on every failed connection. Do not change socket
  creation, timeout, read/write, retry, or auto-launch behavior.
- Update `integrations/danterm/SKILL.md` so agents distinguish "not running"
  from access denial, surface the latter to the user, and do not retry blindly.

## Test Plan

- Practice TDD by first adding
  `scripts/tests/danterm-cli-connect-errors_test.sh` and confirming the
  access-denied and generic-error cases fail with the current implementation.
- Build only the `DanTermCLI` product, never assemble, install, launch, quit, or
  signal either DanTerm app.
- Give every subprocess an explicit unique temporary `DANTERM_SOCK`; never read
  or connect to the inherited/live socket.
- Cover these observable cases, asserting exit 1, empty stdout, and exact
  stderr:
  - Missing socket (`ENOENT`) keeps "DanTerm is not running".
  - Bound-then-closed temporary Unix socket (`ECONNREFUSED`) keeps "DanTerm is
    not running".
  - Socket path inside a non-searchable temporary directory (`EACCES`) reports
    the access error and path.
  - Socket path beneath a regular-file component (`ENOTDIR`) reports the generic
    connection error, POSIX reason, and path.
- Set `LC_ALL=C` in the generic-error case so the `strerror` text is
  deterministic.
- Add the new GUI-free script to `just test`, then run the script and the full
  `just test` gate. Do not run `just test-cli`, `dev-build`, `build-run`, `open`,
  or `pkill`.
- Keep the existing live-app smoke test unchanged; do not add a production test
  hook or restructure module boundaries solely to synthesize `EPERM`. The
  deterministic `EACCES` case pins the shared access-denied contract.

## Assumptions

- Socket paths are printed verbatim for diagnosis.
- Unexpected errors include the human-readable POSIX reason, as selected.
- No server, protocol, README, historical plan, or release workflow changes are
  needed.
- The currently running DanTerm session is a hard exclusion throughout
  implementation and verification.
