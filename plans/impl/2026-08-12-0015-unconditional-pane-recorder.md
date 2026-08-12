# A pane recorder that runs in production

## Problem

A production pane stopped responding after a typed Ctrl-C and there was no way
to say why. Three probes reproduced the scenario -- a bare `read` prompt, the
interrupted script's exact teardown, and the whole real command end to end --
and each returned to a prompt in 0.33s. The one hypothesis left standing was
that the keystroke was delayed inside the app before it reached the child, and
that hypothesis was unfalsifiable: the pane had kept no record of itself.

Two independent causes, both of which this plan removes.

**The recorder does not run in production.** It is gated on a bundle capability
that only the dev build sets, and a notarized bundle's `Info.plist` cannot be
edited, so a shipped pane can never capture. The gate also misreports itself:
asking a production pane for a tape returns an error blaming the terminal
backend, which sent the first investigation down a wrong path.

**The recorder captures one direction.** It records bytes read from the child
and pane resizes; nothing travelling toward the child enters it. Output-only
evidence cannot separate "the app was slow to deliver the keystroke" from "the
child was slow to answer it", which is the distinction the incident needed.

## Desired outcome

Every pane in the shipped app continuously retains the recent byte traffic
across its own PTY boundary, in both directions, with enough timing to
attribute a delay to the app or to the child. `danterm pane tape` answers for
any live pane without reproducing the symptom first.

## Load-bearing premises

- Recording is bundle-static: the capability is read once at backend
  construction and frozen into the PTY host's initializer. There is no runtime
  seam that creates or destroys a recorder after a pane exists.
- Applying a keystroke is not delivering it. The owner encodes a key and
  appends the bytes to a pending-input buffer; a partial write or `EAGAIN`
  leaves them there for a later write-source turn. Time spent in that buffer is
  the app's, and a tape stamped at encode time would charge it to the child.
- Keys are not the only thing travelling toward the child. Terminal-generated
  replies and programmatic input enter the same buffer, and an action that
  encodes to no bytes -- a focus change with focus reporting off -- delivers
  nothing at all.
- An AppKit event carries its own occurrence time, taken when the system
  created it, on the same monotonic base the recorder already uses. A stall
  before the app's handler runs is visible in that number and in nothing the
  handler could sample itself.
- The benchmark bundle copies the shipping `Info.plist` unmodified and never
  enables the capability. Every frozen threshold in the terminal harness was
  therefore measured with no recorder running, so this change adds a boundary
  cost the harness has never priced -- and can price, because the baseline arm
  genuinely differs from the candidate.
- The retained snapshot must fit one IPC line, which is what couples the
  per-pane budget to the transport. An existing test pins both the bulk and the
  many-tiny-events shapes against that ceiling.
- Retention charges payload bytes only for output events; every other event
  costs a fixed per-event overhead. A new event that carries a payload and is
  not charged for it would silently break the budget.
- Replay ignores every event that is not child output or geometry, and the
  fixture converter already refuses any capture that reports dropped events.

## Decision

**The recorder is unconditional.** Delete the build-time capability rather than
flip it on -- the bundle key, the capability reader, and the flag threaded down
into the PTY host all go. A flag that is always true is a structure in which
"production kept no evidence" remains reachable; removing it is the structure
in which it cannot happen. Deleting it also makes the benchmark bundle record,
so the harness measures what production runs.

**The tape is a boundary ledger, not an intent log.** Every event is a byte
transfer that actually happened at the PTY: output when a read succeeds, input
when a write succeeds, geometry when the resize ioctl succeeds. Bytes are
recorded as transmitted, after encoding and sanitization, which also brings
terminal replies and programmatic input into the record for free. An action
that produces no bytes leaves no trace, because nothing crossed.

**Input carries where it came from.** Bytes travelling toward the child are
stamped with the time their originating event occurred -- for a keystroke, the
system's own event time, not the moment the app's handler got around to it --
and that stamp travels with the bytes until they cross. The event also records
when the write succeeded. The distance between the two is time the app owned,
and it is what makes an internal stall legible after the fact. Bytes with no
app origin, including terminal replies, carry no origin stamp: absence means
"originated at the owner", never zero.

**Retention keeps its shape and its size.** Bounds stay on retained payload and
event count, not age: a pane that hangs and then goes quiet is noticed minutes
later, and an age window would expire precisely the evidence worth keeping. The
per-pane budget is unchanged, so the transport ceiling it was chosen against
still holds.

