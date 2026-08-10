# Milestone 7, Slice 5: Real-Pane Protocol and Capability Probes

## Problem

DanTerm's native fixtures prove deterministic terminal behavior, but they do not prove that an external program can drive stateful query/reply behavior through the production pane, PTY, and reply-routing path. The final Milestone 7 roadmap item needs that black-box evidence without making external suites authoritative or creating a second capability conformance system.

## Decision

Add a short, opt-in validation slice that runs a pinned, explicit subset of esctest2 through `TerminalPaneSession -> TerminalPTYHost -> PTY child`. Select only stateful behavior that is both advertised by capability manifest v1 and materially harder to prove with feed-only fixtures: cursor position reports and implemented mode queries. Each selected group carries a short rationale; the upstream revision pin prevents its contents from changing silently.

Before admitting wraptest, compare its pending-wrap transitions with existing native wrapping coverage. Run only a demonstrably uncovered case through the real pane, or record that wraptest adds no coverage and omit it.

When a selected external probe exposes a genuine DanTerm defect, first reduce it to the smallest deterministic native fixture at the lowest applicable layer, verify that fixture fails, then fix the defect. Unsupported, xterm-specific, and identity-report behavior is excluded rather than implemented for suite compliance.

Record one dated successful validation with the tool pins, selected cases and rationales, host environment, results, and any promoted native regressions. Successful runs need only this compact summary; failed runs retain the raw bytes and logs needed to reproduce and minimize the failure.

Completion checks and links the final Milestone 7 item in `plan-terminal-engine/14-roadmap.md`. Milestone 8 remains untouched.

## Invariants

- External probes are evidence, not authority. They cannot expand or reinterpret `terminal-capabilities-v1.json`.
- Every admitted probe exercises behavior DanTerm already claims; unadvertised behavior is excluded without a complete upstream inventory or exclusion ledger.
- Probe traffic, terminal-generated replies, and teardown use the production pane/session/PTY ownership path rather than a direct PTY-master shortcut.
- Live external execution remains opt-in and outside `just test`; promoted deterministic regressions join the normal native test gate.
- Probes have a bounded timeout, reliable result parsing independent of esctest2's process status, and complete child/process cleanup.

## Proof Obligations

- A checked-in explicit esctest2 allowlist at commit `664be3cf2c1e3f06bc93a8bafb48a0db83c607db` covers selected CPR and implemented DECRQM semantics and explains the distinct application-relevant behavior of each group.
- DSR, DA1, XTVERSION, and other fixed or identity replies are absent unless implementation work identifies a supported application whose behavior depends on them.
- A harness self-test proves that an intentionally failing probe makes the validation command fail; timeout and teardown tests prove bounded execution and cleanup.
- The selected probes pass through a real pane session. Any genuine failure is represented by a failing-then-passing deterministic native regression before the dated result is accepted.
- A coverage comparison records whether pinned wraptest commit `5409c25131a24c2cf150d42f3b4de5cb9c771d6b` contains an uncovered pending-wrap transition. If so, that gap passes through the same real-pane path; otherwise wraptest is omitted.
- `just test` passes with the harness self-tests and all promoted native regressions, and the opt-in real-pane validation command passes before Milestone 7 is closed.

## Non-goals and Accepted Risks

- No DanTerm-owned terminfo or capability census, Termless integration, or assertions over every manifest entry. The harness supplies only the advertised capabilities needed to launch selected probes correctly.
- No complete esctest2 inventory, durable exclusion ledger, exhaustive selection-count framework, or automatic accommodation of later upstream revisions.
- No automated or manual vttest program and no mandatory adjudication of the six pending Alacritty `vttest_*` recordings. A recording is adopted only if a live probe reveals missing native coverage.
- No complete wraptest report comparison when its behavior is already covered natively.
- No success-time recording, snapshot, reply-byte, inventory-copy, or cleanup-evidence archive beyond the compact dated result. Diagnostic detail is retained only for failures.
- No AppKit, pixel, Accessibility, tmux, editor, advanced-TUI, custom terminfo, or capability-expansion work in this slice.

## Commit progress

- [x] 1. Add the pinned real-pane protocol probe gate
- [x] 2. Publish probe evidence and close Milestone 7
