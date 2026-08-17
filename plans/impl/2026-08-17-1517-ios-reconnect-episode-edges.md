# iOS reconnect: keep the episode's contract at its three edges

## Problem and desired outcome

`plans/impl/2026-08-17-1346-ios-client-automatic-reconnect-policy.md` shipped a
pure, kit-owned policy that decides when the phone attempts a connection, and a
UIKit shell that supplies what a pure machine cannot observe and performs the
one decision it gets back. The decision is sound and stays. Three defects sit at
its edges -- two where the shell meets the policy, one inside the policy's own
representation of its budget.

- **The scheduled deadline is not the deadline the shell delivers.** The shell
  schedules the `wait(until:)` decision with `Timer.scheduledTimer`, which
  registers on the current run loop in the default mode only. While the user
  drags the pane table the main run loop runs in tracking mode, so the retry is
  parked until the drag ends. The same instrument also converts a monotonic
  deadline into an interval and hands it to a timer whose fire date is a
  wall-clock `Date`, so the timebase the policy chose on purpose is not
  preserved end to end. The consequence is that the policy's exact `until` is a
  floor and not the delay: the shell is meant to execute the decision, and the
  one part of the contract it cannot keep is the part the policy states most
  precisely. The shell's 30-second checkpoint flush is scheduled the same way
  and is parked by the same drag.
- **An invalid host field composes into a misleading header.** The shell
  deliberately does not dispatch when the host or port is unusable -- a typo
  must not cancel a retry already owed to a good target -- but it reports the
  problem by writing a connection state into the connection status channel, and
  the recovery phase is then appended to whatever is there. The header can read
  `Enter a host and port - retrying in 4s`: both halves true, the composition
  nonsense, because the causal half describes a form with no target and the
  recovery half describes a retry against a different, valid one. The channel is
  a single free string that two different kinds of message write to. The same
  path also re-reads the text fields on every pane-row tap, so a half-edited
  host field reports a form problem in answer to a gesture about an established
  episode's target.
- **The retry budget is represented by a quantity nothing bounds.** The policy
  increments an attempt counter on every attempt it authorizes, including the
  extra attempt a signal buys after give-up, and nothing ever caps it. It is
  safe only because the budget check runs before the delay lookup that would
  otherwise index out of range. That makes a scheduling rule load-bearing for
  memory safety inside a type whose whole value is that it is cheap to reason
  about: a reader has to prove an absence-of-crash argument to understand a
  counter.

Desired outcome: the moment the policy named is delivered on the policy's own
timebase -- never early, never moved by a wall-clock correction, and never
parked because the main run loop is in a tracking mode; the connection status
line can only ever compose a connection cause with a recovery phase, and a form
problem has no way in; and the episode's budget is a quantity that cannot be
exceeded because exceeding it is not expressible.

Load-bearing premises, from the tree:

- The kit is linted `portable`, not `pure` -- it already holds a socket-owning,
  thread-owning connection runner. An instrument that owns a real timer is
  admissible there, and everything there is tested headlessly in the Mac suite.
  Nothing in the shell is tested at all, so where a rule lives decides whether
  it has a proof.
- The policy reads time from `ProcessInfo.systemUptime` so a wall-clock
  correction cannot move a pending retry. That choice is only worth what the
  delivery instrument preserves.
- The failure vocabulary is total over real connection causes (step-0 plan I7),
  and each of its entries names a remedy against a target. A form with no target
  is not a member of that vocabulary.
- The policy's shipped behavior -- scheduling, give-up, signal arming, budget
  rearming -- is pinned by 24 headless tests covering the shipped plan's PO1-PO6.

## Decision

**Repair each edge in the layer that can prove it: the timing instrument moves
into the kit and carries a monotonic deadline; the status channel becomes typed
and its wording moves into the kit, with form validation given its own channel;
and the budget becomes the episode's remaining effort rather than a count of
effort spent.**

- **One timebase, delivered by one instrument.** The kit owns a deadline timer
  that reads the same monotonic clock the policy is given, takes the deadline
  rather than an interval, and delivers on the main queue independently of the
  run loop's current mode. The shell hands it the policy's `until` and does no
  arithmetic. Every piece of shell work scheduled for a later moment uses it, so
  no shell timer can be mode-gated. Rejected alternative: adding the existing
  timer to the common run-loop modes -- see RI1.
