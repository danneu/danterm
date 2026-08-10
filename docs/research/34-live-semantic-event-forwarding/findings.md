# Findings

### F1 -- OpenSSH preserves the environment and returned envelope

- Status: settled.
- Date and investigator: 2026-08-10, Codex.
- Commit and worktree state: `01cf9d35`; the live semantic plan had intentional
  unstaged edits, and unrelated untracked files were present.
- Commands, inputs, or reproduction: OpenSSH 10.2p1 connected to a temporary
  unprivileged `sshd` on `127.0.0.1:22222`. The client set `LC_DANTERM=1` and
  `SendEnv=LC_DANTERM`; the server set `AcceptEnv LC_DANTERM`. Remote zsh and
  Bash sourced the repository integrations. Captures allocated a real PTY at
  every SSH layer and hex-encoded the outer byte stream.
- Measurements or examples:
  - The remote process printed `LC_DANTERM=<1>`.
  - A far-side zsh emitted, in order, `remote-host`, `command-start;probe`, and
    `command-end`; the outer capture contained the exact OSC bytes and ST
    terminators.
  - A nested trace with distinct synthetic identities produced `outer identity,
    remote-start, inner identity, outer identity` in that exact order.
- Observation: SSH forwards the opt-in marker when the server accepts it and
  returns the private envelope byte for byte. The existing wrapper's identity
  re-report after nested SSH is observable at the outer terminal.
- Inference: SSH supports every declared shell event. A connection-end emitted
  after the near-side `ssh` command returns does not traverse SSH at all; a
  nested far-side wrapper's reports also survive because they travel through
  the same byte-preserving channel.
- Uncertainty: servers that do not accept `LC_DANTERM` never load the remote
  integration. They remain remote-without-identity, which is a valid steady
  state rather than a failed transition.

### F2 -- mosh passes the marker but filters the private OSC

- Status: settled.
- Date and investigator: 2026-08-10, Codex.
- Commit and worktree state: `01cf9d35` plus the plan edits described in F1.
- Commands, inputs, or reproduction: mosh 1.4.0 connected through the F1 SSH
  server in an 80x24 PTY. One remote command printed `LC_DANTERM`; another
  emitted only `OSC 1337;DanTermShell=1;connection-end ST`.
- Measurements or examples: the environment probe rendered
  `LC_DANTERM=<1>`. The byte probe's outer capture contained mosh's alternate
  screen and cursor updates but no `DanTermShell`, `1337`, or `connection-end`
  bytes.
- Observation: mosh transfers `LC_DANTERM` to the remote process, but its
  terminal-state protocol does not return arbitrary private OSC.
- Inference: the local wrapper can authoritatively emit detection before mosh
  and connection-end after mosh returns. Far-side integration-ready, command,
  identity, and nested connection reports are unavailable, even though the
  remote shell can see the marker.
- Competing interpretations: the remote process might not have emitted. The
  same script produced the exact OSC through `script(1)` in F4, so the stimulus
  could and did produce a positive result outside mosh.
- Uncertainty: this pins mosh 1.4.0, not every future terminal-state protocol.

### F3 -- tmux requires explicit DCS passthrough

- Status: settled.
- Date and investigator: 2026-08-10, Codex.
- Commands, inputs, or reproduction: tmux 3.6a ran a one-shot zsh command in a
  real PTY with an empty config. The command first emitted raw
  `OSC 1337;DanTermShell=1;connection-end ST`. A second run enabled
  `allow-passthrough on` and emitted the OSC inside `DCS tmux; ... ST`, doubling
  embedded ESC bytes as tmux requires.
- Measurements or examples: the raw run's outer capture contained no
  `DanTermShell` bytes. The explicit passthrough run contained the exact inner
  `OSC 1337;DanTermShell=1;connection-end ST` sequence.
- Observation: default tmux filters the private OSC. DCS passthrough preserves
  it only when the option is enabled.
- Inference: a shell integration under tmux must use the DCS form, and DanTerm
  can claim support only for sessions whose tmux policy enables passthrough.
  Silently changing the user's tmux server policy from a shell hook is not part
  of this slice.
- Competing interpretations: a malformed OSC might explain the null result.
  F4 emitted the same raw bytes successfully, and the DCS run delivered those
  same bytes after correcting the required doubled inner ESC terminator.
- Uncertainty: nested tmux was not probed.

### F4 -- a plain nested PTY preserves the envelope

- Status: settled.
- Date and investigator: 2026-08-10, Codex.
- Commands, inputs, or reproduction: macOS `script(1)` allocated a child PTY
  and ran zsh, which emitted `OSC 1337;DanTermShell=1;connection-end ST`.
- Measurements or examples: after `script(1)`'s local control prefix, the outer
  capture contained hex
  `1b5d313333373b44616e5465726d5368656c6c3d313b636f6e6e656374696f6e2d656e641b5c`.
- Observation: the nested PTY forwarded every byte, including the ST
  terminator.
- Inference: ordinary nested shells and PTY relays need no transport-specific
  envelope encoding.
- Uncertainty: an application that parses terminal output is a terminal-state
  relay, not a plain PTY relay; mosh and tmux are covered separately.

### F5 -- installed agents expose exact activity and end hooks

- Status: settled with the Claude authentication caveat below.
- Date and investigator: 2026-08-10, Codex.
- Commands, inputs, or reproduction:
  - Codex CLI 0.147.0 ran the repository's bounded live notification fixtures
    for `root-question` and `root-completes`, plus a hook-only turn interrupted
    after startup to capture `SessionEnd`.
  - Claude Code 2.1.226 ran with command hooks registered for session, prompt,
    tool, permission, and stop events. It reached hook dispatch before reporting
    that the account was not logged in. Its installed binary's hook registry and
    the repository's existing live fixture were audited for the other surfaces.
- Measurements or examples:
  - Codex `SessionStart` carried `session_id` and `source=startup`;
    `UserPromptSubmit` carried the same session id and a `turn_id`.
  - Codex waiting for user input emitted `PreToolUse` with
    `tool_name=request_user_input`, the questions payload, and the session and
    turn ids.
  - Codex completion emitted `Stop` with `last_assistant_message`, session id,
    and turn id. Interruption emitted `SessionEnd` with `reason=other`.
  - Claude invoked `UserPromptSubmit` with session id and prompt id, then
    `SessionEnd` with the same ids and `reason=other`, despite the later
    authentication failure.
  - Claude's installed registry exposes `PreToolUse`, `PermissionRequest`,
    `Elicitation`, `Stop`, `SessionStart`, and `SessionEnd`; the existing
    `scripts/agent-notifications-live.py` fixture distinguishes blocking
    `AskUserQuestion`, permission, and elicitation events from completion and
    subagent events.
- Observation: both agents have explicit root-session start, prompt-submit,
  wait, stop, and session-end surfaces. Neither requires command-end or pane
  teardown to manufacture an agent lifetime transition.
- Inference: the activity subset in D2 is genuinely reportable. Subagent
  start/stop and background-task parking do not detach the attached root session
  and do not independently define its activity.
- Uncertainty: fresh authenticated Claude waiting and stop payloads were not
  captured in this run. Their availability is supported by the installed hook
  registry and the repository's already-shipped live fixture, not by a new live
  authenticated trace.
