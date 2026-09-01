# Give the confirmation panel's layout a fixed point

## Problem

Quitting with many running commands draws a broken confirmation: the Copy
buttons pile up on top of each other, the list does not scroll, and the panel
sits at a width nothing asked for.

The panel's width is a negotiation with no solution. The column may grow between
a floor and a ceiling; the command list takes its width from that column; and
each command's wrapping label pushes its own intrinsic width back up into the
column, because `ConfirmationCommandItemView` discovers its wrap width by
reading back the width a finished layout pass gave it
(`app/ConfirmationCommandItemView.swift:73-82`) and invalidates itself. Width A
produces a wrapped label that asks for width B, and width B asks for A again.

Evidence, from a standalone AppKit reproducer of the panel built for this
investigation: with 38 commands one item's label was re-measured 350 times at
widths `447, 555, 447, 555, ...` and never settled. `sizeToContent`'s retry loop
(`app/ConfirmationPanel.swift:194-221`) is written to "repeat until the size
settles" and gives up mid-oscillation after four rounds, which is the frame the
screenshot shows. AppKit then keeps re-running constraints until it throws
`NSGenericException` out of the window's update-constraints pass -- an uncaught
exception that takes the process down. The reproducer aborts this way
deterministically at ten commands and above and not at all at three to five,
which is why this shipped.

The command list is the half of the negotiation that oscillates, but it is not
the whole of it. Two more parts of the same knot are load-bearing here:

- The heading and body are wrapping labels with no stated maximum width
  (`app/ConfirmationPanel.swift:79-87`), so their intrinsic width is the whole
  string on one line, and it ties against the column's preferred width at the
  same priority. They do not oscillate today only because nothing closes a loop
  back to them. A long tab name in a heading already stretches the panel.
- The ceiling on the column is a required constraint that cannot hold. The
  column is capped, the button row is pinned to the column, and the row's cancel
  and default buttons resist compression at required priority
  (`app/DialogActionRow.swift:129`), so a button row wider than the cap makes the
  system unsatisfiable. The existing long-title case passes only because AppKit
  breaks the cap for us and logs a conflict. The cap's own comment says the
  alternate truncates instead, and in that case there is no alternate.

The harness cannot see any of it: `tests-ui/ConfirmationPanelTests.swift` only
calls `layoutSubtreeIfNeeded()` and never puts the panel on screen, so the
window pass counter that trips never runs, and an oscillation that is merely
"not finished yet" reads as a laid-out panel.

## Decision

**The panel states its width in Swift; Auto Layout solves only heights.**

The width is computed once per refresh, before anything wraps, and every wrapping
label is told the width it must wrap to. Nothing downstream reports a width back
upward, so there is no negotiation left to fail to converge.

This is what makes the rest of the change provable rather than lucky:

- The read-back override and the retry loop are deleted rather than tuned. Once
  every wrapping label knows its width before the first pass, every intrinsic
  height is right on the first pass, so one layout pass is exact. A loop that
  searches for a fixed point is unnecessary the moment one is guaranteed.
- The width the buttons need is a question the button row answers about itself,
  from its own buttons and spacing. That dependency is acyclic -- a button never
  wraps -- and it is the only reason the width was ever negotiated.
- The cap that keeps the panel on screen is applied as a computed minimum, not
  asserted as a constraint AppKit must break. A bound the solver has to violate
  is not a bound.
- The visible command area is bounded one-directionally, so a clipped height can
  never be pushed back onto the list and squeeze the items into each other.
- The scroller's channel is reserved out of the stated width whether or not one
  is drawn. Reserving is what keeps this acyclic: whether a scroller shows
  depends on content height, which depends on wrap width, so a wrap width that
  depended on the scroller would be a second loop. Forcing overlay scrollers is
  the alternative and a worse one -- AppKit re-applies the system style on a
  preference change, which is why `app/ScrollableTerminalView.swift:106-117`
  carries an observer to fight it. For the same reason the channel is a fixed
  width rather than one derived from the style currently in effect: a width read
  from the ambient style is stale the moment the style changes under an open
  panel, and reading it makes a system preference an input to how text wraps.

Critical files: `app/ConfirmationPanel.swift`,
`app/ConfirmationCommandItemView.swift`, `app/DialogActionRow.swift` for the
width it reports, `app/NoticePanel.swift` for the shared resize, and
`tests-ui/ConfirmationPanelTests.swift` and `tests-ui/NoticePanelTests.swift`.

