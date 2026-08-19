# One flight tape: delete the five parallel capture buffers (PTY-3)

## Context

`TerminalPTYHost` runs two recorders over the same event vocabulary. The
always-on `flightTape` records `.feed`, `.write`, and `.resize`. Behind the
`captureTransitions` flag, five more buffers (`capturedOutput`,
`appliedTransitions`, `capturedSubmittedTransitions`, `capturedInputWrites`,
`capturedReplyWrites`) record overlapping slices of the same stream at nine
scattered branch sites, feeding characterization recordings and ~40 test
assertions. Two logs of one pane's transitions can disagree about order and
content, and a new transition kind must be threaded into whichever subset a
reader happens to consult. This is audit item PTY-3
(docs/scratch/2026-08-18-construction-audit.md); XPORT-1 (turn-scoped feeds)
made it fixable, and PTY-4 has landed (it touches different functions; no real
conflict). INTERACT-2 has landed too, with its recorded-insideness decision
taken: `TerminalPointerEvent` carries a `TerminalViewportCell` and
`NeutralTerminalMouseEvent` records `isInsideGrid`. That is the prerequisite
for a lossless one log -- without it the record would drop a bit the pointer
policy consumes, and an off-grid Cmd-press would replay on `PaneReplica` as
inside-grid, arming a link the Mac pane never armed.

Desired outcome: one recorder. The flight tape records every applied
transition; the five buffers, both `TerminalPTYAppliedTransition` /
`TerminalPTYSubmittedTransition` enums, the `captureTransitions` boolean, and
the controller's `neutralEvents(_:)` translation all delete. PTY-6 falls out:
with the wide enum gone, `applyViewportNavigation` takes the three-case
`NeutralTerminalViewportNavigation` that already exists and its
`preconditionFailure` arm becomes unrepresentable.

Load-bearing premises (verified this session):

- The tape already stores `NeutralTerminalRecordingEvent`, whose vocabulary
  contains every kind the buffers capture; `neutralEvents(_:)` is a pure 1:1
  translation.
- `captureTransitions` is production-off: only the
  `DANTERM_TERMINAL_CHARACTERIZATION` build with a recording directory sets it.
- Recording interaction kinds on production tapes would change live behavior:
  `PaneReplica.applyEvent` applies `.mouse` and `.viewport` (a following phone
  would mirror Mac selection and have its viewport yanked), mouse moves would
  evict feed history from the bounded ring, and each keystroke would double
  its IPC stream records.
- The tape's `.write` records at transmission, split at min(submission span,
  kernel write); replies and default user sends both carry nil origin, so the
  capture cannot distinguish them today.
- A result adopted from a flushed update signal in `consume()` bypasses the
  fence's exit gate, so the characterization recording is silently lost in
  that window -- a latent bug today, not introduced by this change.

## Decision

One `TerminalFlightRecorder` per pane remains the only transition log. Its
configuration gains, beside the existing retention bounds, a switch for
whether interaction-intent kinds (`.input`, `.paste`, `.focus`, `.mouse`,
`.viewport`) are recorded, plus an unbounded "complete" preset. The gate
executes inside the recorder's `record()`, not at host call sites -- host
sites record unconditionally, so a future capture site cannot forget the
gate. Production panes keep today's boundary vocabulary and bounds; the
characterization build and tests select the complete configuration where they
set `captureTransitions: true` today. At the one public app seam
(`TerminalPaneSessionController`'s characterization init,
`app/SwiftTerminalBackend.swift`), a single public boolean maps to the
complete configuration, since the configuration type is `package`.

Capture-side write attribution: the host already knows who chose each write's
bytes (user input, the pane's own reports such as focus, or a terminal
reply). That fact rides `TerminalFlightRecordingEvent` as capture metadata
beside `origin` and the payload span. It does not enter
`NeutralTerminalRecordingEvent` and is not lowered into the pane-tape IPC
stream.

Characterization recordings and diagnostic captures are lowered from tape
captures. `capturedRecording(test:)` becomes a pull: it returns nil unless the
pane observed a child exit, and otherwise takes the tape capture at that
moment through the existing non-production `flightRecordingCapture()` fence.
No transitions and no capture ride the `.consumptionState` payload, and
`consume()` stores no recording. The `.diagnosticState` fence stays one fence
and keeps draining damage.

