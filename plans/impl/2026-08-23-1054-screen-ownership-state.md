# Make "alternate live without a retained primary" unrepresentable (PARSE-2)

## Context

Audit finding PARSE-2 (`docs/scratch/2026-08-18-construction-audit.md`).
`Terminal` (lib/TerminalCore/Sources/TerminalCore/Terminal.swift) stores the two
screens as `screen` (whichever is live), `inactiveScreen: ScreenState?`, and an
`activeScreen` enum. Three fields carry two facts, so "the alternate screen is
live and no primary screen is retained" is expressible. Nothing upholds the
invariant but the fact that one function writes all three fields together, and
three readers defend against the impossible state by hand: a force unwrap in
`encodeStateSynchronization`, a `preconditionFailure` in `primaryScreenRows`,
and a second `preconditionFailure` in `resize`.

The state is unreachable today, so this is not a latent crash. The value is
deleting three defenses of an invariant the type system should carry, and
retiring an accepted risk the previous refactor recorded on purpose: the plan
behind commit `a8eefabc` accepted the resize trap as "consistent with
`primaryScreenRows`'s existing precondition, and a trap beats garbage". This
change is the follow-up that makes both unnecessary.

`resize` carries a second, separate defect the finding misreads. It installs the
primary in the live slot, does the resize, and swaps it back out, with each half
guarded by its own precondition. The two halves are balanced by hand; nothing
makes an unbalanced install impossible. The finding proposes removing the swap
entirely, which is not achievable -- see Rejected ideas.

Desired outcome: the impossible screen state stops being expressible, the three
hand-written defenses are deleted rather than reworded, and the resize install
becomes one scoped operation that cannot be left unbalanced.

Sequencing: FEED-1's row ring has landed, so its declared conflict with this
finding is resolved and this rebases onto `Deque<GridRow>`. This blocks PARSE-6.

## Decision

Keep the live screen stored as `screen`. Replace `inactiveScreen` and
`activeScreen` with one enum whose cases are "primary is live, carrying the
alternate if one was ever created" and "alternate is live, carrying the
primary". The alternate stays optional because it genuinely may never have
existed; the primary stops being optional because it never can be.

- Reading the primary grid, and encoding it into state synchronization, become
  total functions. The force unwrap and both `preconditionFailure`s are
  deleted, not reworded.
- The screen exchange becomes a switch over the two cases, preserving today's
  semantics exactly: carry the live cursor into the incoming screen, clear its
  pending wrap, mint a blank alternate on first entry.
- `resize` installs the primary in the live slot through one scoped operation
  that restores the previous live screen on the way out, so the pair cannot be
  written unbalanced and the "was the alternate live" fact cannot be lost
  between the halves.
- The three places that must walk every resident cell -- the style collector,
  the hyperlink collector, and the memory census -- reach the offscreen screen
  through one accessor instead of each spelling the walk itself.

## Invariants

- I1: "The alternate screen is live and no primary screen is retained" is not
  representable. No reader defends against it.
- I2: Reading the primary grid is total, from either live side. State
  synchronization taken while the alternate is live still encodes the primary
  beneath it, and the primary-history projections still read the primary.
- I3: Installing the primary in the live slot for the duration of a resize is
  one scoped operation that always restores the previous live screen. An
  unbalanced install is not expressible.
- I4: Screen switch semantics are unchanged: the live cursor is carried into
  the incoming screen with its pending wrap cleared, first entry to the
  alternate mints a blank screen, per-screen saved cursors and kitty keyboard
  stacks stay screen-scoped, and RIS/DECSTR reselect the primary.
- I5: Resize semantics are unchanged: the primary reflows under its own cursor
  and semantic state, the alternate only ever takes the rectangle resize plus
  clamp, and both screens' live and saved cursors are clamped.
- I6: Every place that must account for all resident cells reaches both
  screens; a walk cannot silently cover only the live one.
- I7: A screen exchange and a resize move screen state rather than duplicating
  it. Neither copies row storage that today's code does not already copy.
- I8: Feed and render hot-path cost is unchanged, measured on the final state
  rather than asserted (agent-docs/measurement-discipline.md).

## Proof obligations

- PO1 (I1): compile-time. The evidence is that the two `preconditionFailure`
  sites and the force unwrap have no replacement.
- PO2 (I2, I4, I5): existing suites are the gate, passing unchanged --
  `TerminalAlternateScreenTests`, `TerminalStateSynchronizationTests`,
  `TerminalResizeTests`, `TerminalKittyKeyboardTests`,
  `TerminalSavedCursorTests`, `TerminalResetTests`. `just test`.
- PO3 (I5): written first and green against current code.
  `TerminalAlternateScreenTests.inactivePrimaryResizeEquivalence` compares a
  resize-while-alternate-live run against a resize-before-entry run, but its
  oracle (`primaryContent(of:)`) covers history, scrollback, viewport and wraps
  and omits the live cursor after alternate exit. Extend the oracle so the
  equivalence covers the cursor. This is exactly the path the change edits.
