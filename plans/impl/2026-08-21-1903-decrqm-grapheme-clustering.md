# DECRQM Grapheme-Clustering Capability

## Problem

DanTerm always segments terminal text into extended grapheme clusters, as required by
`docs/design/2026-08-06-swift-terminal-engine.md D1`. However, `CSI ? 2027 $ p`
reports status 0, which tells applications that DanTerm does not recognize grapheme-cluster
mode. Applications can then choose width rules that disagree with the grid DanTerm renders.

## Decision

Report DEC private mode 2027 as permanently set with status 3. Keep grapheme clustering as
an unconditional engine capability. Setting or resetting mode 2027 must not create mutable
mode state or change text segmentation.

This is a fixed capability, separate from the registry of mutable terminal modes. A query
about it reports the engine contract; it does not expose a configuration switch.

Amend `docs/design/2026-08-06-swift-terminal-engine.md D1` to state that mode 2027 is
reported permanently set because clustering is unconditional, and that the behavior and
advertised status must change together.

## Invariants

- `CSI ? 2027 $ p` replies with `CSI ? 2027 ; 3 $ y`.
- DECSET and DECRST 2027 cannot change the reported status.
- DECSET and DECRST 2027 cannot disable or interrupt extended grapheme clustering.
- Unknown modes continue to report status 0.
- Mutable mode set, reset, query, reset-to-default, and state-synchronization behavior stays
  unchanged.

## Proof Obligations

- A query proves that mode 2027 reports the exact permanent-set reply.
- Queries before and after DECSET and DECRST 2027 prove that the status remains permanent.
- A grapheme assembled across a mode-2027 set or reset sequence proves that the sequence
  cannot change or interrupt clustering.
- Existing mode-query tests prove that unknown and mutable modes retain their current replies.
- The full test gate proves that the fixed capability does not change other terminal behavior.

## Rejected Ideas

- A mutable mode-2027 flag is rejected because it would make the engine's grapheme unit
  optional and contradict the accepted Unicode contract.
- A general registry for fixed mode statuses is rejected until more than one fixed capability
  needs it; it would add structure without strengthening this contract.

## Implementation Discretion

- The placement and shape of the fixed-capability lookup are implementation details, provided
  it remains separate from mutable terminal state.
