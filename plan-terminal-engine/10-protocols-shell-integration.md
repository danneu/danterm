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
xterm. DanTerm's documented capability contract
([`docs/terminal-capabilities.md`](../docs/terminal-capabilities.md)) is
normative: it lists the exact terminfo capabilities and dynamically
discoverable protocols required by the accepted workflows, including every
output and key-sequence variant those workflows exercise. The contract is
checked against the `xterm-256color` entries shipped by the minimum supported
macOS and a pinned current ncurses source. A difference must be added to the
contract or shown not to occur in an accepted workflow; a single database
snapshot is never treated as authoritative.

The engine recognizes the protocols needed by existing DanTerm behavior and the
compatibility target, including:

- title changes
- cwd/host reporting through OSC 7
- OSC 8 hyperlinks
- bounded OSC 52 clipboard writes with reads denied
- desktop notifications used by DanTerm integrations
- progress reporting used by DanTerm
- OSC 133 semantic prompt tracking and shell redraw on primary-screen resize
- synchronized updates
- legacy xterm and Kitty keyboard negotiation

[`docs/terminal-capabilities.md`](../docs/terminal-capabilities.md) is the
public contract. It records the two pinned terminfo baselines, the limited set
of claimed capabilities and their variants, supported and denied protocol
families, child-environment ownership, and numeric resource limits.
Incompatible contract changes require a new versioned document section or, if
a machine-readable artifact is ever needed again, a new versioned artifact
(v2+) -- not a revival of the retired v1 JSON manifest this document
superseded.

XTVERSION accepts `CSI > q` and `CSI > 0 q` and replies
`DCS >|DanTerm <version> ST`, using the same injected bundle version exported as
`TERM_PROGRAM_VERSION`. DA2, DECRQSS, XTGETTCAP, and 8-bit replies remain
unsupported.

The accepted notification and progress grammar is deliberately narrow:

- `OSC 9;<body>` emits a notification with an empty title unless the first
  field is the canonical selector `1` through `12`.
- `OSC 777;notify;<title>;<body>` emits a notification and retains later
  semicolons in the body.
- `OSC 9;4;0`, `OSC 9;4;1;<0...100>`, `OSC 9;4;2[;<0...100>]`,
  `OSC 9;4;3`, and `OSC 9;4;4[;<0...100>]` respectively remove, set,
  mark error, mark indeterminate, or pause progress.

Reserved selectors are ignored, including malformed selector-4 forms. Numeric
bodies outside exact selectors `1` through `12` remain notification text.
Unknown notification variants and Kitty OSC 99 are ignored.

DanTerm shell integrations use a private, versioned OSC 1337 envelope carrying
typed command-start, command-end, remote-start, and remote-host events:
`OSC 1337;DanTermShell=1;<event>[;<base64-arg>...] ST`. Command and host text
uses canonical padded base64. The engine validates exact field counts and
bounds the envelope before admitting a semantic event; the PTY/session adapter
binds accepted events to the owning pane. Shell events never pass through title
handling.

Canonical opt-in zsh, Bash, and fish integrations ship in the app bundle. They
emit locally when `DANTERM` is present, preserve existing prompt hooks, report
local cwd with OSC 7, and have ssh/mosh wrappers forward `LC_DANTERM=1` through
`SendEnv`. A shell with `LC_DANTERM` present and `DANTERM` absent reports its
remote identity and suppresses OSC 7 cwd events. Markers remain available to
nested remote shells.

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
- one retained title, cwd, link target, complete notification title-plus-body,
  progress, or typed shell-event payload is limited to 64 KiB; each layer bounds
  its own retention independently rather than summing to one aggregate budget --
  the engine caps its own retention at 256 KiB, and the model caps every
  terminal-originated field at 64 KiB per value plus at most 100 alerts, so
  model metadata scales with live pane count rather than a fixed byte bound
- pending terminal query replies are limited to 64 KiB per pane
- damage is coalesced into bounded active-grid state or a full-redraw marker,
  never retained as an event-by-event queue

Semantic-event queues have both count and byte bounds. Replaceable title, cwd,
and progress values coalesce to their newest complete value. Bell, shell, and
notification events share a 100-event discrete queue. Other excess events are
dropped as complete pane-scoped units rather than creating an unbounded model
or adapter backlog. Query replies are also admitted or dropped as complete
units. Reaching a downstream limit does not retain a second unbounded copy or
prevent later valid terminal input from being processed.

### UTF-8 control-string parsing

In UTF-8 input mode, OSC, DCS, APC, PM, and SOS payloads own every encoded byte
from `0x80` through `0x9f`; raw C1 values never transition or terminate an
active string. OSC terminates on BEL or 7-bit ST (`ESC \`). The other four
families terminate only on 7-bit ST. CAN and SUB cancel every control string.
An ESC followed by any byte other than `\` cancels the string without OSC
dispatch and restarts normal escape recognition from that ESC.

OSC retains each non-C0, non-DEL payload byte up to its encoded-input limit.
Semantic consumers then validate their own fields atomically: malformed OSC 8
URI bytes and malformed decoded OSC 52 text apply nothing, while malformed OSC
8 parameter bytes may discard the optional ID without invalidating a valid URI.
Raw C1 bytes in ground remain malformed UTF-8. DanTerm does not support 8-bit
ST, raw C1 introducers, or S8C1T mode.

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
- Authentication on DanTerm-private shell events remains enforced.
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
- Bundled DanTerm shell hooks drive command and remote-session model behavior
  through the native backend without encoding private directives as titles.
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
- Encoding private shell directives as terminal titles; it couples application
  title behavior to authenticated model events and risks visible title pollution.

## Implementation discretion

- Additional harmless protocols may be supported when required by the accepted
  application matrix.
- Compatible additions to the private envelope require a new version; unknown
  versions and events remain ignored.
