# Milestone 6 slice 9: bounded OSC 52 clipboard writes

## Context

[plan-terminal-engine/08-input-interaction.md](../../plan-terminal-engine/08-input-interaction.md):70-71
fixes the clipboard policy: "OSC 52 writes are allowed up to 1 MiB of decoded
clipboard content. OSC 52 reads are denied. This policy applies equally to
local, tmux, and remote applications." Standing invariant (:91): "Remote
output cannot read the system clipboard through OSC 52." Proof obligation
(:115-116): "OSC 52 accepts bounded writes, rejects oversized writes, and
never returns clipboard contents."
[plan-terminal-engine/10-protocols-shell-integration.md](../../plan-terminal-engine/10-protocols-shell-integration.md):37
lists "bounded OSC 52 clipboard writes with reads denied" as recognized
protocol behavior; :61-62 bounds one pending OSC/DCS/APC/PM/SOS string at
2 MiB of encoded input with OSC 52's additional 1 MiB decoded-content limit;
:77-80 requires that an over-limit sequence "applies none of that sequence,
consumes through normal termination or cancellation without retaining the
discarded payload, and resumes parsing later valid input"; :71-75 bounds
semantic-event queues by count and bytes with replaceable values coalescing
to newest.
[plan-terminal-engine/04-terminal-core.md](../../plan-terminal-engine/04-terminal-core.md):13
makes the core produce "ordered output bytes, damage, and semantic effects"
with no IO; malformed sequences must not poison later input.
[plan-terminal-engine/03-engine-architecture.md](../../plan-terminal-engine/03-engine-architecture.md)
keeps effects as ordered values interpreted at the boundary by the single
serialized pane owner, and :44 permits a direct system operation with no
meaningful policy to skip an artificial abstraction.
[plan-terminal-engine/11-configuration-themes.md](../../plan-terminal-engine/11-configuration-themes.md):26
fixes the OSC 52 policy with no config knob;
[plan-terminal-engine/15-open-questions.md](../../plan-terminal-engine/15-open-questions.md):33
explicitly defers any read-permission UX.
[docs/research/1-external-tests.md](../../docs/research/1-external-tests.md):156-157
assigns "the write-only portion of `40state_selection` for bounded OSC 52
clipboard writes, plus DanTerm-native denial tests for reads" to Milestone 6;
:280-281 pre-declares the reads-denied deviation; :254-256 leaves the
remaining `40state_selection` expectations to Milestone 7. Roadmap dependency
constraint (14-roadmap.md:303-304): security policies for clipboard and
terminal string limits are part of their first supported behavior -- the
bounds ship with this slice, not later.

Slice-map note: this is the OSC 52 slice that slice 7
([plans/impl/2026-07-21-0730-mouse-reporting-selection-copy.md](../impl/2026-07-21-0730-mouse-reporting-selection-copy.md))
deferred in its non-goals. OSC 8 hyperlinks, automatic URL detection, hover,
and Cmd-click form a distinct future slice with different state and AppKit
concerns; they are out.

### Verified premises (against the working tree)

- `EscapeAbsorber` (lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift)
  discards all OSC payload bytes: the `.oscString` state (:275-281) only
  checks BEL; ESC at the top-level switch (:79) clears collection into
  `.escape`, so ESC-backslash termination currently works only because there
  is no payload to lose; C1 ST 0x9C (:75-78) grounds silently from every
  state; C1 executes 0x80-0x8F/0x91-0x97/0x99/0x9A (:71-74) cancel and
  execute mid-string; CAN/SUB (:67-70) cancel; bytes 0xA0-0xFF inside OSC
  fall through to silent absorption. Existing caps use a
  silent-drop-past-cap style (parameterCapacity 24, intermediateCapacity 4).
- `TerminalInputStream.feed` (TerminalInputStream.swift:18-39) routes
  non-ground bytes raw to the absorber -- OSC payload bytes are never UTF-8
  decoded -- and `TerminalStreamAction` has
  print/execute/escape/escapeSequence/csi only.