The single-pass `sizeToContent` this leaves behind is the one `NoticePanel`
already has, and the two panels also duplicate their chrome and their
`center(on:)`. They become one shared dialog-panel surface, so the rule that a
dialog resize holds its top edge is stated once, next to the precondition that
makes one pass enough. The precedent for a stated wrap width is
`app/PreferencesPanel.swift:204,210,356`; the precedent for deriving a scroller's
width up front rather than discovering it in a second pass is
`app/PreferencesPanel.swift:267-281`.

## Invariants

- **I1.** No content of the panel reports a width upward. The width is computed
  before layout, and the button row's own required width is the only content
  input to it.
- **I2.** Every wrapping label in the panel -- heading, body, and each command --
  is told the width it wraps to before layout runs, and that is the width it is
  drawn at. This revises the panel's existing claim that an item wraps to the
  width it is given "not to a constant": it still wraps to the width it is
  given, and that width is now stated rather than discovered.
- **I3.** The panel's layout has a fixed point, reached in one pass: after a
  refresh returns, no further layout is owed and laying out again moves no frame.
- **I4.** The visible command area is the smaller of the list's height and the
  bound that keeps the panel on screen. Past the bound the list scrolls, the
  content keeps its full height, and no two items overlap.
- **I5.** The width a command wraps to does not depend on whether a scroller is
  showing, nor on the system's scroller-style setting, and no wrapped line is
  clipped horizontally.
- **I6.** The panel is never asked to satisfy a width bound it must break. A
  button row too wide for the text column widens the panel, up to what the screen
  allows.
- **I7.** Unchanged from the panel's existing contract: one item per projected
  command in order and in full; each copy writes only its own command, including
  for an item too far down to draw; an empty command list shows no command area;
  a refresh holds the title bar still; Return and Escape answer from anywhere in
  the panel.

## Proof obligations

Discharged in the UI harness, which cannot run a real window display cycle --
see AR1.

- **PO1** (I3): after a refresh with a list long enough to scroll, the panel owes
  no layout and is not ambiguous; laying out again moves no frame, neither the
  panel's nor any item's. Fails today.
- **PO2** (I1, I2): the panel's width is identical across an empty list, a short
  list, a long list, and a single command longer than the panel that cannot be
  broken at a space -- the case most likely to leak an intrinsic width upward,
  where the label must also stay within the width it was given.
- **PO3** (I2, I5): a command's label is as tall as its wrapped text needs at the
  width it is drawn at, and the list is never wider than the area that clips it.
  The width a command is drawn at is unchanged by the two things I5 says cannot
  move it: whether the list is long enough to show a scroller, and which scroller
  style the panel is laid out under.
- **PO4** (I4): past the bound, the visible area stops at the bound while the
  content stays taller, consecutive items keep a positive gap and stay in
  projection order, and the buttons stay inside the panel's content.
- **PO5** (I6): a button row wider than the text column leaves every button
  inside the panel, and reports no unsatisfiable-constraint break.
- **PO6** (I7): the panel's existing cases stay green. The one case whose stated
  rationale is that a visible scroller narrows the real wrap width keeps its
  assertion and gets the rationale I5 replaces it with.
- **PO7**: the notice panel holds its title bar across a refresh that resizes it.
  This is new coverage, written before the shared resize is extracted, because
  the extraction is otherwise unguarded on that side.

## Non-goals

- Changing what the model projects or what a copy writes.
- Changing how `DialogActionRow` sizes or truncates its buttons. The panel asks
  it for a width; the row's internal resistance rules serve every dialog in the
  app and are out of scope.
- Bringing this bug class into `just test`. The UI target needs a WindowServer
  and stays excluded from the gate; `just test-ui` is the gate for this change.
- A CLI surface that raises or reports an open confirmation. The prior plan's
  follow-up gap stays open, and stays the reason no agent can verify this panel
  live.

## Accepted risks

- **AR1.** No test reproduces the uncaught exception itself, because the harness
  never orders the panel front and must not take the keyboard from the user.
  PO1 stands in for it: the exception is thrown only because the layout has no
  fixed point, so proving the fixed point exists removes the cause. The manual
  check in `## Verification` covers the real display cycle.
