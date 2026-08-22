# Make pane roster delivery state connection-owned

Source: RECON-6 in `docs/scratch/2026-08-18-construction-audit.md`,
verified 2026-08-21 against `3f106a3a`. This is a pivot from the finding's
shared optional baseline.

## 1. Problem, outcome, and evidence

`AppRuntime` projects and compares the full pane roster after every completed
reconcile, even when no connection subscribes. Its shared baseline also cannot
accurately describe subscribers that joined or repeated their request at
different times.

The runtime should do no roster work without subscribers. Each subscribed
connection should independently track the last complete roster placed on its
FIFO write queue.

The current implementation builds the baseline during runtime initialization,
then `pushRosterIfChanged` projects and compares before it checks
`rosterSubscribers`. Commit `b49b6db2` introduced both paths, and no later
change removed them. The roster subscribe command already carries the current
projection into the runtime, so a subscription has the value it needs without
another projection.

## 2. Decision

Each runtime roster subscription owns its connection, lifecycle token, and
last enqueued roster. There is no global roster baseline.

After a reconcile, an empty subscriber registry returns before roster
projection. Otherwise the runtime projects the roster once, compares it with
each subscriber's baseline, and notifies and advances only subscribers whose
roster differs.

A successful new or repeated subscription uses its bootstrap roster as that
connection's baseline. Replacing one connection does not change any sibling's
baseline. A disconnect removes that connection and its baseline.

The full-state `roster.event` wire format and FIFO connection writes stay
unchanged. No public API, protocol, core, client, or iOS change is required.

## 3. Invariants

- I1. An empty subscriber registry causes no roster projection, comparison,
  encoding, or notification.
- I2. A subscriber receives a notification only when the current roster differs
  from the last roster enqueued for that connection.
- I3. A new or repeated subscription cannot swallow a pending update owed to
  another connection.
- I4. A bootstrap or repeat reply that already contains pending state is not
  followed by a duplicate notification containing that state.
- I5. Connection drop, repeat subscription, and shutdown preserve the existing
  connection-scoped ownership and lifecycle census behavior.

## 4. Proof obligations

- PO1 (I2-I4): Update the pending-change runtime test so the original
  subscriber receives the pending title, the newcomer receives it in the
  bootstrap reply, and the newcomer's next notification is a later roster
  change rather than a duplicate title roster.
- PO2 (I2, I4): Strengthen the repeat-subscription test with a pending roster
  change. The repeat reply contains the current roster, and the next
  notification contains a later change rather than a duplicate.
- PO3 (I2, I3, I5): The existing runtime tests for inline reconciliation,
  coalesced reconciliation, restore, non-roster changes, sibling disconnects,
  and shutdown ownership pass unchanged.
- PO4 (I1): Direct control-flow review confirms that the empty-registry guard
  precedes roster projection. Do not add timing probes, call-count spies, or
  projection injection solely to test this internal cost.

Write the failing behavioral tests first. Run the focused
`AppRuntimeRosterPushTests` suite plus `just lint` during the loop, then run
`just test` before commit.

## 5. Non-goals and rejected ideas

- N1. No roster deltas, sequence numbers, resync protocol, or client changes.
- N2. No optimization of the pure roster projection while subscribers exist.
- RI1. A shared optional cohort baseline is rejected because a newcomer can
  hold newer state than an existing subscriber. One shared value cannot
  describe both connections without either swallowing or duplicating an
  update.

## 6. Implementation discretion

- D1. The mutation mechanics used to update subscriber values while iterating
  the keyed registry are implementation discretion.

Baselines describe values accepted by the connection's FIFO write queue,
matching the runtime's existing asynchronous write semantics.
