# Codex permission checks are not waiting activity

## Problem

Pane `F23517E7-2886-48E8-BF55-D74DF487AC04` remained in agent waiting mode
while Codex visibly continued implementing after an automatic approval. The
Codex hook maps every `PermissionRequest` to waiting, but Codex also emits that
event for automatically approved actions and provides no paired event when the
request resolves. The stale report survives until another prompt starts or the
turn stops.

The desired outcome is that DanTerm reports only Codex waits with an explicit,
paired semantic meaning. Routine permission checks must not turn an active pane
into a durable attention state.

## Decision

Ignore Codex `PermissionRequest` events for agent activity. Continue mapping
`request_user_input` to waiting because that event directly states that Codex
needs the user. Preserve the existing prompt, stop, attachment, and detachment
transitions.

Record the corrected boundary in the research decision and measured hook
evidence. Claude's separately measured hook contract does not change.

After this DanTerm commit, remove the now-unused Codex `PermissionRequest`
registration from `~/world` in its own repository and commit.

## Invariants

- A Codex permission check cannot change the pane's agent activity.
- An explicit Codex request for user input still reports waiting.
- Codex prompt submission, turn stop, session attachment, and session
  detachment retain their current activity and lifetime behavior.
- DanTerm does not synthesize a resume transition from timeouts, terminal
  output, or unrelated tool events.

## Proof obligations

- The captured Codex `PermissionRequest` payload produces no DanTerm command;
  this test must fail against the old hook for the reported reason.
- The hook contract test continues to prove the explicit user-input wait and
  every existing root-session lifecycle transition.
- The local gate passes with the corrected hook and documentation.

## Non-goals and rejected ideas

- Do not change the shared agent activity model, IPC, or CLI surface.
- Do not map `PostToolUse` back to working: it is too late for a long-running
  approved tool and cannot repair rejection or cancellation.
- Do not use a timeout: elapsed time cannot distinguish work from a wait.
- Do not change Claude's permission handling in this fix.

## Commit progress

- [x] 1. fix(codex): stop permission checks from leaving panes waiting

  Codex emits `PermissionRequest` for automatically approved actions and
  provides no paired resume event. Ignoring that hook prevents active turns
  from remaining stuck in waiting while preserving explicit
  `request_user_input` waits.