- `Terminal` is a pure `Equatable, Sendable` value (Terminal.swift:34) with
  no OSC dispatch anywhere; the two existing host-facing channels are
  accumulate-and-drain: `drainReplyBytes` (:343-347) and `drainDamage`
  (:350-354). TerminalCore has zero imports, and
  `scripts/core-purity-lint.sh` runs it under `--forbid-imports` (rejects
  every import including Foundation) -- base64 decoding and UTF-8 validation
  must be stdlib-only, hand-rolled.
- `TerminalPTYHost` (lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift):
  `drainedFrameState()` (:315-318) is the only damage-drain site, reached by
  `frameState()` and `fencedFrameState()`; `fencedSnapshot()` is
  non-draining; `applyOutput` (:765-785) drains replies back to the child
  and signals updates only on `terminal != previousTerminal` (:775). That
  whole-value inequality currently approximates consumer-visible work, but
  bounded OSC accumulation makes it too broad: every retained payload chunk
  changes the terminal even though there is no damage or completed effect.
- `TerminalPaneSessionController`
  (lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift):
  every frame-state read funnels through `consume(frameState:...)` (:332-373)
  -- the consume loop, `synchronizeState`, `readSelectedTextSynchronizing`,
  and init -- and presentation gating (visibility, DEC 2026, plan-equality
  dedupe) sits strictly after the cache updates inside `planIfNeeded`
  (:422-438). `planIfNeeded` currently keys publication from whole-terminal
  inequality without requiring accumulated damage, so synchronous fences can
  bypass the host's update predicate. A pre-gating effect callback is
  structurally ungateable; `tearDown` nils callbacks (:318-321).
- App boundary: `app/SwiftTerminalSessionView.swift` wires controller
  callbacks in init (:72-84) and owns an injectable
  `selectionPasteboard = NSPasteboard.general` (:31) used by
  `copySelection()` (:356-360). The Ghostty backend writes the pasteboard
  directly at its callback boundary (app/GhosttyApp.swift:245-262) with no
  Elm-model involvement -- the precedent this slice follows.
- Fixtures: the runner (lib/TerminalCore/Tests/TerminalCoreTests/TerminalFixtureTests.swift)
  replays every neutral fixture under authored/bytewise/split chunkings and
  asserts identical final `Terminal` values; `FixtureExpectation` (:635-649)
  has no clipboard field; the manifest pins libvterm commit
  `934bc2fbf21800ac3458a499df8820ca5fb45fd3`, exactly 35 source files, and
  an exact `recordedDeviations` set; the test title and comment spell the
  file count in words (:37-40). `references/libvterm/t/40state_selection.test`
  has 16 case headings: write cases with all three base64 padding lengths,
  chunk-split and empty-chunk cases asserting libvterm's streaming partial
  `selection-set` fragments, an empty-payload clear, invalid data (libvterm
  clears on invalid base64), a `?` query expecting a `selection-query`
  response, and five SELECTION send (read-reply) cases.
  `NeutralTerminalRecording.replay`
  (lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift:494)
  drains replies per feed -- the established drain-normalization site for
  keeping captured sessions whole-value replay-equal.
- Size arithmetic: 1 MiB decoded is 1,398,104 encoded base64 bytes plus the
  `52;c;` prefix -- comfortably under the 2 MiB encoded cap, so the absorber
  cap never rejects a policy-valid write, and a 1 MiB + 1 decoded payload
  still terminates normally for policy-layer rejection; the two bounds stay
  independently testable.
- Pre-existing breakage: `tests-ui/SwiftTerminalSessionViewTestShim.swift`
  was not updated by slice 8 commit `9cf0bfc` -- it still declares only
  `onPlan` (:151) and lacks `TerminalPaneFrame`/`TerminalDamage`, which the
  compiled-in real view now requires (`controller.onFrame`,
  SwiftTerminalSessionView.swift:72). `just test-ui` cannot build at HEAD.
  This slice repairs the shim as a prerequisite of its AppKit work; the
  breakage is slice 8 fallout, not this slice's.

