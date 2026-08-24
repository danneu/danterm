# Shared Agent Integration Registry

## Problem and desired outcome

DanTerm separately enumerates Claude and Codex in session presentation, doctor
fact gathering, doctor evaluation, and the `jq` gate. A third supported agent
could therefore appear in one subsystem but remain absent from another.

Replace these parallel lists with one ordered registry in `DanTermProtocol`.
Core session presentation, doctor probing, doctor facts, CLI checks, and `jq`
gating derive from it. This change prepares for a third agent without adding
that agent now.

## Decision

- Add a public, `CaseIterable` agent integration identity with `claude` then
  `codex` as its stable order.
- Each integration declares its session presentation, resume command policy,
  user-facing doctor name, home resolution policy, hook sources, and bundled
  session-hook name. Doctor config labels derive from the home policy's declared
  display form and the hook-source policies instead of restating their paths as
  free text or exposing a machine's resolved path.
- Preserve the current policies:
  - Claude uses `$HOME/.claude`, reads JSON hooks from `settings.json`, uses the
    Claude chip, and resumes with `claude --resume <id>`.
  - Codex uses a trimmed non-empty `CODEX_HOME` or `$HOME/.codex`, reads JSON
    hooks from `hooks.json` plus best-effort TOML hooks from `config.toml`, uses
    the Codex chip, and resumes with `codex resume <id>`.
  - Each integration's skill paths derive from its resolved home plus the shared
    `$HOME/.agents/skills/danterm` root.
- Replace the named Claude and Codex fields in `DoctorFacts` with a total
  per-integration facts value. Its only construction resolves one fact for every
  registry case, its lookup is non-optional, and its iteration follows registry
  order. Missing, duplicate, and misordered facts are unrepresentable. This is a
  source-breaking protocol API refactor, but it changes no wire format.
- Interpret declarative home and hook-source policies in `DanTermSupport`.
  `DanTermProtocol` stays free of filesystem resolution and IO.
- Derive agent check identity from the integration and the hook-or-skill check
  kind. Generate both rows for every gathered integration and derive the `jq`
  gate from all gathered hook facts.

## Invariants

- Within the Swift subsystems, a supported integration cannot appear in session
  presentation without also receiving doctor fact gathering and doctor rows.
- Registry order controls doctor row order. Existing Claude and Codex rows keep
  their current order.
- `danterm doctor` keeps its current text, footer, exit status, flags, and stdout
  shape. Any CLI surface or stdout-shape change requires
  `integrations/danterm/SKILL.md` in the same change.
- Unknown reported agent kinds keep the generic chip, capitalized display text,
  and no resume command.
- Claude and Codex keep their different home resolution, hook formats, parse
  error behavior, skill discovery, and resume commands.
- `DanTermCore` and `DanTermSupport` remain siblings that depend only on the
  portable `DanTermProtocol` declarations they share.
- Adding an integration still requires its hook implementation and the explicit
  bundle and Nix packaging entries that ship and test that asset.

## Proof obligations

- Prove every registry case produces one hook row and one skill row in registry
  order.
- Prove every registry raw value is accepted as an `AgentSession` kind.
- Prove all non-agent doctor rows retain their current order and behavior.
- Characterize Claude home resolution and JSON-only hook discovery.
- Characterize the Codex `CODEX_HOME` override, absent and blank fallback,
  combined JSON and TOML discovery, and JSON-only parse errors.
- Preserve the current hook and skill status ladders, bundled-hook remedies, and
  `jq` behavior for both integrations.
- For every registry case, prove the agent catalog returns the registry's
  declared display name, a non-generic chip kind, and a resume command. Keep the
  exact Claude and Codex values pinned, plus the unknown-agent fallback.
- Add an exact full-report characterization for the current `danterm doctor`
  stdout and exit behavior.
- Follow TDD for each behavioral change. Run the affected protocol, core,
  support, and CLI suites with `just lint` during development, then `just test`
  before commit.

## Non-goals

- Do not add or speculate about the third agent's identity or configuration.
- Do not redesign chip artwork generation, hook payload handling, bundle
  contents, Nix packaging, or CLI output. These assets are genuinely
  agent-specific and remain explicit manual additions for a new integration.
- Do not turn arbitrary reported agent kinds into supported integrations. They
  continue through the existing generic fallback.

## Implementation discretion

- Helper decomposition is discretionary if portability and sibling-module
  independence stay proven.
