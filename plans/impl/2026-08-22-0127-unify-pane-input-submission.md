# Unify pane input submission

Source: PANE-5 in
`docs/scratch/2026-08-18-construction-audit.md`, verified against master
`9b958843` on 2026-08-22.

## Problem and outcome

Pane input crosses the pure command boundary and the AppKit session boundary
through four operations: paste-style text, raw keyboard text, keys, and wheel
steps. Each operation has separate fire-and-forget and completion-taking
session implementations. The command interpreter also repeats the same session
lookup, missing-pane rejection, and completion routing for every operation.

The copies are not a live IPC correctness bug today. A real terminal session
implements the completion paths, and production pane input obtains `KeyName`
from protocol decoding or CLI token parsing, which admit only named keys or one
canonical printable-ASCII character. They are still an unsafe shape: a new
input kind or a new submission fact must be carried through parallel paths that
can disagree.

The outcome is one typed pane-input value and one completion-aware submission
path from the pure command through the terminal session. Every command names a
submission whose result returns to the model; there is no untracked input path.

## Decision

- Represent one pane input item as a closed value that preserves the semantic
  distinction between safe paste, raw text, key plus modifiers, and wheel step
  plus cell coordinates.
- Carry that value and a required submission identity through one core command
  and one runtime interpretation path.
- Give `TerminalSession` one completion-aware input requirement with no default
  implementation. Every conformer must observe and report the real result.
- Convert every production `KeyName` exactly: named keys map exhaustively and a
  character maps from its one validated scalar. Remove the unreachable optional
  and encoding-failure path without adding a substitute or fallback key.
- Keep the engine-facing controller seam as four operations. Each already has
  one completion-aware implementation, and the separation matches distinct
  engine operations rather than duplicated delivery policy.

## Invariants

- Top-level IPC text keeps safe-paste behavior. Structured input text stays raw
  so it can represent typed terminal input.
- Input items from one IPC request are emitted in wire order, receive distinct
  submission identities, and share the wait generation captured when the
  request dispatches.
- Each item completes with the terminal's delivered or typed rejection result.
  An absent pane rejects it as process-ended.
- A request replies once after its last item succeeds, regardless of completion
  order. A rejection replies immediately and retires the remaining items.
- Key conversion preserves the exact key accepted by protocol decoding or CLI
  token parsing; it never substitutes another key.
- Every `TerminalSession` conformer owns input completion; no protocol default
  can claim delivery on its behalf.
- The CLI and JSON wire formats do not change.

## Proof obligations

- In the AppKit UI suite, prove all four input meanings reach the pane controller
  with their payload, modifiers, coordinates, and captured wait generation
  unchanged, and prove safe paste remains observably different from raw text.
- Prove every input meaning preserves delivered and typed controller rejection
  results, and rejected input is not recorded as delivered.
- Prove a missing pane rejects its submission as process-ended.
- Prove multi-item commands are emitted in wire order; success replies once after
  the last completion in any order; rejection replies immediately and makes
  later completions silent; and pane teardown preserves that behavior.
- Preserve protocol coverage that wire decoding and CLI token parsing admit only
  named keys or one canonical printable-ASCII character.
- Prove unknown wire keys still fail before any terminal command is emitted.
- Run the targeted DanTermCore tests and lint during development, then the AppKit
  UI suite and `just test` before delivery.

## Non-goals and rejected ideas

- Do not merge paste and raw text. Their different safety semantics are part of
  the external input contract.
- Do not unify the engine-facing controller operations. That would move the
  switch without removing a duplicated policy.
- Do not retain the old four `TerminalSession` entry points as compatibility
  shims. DanTerm has no internal compatibility requirement for them.
- Do not preserve an untracked or fire-and-forget command shape for a possible
  future producer. Such a producer must join the submission path explicitly.
- Do not change wire decoding or add a session-level test for unknown IPC keys;
  decoding already rejects them at the correct boundary.

## Implementation discretion

- Exact internal type names, source-file placement, and helper decomposition are
  left to implementation.

## Integration

Work that changes the core command set or the runtime command interpreter should
not land concurrently with this refactor. Rebase after such work, then update
the audit entry only after the implementation commit identifier exists.
