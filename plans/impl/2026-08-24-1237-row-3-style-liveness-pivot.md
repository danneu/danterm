# Pivot ROW-3 to correctness and deterministic work evidence

## Problem and desired outcome

Style-table reclamation derives retained style liveness by walking packed cells
and trailing fills. It omits the pending wrap margin even though retained-row
readers can project that margin as a styled cell. A sweep can therefore reclaim
the margin's only style and repaint it as the default.

ROW-3 also identifies a possible performance cliff: reclamation scans all
retained cells synchronously during `feed`. The adaptive sweep threshold
amortizes that scan against the surviving style population, but the production-
depth work has only been derived from the code rather than counted through the
engine.

The desired outcome is correct style liveness plus an exact, machine-independent
count of the retained-cell work at production scrollback depth. The work must
not add exact retained-style counts or change sweep policy without calibrated
evidence.

## Decision

- Retained-style enumeration covers every style-bearing store state: packed
  cells, trailing fills, and the pending wrap margin.
- The current adaptive sweep policy and exact scans of the live and offscreen
  screens remain unchanged.
- The engine's task-local cost instruments count arena cell words visited while
  deriving style liveness. Trailing fills and the pending margin are metadata
  reads, not cell visits. Recording occurs once per retained walk with its
  total, never inside the per-cell loop.
- A gate-resident deterministic test uses a small scrollback budget to prove
  that one reclamation walk reports exactly the stored-cell population exposed
  by the memory census.
- An env-gated probe outside `just test` fills production-depth history, mints a
  known number of distinct styles, and reports the arena cell-word visits caused
  by reclamation. The probe supplies an exact, machine-independent descriptive
  number, not a benchmark verdict.
- The measured visit count per newly minted style and the measured tree identity
  are recorded in the ROW-3 entry of
  `docs/scratch/2026-08-18-construction-audit.md`.
- ROW-3 closes as a pivot after the correctness fix and deterministic evidence
  land. Any later optimization starts as separately measured work.

## Invariants

- A style ID retained by any stored or projected history state remains
  resolvable until that state is removed or resolved.
- Reclamation does not change the paint of live, offscreen, or retained cells.
- Counting work does not add per-cell instrumentation overhead.
- Product-facing APIs and terminal compatibility do not change.

## Proof obligations

- **PO1 -- pending-margin liveness.** A uniquely painted pending wide-wrap
  margin remains the style's sole holder after all live and offscreen copies
  leave both screens, while its retained record remains unevicted. It keeps its
  original paint after enough distinct styles are interned to trigger
  reclamation.
- **PO2 -- existing reclamation behavior.** Style churn remains bounded, dead
  styles become reclaimable after eviction, ID recycling preserves live paint,
  the offscreen screen survives a sweep, and reclamation still materializes no
  retained rows.
- **PO3 -- instrument fidelity.** At a small scrollback budget, one reclamation
  walk reports exactly the census's independently counted
  `retainedStoredCellCount`, with no per-cell recording operation. Trailing-fill
  and pending-margin metadata do not contribute visits.
- **PO4 -- production-depth reading.** The env-gated probe fills the production
  scrollback budget and reports exact arena cell-word visits per newly minted
  style under deterministic distinct-style churn.
- **PO5 -- repository gate.** The targeted `TerminalCore` suites and `just lint`
  pass during development, and `just test` passes before commit.

## Non-goals, accepted risks, and rejected ideas

- **Non-goal:** This work does not add exact retained-style counts, tune sweep
  thresholds, add or recalibrate a benchmark workload, or implement ROW-2.
- **Accepted risk:** Reclamation can still scale with retained depth. The
  adaptive threshold remains because a work count establishes cost shape but
  does not establish elapsed-time impact or justify new mirrored state.
- **Rejected idea:** Do not treat the work count as a directional performance
  verdict. A future optimization needs a paired, screened comparison against a
  named baseline.
- **Rejected idea:** Do not add a profiling corpus or sampling harness for this
  claim. A deterministic counter supplies the durable evidence this plan needs
  without changing a frozen workload or producing a disposable time share.

## Implementation discretion

- The deterministic byte stimulus and test-helper organization are
  implementation choices, provided the proof obligations remain exact and
  structure-insensitive.

## Commit progress

- [x] 1. fix(terminal): retain pending wrap-margin styles through reclamation
- [x] 2. perf(terminal): count retained style-liveness scan work
- [x] 3. docs(audit): close ROW-3 as a measured correctness pivot
