# State the pane-tape start record's geometry contract where readers look

## Problem

Audit finding MOBILE-6 (and IOS-1's "Sharper ideal (a)") read `PaneTapeStartRecord.pinned`
as the pane's pinnedness at the cursor the start record publishes, and proposed that
`PaneReplica.applyStart` adopt it. That reading is wrong and the fix would be a regression:
on a `--from-cursor` resume the producer puts the recorder's **birth** geometry (sequence 0)
in the start record beside the client's own cursor, and ships every later geometry change as
replayed events or a sync. A replica that adopted the start bit would overwrite a correct
checkpoint bit with the birth bit -- a phone that claimed a pane, checkpointed, and resumed
would offer Claim on a pane it still holds until the next resize event, which may never come.

The replica's current behavior (keep the checkpoint bit; let events and syncs move it) is
the documented decision, but the documentation is in a commit message (`b0aceba5`) and a
historical plan, not where a reader looks. Two auditors misread it independently, and the
one external statement of the contract points the wrong way.

## Evidence

- Producer: `lib/DanTermCore/Sources/DanTermCore/PaneTapeStreamState.swift` -- the
  `.beginning` and `.cursor` opening branches pass `fence.origin.initial` as the start
  geometry; `.now` passes live geometry; a sync opening mirrors the sync's geometry.
  `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift`
  `TerminalFlightRecordingStreamFence.origin` is "recorder birth geometry and its real
  lifetime cursor at sequence zero".
- Consumer: `ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift` `applyStart`
  keeps `heldPinned` on a matching resume; no comment says why. `PaneReplicaTests` has no
  test pinning it.
- External doc: `integrations/danterm/SKILL.md` ("Geometry is one fact on this stream")
  says the start record lets "a reader always know the pane's current pinnedness" -- true
  for `--from-now`, false for `--from-cursor` and `--from-beginning`-after-eviction where
  the grid is the recorder's birth grid.
- Record doc: `lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeRecord.swift`
  `PaneTapeStartRecord.pinned` reads as authoritative with no position qualifier.
- `MobileSessionModel.pinnedStatement(.start)` reads `start.pinned` to end a standing
  claim, but a standing claim is cleared on every new connection and a detected gap ends
  the connection, so no start record can meet a confirmed claim. Not a live defect.

## Decision

Docs fix, not a code change. State the contract at the four places a reader meets it, and
pin it with two behavioral tests. User chose this over the structural ideal (RI2).

Deliverables:

- `PaneReplica.applyStart`: a comment on the resume path saying a start record is not a
  pinnedness source and why (its grid is the recorder's birth grid; the replica's own bit
  is the one at its cursor; later transitions arrive as events or a sync).
- `PaneTapeStartRecord` geometry docs (`columns`, `rows`, `pinned`): say which grid the
  record states by position -- the recorder's birth grid on any stream that replays
  recorder events, the live grid for a from-now raw stream, the sync's grid when a sync
  opens the stream -- and that a reader resuming from its own cursor keeps its own grid.
- `PaneTapeStreamState.swift`: one comment at the resume branch naming the same rule, on
  the producer side where it is decided.
- `integrations/danterm/SKILL.md` geometry paragraph: replace "always knows the pane's
  current pinnedness" with the per-position statement above. SKILL.md is the CLI source
  of truth, so this is the sentence that stops the next misreading.
- `docs/scratch/2026-08-18-construction-audit.md`: mark MOBILE-6 resolved-by-docs with a
  one-line reason, and strike IOS-1's "Sharper ideal (a)" (it restates the same wrong
  premise and names `applyStart` adopting `start.pinned` as a precondition for IOS-1; it is
  not one).

## Invariants

- I1. A start record whose cursor matches an exact replica's cursor leaves the replica's
  pinnedness unchanged; only a sync payload, a geometry event, or a checkpoint moves it.
- I2. On an opening that replays recorder events (`--from-cursor`, beginning), the start
  record's `initial` geometry is the recorder's birth geometry, and every geometry change
  after the published cursor reaches the reader as a geometry event or a sync -- never only
  through the start record.

## Proof obligations

- PO1 (I1): `PaneReplicaTests` -- a replica restored from a checkpoint stating one
  pinnedness, given a start record at the same cursor stating the other, reports the
  checkpoint's bit; both directions.
- PO2 (I2): `PaneTapeStreamStateTests` -- a placed `--from-cursor` resume whose live
  geometry differs from birth geometry opens with the birth geometry in the start record
  and the transition in the replayed records. Asserted through the same public opening
  outputs the existing tests use.

## Non-goals / Accepted risks / Rejected ideas

- NG1. No change to `MobileSessionModel.pinnedStatement` -- IOS-1 owns it.
- NG2. No edit to `plans/impl/2026-08-18-0100-pinned-geometry-and-phone-claim-affordance.md`;
  plans are historical. Its "current geometry" wording is imprecise but stays.
- RI1. Replica adopts `start.pinned` on resume (the finding's fix) -- overwrites the
  correct bit at the replica's cursor with the birth bit; reintroduces the symptom.
- RI2. Make a resumed start record carry no geometry (optional `initial`), so a start whose
  grid is not the grid at its cursor becomes unrepresentable -- the structural ideal. Wire
  change to `PaneTapeStartRecord`, its decoder, and SKILL.md; no consumer loses anything
  it uses correctly. Declined by the user for this round because it is driven by reviewer
  confusion, not a live defect; recorded so it is a decision, not an omission.

## Verification

- `swift test --package-path ios/DanTermMobileKit --filter PaneReplicaTests`
- `swift test --package-path lib/DanTermCore --filter PaneTapeStreamStateTests`
- `just test` once at the end (docs lint, purity lint, full gate).
- PO1 and PO2 are characterization tests, not TDD: this plan changes documentation, not
  behavior, so both must pass against unchanged production code. Write them first. A first
  run that fails means the premise is wrong, not the test.

## Implementation discretion

- Wording and placement of each comment, and whether the SKILL.md paragraph gains a
  sentence or a short sub-list.
