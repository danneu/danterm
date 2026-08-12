# Live semantic event forwarding

Research started: 2026-08-10.

- [findings.md](findings.md) -- the byte-level transport probes and installed
  agent-hook audit.
- [decisions.md](decisions.md) -- the supported forwarding matrix and the
  activity and detach mappings selected for implementation.

## Purpose

This doc owns R2 of the live pane semantic model: establish where DanTerm's
private shell envelope survives, and identify only the activity and lifetime
states that the bundled Claude Code and Codex integrations can report
explicitly.

The investigation does not design a command journal or infer state from screen
contents. A transport passes only when a real process in a real PTY delivers the
authored bytes. An agent state exists only when the installed agent exposes a
hook whose payload distinguishes it.

## Investigation rules

- Run real OpenSSH, mosh, tmux, shell, and PTY binaries. Source inspection may
  select the probe but cannot replace it.
- Capture exact bytes at the outer PTY. A visible screen result is not evidence
  that the private OSC survived.
- Separate near-side wrapper events from far-side integration events. A remote
  command may be detectable even when its transport filters every return event.
- Treat an installed agent binary and a live hook payload as separate evidence.
  A named hook in the binary proves availability; a captured invocation proves
  the payload used by DanTerm.
- Unsupported forwarding is a compatibility limit, not a reason to infer
  semantic state from rendered cells or process inspection.

## Trigger and current evidence

The shell integrations emit raw `OSC 1337;DanTermShell=1` reports. Their SSH and
mosh wrappers emit `remote-start` before launching the real command, and remote
shells report identity from the far side. Before this investigation, no evidence
showed which return paths preserved those bytes. The agent integrations attached
sessions on `SessionStart`, but had no recorded decision for activity or detach.

## Current hypotheses

### H1 -- PTY relays and SSH preserve the envelope byte for byte

Confirmed by 34/F1 and 34/F4. OpenSSH needs the existing `SendEnv=LC_DANTERM`
client option and a server that accepts the variable, but it does not rewrite the
returned OSC.

### H2 -- terminal-state relays preserve arbitrary OSC

Rejected by 34/F2 and 34/F3. Mosh reconstructs terminal state and drops the
private OSC. tmux drops it in its default configuration; its explicit DCS
passthrough path works only when `allow-passthrough` is enabled.

### H3 -- both bundled agents have symmetric end hooks

Confirmed by 34/F5. Claude Code 2.1.226 and Codex CLI 0.147.0 both expose and
invoke `SessionEnd`, so pane teardown is not their only honest detach source.

## Task ledger

- [x] Probe the envelope and `LC_DANTERM` through a real SSH PTY. Recorded in
  34/F1.
- [x] Probe environment and private OSC forwarding through real mosh. Recorded
  in 34/F2.
- [x] Probe raw and explicit passthrough forms through real tmux. Recorded in
  34/F3.
- [x] Probe a plain nested PTY. Recorded in 34/F4.
- [x] Audit installed Claude Code and Codex hooks, then capture the available
  activity and end payloads. Recorded in 34/F5.
- [x] Correct the Codex permission-wait boundary after an automatic approval
  left a working pane stale. Recorded in 34/F6 and 34/D2.
- [x] Select the supported forwarding and agent-state contracts. Recorded in
  34/D1 and 34/D2.

## Rejected

### Infer remote identity or agent state when a transport drops reports

Mosh and default tmux provide no returned private envelope to interpret. Screen
text, process inspection, and silence cannot distinguish the declared states, so
the model keeps those facets absent or at remote-without-identity.

### Treat every agent hook as an activity state

Tool completion, subagent lifetime, compaction, and notification hooks describe
events, not the attached root agent's current activity. Only the transitions in
34/D2 enter the activity facet.

## Open questions and caveats

- Claude Code was not logged in on the probe machine. Its `UserPromptSubmit` and
  `SessionEnd` hooks invoked before the authentication failure; the installed
  binary and the repository's existing live fixture establish the remaining
  hook names, but this run did not obtain fresh authenticated waiting and stop
  payloads.
- The tmux probe covered one tmux layer. A nested tmux stack needs one passthrough
  wrapper per layer and is not claimed.
- Mosh 1.4.0 accepted `LC_DANTERM` on the remote side but filtered the private
  OSC on the return path. A future mosh terminal protocol could change that.

## Outcome

Investigation closed. Direct PTYs, nested PTYs, and SSH carry the live envelope.
Mosh supports only the near-side connection lifetime. tmux supports the envelope
only through its explicit DCS form with `allow-passthrough` enabled. Both bundled
agents can report working, waiting, idle, and detach through the exact hook
mappings in 34/D2; Codex permission checks are excluded because they cannot
distinguish an automatic approval from a user-blocked wait.
