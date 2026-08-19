# Split the pane chip's one state dot into an alert mark and an agent mark

## Context

A sidebar tab row for a multi-pane tab draws a strip of 12pt pane chips
(`app/PaneStripView.swift`). Each chip can carry one state dot on its top-right
corner. Three different facts feed that one dot today, and the core collapses
them before the view ever sees them (`paneChipState` in
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`):

- pane has an unread alert -> `.attention` (red)
- agent waiting on a prompt -> `.attention` (red)
- agent mid-turn -> `.busy` (amber)

So a red dot is ambiguous, and an alert on a pane whose agent is also waiting or
working shows exactly one mark for two independent facts. You cannot tell "this
pane rang" from "this pane wants an answer", and a pane that is both reports
only one of them.

The collapse is the defect, not the corner. The ideal structure is the one where
the ambiguity cannot exist: the chip carries the two facts separately, and each
gets its own corner. Alert keeps the top-right red dot. Agent state moves to the
bottom-right, with waiting recolored to system green so it can never be confused
with the red the alert mark owns.

Decisions taken with the user:

- A pane that is both alerting and running an agent draws **both** dots. That is
  the point of the change.
- Busy stays amber. It already survives the accent row (it has a ring, and the
  regression test in `tests-ui/PaneStripViewTests.swift` pins that).
- Both dots keep the same diameter and ring. `icon/chips/chips.json`'s
  `_stateDotNote` records why the two were made equal and forbids shrinking one
  to rank it; that stays true across corners.
- The waiting green is a fixed manifest color, so every chip color stays in
  `chips.json` and judgeable in `preview.html`. Green clears the accent-painted
  selected row on its own, so the waiting mark needs no selection-dependent
  color and the strip's existing row input is untouched: it still carries only
  what the dot rings are punched out of.

## Contract

**C1 -- the core reports two independent facts.** A pane chip
(`TabPaneChip`) carries an alert bit and an agent state (waiting / working /
quiet) as separate fields. Neither outranks the other and nothing collapses
them. The alert bit is the pane's unread-alert count from the tally the sidebar
projection already computes. The agent state maps an attached agent's reported
activity: waiting -> waiting, working -> working; idle, unreported, and no
attached agent alike -> quiet. `PaneChipState` and `paneChipState` go away.

**C2 -- two corners.** The alert mark draws at the chip's top-trailing corner,
the agent mark at its bottom-trailing corner. Same diameter, same ring, same
bleed as today's single dot. A chip may draw both at once, and the two never
overlap.

**C3 -- the manifest is what ships.** `paneList.<mode>.stateDot` grows to four
colors plus the ring, and the generated `ChipArtwork` palette follows:

| key | light | dark | meaning |
|---|---|---|---|
| alert | `#FF3B30FF` | `#FF453AFF` | renamed from `attention`; value unchanged |
| waiting | `#34C759FF` | `#30D158FF` | system green |
| busy | `#C77700FF` | `#FF9F0AFF` | unchanged |
| ring | `#FAFAFAFF` | `#232326FF` | unchanged |

`_stateDotNote` is rewritten to state the new contract, keeping the paragraphs
that record why busy must keep its ring and its size and why both dots are
opaque, and adding which corner each mark takes and why. `preview.html`'s
`shipped` variant draws both marks from the manifest and gains alert+waiting and
alert+working to the state matrix.
The exploratory dot variants stay untouched -- they record losing candidates.

## Files

- `icon/chips/chips.json`, `icon/gen-chips.sh`, and the regenerated
  `lib/ChipArtwork/Sources/ChipArtwork/ChipArtwork.swift` (generated, checked
  in; `scripts/chip-artwork-isolation-gate.sh` still passes -- these are plain
  `CGColor`s).
- `icon/chips/preview.html`.
- `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift` -- `TabPaneChip`,
  `tabPaneChips`, and the lifecycle mapping. Nothing else in the core reads
  these; pane focus borders and the tab badge take the tally directly
  (`Projections.swift`).
- `app/PaneStripView.swift` -- corner geometry and two-mark drawing. Its
  row-background input and `SidebarRowView`'s push of it are unchanged.

Vertical room is already there: the strip is 12pt tall inside a 40pt row, its
top pinned 2pt under the title (`app/SidebarCellViews.swift`), leaving roughly
5pt below -- more than the 2pt a bottom dot plus ring needs.
`clipsToBounds = false` is already set and already documented as covering the
bleed.

## Implementation discretion

Names and helper boundaries are the implementer's call, so long as C1-C3 hold.

## Tests

Write these first and watch them fail for the right reason.

**Core** (`lib/DanTermCore/Tests/DanTermCoreTests/ChipKindTests.swift`) --
replacing `paneStateCollapsesAlertAndActivity` and `alertOutranksWorking`:

- A pane that is both alerting and mid-turn reports the alert bit **and** the
  working state. This is the test the old model could not express, and the bug
  in one line.
- The lifecycle mapping of C1, including the three cases that mean quiet.
- Keep `alertMarksOnlyItsOwnPane` and
  `activityChangeReachesTheSidebarProjection`, restated on the new fields.

**Wait retraction** (`AgentWaitRetractionTests.swift`) -- a retracted wait
leaves the agent state quiet and does not touch the pane's alert bit.

**Paint** (`tests-ui/PaneStripViewTests.swift`), extending the existing 3x
`ringSamples` sampling:

- *Geometry:* the alert mark lands at the top-trailing corner and the agent mark
  at the bottom-trailing, both inside the bleed budget the strip declares, and
  the two never intersect, rings included. Replaces "both states draw the same
  dot, so neither is the quieter one" with the equal-size claim restated across
  corners.
- *Both at once:* a chip that is alerting and waiting paints red at the top
  sample point and green at the bottom one. This is the regression the whole
  change exists for.
- *Rings:* extend "a busy dot is ringed in the color of the row behind it" --
  the amber-on-accent-blue regression -- to every mark the strip can paint, so
  the ring band around the alert and waiting marks is sampled too. C2 says both
  marks keep the ring, and only a sampled band proves one was painted; geometry
  that reserves room for a ring proves nothing about whether it exists. This is
  the test that stops a new mark from shipping bare against the chip it lands
  on.
- Keep the fitting, elision, and focus-anchoring tests.

**Projection rows** (`tests-ui/SidebarProjectionRowTests.swift`) -- the three
assertions on the collapsed chip state become assertions on the two new fields.

## Verification

1. Regenerate `ChipArtwork.swift` with `icon/gen-chips.sh` and diff it: only the
   pane-list palette and its doc comments should move.
2. `just test`.
3. `just test-ui > .build/ui.log 2>&1`, then grep the log. One command, one run.
4. Open `icon/chips/preview.html` and judge the new pairing by eye in both
   appearances and on all row surfaces -- especially green on the accent-painted
   selected row, and whether an alert+working chip reads as two facts rather
   than as noise.
5. Live: `just launch-slot | tail -1`, then with `danterm --socket <sock>` split
   a tab into panes, run a Claude session in one, and ring a bell (`printf
   '\a'`) in that same pane so it carries an alert and an agent state at once.
   Confirm the two marks, and that both still read with the row selected.
   `just stop-slot <n>` when done.

## Commit progress

- [x] **1. Split the fact and the corner.** Manifest, preview, generated
  palette, core fields, strip drawing, row propagation, and every test above, in
  one commit. The manifest and `preview.html` are the repo's statement of what
  ships, so no commit may leave them describing two marks while the app draws
  one.

## Implementation notes

- The core names the two fields `hasAlert` and `agent` on `TabPaneChip`, and
  the agent states live in `PaneAgentMark` (`waiting` / `working` / `quiet`).
  `PaneChipState` and `paneChipState` are gone; `paneAgentMark(agent:)` is the
  lifecycle mapping.
- `PaneStripView.stateDotRect` became `markRect(_:on:)`, which takes a corner
  and always returns a rect. Whether a mark is drawn is now the caller's
  question, decided per fact, so the rect no longer needs to be optional.
- `preview.html`'s exploratory dot variants are untouched, as the plan
  required, so they cannot express the two combined states. `dotStrip` collapses
  a combined state to `alert` before handing it to a non-shipped variant, which
  shows each losing candidate doing exactly what it proposed: spending its one
  slot on the alert and dropping the agent fact.
- The both-at-once paint test resolves the expected palette from the strip's
  own `effectiveAppearance` rather than pinning the light one: the UI harness
  runs under whatever appearance the machine is set to, and a hard-coded
  palette fails on a dark-mode machine for a reason that has nothing to do with
  the strip.

## Follow Up

- Verification steps 4 and 5 of this plan are human judgement and were not run:
  open `icon/chips/preview.html` to judge the new green-on-accent pairing and
  the combined-mark rows by eye, and check a live slot with a pane that is both
  alerting and running an agent.
