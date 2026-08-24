# Derive Mutable-Suffix Search Ranks in One Scan

## Problem

The current-match scan finds mutable-suffix matches, but nearest-match resolution
derives their content ranks in separate walks. A match and the rank that describes
it therefore have separate producers even though one ordered pass has already
produced both facts.

When the durable search position lies strictly between two surviving matches,
those separate derivations also repeat work over the mutable suffix. Normal
navigation returns before this work, so the cost affects only exceptional
resolution, such as when output overwrites the selected match.

FIND-2 already makes one current-match snapshot serve each readout. That snapshot
is the right owner for the ranks derived during its suffix scan.

## Decision

Derive the mutable suffix's content ranks during the scan that finds its matches.
The snapshot carries enough rank information to compare the durable position with
its two neighboring matches without another projection walk.

Rank retained seed units in the same sequence as newly scanned units. This keeps a
match that crosses the retained/live seam coupled to the rank assigned by the scan
that found it. Closed-prefix matches continue to use the retained store's
width-free rank.

The durable position's rank belongs to the snapshot built for that position. It
dies with the readout and is never reused after search navigation changes the
position.

This is a private TerminalCore change. Public search APIs, persistent search state,
the retained match index, and `NeedleWindow` do not change.

## Invariants

- I1. Nearest-match selection continues to measure content units, independent of
  display width and hard-line padding.
- I2. A position exactly on a current occurrence avoids distance resolution.
- I3. A position strictly between matches selects the nearer occurrence and selects
  the later occurrence when distances are equal.
- I4. Closed-prefix, mutable-suffix, and seam-spanning matches share one content-rank
  coordinate, including the hard boundary at the seam.
- I5. Exceptional resolution does not walk mutable-suffix content after the current
  match snapshot has been built.
- I6. A snapshot's position rank is valid only for the durable position captured by
  that snapshot, and the snapshot does not survive the readout that built it.

## Proof Obligations

- PO1. With no closed records, a live-suffix position between unequal live matches
  selects the nearer match while `Instrument.searchDistanceWork` records exactly
  zero distance work.
- PO2. Overwriting a selected match preserves nearest-survivor selection and the
  later-match tie rule.
- PO3. Cross-seam nearest-match selection works in both directions: a closed
  position can select a nearer mutable-suffix match, and a live position can select
  a nearer closed-prefix match. The coverage includes a seam-spanning match.
- PO4. Width changes do not change nearest-match selection for the same content and
  durable position.
- PO5. Existing closed-history distance-work bounds remain unchanged.
- PO6. Run the targeted TerminalSearch suite and `just lint` during the edit loop,
  then run `just test` before commit.
- PO7. Report paired before/after `just terminal-occupancy-probe --json` results for
  both search workloads as descriptive measurements, not gates.

## Non-goals / Accepted Risks / Rejected Ideas

- N1. Do not combine FIND-3's matcher change or FIND-4's row-content query with this
  work. They overlap the scan and must land separately.
- N2. Do not cache ranks across readouts or add persistent search state.
- AR1. Each transient suffix match gains rank information. The storage follows the
  already-materialized suffix matches and dies with the readout snapshot.
- RI1. Carrying ranks only for neighboring matches is rejected because it still
  repeats the durable-position walk and leaves one scan product to be re-derived.
- RI2. Storing cumulative counts per scanned row is rejected because it retains a
  larger position-independent index when one readout needs the rank of only its
  captured durable position.

## Implementation Discretion

- The private representation of scan-local offsets and snapshot ranks is left to
  implementation, provided the invariants and proof obligations above hold.
- Handling an internally inconsistent snapshot is defensive implementation
  discretion. I4 and I6 require every rank in a valid snapshot to resolve.
