# Drop the cross-layer metadata budget; keep independent per-layer caps

## Context

The "exactly 1 MiB end-to-end" terminal-metadata arithmetic (256 KiB engine +
256 KiB held handoff + 512 KiB model) exists mainly to be provable, and proving
it forced `TerminalCore`'s test target to depend on the `DanTermCore` package --
the only cross-package coupling in the repo (the integration test in
`lib/TerminalCore/Tests/TerminalCoreTests/` is the sole reference to
DanTermCore anywhere in TerminalCore). The model-side 512 KiB share also
requires per-pane byte accounting and an alert-eviction loop in the pure core.

Independent per-layer caps already bound every layer without the sum: the
engine keeps its own 256 KiB retention, and the model rejects any
terminal-originated value over 64 KiB at every ingestion path and caps alerts
at 100 globally. Removing the cross-layer proof deletes ~150 lines and the
architectural seam.

## Decision

Remove the model-side aggregate byte budget and the cross-layer integration
proof. Independent ownership and limits become the architectural boundary:
each layer states and tests its own cap; no test spans the
TerminalCore/DanTermCore package boundary.

Surviving contract, stated precisely: the engine bounds its own retention at
256 KiB (unchanged); the model retains at most 100 alerts of up to 128 KiB
each (~12.5 MiB globally), plus independently capped terminal-originated
fields (64 KiB per value) for every live pane -- so total model metadata
remains proportional to pane count, with no aggregate per-pane or app-wide
byte bound.

## Changes

1. Remove the `TerminalCore` -> `DanTermCore` package dependency: delete the
   cross-layer integration test and the manifest entries that exist only for
   it (`lib/TerminalCore/Package.swift`).
2. Remove the model-side aggregate accounting and alert-eviction mechanism
   from `DanTermCore` (`TerminalMetadataBounds.swift` and its `Update.swift`
   call sites), preserving the per-value 64 KiB rejection guards and the
   100-alert cap.
3. Update the documented contract -- `docs/terminal-capabilities.md` and
   `plan-terminal-engine/10-protocols-shell-integration.md` -- replacing the
   1 MiB share arithmetic with the per-layer statement above.

## Invariants

- I1: Engine-side retention stays capped at 256 KiB (unchanged).
- I2: Every model ingestion path rejects terminal-originated values whose
  UTF-8 exceeds 64 KiB, with no partial effect.
- I3: `model.alerts.count <= 100`.
- I4: An oversized value cannot prevent a later valid value from applying.

## Proof obligations

- I1: existing engine coverage in `TerminalSemanticEventTests` and
  `TerminalHyperlinkInteractionTests` (including
  `hoverSharesMetadataBudget`); no new tests.
- I2 + I4: extend the existing `terminalMetadataValueLimit` test
  (`UpdateGhosttyTests.swift`) to cover any missing field paths and to show a
  valid value applies after an oversized one. Delete the eviction test
  (`paneMetadataBudgetEvictsOldestSamePaneAlerts`) outright -- its mechanism
  is gone.
- I3: existing `UpdateAlertTests.testAlertHistoryCappedAt100`; no new test.

## Verification

- `swift test --package-path lib/TerminalCore` passes with no DanTermCore
  product resolved; `grep -rn "DanTermCore" lib/TerminalCore/` returns
  nothing.
- `swift test --package-path lib/DanTermCore` passes with no references to
  the deleted symbols.
- `just test` for the full local gate.

## Non-goals / Accepted risks

- No change to engine-side budgets, handoff/queue bounds, or the 64 KiB
  per-value limit.
- No replacement aggregate byte bound (rejected: a smaller per-value cap
  would squeeze legitimate notification bodies to buy a bound nothing needs).
- Accepted risk: model metadata scales with pane count (no app-wide byte
  bound); per-value and alert-count caps keep any realistic total small.