User-settled toggles: read queries are denied silently (no reply bytes; the
denial site stays a single seam for the deferred permission UX); any valid
Pc target -- empty or drawn from `[cpqs0-7]` -- maps to the one macOS
general-pasteboard write; multiple writes between drains coalesce newest-wins
(at most one pending value retained); the effect channel is a dedicated
pending-clipboard-write value, not a general effect enum (Milestone 7 may
generalize); the pasteboard write happens directly at the session-view
boundary with no new `TerminalSessionEvent` or Elm `Msg`.

## Decision

**Scope:** the escape absorber accumulates bounded OSC payloads and surfaces
them as a new stream event; the core gains its first OSC dispatch, applying
the fixed OSC 52 write policy into a newest-wins pending-clipboard-write
channel with drain semantics; the pane owner drains it into the frame state;
the pane session delivers each drained write through a new callback
unaffected by presentation gating; the AppKit view writes the system
pasteboard through the existing injectable seam; the adapted
`40state_selection` write-only corpus, native denial tests, and boundary
tests pin the behavior; the roadmap gains the Slice 9 entry. Nothing else.

- **D1 -- Bounded OSC accumulation in the absorber.** The absorber retains
  payload bytes for every OSC string in one bounded buffer capped at 2 MiB
  of encoded input. Printable bytes 0x20-0x7E and high bytes 0xA0-0xFF
  accumulate; C0 bytes and DEL are absorbed without accumulating (VT500
  string-state semantics -- this makes base64 payloads LF/CR-tolerant,
  matching xterm). Termination by BEL, by ESC-backslash (via a
  payload-preserving ESC sub-state inside OSC), or by C1 ST dispatches one
  OSC event carrying the raw payload through the input stream to the
  terminal. Cancellation -- CAN, SUB, a C1 execute, or ESC followed by
  anything but backslash -- discards the payload and processes the
  cancelling byte exactly as today. Past the cap the absorber stops
  retaining, remembers overflow, and dispatches nothing at termination:
  apply-none, consume-through, resume with later valid input. DCS/SOS/PM/APC
  keep their existing discard behavior.