Taking the capture at read time is also what fixes the flushed-signal
recording loss, and it removes the mechanism the race lives in instead of
fencing around it: the recording no longer depends on which fence observed the
exit, so a result adopted from a flushed signal yields the same recording as
one the fence returned. The tape is never drained, so a capture taken later is
complete, and it is taken once per read rather than once per fence -- a long
session never re-copies its history on the delivery path.

The existing `TerminalPointerEvent -> NeutralTerminalMouseEvent` mapping moves
from the pane session to where the host can reach it (TerminalCoreRecording
owns both vocabularies), unchanged in behavior: it carries the cell the view
measured, `isInsideGrid` included, so insideness still travels with the
coordinates rather than being reconstructed at replay. Every recorded mouse
event must stay replica-decodable: `.down`/`.up` always carry a one-based
button, `.move` never does -- an undecodable event ends every following
replica's connection.

`scripts/terminal-viability.sh` widens its event-kind allow-list: recordings
now legitimately contain `.write` events, which replay ignores.

## Invariants

- I1. One log: the pane has exactly one record of its applied transitions,
  and a transition kind is recorded at one site or none.
- I2. Under the complete configuration, a key press, paste, focus change,
  pointer event, effective viewport move, and resize appear on the capture in
  the order the owner applied them, each with nil payload span and nil origin.
- I3. Under the production configuration, the tape's observable content --
  vocabulary, byte watermarks, cursor arithmetic, retention behavior, live
  pane-tape streams, replica behavior -- is unchanged.
- I4. Interaction events never advance the feed/write byte watermarks and
  never carry a payload span; a bounded configuration charges a `.paste`'s
  UTF-8 byte count against the budget, and an evicted `.paste` reports zero
  dropped feed/write bytes.
- I5. Every `.write` on a capture states its attribution: user, pane, or
  reply. Core replies stay distinguishable from user input.
- I6. A session yields a characterization recording iff its pane observed a
  child exit and it was built with the recording configuration -- including
  when the result arrives via a flushed update signal; live sessions,
  torn-down live children, launch failures, and production-configured
  sessions yield nil.
- I7. Replaying a complete-configuration recording reproduces the live
  terminal's snapshot (interaction events included); replaying a
  production-vocabulary recording keeps today's equality.
- I8. The controller's fence census is unchanged: the payload changes add no
  production fence, and the diagnostic capture remains one fence that drains
  host damage into the pending plan.
- I9. Recorded mouse events are always replica-decodable shapes, and a
  recorded pointer event replays with the insideness the Mac pane decided --
  an off-grid press stays off-grid on the replica.

## Proof obligations

Existing tests pin the no-regression half; they must pass unchanged or with
mechanical restatement only:

- I3: replay-equality on production tapes (H:1757, H:2414), exact-loss under
  bounded retention (H:1421/1463/1488), query-before-reply order (H:1807),
  origin stamps across backpressure splits (H:2466), writes never satisfy
  output waits (H:1523).
- I8: `everyControllerFenceIsAccounted` (C:47),
  `diagnosticCaptureFoldsDamageIntoTheNextPlan` (C:1673),
  `consumptionFencePairsFrameAndExitMetadata` (H:1849).
- I6 (nil half): the four nil-gating controller tests, with
  `captureDisabledExposesNoRecording` re-pointed at the production
  configuration.

New behavioral tests:

- I2: complete-configuration application-order test.
- I3: the same stimulus under production configuration records none of the
  interaction kinds.
- I4: recorder unit tests for paste accounting and eviction reporting.
- I5: attribution triple -- user key => user, focus report => pane, CPR
  reply => reply (restates H:2152, H:566, C:881).
- I6: the flushed-signal race -- a result adopted from a flushed signal still
  yields a recording (needs a package seam to stage a pending signal).
- I7 and I9: `controllerNavigationCaptureEquality` (C:2143) restated onto the
  tape source -- replay equality of `capturedRecording` with interaction
  events present, keeping its assertion that the off-grid pointer records
  `isInsideGrid == false`. That is the test that proves the new capture source
  preserves the bit; INTERACT-2 already proved the replica-side effect, and
  `NeutralTerminalRecordingTests.offGridMouseRoundTrip` stays green unchanged
  for codec and replay.

