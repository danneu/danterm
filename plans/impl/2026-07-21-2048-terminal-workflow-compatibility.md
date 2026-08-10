# Milestone 7, Slice 3: Baseline Shell, SSH, and Pager Compatibility

## Summary

Close only the first unchecked Milestone 7 roadmap item by proving zsh, Bash, fish, ssh, fzf, more, and less through controlled real PTYs. Add an opt-in, reproducible live-workflow gate; preserve diagnostic captures from every failure; reduce terminal-semantic failures into deterministic TerminalCore fixtures; and publish dated evidence.

The capability manifest, remaining libvterm protocol classifications, esctest2, external black-box probes, tmux, and advanced applications remain for later slices.

## Interfaces and Gates

- Add `just test-terminal-workflows`, an opt-in headless real-PTY gate requiring no GUI or Accessibility access.
- Provide a Darwin workflow environment, pinned by `flake.lock`, for fish, fzf, and harness tools. Deliberately exercise the macOS-provided zsh, Bash, OpenSSH, more, and less; preflight and record every executable path and version.
- Preserve each run under `.build/terminal-workflow-runs/` with an environment manifest, per-workflow result, PTY recording, terminal snapshots, semantic events, and ownership census. Artifacts survive success or failure, while all spawned processes and temporary services are still cleaned up.
- Add a test-only diagnostic capture operation that can fence and serialize the owner-ordered PTY transitions before failure teardown. Keep the existing app-facing rule that an ordinary characterization recording is exposed only after child-originated session completion.
- Make no user-facing CLI, terminal wire protocol, capability, or app API changes.

## Implementation Changes

### 1. Controlled real-PTY workflow harness

- Run every application through the existing TerminalPTY/TerminalPaneSession boundary, sending normalized text and key input and applying resize through the session owner rather than writing directly to the PTY master.
- Give each workflow an isolated home, shell configuration, history, temporary corpus, locale, prompt, and environment. Source the shipped DanTerm shell integration in zsh, Bash, and fish so the live runs also prove the existing command, cwd, remote-start, and remote-host events without changing their protocol.
- Synchronize on terminal output, semantic events, child state, and process state. Use bounded deadlines only as failure limits, not sleeps as behavioral evidence.
- Launch a per-run loopback sshd on an unprivileged port with generated host/client keys, an isolated authorized-keys file and config, password and agent authentication disabled, and no reads from the user's SSH configuration, known-hosts, agent, or Remote Login service. Accept only the existing `LC_DANTERM_TOKEN` forwarding needed by the shipped integration.
- Replace the current passwordless-localhost dependency in the SSH teardown proof with this controlled host. Leave the existing tmux case and its gate behavior otherwise unchanged.

### 2. Workflow contracts and failure-driven fixes

- For each of zsh, Bash, and fish, prove:
  - cursor-edit and execute a pipeline whose final output is exact;
  - complete a controlled Unicode path or argument with Tab and execute it;
  - run foreground and background jobs, stop with Ctrl-Z, resume with `bg` and `fg`, interrupt or complete them, and observe the expected process-group state;
  - resize while interactive and observe the new PTY geometry;
  - return to the fixed usable prompt after completion, interruption, job-control transitions, and resize.
- For ssh, connect through the shell integration to the controlled host, observe exact Unicode and non-default color semantics, propagate narrow and wide PTY dimensions to the remote helper, disconnect normally, restore the local prompt and shell-event state, and leave no ssh client, remote helper, sshd child, PTY owner, descriptor, source, or session behind.
- For fzf, filter Unicode candidates, navigate to a non-default intended result, resize while its interface is active, accept that result, and recover the prompt without stale alternate-screen state.
- For more and less independently, page a long Unicode corpus, search for a Unicode marker, navigate forward and backward across a resize, quit, and recover an intact prompt.
- On any failure, preserve the raw owner-ordered recording and snapshots before cleanup, classify the failing boundary, and write the failing regression first:
  - terminal parsing, state, resize, reflow, style, or screen behavior becomes a minimized DanTerm-owned TerminalCore fixture with authored, bytewise, and split replay;
  - input encoding, PTY/job-control, lifecycle, shell integration, or harness failures receive deterministic coverage at their own lowest layer;
  - only the concrete workflow blocker is fixed. Do not broaden it into a protocol census or capability tranche.
- Full live recordings remain diagnostic evidence. Only minimized, reviewed cases with stable observable expectations enter the checked-in fixture corpus.

### 3. Evidence and closure

- Add a dated evidence document containing the exact command, OS and tool versions, application-by-application result matrix, resize geometries, shell-event observations, SSH isolation and ownership results, artifact location, and every promoted deterministic regression.
- Add harness contract tests to `just test` covering prerequisite refusal, isolated configuration, failure-artifact preservation, bounded cleanup, diagnostic replay, and protection of the existing completed-session capture semantics.
- Keep real applications and the ephemeral sshd in `just test-terminal-workflows`; keep harness policy tests and all promoted TerminalCore/TerminalPTY regressions in `just test`.
- After both gates pass, mark only the first remaining Milestone 7 checkbox complete and link its judgment to the workflow recipe, evidence document, and deterministic regressions. Leave the protocol/capability and black-box roadmap checkboxes open.

## Test Plan

- Run focused harness self-tests with fake dependencies to prove failures cannot touch user shell or SSH state and cleanup targets only per-run ownership.
- Run focused TerminalPTY tests for input/resize ordering, stopped and resumed process groups, normal exit, forced failure capture, SSH disconnect, and complete ownership release.
- Replay every promoted TerminalCore fixture under authored, bytewise, and split chunking and assert structure-insensitive terminal state, including Unicode, color, alternate-screen restoration, resize, and prompt recovery as applicable.
- Run `just test` to prove the new deterministic coverage and existing capture, lifecycle, shell-event, recording, and fixture contracts remain green.
- Run `just test-terminal-workflows` in the pinned workflow environment and require every shell, SSH, fzf, more, and less row to pass before publishing the evidence or closing the roadmap item.

## Assumptions and Non-goals

- zsh and Bash use `/bin/zsh` and `/bin/bash`; ssh/sshd, more, and less use the supported macOS system versions. fish and fzf come from the flake-pinned workflow environment.
- fzf's successful outcome is the intended accepted Unicode item; more and less exit cleanly to the shell prompt.
- The controlled SSH server runs as the current test user on loopback and requires neither root access nor macOS Remote Login.
- This slice does not run the applications inside tmux or build a direct/SSH/tmux application matrix.
- Capability manifests, remaining libvterm protocol/event dispositions, esctest2, Termless/terminfo probes, vttest/wraptest expansion, and unrelated protocol additions are explicitly deferred to Slice 4.

## Commit progress

- [x] 1. Add the isolated real-PTY workflow harness and diagnostic capture seam
- [x] 2. Prove the shell, SSH, fzf, more, and less workflow contracts
- [x] 3. Publish compatibility evidence and close the first Milestone 7 item