- **D2 -- First core OSC dispatch; only selector 52 acts.** The terminal
  parses the leading numeric selector; every other selector is consumed with
  no effect and no state change. OSC 52 is `52;Pc;Pd`. Pc must be empty or
  drawn from `[cpqs0-7]`; anything else is malformed. Every valid Pc maps to
  the single system-pasteboard write. `Pd == "?"` is a read query, denied
  silently: no effect, no reply bytes. Otherwise Pd must strictly
  base64-decode (standard alphabet, correct padding); the decoded content
  must be at most 1 MiB and valid UTF-8. Any violation -- bad Pc, invalid
  base64, oversize, invalid UTF-8, missing fields -- rejects the sequence
  with no effect (a recorded deviation from libvterm's clear-on-invalid).
  An empty Pd decodes to the empty string and is a real write that clears
  the pasteboard. Decoding and validation are stdlib-only; the core stays
  import-free.
- **D3 -- Pending-clipboard-write channel, newest wins.** The terminal
  retains at most one pending clipboard write (the decoded string), set only
  by a fully valid OSC 52 write, replacing any undrained predecessor -- a
  hard retention bound of one value of at most 1 MiB per pane. It
  participates in synthesized `Terminal` equality for whole-value
  chunk-invariance and replay proofs, but equality is not the host wakeup
  contract. The value is consumed by a mutating drain on the reply/damage
  model.
- **D4 -- Consumer-work wakeup and owner drain.** After applying output and
  draining replies, the host requests session consumption only when the
  terminal has consumer-visible pending work: damage or a completed pending
  clipboard write. Partial OSC accumulation alone requests no automatic
  update or frame-state publication; a completed grid-silent write still
  requests a drain. The frame state gains the drained clipboard write;
  `drainedFrameState()` drains it beside damage so both the consume loop and
  the synchronous fences carry it, and values crossing the owner boundary
  hold empty damage/effect accumulators. Non-draining snapshot reads stay
  non-draining.
  `NeutralTerminalRecording.replay` drains the channel beside its per-feed
  reply drain so captured sessions containing OSC 52 replay whole-value
  equal, with at most the damage-style drain normalization in the host and
  session equality suites.
- **D5 -- Ungated session delivery.** The pane session controller gains a
  clipboard-write callback fired inside `consume` before any planning, so
  visibility, DEC 2026 suppression, and plan-equality dedupe can neither
  suppress nor delay delivery. Delivery is exactly-once per drained write,
  in owner order, across both the asynchronous consume loop and synchronous
  fences, and stops at teardown (the callback is nilled with its peers).
  Planning and frame publication require non-empty accumulated damage in
  addition to the existing visibility, DEC 2026, and plan-equality gates;
  synchronous inspection may refresh cached terminal state and deliver an
  effect, but terminal inequality from partial OSC state or its grid-silent
  termination cannot publish a render frame.
- **D6 -- AppKit boundary write.** The session view wires the callback to a
  direct write through the existing injectable pasteboard seam (the
  `copySelection` shape). The empty-string write clears the pasteboard. No
  Elm `Msg`, no `TerminalSessionEvent`, no 1 MiB payloads in the top-level
  model; the Ghostty-era clipboard path is untouched.
- **D7 -- Fixture schema and the adapted selection corpus.** Fixture
  checkpoints gain an expectation for the decoded clipboard writes delivered
  since the previous checkpoint (accumulated like reply bytes; JSON spelling
  is discretion). `t/40state_selection.test` joins the manifest (35 -> 36
  files; count strings updated) as a neutral fixture: single-push write
  cases and the empty-payload clear adopted; the split, empty-chunk, and
  longer-than-buffer streaming cases adapted -- no effect at intermediate
  checkpoints, one completed write at termination -- under a new
  single-complete-write deviation; invalid-data adapted (reject, not clear)
  under its own deviation; the query case adapted (no effect, no reply
  bytes) under the pre-declared reads-denied deviation; the five SELECTION
  send cases out-of-scope (reads denied). Authored fixtures place at most
  one completed write per feed event between checkpoints, which keeps the
  expectation chunk-invariant (I3); upstream's one-push-per-case structure
  already satisfies this.
- **D8 -- UI harness repair and boundary test.** Repair the stale shim
  (slice 8's `onFrame`/`TerminalPaneFrame`/`TerminalDamage`; pre-existing
  breakage) and extend it with the clipboard callback; a UI-harness test
  drives an OSC 52 write through the shim into an isolated named
  `NSPasteboard`, mirroring the slice 7 select-then-copy precedent,
  including the empty-write clear.
- **D9 -- Roadmap.** Add the checked Slice 9 sub-bullet under Milestone 6
  linking the promoted plan. The input/renderer bullet (14-roadmap.md:231-235)
  stays unchecked (links are still missing); the external-families bullet
  (:239-242) is audited at fixture time and expected to stay unchecked
  (other Milestone 6 families still lack dispositions); Milestone 7's
  protocol bullet is untouched. No Milestone 6 gate fully closes this slice.

## Invariants

- **I1 (bounded, poison-free parsing).** At most one pending OSC payload
  exists, retaining at most the 2 MiB encoded cap; an over-cap string
  retains nothing further and applies nothing at termination; every
  cancellation path discards the payload; parsing of later valid input
  always resumes; non-OSC string families retain nothing new.
- **I2 (policy exactness).** A write is applied iff the selector is 52, Pc
  is empty or `[cpqs0-7]`-only, Pd strictly base64-decodes, and the decoded
  content is at most 1 MiB of valid UTF-8; exactly 1 MiB is accepted and
  1 MiB + 1 rejected; a query produces no effect and no reply bytes; a
  rejected or denied sequence leaves every observable -- grid, modes,
  replies, damage, pending write -- identical to never having received it;
  the empty write is a real effect distinct from no effect.
- **I3 (determinism and chunk invariance).** For any chunking of the same
  byte stream, the final `Terminal` value is identical; the delivered-write
  sequence between two checkpoints is identical up to newest-wins folding,
  always ends with the same newest value, and is exactly identical when at
  most one write completes per drain interval.
- **I4 (channel bounds and exactly-once delivery).** Retention is one value
  of at most 1 MiB; consecutive drains yield the value then nothing;
  multiple completed writes between drains deliver only the newest; each
  drained write is delivered exactly once, in owner order, across both the
  asynchronous consume loop and synchronous fences. Incomplete OSC payloads
  cause no host update or frame publication; completion of a grid-silent
  write wakes the consumer but causes no render-frame publication when there
  is no damage.
- **I5 (ungated, teardown-safe delivery).** Hidden panes, DEC 2026
  suppression, and plan-equality dedupe never suppress, delay, or duplicate
  clipboard delivery; within one consume the write is delivered before that
  consume's frame publication; no delivery occurs after teardown.
- **I6 (no read path).** No code path derives reply bytes or any
  child-visible data from pasteboard contents; the core remains IO- and
  import-free; the pasteboard is touched only at the AppKit boundary in
  response to a delivered write.
- **I7 (containment).** Clipboard payloads flow only Terminal -> pane owner
  -> pane session -> view; nothing clipboard-shaped enters the top-level Elm
  model, the `TerminalSession` event vocabulary, or the neutral recording
  event schema (replay recomputes effects from bytes).

## Proof obligations

- **PO1 (I1, I3).** Core parser proofs: all three terminators dispatch the
  same payload; every cancellation path discards it and leaves later input
  parsing normally; C0 bytes inside the payload do not join the base64; an
  over-2 MiB string applies nothing and a following valid write applies
  (resume proof); split-point invariance across every byte boundary,
  including mid-selector, mid-base64, and between ESC and backslash.
- **PO2 (I2).** Policy matrix proofs: the accept/reject boundary at exactly
  1 MiB, base64 and padding validity, Pc validity, missing-field forms,
  non-UTF-8 rejection, silent query denial, empty-payload clear as a
  distinct effect, and inert consumption of other selectors. Rejection
  purity is proven by whole-value equality against a terminal that never
  received the sequence.
- **PO3 (I3, I4).** Channel proofs: newest-wins across writes in one feed;
  drain-then-empty; a completed grid-silent write is pending consumer work,
  while an incomplete OSC payload is not.
- **PO4 (I2, I3; discharges the research-doc `40state_selection` write
  assignment).** The adapted fixture passes under authored, bytewise, and
  split chunkings; manifest coverage passes with 36 files, a disposition
  with rationale for all 16 cases, and the new deviation strings; all
  existing fixtures replay unchanged.
- **PO5 (I4, I6).** Real-host proofs: a child emitting OSC 52 yields a
  fenced frame state carrying the decoded write exactly once; interleaved
  query replies and clipboard writes reach their respective channels without
  cross-talk; feeding one incomplete OSC 52 in multiple chunks emits no
  automatic host update, and synchronously fencing after incomplete chunks
  publishes no frame; grid-silent termination delivers exactly one clipboard
  write and publishes no frame through either automatic consumption or a
  synchronous fence; no input write is ever derived from the pasteboard;
  host and session whole-value replay-equality suites stay green with at most
  drain normalization.
- **PO6 (I5).** Session proofs: the callback fires while hidden, during
  active DEC 2026 suppression, and on a synchronous fence; exactly-once
  across mixed fence and loop consumption; delivered before that consume's
  frame callback; never after teardown.
- **PO7 (I6, I7; discharges 08's OSC 52 proof obligation at the AppKit
  seam).** UI-harness proofs (`just test-ui`, after the shim repair): a
  write delivered through the shim lands on an isolated pasteboard; an
  empty write clears it.
- **PO8 (I6, I7).** The core-purity lint (including `--forbid-imports` on
  TerminalCore) and the existing boundary lints in `just test` stay green.

**Slice exit gate:** `just test` green, `just build` green, `just test-ui`
green (requires the pre-existing shim repair); roadmap Slice 9 sub-bullet
added linking the promoted plan. Live sanity check, non-gating: in a
Swift-engine pane run `printf '\e]52;c;aGVsbG8=\a'` and paste elsewhere;
verify `\e]52;c;?\a` produces no visible reply; verify a multi-MiB garbage
OSC string leaves the pane responsive.

## Non-goals

- OSC 8 hyperlinks, automatic URL detection, hover, and Cmd-click (a
  distinct future slice).
- Any other OSC selector's semantics (title, cwd, notifications, progress
  -- consumed inertly; their slices come later).
