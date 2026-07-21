# Milestone 7 Slice 1: Bounded Title, Cwd, and Bell Events

## Problem and desired outcome

The Swift terminal backend does not yet deliver pane-scoped title, working-directory,
or bell semantics to DanTerm, even though the existing model and runtime already know
how to consume those events. This slice establishes the generic semantic-event path
needed by ordinary shells while proving that the path remains deterministic, bounded,
pane-isolated, and safe during teardown.

The completed slice supports OSC 0/2 title updates, local-host OSC 7 cwd reports, and
BEL pane alerts without audio. It preserves DanTerm's existing valid-event behavior
for chrome, persistence, alert history, focus suppression, notifications, and the
current authenticated shell hooks without allowing their temporary title-channel
encoding to become part of the new engine's semantic architecture.

## Decisions

### D1. Protocol semantics

- OSC 0 and OSC 2 produce the same complete title update.
- An empty title restores the current cwd-derived title when a cwd is known, or an
  empty title otherwise. Later cwd reports continue updating that fallback until a
  non-empty explicit title arrives.
- OSC 7 accepts an empty reset or a valid `file://<host>/<path>` URI whose host is
  local. Local means `localhost` or an exact match for the injected machine hostname;
  if hostname lookup fails, only `localhost` is accepted. A reset clears cwd to `nil`;
  otherwise the decoded path is exposed as the cwd. The host is validation input only.
- A standalone BEL produces a bell event. A BEL that terminates an OSC sequence is
  only the terminator and does not also produce a pane alert.
- Title and cwd values must be valid UTF-8 and at most 64 KiB each. Exactly 64 KiB is
  accepted. Malformed or oversized input has no semantic effect, and later valid
  input must still be recognized.
- A legacy private-shell payload must likewise be valid UTF-8 and at most 64 KiB.
  Oversized or malformed payloads are discarded as complete events.

### D2. One generic pane-scoped delivery path with a temporary legacy shim

TerminalCore exposes an ordered, Sendable semantic-event batch and a destructive
drain operation. The existing PTY owner carries drained events through the Swift
session adapter to DanTerm's title, optional cwd, bell, and private-shell session
events. The runtime continues binding the owning pane identity; child output cannot
select or spoof another pane.

The current shell hooks still encode `__DANTERM_EVT__:<token>:...` through OSC 0.
TerminalCore recognizes that exact legacy prefix before ordinary title handling and
emits a distinct legacy private-shell event. It never applies the payload as a title,
allows it to compete for the coalesced title slot, or exposes it to rendering. The
token-aware DanTerm boundary continues authenticating and translating the raw event
into the existing command and remote-session messages. Invalid or wrong-token legacy
events have no model effect.

This is wire compatibility only. A follow-on retirement slice selects a non-title
shell protocol, migrates the hooks, and deletes the OSC 0 recognition and legacy
translator. The replacement gate does not permit both encodings to remain as
permanent backends.

Hostname resolution is an explicit input at the deterministic core boundary. The
core performs no ambient IO.

### D3. Bounded and coalesced delivery

- Each pane retains only its newest pending title and newest pending cwd.
- Bells and legacy private-shell events share one FIFO of at most 100 discrete
  events. A new discrete event is dropped when that count bound is full.
- TerminalCore retains at most 256 KiB across existing OSC 8 targets,
  hovered/armed interaction copies, and pending semantic events. One drained
  PTY/session handoff has its own 256 KiB cap, and the DanTerm model retains at most
  512 KiB. These layer-local caps total the 1 MiB end-to-end allowance; no layer has
  an independent 1 MiB allowance or introduces another queue. The core may refill
  while the handoff remains retained.
- Cross-kind admission is deterministic. Dead hyperlink targets are reclaimed first;
  live hyperlink/interaction metadata and already admitted pending events retain
  priority. A new complete hyperlink or semantic event is admitted only if it fits
  the remaining core allowance, otherwise it is dropped without partial effect.
  Replacing a coalesced value releases the superseded value before admission.
- Replacing a coalesced value moves it to the ordering position of its newest
  occurrence relative to retained events.
- Semantic-event-only output wakes the consumer but does not require a render frame.
  Hidden-pane and synchronized-output rendering gates do not delay semantic events.

### D4. Existing DanTerm behavior remains authoritative

The runtime maps valid semantic events into the existing model messages, extending
the cwd path to carry `nil` for reset. Existing behavior remains unchanged: title and
cwd updates are pane-scoped and checkpointed; focused active-pane bells are
suppressed; other bells create pane alerts, preserve the global 100-alert cap, and
use the existing notification policy.

DanTerm defensively enforces the 64 KiB per-value limit. Its 512 KiB share includes
the current title, cwd, last command, remote-session strings, and retained alert
strings for that pane. Current pane fields win, then newest same-pane alerts win;
oldest same-pane alerts are evicted first. A cwd reset removes the value rather than
retaining or checkpointing an empty path.

