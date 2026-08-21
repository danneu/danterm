# iOS reconnect: make the episode the one target authority

## Problem and desired outcome

The phone stores the reconnect episode's target separately from the policy that
authorizes attempts. A valid Go gesture can replace and persist that target
while an older attempt is in flight, but the policy rejects the gesture because
an attempt already exists. The old attempt remains current and can connect to a
server the user just replaced.

The reconnect path should have one authority for the active target. Every
authorized attempt should carry that authority's target, and a manual gesture
should replace an in-flight attempt without allowing automatic signals to start
overlapping attempts.

Load-bearing premises from the current tree:

- Network-path and app-lifecycle facts can arrive before the first valid target,
  and must still govern later automatic recovery.
- The shell performs a reconnect by disconnecting before connecting. Disconnect
  invalidates the old attempt's generation, so a late result cannot become
  current.
- An invalid draft must leave an existing target and any recovery owed to it
  unchanged. Pane selection must reuse that target without reading the draft.

## Decision

Replace the separate target holder and reconnect policy with one reconnect
episode state machine. It has a targetless idle state and an active state that
owns the validated target and the existing scheduling state. Network-path and
lifecycle facts remain available in both states.

The episode distinguishes a gesture that names a new server from one that
reuses the active server. A decision to attempt now carries the exact target it
authorizes. Both gestures are the same manual remedy: each restores the retry
budget and replaces any in-flight attempt. The distinction only decides whether
the authorization carries a newly validated and persisted target or reuses the
active target. Automatic signals retain the existing one-at-a-time rule.

Draft validation becomes stateless. The session model stores no second copy of
the active target, and starting an attempt takes a non-optional target from the
episode's decision. The existing flush, disconnect, and connect ordering stays
intact.

Behavioral scope is limited to target ownership and manual replacement of an
in-flight attempt. Retry classification, backoff, capacity floors, stability,
presentation, resume policy, persistence, and the wire protocol do not change.

## Invariants

- **I1 -- one target authority.** The active reconnect episode is the only
  stored authority for the server target. Draft fields and persisted defaults
  are inputs or outputs, not competing episode state.
- **I2 -- authorization is complete.** Every attempt authorization carries a
  validated target. The session cannot authorize an attempt and then discover
  that it has nothing to dial.
- **I3 -- manual replacement wins.** Every valid manual connect gesture replaces
  any in-flight attempt, restores the retry budget, and starts either its newly
  named target or the active target it reuses. The old attempt is disconnected
  before the new one starts, and a late old result cannot become current.
- **I4 -- automatic attempts do not overlap.** Timer, path, and lifecycle
  signals cannot start another attempt while one is in flight.
- **I5 -- idle facts survive.** Path and lifecycle facts observed before the
  first target still govern automatic recovery after that target's manual
  attempt ends.
- **I6 -- invalid drafts are isolated.** An invalid draft reports its own
  problem without changing the active target, retry budget, or pending recovery.
  Pane selection reuses the active target without consulting the draft.
- **I7 -- existing recovery behavior survives.** Retry classes, budget
  exhaustion and restoration, capacity floors, stability rearming,
  backgrounding, cancellation, and recovery presentation remain unchanged.

## Proof obligations

- **PO1 (I1-I3).** A model test starts an attempt for one server, leaves it in
  flight, then submits a second valid server. The observable effects persist the
  second target, disconnect the first attempt, and connect the second in order;
  the presented status describes the second target.
- **PO2 (I2, I4).** Episode tests show that every immediate and automatic
  authorization carries the active target, automatic signals rest during an
  in-flight attempt, and both kinds of manual gesture authorize a replacement.
  Reuse is covered both during an in-flight attempt and after budget exhaustion.
- **PO3 (I5).** A test records an unusable path while idle, starts the first
  target manually, then shows that its failure waits for the path and that path
  restoration retries the same target.
- **PO4 (I6).** Model tests show that an invalid edit leaves an existing retry
  intact, a pane gesture after that edit reconnects to the established target,
  and a pane gesture before any episode does nothing.
- **PO5 (I7).** The existing behavioral suite continues to prove failure
  classification, schedule and budget bounds, capacity timing, stability,
  lifecycle, cancellation, and recovery wording with target-bearing
  authorizations.
- **PO6 (I3).** A one-time manual simulator probe replaces a slow or unreachable
  server with a reachable one and confirms that only the replacement becomes
  current, even if the abandoned attempt finishes later.

## Non-goals

- Redesigning live-connection identity or resolving the separate IOS-3
  structural finding.
- Removing unused reconnect vocabulary from IOS-5.
- Changing retry timing, adding a disconnect control, or adding an app test
  target.

## Accepted risks

- **AR1.** The late-callback fence remains app-shell behavior without a unit-test
  target. Accepted because the fence is unchanged; model tests prove the
  required effect order, and a one-time manual simulator probe checks the
  integrated outcome. No standing regression gate covers that callback fence.
- **AR2.** Public MobileKit reconnect and target-validation source APIs may
  break. Accepted because DanTerm requires no internal source compatibility and
  keeping compatibility shims would preserve the duplicate vocabulary.

## Rejected ideas

- **RI1 -- delete only the in-flight guard.** This fixes the visible gesture but
  leaves target ownership and attempt authorization separately coordinated.
- **RI2 -- add a target field beside the current target holder.** This moves the
  disagreement instead of making it impossible.
- **RI3 -- make the active episode optional and discard the idle policy.** This
  loses path and lifecycle facts received before the first target.

## Implementation discretion

- The internal names and file layout of the episode state machine and stateless
  draft validator.
- How the existing policy tests share a representative target while retaining
  their behavioral assertions.
