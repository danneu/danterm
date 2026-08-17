# iOS client automatic reconnect: signal-first, bounded-clock policy

## Problem and desired outcome

The peer-liveness contract (plans/impl/2026-08-17-1500-remote-peer-liveness-
advertised-silence-bound.md) made peer death punctual: a remote connection
that goes one advertised bound without an arriving byte is declared dead on
both ends. That plan's AR2 accepted the consequence this plan discharges --
every declared death now ends in the user tapping a button, and Mac sleep,
previously undefined, now presents as "Connection lost" at the bound.

Today the client connects on exactly four triggers -- launch, foreground
return, the Go button, and selecting a pane row -- and every failure path
presents a state and stops. There is no retry of any kind.

Desired outcome: a transient interruption heals without a tap and resumes
exactly; a condition retrying cannot change never spins; no state the app
can occupy reads as a hang; retry never competes for the Mac's connection
slots; and the case the phone cannot fix -- a sleeping Mac it cannot wake --
costs a bounded, visible effort and then rests.

Load-bearing premises, from the tree and the research record:

- Reconnect is cheap and exact (research/35/F9, on hardware): one connection
  plus three requests inside a second, with the D5 cursor resuming exactly,
  proven on scrollback depth and viewport digest. The policy question is
  *when* to retry, not what a retry costs.
- The Mac admits 8 remote connections (D4) and a cold start transiently
  opens 2 (F9). A server reclaims a dead peer's slot within the advertised
  liveness bound; a capacity refusal arrives as a typed
  `refusedByMac(.connectionLimit)`.
- The client's failure vocabulary (step-0 plan I7) is total over errors and
  names the remedies; the liveness plan made it total in fact. The shipped
  client declares `peerSilent` at the bound on an established stream and
  `serverUnreachable` when establishment stops progressing.
- The single establishment path already flushes the replica checkpoint
  before each attempt and resumes from the stored cursor; a cursor the
  recorder cannot place takes D5's explicit gap-plus-fresh-sync repair.
  Cursors and checkpoints advance only when the replica applies records,
  never on a connection attempt (step-0 plan I3).
- The phone cannot wake a sleeping Mac, and Mac sleep semantics are
  formally unowned (research/35 README). The app disconnects on
  backgrounding by design, and iOS suspends it there.

## Decision

**A kit-owned pure reconnect policy: signals trigger attempts immediately,
a bounded clock covers what no signal can observe, and the only effect the
policy has is scheduling the existing connect path.**

This is the ideal structure for the problem, kept deliberately: retry adds
no second state-mutation path (it decides only *when* the existing attempt
runs), so it cannot corrupt resume state by construction; slot competition
is answered by pricing the capacity refusal at the server's own reclamation
bound and by never overlapping attempts; hang-shaped UI is answered by
presentation totality; and battery-against-a-closed-lid is answered by
gating on signals and bounding the clock.

- **Placement (per step-0 plan I4).** The policy is a pure state machine in
  `ios/DanTermMobileKit`, driven by injected events -- attempt outcomes,
  clock ticks, network-path status, app lifecycle, user gestures -- and
  emitting decisions (attempt now, wait until, rest) that the UIKit shell
  executes. The shell supplies the timer, the path observation, and the
  lifecycle notifications; it decides nothing.