### D5. Exit and teardown have distinct delivery rules

On natural child exit, semantic events parsed before EOF are delivered before the
session-close transition. On explicit pane or session teardown, pending events are
discarded and no later callback may reach the removed pane or shorter-lived UI
objects.

## Invariants

- **I1 - Determinism:** Equivalent byte streams produce equivalent semantic events
  regardless of input chunk boundaries.
- **I2 - Bounded recovery:** Malformed, incomplete, and oversized sequences never
  cause unbounded retention and never prevent later valid sequences from applying.
- **I3 - Pane isolation:** Every event affects only the pane whose PTY produced it;
  protocol data cannot carry a target pane identity.
- **I4 - Delivery bounds:** A stalled consumer can retain at most one pending title,
  one pending cwd, 100 discrete bell/private events, and 1 MiB of terminal-originated
  metadata per pane under fixed 256 KiB core, 256 KiB handoff, and 512 KiB model
  budgets. The core budget includes OSC 8 and pending semantic retention.
- **I5 - Existing semantics:** Once accepted at the boundary, events retain DanTerm's
  current title, cwd, alert, persistence, focus, and notification behavior.
- **I6 - No audio or visual bell:** BEL in this slice is a pane alert input only.
- **I7 - Compatibility is not architecture:** Legacy private payloads remain ordered
  and authenticated but never become terminal titles; the follow-on retirement slice
  removes their OSC 0 wire encoding rather than preserving two permanent shell-event
  protocols.

## Proof obligations

- Deterministic TerminalCore tests cover OSC 0/2, OSC 7 reset and local-host policy,
  percent decoding, title fallback, standalone versus OSC-terminating BEL, arbitrary
  chunking, exact-limit acceptance, over-limit rejection, malformed input, and
  recovery to later valid input. OSC 0/2 coverage includes valid multibyte UTF-8 with
  continuation bytes in the C1 range, both BEL and ST termination, splits within
  scalars, and a following valid event or ordinary text without spurious control or
  bell events. Malformed or truncated scalars recover to a later valid OSC, while a
  standalone 8-bit ST retains its terminal meaning.
- Legacy compatibility tests prove prefixed OSC 0 payloads become private events
  rather than titles, retain their order among ordinary title and bell events, keep
  existing token rejection, and preserve a same-feed command-start/title/command-end
  sequence without title coalescing erasing either private event.
- Core overload tests prove title/cwd coalescing, mixed discrete-event FIFO ordering,
  the shared 100-event count bound, complete-event dropping, and deterministic shared
  admission with near-limit OSC 8 targets, hovered/armed interaction state, and new
  title, cwd, and private-event payloads under a stalled consumer.
- Narrow PTY/session integration tests prove event-only wakeups, delivery independent
  of render suppression, natural-exit ordering, explicit-teardown cancellation, and
  isolation between two panes.
- A combined engine-to-model overload test holds a full 256 KiB handoff while the
  independently capped core refills to 256 KiB with a near-limit mix of OSC 8 and
  semantic state, fills the model's 512 KiB share, and proves the simultaneous
  retained total never exceeds 1 MiB or blocks recovery to later valid input.
- Pure model tests prove defensive value limits, title/cwd set and reset checkpoint
  behavior, nil cwd after checkpoint restore, bell focus suppression, alert and
  notification behavior, the existing global alert cap, and deterministic
  oldest-same-pane eviction under the 512 KiB model share.
- Existing model/runtime tests remain green, and a narrow AppKit-side test verifies
  that post-teardown callbacks cannot reach removed pane UI.
- Adapted neutral terminal fixtures cover the newly supported title semantics. The
  full local test gate passes before the slice is considered complete.

## Non-goals and accepted risks

This slice does not add desktop notification protocols, progress protocols, a new
private shell-event wire format, OSC 133, capability-manifest generation, or full
zsh/bash/fish workflow automation. It only isolates and preserves the existing
authenticated OSC 0 encoding long enough for the follow-on retirement slice to
migrate the hooks and remove it.

OSC 7 does not expose remote host metadata and deliberately rejects host aliases or
FQDN variants that do not exactly match the injected hostname. This favors protection
against remote cwd spoofing over permissive host interpretation.

## Implementation discretion

Internal event storage, URI parsing helpers, and test-file placement are left to the
implementation as long as the decisions, invariants, and proof obligations above are
preserved. The explicitly excluded follow-on work remains open.

## Commit progress

- [x] 1. Add bounded deterministic TerminalCore semantic events
- [x] 2. Deliver semantic events through pane session lifecycle
- [ ] 3. Enforce semantic event bounds in DanTerm model and runtime
