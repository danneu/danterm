# Decisions

### D1 -- support byte-preserving transports and name filtered paths

- Status: selected.
- Evidence used: F1 through F4.
- Candidate solutions: claim every wrapper transport; support only raw
  byte-preserving paths; or add the one explicit passthrough form the measured
  transport provides while retaining honest limits elsewhere.
- Tradeoffs and correctness risks: claiming mosh or default tmux would turn
  missing reports into stale or fabricated state. Dropping tmux entirely would
  ignore its measured explicit transport. Enabling a user's tmux server option
  from a sourced shell integration would mutate unrelated terminal policy.
- Selected direction:
  - Direct PTYs, plain nested PTYs, and SSH support the complete envelope.
  - Under tmux, wrap the private envelope in tmux DCS passthrough. Support is
    conditional on the user's `allow-passthrough` policy already being enabled.
  - Under mosh, support only the near-side `remote-start` and `connection-end`
    emitted around the local mosh process. The far-side facets remain absent,
    and the connection remains remote-without-identity.
- Behavioral verification: F1 and F4 captured exact raw events; F3 captured the
  exact inner OSC only through enabled DCS passthrough; F2 supplied a positive
  environment control while returning no private OSC.
- Decision and rationale: semantic state follows delivered declared events.
  Compatibility limits stay visible in the facet rather than being covered by
  inference.

### D2 -- map only explicit root-agent lifecycle hooks

- Status: selected.
- Evidence used: F5 and the existing production notification hook's distinction
  between a real root stop, a blocking prompt, a subagent stop, and a root parked
  on background work.
- Candidate solutions: infer activity from terminal output; map every agent
  hook; or select only hooks that directly name a root-session transition.
- Tradeoffs and correctness risks: screen inference violates the semantic-source
  boundary. Mapping every hook makes tool calls and subagent activity overwrite
  the attached root session. The narrow mapping may omit intermediate work that
  neither agent reports, but never claims a state without evidence.
- Selected direction:
  - `SessionStart` attaches the session and starts it as working.
  - `UserPromptSubmit` reports working.
  - A root `PreToolUse` for `AskUserQuestion` or `request_user_input`, a blocking
    `PermissionRequest`, or Claude `Elicitation` reports waiting.
  - A genuine root `Stop` reports idle. A stop that the existing Claude fixture
    proves is only parking on live background work does not report idle.
  - `SessionEnd` detaches the matching session.
  - Subagent hooks and events carrying a different agent identity do not mutate
    the attached root session's facet.
- Behavioral verification: Codex live fixtures captured request-user-input and
  completion at the exact hooks. Both installed agents invoked `SessionEnd`;
  the existing Claude live fixture pins its wait-versus-park classification.
- Decision and rationale: these are the smallest activity and lifetime sets
  both integrations can state honestly. Missing transitions remain absent
  rather than inferred.
