# Write the recorder state-synchronization pairing once

## Context

The landed plan `plans/impl/2026-08-17-1557-typed-production-fence-payload.md`
left one follow up: `TerminalFlightRecordingStateSynchronization` is assembled
more than once in `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`.
It named the work a non-goal because deduplicating it must not move a timing
boundary.

Investigating that follow up found its premise wrong in two ways. The assembly
happens at three sites, not two. And one of the three, `fencedStateSynchronization()`,
has no production caller at all -- it is a `package` fence kept alive by a single
host test. The duplication is the smaller half of the problem; a production-dead
entry point that a test mistakes for API is the larger half.

Desired outcome: the pairing is written in one place, no host fence exists only
to serve a test, and the scrollback serialization keeps running off the owner
queue.

## Load-bearing premises

- **One of the three sites is production-dead.** `fencedStateSynchronization()`
  has zero callers in `lib/`, `app/`, `cli/`, `ios/`, and `tests-ui/` other than
  the test `stateSynchronizationSharesRecorderFence`. It is the surviving sibling
  of the dead counted operation the previous plan deleted, kept only because a
  test drove it.
- **Its payload is already reachable from production.** It returns the same
  pairing as the stream fence's `synchronization`: the same fence, taken against
  the same live recorder cursor.
- **The other two sites are production.** `TerminalPaneSession` forwards them,
  and `app/SwiftTerminalSessionView.swift` drives them.
- **Serializing state is proportional to scrollback.** `Terminal.stateSynchronization`
  materializes every retained history row plus both screens into replay bytes.
  All three sites copy the cheap `Terminal` value out of the fence and serialize
  after it returns, so the owner queue -- which also ingests PTY output -- never
  stalls on a history walk. This is the timing boundary the previous plan
  protected, and it is real.
- **The boundary constrains the dedup shape, not the dedup.** A shared builder
  invoked inside the fence closure would move the serialization onto the owner
  queue. One invoked after the fence returns runs at exactly the point the
  memberwise initializer runs today.
- **The type is consumed, not constructed, outside the package.** `app/` only
  reads the type.
- **Nothing external pins these names.** No lint script and no design doc names
  any of the affected symbols.

## Decision

Three moves, in this order:

1. **Delete `fencedStateSynchronization()`** and retarget its test at the
   production stream fence. The test's distinctive value is its continuation
   replay -- replay the state bytes into a fresh terminal, replay the recorded
   suffix from the paired cursor, and match the live pane -- which is stronger
   than what the existing stream-fence test pins. That assertion must survive the
   move; only the fence it drives changes.
2. **Write the pairing once, and make it unforgeable.** Introduce one value that
   holds the fence-copied terminal beside the cursor paired with it and
   serializes only when resolved, after the fence returns. Its only constructors
   are isolated members on the host that derive both pairing ingredients -- the
   terminal and the cursor its state is paired with -- off the owner in a single
   turn, taking neither from the caller, so a cross-turn pairing has no
   initializer to call. Parameters that are not pairing ingredients, such as a
   subscription id or a cursor whose placement is being asked about, stay
   ordinary arguments. Both surviving sites fence for that value and
   resolve it afterward. The genuine difference between the two stays visible at
   the call sites: one pairs with the live recorder cursor, the other with the
   followed snapshot's next cursor.
3. **Seal construction behind the resolve step**, which becomes the only way to
   obtain a `TerminalFlightRecordingStateSynchronization`. No other initializer
   stays reachable, from `app/` or from the package's own tests. Nothing outside
   the host constructs one today, so this closes the path rather than migrating
   callers.

Critical files: `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift`, and
`lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift`.

## Invariants

- **I1.** Every `TerminalFlightRecordingStateSynchronization` carries state bytes
  and a recorder cursor read in the same owner turn. No reachable API accepts the
  two as independent arguments, so a cross-turn pairing does not compile.
- **I2.** The serialization of terminal state never runs on the owner queue.
- **I3.** The pairing is serialized in exactly one place in the package.
- **I4.** State bytes plus the recorded suffix taken from the paired cursor
  reconstruct the live pane, with no output dropped or applied twice across the
  seam.
