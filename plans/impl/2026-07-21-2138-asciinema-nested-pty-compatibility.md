# Milestone 7, Slice 3b: Asciinema Nested-PTY Compatibility

## Problem and desired outcome

The baseline terminal workflow gate proves direct shells and applications but
does not prove an application that owns an intermediate PTY. Extend that gate
with the flake-locked asciinema 2.4.0 and prove recording plus local playback
through `TerminalPaneSession -> asciinema -> nested PTY -> interactive job`.
This adds evidence without closing another Milestone 7 checkbox.

## Decision

- Add asciinema to the existing `terminal-workflows` development shell and
  extend `just test-terminal-workflows`; keep `flake.lock` unchanged.
- Record the executable path and version during preflight. Missing asciinema is
  a prerequisite refusal with preserved diagnostics.
- Preserve the standard workflow artifacts plus the asciicast and a validation
  report under an `asciinema` workflow directory.
- Keep asciicast diagnostic-only. Make no product API, terminal protocol,
  DanTerm CLI, capability, or native fixture-format change.

## Behavioral contract

- An isolated outer zsh starts asciinema with stdin capture, overwrite, and
  quiet operation and records an interactive `/bin/zsh -f` with a fixed prompt,
  controlled `SHELL`, and `TERM`.
- The nested session emits an exact non-ASCII marker in a non-default color;
  stops, backgrounds, foregrounds, and interrupts a foreground job with prompt
  recovery; observes a resize from 80x24 to 53x17; exits normally; and restores
  the outer prompt.
- The generated asciicast v2 stream has a version 2 header with the controlled
  environment and initial geometry, output containing the exact UTF-8 marker
  and color sequence, captured input, a 53x17 resize event, and no malformed or
  unsupported required fields.
- After restoring the outer pane to at least 80x24, accelerated local playback
  reproduces the marker and color semantics, completes normally, and restores
  the outer prompt without stale cursor, style, or alternate-screen state.
- Failure evidence is captured before cleanup. Recorder, nested shell, job,
  pane session, PTY owner, descriptors, and dispatch sources are released and
  censused on every outcome.

## Proof obligations

- Deterministic harness tests reject missing asciinema, an omitted manifest
  version, and missing asciinema workflow artifacts.
- Synthetic valid and malformed v2 streams prove cast validation, including
  missing output, input, and resize evidence.
- `just test` preserves deterministic workflow, capture, lifecycle, and cleanup
  contracts.
- `nix develop .#terminal-workflows -c just test-terminal-workflows` passes the
  existing seven workflows plus asciinema.
- Dated evidence records commands, version, cast contract, nested job control,
  resize, playback, ownership, artifacts, and any promoted regressions. The
  Milestone 7 roadmap links this plan and evidence while leaving protocol and
  black-box items open.

## Non-goals and accepted risk

- Upload, streaming, browser playback, authentication, network behavior,
  asciinema 3.x compatibility, and checked-in asciicast fixtures are out of
  scope.
- The slice accepts proving only flake-pinned asciinema 2.4.0 because v2 covers
  the targeted nested-PTY behavior.

## Implementation discretion

- Cast parser placement and the exact controlled marker/job command are left to
  implementation as long as the observable contract and deterministic tests
  hold.
