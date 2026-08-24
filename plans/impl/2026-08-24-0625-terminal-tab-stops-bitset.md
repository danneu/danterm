# Replace Terminal Tab Stops with BitSet

## Problem and desired outcome

`Terminal` stores bounded, ordered tab-stop columns in an unordered `Set<Int>`.
HT creates a filtered set to find its successor, CHT and CBT filter and sort,
resize rebuilds a filtered set, and state synchronization sorts before emission.

Replace that storage with `BitCollections.BitSet`. The representation should
make ordered tab navigation native and remove the temporary collections and
sorting without changing terminal behavior or public API.

This is a structural refactor. Current evidence establishes no speedup: the
committed benchmark workloads do not execute HT.

## Decision

- Add the existing swift-collections `BitCollections` product to the
  `TerminalCore` target and store tab stops directly as `BitSet`.
- Use BitSet's ranged ordered views for HT, CHT, and CBT.
- Truncate stops on resize through range intersection, then add default stops
  only for newly introduced columns.
- Iterate BitSet directly when encoding state synchronization.
- Land this before PARSE-6, which otherwise conflicts at the tab-stop emission
  site that PARSE-6 moves into the state-synchronization encoder.

## Invariants

- HT, CHT, and CBT keep their current direction, count normalization, and edge
  clamping.
- HTS and TBC keep their current effects without changing pending wrap or
  grapheme continuation state.
- Width shrink removes out-of-range stops. Later growth does not resurrect them
  and adds defaults only in newly introduced columns.
- DECSTR preserves custom tab stops. RIS restores the every-eight defaults.
- Terminal equality depends on the tab-stop member set, not storage capacity or
  mutation history.
- State synchronization reconstructs the same tab-stop set and produces the
  same subsequent tab movement.
- Default column zero remains stored, while navigation selects stops strictly
  before or after the cursor.

## Proof obligations

- `TerminalTabStopTests` stays green for mutation, navigation, clamping, side
  state, resize, and equality.
- `TerminalResetTests` stays green for DECSTR preservation and RIS restoration.
- `TerminalStateSynchronizationTests` stays green for reconstruction and
  continued HT behavior.
- `TerminalFixtureTests.replayFixtures` stays green for the libvterm tab-stop
  recording across every chunk split.
- Run the targeted `TerminalCore` suites with `just lint` during the loop, then
  run `just test` before commit.

## Non-goals and rejected ideas

- No speedup claim or benchmark acceptance criterion. Do not add or recalibrate
  a benchmark corpus as part of this refactor.
- No handwritten `[UInt64]` bitset, wrapper, or mirrored ordered collection;
  each would recreate storage or synchronization mechanics already supplied by
  BitSet.
- No reset-policy, state-synchronization-format, public-interface, dependency
  version, or prior research-record change.

## Implementation discretion

- Exact local expression shape for selecting the requested member from a
  ranged BitSet view.