- **Retry classes, total over typed causes.** Classification reads the
  typed failure cause -- the transport or conversation error together
  with the establishment-versus-established phase -- not the collapsed
  user-facing state, because causes that share a presentation do not
  share a remedy: a dropped stream and a malformed hello both present
  as `connectionLost`, and only the first is worth retrying. Cause to
  class and cause to state are both exhaustive, so a new cause cannot
  ship unclassified in either.
  - *Transient, retried*: interruptions -- a connect failure or timeout,
    peer silence, a closed peer, a read or write failure. Retrying is
    exactly the remedy these name.
  - *Capacity, retried after the bound*: the Mac's connection-limit
    refusal. The advertised liveness bound is the time by which the
    server has provably reclaimed any dead peer's slot -- the phone's
    own ghost included -- and only the refusing server knows today's
    number, so the refusal itself carries the server's current bound (a
    wire addition this plan makes, the same advertise-don't-assume
    principle the liveness contract is built on). The first automatic
    attempt waits at least the carried bound, or the contract's default
    in a refusal that carries none; the client remembers nothing.
    Retrying sooner competes for exactly the resource the refusal
    names.
  - *Manual, never retried automatically*: every cause a retry cannot
    change -- protocol violations (a malformed hello, an oversized
    line, a version mismatch), the remaining Mac refusals, an
    unresolved host, a device setup failure -- plus service outcomes on
    a live connection (`streamEnded`, `requestRefused`) and the user's
    own cancel.
  The classification lives in the policy as a compiler-forced total
  switch, mirroring the tree's method-classification pattern. The state
  enum itself is untouched: it stays the remedy vocabulary, free of
  policy.
- **Signals beat the clock; class and floor gate the signals.** The
  phone has real signals for its own side of the world -- the app
  returning to the foreground, a usable network path appearing -- and no
  signal for the Mac's side (a Mac waking, a slot freeing), so a bounded
  backoff clock covers that, and only that. Triggers obey one
  precedence: a user gesture always starts a prompt attempt and
  restores the full policy, in every class and phase, because the
  gesture is the manual remedy itself. Automatic signals act only on
  outcomes in an automatic class; a manual-class rest waits for a
  gesture. No automatic trigger, signal or clock, starts a capacity
  attempt before its earliest allowed time. While the phone has no
  usable network path the clock is suspended outright: an attempt that
  cannot succeed is not worth an attempt, and the path signal is the
  trigger that matters.
