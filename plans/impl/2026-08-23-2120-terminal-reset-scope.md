# Refactor terminal reset scope

## Summary

Replace the shared, ambiguous reset funnel with explicit soft-reset and
hard-reset policy over terminal-global and screen-scoped state. The refactor
closes BUG-02, BUG-31, PARSE-5, and its duplicate BUG-32 as one coherent
correction.

No public API changes.

## Decision

- Define one common reset operation for terminal-global state reset by both
  DECSTR and RIS: scroll region, terminal modes, charsets, and current style.
- Group the saved cursor and Kitty keyboard stack in one nested control value
  owned by `ScreenState`. A full screen-control reset assigns one complete
  default value rather than enumerating its fields.
- Apply screen-control reset with the protocol's asymmetric screen scope,
  without creating a missing alternate or copying row storage:
  - DECSTR defaults the live screen's complete control value. It clears the
    offscreen screen's Kitty keyboard stack without changing that screen's
    saved cursor.
  - RIS defaults every resident screen's complete control value through an
    exhaustive `ScreenOwnership` traversal.
- A saved cursor reset by either operation returns to its complete initial
  state: home position, default style, no pending wrap, origin off, visible
  steady block cursor, and default charset state.
- Keep behavior unique to each reset outside the common operation:
  - DECSTR keeps the active screen, live cursor position, screen contents,
    history, custom tab stops, REP memory, and projection-derived inspection
    state: selection, search, viewport position, and row-numbered anchors. It
    clears pending motion and the hyperlink hover and arm slots, but performs
    no projection invalidation or row renumbering.
  - RIS selects primary, restores default tab stops, homes the live cursor,
    clears pending motion and REP memory, and erases the primary viewport under
    the existing history-seam rules.
- Preserve the current `ScreenOwnership` representation. The reset traversal
  must be exhaustive over both cases so correctness does not depend on caller
  ordering.
- Update the construction audit after the implementation lands: close BUG-02,
  BUG-31, PARSE-5, and BUG-32 together. Record that
  `alternateCursorProjectionOverScrollback` contains no DECSTR and required no
  change despite BUG-02 naming it as a pin. Do not rewrite the historical
  2026-07-18 implementation plan.

## Invariants

- I1: DECSTR never changes which screen is active.
- I2: DECSTR preserves custom tab stops; RIS restores every-8 defaults.
- I3: DECSTR resets only the live screen's saved-cursor slot. RIS resets every
  resident slot, including an offscreen slot.
- I4: DECRC cannot restore pre-reset position, rendition, origin mode, pending
  wrap, cursor presentation, or charset state from a slot that its reset
  operation covers.
- I5: Resetting screen-scoped control state never creates an alternate screen
  or duplicates screen row storage. The ownership traversal enforces this by
  construction; it has no separate behavioral proof.
- I6: Existing DECSTR and RIS behavior outside the corrected scope remains
  unchanged.
- I7: State synchronization continues to reproduce the live screen, plus the
  retained primary and its saved slot when the alternate is live.

## Test plan

Write failing behavioral tests first.

- Prove the full saved-cursor payload resets through public behavior: DECRC
  restores home, default style, origin off, no pending wrap, visible steady
  block presentation, and ASCII charset behavior after both DECSTR and RIS.
- Exercise both ownership cases with distinct primary and alternate saves:
  - DECSTR resets the live slot only. When the alternate is live under 1049,
    DECSTR leaves it active, and 1049 exit restores the retained primary's
    pre-entry saved cursor rather than homing it. When primary is live with a
    retained alternate, re-entering and restoring that alternate after DECSTR
    likewise returns its pre-reset saved cursor.
  - RIS resets an offscreen alternate slot: save there, return to primary,
    reset, re-enter the alternate, and restore its slot to defaults.
- Prove DECSTR clears both Kitty keyboard stacks while leaving the alternate
  live: query the live alternate after reset, then exit 1049 before querying
  the retained primary.
- Prove reset-specific behavior:
  - DECSTR preserves custom tab stops, contents, history, live cursor position,
    and REP memory.
  - RIS selects primary, restores default tab stops, homes and clears the
    viewport, and preserves the established scrollback contract.
- Invert every assertion that pins a corrected defect:
  `resetsReselectPrimary`'s DECSTR case, `alternateScreenStateTransitions`'s
  soft-reset case, `alternateTransitionMatrix`'s `softAlternate` case,
  `softResetMatrix`'s tab probe, both reset matrices' saved-slot probes, and
  `TerminalPresentationModeTests.resetMatrix`'s post-DECRC appearance.
- Keep any existing projection-derived inspection state across DECSTR:
  selection, search, viewport position, and row-numbered anchors. Continue to
  clear hyperlink hover and arm slots, and keep the hyperlink-interaction reset
  coverage green.
- Move the alternate-screen DECSTR arm from
  `leavingTheAlternateScreenStopsTheDrag` into the drag-preservation cases:
  because DECSTR no longer replaces or renumbers the screen, the held drag
  continues.
- Keep the remaining saved-cursor alias, alternate-screen,
  cursor-presentation, charset, state-synchronization, and chunk-invariance
  assertions green.
- During TDD, run the targeted TerminalCore reset, saved-cursor,
  alternate-screen, charset, presentation, interaction-policy,
  hyperlink-interaction, and synchronization suites plus `just lint`. Run
  `just test` before commit.

## Dependencies and delivery

- PARSE-2 and PARSE-3 are complete; implement against `ScreenOwnership` and the
  exhaustive mode catalog now in the tree.
- Land this before PARSE-6 moves the saved-cursor synchronization encoder.
- Treat concurrent BUG-02 or BUG-31 work as the same change, not as independent
  patches. Both directly overlap reset policy and tests.
- The chosen contract intentionally supersedes the old saved-slot-survival
  decision only for slots covered by each reset. On DECSTR, xterm resets only
  the active slot and homes its saved position; VTE overwrites both slots with
  each screen's live position and reset defaults; kitty invalidates both.
  DanTerm follows xterm's live-screen scope and home result. RIS resets every
  resident slot to home/default state.
- Exact helper names and placement inside `Terminal.swift` are implementation
  discretion; the exhaustive ownership boundary and soft-versus-hard policy
  split are not.

## Implementation notes

- The audit's BUG-13 is the RIS half of the stale saved-cursor defect that the
  plan already requires RIS coverage to fix. The audit now closes BUG-13 with
  BUG-02, BUG-31, BUG-32, and PARSE-5 so its status matches the implementation.
