# Milestone 7, Slice 2: Native Shell-Event Protocol and Legacy Retirement

## Summary

Replace the temporary OSC 0 `__DANTERM_EVT__` shim with one authenticated, versioned, non-title protocol decoded directly into typed TerminalCore events. Migrate repo-owned zsh, bash, fish, SSH, and mosh integrations in the same slice, preserve current model/recovery/theme behavior, and remove the legacy encoding without a compatibility period.

## Wire Protocol and Interfaces

- Define the DanTerm-private envelope, terminated by BEL, `ESC \`, or C1 ST (`0x9C`); shipped emitters use `ESC \`:

```text
OSC 1337;DanTermShell=1;<token>;command-start;<base64-command>
OSC 1337;DanTermShell=1;<token>;command-end
OSC 1337;DanTermShell=1;<token>;remote-start
OSC 1337;DanTermShell=1;<token>;remote-host;<base64-user>;<base64-host>
```

- `<token>` is the pane session's fresh random UUID token. Base64 uses the RFC 4648 standard alphabet, required padding, and no whitespace.
- Command, user, and host fields must decode to non-empty valid UTF-8. A command payload, or the combined user and host payload of one remote-host event, is limited to 64 KiB. The complete encoded OSC content is limited to 88 KiB, covering the base64 expansion and fixed envelope overhead for any valid maximum-size event.
- Reject unknown versions/events, wrong field counts, malformed or non-canonical base64, invalid UTF-8, empty fields, oversized envelopes, and missing/wrong tokens without semantic, title, or model effects. Later valid input must still parse.
- Replace `.legacyPrivateShell` with typed TerminalCore events for command started, command ended, remote started, and remote user/host. Mirror these in `TerminalSessionEvent` and map them directly to the existing pane-scoped `Msg` cases.
- Thread the token explicitly through `TerminalSessionRequest`, the Swift PTY/session owner, and TerminalCore configuration while also injecting it into the child environment. Do not recover authentication state from ambient environment variables or retain a runtime pane-token lookup table.

## Behavioral and Integration Changes

- Authentication occurs before TerminalCore admits a semantic event. Authenticated events retain the existing 100-event discrete FIFO and participate by decoded byte cost in the existing 256 KiB core, 256 KiB handoff, and 512 KiB model budgets.
- The wire contains no pane identifier. Only the PTY/session adapter binds a typed event to its owning `PaneId`; a token copied from another pane is rejected, and terminal output cannot redirect an event across panes.
- Keep `DANTERM_TOKEN` for the local shell and `LC_DANTERM_TOKEN` for SSH forwarding. Each integration copies the token into a non-exported shell variable and immediately unsets the environment value. Forwarding grants the remote shell authority only over the originating pane; restored or recreated sessions receive fresh tokens.
- Add canonical sourceable zsh, bash, and fish assets under the shell integrations, and ship them at stable `Contents/Resources/shell-integration/` paths. README installation instructions point to these assets; integration remains opt-in rather than automatically injected.
- Support macOS Bash 3.2 and newer by vendoring pinned `bash-preexec` 0.6.0 with its MIT license and provenance. Preserve existing `PROMPT_COMMAND`, DEBUG traps, zsh hook arrays, and fish event handlers; sourcing any integration repeatedly must not duplicate events or wrappers.
- Local shell behavior is identical across shells: emit one command-start with the complete command, one command-end when the prompt returns, and OSC 7 cwd metadata at the local prompt. SSH/mosh wrappers emit remote-start before launch; SSH forwards the token, remote shells report user/host, and nested SSH restores the outer host report on return.
- Shell integrations emit no OSC 0 title updates. Ordinary application title handling remains unchanged, while cwd, command recovery, and checkpoint freshness come from OSC 7 and typed shell events.
- Preserve existing model semantics:
  - command-start updates `lastCommand` and schedules a checkpoint;
  - local cwd reports update recovery cwd and schedule a checkpoint;
  - remote-start clears stale host metadata and applies the remote theme override;
  - remote-host updates the pane-scoped label without reapplying an established override;
  - command-end clears remote state, remote theme override, and agent attachment, scheduling the existing agent-detach checkpoint when applicable.
- Atomically delete TerminalCore `__DANTERM_EVT__` recognition, `.legacyPrivateShell`, `DantermEvent`, `parseDantermEvent`, title-based `translateMsg`, `PaneTokenStore`, AppRuntime translation, legacy tests, and the shell title workaround. No feature flag or dual decoder remains.
- Update the protocol component plan, roadmap, open-question ledger, README, bundled-resource checks, and `integrations/danterm/SKILL.md`. The CLI command surface is unchanged; the skill documents the bundled integrations and treats the token as a private capability that agents must not print or synthesize.

## Test Plan

- TerminalCore tests prove all four typed events, stream ordering, every byte split/chunk partition, BEL, `ESC \`, and C1 ST termination, exact decoded and encoded limits, shared metadata/count bounds, malformed and oversized recovery, unknown-version rejection, and wrong-token rejection.
- Title-isolation tests prove native events never mutate title or title-fallback state, interleaved ordinary titles remain independent, and shipped shell output contains no OSC 0 sequence.
- Direct zsh/bash/fish harnesses prove identical command text and boundaries, Unicode/special-character preservation, idempotent sourcing, prior-hook preservation, token unsetting, SSH argument and `SendEnv` preservation, local/remote precedence, remote-host reporting, nested SSH behavior, mosh fast-start behavior, and byte-for-byte protocol parity.
- Real-PTY tests launch each shell with isolated configuration, execute a command, and prove typed event delivery through TerminalCore and the pane session without render dependence. Two-pane cases prove ownership and cross-token rejection.
- Engine-to-model tests prove the native path preserves command tracking, recovery snapshots, remote state/labels, remote theme entry/exit, agent cleanup, metadata budgets, and existing checkpoint decisions without title translation.
- A retirement audit covers production sources, active integration assets, README, and active protocol plans for the absence of `__DANTERM_EVT__`, `.legacyPrivateShell`, and the removed translators. Historical implementation plans need not be rewritten.
- Add the shell harness to `just test` and a Nix check supplying zsh, Bash, and fish; keep build-bundle validation for all shipped shell resources. The full local gate must pass before marking Slice 2 complete.

## Assumptions and Non-goals

- Native shell metadata is intentionally unavailable on the temporary Ghostty development backend after this slice. No IPC bridge, legacy fallback, or Ghostty removal is included.
- With all special recognition deleted, arbitrary third-party OSC 0 text beginning `__DANTERM_EVT__` follows ordinary OSC 0 title rules. The no-pollution guarantee applies to the new protocol and migrated emitters.
- This slice does not add generic OSC 133 semantic-prompt support, command exit-status modeling, automatic shell injection, remote cwd ownership, or new CLI commands.

## Commit progress

- [x] 1. Replace legacy title events with authenticated native shell events
- [x] 2. Ship sourceable shell integrations with direct and PTY coverage
- [x] 3. Close packaging, documentation, and retirement gates
