# Bounded iOS replica continuation via self-synthesized state checkpoints

## Problem and desired outcome

The iOS client's process-death continuation record
(`ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift`) stores the
last complete server synchronization plus every later neutral event and the
advancing cursor. The event suffix grows with session duration after the last
server sync, so memory, encode work, and persisted storage grow without bound.
The shell JSON-encodes that archive -- sync bytes as a numeric JSON array --
into UserDefaults on a coalesced timer and on backgrounding.

Desired outcome: after iOS process death the app still restores a visible,
exact terminal immediately and resumes the stream from its cursor, applying
later events exactly once, with a fresh server sync as the designed recovery
when the cursor cannot be honored -- and the continuation record is bounded by
the terminal's retained state, independent of session age. The remote grid
stays authoritative; the phone never resizes the Mac pane.

Load-bearing premises, taken from the tree and the research record:

- The engine already owns portable, exact state serialization.
  `Terminal.stateSynchronization`
  (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`) emits
  reset-to-current terminal bytes covering retained history, the primary and
  active alternate screens, geometry, cursor and saved cursor, pending
  autowrap, tab stops, scroll region, input and mouse modes, kitty keyboard
  stack, current style and hyperlink pen, hyperlink metadata at the shared
  cap, semantic prompt ownership, REP/grapheme-cluster memory, and unfinished
  input recognition (a fence inside UTF-8/CSI/DCS/OSC) via the parser's
  synchronization prefix. `TerminalStateSynchronizationTests` pins round-trip
  equivalence for each of these, including the mid-sequence fences. The
  engine has no image protocol, so images are outside the state universe. The
  inactive alternate screen is excluded by design -- the engine blanks it on
  entry (research/35, D5 shipped notes).
- research/35/D5 decided that pane state transfers as terminal bytes, not a
  structured dump, and that no stream's ability to reach exact state depends
  on retention: the server injects a sync whenever a requested cursor cannot
  be placed, and a cursor is meaningful only to the recorder lifetime that
  minted it.
- Retained terminal state is almost bounded: scrollback is byte-budgeted with
  head eviction (`Terminal.scrollbackByteLimit`, the `LogicalLineStore`
  budget), hyperlink metadata sits under a shared cap, and the kitty keyboard
  stack has a fixed depth. The exception is grapheme-cluster storage: a live
  cell's scalars and the REP/last-printed-cluster memory grow without bound
  under a continuing combining-scalar stream, and `stateSynchronization`
  serializes both (the oversized-repeat-cluster test pins retention of a
  cluster over 2 MiB encoded). This is the one component that lets serialized
  state grow with session age, and this plan closes it (D-pre, I6).
- The Mac already pairs these bytes with a continuation cursor as one
  inseparable fence (`TerminalFlightRecordingStateSynchronization`), which is
  exactly the atomicity shape a client checkpoint needs.
- The replica invariant (step-0 plan, I3) makes an exact replica's terminal
  state equal, in observable terms, to the authoritative pane at the same
  cursor -- so bytes synthesized from the replica are as good as bytes
  synthesized on the Mac at that fence.

## Decision

**Delete the event suffix. The replica synthesizes its own baseline: a
checkpoint is the engine's state-synchronization bytes for the replica's
current terminal, captured together with the current cursor.** Restore builds
a fresh terminal at the checkpoint geometry, feeds the bytes, discards drained
authority (reply bytes, clipboard, semantic events), and resumes the stream
from the checkpoint cursor. Growth cannot happen because nothing accumulates:
a checkpoint is a pure function of bounded current state, taken whenever the
app wants one, and each checkpoint replaces the last.

**D-pre -- engine prerequisite: bound grapheme-cluster retention.** Before the
checkpoint work, TerminalCore places a behavioral byte bound on per-cell
cluster storage and on REP/last-printed-cluster memory, so that every
variable-size component `stateSynchronization` serializes is bounded. Scalars
past the bound are dropped rather than retained. The references disagree
here, so there is no universal behavior to match: Alacritty retains
zero-width scalars unboundedly
(`references/alacritty/alacritty_terminal/src/term/cell.rs#Cell::push_zerowidth`),
kitty caps a cell at 24 code points, libvterm exposes six, xterm about five.
The bound is therefore a documented compatibility decision, not a mirror:
probe the relevant reference binaries' continuing-combining-stream behavior
per the repo's probe discipline, record the disagreement and the chosen
retention bound in the engine design register, and let boundedness win --
DanTerm's own invariant outranks matching the one uncapped reference. The
Mac benefits identically -- pane memory and D5 sync payloads on the wire gain
the same bound.

**The persisted envelope carries an integrity check over the entire
checkpoint except the integrity field itself** -- state bytes, cursor,
geometry, pane identity, and format version alike. Any field that decodes
cleanly can still be silently wrong after a bit flip (a valid-looking
geometry would rebuild the terminal at the wrong size and still resume from
an honorable cursor); verification runs before any terminal is constructed.

Ownership, and why it sits where it does:

- **TerminalCore** already owns the state representation; the checkpoint
  path adds no new serialization API or format to it, and no IO or
  persistence. Its one engine change is D-pre, which alters the grapheme
  retention contract, not serialization. Reusing D5's bytes-as-state
  representation means one exactness surface with one set of equivalence
  tests, shared with the Mac's sync path.
- **The kit's replica** owns pairing state with cursor, because only the
  replica knows both at one coherent fence. The incremental archive type, its
  per-event append, and archive replay on restore are deleted.
- **The kit** also owns persistence of the checkpoint (a store working on an
  injected directory), so persistence behavior is headless-tested in the Mac
  suite. Persistence moves out of UserDefaults into a single
  atomically-replaced file: the payload can approach the scrollback budget
  (16 MiB class), which does not belong in the defaults plist, and the
  encoding must not inflate bytes into per-byte JSON numbers. UserDefaults
  keeps only small scalar settings (host, port).
- **The UIKit shell** owns only lifecycle triggers: when to ask for a
  checkpoint and persist it (coalesced updates, backgrounding), and restoring
  before requesting stream continuation. The old per-pane UserDefaults blobs
  are abandoned without migration (private format, single user).

Behavioral scope: continuation after process death is otherwise unchanged --
resume from cursor, apply later events once, explicit gap plus fresh sync when
the cursor cannot be honored. Restore-from-checkpoint presents exactly like
applying a server sync: following viewport, fresh mouse-interaction state.

## Invariants

- **I1 -- boundedness independent of session age.** A checkpoint is a pure
  function of the replica's current terminal state and cursor. Its size is
  bounded by the engine's retained-state bounds (geometry plus the scrollback
  byte budget) and is independent of session duration and of the number of
  events applied since the last server sync. The replica keeps no per-event
  continuation state in memory, and the store retains at most one checkpoint
  (the last-subscribed pane's). Persisted size stays within a small constant
  factor of the state-synchronization payload.
- **I2 -- exact restore plus resume.** A replica restored from a checkpoint
  matches the pre-death replica at the same cursor on observable state --
  including the state D5's acceptance rule names because it does not
  self-heal (scrollback depth, input modes, alternate-screen flag) and grid
  content -- and subsequent stream events from that cursor apply identically
  on both wherever they act on serialized authoritative terminal state,
  including events that complete a byte sequence split across the checkpoint
  fence. Events that continue an interaction gesture begun before the
  checkpoint (a held pointer, a drag in progress, an accumulated wheel
  remainder) are outside this equivalence: restore begins with fresh
  interaction state, exactly as a server sync replacement does (AR1), and the
  next complete gesture behaves normally.
- **I3 -- one coherent fence, atomic persist.** A checkpoint's state and
  cursor are captured together from the replica's last exact fence; no
  checkpoint pairs state from one moment with a cursor from another, and a
  partially assembled sync or a gap state never leaks into one. An
  interrupted persist leaves the previous checkpoint or the new one readable,
  never a blend.
- **I4 -- recovery is total and never silently wrong.** A checkpoint that
  cannot be honored ends in a fresh sync, not in wrong state: decode failure,
  integrity-verification failure (mutation of any envelope field -- state
  bytes, cursor, geometry, pane identity, or format version -- inside a
  still-decodable envelope, rejected before any terminal is constructed),
  format-version mismatch, pane mismatch, or geometry the engine rejects
  discards the checkpoint and subscribes from now; a stale recorder lifetime
  or unplaceable cursor takes the existing server gap-plus-sync repair,
  presented through the replica's explicit gap state. Correctness is
  independent of checkpoint cadence: a stale-but-valid checkpoint only makes
  the server replay more, or gap-and-sync.
- **I5 -- layer boundaries hold.** TerminalCore gains no IO, persistence,
  UIKit, or second serialization format; the checkpoint's state
  representation is the engine's existing state-synchronization bytes.
  Checkpoint assembly, restore, and the store live in the portable kit and
  are exercised headlessly in the Mac suite under the existing portability
  gate; the shell contributes lifecycle triggers only.
- **I6 -- engine retained state is byte-bounded.** After D-pre, every
  variable-size component `stateSynchronization` serializes -- per-cell
  cluster storage and REP/last-printed-cluster memory included -- carries a
  behavioral byte bound, so serialized state size is bounded by geometry plus
  fixed caps plus the scrollback budget, independent of input history. The
  retention bound is a documented contract recorded in the engine design
  register: content within it round-trips exactly, and scalars past it are
  dropped without corrupting the cluster or later output.

## Proof obligations

- **PO1 (I1, I6).** Two replicas that reach identical terminal state and
  cursor through different-length event histories produce identical
  checkpoint payloads; and a replica that keeps churning events after
  retained history saturates its budget shows no further checkpoint-size
  growth. The churn scenarios include a continuing combining-scalar stream
  onto one cell, so the plateau covers grapheme storage, not only
  scrollback. All are behavioral: they read only checkpoints, not internals.
- **PO7 (I6).** Engine-level: under a combining-scalar stream past the bound,
  cell content, REP memory, and the state-synchronization payload stop
  growing, the terminal stays coherent (later feeds, round-trip
  synchronization, and rendering still agree with a never-flooded terminal
  outside the flooded cell), content within the documented bound is
  preserved unchanged, and the first scalar past it is dropped cleanly.
- **PO2 (I2).** Kill-and-restore equivalence: build a replica from a sync and
  events, checkpoint, encode, decode, restore, then apply an identical
  subsequent record sequence to the original and the restored replica and
  assert observable-state equality. Scenarios must include a fence inside an
  unfinished escape or UTF-8 sequence, pending autowrap, an active alternate
  screen over retained primary history, and non-default input modes. A
  further scenario checkpoints mid-gesture and asserts the restored replica
  starts with fresh interaction state and handles the next complete gesture
  as a sync-fresh replica would (I2's stated exclusion).
- **PO3 (I3).** A checkpoint taken while a multi-record sync is partially
  assembled, or while the replica is in a gap state, reflects only the last
  exact fence. A simulated torn write leaves the prior checkpoint readable.
- **PO4 (I4).** A table over corruption, version mismatch, pane mismatch, and
  engine-rejected geometry asserts the checkpoint is discarded and the
  subscription starts from now. The corruption rows must cover a
  still-decodable mutation of each envelope field -- state bytes, cursor,
  geometry, pane identity, and format version -- rejected before any
  terminal is constructed; malformed-envelope rows alone do not discharge
  this obligation. Restore followed by reconnect against a
  foreign recorder lifetime produces the explicit gap and then converges
  through the replacement sync (the existing replica reconnect tests,
  extended over the checkpoint path).
- **PO5 (I5).** The checkpoint and store tests run in the ordinary Mac suite
  with no UIKit; the existing portability gate keeps compiling the kit for
  the device triple. Beyond D-pre's retention bound, the checkpoint work
  requires no new TerminalCore API; if one turns out to be missing, that is
  a plan deviation to surface, not to absorb quietly.
- **PO6 (measurement).** Before any save-cadence or size/time threshold is
  chosen, measure checkpoint synthesis duration and payload size at a
  representative history and at a saturated scrollback budget, per
  agent-docs/measurement-discipline.md, and record the numbers. This plan
  freezes no numeric threshold.

Tests follow TDD: each obligation's failing test lands before the change it
proves.

## Non-goals

- Multi-pane checkpoint retention: one checkpoint, for the last-subscribed
  pane; returning to another pane costs a fresh sync (the named pane-switch
  cost, owned by research/35 T20/T22).
- Automatic reconnect policy beyond foreground-return and manual retry
  (research/35 T9).
- Any wire, protocol, CLI, or Mac-side change, including the Mac's own
  recovery store.
- Preserving the browsing viewport offset or transient mouse-interaction
  state across process death (see AR1).

## Accepted risks

- **AR1.** Restore presents the following viewport with fresh interaction
  state, exactly like a server sync replacement -- today's gap-repair
  behavior. The old suffix replay happened to preserve a browsing offset and
  in-progress gesture context; both are dropped for uniform sync semantics,
  and I2 scopes continuation equivalence accordingly.
- **AR2.** Checkpoint synthesis walks the full retained state at capture
  time. PO6 measures it before a cadence is chosen; if saturated-budget cost
  is too high for frequent capture, the cadence drops without touching
  correctness (I4's cadence independence).
- **AR3.** A checkpoint written by an older app version is discarded, costing
  one fresh sync. No migration is written for a private single-user format.

## Rejected ideas

- **RI1.** Trimming or capping the event suffix, or periodically reconnecting
  to force a server sync: policy bounds on a structurally unbounded design,
  with growth still possible below the trigger and a second recovery path to
  maintain.
- **RI2.** A structured Codable dump of `Terminal`: D5 already decided state
  transfers as terminal bytes; a second format doubles the exactness surface
  and its equivalence-test burden for no representational gain, and pushes
  serialization concerns into the pure engine.
- **RI3.** A server-owned checkpoint the phone refetches on relaunch: cannot
  show a terminal before a network round trip, and couples process-death
  recovery to reachability.
- **RI4.** Keeping the checkpoint blob in UserDefaults: the payload is
  scrollback-budget class, the defaults plist is loaded wholesale at launch,
  and it offers no atomic-replace contract for I3.

## Deliverables

- Engine (D-pre): the grapheme-cluster retention bound in TerminalCore with
  PO7's tests, and the chosen bound recorded in the engine design register.
- Kit: the checkpoint (state bytes plus cursor plus pane identity plus format
  version plus integrity check), replica restore from it, the atomic
  single-checkpoint store, and the suffix machinery's deletion, with PO1-PO4
  tests.
- App: shell wiring for capture triggers and restore-before-continuation;
  removal of the UserDefaults blob path.
- Docs: research/35 ledger note recording that client-side continuation now
  reuses D5's bytes-as-state representation synthesized on the client. No
  CLI surface changes, so `integrations/danterm/SKILL.md` is untouched.

## Implementation discretion

- Checkpoint capture cadence and coalescing, decided after PO6's
  measurements.
- On-disk encoding and file layout of the checkpoint, within I1's size factor
  and I3's atomic-replace requirement.
- Names of the new kit types and the store's directory placement.

## Commit progress

- [x] 1. Bound terminal grapheme retention and record the compatibility decision
- [x] 2. Replace replica event archives with bounded checkpoints and wire their lifecycle

## Implementation notes

- The engine retains at most 256 UTF-8 bytes per grapheme. Temporary executable probes
  built from the pinned references retained all 4,096 injected marks in Alacritty and
  stopped at six code points in libvterm; kitty's pinned source stops at 24 to prevent
  denial of service. The byte limit preserves at least 64 maximum-width scalars or 127
  common two-byte combining marks while bounding serialized size across scalar widths.
- `ClusterContext` tracks the retained byte count. A continuing stream past the limit
  therefore drops each later scalar in O(1) time instead of rescanning the retained cell.
- PO6 measured three debug-build checkpoint syntheses per case on 2026-08-15. A 120x40
  replica with 2,000 ordinary shell-output lines took 196.5-199.3 ms and encoded to
  158,895 bytes. A 1,024x2 replica past the 16 MiB scrollback input budget took
  2.632-2.638 s and encoded to 1,987,152 bytes. Every sample produced a payload; no save
  cadence or performance threshold was frozen from these measurements.
- The original kit/app split could not leave a valid intermediate commit. Removing the
  archive API forces its UIKit consumer either to stop saving continuation state or to
  synthesize a saturated checkpoint on every stream record. The unchecked remainder was
  therefore re-sliced into one checkpoint-and-lifecycle commit, with the research note.

## Follow Up

- Investigate the parallel-gate-only DanTermMobileKit failures at
  `scripts/run-test-suite.sh:28`. The exact package step and the serial 91-step gate
  passed, but the parallel `just test` run produced nine replica assertion failures.