- PO4 (I6): one proof per consumer of the both-screens walk. The style
  collector already has it -- `TerminalStyleTableTests.sweepPreservesVisibleStyles`
  churns styles on the alternate screen until a sweep runs, then asserts the
  offscreen primary's cells keep the styles they still point at. The hyperlink
  collector and the memory census have no equivalent and each need one: a
  reclamation sweep that must keep alive a link held only by the offscreen
  primary, and a census taken while the alternate screen is live asserting both
  resident screens are counted. `TerminalHyperlinkTests.penAcrossStructuralOperations`
  carries a primary link across an alternate round trip but never churns enough
  to trigger a sweep, and `TerminalMemoryCensusTests` never enters the alternate
  screen, so neither gap is covered today.
- PO5 (I8): `just benchmark-confirm baseline=<pre-change revision>` on the
  final state. A regression stops the land.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: PARSE-3 (mode table) and PARSE-6 (encoder and inspection split).
  PARSE-6 is ordered behind this; neither is part of it.
- Non-goal: changing which state is per-screen. `scrollRegion` stays
  terminal-scoped, as the previous refactor already decided.
- AR1: extracting a screen from the enum by pattern match leaves its row
  storage referenced twice, so a naive implementation copies a whole screen's
  rows on every alternate switch and every resize. The exchange must move the
  state out before mutating it; `withHistoryDoor` is the in-repo precedent for
  the swap-into-a-local idiom and its doc comment explains the exclusivity
  reasoning. No test detects a violation, so this rests on review plus PO5.
- AR2: resize cost is not paired-measured. Carried from the previous refactor's
  plan: the documented gate for admitting a paired resize workload is a change
  *expected* to move resize cost, and a representation change with no intended
  cost difference is not that change. I5's behavioral tests cover correctness.
- RI1: fixed `primary`/`alternate` slots with a computed live accessor --
  PARSE-2's own stated cheaper fallback. Rejected, and already rejected once in
  the plan behind `a8eefabc`: a get/set computed property CoW-copies the rows
  array on every hot-path read-modify-write, and `_read`/`_modify` is an
  unofficial idiom absent from this codebase. The live screen stays a stored
  field, which is why this plan's enum carries only the offscreen state.
- RI2: PARSE-2's stated ideal that `resize` can then "address the primary
  directly instead of swapping it in and back out". Rejected: `resizeHeight`
  and `resizeWidth` are roughly 280 lines written against the live slot and
  entangled with history mutation, anchor capture, selection clamping and
  viewport state. Converting them to take the primary as an argument re-opens
  RI1's copy question and changes the most delicate code in the file for no
  behavioral gain. The scoped install (I3) is what the finding was reaching for
  and is where the value in that claim actually sits. Record this correction on
  the finding so it is not re-proposed.

## Implementation discretion

- The enum's name, its case names, and its payload labels.
- The shape of the scoped install -- a closure-taking helper in the style of
  `mutateHistory` / `withHistoryDoor`, or any other shape that makes the
  install/restore pair unbreakable.
- Whether the both-screens accessor vends an optional screen or a walk.
- How the change splits into commits.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- the screen fields
  and `ScreenState`/`ActiveScreen` declarations; `encodeStateSynchronization`;
  `isAlternateScreenActive` and `primaryScreenRows`; `resize`;
  `swapActiveScreen`, `switchAlternateScreen`, `selectPrimaryScreen`;
  `resetControlState`; the style and hyperlink collectors and the memory
  census.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalAlternateScreenTests.swift`
  -- PO3.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalHyperlinkTests.swift` and
  `lib/TerminalCore/Tests/TerminalCoreTests/TerminalMemoryCensusTests.swift`
  -- PO4's two new proofs.
- `docs/scratch/2026-08-18-construction-audit.md` -- mark PARSE-2 done and
  record RI2's correction to its stated ideal.

No public surface changes: the fields are private and `isAlternateScreenActive`
keeps its type.

## Verification

1. PO3's extended oracle passes before and after the change.
2. `just test` (full gate). Targeted during the loop:
   `swift test --package-path lib/TerminalCore --filter "AlternateScreen|Resize|StateSynchronization|KittyKeyboard|SavedCursor|Reset|MemoryCensus|StyleTable|Hyperlink"`,
   plus `just lint`.
3. `just benchmark-confirm baseline=<pre-change revision>` on the final state --
   neutral expected; a regression stops the land.

## Commit progress

- [x] 1. test(terminal): prove offscreen primary accounting and resize cursor behavior
- [ ] 2. refactor(terminal): make screen ownership states unrepresentable

## Implementation notes

- The resize equivalence fixture uses 1049 and no longer writes `ALT` after
  entry. A 1047 exit intentionally carries the alternate cursor into the
  primary, and alternate rectangle resize does not match primary reflow. The
  1049 save/restore path lets the proof compare the resized primary cursor as
  planned without unrelated alternate cursor motion replacing it on exit.