- **Two kinds of message, two channels.** The connection status channel takes a
  causal connection state and a recovery phase, not a free string, so a form
  problem is not representable there. The wording of both halves and their
  composition move into the kit as pure code, which is what finally puts the
  shipped plan's presentation invariant under test. Input problems get their own
  channel beside the fields, with their own vocabulary. Which gesture may
  consult the draft fields is decided in pure kit code, not by a shared shell
  route: the gesture that sets a target validates the draft, and the gesture
  that names a pane answers from the established episode's target alone.
- **The budget is what remains.** The policy holds the episode's remaining
  effort and consumes it as attempts are authorized. Exhaustion is that quantity
  being empty, so no range check stands between the representation and safety,
  and no quantity grows without bound. The schedule still states the episode's
  total effort in one place, as the shipped plan requires.

Behavioral scope: the phone's timing fidelity, its status presentation, and the
policy's internal budget representation. No change to the retry classes, the
failure vocabulary, the wire, the Mac, or the CLI;
`integrations/danterm/SKILL.md` is untouched.

## Invariants

- **I1 -- the deadline is delivered on the policy's own timebase.** A scheduled
  deadline is delivered on the same monotonic base the policy computed it on:
  never before that moment, never moved by a correction to the system's wall
  clock, and never withheld because the main run loop is running in a non-default
  common mode, as it does throughout a drag. Ordinary scheduler and main-actor
  latency after the
  deadline is not a violation: no instrument that delivers on the main actor can
  preempt work already running there, and the policy's delays are seconds.
- **I2 -- no shell work is scheduled by a mode-gated instrument.** Every piece
  of shell work due at a later moment -- the retry and the checkpoint flush
  alike -- is scheduled through the instrument of I1.
- **I3 -- the connection status channel carries only connection facts.** It is
  composed from a causal connection state and the current recovery phase.
  Nothing that is not a connection cause can be written to it, and this is
  enforced by the channel's type rather than by convention. Every fact the
  channel presents today is a connection fact and survives the change: the
  target being attempted, the Mac's version, and the replica's gap and repair
  notes ride on the causal side, as that vocabulary already does for facts it
  cannot enumerate. Only the form problem leaves.
- **I4 -- validation belongs to the field, a target belongs to the episode.** An
  unusable field reports itself on its own channel, never composed with a
  recovery phase, and still never cancels a retry already owed. A connect
  gesture about an established episode -- selecting a pane -- reuses that
  episode's target and is neither blocked nor reported on by the current
  contents of the text fields.
- **I5 -- the presentation is decided where it can be tested.** The wording of a
  causal state, the wording of a recovery phase, and their composition are pure
  and live in the kit; the shell paints the result and decides none of it.
- **I6 -- the scheduled budget cannot be exceeded, by construction.** The
  episode's stated effort is its scheduled automatic attempts, and the policy
  schedules none beyond it. A signal arriving after give-up still grants one
  prompt attempt, as the shipped policy already provides; that grant neither
  restores the exhausted effort nor draws on it. The policy holds no quantity
  that grows without bound, and its safety does not rest on a range check.
- **I7 -- the shipped policy's behavior is unchanged.** Classification,
  scheduling, give-up, signal arming, and budget rearming behave exactly as
  before; the shipped plan's invariants and its existing tests stand untouched.

## Proof obligations

- **PO1 (I1).** A headless test drives the instrument while the run loop runs in
  a non-default common mode and shows the deadline is still delivered, and shows
  it is never delivered before the deadline. Both are proved against the
  instrument's own monotonic base. Neither asserts an upper bound on lateness:
  I1 does not claim one, and a passing run must never depend on production being
  fast enough. I2 -- that the shell's retry and checkpoint flush both route
  through the instrument -- is an architectural obligation discharged by
  implementation review, since nothing in the shell is under test.
- **PO2 (I3, I5).** A table-driven kit test over reachable causal-state and
  recovery-phase pairs asserts the composed text, including that rest after
  give-up presents the plain terminal state with no recovery clause. This
  discharges the shipped plan's presentation obligation, which until now had no
  test outside the shell.
- **PO3 (I3, I4).** A form problem has no representation in the connection
  status channel: constructing one is a compile failure, not a runtime
  convention. A headless kit test drives both gestures against one unusable
  draft: the target-setting gesture reports a field problem and leaves any
  pending recovery untouched, while the pane-naming gesture connects to the
  established episode's target and reports no field problem at all.
