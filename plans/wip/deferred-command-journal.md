# Deferred Command Journal

## Status

Deferred. Do not use this direction to gate terminal-engine replacement.
Revisit it only after the ordered pane event stream has real-pane evidence and
a concrete historical consumer still justifies the added machinery.

## Problem

Latest-value pane facts can say what is happening now, but intentionally forget
completed commands. An agent debugging a pane, a future command timeline, or
command-scoped navigation would otherwise need to scrape terminal text and
guess at structure the engine once knew.

Historical semantics are not a small extension of latest-value state. A useful
journal needs bounded records, content-honest references into mutable terminal
history, independent eviction, structured queries, and a reliable command
admission boundary for launch-and-await. Those mechanisms should be bought
only by a demonstrated consumer after the live model proves the shared event
stream.

## Candidate direction

If activated, retain a bounded pane-owned journal beside terminal selection and
search. The private shell envelope remains its sole command authority; OSC 133,
OSC 7, rendered cells, and process inspection never manufacture records.

Each complete command-start would open one record carrying command text, cwd,
user, and host. Command-end would close it with exit status. A new start or
pane teardown would seal a dangling record without inventing an exit status.
At most one record would be open, always the newest, and a never-reported pane
would remain distinguishable from an integrated pane with no commands.

Records would retain no output text. A record could instead hold a logical
span into primary history, but only if research proves that span is
content-honest: reflow preserves retained text, eviction and destructive
primary-screen mutations truncate or invalidate affected portions, and an old
span never reattaches to later-written content. Scrollback would remain the
only text authority.

Journal count and byte bounds would be independent of the 10 MiB scrollback
budget. Oldest journal records could evict without touching scrollback;
scrollback eviction could reduce span fidelity without deleting a record.
Envelope events remain bounded self-reports from the pane process tree, not
authorization: a writer can forge or disrupt records within that pane.

Structured IPC could list records and read retained output through the logical
projection. Historical queries would be a Swift-engine capability while both
backends coexist; Ghostty panes would report it absent rather than emulate it.

First-release launch-and-await, if it is still wanted, must use owned command
admission. A correlated launch creates a fresh pane whose initial command is
owned by DanTerm before other input can reach it. Existing-pane input remains
uncorrelated and un-awaitable. The launch request and shell report share a
unique correlation id; a missing or wrong echo resolves as an explicit
protocol failure rather than hanging or binding by arrival order or text.

## Activation criteria

Do not promote this candidate into an implementation plan until all of these
are true:

- A named consumer requires history rather than latest-value state or an
  immediate completion effect.
- Real-pane evidence shows the versioned shell event stream is reliable across
  the supported local, remote, tmux, and nested-PTY paths.
- Anchor research demonstrates a bounded representation that remains
  content-honest under reflow, eviction, overwrite, erase, line insertion and
  deletion, clear, reset, and later writes over the same rows.
- Journal-scale anchor maintenance is measured at the intended record bound
  and does not compromise interactive resize or the per-pane resource policy.
- The CLI and IPC consumer contract justifies its retention and query surface.
- Launch-and-await, if included, has a fresh-pane admission contract and an
  explicit terminal result for matching completion, protocol mismatch, and
  teardown.

## Candidate proof obligations

- Authored, bytewise, and split replay produce identical records and current
  pane facts.
- Unmatched and re-entrant command traces yield at most one complete record per
  reported command and no record from marks alone.
- Width and height walks preserve retained span reads; eviction and every
  destructive mutation report truncation rather than later-written text.
- Journal floods evict oldest records within explicit count and byte bounds
  without touching scrollback or preventing later valid records.
- Queries are stable across resize for retained content and use the one
  logical-text projection.
- A fresh-pane correlated launch resolves exactly once with its matching
  completion, explicit protocol failure, or teardown; existing-pane injection
  creates no await.

## Non-goals while deferred

- Adding journal state, spans, queries, or correlation fields to current
  pane-state work.
- Treating the candidate invariants above as replacement gates.
- Persisting journals in recovery checkpoints.
- Parsing command text into argv, classifying applications, or adding
  workspace and VCS context.
- A global cross-pane timeline, analytics, or usage store.
- Styled or annotated output capture.

## Research when activated

- Grow the versioned command-start envelope with cwd, user, and host so each
  historical record receives its location and reporting identity atomically
  from the shell that ran the command.
- Audit how current selection, search, semantic rows, and reflow attachments
  map to thousands of durable span endpoints and how every destructive primary
  mutation reaches that layer.
- Pin journal count and byte budgets from measured memory and resize costs.
- Re-evaluate the first historical consumer and delete launch-and-await if
  structured inspection alone earns the journal.
