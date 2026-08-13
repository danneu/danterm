# Decisions -- iOS remote client

Auditable decision log for doc 35. D2, D3, D4, D6, and D7 are reserved as gates
by the task ledger in [README.md](README.md) and remain open.

### D1 -- scope and first milestone

- Status: decided 2026-08-12, by user direction.
- Evidence used: the initiating conversation with the user;
  [briefing.md](briefing.md) sec. 8.7 (the phasing sketch and the
  early-vs-late engine question).
- Candidate solutions: (a) agent-supervision-first (push notification, text
  read, quick reply -- no renderer), (b) read-only live viewer first, (c) full
  interactive engine-rendered terminal as milestone 1.
- Selected direction: (c). The first thing the user wants to use daily is a
  pane they can genuinely type into, rendered by the real engine.
- Decision and rationale: milestone 1 is a full interactive, engine-rendered
  terminal pane on the iPhone. This puts the Phase 1 rendering and engine
  spikes on the critical path and provisionally resolves briefing.md's
  early-vs-late engine question toward linking the engine from day one; that
  direction is restated as the D3 gate so Phase 1 evidence can still overturn
  it. Standing scope constraints recorded with the same authority: no todo
  surface on iOS; splits flatten to a pane list and the phone never issues
  `pane.split`; everything else starts as simple as possible. Environment
  facts that weight later decisions: a paid Apple Developer account exists
  (APNs and TestFlight available), and Tailscale runs on the Mac today with
  the phone able to join the tailnet.

### D5 -- durable subscriptions: state sync as tape bytes, and cursor resume

- Status: decided 2026-08-12, from F4.
- Evidence used: [f4-mac-to-mac.md](f4-mac-to-mac.md) in full -- the
  divergence table for a from-now join, the `aftermath` run showing a joiner
  heals its visible screen and never its history, the `evict` run showing an
  evicted resize left a reader replaying 8,940 events into an 80x24 grid for a
  179x66 pane, and the `reconnect` run where 216 skipped events were reported
  as nothing. Plus the existing machinery F4 names:
  `TerminalFlightRecordingCursor`, `cursorSnapshot(from:)`, and the
  origin/cursor fence in `TerminalFlightRecordingCapture`.
- Candidate solutions:
  1. Structured state serialization -- the snapshot is a protocol value
     carrying cells, attributes, and mode flags, loaded through a new engine
     entry point.
  2. State serialized as terminal bytes -- the snapshot is a synthetic byte
     stream that reconstructs the state when fed to a reset terminal of a
     stated geometry, delivered as a record in the tape stream.
  3. No snapshot; raise the recorder's retention bound so backlog replay is a
     reliable recovery path.
- Selected direction: (2), delivered as a `sync` record in the tape stream plus
  a one-shot method returning the same payload, with tape requests able to
  supply a start cursor.
- Decision and rationale:
  - **Payload shape.** The wire is the terminal protocol itself. A reader
    already knows how to feed bytes to a terminal, so sync needs no new
    decoding path and no engine-internal format, and an engine change is not a
    wire change. (1) is exact but couples the wire to engine internals and
    needs a load-state entry point that exists for no other reason; anything
    the byte form cannot express is state no real terminal stream could have
    produced. (3) makes recovery probabilistic in memory rather than
    guaranteed, and F4 showed that failure is silent and geometric.
  - **Broker location: the app runtime, and there is no new broker.** The
    per-pane bounded ring buffer is the flight recorder and the per-subscriber
    cursors are the follow subscriptions; both already exist in the app. A ring
    in the bridge would duplicate them behind a second bound and a second
    sequence space, and would earn its place only if a client's offline window
    could outrun the app-side ring -- which sync removes as a failure mode. So
    T8 does not depend on T5, and the bridge stays a frame proxy.
  - **The retention bound stays a debugging parameter, unchanged at 8 MiB /
    32,768 events.** F4 correctly observed that today the retained tape is a
    snapshot substitute exactly while it is un-evicted, which made the bound a
    session-durability parameter. Sync ends that coupling rather than
    re-tuning it: the design invariant is that no stream's ability to reach
    exact state depends on retention. This is the structurally independent
    answer, so the bound goes back to deciding only how much raw history a
    debugging dump can show.
  - **Sync is injected exactly when the requested position is not
    reconstructible from the records that will be delivered**, and the stream
    continues at the sync's own fence. State and cursor are taken in one fence,
    the way `TerminalFlightRecordingCapture` already pairs origin with cursor
    snapshot, so no event is both reflected in the state and delivered after
    it. Loss is measured against the position the requester asked for, which
    turns F4's silent 216-event reconnect into a stated gap.
  - **Acceptance is asserted on state that does not self-heal**: join a pane
    running a full-screen program, let the program exit, then assert scrollback
    depth and `inputModes`. F4's `aftermath` run showed the visible screen
    heals through a prompt repaint, so a screen-reading test would pass against
    a sync that carried nothing.
- Deferred, with reasons recorded in the plan: the two-engines-answering-a-query
  question, which is an input-direction rule (only the engine owning the PTY
  answers) and belongs with the input surface, not with state transfer; and
  DCS state, OSC 4 palette redefinition, the title stack, and OSC 11 background
  override, which are not gaps in the payload because the engine models none of
  them -- they become sync work only if it starts to, and the round-trip proof
  obligation is what will say so.
- Plan: `plans/wip/2026-08-12-1500-pane-snapshot-and-tape-resume.md`.
