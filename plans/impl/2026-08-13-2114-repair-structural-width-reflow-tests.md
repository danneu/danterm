# Repair Structural Width-Reflow Tests

## Problem

The structural blank-preserving width-reflow change correctly moves rows across
the history/live seam, but several updated tests no longer prove their original
behavior:

- The logical-line fold suite reads displaced reference rows through the same
  store it is meant to verify, so its width-change oracle is no longer
  independent.
- The Kitty- and WezTerm-adapted cases assert where displaced rows went but no
  longer assert the text and wrap structure those cases exist to preserve.
- The cursor-visibility clamp test removes every trailing blank, so it does not
  prove that resize removes only the blanks required to show the cursor.

The production behavior and the D7 decision are unchanged. This work repairs
only the behavioral evidence for that contract.

## Decision

- Restore the logical-line fold suite's independent oracle. Construct the
  reference terminal directly at the width being verified and keep its entire
  transcript in the live grid. A reference used to verify `LogicalLineStore`
  must never read rows back through retained history.
- Keep a resize-driven reference only for the existing test whose subject is
  the current resize path dropping a background-erase tail. That fixture must
  keep its transcript out of history so it remains independent of the store.
- Keep the new Kitty and WezTerm history/live placement, but assert each case's
  whole displayed stream through one seam-agnostic representation: history
  followed by viewport, with text and wrap state for every row. Assert the
  scrollback count separately so the seam remains an explicit claim without
  fragmenting the upstream evidence into per-side expectations.
- Replace the all-or-nothing cursor-visibility fixture with a partial-clamp
  case. The narrow leg must remove only the shortfall, leave at least one
  trailing blank, and keep the cursor visible. The widen leg must fill exactly
  the lost rows from retained history while restoring the remaining blanks.

## Invariants

- I1. The fold fidelity oracle shares neither retained-history storage nor a
  read-time fold with `LogicalLineStore`.
- I2. Structural displacement changes only a row's side of the history/live
  seam. Its text, styles, cell structure, and wrap boundary remain intact.
- I3. Adapted tests continue to prove the upstream behavior named by their
  intent, with DanTerm's trailing-blank divergence stated explicitly.
- I4. Cursor visibility removes exactly the required number of trailing blanks;
  all remaining blanks survive the width round trip.
- I5. These repairs do not change production code, public API, D7, or the
  chosen compatibility behavior.

## Proof Obligations

- PO1 (I1). The fold-at-new-width comparison uses a terminal created at that
  width and fails if the reference transcript enters scrollback. Compare the
  store's painted walk across the full width and its content walk only through
  the reference content end, so background-erase paint is verified without
  treating it as text. The existing background-erase divergence remains the
  sole test using a resize-driven live-grid reference.
- PO2 (I2, I3). Each Kitty and WezTerm adapted case compares the complete
  history-plus-viewport stream, including row text and wrap state, and asserts
  the scrollback count separately. The expected streams preserve the
  hard-ended `123` row, the soft-wrapped `123` / `  a` / `bcd` / `e` line with
  its two interior spaces, and the soft-wrapped `some long long tex` plus `t`
  line. The existing styled-wide-cell reflow test remains the proof that style
  and synthesized spacer attributes survive displacement across the seam.
- PO3 (I4). A partial-clamp round trip starts with retained history and more
  trailing blanks than cursor visibility must remove. It asserts the exact
  narrow and restored stream layout, seam movement, cursor visibility,
  unchanged logical text, and grid validity.
- PO4 (I5). Run the logical-line fold, Kitty-adapted, WezTerm-adapted, and
  terminal-resize suites, then the full local gate with `just test`.

## Non-goals

- Changing structural blank preservation or restoring the resize-series
  fallback.
- Matching Kitty, WezTerm, or libvterm viewport placement when their behavior
  consumes trailing blanks.
- Changing production or public test-support APIs.

## Implementation Discretion

- Test-only row rendering and fixture helpers may be reused or added as long as
  they preserve explicit spaces, ignore wide tails, and do not weaken oracle
  independence.