- **PO4 (I6, I7).** The existing policy suite passes unchanged, and a long
  sequence alternating a signal and a failure after give-up authorizes exactly
  one attempt per signal and never more. That is the whole behavioral claim: no
  test can observe the budget's representation without asserting private
  structure, so I6's second half -- that nothing in the policy grows without
  bound and no range check is load-bearing -- is an architectural obligation
  discharged by implementation review.

## Non-goals

- The `retrying in Ns` label counting down. It reads the same composition this
  plan moves into the kit and would be cheaper to add afterwards, but it needs a
  second recurring tick and is separately owned.
- A disconnect affordance, and therefore a producer for the policy's user-cancel
  event.
- A declared gap presenting as a lost connection while the connection is
  healthy. This plan carries its wording across unchanged; giving it a state of
  its own is separately owned.
- The readiness-based connection reader, focus-report semantics, the audit
  descriptor's resume-versus-fresh-join gap, and anything about the liveness
  bound's value or its silence-declaration semantics.
- Any change to the retry classes or to the user-facing failure vocabulary.

## Accepted risks

- **AR1.** A problem reported beside the field is easier to miss than one in the
  status line the user is already watching. Accepted: a message in the wrong
  channel that composes into nonsense is worse than a quieter true one.
- **AR2.** The kit gains a component that owns a real timer, so not everything
  in it is a pure value. Bounded: the kit is portable by contract and already
  owns sockets and a thread, and the instrument is testable headlessly -- which
  is exactly what it is not while it lives in the shell.
- **AR3.** Selecting a pane stops re-reading the text fields, so editing the
  host and then tapping a pane row no longer retargets the connection. The Go
  button becomes the only retarget gesture. Deliberate: a pane row names a pane
  in the episode that produced the list, not a new server.
- **AR4.** The shipped plan's live hardware smoke is still unrun, and this work
  changes both the header text it reads and the retry timing it observes. Run it
  after this work, not before.

## Rejected ideas

- **RI1 -- add the existing timer to the common run-loop modes.** Fixes the
  mode gate in one line and leaves both of the other problems exactly where they
  are: the deadline still crosses from a monotonic base to a wall-clock fire
  date, and the shell's obligation stays unprovable because nothing in the shell
  is tested. The defect is that the instrument is wrong, not that it is
  configured wrong.
- **RI2 -- a kit-owned driver that also owns the policy and the event
  dispatch.** The attempt itself cannot move into the kit -- it carries the
  generation guard, the checkpoint flush, and the replica reset -- so the driver
  would add a second seam to carry a mapping of a few lines, while the whole
  defect lived in the timing instrument alone.
- **RI3 -- disable the connect control while the fields do not parse.** The
  strongest form of "cannot happen", but a disabled control names no problem, so
  the user is left to work out which field is wrong.
- **RI4 -- give form validation an entry in the connection-state vocabulary.**
  That vocabulary is total over connection causes and each entry names a remedy
  against a target. A form with no target has no such remedy, and admitting it
  would re-open the composition this plan closes.
- **RI5 -- cap the attempt counter at the budget.** Keeps the counter and adds a
  second rule to reason about. The counter is the wrong representation; a cap
  papers over that.

## Implementation discretion

- The instrument's shape, and how the shell holds and cancels it.
- The validation wording and where the field channel sits in the header layout.

## Commit progress
- [x] 1. the reconnect deadline survives a drag and a clock correction
- [ ] 2. form validation leaves the connection status channel
- [ ] 3. the retry budget is what remains, not what was spent

## Implementation notes

- **PO1's run-loop-mode half has no headless test, and cannot have one in this
  harness.** The instrument delivers through a dispatch timer on the main queue,
  which CFRunLoop drains in every common mode -- the production property I1
  states. A test cannot observe it: a swift-testing test body already runs as a
  main-queue block, and libdispatch does not drain the main queue re-entrantly
  from a nested run loop, so no nested mode-running loop in a test can ever see a
  main-queue delivery. Measured directly with a throwaway probe: a nested run
  loop in a test fires run-loop timers but drains no main-queue block. What the
  suite does prove behaviorally is I1's other half -- delivery is never before the
  deadline on the instrument's own monotonic base -- plus replacement and
  cancellation. The mode claim joins I2 as an obligation discharged by
  implementation review: the instrument creates no `Timer` and registers on no run
  loop.
- **The clock became a named kit value.** `MobileMonotonicClock.now` replaces the
  shell's direct `ProcessInfo.processInfo.systemUptime` readings, so the base the
  policy schedules on and the base the timer delivers on are one declaration
  rather than two matching call sites.
