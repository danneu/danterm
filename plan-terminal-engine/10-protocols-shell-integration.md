# Protocols and Shell Integration

## Problem

Applications need an accurate capability contract, while DanTerm needs title,
cwd, notification, progress, link, clipboard, and shell lifecycle events. A
custom terminal identity or early shell-protocol redesign would expand the
replacement unnecessarily.

## Decision

The initial child environment advertises:

```text
TERM=xterm-256color
COLORTERM=truecolor
TERM_PROGRAM=DanTerm
TERM_PROGRAM_VERSION=<DanTerm version>
```

`xterm-256color` is the advertised identity, not a promise to clone all of
xterm. A versioned DanTerm capability manifest is normative: it lists the exact
terminfo capabilities and dynamically discoverable protocols required by the
accepted workflows, including every output and key-sequence variant those
workflows exercise. The manifest is checked against the `xterm-256color`
entries shipped by the minimum supported macOS and a pinned current ncurses
source fixture. A fixture difference must be added to the manifest or shown not
to occur in an accepted workflow; a single database snapshot is never treated
as authoritative.

The engine recognizes the protocols needed by existing DanTerm behavior and the
compatibility target, including:

- title changes
- cwd/host reporting through OSC 7
- OSC 8 hyperlinks
- bounded OSC 52 clipboard writes with reads denied
- desktop notifications used by DanTerm integrations
- progress reporting used by DanTerm
- synchronized updates
- legacy xterm and Kitty keyboard negotiation

The initial replacement preserves DanTerm's authenticated title-channel shell
events. The engine reports ordinary title events and the existing pure DanTerm
translator continues recognizing command and remote-session payloads. Redesigning
that private integration is separate future work.

BEL emits DanTerm's existing pane-scoped bell event. The initial engine never
plays an audible bell. Existing alert suppression and admitted-event
notification behavior remain in the DanTerm model; a transient visual bell is
permitted for the focused pane because that pane's normal alert is suppressed
while the app is active.

### Per-pane resource policy

Untrusted terminal output is bounded across components, not only within
scrollback:

- retained scrollback uses the 10 MiB budget in
  [Unicode, grid, and scrollback](05-unicode-grid-scrollback.md)
- one pending OSC, DCS, APC, PM, or SOS string may contain at most 2 MiB of
  encoded input; OSC 52 additionally retains its 1 MiB decoded-content limit
- one retained title, cwd, link target, notification, progress, or private
  shell-event payload is limited to 64 KiB; the 1 MiB aggregate
  terminal-originated metadata budget per pane applies end to end across engine
  retention, semantic-event handoff, DanTerm model retention, and adapter queues
- pending terminal query replies are limited to 64 KiB per pane
- damage is coalesced into bounded active-grid state or a full-redraw marker,
  never retained as an event-by-event queue

Semantic-event queues have both count and byte bounds. Replaceable title, cwd,
and progress values coalesce to their newest complete value; other excess events
are dropped as complete pane-scoped units rather than creating an unbounded
model or adapter backlog. Reaching a downstream limit does not retain a second
unbounded copy or prevent later valid terminal input from being processed.

When a sequence exceeds its limit, the engine applies none of that sequence,
consumes through normal termination or cancellation without retaining the
discarded payload, and resumes parsing later valid input. PTY ingress may apply
backpressure rather than creating an unbounded user-space byte queue.

Inside tmux, the inner terminal identity remains tmux's responsibility; DanTerm
implements the outer capabilities tmux consumes.

## Invariants

- Advertised capabilities are implemented and tested.
- Capability queries never claim unsupported behavior.
- Unrecognized OSC, CSI, and DCS sequences are bounded and ignored safely.
- Terminal-originated title, cwd, notification, progress, clipboard, and shell
  events remain pane-scoped.
- Authentication on existing DanTerm-private shell events remains enforced.
- A remote application receives no broader host authority than the protocol
  policy grants.
- Aggregate parser, metadata, semantic-event, reply, scrollback, model, adapter,
  and damage state and pending work remain within the per-pane resource policy
  under adversarial output.

## Proof obligations

- Every capability in the DanTerm manifest exercises its expected output and
  key sequences against both the supported macOS and current ncurses
  `xterm-256color` fixtures, including every fixture-specific sequence variant
  reached by an accepted workflow.
- tmux runs the required compatibility workflows with correct colors, keys,
  mouse, links, clipboard writes, focus, and synchronized updates.
- Existing DanTerm shell hooks continue driving command and remote-session model
  behavior through the new backend.
- Within the resource policy, notification and progress protocols produce the
  same pane-scoped DanTerm behavior as the current app; overload follows the
  explicit coalescing and drop contract.
- Malformed and oversized string protocols cannot allocate unbounded memory or
  escape pane scope.
- Combined scrollback, control-string, title/cwd/link, query-reply, semantic
  event, model-retention, adapter-queue, and damage pressure stays within every
  individual and aggregate bound and recovers to later valid input. Repeated
  near-limit notifications and progress events against a stalled consumer prove
  the full engine-to-product boundary rather than only parser storage.
- BEL produces the existing pane alert behavior without audio; focused-pane
  visual feedback, if present, remains transient and pane-scoped.

## Rejected ideas

- Initial `TERM=danterm`: remote hosts would need a custom terminfo entry before
  ordinary applications could rely on it.
- Ghostty terminal identity or protocol compatibility as a goal.
- Redesigning DanTerm's private shell-event channel in the terminal replacement
  critical path.

## Implementation discretion

- Additional harmless protocols may be supported when required by the accepted
  application matrix.
- The eventual replacement for DanTerm's private title-channel events.
