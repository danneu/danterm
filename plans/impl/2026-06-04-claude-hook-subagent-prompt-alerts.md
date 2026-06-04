# Fix Claude Hook Subagent Prompt Alerts

## Summary

Update the Claude Code OSC 777 hook so it suppresses subagent completion noise
but still alerts when any agent is blocked on user input.

Current Claude Code docs support this split: `Stop` is main-agent completion,
`SubagentStop` is subagent completion, `agent_id` is the subagent
discriminator, and `Elicitation` covers MCP-driven user input dialogs.
`agent_type` is metadata and can also appear for main sessions started with
`claude --agent`, so it must not be used to decide whether a hook is from a
subagent. `terminalSequence` remains the right hook output for emitting
terminal OSC notifications.

## Key Changes

- Replace the global `agent_id` early exit in
  `integrations/claude-code/claude-notify-osc777.sh` with event-specific
  filtering. Use only non-empty `agent_id` to detect subagent context; never
  treat `agent_type` alone as a subagent signal.
- Keep completion behavior quiet for subagents:
  - `Stop` without `agent_id`: emit a `"Claude Code"` notification using
    `last_assistant_message`.
  - `Stop` with `agent_type` but no `agent_id`: emit like any other main-agent
    `Stop`.
  - `Stop` with `agent_id`: silent defensive fallback.
  - `SubagentStop`: silent.
- Notify for blocking prompts regardless of top-level vs subagent context:
  - `PreToolUse` + `AskUserQuestion`: emit `"Claude has a question"`.
  - `PermissionRequest` + `AskUserQuestion`: stay silent to avoid duplicating
    the `PreToolUse` alert.
  - Other `PermissionRequest` events, including subagent ones: emit the
    existing permission messages.
  - `Elicitation`: emit a sanitized generic input-needed notification derived
    from `.message`, with fallback text if `.message` is absent.
- Add `Elicitation` to every recommended hook configuration that installs this
  script: the README JSON example and the user's Nix/Home Manager hook config
  in `~/world/common/claude-code.nix`.
- Update the hook comment and README integration note to document the policy:
  final top-level turn alerts, subagent stop spam is suppressed, subagent
  blocking prompts still alert, including MCP elicitation dialogs.

## Test Plan

- TDD first in `integrations/claude-code/claude-notify-osc777.test.sh`.
- Change these existing expectations to fail red before the hook edit:
  - `Stop` with `agent_type` but no `agent_id` emits the sanitized
    `last_assistant_message`.
  - `PreToolUse` + `AskUserQuestion` + `agent_id` emits
    `"Claude has a question"`.
  - `PermissionRequest` + `Bash` + `agent_id` emits
    `"Claude wants to use Bash"`.
- Add red-driving `Elicitation` expectations before the hook edit:
  - Top-level `Elicitation` emits the sanitized `.message`.
  - `Elicitation` + `agent_id` emits the sanitized `.message`.
  - `Elicitation` without `.message` emits fallback input-needed copy.
- Keep or add silent completion coverage:
  - `Stop` + `agent_id` stays silent.
  - `SubagentStop` + `agent_id` stays silent.
- Add duplicate-prevention coverage:
  - `PermissionRequest` + `AskUserQuestion` + `agent_id` stays silent.
- Verify:
  - `./integrations/claude-code/claude-notify-osc777.test.sh`
  - `nix build .#checks.aarch64-darwin.claude-notify-osc777 -L`

## Assumptions

- Chosen policy: alert for all blocking subagent prompts, not just explicit
  questions.
- `agent_type` is informational only for this hook. Filtering and suppression
  must key on `agent_id` or the explicit `SubagentStop` event name.
- User-side hook installation needs a settings-shape change for `Elicitation`;
  rebuilding the existing hook package alone is not enough for MCP elicitation
  dialogs.
- Do not add `SubagentStop` to the recommended Claude settings examples; the
  script should still handle it silently if configured elsewhere.
- Do not change DanTerm app notification throttling, OSC 777 handling, or
  Claude native notification settings.

## Implementation notes

- The user requested the out-of-repo `~/world/common/claude-code.nix` change
  land in a second `/Users/dan/world` commit after the DanTerm commit, because
  that file is not tracked by this repository.
