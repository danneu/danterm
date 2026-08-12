# Decisions -- iOS remote client

Auditable decision log for doc 35. D2 through D7 are reserved as gates by the
task ledger in [README.md](README.md) and remain open.

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
