# Authoritative mobile connection lifecycle

## Problem and outcome

`MobileSessionModel` stores the live connection across independent optional
facts. A hand-written teardown must clear them together, and the selected pane
survives teardown even though ordinary input uses it as permission to send. The
shell currently fences stale frames and drops sends when no runner exists, but
the model can still produce effects for a connection that is gone.

Replace these facts with one lifecycle that is the authority for connection
phase, attached pane, request identities, claim, stream condition, request
outcome, and status presentation. Invalid combinations must be absent from the
model rather than repaired by reset lists or discarded by the shell.

The phone issues only string JSON-RPC identities. The shared protocol must
remain able to represent notifications, omitted ids, and `null` parse-error
ids.

## Decision

- Add a string-backed mobile request-id value. Use it throughout the mobile
  environment and effects, and convert it to JSON only at the wire boundary.
  Do not narrow the shared JSON-RPC envelope.
- Give the session model one connection lifecycle covering disconnected,
  connecting, pane attachment, serving, and failed states. The serving state
  owns the attached pane and every fact whose lifetime is that connection.
- Derive the status line from the lifecycle and reconnect recovery. Status is
  an immutable projection, not a separately mutated copy of connection facts.
- Keep the user's preferred pane separate from the last pane resolved and
  attached. While serving, the projection and New pane action use the
  lifecycle's attached pane; outside serving, the projection retains the last
  resolved pane.
- Only the serving lifecycle may authorize a request-bearing pane action.
  Local viewport movement remains authorized by the retained replica and its
  surface facts after teardown.
- Treat connection callbacks that arrive outside their valid lifecycle phase
  as stale input. They produce no effect and cannot revive or alter a later
  connection.
- Background teardown enters the disconnected lifecycle and presents
  "Disconnected" until a foreground attempt enters connecting.

## Invariants

- I1. A serving connection always has one non-null string tape request id and
  one attached pane.
- I2. A claim, pending New pane request, stream condition, and ordinary request
  outcome cannot outlive the serving connection that owns them.
- I3. No request-bearing input, owner-directed scroll, claim, split, or tape
  effect can be emitted without a serving connection. Local viewport movement
  remains available while the retained replica is displayed.
- I4. Omitted, `null`, or foreign response ids can never match a request the
  phone issued. Only the exact tape id can classify a refusal as connection
  ending.
- I5. Connection status, serving details, and request authority have one model
  owner. Recovery scheduling remains independently owned by the reconnect
  episode and is composed into the projection.
- I6. Existing response-versus-record ordering for claim confirmation and
  external release is unchanged.
- I7. Checkpoint dirt and its deadline are session-scoped. Connection teardown
  does not discard or disable checkpoint work.

## Proof obligations

- PO1 (I1, I4): On a serving stream, omitted, `null`, and foreign-id errors
  leave the connection serving; an error with the exact tape id ends it.
- PO2 (I2): Connection end prevents an old claim from renewing and prevents an
  old New pane request from suppressing the affordance after reconnect.
- PO3 (I3): After teardown, every input category and owner-directed scroll emits
  no request, while local viewport scrolling over retained content still works.
- PO4 (I1-I3): Stale frame, replica-state, and pane-attachment callbacks after
  teardown produce no effects and cannot start a stream. Checkpoint events keep
  their session-scoped behavior.
- PO5 (I5): While backgrounded, the complete composed status line is
  "Disconnected" with no recovery clause; foreground reconnect projects the
  connecting state with its target detail. Failure severity, retry wording,
  serving stream condition, and request-outcome wording retain their current
  behavior.
- PO6 (I6): The existing claim response and tape-record ordering scenarios pass
  unchanged.
- PO7: When a preferred pane has left the roster, reconnect falls back to an
  available pane, the projection names that attached pane, and New pane remains
  available for its tab.
- PO8: The mobile package suite, portability lint, and repository gate pass.

## Non-goals and rejected ideas

- Non-goal: redesign JSON-RPC identities across the server, CLI, or shared
  protocol. Those readers must continue to accept the current wire vocabulary.
- Non-goal: change reconnect scheduling, resume policy, pane selection, or wire
  shapes.
- Rejected: guard an optional tape id before comparison while retaining the
  independent fields. It protects an unreachable state but preserves the reset
  list and stale-send behavior.
- Rejected: keep mutable status beside an operational lifecycle. That would
  preserve two authorities for the same connection phase.

## Dependencies and delivery

IOS-1/MOBILE-3 (`40ca4c51`) and IOS-2 (`b6e331d1`) are complete prerequisites.
Resolve the overlapping IOS-5 removal of the dead `listingPanes` status before
or in the same change. Land this lifecycle before any MOBILE-5 asynchronous
replica-delivery redesign so that boundary has one connection authority to
report into.

Use TDD for each changed behavior. Run targeted mobile model and status tests
during the edit loop, then the mobile package suite and lint. Run `just test`
before the commit.

## Implementation discretion

- The private lifecycle's internal type names and file placement are left to
  implementation, provided the ownership and phase invariants above hold.