- **I5.** No fence on the host exists solely to serve a test.
- **I6.** Every fence keeps its production-accounting classification. This change
  adds and removes only uncounted fences, so the production census is untouched.

## Proof obligations

- **PO1** (I1): the build is the proof. The only way to obtain the pairing is the
  resolve step, and the only way to obtain what it resolves is a host mint that
  takes neither pairing ingredient from its caller, so code pairing a terminal
  from one turn with a cursor from another fails to compile. No test
  can establish this, and none is asked for: no test can force PTY output to land
  between two internal fences.
- **PO2** (I4): the retargeted continuation-replay test, driving the production
  stream fence.
- **PO3** (I4): the existing follow-fence test continues to pin that a followed
  suffix and its replacement state end at the same recorder cursor, unchanged.
- **PO4** (I6): the existing stream-fence and fence-accounting tests pass
  unedited. A correct refactor cannot need them changed. I3 is not observable to
  a test -- two sites with separate but equivalent serialization would stay green
  -- so it is an implementation-review criterion, not a test obligation.
- **PO5** (I5): the deleted fence has no production caller, so the full gate stays
  green with nothing else edited.
- **PO6** (I2): discharged by construction -- both call sites resolve the pairing
  after their fence returns. See AR1.

Verification: `just test` for the gate; `swift test --package-path lib/TerminalPTY
--filter TerminalPTYHostTests` for the retargeted and neighboring tests;
`bash ./dev-build.sh --no-install` to confirm `app/` still compiles once the
initializer is sealed. Then run a slot (`just launch-slot`), split a pane, and
follow a flight recording from another pane to exercise the two surviving fences
live, since both feed the recorder read path.

## Non-goals

- Deduplicating the assembly of `TerminalFlightRecordingStreamFence` and
  `TerminalFlightRecordingFollowFence` themselves. They differ in what else their
  fence reads.

## Accepted risks

- **AR1.** Nothing enforces I2. Resolving the pairing inside a fence closure
  instead of after it would compile and would put an O(scrollback) serialization
  on the owner queue. Rationale: no type expresses "not inside `queue.sync`", and
  a lint was considered and rejected (RI1). The resolve step's own comment
  carries the constraint.

## Rejected ideas

- **RI1.** A lint asserting the host file never names the serializer. It would
  pin I2 in one grep once the last mention leaves that file. Rejected because the
  existing lint family pins global, cross-file, count-based invariants, and this
  one is intra-file.

## Implementation discretion

- Which cursor the retargeted test supplies to the stream fence, given that the
  test asserts nothing about cursor placement.
- Where the pairing value is declared, whether the host exposes one mint or two,
  and what a mint returns alongside the pairing when its caller also needs the
  intermediate it derived.

## Implementation notes

- **Both types now live in `TerminalPTYHost.swift`, and
  `TerminalFlightRecordingStateSynchronization` moved there from
  `TerminalFlightRecorder.swift`.** Sealing both initializers means `fileprivate`,
  which needs the mints, the pairing, and the resolved type in one file. The mints
  must be host members that read `terminal` and `flightTape`, and both of those are
  `private` to `TerminalPTYHost.swift`, so that file is the only one where the seal
  closes. `TerminalPTYProductionFenceOperation` in the same file already uses this
  idiom -- a `fileprivate` member that makes the file the sole mint.
- **Two mints, not one.** `liveStatePairing()` and
  `followedStatePairing(subscriptionId:from:)` differ in which cursor they pair
  with, which is the difference the plan asked to keep visible. The follow mint
  returns its suffix snapshot beside the pairing, because the caller needs the same
  derived value for `TerminalFlightRecordingFollowFence.snapshot`.
- **The retargeted test drives the stream fence from `.beginning`.** The test
  asserts nothing about cursor placement, so the request cursor only has to be one
  the fence accepts.
- **Live check.** A dev slot reproduced both fences: a reconstructible dump
  (stream fence) and a `--follow --from-now` capture (follow fence). The follow's
  `sync` record paired state with recorder sequence 26 and the following events
  resumed at sequence 26, with nothing dropped or repeated across the seam.