- **AR2.** Commands wrap in a column narrower than the heading and body above
  them, by a scroller channel that is often empty. The alternative -- forcing
  overlay scrollers and reclaiming the width -- makes the wrap width depend on a
  system setting and on an observer firing before the next draw.
- **AR3.** Replacing the fixed ceiling with a screen-derived one means a very
  wide button row now widens the panel further than it used to. It could not
  honor the old ceiling anyway; it broke it silently. On a display too narrow to
  fit the row, the buttons still overflow, because nothing in the row is
  permitted to give.

## Rejected ideas

- **RI1.** Lowering the command labels' horizontal compression resistance so the
  column's preferred width wins. Verified in the reproducer -- 2 re-measures
  instead of 350 -- but it leaves the width a negotiation that happens to be won
  on priority. The read-back and the retry loop would survive, and the next
  constraint added to this panel could restart the oscillation with nothing in
  the design saying why it must not. Once a wrap width is stated, a label's
  intrinsic width is that width, so there is nothing left to resist with, and the
  priority change becomes dead code that reads like the fix.
- **RI2.** Raising the retry count, or looping until the size settles. There is
  no fixed point to converge on; more rounds only pick a different frame to stop
  at.
- **RI3.** A table view for the command list, or laying the items out by hand.
  Auto Layout was never the problem -- a negotiated width was. Both cost a second
  measurement path, and the table also breaks the per-item ownership of the copy
  action that the item view exists to hold.

## Verification

- Write the harness cases first and watch PO1 fail for the stated reason, then
  change the panel. `just test-ui > .build/ui.log 2>&1`, then grep the log --
  including for an unsatisfiable-constraint break, which PO5 says must not
  appear. `just test` and `just lint` before the commit.
- Manually, in a real display cycle: open many tabs with running commands, quit,
  and confirm the list scrolls under a stationary Cancel/Quit row, that no Copy
  button overlaps another, and that the app does not abort. This is the only
  check that exercises the window pass that throws.

## Implementation discretion

- How the stated width is derived and carried to each wrapping label, and how
  the button row reports the width it needs.
- Whether the shared dialog surface is a base class, an extension, or a free
  function, and how much of the duplicated chrome and centering moves with the
  resize.

## Commit progress

- [x] 1. fix(ui): give confirmation layout a fixed point

## Implementation notes

- The shared dialog surface is a base class, `app/DialogPanel.swift`: the
  utility chrome, `center(on:)`, and the one-pass `sizeToContent`. The
  precondition that makes one pass enough is stated on the class, because it
  binds any future subclass and not just these two.
- `sizeToContent` lays out twice: once to measure at the stated width, once to
  settle the subviews into the frame it then sets. That is not the deleted retry
  loop -- nothing is re-measured, and the second pass cannot change the size --
  but it is what leaves the caller owing no layout, which PO1 asserts.
- The visible command area is `min(list height, bound)` written as three
  constraints -- two required upper bounds and an optional pull toward the
  content height -- plus required vertical clipping resistance on the list. The
  resistance is what makes I4 hold: without it the solver satisfies the pull by
  shrinking the list instead of the area.
- A command's label now wraps by character, not by word. A command is often one
  unbreakable token, and a word-wrapped label draws such a token past the width
  it was given and clips it, which I5 forbids.
- `DialogActionRow.requiredWidth` counts only the buttons that resist
  compression. An alternate truncates by design, so counting its natural width
  would make a long alternate widen the panel and quietly retire the row's own
  truncation rule.
- PO5's case now uses a confirm title 8 repeats long instead of 12. The ceiling
  is screen-derived from this commit on, so a 12-repeat row could exceed the
  ceiling on a small display and make the case turn on the tester's screen.

## Follow Up

- The manual check in `## Verification` is still owed: quit with many running
  commands in a real display cycle and confirm the list scrolls under a
  stationary button row and the app does not abort. No harness case can reach
  the window pass that used to throw, and no CLI surface can raise or report an
  open confirmation, so a person has to run it.
- `app/NoticePanel.swift:32` states no `preferredMaxLayoutWidth` on its body
  label, so a long single-line notice message still stretches that panel to one
  line. The confirmation panel's fix does not reach it, and nothing in this
  plan's scope covers the notice panel's width.