This reverses a standing decision that recording stays a dev-build capability,
and it lets terminal output reach another application from a shipped build.
Both are decisions the engine's design register must carry, so the register is
amended in the same change rather than left contradicted.

## Invariants

- **I1** Every pane the shipped app creates has a tape. No build flag, bundle
  key, environment variable, or preference can produce a pane without one.
- **I2** The tape holds one sequence of completed byte transfers in both
  directions, ordered by when each transfer completed. No event is recorded for
  bytes that were buffered but not yet written, and none for an action that
  produced no bytes.
- **I3** An event whose bytes originated outside the pane owner carries the
  time that origin occurred as well as the time the transfer completed, on one
  monotonic clock comparable within a pane. An event with no earlier origin
  carries no origin stamp. Origin stamps need not be monotonic along the
  sequence, and a reader must not assume they are.
- **I4** Retention is bounded per pane by retained payload and event count, and
  every event that carries a payload is charged for it. Events are never
  evicted for age, so an idle pane keeps its last events for as long as it
  lives.
- **I5** Eviction is oldest-first and reports exact event and byte loss, so a
  reader can tell a gap from delivered history.
- **I6** Asking a live terminal pane for a tape always succeeds. The only
  failure is a session that has no terminal at all, and the error says so.
- **I7** The tape exists only in memory and dies with its pane. Nothing in the
  app writes captured terminal traffic to disk.
- **I8** An untruncated tape replays to the state it was captured from. A
  truncated one is a diagnostic suffix carrying explicit loss, and makes no
  replay claim.
- **I9** A tape converted into a committed fixture carries no local identifier
  from any event, in either direction.

## Proof obligations

- **PO1** (I1) A pane created through the shipping path has a tape, with no
  input available to suppress it. The existing coverage asserting that a
  recorder-less host retains nothing describes a configuration that no longer
  exists and is replaced, not adapted.
- **PO2** (I2, I3) For every path that can put bytes into a pane, the origin
  time survives to the recorded event, the recorded completion time is the time
  the write succeeded rather than the time the bytes were queued, and the
  recorded bytes are the bytes transmitted. This must hold when the owner is
  stalled between origin and application, and when the write is backpressured
  so the bytes cross in a later turn. The keystroke path is proved from the
  layer that reads the system event, with an occurrence time earlier than the
  handler's own: a proof that only injects an origin below that layer would
  stay green against the exact regression this plan exists to prevent, which is
  an app that samples the clock after the stall instead of forwarding the
  event's own time.
- **PO3** (I4, I5) Retention under sustained bidirectional traffic keeps the
  newest suffix within both bounds, charges payload-bearing events in both
  directions, evicts nothing for age, and reports loss exactly.
- **PO4** (I4) Both production retention shapes -- one bulk capture and a full
  ring of minimal events, now including input-direction ones -- still encode
  into a single IPC line.
- **PO5** (I6) The tape surface's only error is the no-terminal session; a live
  pane never produces the backend error the incident hit.
- **PO6** (I8) An untruncated tape captured from a live pane, containing
  input-direction events, replays to the state it was captured from.
- **PO7** (I9) Fixture conversion refuses a tape whose input-direction payloads
  still contain a local identifier, the same way it already refuses one whose
  output does.
- **PO8** Recording on every pane does not regress sustained-output throughput
  past its frozen threshold, measured as a paired comparison against the
  pre-change revision. The comparison is only admissible if each arm proves its
  own recorder state first -- candidate recording, baseline not -- because an
  arm that silently lost its recorder would report the reassuring answer. It
  licenses "no regression above that threshold" and nothing stronger; the
  workload's own A/A history means a difference below roughly three and a half
  points is not evidence either way.

### Verification

- Coverage for PO1-PO7 lives at the layer that owns each claim: the recorder's
  own tests for retention and stamps, the PTY host for the write-boundary and
  backpressure behavior and the live replay round trip, the support layer for
  the follow stream, and the converter's Python tests for scrubbing.
- End to end: `just launch-slot`, then `danterm pane tape --pane <id> --follow`
  in a second pane while typing in the first. Input-direction events appear
  with both stamps; output events appear with one.
- The regression the plan exists to catch is a gated test, not the manual run
  above: the origin a keystroke's tape event reports is the system event's own
  time, so a handler that sampled the clock instead goes red. It belongs in the
  app test target the suite already runs, not the windowed UI harness the gate
  excludes.
- PO8 is `just benchmark-confirm` on the sustained-output workload against the
  revision before this change, with the decision-bearing numbers recorded in
  the commit rather than left in the disposable artifact directory.