- OSC 52 reads, read replies, or permission UX (15-open-questions.md:33).
- A general terminal-effect enum or multi-effect queue (Milestone 7 may
  generalize the single-channel pattern).
- Primary-selection vs clipboard distinction for Pc targets.
- Streaming partial-decode effects (libvterm's shape; recorded deviation).
- C1-tolerant UTF-8 OSC payloads (AR4; the future title/cwd slice's
  problem).
- Config knobs (11-configuration-themes.md:26 fixes the policy).

## Accepted risks

- **AR1.** A write drained into the final in-flight frame state around
  teardown is dropped without reaching the pasteboard; the pane is closing,
  and post-teardown delivery would violate I5.
- **AR2.** Newest-wins can drop an intermediate write between drains; only
  a racing external pasteboard reader could observe the difference, and the
  protocol contract sanctions replaceable-value coalescing.
- **AR3.** Accumulating every OSC string raises owner-side payload storage to
  the 2 MiB encoded cap; an explicit synchronous fence can temporarily retain
  one older bounded COW copy in the session cache (about 4 MiB total encoded
  payload storage), while automatic partial-input updates and render frames
  retain none. This is bounded, inspection-triggered, and gives every future
  OSC slice its payload for free.
- **AR4.** C1 bytes 0x80-0x9F still cancel strings, so future UTF-8 OSC
  payloads containing raw C1-range continuation bytes cannot ride this
  absorber unchanged; base64 is pure ASCII and unaffected.
- **AR5.** Every valid Pc target (including `p`, `q`, `s`, and cut-buffer
  digits) collapses to the one general pasteboard; macOS has no primary
  selection, and the fixed policy makes the collapse deterministic.
- **AR6.** Raw OSC 52 bytes transit the host's existing 64 KiB
  recovery-output buffer like any output; that is byte capture, not
  clipboard retention, and is already bounded.

## Rejected ideas

- **RI1.** A general effect enum now -- one channel with drain semantics is
  the proven damage/reply shape; generalizing before a second effect exists
  invents vocabulary Milestone 7 owns.
- **RI2.** Routing writes through the Elm model or a new
  `TerminalSessionEvent` -- puts 1 MiB payloads in the top-level model
  against 03's containment; the Ghostty backend already writes at the
  callback boundary.
- **RI3.** libvterm's clear-on-invalid -- a rejected sequence must apply
  none of itself (10-protocols :77-80); clearing is an applied effect.
- **RI4.** Streaming per-chunk decode effects (libvterm's `selection-set`
  fragments) -- breaks the deterministic single-effect value, the
  newest-wins bound, and chunk-invariant delivery.
- **RI5.** Accumulating only after matching `52;` -- saves nothing (the cap
  already bounds retention), complicates the state machine, and starves
  every future OSC slice of its payload.
- **RI6.** Excluding the pending write from `Terminal` equality -- slice 8
  RI1 redux: manual `==` drift hazard and loss of the free whole-value
  chunk-invariance and replay proof. Equality remains value semantics, while
  D4's consumer-work predicate independently provides delivery liveness.
- **RI7.** Answering queries with an empty `52;Pc;` reply -- a denial reply
  channel invites capability probing, and some querying clients would treat
  "empty clipboard" as an answer instead of falling back; silence is the
  conservative default and keeps the deferred permission UX open.
- **RI8.** A single-value fixture expectation instead of the delivered-list
  shape -- the list mirrors reply-byte accumulation, and the
  one-write-per-feed authoring constraint restores exact chunk invariance;
  coalescing is pinned in unit tests, not fixtures.

## Implementation discretion

- Base64 decoder shape, whether the decoded-size check precedes decoding
  via encoded-length arithmetic, and the UTF-8 validation mechanism,
  provided the core stays import-free.
- The absorber's OSC-ESC sub-state mechanics and overflow-flag reset
  points, provided PO1's observable behavior holds.
- Names and spellings: the stream action case, the drain method, the
  frame-state field, the callback, the fixture JSON field, and the 1 MiB
  constant; leading-zero selector parsing.
- Empty-write pasteboard mechanics (clear alone vs clear-plus-set of the
  empty string).
