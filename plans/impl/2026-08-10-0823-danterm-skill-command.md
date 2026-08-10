# Add `danterm skill`

## Problem

Agents can only obtain DanTerm's operating instructions through skill discovery
or the source tree. DanTerm should expose the instructions shipped with the same
CLI version without requiring skill installation, a running app, or network
access.

## Decision

Add `danterm skill` as a local command that writes the exact bytes of
`integrations/danterm/SKILL.md` to stdout and exits successfully. It writes no
status text or decoration.

Ship that canonical file in both development and release app bundles. Resolve
the executable's symlinks and walk up from that path to the enclosing app
bundle; `Bundle.main` does not identify the app for a helper under
`Contents/Helpers`. Direct and PATH-symlink invocations therefore use the same
version-matched file without depending on the current directory or an installed
agent skill.

Keep the command outside JSON-RPC and socket targeting, alongside the existing
local `help` and `doctor` handling. Arguments or flags are invalid. A missing or
unreadable bundled file produces the normal `danterm:` error and a nonzero exit.

List the command in `danterm help`, the working-tree skill's CLI and stdout
contracts, and the README. Update `doctor` so its missing-skill guidance no
longer says the skill is absent from the app bundle and points to `danterm
skill` for on-demand instructions.

## Invariants

- `integrations/danterm/SKILL.md` remains the sole authored copy.
- The bundled resource and command output are byte-identical to that source.
- The command does not inspect pane targeting or contact the control socket.
- The command works when DanTerm is stopped, when `DANTERM_SOCK` is unusable,
  and when the bundled helper is invoked through a symlink.

## Proof obligations

- Start with a failing CLI test that compares stdout byte-for-byte with the
  canonical source while the configured socket is unusable; cover direct and
  symlink invocation, exit status, stderr, and argument rejection.
- Prove a missing resource fails cleanly without attempting IPC.
- Extend development and release bundle contracts to compare the packaged file
  with the canonical source. Require the resource in both independent ZIP
  round-trip checks: release-build validation in CI and the stable-release
  workflow. These workflow checks are release gates outside `just test`.
- Verify help, the skill contract, README guidance, and `doctor` describe the
  new on-demand path consistently, then run the targeted checks and `just test`.

## Non-goals

- Do not add `danterm skill install`, automatic installation, alternate output
  formats, network lookup, or a JSON-RPC method.
- Keep the existing skill installation paths and Nix skill package for users
  who want automatic agent discovery.

## Implementation discretion

- The internal resource-loading seam beyond executable-path resolution, and the
  exact bundle subdirectory, are left to implementation, provided the invariants
  and failure behavior above hold.