- **The automatic phase is bounded and rests legibly.** After a lost
  connection with a usable path the first attempt is immediate, so the
  common blip heals in about a second (F9's measured cost). Subsequent
  delays grow, the attempt budget is finite, and exhaustion rests in the
  plain terminal failure state with its manual remedy. After give-up a
  gesture restores the full policy; an automatic signal buys one prompt
  attempt whose failure returns to rest without restarting the budget,
  so a flapping path costs one attempt per genuine restoration, never a
  fresh budget. Success rearms the budget only after the connection
  proves stable, so a connect-then-die flap terminates at the budget
  instead of looping forever.
- **Presentation decorates, never replaces.** The failure vocabulary is
  unchanged; recovery is an orthogonal phase presented alongside the causal
  state -- retrying, or waiting for network -- so the user always sees both
  what happened and what the app is doing about it. After give-up the plain
  terminal state remains.

Behavioral scope: the phone's connection lifecycle, plus the one wire
addition it needs -- the connection-limit refusal carries the server's
current liveness bound (Mac-side emission, typed exposure through
`lib/DanTermClient`). No other Mac or contract change, no CLI behavior
change; `integrations/danterm/SKILL.md` is untouched.

## Invariants

- **I1 -- one attempt path, one attempt at a time.** An automatic attempt
  is the same attempt a user gesture starts: same establishment path, same
  cursor resume, same checkpoint handling. At most one attempt is in
  flight, where an attempt is in flight from the moment it starts until
  its outcome -- or its cancellation -- is terminal, a socket still
  opening included; a replacement attempt starts only after that. A
  failed attempt moves no stored resume state.
- **I2 -- total, compile-forced classification of causes.** Every
  terminal failure cause has exactly one retry class and one user-facing
  state; both maps are exhaustive, so a new cause cannot ship
  unclassified in either. Classification reads the typed cause, never
  the collapsed state. The user-facing state vocabulary is unchanged.
- **I3 -- only what retrying can change is retried.** Transient causes
  retry automatically; a capacity refusal's first automatic attempt
  comes no sooner than the bound that refusal carries (the contract's
  default when it carries none); every other cause waits for the user.
- **I4 -- bounded effort, legible rest.** From any triggering failure the
  automatic phase makes finitely many attempts and then rests in the
  terminal failure state. Nothing is scheduled after give-up,
  backgrounding, or user cancel. Only a stable connection or a user
  gesture restores the budget -- an automatic signal never does -- so a
  flapping link or path reaches rest rather than looping.
- **I5 -- signals trigger immediately, within class and floor.** During
  the automatic phase, foreground return and a restored network path
  each trigger a prompt attempt; after give-up each buys one attempt
  without restoring the budget. Neither acts on a manual-class rest, and
  neither starts a capacity attempt before its earliest allowed time. A
  user gesture starts a prompt attempt from any state. While no usable
  path exists the retry clock is suspended and no automatic attempt is
  spent.
- **I6 -- recovery is presented, never a hang.** Every state the policy can
  occupy has a presentation naming the causal failure and, while active,
  the pending recovery. No presented state reads as a hang.
- **I7 -- pure and portable.** The policy is a pure state machine in the
  kit, decided entirely by injected events, tested headlessly in the Mac
  suite; the shell only executes its decisions.

## Proof obligations

- **PO1 (I1).** A scripted episode -- failure, several automatic attempts,
  success -- shows every attempt used the stored cursor, no cursor or
  checkpoint movement across failed attempts, and no overlapping attempt
  when an outcome races a trigger -- including a cancellation issued
  before the attempt has published a cancellable session racing a
  foreground reconnect.
- **PO2 (I2).** A table-driven test over every terminal failure cause
  asserts its retry class and its user-facing state; the construction
  makes an unclassified new cause a compile failure rather than a
  runtime default. Two causes presenting as the same state carry
  different classes: a malformed hello never retries, a dropped stream
  does.
- **PO3 (I3).** Per class: a transient cause schedules an attempt; each
  manual cause schedules nothing however long the clock runs; a capacity
  refusal's first attempt is no earlier than the bound the refusal
  carries -- proven with a nonstandard carried bound and with a refusal
  carrying none (the default applies). The carried bound is proven at
  each boundary it crosses: a server-side test proves the Mac's
  capacity refusal carries its current advertised bound, and a
  `DanTermClient` test proves a serialized refusal carrying a
  nonstandard bound surfaces that same bound in the typed error its
  caller receives.
- **PO4 (I4).** Repeated failure reaches give-up, after which clock ticks
  schedule nothing; backgrounding and cancel drop any pending attempt; a
  connect-then-die flap sequence terminates at the budget; a stable
  connection rearms it; an automatic signal after give-up yields one
  attempt and leaves the budget unrestored.
- **PO5 (I5).** With the path unusable, ticks produce no attempts and the
  phase presents as waiting for network; the path becoming usable
  triggers a prompt attempt, and foreground return does the same; a
  manual-class rest ignores both and answers only a gesture; a gesture
  attempts from any state, the rested state included.
- **PO6 (I6).** Every reachable failure-and-phase pair produces a
  presentation; over a full scripted episode the presented sequence names
  the causal failure throughout and ends, on give-up, at the plain terminal
  state.
- **PO7 (acceptance -- live smoke, manual, on hardware).** Airplane mode on
  and off with the app foregrounded: the connection is declared lost at the
  bound, heals with no tap once the network returns, and resumes exactly
  (scrollback depth and viewport digest via the t9-checkpoint instrument,
  per D5's acceptance rule). Mac asleep: the phone presents bounded visible
  retries and rests in a legible state without user action.

## Non-goals

- Waking the Mac (Wake-on-LAN, push-assisted reconnect). APNs machinery is
  T15's; a Mac-side "I am back" signal would be the true signal for
  Mac-side recovery and belongs there. The clock here stays correct
  without it.
- Reconnecting from the background (background tasks, silent push). The
  app disconnects on backgrounding by design and iOS suspends it; the
  policy runs foregrounded only.
- The readiness-based (kqueue) connection reader -- its own plan, AR1 of
  the liveness plan.
- Focus-report semantics (unowned per research/35).
- The audit descriptor's resume-versus-fresh-join gap (F9 records it as a
  distinct defect).
- Any change to the liveness bound's value or to silence-declaration
  semantics on either end; the only contract change is the capacity
  refusal carrying the bound that already governs it.

## Accepted risks

- **AR1.** A Mac that returns just after give-up is not discovered until
  the next signal or gesture; the app does not poll forever by design. The
  worst case is one tap, and it is the price of not spinning against a
  closed lid.
- **AR2.** `hostNotFound` and `refusedByMac(.identityUnresolved)` are
  classified manual even though each can be transient (a DNS hiccup, a
  tailscaled restart). The cost is one tap; the benefit is never looping
  against a typo or a misconfigured tailnet.
- **AR3.** The flap guard means a genuinely unstable link degrades to
  manual after the budget rather than healing indefinitely. Deliberate:
  endless auto-heal on a flapping link is silent battery drain with no
  user-visible progress.

## Rejected ideas

- **RI1 -- unbounded retry with capped backoff.** Retries against a
  sleeping Mac until the battery dies, and makes "Reconnecting" a
  permanent hang-shaped state -- the exact defect I7 exists to forbid.
- **RI2 -- auto-reconnect inside `lib/DanTermClient`.** Wrong layer: the
  CLI shares that module and must not inherit phone policy, and resume
  needs kit facts (cursor, checkpoint, pane selection). Step-0 I4 already
  places connection lifecycle in the kit.
- **RI3 -- retryability as a property of the state enum.** The state enum
  is the user-remedy vocabulary; retry class is policy. Folding it in
  couples presentation to scheduling and invites the enum to grow
  policy-shaped states.
- **RI4 -- treating the capacity refusal as ordinary transient.** Fast
  retry competes for the exhausted resource; the reclamation bound is
  known, so the delay is derived rather than guessed.
- **RI5 -- a "Reconnecting" state that replaces the failure state.** Hides
  the diagnosis the vocabulary exists to present; the causal state stays
  visible with recovery as a decoration.
- **RI6 -- deriving the capacity floor from a remembered
  previously-advertised bound.** Stale across a server restart, a retuned
  bound, or a hostname that now reaches a different Mac, so it cannot
  prove the current server's reclamation deadline; the refusal states
  the number instead, and the client remembers nothing.

## Implementation discretion

- Schedule constants: per-attempt delays, the attempt budget, and the
  stability window that rearms it -- bounded per I4, exact values free.
- The policy machine's event and decision types and its seam against the
  existing connection model in the kit.
- How the shell observes network-path usability, provided the kit consumes
  it as an injected event.

## Commit progress
- [x] 1. the capacity refusal carries the server's reclamation bound
- [x] 2. a kit-owned pure reconnect policy decides when to attempt
- [ ] 3. the phone's shell executes the reconnect policy's decisions

## Implementation notes

- `closedBeforeHello` is classified transient, not a protocol violation. A peer
  that closed before speaking has said nothing wrong, so it reads as the same
  interruption a `peerClosed` transport failure names. The bounded budget caps
  the cost if a Mac ever closes that way persistently.
- Schedule constants (free per Implementation discretion): delays
  `[0, 2, 5, 15, 30]` seconds and a 60-second stability window. The delay count
  *is* the attempt budget, so one episode's total effort is stated once and
  spans about a minute.
- Stability is judged when a connection ends, not by a second timer: at failure
  time the policy compares how long the connection served against the window.
  The observable rule of I4 is unchanged and the shell owns one timer, not two.
- `MobileRecoveryPhase` ships with the policy because the phase is decided, not
  worded. The wording that decorates the causal state is the shell's, so it
  lands with commit 3.