- `just test` gates the rest; new script-level checks belong in the suite's own
  step list, independent of every other step.

### Owning layers

The capability is deleted from the app bundle and its build script, the
protocol module's capability reader, the AppKit backend, and the flag's path
through the PTY package. The recorder, its retention accounting, and the new
record sites at the PTY read, write, and resize boundaries are all inside the
PTY host package. The origin stamp starts in the AppKit session view and at the
IPC input entry. The tape's error text is owned by the support layer and the
runtime's follow-start path. Format-side consumers are the neutral recording
event schema in the terminal core package, the fixture converter, and the
recording schema audit.

## Deliverables beyond code

- The neutral recording vocabulary gains one event for bytes travelling toward
  the child; replay ignores it as it already ignores non-output events.
- The engine design register is amended in the same change: recording in
  production, and terminal output reaching another application from a shipped
  build, are decisions it must carry.
- The CLI skill document currently tells the reader that production panes have
  no tape and return an unsupported-backend error. It is corrected in the same
  change, along with the privacy note, which must now say that a tape can
  contain what was typed.

## Non-goals

- The tape is not a metrics facility. It answers what crossed the pane boundary
  and when; rates, counters, and aggregates belong to their own instruments, as
  the existing per-pane samplers already establish.
- No durability. A force-quit or crash loses the tape, and nothing spills it to
  disk. An operator who needs evidence to survive a crash still redirects the
  follow stream.
- No redaction of captured input.
- The characterization capture path and its unbounded transition buffer are
  left alone. Subsuming them into the recorder is a plausible follow-on, not
  this change.

## Accepted risks

- **AR1** Recording input places no-echo input -- a password typed at a `sudo`
  or `ssh` prompt -- into the in-memory tape, where today it lands nowhere. Any
  local process reaching the control socket can dump it. Accepted: the machine
  has one user, and that socket already serves rendered scrollback. Taken over
  a redacting variant so the tape stays a faithful byte record and the recorder
  stays free of terminal echo state.
- **AR2** Steady-state memory grows by up to the per-pane budget for every pane
  that has produced traffic, and the app now pays it on every pane rather than
  none.
- **AR3** The throughput comparison cannot resolve a small regression on this
  workload. A real cost below its noise floor would ship unnoticed.
- **AR4** A tape shows what crossed the boundary, so an intent that produced no
  bytes is invisible. A keystroke swallowed before encoding leaves no evidence
  that it happened. Accepted: the alternative is a second, intent-shaped event
  stream whose timestamps do not describe delivery, which is the ambiguity this
  design exists to remove.

## Rejected ideas

- **RI1** A runtime preference, or an environment escape hatch, that arms
  recording after a sighting. It can only ever catch a recurrence, and the
  motivating incident was a first sighting that never recurred.
- **RI2** An age-based retention window. It expires the evidence for the one
  symptom class -- a pane that stops responding and therefore stops producing
  events -- that most needs it.
- **RI3** Stamping child output with an origin as well. The read and the record
  happen in the same turn, so the second number would restate the first, and a
  metric that cannot distinguish itself from its neighbour is worse than an
  absent one.

## Implementation discretion

- Where the two stamps sit in each of the two document shapes, given that the
  event schema admits exactly one inert metadata key today and this adds a
  second.
- How an origin stamp stays associated with its bytes while they sit in the
  pending-input buffer.

## Commit progress

- [x] 1. delete the flight-tape build capability so every pane records
- [ ] 2. add an input-direction byte event to the neutral recording vocabulary
- [ ] 3. record input bytes at the PTY write boundary with origin stamps
- [ ] 4. stamp pane input with its originating system event time

## Implementation notes

- **Commit 1.** The recorder's optionality was removed from the type, not just
  from the construction site: `flightTape` is a `let`, and the host, the pane
  session controller, and the AppKit adapter all return non-optional snapshots
  and origins. The one optional left on the follow path means "this subscription
  is no longer registered", which is a different fact from "no recorder".
- **Commit 1.** The register's J12 row states only what this commit makes true --
  output and geometry -- because input-direction recording lands in commit 3.
  Commit 3 amends the row rather than adding a second one.
- **Commit 1.** PO1 is proved at the PTY host initializer rather than at
  `TerminalPaneSessionController`, because the controller's shipping path would
  need a real spawned child to observe a tape, and the host initializer is the
  narrowest layer that owns the claim. The stronger half of the proof is that the
  suppressing parameter no longer exists in any signature on that path.
