# Persisted agent session: degrade locally, validate once

Source: `docs/scratch/2026-08-26-improvement-audit.md` PERSIST-2 (Wave 10), pivoted.

## Problem

A checkpoint or `--init` / Import State file whose `agentSession` is well
typed but invalid (`{"kind": "claude", "sessionId": "bad;id"}`) is rejected
whole by `parseSplitNode` (`lib/DanTermCore/Sources/DanTermCore/Model.swift`,
leaf arm), so one hint field costs every group, tab, and pane. Every other
pane field degrades locally: `fontSizeSteps` clamps, `gridOverride` becomes
no override, and since MODEL-4 (`4ff67477`) an out-of-range split `ratio`
falls back to `0.5`. The agent session is the only value-domain failure
that is fatal.

The same string is also validated twice. `parseSplitNode` builds
`PaneModel.session.lastAgentSession` from the raw DTO, and
`recoveryReplayText` (`AgentSession.swift`) re-validates the raw DTO again
because its only caller, `app/AppRuntime.swift` restore, hands it the
`PaneSnapshot` rather than the pane model it is iterating.

Evidence: DanTerm never writes the rejected state (`Persistence.swift`
serializes an already-validated `AgentSession`), so the reachable inputs are
hand-authored and imported files. Impact is a papercut on a supported
surface, not silent data loss.

## Decision

Adopt the rule the tree already follows after MODEL-4 and make it uniform:

- A JSON **type** error (`{"kind": 42}`) still rejects the file with
  `decodeFailed`. The wire decode stays strict, matching `ratio`,
  `gridOverride`, and `fontSizeSteps`.
- A well-typed **value** outside the domain degrades to the field's neutral
  value: the pane restores with no last agent session and no recovery hint.

Move the validation obligation onto the value: the validated `AgentSession`
carried by the restored pane model is the single source for the recovery
hint. `recoveryReplayText` takes the validated session, not the DTO, and the
restore path in `AppRuntime` reads it from the pane it is already visiting.
The second validator and the fatal guard both disappear.

Not the audit's proposal: the audit asked for a lossy wire decode as well.
That would make `agentSession` the only pane field tolerant of a JSON type
error -- a new outlier -- so it is rejected (RI1).

## Invariants

- I1. A file whose only defect is an invalid `agentSession` value loads; the
  tab and pane are present and the pane's session carries no last agent
  session.
- I2. A file whose `agentSession` is malformed at the JSON type level is
  still rejected as a decode failure.
- I3. A valid persisted `agentSession` restores as the equivalent validated
  session on the pane and produces the same recovery hint as today.
- I4. After validation, recovery code reads only the pane model's
  `lastAgentSession`; nothing consults the snapshot's `agentSession` again.
  The raw DTO stays in the restore's pane-snapshot map untouched (it still
  carries scrollback and launch facts) and is not sanitized.
- I5. An `AgentSession` is immutable once its validating initializer
  succeeds, so a value that reaches `recoveryMessage` is always one the
  initializer admitted.

## Proof obligations

- PO1 (I1): the existing "invalid agentSession value rejects restore" test
  in `lib/DanTermCore/Tests/DanTermCoreTests/SnapshotTests.swift` is rewritten
  to assert the opposite: load succeeds, structure intact, `lastAgentSession`
  nil.
- PO2 (I2): keep "malformed agentSession snapshot rejects restore" unchanged.
- PO3 (I3): a load test with a valid session asserts the pane's
  `lastAgentSession` equals the expected `AgentSession`; the existing
  `recoveryReplayText` composition tests in `AgentSessionTests.swift` keep
  their expected strings.
- PO4 (I4): the "defensively validates a directly constructed agent snapshot"
  tests (`SnapshotTests.swift`, `AgentSessionTests.swift`) are deleted; the
  invalid-DTO input they exercised is no longer expressible at that seam.
- PO5 (I4, runtime handoff): an `app-tests` test following the
  `replayFileIsPrivate` pattern in `app-tests/CreatedFilePrivacyTests.swift`
  drives the runtime's own restore path with a valid persisted session and
  asserts the written replay file contains the expected recovery hint. This
  is the only proof that the runtime feeds the model-owned session, not nil,
  into the replay text.
- PO6 (I5): compile-time; no test.

## Non-goals / Rejected ideas

- Non-goal: changing what DanTerm writes; `Persistence.swift` is untouched.
- Non-goal: changing the `--init` / import diagnostics for decode failures.
- RI1. Lossy wire decode for `agentSession` (the audit's ideal): makes the
  field the sole tolerator of JSON type errors, contradicting the rule every
  other pane field follows.
- Accepted risk AR1: a user who used whole-file rejection as a corruption
  signal for a typo'd session id now gets the session back minus one hint.
  Nothing reads `lastAgentSession` for control flow.

## Verification

- `swift test --package-path lib/DanTermCore --filter SnapshotTests` and
  `--filter AgentSessionTests` red then green per TDD.
- `just lint`, then `just test` before commit (covers `app-tests` for PO5).
- Manual: `just launch-slot` with an init file carrying `"sessionId":
  "bad;id"` restores the pane with no hint; the same file with a valid id
  prints the resume hint in the replayed scrollback.

## After landing

Tick `- [ ] [PERSIST-2]` in the audit's `## Plan of work` and append
`-- done <sha>`.

## Commit progress

- [x] 1. fix(core): degrade invalid persisted agent sessions locally
- [ ] 2. docs(audit): mark PERSIST-2 complete