The ~40 accessor-based assertions restate against tape captures: negative
"no write" assertions take a cursor baseline (every childless host has one
launch-line write before the test body), reply/input distinctions filter by
attribution, and grouping-sensitive shapes assert tape `.write` spans.

## Non-goals

- Exposing attribution or interaction kinds over the pane-tape IPC stream or
  wire format; `paneTapeStreamVersion` and `PaneTapeRecord` do not change.
- Replica mirroring of selection/scroll (a product decision for a future
  item; production tapes carry no such events after this change).
- Fixing `scripts/terminal-tape-to-fixture.py` staleness (already rejects
  every current tape: stream version and `pinned`; also lacks mouse
  `offsetX`) -- pre-existing and not on this path; raise separately.

## Accepted risks

- AR1. Grouping-sensitive write-shape tests move from "recorded at emission"
  to "the kernel did not split the write": acceptable because those tests
  write tiny payloads into a drained tty and cannot approach the split
  threshold; genuinely split writes are already covered tape-side (H:2466).
- AR2. Characterization recordings gain inert `.write` events and grow;
  replay ignores them and corpus tests already tolerate them. The viability
  script's allow-list widens accordingly.

## Rejected ideas

- RI1. Uniform vocabulary on every production tape (the audit's literal
  ideal): rejected because it changes live replica behavior, evicts feed
  history under mouse traffic, and doubles keystroke stream records -- a
  production cost for a test-support need. Configuration already owns "what
  is worth a slot" (retention); vocabulary joins it.
- RI2. The audit's cheaper fallback (one ordered event log behind the flag,
  second recorder kept): rejected because the configuration-gated recorder
  achieves one recorder at similar cost.
- RI3. Deriving reply-vs-user from origin or event adjacency: rejected --
  replies and default user sends both carry nil origin, so only carried
  attribution states the fact.

## Implementation discretion

- Exact configuration and attribution type shapes, preset names, and how the
  budget charge is decoupled from the direction watermarks inside the
  recorder.
- Mechanics of test restatement (cursor-baseline helpers, span grouping).

## Critical files

- lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift
- lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift
- lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift
- lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift
  (mouse adapter home; vocabulary untouched)
- app/SwiftTerminalBackend.swift
- lib/TerminalPTY/TestSupport/TerminalWorkflowRunner/main.swift,
  lib/TerminalPTY/TestSupport/TerminalProtocolProbeRunner/main.swift
- lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift (H),
  lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift (C)
- scripts/terminal-viability.sh

## Verification

- `swift test --package-path lib/TerminalPTY` for the host, recorder, and
  controller suites; `just test` as the full gate.
- One manual `scripts/terminal-viability.sh` run once recordings source from
  the tape.
- Grep proves the deletion: `captureTransitions`,
  `TerminalPTYAppliedTransition`, `TerminalPTYSubmittedTransition`,
  `capturedOutput|capturedInputWrites|capturedReplyWrites|capturedSubmittedTransitions|appliedTransitions`
  have zero hits outside git history.

## Commit progress
- [x] 1. Gate interaction-intent kinds on the flight recorder's configuration
- [x] 2. Carry write attribution from the submitting path onto the tape
- [ ] 3. Source characterization recordings from the tape and delete the five capture buffers

## Implementation notes

- Commit 2 gave writes their own recorder entry point (`recordWrite(_:origin:
  attribution:)`) instead of adding a defaulted parameter to `record`. Only a
  write has bytes travelling toward the child, so only a write has an origin
  stamp or a chooser; splitting the two makes I5 true by construction rather
  than by call-site discipline, and `TerminalFlightRecordingEvent.init` refuses
  the two mismatched pairings outright. `record` and `recordWrite` share one
  private `append`, so the interaction-intent gate, the byte watermarks, and the
  retention charge each stay in one place.
- The reducer releases the pane's launch line as a write with no submission of
  its own. That line is attributed `.pane`: nobody typed it, and it is the same
  kind of fact as a focus report. So an absent submission means the pane, not an
  unknown chooser.
