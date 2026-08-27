# Improvement audit: vetted findings

A fan-out over the whole DanTerm tree at `272db20c` (2026-08-26), 41 agents.

- **Round 1 -- audit.** Eighteen auditors, one per lane, looking for wrong
  behavior, states that should not be representable, work that scales with how
  much state exists instead of with what changed, and concepts that could be
  removed outright. Every lane was told to work out the ideal fix first, and to
  score impact and confidence separately from effort. 131 findings
  (`PARSE-1`, `REFLOW-2`, ...).
- **Round 2 -- vetting.** One adversarial verifier per lane re-opened every
  cited symbol in the tree, re-checked each quote, asked whether the problem is
  reachable rather than merely representable, followed each `references/`
  citation, rescored, and recorded the conflicts between findings. 36 findings
  came back confirmed as written, 51 were rescored, 43 were rewritten, and one
  (`GRID-1`) absorbed a duplicate. Nothing was pruned outright.
- **Synthesis.** Four synthesizers rolled the vetted corpus into root-cause
  themes through four lenses -- structure, cost, correctness, process -- and one
  final pass ordered the corpus into fifteen waves by what blocks what.

**No number in this file was measured.** The auditors were forbidden from
running benchmarks: eighteen agents each building two arms would have wrecked
the machine, and this repo does not accept an unmeasured magnitude anyway. Each
cost finding names, in **Verification**, the exact command and workload that
would decide it and the number that must move. Treat every cost finding as a
candidate with a stated experiment, not as a result. Note what wave 1 is for:
three of the instruments that would settle these questions cannot currently
fail, so they get fixed before any number is read off them.

## How to use this file

Every finding has a stable id and its own anchor. To start work on one, tell an
agent:

> plan the ideal solution to REFLOW-1 in `docs/scratch/2026-08-26-improvement-audit.md`

The finding section is meant to be enough context on its own: files as
`path#symbol`, the problem, quoted evidence, the ideal fix, what stops being
representable, the cheaper fallback named as an explicit trade-off, the
behavioral test that would prove it, the risk -- and, from the vetting pass,
what a second agent found when it opened the cited code. **Read the `Vetted`
line first**: where it carries a `Correction`, the correction wins over the
prose above it. Scores are the vetted numbers, not the auditors' originals.

**The working list is the [Plan of work](#plan-of-work)**, ordered into fifteen
waves. Tick the box there, and if the outcome needs a word, append it on the
same line (`-- done 1a2b3c4`, `-- skip: not worth it`). That is the one place to
edit; everything below it is reference. A ticked box means the prose in that
finding's section may now describe code that no longer exists, so read the
commit, not the finding.

Each finding carries one of five verdicts:

| Verdict | Meaning |
|---|---|
| `confirmed` | Evidence checked, problem real, fix sound, as written. |
| `rescored` | Real, but the original numbers were wrong. The numbers below are the verifier's. |
| `rewritten` | Real, but the finding misstated the problem, the evidence, or the fix. The correction is in the **Vetted** block. |
| `merged` | Two auditors found the same thing. Keeps its id so links do not dangle; the survivor carries the work. |
| `pruned` | Not real or not worth doing. None this round. |

## The lanes


- **`PARSE`** (7). The parser state machine itself is sound; every remaining defect is a closed vocabulary that lives in more than one place -- DEC private modes restated by three switches (so mode 47 is missing from all three), kitty keyboard flags as a bare UInt16 masked at each writer, a DCS header rebuilt from its route instead of its retained parameters -- plus two lone arithmetic expressions (REP's row cap, the X10 mouse clamp) that no reference emulator has.
- **`GRID`** (5). The arena and the row bytes are sound; what is left are seam rules and mode vocabularies written out by hand at every reader instead of declared once, plus two small places where a sequence or a metric does slightly more or less than its definition.
- **`REFLOW`** (7). Reflow decides what a row holds from cell `kind` alone and rebuilds everything else from a default, so background fills are erased, a cursor parked in trailing blanks is clamped onto committed text, and per-cell lookup tables are built to answer two queries.
- **`DRAW`** (9). Almost every defect is a fact stored twice -- a run's row beside the array that indexes it, the executor's sprite routing re-guessed in the planner's ink model, sixteen palette fields and a nil-slot table hand-matched to a switch -- plus rot in the one benchmark the gate never compiles.
- **`SELECT`** (7). The interaction layer's own structure is sound; what remains is two protocol-level deviations from the reference emulators (a clamped legacy mouse coordinate, a missing DECSET 1007), a handful of tag-beside-payload pairs that let a counter, a wheel cell, or a row-clip rule disagree with the value it describes, and per-cell loops in link resolution that repaint a whole history row on every iteration.
- **`PTY`** (9). The steady-state read, write, and recording paths hold up; every real defect sits at the end of a lifecycle -- a teardown ladder bounded only when a human asked to close, a session kill sweep latched once per stage, a recorder guard that traps where the same file already has a total classifier, and a launch handshake that reads "no payload" as success.
- **`PROBE`** (8). The harness collects honestly once it starts, but its input boundary does not: three CLIs accept a parameter that makes the run meaningless and still print a well-formed report, one recipe is rebuilt field-by-field where a default hides an omission, and the ladder's tightest-threshold workload times its own checksum inside the measured bracket.
- **`MODEL`** (7). The remaining defects all take one shape: a rule stated once and silently depended on elsewhere -- the sidebar op script assuming the store did not remount a group, the confirmation projection restating the reducer's retraction rule, the container diff building the exact parallel tree its own comparison exists to avoid, and a split ratio repaired at projection instead of at ingress.
- **`UPDATE`** (9). The reducer's remaining defects are all a rule that already has an owner, restated by hand somewhere else -- an alert-suppression test written twice with the copies disagreeing, a pane-teardown ritual written five times, a close-subject vocabulary declared twice, and a "what survives a restore" rule split across three sites and short of the fields it needs.
- **`PERSIST`** (7). The persistence codec is sound, but several facts live in two places and are reconciled by a rule written in prose instead of in the types -- structure in two checkpoint files with a comment picking the winner, one agent-session string validated twice with two different failure policies, the --init snapshot validated twice with one result discarded, and a split direction that is an enum on both ends and a String in between.
- **`IPC`** (6). The IPC catalog and framing are sound; every remaining defect is one fact restated somewhere it already had an owner -- the hello restates a per-connection liveness bound from a server-wide field, the audit descriptor is derived twice from the same request, a decode error is carried through the Elm model to be turned back into the constant it already was, and one wire object has four spellings.
- **`SUPPORT`** (6). The seams themselves are sound; the defects are all cases of a seam written for one artifact being pointed at another -- a private-directory creator aimed at a folder the user picked, a probe carrying two homes, an installer whose two branches mode the same directory differently.
- **`CHROME`** (7). The chrome's remaining defects are all a fact written a second time beside the value that already owns it -- the sidebar's width kept only in NSSplitView, a badge hidden by both the badge and its cell, two objects each holding "the applied sidebar projection", and a container built in two steps so it briefly contradicts its tab.
- **`INPUT`** (8). The input layer already holds every fact it needs, but does not carry it to the boundary that asks -- so the cursor position, the pressed button, the horizontal wheel axis, the resolved pane geometry, and a command's identity each get re-invented or dropped at the seam.
- **`MOBKIT`** (6). The iOS kit's pure core is sound; the remaining defects all sit on the seam between the model and its untested UIKit shell -- a record the shell cannot decode is dropped instead of ending the stream, facts are round-tripped or re-derived across that seam, and two effects the shell declines to perform are never reported back.
- **`MOBAPP`** (6). Almost every defect left in the iOS shell is a session rule stated a second time inside the app target, which has no test target -- the hardware-key mapping, the overflow-menu predicate, and the launch-sheet condition each duplicate a decision the kit already owns as a tested value.
- **`CLI`** (11). Almost every defect is one rule written down twice with only one copy enforced -- a catalog policy nothing reads, a doctor title that re-states its own status, SKILL.md prose restating protocol constants, a grid bound copied into help text -- plus two plain bugs where a hidden constant overrides the caller's timeout and a blank todo edit reports success without changing anything.
- **`GATE`** (6). Every remaining defect in the gate is a check whose subject is named by hand, so its absence and its success look identical: three lints print "passed" when the file they check is gone, nothing forces a lint script to run over the tree at all, one hard deadline covers a build the gate itself forces cold, and two PTY tests assert an elapsed duration in place of a counter that already carries the fact.


## All findings by score


| Score | Id | Cat | Effort | Verdict | Fix |
|---|---|---|---|---|---|
| 4x5 | [MOBAPP-1](#mobapp-1) | correctness | medium | confirmed | Send the shifted character a hardware key would insert, and decide that in the kit |
| 4x5 | [REFLOW-1](#reflow-1) | correctness | small | rewritten | Re-fold the cursor's trailing-blank distance instead of clamping it into the last column |
| 4x5 | [REFLOW-2](#reflow-2) | correctness | medium | confirmed | Carry each row's fill style through the refold instead of rebuilding blanks at the default style |
| 4x5 | [UPDATE-1](#update-1) | correctness | small | confirmed | Let one rule decide whether a focused pane's alert is suppressed, so an agent waiting for input notifies a backgrounded app |
| 3x5 | [CHROME-1](#chrome-1) | correctness | medium | confirmed | Give the sidebar's collapse and width a model slot instead of leaving them in `NSSplitView` |
| 3x5 | [CHROME-3](#chrome-3) | cost | medium | rewritten | Stop submitting a new grid to every hidden tab's child process on every frame of a window resize |
| 3x5 | [CLI-1](#cli-1) | correctness | small | rescored | Give the TCP connect the whole caller-supplied deadline instead of capping each address at one second |
| 3x5 | [DRAW-1](#draw-1) | structural | medium | rescored | Delete the `row` field from the four run types, so a run's row is the array that holds it |
| 3x5 | [DRAW-2](#draw-2) | cost | medium | confirmed | Classify a sprite cell's ink as the cell band, not as unmeasured font ink |
| 3x5 | [DRAW-3](#draw-3) | correctness | small | confirmed | Repair the headless draw benchmark arm, which has not compiled since the plan went row-indexed |
| 3x5 | [GATE-1](#gate-1) | correctness | small | rescored | Make a lint whose target is missing fail, not print "passed" |
| 3x5 | [GATE-3](#gate-3) | structural | small | confirmed | Make the gate prove that each lint script runs over the tree, not just that its self-test runs |
| 3x5 | [GATE-4](#gate-4) | correctness | small | rewritten | Replace the two wall-clock acceptance thresholds in the PTY suites with the fact they are standing in for |
| 3x5 | [GRID-1](#grid-1) | correctness | small | rewritten | Accept DECSET/DECRST 47 and declare the three alternate-screen switch modes as one table |
| 3x5 | [IPC-1](#ipc-1) | structural | small | confirmed | Answer a decode failure on the server, not through the Elm model |
| 3x5 | [MOBKIT-1](#mobkit-1) | correctness | small | rescored | End the stream on a record the phone cannot decode instead of skipping it |
| 3x5 | [MOBKIT-3](#mobkit-3) | simplification | small | confirmed | Decide a stream's end where the record is decoded, and delete the record round trip |
| 3x5 | [PARSE-1](#parse-1) | correctness | small | merged into GRID-1 | Implement DEC private mode 47 alongside 1047 and 1049 |
| 3x5 | [PERSIST-1](#persist-1) | correctness | medium | rewritten | Give the restore structure one source on disk, and write it on the exit path |
| 3x5 | [PTY-1](#pty-1) | correctness | small | rewritten | Arm the teardown bound when the ladder starts, not when a human asks to close |
| 3x5 | [REFLOW-3](#reflow-3) | correctness | small | rewritten | Give a cursor on a blank continuation row a row of its own instead of snapping it to the line head |
| 3x5 | [REFLOW-7](#reflow-7) | correctness | small | rewritten | Have the height-shrink trim read `logicallyContinues`, like every other line-structure reader |
| 3x5 | [SUPPORT-1](#support-1) | correctness | small | rescored | Stop the checkpoint writer from creating the destination's parent, so a state export cannot chmod the user's folder to 0700 |
| 3x5 | [UPDATE-4](#update-4) | correctness | large | rescored | Separate the process-scoped half of `AppModel` from the session half so a restore cannot drop it |
| 3x4 | [GATE-2](#gate-2) | correctness | small | rescored | Take the build out from under the TerminalPTY lane's hard deadline |
| 2x5 | [CHROME-2](#chrome-2) | structural | medium | rescored | Give `SplitContainerView` one presentation entry point that takes the tree and the zoom together |
| 2x5 | [CHROME-5](#chrome-5) | structural | small | rewritten | Let one owner decide a badge's visibility instead of the badge deciding and the cell overwriting |
| 2x5 | [CHROME-6](#chrome-6) | structural | small | rewritten | Decide whether a pane drag may start from the pane's own toolbar projection, not from the selected tab |
| 2x5 | [CLI-10](#cli-10) | cost | small | confirmed | Stop allocating and zeroing a 64 KiB buffer on every socket read |
| 2x5 | [CLI-11](#cli-11) | correctness | small | rewritten | Say which entity `pane zoom` reports, in the one line `danterm help` prints |
| 2x5 | [CLI-3](#cli-3) | correctness | small | rescored | Refuse blank todo text at the request boundary instead of silently succeeding |
| 2x5 | [CLI-4](#cli-4) | structural | medium | rescored | Let `doctor` name the instance it queries, or stop calling `localOnly` a local command |
| 2x5 | [CLI-5](#cli-5) | structural | small | rescored | Enforce the catalog's target policy, or derive it from the method traits that already decide it |
| 2x5 | [CLI-6](#cli-6) | structural | small | rescored | Print the doctor row's identity, and keep the observed state out of its title |
| 2x5 | [CLI-7](#cli-7) | correctness | medium | rescored | Gate the protocol constants SKILL.md states as prose, the way its synopsis is already gated |
| 2x5 | [CLI-9](#cli-9) | structural | small | rewritten | Declare the pane grid bound once, instead of stating it as help prose beside the range that enforces it |
| 2x5 | [DRAW-4](#draw-4) | simplification | small | confirmed | Store the ANSI palette in an `InlineArray<16, RenderColor>`, deleting the sixteen fields, the switch, and the trap |
| 2x5 | [DRAW-5](#draw-5) | structural | small | confirmed | Make the box-drawing table total, deleting its nil slots and the unreachable trap |
| 2x5 | [DRAW-7](#draw-7) | cost | small | rescored | Resolve a row's search overlays with an advancing cursor instead of a scan per column |
| 2x5 | [DRAW-8](#draw-8) | simplification | small | confirmed | Delete `withGlyphHalo` and its bitset routine, which the reach ledger replaced |
| 2x5 | [GATE-5](#gate-5) | structural | small | rescored | Widen checkpoint-off-main-lint to the whole `app/` tree for the three spellings that are already unique to it |
| 2x5 | [GRID-2](#grid-2) | structural | medium | rewritten | State the history/live seam once, and give a stream row one meaning |
| 2x5 | [GRID-4](#grid-4) | simplification | small | confirmed | Materialize a retained display row once, in one function |
| 2x5 | [INPUT-1](#input-1) | correctness | small | rescored | Report a claimed control-click as the left button, and delete the physical-vs-reported button split |
| 2x5 | [INPUT-2](#input-2) | correctness | small | rescored | Answer `firstRect(forCharacterRange:)` from the published cursor so the IME panel follows the caret |
| 2x5 | [INPUT-3](#input-3) | structural | medium | rescored | Store the pane's resolved presentation geometry as one value instead of four correlated optionals |
| 2x5 | [INPUT-4](#input-4) | correctness | medium | rewritten | Report horizontal wheel motion instead of discarding it |
| 2x5 | [INPUT-5](#input-5) | structural | medium | rewritten | Carry the typed `ConfigurableCommand` through the menu item instead of a raw id string |
| 2x5 | [INPUT-6](#input-6) | simplification | small | rescored | Delete the input-source observer that rebuilds the menu bindings identically |
| 2x5 | [IPC-2](#ipc-2) | correctness | small | rescored | Advertise in `hello` the silence bound the connection is actually under |
| 2x5 | [IPC-5](#ipc-5) | simplification | small | confirmed | Give the `ok` reply and the todo wire object one spelling each |
| 2x5 | [MOBAPP-2](#mobapp-2) | structural | small | rescored | Offer the overflow menu from the item list itself, not from a second copy of its conditions |
| 2x5 | [MOBAPP-3](#mobapp-3) | structural | small | rescored | Ask the model whether the launch needs a target, instead of re-deriving it in the shell |
| 2x5 | [MOBAPP-4](#mobapp-4) | simplification | small | confirmed | Delete the unread `runnerThread` property |
| 2x5 | [MOBKIT-2](#mobkit-2) | cost | medium | rescored | Build the pane outline where the roster arrives, not on every projection read |
| 2x5 | [MOBKIT-4](#mobkit-4) | cost | small | rescored | Reflect the scroll chrome only when the mode it describes moved |
| 2x5 | [MOBKIT-5](#mobkit-5) | structural | small | confirmed | Carry the connection phase only on the failure that reads it |
| 2x5 | [MODEL-4](#model-4) | structural | medium | confirmed | Make the split ratio a bounded type so a corrupt one cannot be stored or reported |
| 2x5 | [PARSE-2](#parse-2) | correctness | small | confirmed | Let REP repeat its count instead of stopping at the row edge |
| 2x5 | [PARSE-3](#parse-3) | correctness | small | rewritten | Emit xterm's past-end marker for legacy mouse coordinates over 222 |
| 2x5 | [PARSE-4](#parse-4) | structural | medium | rewritten | Declare each DEC private mode once, as data, instead of once per consumer |
| 2x5 | [PERSIST-2](#persist-2) | correctness | small | rescored | Drop an invalid persisted agent session like every other corrupt pane field, instead of rejecting the whole restore |
| 2x5 | [PERSIST-3](#persist-3) | cost | small | rescored | Arm the light-checkpoint window without snapshotting the whole model on every message |
| 2x5 | [PERSIST-4](#persist-4) | correctness | small | confirmed | Advance the light-checkpoint baseline only when the write actually succeeded |
| 2x5 | [PERSIST-5](#persist-5) | structural | small | confirmed | Carry the validated restore from launch into bootstrap instead of validating the `--init` snapshot twice |
| 2x5 | [PERSIST-6](#persist-6) | structural | small | confirmed | Persist a split's direction as its own enum, not as a string re-parsed on load |
| 2x5 | [PERSIST-7](#persist-7) | simplification | small | confirmed | Make `terminate()` mark termination and stop returning an action no one applies |
| 2x5 | [PROBE-1](#probe-1) | cost | small | rewritten | Hoist the browse benchmark's plan checksum out of its timed loop |
| 2x5 | [PROBE-2](#probe-2) | correctness | small | rewritten | Make the probe CLIs reject a flag value instead of falling back to the default |
| 2x5 | [PROBE-3](#probe-3) | correctness | small | rescored | Fail the memory probe when a payload could not be measured, instead of printing an empty report |
| 2x5 | [PROBE-4](#probe-4) | correctness | small | rescored | Reject an occupancy run with no iterations, and delete the statistics' `?? 0` |
| 2x5 | [PROBE-5](#probe-5) | structural | small | rescored | Let the resize CLI mutate the recipe instead of rebuilding it field by field |
| 2x5 | [PROBE-7](#probe-7) | structural | small | confirmed | Let the marker scan take the damage value instead of a `Set<Int>` rebuilt from it |
| 2x5 | [PROBE-8](#probe-8) | structural | small | rewritten | Give `PreparedDraw` a non-optional context so a zero-cost draw is unrepresentable |
| 2x5 | [PTY-2](#pty-2) | correctness | small | rescored | Sweep the session census against the members already signalled, not against a one-shot per-stage latch |
| 2x5 | [PTY-4](#pty-4) | structural | small | rescored | Share the bootstrap stage vocabulary between the C child and its Swift parent instead of hardcoding 8 |
| 2x5 | [PTY-6](#pty-6) | simplification | small | rewritten | Let the session census carry the session it enumerated, so no consumer re-filters it |
| 2x5 | [PTY-7](#pty-7) | cost | small | rescored | Read the tty mode once per write turn instead of once per write syscall |
| 2x5 | [REFLOW-5](#reflow-5) | structural | small | confirmed | Hoist the reflow line index into the attachment once and split the trailing-padding anchor into its two real shapes |
| 2x5 | [REFLOW-6](#reflow-6) | structural | small | rewritten | Stamp reflowed continuation rows by the same rule printing uses, not for every marked line |
| 2x5 | [SELECT-1](#select-1) | correctness | small | rescored | Suppress a legacy mouse report whose coordinates do not fit, instead of clamping the byte |
| 2x5 | [SELECT-3](#select-3) | cost | small | rescored | Materialize a projection row once per row, not once per cell, in link resolution |
| 2x5 | [SELECT-4](#select-4) | correctness | small | rescored | Implement DECSET 1007 and gate the alternate-screen wheel route on it |
| 2x5 | [SUPPORT-2](#support-2) | structural | small | rescored | Derive the doctor probe's config path from the probe's own home, so one run has one home |
| 2x5 | [SUPPORT-3](#support-3) | simplification | small | confirmed | State the `sun_path` capacity rule once, instead of once per Unix-socket caller |
| 2x5 | [UPDATE-2](#update-2) | structural | medium | rewritten | Prune a departing pane's pending work from one pass instead of repeating the ritual at five teardown sites |
| 2x5 | [UPDATE-3](#update-3) | structural | medium | rewritten | Fold `ConfirmationSubject` into `ConfirmationKind` so the close vocabulary is declared once |
| 2x5 | [UPDATE-5](#update-5) | correctness | small | confirmed | Ask the quit question before the batch close removes the tabs, the way the single close does |
| 2x5 | [UPDATE-6](#update-6) | simplification | small | confirmed | Delete the `closeRequested` / `sessionEnded` chain, which nothing emits |
| 2x4 | [CLI-2](#cli-2) | correctness | small | rewritten | Make a partial write end the stream instead of throwing a recoverable-looking timeout |
| 2x4 | [CLI-8](#cli-8) | simplification | medium | rescored | Give the CLI a verb for the roster subscription the protocol already serves |
| 2x4 | [GRID-5](#grid-5) | correctness | small | rewritten | Make `multiScalarAllocationCount` count one thing |
| 2x4 | [MOBKIT-6](#mobkit-6) | structural | small | confirmed | Report the two effects the shell cannot perform instead of dropping them |
| 2x4 | [MODEL-1](#model-1) | correctness | small | rewritten | Stop emitting tab row ops for a group the same script just remounted |
| 2x4 | [PTY-3](#pty-3) | structural | small | rewritten | Place a follow subscription's cursor through the recorder's own classifier instead of trapping on it |
| 2x4 | [REFLOW-4](#reflow-4) | cost | medium | rescored | Resolve the tracked cursors during the pack walk instead of building a per-cell destination map |
| 2x4 | [SUPPORT-4](#support-4) | structural | small | rescored | Give the PATH parent directory one mode, whichever install branch creates it |
| 2x4 | [SUPPORT-6](#support-6) | cost | medium | rewritten | Split an oversized IPC batch by measured element size instead of re-encoding the whole batch per halving |
| 2x3 | [GRID-3](#grid-3) | correctness | small | rewritten | Leave the pending-wrap flag alone when ED 3 erases saved lines |
| 2x3 | [PTY-8](#pty-8) | correctness | medium | rewritten | Give forced quiescence's kill loop a way to stop, or stop claiming it enumerated the session |
| 2x3 | [SELECT-2](#select-2) | structural | medium | rescored | Fold the active match into `TerminalSearchStatus.matched` so a counter cannot exist without the match it counts |
| 2x3 | [SUPPORT-5](#support-5) | correctness | small | rewritten | Make the atomic write durable by flushing the directory entry, or stop claiming durability |
| 1x5 | [CHROME-4](#chrome-4) | structural | small | rewritten | Keep one record of the last applied sidebar projection, not one in the driver and one in the view |
| 1x5 | [CHROME-7](#chrome-7) | simplification | small | confirmed | Delete `WindowChromeView.updateSeparatorPosition` |
| 1x5 | [DRAW-6](#draw-6) | simplification | small | rescored | Put the four overlay seeds in one place, and stop pretending one of them is a theme input |
| 1x5 | [GATE-6](#gate-6) | simplification | small | rewritten | Retire the Swift-source text greps in the benchmark harness self-test |
| 1x5 | [INPUT-8](#input-8) | correctness | small | rescored | Set the divider drag offset on every press, so a double-click followed by a drag does not jump |
| 1x5 | [IPC-3](#ipc-3) | cost | medium | rewritten | Build the audit descriptor once, and without materializing the wire params |
| 1x5 | [IPC-4](#ipc-4) | structural | small | rewritten | Make `AppRuntimeIpcDispatch` non-optional on the server |
| 1x5 | [IPC-6](#ipc-6) | structural | small | rewritten | Stop rejecting the empty pane-input text that the catalog can express |
| 1x5 | [MOBAPP-5](#mobapp-5) | simplification | small | rescored | Declare the scene delegate once |
| 1x5 | [MODEL-2](#model-2) | simplification | small | rewritten | Make an emptied Font Size field mean "no `font.size` key" |
| 1x5 | [MODEL-3](#model-3) | cost | medium | rescored | Diff container shape against the split tree itself and delete `ContainerLayoutNode` |
| 1x5 | [MODEL-5](#model-5) | simplification | small | rewritten | Delete the existence guards from `desiredConfirmation` and let the reducer own retraction |
| 1x5 | [MODEL-6](#model-6) | cost | small | rescored | Walk the tree in the per-pane projections instead of materializing `allPanes` three times a sweep |
| 1x5 | [MODEL-7](#model-7) | simplification | small | confirmed | Delete `AlertTab` and read the alert filter off the model's own flag |
| 1x5 | [PARSE-5](#parse-5) | structural | small | rescored | Give kitty keyboard flags a type that cannot hold an unsupported bit |
| 1x5 | [PARSE-6](#parse-6) | correctness | small | confirmed | Rebuild the routed-DCS synchronization prefix from the retained header, not from the route |
| 1x5 | [PARSE-7](#parse-7) | correctness | small | confirmed | Stop clearing the wrap latch on CHT and CBT |
| 1x5 | [PROBE-6](#probe-6) | structural | small | rewritten | Stop the retained-row probe from silently skipping a row it cannot read |
| 1x5 | [PTY-9](#pty-9) | simplification | small | confirmed | Enqueue `.sessionDrained` through `process`, not by writing the reducer's queue directly |
| 1x5 | [SELECT-5](#select-5) | simplification | small | rescored | Delete the unreachable second selection branch in the pointer-move arm |
| 1x5 | [SELECT-7](#select-7) | simplification | small | rescored | Collapse the two copies of "project a stream range onto one viewport row" in the frame planner |
| 1x5 | [UPDATE-8](#update-8) | simplification | small | confirmed | Delete the accumulate-then-discard bookkeeping in the two alert-clearing arms |
| 1x5 | [UPDATE-9](#update-9) | simplification | small | confirmed | Say why `.themeBrowserControlClicked` has an empty arm, or remove the message |
| 1x4 | [INPUT-7](#input-7) | correctness | small | rewritten | Stop the jump-mode monitor from swallowing modified chords, and drop its no-op `flagsChanged` arm |
| 1x4 | [PTY-5](#pty-5) | correctness | small | rewritten | Make an absent bootstrap-failure payload a launch failure, not a launch success |
| 1x4 | [SELECT-6](#select-6) | structural | medium | rewritten | Carry the normalized `TerminalViewportCell` into `TerminalWheelEvent` instead of loose column and row |
| 1x3 | [DRAW-9](#draw-9) | cost | medium | rescored | Give the packaged symbols face the same eager glyph resolution the styled faces get |
| 1x3 | [UPDATE-7](#update-7) | cost | medium | rescored | Stop the per-message repair sweep from scaling with the tab and alert count |
| 1x2 | [MOBAPP-6](#mobapp-6) | cost | small | rescored | Write the status pill only when the status changes |


<a id="plan-of-work"></a>


## Plan of work

### Wave 1 -- Make the gate and the instruments able to fail

Nothing later can be priced or trusted until a check that cannot find its subject goes red and a probe stops reporting what it never measured. The headless draw arm has not compiled since `13db5f73`, and four DRAW/MODEL/MOBKIT cost findings name it or a probe as their experiment. Every item here is startable today, touches only `scripts/`, the probe CLIs, and the gate, and blocks work in Waves 2, 6, 7 and 14.

- [x] [GATE-1](#gate-1) -- Promote `setup_fail` into a shared `scripts/lib` helper and fail any lint whose named target is missing (3x5, small, correctness)
- [x] [GATE-2](#gate-2) -- Run `swift build --build-tests` outside `run-with-deadline.py`, then both PTY lanes with `--skip-build` (3x4, small, correctness)
- [x] [GATE-4](#gate-4) -- Delete the two elapsed-time acceptance assertions in the PTY suites and keep `forcedQuiescenceCount == 0` (3x5, small, correctness)
- [x] [GATE-6](#gate-6) -- Delete the three `justfile` recipe-name greps in the benchmark harness self-test; keep every `app/*.swift` grep (1x5, small, simplification)
- [x] [DRAW-3](#draw-3) -- Store `TerminalDamage` in `PreparedDraw`, pass it as `restrictedTo:`, and add the arm to the lint pass as a type-check-only build (3x5, small, correctness) -- done, but not as a typecheck lint: the arm is now the `HeadlessDrawArm` target of `lib/TerminalCore`, so the gate compiles it with everything else. A second orphan was found and moved the same way (`terminal-recording-replay.swift`), and `scripts-swift-orphan-lint.py` keeps a third from appearing. `just benchmark-headless-draw 2` runs; its A/A control read +0.22% with a 0.85% paired spread.
- [x] [PROBE-8](#probe-8) -- Make `PreparedDraw`'s context a non-optional `let` and free the buffer under `withExtendedLifetime(context)` (2x5, small, structural) -- done in both copies, per the Correction. The verification it proposed was already in the suite (`drawnCellCount > 0`); the ASan run is what this change needed and it is clean.
- [x] [PROBE-2](#probe-2) -- Replace the can't-fail `flagValue` helper with the positional parse loop; exit 2 on a bad flag (2x5, small, correctness) -- done, but not as a fourth hand-rolled loop. `flagValue` and the four divergent argv walks are gone, replaced by one `TerminalProbeArguments` target: a probe declares its flag names, defaults, and ranges, and a pure `parse` returns either a validated `ProbeArguments` or the refusal to print. Each probe's spec moved out of `main.swift` into its support module, so the gate tests it -- the parse used to be the one part of these CLIs no suite could reach. Two failures the finding did not name were the worst of them and are fixed too: `--chunk -5` silently selected single-shot feeding (measuring one huge parse instead of a resident terminal), and `--iterations 0` exited 0 over a full table of 0.00 ms readings. `--payload`'s name check and the resize probe's no-op-width check moved onto the same refusal path. Confirmed against the release binaries: `--columns eighty` and `--iterations 0` now exit 2 with a usage line, and `--columns 80 --rows 24` still heads `80x24`. The `just` half of the Correction held -- the recipes word-split and were never broken.
- [x] [PROBE-5](#probe-5) -- Make `ResizeProbeRecipe`'s fields `private(set) var` behind `with(...)` and carry `payload` into `ResizeProbeReport` (2x5, small, structural). `sampleCount` was not added: `distribution.sampleCount` already reports it, and it is the *measured* count rather than the requested one.
- [x] [PROBE-6](#probe-6) -- Return nil on the first unreadable retained row and derive `retainedRowCount` from `storedCellCounts.count` (1x5, small, structural)
- [x] [PROBE-1](#probe-1) -- Hoist the browse benchmark's plan checksum out of the timed bracket (2x5, small, simplification)

### Wave 2 -- Close the gate's last blind spots and the probe report types

These four need Wave 1 in place: `GATE-3` and `GATE-5` build on the shared target-check helper, and `PROBE-3`/`PROBE-4` push Wave 1's parse refusal into the report types so a zero-payload report and a zero-iteration sample stop being constructible. Small wave, one sitting.

- [x] [GATE-3](#gate-3) -- Require every tracked `*-lint`/`*-gate` script to appear as a command word in the assembled gate or carry `# gate: opt-out` (3x5, small, structural) -- done: the rule is in `gate-test-coverage-lint.py`, keyed on the name a rule check carries, with `scripts/lib` excluded and one same-stem wrapper indirection (the two `.py` files behind `core-purity-lint.sh` and `swift-file-header-lint.sh`). The tree was already complete, so the diff is zero-to-green; ablating one `LINT_STEPS` line turns it red. The finding's by-construction claim is narrower than written -- several real gate lints are named neither `-lint` nor `-gate` -- so the docstring records derivation (a gate list assembled from the tree) as the endpoint this rule is the load-bearing half of.
- [x] [GATE-5](#gate-5) -- Widen `checkpoint-off-main-lint` to all of `app/`, with `JSONEncoder(` as a one-entry allowlist under a stale-entry check (2x5, small, structural) -- done, as a second target list rather than an allowlist: `lint_resolve_targets` already fails red on a stale name
- [x] [PROBE-3](#probe-3) -- Validate the geometry before any payload is built, so `runMatrix` cannot return a zero-payload report at exit 0 (2x5, small, correctness) -- done. `PROBE-2`'s flag minimums had already closed the CLI path, so what was left was the half the Correction names: the `--json` artifact. `runMatrix` and `measure` now throw `MemoryProbeFailure`, the geometry is settled by `Terminal.acceptsGeometry` before a payload byte is built, `MemoryProbeReport` refuses an empty payload list on construction and on decode, and `cellStrideBytes` is derived from the first payload rather than stored beside it with a `?? 0` -- so the report is schema 3 and the field left the wire. `footprintCoverageOfCellStorage` went with it, per the Dropped note: it is `Double?` now, and the coverage column prints `--` for an unmoved footprint instead of the `0.00` a real uncovered delta prints. The engine's geometry bound, restated in two probe CLIs and the `init` guard, is now one pair of constants.
- [x] [PROBE-4](#probe-4) -- Reject `iterations < 1` and make `OccupancySample` hold at least one measurement by construction (2x5, small, correctness) -- done e2ec7e70. The parse half was already landed by `PROBE-2`; what remained was the type. `PositiveCount` in `TerminalProbeArguments` carries the floor of 1 into `runOccupancyProbe`'s signature, and `CountFlag` is the flag kind that parses to one, so a caller that never touches the command line cannot ask for zero either. `OccupancySample` holds its first measurement as a stored field and the three fallbacks are gone. Scope grew by one sibling the finding did not name: `ResizeProbeDistribution` had the identical empty-to-zeros branch, and its statistics are now a reduction of the samples it holds rather than fields beside them -- so a decoded artifact whose median no sample supports reduces to the samples' own median, and one with no samples fails to decode. The artifact keys are unchanged. The cheaper fallback (an `iters` column) was not taken and is not needed.

### Wave 3 -- Delete what nothing reaches

Every item removes a symbol, a case, a payload or a whole chain that production abandoned. Deleting first shrinks the files that Waves 4, 9 and 12 rewrite, and it removes three conflicts outright: `CHROME-7` clears a method `CHROME-1` would otherwise have to reconcile, `INPUT-6` unblocks `INPUT-5`, and `MOBKIT-5`/`MOBAPP-4` clear the fields `MOBKIT-6` touches. No prerequisites, all small.

- [x] [UPDATE-6](#update-6) -- Delete the five-link `closeRequested`/`sessionEnded` chain and re-point four test files at `.sessionProcessExited` (2x5, small, simplification) -- done
- [x] [UPDATE-8](#update-8) -- Reduce both alert-clearing arms to `markAlertsReadForPane` and delete `unreadAlertPaneIds` (1x5, small, simplification) -- done 683bd724
- [x] [UPDATE-9](#update-9) -- Comment `.themeBrowserControlClicked` with what it drives and report the click through `ReconcileFollowUps` (1x5, small, simplification) -- done ca12bcf1: renamed to `.nonPaneControlTookFocus` and commented at both sites; the `ReconcileFollowUps` half was a no-op, `runtime.send` already routes through the outbox
- [x] [PERSIST-7](#persist-7) -- Make `RecoveryCheckpointPolicy.terminate()` return `Void` and drop the two assertions pinning a rule production disobeys (2x5, small, simplification) -- done
- [x] [MODEL-7](#model-7) -- Delete `AlertTab` and read the alert filter off `model.showAllAlerts` (1x5, small, simplification) -- done. The four helper-shape tests the Correction names went with it; `desiredAlertsPopover` cases in `ProjectionsTests.swift` already covered both the filter and both empty strings.
- [x] [DRAW-6](#draw-6) -- Delete `RenderTheme.searchMatchBackground` and name all four ladder seeds together in `RenderColorResolution.swift` (1x5, small, simplification) -- done, with three seeds rather than four: the fourth is `theme.selectionBackground`, a color a caller does choose, so it stays on the theme. One thing the finding did not name went with the field: `searchHighlightSeed` compared the constant to itself and had been vacuous since `f30f8cd9` replaced the per-theme derivation with the literal. It now resolves `.activeSearchMatch` through two themes that share every color the ladder consults and differ in all sixteen ANSI entries and both cursor colors, which fails if the seed is ever theme-derived again. The 592-theme contrast sweep passed unchanged, as a pure move must.
- [x] [DRAW-8](#draw-8) -- Delete `withGlyphHalo` and `TerminalDamageRowBits.haloed`, folding the halo locally in the frozen research probe (2x5, small, simplification) -- done
- [x] [SELECT-5](#select-5) -- Delete the unreachable second selection branch in `decidePointerArm`'s `.move` case (1x5, small, simplification) -- done
- [x] [CHROME-7](#chrome-7) -- Delete `WindowChromeView.updateSeparatorPosition`, which has no caller (1x5, small, simplification) -- done
- [x] [MOBAPP-4](#mobapp-4) -- Delete the unread `runnerThread` property and both of its writes (2x5, small, simplification) -- done e1bc6e11
- [x] [MOBAPP-5](#mobapp-5) -- Delete the plist's `UISceneDelegateClassName` key, leaving the compiler-checked symbol (1x5, small, simplification) -- done, widened to the whole `UISceneConfigurations` dict
- [x] [MOBKIT-5](#mobkit-5) -- Drop the unread `phase:` payload from `MobileConnectionFailure.transport` (2x5, small, structural) -- done
- [x] [INPUT-6](#input-6) -- Delete the input-source observer that rebuilds identical menu bindings, and rename `reapplyForCurrentInputSource` (2x5, small, simplification) -- done. Confirmed inert first: no layout API (`TISInputSource`, `UCKeyTranslate`) exists anywhere in the tree, and a canonical chord names a character rather than a physical key, so the refresh clause in `plans/impl/2026-08-21-2110-customizable-keybindings.md` has nothing to refresh. A `tests-ui` case posting the notification and comparing the whole projection passed before the deletion and after it.

### Wave 4 -- Declare each closed vocabulary once, as data

This is the shape the largest cluster of findings is written against, so it goes before anything that adds a case. `PARSE-4`'s keypath table and `GRID-1`'s `SwitchScreenMode` rows are one change with `PARSE-1` and `SELECT-4`: all four conflict on `Terminal.swift`, and modes 47 and 1007 only exist once the table does. The rest are the same move in other files -- palette, box-drawing table, snapshot direction, bootstrap ABI, menu command -- and each is independent of the others.

- [x] [PARSE-4](#parse-4) -- Give the seven plain-Bool DEC private modes one keypath declaration and derive set, reset, DECRQM and resynchronization from it (2x5, medium, structural)
- [x] [GRID-1](#grid-1) -- Add a `SwitchScreenMode` value carrying each mode's three answers, and map 47/1047/1049 onto it (3x5, small, correctness) -- done 132420d2
- [x] [PARSE-1](#parse-1) -- Implement DEC private mode 47 in the enum, the setter and the DECRQM answer, in GRID-1's shape (3x5, small, correctness) -- done 132420d2 (folded into GRID-1)
- [x] [SELECT-4](#select-4) -- Add `alternateScroll = 1007` as a table row and gate `wheelRoute`'s alternate-screen choice on it (2x5, small, correctness) -- done e5cab41e
- [x] [PARSE-5](#parse-5) -- Replace the raw `UInt16` kitty keyboard flags with an OptionSet that masks in `init` (1x5, small, structural) -- done
- [x] [PARSE-6](#parse-6) -- Rebuild the routed-DCS synchronization prefix from the retained header via `appendParameters(to:)` (1x5, small, correctness) -- done, pivoted: reusing `appendParameters(to:)` would have trapped on the emptied `colonSeparators`, so the routed header now stays in the collection for the whole body and `DCSRoute.headerBytes` is deleted
- [x] [DRAW-5](#draw-5) -- Make `lineMappings` a total 128-entry table, deleting the nil slots and the unreachable trap (2x5, small, structural) -- done f1dab3bd
- [x] [DRAW-4](#draw-4) -- Store the ANSI palette in an `InlineArray<16, RenderColor>` with a hand-written element-wise `==` (2x5, small, simplification) -- done
- [x] [PERSIST-6](#persist-6) -- Give `SplitNodeSnapshot.split` a `String`-raw-valued Codable direction enum and delete both switches (2x5, small, structural) -- done 18bb1ca0, 8e272c5e, 1a5d9872
- [x] [PTY-4](#pty-4) -- Give the bootstrap a shared C ABI target declaring `bootstrap_stage` and `bootstrap_failure`, and import it (2x5, small, structural) -- done 020f1bc3; the PTY-5 conflict is settled in PTY-5's favour: `bootstrap_stage_usage` is kept and now written on `argc < 6`
- [x] [PTY-5](#pty-5) -- Return `execSucceeded`/`failed`/`truncated` from `readBootstrapFailure` and map `truncated` to `.systemError(EPROTO)` (1x4, small, correctness) -- done; the read-error arm is the live one, and a bootstrap killed before `execve` still reads as a clean exec, which no return shape can fix
- [x] [INPUT-5](#input-5) -- Type `addCommand`, `representedObject` and `commandDescriptor` on `ConfigurableCommand` and switch `TabColor` exhaustively (2x5, medium, structural) -- done f7748fd9, 50a000ca

### Wave 5 -- Settle the reference divergences with the user

Each of these deletes an assertion whose own preamble argues for the current behavior, so none can land as an ordinary fix. Take them as one sitting with `references/` open: REP's cap, the legacy mouse coordinate, the wrap latch on CHT/CBT and ED 3, the control-click button, and the 0700 PATH parent. They come after Wave 4 because the mode table is the place a decision now gets recorded, and before Waves 6 and 7 because they touch the same `Terminal.swift` regions.

- [x] [PARSE-2](#parse-2) -- Delete the two capping expressions in `repeatLastPrintedCluster` and loop the requested count through `print` (2x5, small, correctness) -- done d77c22fd; the audit is wrong that "every reference emulator" wraps -- it is 7-3, with vte, tmux and libvterm capping at the row remainder. DanTerm's cap was adopted from libvterm along with its `REP till end of line` fixture, so R6's "invented in-house, the reference check was never made" does not fit this item: the check was made and landed on libvterm. Shipped xterm's answer anyway, since DanTerm advertises TERM=xterm-256color; state-rep-edge.json is now `adapted` with the deviation recorded
- [ ] [PARSE-3](#parse-3) -- Replace both `UInt8(clamping:)` coordinate conversions with one helper that emits xterm's past-end marker (2x5, small, correctness)
- [ ] [SELECT-1](#select-1) -- Or: range-test above 222 and return `[]`, as ghostty and vte do -- adjudicate against PARSE-3 and land one answer (2x5, small, correctness)
- [ ] [PARSE-7](#parse-7) -- Route CHT and CBT through the column-setting primitive HT uses, so the wrap latch has one rule (1x5, small, correctness)
- [ ] [GRID-3](#grid-3) -- Decide whether the side-state policy yields for sequences touching no live grid, and drop `clearPendingMotionState()` from ED 3 (2x3, small, correctness)
- [ ] [INPUT-1](#input-1) -- Forward the button AppKit delivered and delete the physical-vs-reported button map (2x5, small, correctness)
- [ ] [SUPPORT-4](#support-4) -- Give the PATH parent one umask-default mode in both install branches, or record 0700 as a numbered deviation (2x4, small, structural)

### Wave 6 -- Give a display row one owner

Six readers write the history/live seam by hand, two builders materialize the same row, and the frame planner answers row-scoped questions per cell. `GRID-4` is innermost, `GRID-2` sits on it, and `SELECT-3` is a caller of both -- that order is fixed. The planner group (`DRAW-1`, `PROBE-7`, `DRAW-7`, `SELECT-7`, `SELECT-2`) all conflict on `RenderFramePlanner.swift` and land as one pass. This wave has to precede reflow: reflow's fix is stated in terms of a row value that carries its own facts.

- [ ] [GRID-4](#grid-4) -- Collapse `paintedRow` and `materializedGridRow` into one `materializedRow(at:includeFill:)`, shared with `pullBackOpenTailRemainder` (2x5, small, simplification)
- [ ] [GRID-2](#grid-2) -- Put the seam rule and the alternate-screen rule in one private projector that all six readers call (2x5, medium, structural)
- [ ] [SELECT-3](#select-3) -- Hoist `stream[row]` above the column loop in `activationIdentity` and give `explicitLink` a row-scoped cursor (2x5, small, cost)
- [ ] [DRAW-1](#draw-1) -- Delete `row` from the four run types and have `RenderPlanRowSelection` yield `(index, row)` pairs (3x5, medium, structural)
- [ ] [PROBE-7](#probe-7) -- Change `scan(_:limitedToRows:)` to take a `TerminalDamage`, deleting the optional, the force-unwrap and the per-frame set (2x5, small, structural)
- [ ] [DRAW-7](#draw-7) -- Resolve a row's search overlays with one advancing index, and fix the per-row `compactMap` in the same change (2x5, small, cost)
- [ ] [SELECT-7](#select-7) -- Delete `hoveredColumns` and call `columns(for:row:columns:viewportTop:)` at the hover call site (1x5, small, simplification)
- [ ] [SELECT-2](#select-2) -- Delete the unreachable `?? matches.count - 1`, and fold the active range into `.matched` once the change-key is narrowed (2x3, medium, structural)
- [ ] [GRID-5](#grid-5) -- Restate `multiScalarAllocationCount` on the per-spill-table unit and move the retained branch onto it (2x4, small, correctness)

### Wave 7 -- Make reflow carry the whole row

The two 4x5 correctness defects in the audit live here, and both were reproduced against the live engine: a width change destroys committed text under a parked cursor, and a widen erases every background-colored blank on the primary screen. All six items rewrite `reconstructLogicalLines`, `reflowDestination` and `pack`, so they land as one change with two internal halves -- the cursor as a folded logical offset, and the row's non-character facts. It comes after Wave 6 because the row value it needs is the one Wave 6 introduces, and it must be finished before `REFLOW-4` touches the same walk in Wave 14.

- [ ] [REFLOW-1](#reflow-1) -- Fold `contentEnd.column + distance` at the new width instead of clamping it into the last column (4x5, small, correctness)
- [ ] [REFLOW-3](#reflow-3) -- Resolve an all-padding row's cursor as `boundaryOffset + column` folded at the new width, not as `baseRow` (3x5, small, correctness)
- [ ] [REFLOW-5](#reflow-5) -- Hoist `line` onto `.inLine` and split `.trailingPadding` into `pastContentEnd` and `blankRow` behind one guard (2x5, small, structural)
- [ ] [REFLOW-7](#reflow-7) -- Test `last.logicallyContinues == false` in the height-shrink trailing-blank trim (3x5, small, correctness)
- [ ] [REFLOW-2](#reflow-2) -- Give reflow its own content-end rule and pass unfolded rows through the alternate screen's width adjustment (4x5, medium, correctness)
- [ ] [REFLOW-6](#reflow-6) -- Name one `wrapsIntoContinuation` predicate the printer, the packer and both materializers call (2x5, small, structural)

### Wave 8 -- Attach the PTY host's obligations to values

The teardown bound is armed where a human asks to close, and the session sweep uses a per-stage latch, so a child that exits on its own is unbounded and a member that appears late is never signalled. `PTY-6`'s `SessionCensus` is the value the other three hang off, so it leads; `PTY-2`, `PTY-9` and `PTY-8` all conflict with it on `TerminalPTYHost.swift` and land in the same pass. The wave needs Wave 4's shared bootstrap ABI in place and Wave 1's deadline change, so the suite fails for the right reason.

- [ ] [PTY-1](#pty-1) -- Arm `armExitBound()` in the host's `.closeMaster` arm as well as in `beginShutdown` (3x5, small, correctness)
- [ ] [PTY-6](#pty-6) -- Return a `SessionCensus` only `sessionMembers` can mint, stating the session id and the pid count once (2x5, small, simplification)
- [ ] [PTY-2](#pty-2) -- Sweep against the set of pids already signalled at the current stage, not a one-shot latch (2x5, small, correctness)
- [ ] [PTY-9](#pty-9) -- Call `process(.sessionDrained)` in both arms of `signalSession` instead of writing the reducer's queue (1x5, small, simplification)
- [ ] [PTY-8](#pty-8) -- Put a deadline on `killOwnedSession`'s census retry, fall through to the group kill, and correct the comment (2x3, medium, correctness)
- [ ] [PTY-3](#pty-3) -- Route `addFollowSubscription`'s cursor through `cursorPlacement` and return `false` on `.unplaceable` (2x4, small, structural)
- [ ] [PTY-7](#pty-7) -- Hoist the `tcgetattr` to the top of `flushInput` and cache the canonical-oversize answer per head record per `c_iflag` (2x5, small, cost)

### Wave 9 -- Give the reducer one close vocabulary and one owner per rule

`UPDATE-1` is the highest-scoring app defect: an agent waiting for input never notifies a backgrounded app, because the arm restates a suppression rule `paneAlertCommands` already owns. It changes behavior, so put it to the user in the same sitting as the rest. `UPDATE-5` must land before `UPDATE-3`, which must land before `MODEL-5` -- all three conflict on the confirmation vocabulary and are one chain. `MODEL-4` and `MODEL-2` mint the bounded types the persistence wave then relies on.

- [ ] [UPDATE-1](#update-1) -- Delete the agent-waiting arm's focused-pane guard so one rule decides suppression (put the behavior change to the user) (4x5, small, correctness)
- [ ] [UPDATE-5](#update-5) -- Move the emptiness test ahead of the removals in `answerPendingConfirmation`'s `.closeTabs` arm (2x5, small, correctness)
- [ ] [UPDATE-3](#update-3) -- Fold `ConfirmationSubject` into `ConfirmationKind.close(Close)` with a nested per-target payload (2x5, medium, structural)
- [ ] [MODEL-5](#model-5) -- Freeze the names into `DeleteGroupConfirmation` and delete all three dead existence guards from `desiredConfirmation` (1x5, small, simplification)
- [ ] [MODEL-1](#model-1) -- Have `sidebarSequenceOps` report re-inserted ids so `computeSidebarRowOps` skips the tab diff for a remounted group (2x4, small, correctness)
- [ ] [MODEL-4](#model-4) -- Give the split ratio a failable bounded type so `parseSplitNode` rejects an out-of-range persisted number (2x5, medium, structural)
- [ ] [MODEL-2](#model-2) -- Collapse `fontSizeText` to a plain `String` with a `resolveFontSizeDraft` peer, so the core owns the blank-means-no-key rule (1x5, small, simplification)

### Wave 10 -- Persistence and the support seams

Every item here fixes an obligation attached to a call site: a baseline advanced before the write succeeded, a snapshot validated twice, a directory created by a writer for a caller who picked the path in a save panel. `PERSIST-3` and `PERSIST-4` are one change to the same function and land together. `SUPPORT-1` conflicts with them, so it lands after. This wave follows Wave 9 because `PERSIST-2` and `MODEL-4` share `Model.swift`, and it precedes Wave 15's single-structure-file rewrite.

- [ ] [PERSIST-4](#persist-4) -- Pass a completion to the light `checkpointWriter.write` and clear the baseline on failure (2x5, small, correctness)
- [ ] [PERSIST-3](#persist-3) -- Drop the projection compare from `scheduleLightCheckpointIfNeeded`'s guard and delete `retractionIsLive` (2x5, small, cost)
- [ ] [PERSIST-5](#persist-5) -- Hand `AppDelegate` the `ValidatedAppRestore` for `--init`, delete `bootstrapFromSnapshot` and the readerless `snapshot` field (2x5, small, structural)
- [ ] [PERSIST-2](#persist-2) -- Decode `agentSession` lossily in `parseSplitNode` and delete the fatal guard (2x5, small, correctness)
- [ ] [SUPPORT-1](#support-1) -- Take directory creation out of `CheckpointWriter.write` so an export cannot chmod the user's folder to 0700 (3x5, small, correctness)
- [ ] [SUPPORT-2](#support-2) -- Give `DanTermConfigPaths` an explicit home and compose it from `DoctorProbeEnv.homeDirectory` (2x5, small, structural)
- [ ] [SUPPORT-3](#support-3) -- Delete the private `unixSocketAddress` copy and call `PrivateFile.unixSocketAddress`, with its own resolver error (2x5, small, simplification)
- [ ] [SUPPORT-5](#support-5) -- Record the durability level `writeAtomically` actually offers, instead of implying one it does not (2x3, small, correctness)
- [ ] [SUPPORT-6](#support-6) -- Split an oversized IPC batch into `ceil(measured/bound)` parts in one step instead of recursive halving (2x4, medium, cost)

### Wave 11 -- Make the IPC and CLI contracts enforce themselves

The catalog declares a target policy nothing enforces, SKILL.md states protocol constants as ungated prose that has already rotted, and a doctor row hides its identity inside a title that changes with the answer. `CLI-5` makes the policy a projection first; `CLI-4` and `CLI-6` then land as one doctor change. `CLI-3` blocks `IPC-5` and they share the todo path. This wave needs Wave 2's gate rule so the new generated regions are actually checked, and Wave 10's `SUPPORT-2` so `doctor` holds one home.

- [ ] [IPC-1](#ipc-1) -- Answer an IPC decode failure with `writeErrorResponse` on the server and delete the whole `Msg` round trip (3x5, small, structural)
- [ ] [IPC-2](#ipc-2) -- Pass `state.livenessBound` into `writeHello` and omit `silenceSeconds` when it is nil (2x5, small, correctness)
- [ ] [IPC-4](#ipc-4) -- Make `runtimeDispatch` and its init parameter non-optional, with a recording dispatch in the test fixture (1x5, small, structural)
- [ ] [IPC-6](#ipc-6) -- Drop the `text.isEmpty == false` condition in `decodePaneInput` so an empty paste is answered ok (1x5, small, structural)
- [ ] [IPC-3](#ipc-3) -- Take `let descriptor = typedRequest.auditDescriptor` once and pass it to both sites (1x5, small, simplification)
- [ ] [CLI-3](#cli-3) -- Carry a validated non-blank `TodoText` through `todoAdd` and `todoEdit` so a blank edit fails at parse (2x5, small, correctness)
- [ ] [IPC-5](#ipc-5) -- Delete `IpcDispatch.todoJSON` for `IpcEntityEncoder.todo` and replace the four open-coded ok literals with `okResult()` (2x5, small, simplification)
- [ ] [CLI-1](#cli-1) -- Pass the loop's `remaining` into the per-address connect instead of `min(remaining, 1)` (3x5, small, correctness)
- [ ] [CLI-2](#cli-2) -- Close the descriptor when a write stops after emitting a byte, so the seam's promise becomes true (2x4, small, correctness)
- [ ] [CLI-10](#cli-10) -- Hold one read buffer per transport instance, with the single-reader rule restated at the property (2x5, small, cost)
- [ ] [CLI-5](#cli-5) -- Make `targetPolicy` a projection of the route's request method and enforce all three cases in `routeCLIInvocation` (2x5, small, structural)
- [ ] [CLI-4](#cli-4) -- Give `doctor` the `implicitAllowed` policy and print the instance its app-owned rows came from (2x5, medium, structural)
- [ ] [CLI-6](#cli-6) -- Drop `deniedTitle` for one subject-named title per row, and add a `--json` projection carrying stable ids (2x5, small, structural)
- [ ] [CLI-7](#cli-7) -- Add generated, gate-checked regions for SKILL.md's protocol constants and stdout-shape table (2x5, medium, correctness)
- [ ] [CLI-9](#cli-9) -- Move both grid ranges into `DanTermProtocol` constants and interpolate them into the `pane resize` help (2x5, small, structural)
- [ ] [CLI-11](#cli-11) -- Change the `pane zoom` help to name the field SKILL.md tells callers to read (2x5, small, correctness)
- [ ] [CLI-8](#cli-8) -- Add `danterm roster [--follow]`, rendered as JSON Lines by the existing record-stream path (2x4, medium, simplification)

### Wave 12 -- Move the macOS shell's decisions back to their owners

`INPUT-3` is the enabling shape: four correlated optionals become one `PanePresentation`, after which the IME rect, the reported button, a horizontal `columnDelta` and Wave 14's visibility gate all have somewhere to read from. `INPUT-4` and `SELECT-6` are the wheel half of that same value and land together. `CHROME-2` and `CHROME-3` conflict on `SplitContainerView` and its incident test, so they are one container change -- and `CHROME-3` changes behavior for a background program, so put it to the user. `CHROME-1` needs `CHROME-7` already deleted, which Wave 3 did.

- [ ] [INPUT-3](#input-3) -- Fold `currentMetrics`, `currentDimensions`, `currentGridPinned` and `displayedCellSize` into one `PanePresentation` (2x5, medium, structural)
- [ ] [INPUT-2](#input-2) -- Build the IME rect from `publishedFrame?.plan.cursor` and the displayed cell box (2x5, small, correctness)
- [ ] [INPUT-4](#input-4) -- Give `TerminalWheelEvent` a `columnDelta` from `scrollingDeltaX` and emit `.left`/`.right` (2x5, medium, correctness)
- [ ] [SELECT-6](#select-6) -- Clamp the IPC-supplied wheel coordinates against `terminal.geometry` inside `decideTerminalWheel` (1x4, medium, structural)
- [ ] [INPUT-8](#input-8) -- Compute and store the divider grab offset before the double-click early return (1x5, small, correctness)
- [ ] [INPUT-7](#input-7) -- Give `classifyJumpInput` the modifiers, answer `.cancel` for a Command/Control/Option chord, and delete the dead case (1x4, small, correctness)
- [ ] [CHROME-2](#chrome-2) -- Replace `rebuild`/`ensureLaidOut`/`setRootNode`/`setZoomedPane` with one `present(tree:zoomedPaneId:)`, taking zoom in `init` (2x5, medium, structural)
- [ ] [CHROME-3](#chrome-3) -- Gate `setGridDimensions` on the pane's model visibility so a hidden pane submits once at reveal (3x5, medium, cost)
- [ ] [CHROME-5](#chrome-5) -- Carry `alertBadge`/`tabCountBadge` as `Int?` on the projection and give `BadgeLabel` one `apply(_:)` (2x5, small, structural)
- [ ] [CHROME-6](#chrome-6) -- Put `canDrag` on `PaneToolbarRender` and resolve the drag's container through `tabForPane` (2x5, small, structural)
- [ ] [CHROME-4](#chrome-4) -- Move the tab context menu onto the model so the driver's merged record is the only applied-projection record (1x5, small, structural)
- [ ] [CHROME-1](#chrome-1) -- Give the sidebar's collapsed flag and width one model field written only by the reducer, and drive the divider from a projection (3x5, medium, correctness)

### Wave 13 -- iOS: decide in the kit, not in the untested shell

`ios/DanTermMobileApp` has no test target, and it currently owns the hardware-key mapping, the menu predicate and the launch-target rule -- which is why a Shift-only press sends the unshifted byte. `MOBAPP-1` is the shipped bug and leads. `MOBKIT-3` and `MOBKIT-1` are one change at the record edge: decode and lift in `take`, then end the stream where the record is decoded. `MOBKIT-2`, `MOBAPP-2` and `MOBAPP-3` all rewrite the same projection and land as one pass. This wave is independent of the macOS waves and can run in parallel.

- [ ] [MOBAPP-1](#mobapp-1) -- Narrow the hardware character arm to Ctrl/Alt chords and move the press-to-event decision into `DanTermMobileKit` (4x5, medium, correctness)
- [ ] [MOBKIT-3](#mobkit-3) -- Read the `.end` record in `take` and delete `MobileSessionEvent.recordApplied` with its shell dispatch (3x5, small, simplification)
- [ ] [MOBKIT-1](#mobkit-1) -- Decode and lift in one function at the model's edge, so both `receive` arms end the connection on an unreadable record (3x5, small, correctness)
- [ ] [MOBKIT-6](#mobkit-6) -- Make `beginStream` and `send` total by dispatching `.connectionEnded(.deviceSetup)` instead of returning (2x4, small, structural)
- [ ] [MOBAPP-3](#mobapp-3) -- Publish `needsTarget` on `MobileSessionProjection` and reduce `viewDidAppear` to guarding on it (2x5, small, structural)
- [ ] [MOBAPP-2](#mobapp-2) -- Project the session's menu actions as an ordered typed list and enable the overflow button on it being non-empty (2x5, small, structural)
- [ ] [MOBKIT-2](#mobkit-2) -- Store the prepared outline at the two sites that write the roster, and stop `render` building a second projection (2x5, medium, cost)
- [ ] [MOBKIT-4](#mobkit-4) -- Compare the incoming mode in `replicaChanged` and return no action when it is equal (2x5, small, cost)
- [ ] [MOBAPP-6](#mobapp-6) -- Guard both writes in `ConnectionStatusPillView.show` on inequality with what the label holds (1x2, small, cost)

### Wave 14 -- Cost work, now that the instruments run and the shapes hold

Every item here needs a number the tree could not produce before Wave 1, or a shape that Waves 6, 7 and 12 were still moving. `UPDATE-7` leads and is expected to falsify its own claim -- its answer also decides whether `UPDATE-2` takes its ideal or its `tearDownPanes` fallback, so do not touch the reducer's `defer` before it. `REFLOW-4` deletes five structures from the pack walk and only lands if `TerminalResizeProbe --recipe wide` moves. `DRAW-2` is the one large change in the audit and goes last in this wave, on the repaired harness and `DRAW-5`'s total table.

- [ ] [UPDATE-7](#update-7) -- Build the headless probe first and expect it to falsify the per-message sweep claim; change nothing until a number says otherwise (1x3, medium, cost)
- [ ] [UPDATE-2](#update-2) -- Replace the five hand-written teardown rituals with one `tearDownPanes` helper and delete the four dead popover lines (2x5, medium, structural)
- [ ] [MODEL-6](#model-6) -- Replace the three `model.allPanes` loops with `forEachPane` walks and correct the stale scan-cost comment (1x5, small, cost)
- [ ] [MODEL-3](#model-3) -- Hold the `SplitNodeModel` root in `ContainerShape` with a payload-skipping compare, deleting `ContainerLayoutNode` and its `Equatable` (1x5, medium, cost)
- [ ] [REFLOW-4](#reflow-4) -- Carry each tracked cursor as a logical offset resolved during the pack walk, deleting the per-cell destination maps (2x4, medium, cost)
- [ ] [DRAW-9](#draw-9) -- Delete `nominalGlyph`'s two per-call array allocations, and only then measure a coverage-built glyph table (1x3, medium, cost)
- [ ] [DRAW-2](#draw-2) -- Move the eight families' membership predicate into `TerminalSpriteGeometry` and classify a sprite cell as `.band` (3x5, large, cost)

### Wave 15 -- The two large rewrites, after everything else stops moving

Both restructure something many earlier waves write to. `UPDATE-4` classifies 24 `AppModel` fields into a session half and a process half, and it conflicts with `PERSIST-5`, which lands in Wave 10. `PERSIST-1` makes `last-light.json` the only structure on disk and writes it on the exit path; it conflicts with `PERSIST-3`, `PERSIST-4`, `PERSIST-7` and `CHROME-1`, all of which land earlier -- and it must not regress the empty-model quit, which both current proposals do.

- [ ] [UPDATE-4](#update-4) -- Split `AppModel` into session and process halves so `.restoreSession` has no slot to forget a process-scoped field in (3x5, large, correctness)
- [ ] [PERSIST-1](#persist-1) -- Make `last-light.json` the only structure on disk, written on the exit path, with `last-enriched.json` a scrollback-only sidecar (3x5, medium, correctness)

## Combine these

**The headless draw arm: DRAW-3 + PROBE-8.** Both rewrite `PreparedDraw` in two places -- the library copy and the `scripts/` mirror -- and the arm cannot compile until the damage type and the non-optional context land together. `DRAW-3` owns it.

**The DEC private mode table: PARSE-4 + GRID-1 + PARSE-1 + SELECT-4.** All four edit the same three consumers in `Terminal.swift` and `TerminalStateSynchronizationEncoder.swift`. Modes 47 and 1007 exist only once the table does, and `GRID-1`'s three-answer rows are the table's shape for the screen-switch modes. `PARSE-4` owns it; land the roster test that walks every declared raw value in the same commit.

**The gate's missing-target rule: GATE-1 + GATE-5 + GATE-3.** One shared helper, one widened sweep that depends on it, and one symmetric coverage rule that depends on both. Splitting them means writing the helper's call sites twice. `GATE-1` owns it.

**The probe boundary: PROBE-2 + PROBE-3 + PROBE-4.** One parse loop replaces `flagValue` in both CLIs, and the two report types are where that refusal has to end up or the parse fix buys nothing. `PROBE-2` owns it.

**The legacy mouse coordinate: PARSE-3 + SELECT-1.** These are two answers to one question about the same two expressions. Pick one wire behavior with `references/` open, put it in one `legacyMousePositionByte(_:)`, and rewrite the assertion that pins the clamp. `PARSE-3` owns it.

**The wrap latch: PARSE-7 + GRID-3.** Both decide when a sequence that moves no live cell may clear pending motion state, and `GRID-3` is the same policy question one level up. `PARSE-7` owns it.

**The row projector: GRID-4 + GRID-2 + SELECT-3.** One builder, one seam, then the caller that was materializing a row per cell. Landing `SELECT-3` before `GRID-2` would hoist a call that is about to change shape. `GRID-2` owns it.

**The frame planner pass: DRAW-1 + PROBE-7 + DRAW-7 + SELECT-7 + SELECT-2.** All five rewrite `RenderFramePlanner.swift` and the run types beside it; `PROBE-7` is only possible once runs stop carrying `row`. `DRAW-1` owns it.

**Reflow, cursor half: REFLOW-1 + REFLOW-3 + REFLOW-5.** Folding the cursor as a logical offset deletes the clamp, the `distance == 0` conjunction and the `retainedEnd == 0` branch together, and collapses the anchor enum -- which is exactly what `REFLOW-5` is. `REFLOW-1` owns it.

**Reflow, row-facts half: REFLOW-2 + REFLOW-6 + REFLOW-7.** The fill style, the continuation predicate and the trim's line-structure reader are three readings of the same missing row value, in the same three functions. `REFLOW-2` owns it.

**The PTY session census: PTY-6 + PTY-2 + PTY-9 + PTY-8.** `PTY-6` mints the value; the sweep, the enqueue and the retry deadline are what the value makes correct. All four edit `TerminalPTYHost.swift`. `PTY-6` owns it.

**The close vocabulary: UPDATE-5 + UPDATE-3 + MODEL-5.** `UPDATE-5` fixes the ordering, `UPDATE-3` states the vocabulary once, and `MODEL-5` deletes the guards that only existed because retraction had two writers. `UPDATE-3` owns it.

**The light checkpoint: PERSIST-3 + PERSIST-4.** Same function, opposite ends: one deletes the compare in the arming guard, the other adds the completion that advances the baseline. `PERSIST-4` owns it.

**The client transport: CLI-2 + CLI-10.** The reused instance buffer needs a defined release point, which is the close path `CLI-2` adds. `CLI-2` owns it.

**Doctor's identity: CLI-4 + CLI-6, after CLI-5.** Both rewrite `cli/Doctor.swift`'s rows; naming the instance and naming the row are one output change. `CLI-4` owns it, and `CLI-5` lands first so the policy it takes is enforced.

**Todo text: CLI-3 + IPC-5.** The validated `TodoText` and the single ok/todo encoder are the same two functions in `Update.swift` and `IpcDispatch.swift`. `CLI-3` owns it.

**The pane presentation value: INPUT-3 + INPUT-2 + INPUT-4 + SELECT-6.** One folded value, then its three readers -- the IME rect, the horizontal wheel, the clamped wheel cell. Each reader alone would add a fifth correlated optional. `INPUT-3` owns it.

**The container's presentation: CHROME-2 + CHROME-3.** Both rewrite `SplitContainerView`, `Reconcile.swift` and the 2026-08-16 incident test. Doing them apart rewrites that test twice. `CHROME-2` owns it.

**The phone's record edge: MOBKIT-3 + MOBKIT-1.** One decode-and-lift function in `take` both deletes the round trip and gives the failure somewhere to end the stream. `MOBKIT-3` owns it.

**The phone's projection: MOBKIT-2 + MOBAPP-2 + MOBAPP-3.** The prepared outline, the ordered action list and `needsTarget` are three fields on one projection, read by one controller. `MOBKIT-2` owns it.

**The reducer's per-message budget: UPDATE-7 + UPDATE-2.** `UPDATE-7`'s probe decides whether `UPDATE-2` takes its reconcile-pass ideal or its `tearDownPanes` fallback. The two cannot both be right about that budget. `UPDATE-7` owns it.

## Quick wins

Small effort, impact 3 or more, confidence 4 or more. Nine are startable today; the rest are marked with the one item they wait on.

| ID | Fix | Score | Lane |
|---|---|---|---|
| [UPDATE-1](#update-1) | Delete the agent-waiting arm's focused-pane guard, so a waiting agent notifies a backgrounded app | 4x5 | reducer |
| [REFLOW-1](#reflow-1) | Fold the cursor's trailing-blank distance at the new width instead of clamping it | 4x5 | terminal engine |
| [REFLOW-7](#reflow-7) | Test `logicallyContinues` in the height-shrink trailing-blank trim | 3x5 | terminal engine |
| [REFLOW-3](#reflow-3) | Give a cursor on a blank continuation row a row of its own (after REFLOW-1) | 3x5 | terminal engine |
| [GRID-1](#grid-1) | Accept DECSET/DECRST 47 and declare the three switch modes as one table (after PARSE-4) | 3x5 | terminal engine |
| [PARSE-1](#parse-1) | Implement DEC private mode 47 in all three consumers (after PARSE-4) | 3x5 | terminal engine |
| [DRAW-3](#draw-3) | Repair the headless draw benchmark arm and put it in the lint pass | 3x5 | instruments |
| [GATE-1](#gate-1) | Fail any lint whose named target is missing, instead of printing "passed" | 3x5 | gate |
| [GATE-4](#gate-4) | Delete the two wall-clock acceptance thresholds in the PTY suites | 3x5 | gate |
| [GATE-2](#gate-2) | Take the build out from under the PTY lane's 180-second deadline | 3x4 | gate |
| [GATE-3](#gate-3) | Require every tracked lint script to appear in the assembled gate (after GATE-1) | 3x5 | gate |
| [PTY-1](#pty-1) | Arm the teardown bound when the ladder starts, not when a human asks to close | 3x5 | PTY host |
| [SUPPORT-1](#support-1) | Stop `CheckpointWriter` creating the destination's parent, so an export cannot chmod to 0700 | 3x5 | support |
| [IPC-1](#ipc-1) | Answer an IPC decode failure on the server, deleting the whole `Msg` round trip | 3x5 | IPC |
| [CLI-1](#cli-1) | Give the TCP connect the whole caller deadline instead of one second per address | 3x5 | CLI client |
| [MOBKIT-3](#mobkit-3) | Decide a stream's end where the record is decoded, deleting the record round trip | 3x5 | iOS kit |
| [MOBKIT-1](#mobkit-1) | End the stream on an undecodable record instead of skipping it (with MOBKIT-3) | 3x5 | iOS kit |


## Themes

Root causes, from the four synthesis lenses. A theme is worth reading before
its symptoms: fixing the cause retires them together.


### Structure themes

#### S1. A closed vocabulary is re-typed at each consumer instead of declared once as a table, so a case can be missing, half-supported, or unreachable and nothing says so.

_Impact 4/5 -- 21 findings are symptoms._

**Root cause.** DanTerm has many genuine closed vocabularies -- DEC private modes, alternate-screen switch modes, box-drawing patterns, the ANSI palette, kitty keyboard flags, menu commands, split directions, bootstrap stages. Almost none of them is a single declaration that carries every per-case answer; each is an enum (or a bare integer) whose behavior is written out again in every consumer as a switch arm, a stored field, or a hand-applied mask. The compiler checks that each switch is exhaustive over the cases that exist, which is why a case nobody ever added -- DECSET 47, DECSET 1007 -- is absent from all three consumers at once and no build fails. The same gap runs the other way: nothing ties a case to a producer or a reader, so a case with no producer (`JumpInputKind.flagsChanged`), a payload no one reads (`transport(phase:)`), a public field its own initializer overwrites (`RenderTheme.searchMatchBackground`), and a whole dead message chain all survive indefinitely. `IpcRequest` is the counterexample the tree already contains: one catalog, typed decode, and `everyCLIRequestRoundTripsThroughCatalog` forcing one fixture per method -- that lane's construction findings are all landed.

**Combined fix.** Give each vocabulary one table that carries every per-case answer, and make every consumer a projection of it. `DECPrivateMode` gets a declaration table (keypath, DECRQM source, resynchronization source) that `set`, `reset`, DECRQM and `TerminalStateSynchronizationEncoder` all read, with GRID-1's `SwitchScreenMode` rows (saves cursor, clears on entry, clears on exit) as the three-mode case of the same table; `kittyKeyboardFlags` becomes an `OptionSet` that masks in `init`; the palette becomes `InlineArray<16, RenderColor>` and `lineMappings` a total 128-entry array with no nil slot and no trapping default; sprite membership moves into `TerminalSpriteGeometry` as the one predicate the planner and the executor both call; the menu carries `ConfigurableCommand`, the snapshot a raw-valued direction enum, the bootstrap a shared C ABI header. Then generalize the `IpcRequestTests` mechanism into a gate rule: for each of these tables, one test that walks every case and asserts a producer and each declared consumer -- which is what retires the dead-case half without a separate hunt.

Symptoms: PARSE-1, PARSE-4, PARSE-5, GRID-1, SELECT-4, SELECT-5, DRAW-2, DRAW-4, DRAW-5, DRAW-6, DRAW-8, INPUT-4, INPUT-5, INPUT-7, PERSIST-6, PTY-4, MODEL-7, IPC-5, MOBKIT-5, MOBAPP-4, UPDATE-6, CHROME-7

#### S2. A terminal row is not a value: what a row holds and which row it is are re-derived by each reader from cell kinds, defaults, and a loose Int.

_Impact 5/5 -- 17 findings are symptoms._

**Root cause.** The engine stores rows as cell arrays and lets every consumer reconstruct the row-level facts it needs. "Is this row content?" is answered by scanning for `.narrow`/`.wideHead`, so a background-colored blank is not content and a width change erases every themed blank on the primary screen. "What style are this row's blanks?" is answered by `makeBlankRow` at the default style rather than by carrying the row's fill. "Does this row continue the previous one?" is answered three ways -- raw `isSoftWrapped`, `logicallyContinues`, and a `semanticContent` dialect in the packer. "Which row is this?" is answered by an index whose frame (history-inclusive or live-only) each of six readers decides for itself, by a `row` field a run carries next to the array that already is its row, by a `row * columns + column` key two functions must agree on, and by a `Set<Int>` rebuilt from a damage value that already answers the question. The cursor gets the same treatment: parked in trailing blanks it is reduced to a scalar `distance` and then clamped, and on a blank continuation row it has no row identity at all, so it snaps to the head of its logical line. This is the largest correctness cluster in the audit and the only one holding two 4x5 findings.

**Combined fix.** Introduce the row value the code keeps re-deriving, and make it the only currency between the store, reflow, projection and paint. It carries the fill style, the content end, the `logicallyContinues` claim, and its frame. Concretely: one private projector in `Terminal` owns the history/live seam and the alternate-screen rule for all six readers, with `scrollbackRow(at:)` as one of them; `LogicalLineStore.materializedRow(at:includeFill:)` replaces `paintedRow` and `materializedGridRow` and is shared with `pullBackOpenTailRemainder`; `retainedContentEnd` and `pack` carry the row's fill instead of rebuilding at `Terminal.defaultStyleId`, and unfolded rows go through the alternate screen's width adjustment; one `wrapsIntoContinuation` predicate serves the printer, the packer and both materializers; tracked cursors become logical offsets folded at the new width during the pack walk, which deletes `.trailingPadding`, `allPaddingColumn`, `cellDestinations`, `boundaryDestinations` and `sourceKey` together; runs lose `row` and `scan` takes `TerminalDamage`; and the wrap-latch rule lives only in `print` and the one column-setting primitive that HT, CHT and CBT share.

Symptoms: REFLOW-1, REFLOW-2, REFLOW-3, REFLOW-4, REFLOW-5, REFLOW-6, REFLOW-7, GRID-2, GRID-3, GRID-4, SELECT-3, SELECT-7, DRAW-1, DRAW-7, PARSE-2, PARSE-7, PROBE-7

#### S3. Ingress boundaries repair bad input -- clamp it, default it, skip it -- instead of refusing it into a type that cannot hold it.

_Impact 4/5 -- 20 findings are symptoms._

**Root cause.** Every place where an untrusted number, string, or byte enters DanTerm, the code makes the value usable rather than making it impossible. Probe CLIs turn an unparsable flag into the default and then print a well-formed report; a persisted split ratio outside `0...1` is stored and reported raw and repaired with `?? 0.5` at the projection; a mouse coordinate past column 223 is saturated with `UInt8(clamping:)` into a byte that names a different cell; blank todo text is answered `ok`; an undecodable record on the phone is skipped and the replica desynchronizes; an absent bootstrap-failure payload reads as a successful launch; a partial socket write throws something that looks recoverable. The repaired value is then indistinguishable from a real one downstream, which is why the reports, the `?? 0` fallbacks, and the "which denominator is right" questions exist at all. The tree already has the right shape twice -- `PaneGridOverride` fails instead of clamping, and `IpcRequest.decode` is typed-throws -- so this is an unevenly applied rule, not a missing idea.

**Combined fix.** One refusal per ingress, into a type the rest of the code cannot doubt. Replace the can't-fail `flagValue` helper with the positional parse loop the resize and retained-row probes already use, and make the probe recipes and samples non-defaultable so a zero-payload report and a zero-iteration sample stop being constructible. Give the bounded model quantities failable types the way `PaneGridOverride` has one -- `SplitRatio`, `TodoText`, a resolved font-size draft -- so `parseSplitNode`, `todoEdit` and the preferences form all reject at ingress and the `?? 0.5`, the `isFinite` guard and the `nil`-versus-`""` pair disappear. Make the mouse and wheel encoders take a cell already validated against `terminal.geometry`, so an out-of-grid coordinate is not expressible and the legacy branch returns no report instead of a saturated byte. Make every decode name its outcomes rather than lean on `nil`: three-case bootstrap handshake, decode-and-lift at the phone's model edge, lossy per-field decode for the agent session, `cursorPlacement` instead of a trap. Finish with the seams that promise totality -- non-optional `AppRuntimeIpcDispatch`, one caller deadline through the connect loop, a partial write that closes the descriptor, and a search counter folded into the match it counts.

Symptoms: PARSE-3, SELECT-1, SELECT-2, SELECT-6, MODEL-2, MODEL-4, PROBE-2, PROBE-3, PROBE-4, PROBE-5, PROBE-6, PERSIST-2, CLI-1, CLI-2, CLI-3, IPC-4, IPC-6, MOBKIT-1, PTY-3, PTY-5

#### S4. The AppKit and UIKit shells still hold facts and decide rules the pure model should own, so each of those facts has a second, untested copy at the boundary.

_Impact 5/5 -- 19 findings are symptoms._

**Root cause.** The Elm split is real and mostly held: the outbox discipline, `paneLayout` as the sole producer of rectangles, the phone's views holding no session fact. What is left is a ring of small decisions stranded on the wrong side. The sidebar's collapsed flag and width live only in `NSSplitView`, so a menu handler keeps them in step; a badge decides its own visibility and the cell then overwrites it; drag eligibility is computed in an event handler from the selected tab rather than from the pane's own projection; `SplitContainerView` takes the tree and the zoom in two calls, so it exists briefly in a state its tab contradicts; the session view holds one presentation geometry as four independent optionals, so five readers each invent a `?? 0` and the IME asks the view and gets `(0,0)`. On iOS the same line is crossed the other way: the app target -- which has no test target at all -- decides the hardware-key mapping, the menu-offered predicate and the launch-target rule, and the shell is asked to hand applied records back to the model that authored them. Every one of these rules exists twice, and only the copy in the shell runs.

**Combined fix.** Push each decision to the side that already owns the fact, and delete the copy. In the session view, fold `currentMetrics`, `currentDimensions`, `currentGridPinned` and `displayedCellSize` into one optional `PanePresentation` assigned in `synchronizePresentation`, then read the IME rect, the reported button and a new `columnDelta` off it. In the window chrome, give the sidebar's collapse and width one model field written only by the reducer, put `alertBadge`/`tabCountBadge` and `canDrag` on the projections, collapse `rebuild`/`ensureLaidOut`/`setRootNode`/`setZoomedPane` into one `present(tree:zoomedPaneId:)` taking zoom in `init`, gate `setGridDimensions` on model visibility, keep one applied-projection record, and diff container shape against the split tree itself instead of a hand-maintained `ContainerLayoutNode`. On iOS, move the whole press-to-event decision, the ordered session-action list and `needsTarget` into `DanTermMobileKit`, decode-and-lift records at the model edge so `MobileSessionEvent.recordApplied` and its round trip disappear, make `beginStream` and `send` total by dispatching a cause, decide the scroll chrome in `MobileScrollDriver`, and store the prepared outline where the roster arrives. Answer an IPC decode failure on the server rather than routing a protocol constant through the model to get it back.

Symptoms: CHROME-1, CHROME-2, CHROME-3, CHROME-4, CHROME-5, CHROME-6, INPUT-1, INPUT-2, INPUT-3, INPUT-8, MOBAPP-1, MOBAPP-2, MOBAPP-3, MOBKIT-2, MOBKIT-3, MOBKIT-4, MOBKIT-6, IPC-1, MODEL-3

#### S5. An obligation or an identity is attached to a call site rather than to the value that owns it, so a path that skips it is an ordinary path.

_Impact 5/5 -- 18 findings are symptoms._

**Root cause.** The defects that remain in the reducer, the persistence runtime and the PTY host sit at the *ends* of lifecycles, and they share one shape: the thing that must happen is written at the site that happens to be looked at, not attached to the state it protects. The teardown bound is armed in `beginShutdown` because that is where a human asks to close, so a child that exits on its own is unbounded; the session sweep uses a per-stage latch, so a member that appears after the sweep is never signalled; `.sessionDrained` is written straight into the reducer's queue at one call site; pane teardown is a three-step ritual repeated by hand at five removal sites; `.restoreSession` carries a hand-written list of surviving fields that is silently short of three; the quit question is asked after the batch close already removed the tabs; the light checkpoint advances its baseline whether or not the write succeeded; the structure is written on some paths but not the exit path, and a comment picks the winner between two files. The identity version of the same thing: `CheckpointWriter.write` creates the destination's parent for every caller including the one whose URL the user picked in a save panel, and the doctor probe derives its config path from a different home than the one it holds.

**Combined fix.** Make each obligation a property of a value with one writer. Split `AppModel` into a session half and a process half so `.restoreSession` has no slot for a process-scoped field to be forgotten in; replace the five teardown rituals with one `tearDownPanes` pass whose only authority is the tree; fold `ConfirmationSubject` into `ConfirmationKind.close(Close)` so the close vocabulary and its retraction rule are stated once in the reducer's `defer`, and move the emptiness test ahead of the removals. In the PTY host, arm `armExitBound()` where the ladder starts rather than where a human asks, return a `SessionCensus` that only `sessionMembers` can mint and sweep against the set of pids already signalled, put a deadline on the census retry, and enqueue through `process`. In persistence, make `last-light.json` the only structure on disk written on the exit path, advance the baseline only from a write completion, and carry the already-validated restore into bootstrap instead of validating twice. Finally take directory creation out of `CheckpointWriter` and give `DanTermConfigPaths` an explicit home, which is the ambient-identity invariant the ADR already states.

Symptoms: PTY-1, PTY-2, PTY-8, PTY-9, UPDATE-1, UPDATE-2, UPDATE-3, UPDATE-4, UPDATE-5, MODEL-1, MODEL-5, PERSIST-1, PERSIST-3, PERSIST-4, PERSIST-5, SUPPORT-1, SUPPORT-2, IPC-3

#### S6. A statement about the system is a separate artifact from the mechanism that enforces it, so the two drift and the statement is the one people read.

_Impact 4/5 -- 20 findings are symptoms._

**Root cause.** DanTerm has an unusually good pattern for this and applies it in exactly one place: `DanTermSkillSynopsisGenerator --check` makes the SKILL.md command synopsis a gate-checked projection of the catalog. Everywhere else, the statement is hand-written next to the thing it describes. The catalog declares a `targetPolicy` that `routeCLIInvocation` does not enforce; the `pane resize` help states a grid bound that lives as a range in another module; SKILL.md states protocol constants as prose beside a generated region that could carry them; a doctor row states its result inside its title, so a script can only find it by text that changes with the answer. The gate has the same gap one level up: three lints print a green line when the file they name has been renamed away, nothing checks that a lint script runs over the tree rather than only its self-test, and the headless draw benchmark -- the tool this whole render lane would be measured with -- has not compiled since `13db5f73` because no step builds it. And several claims have no enforcement to drift from at all: a doc comment promising durability the write does not have, a census comment claiming a whole session was signalled, a census field whose doc names a different unit than either branch counts, a plist key naming a scene delegate the compiler also names, a `terminate()` return value production deliberately disobeys, two wall-clock assertions standing in for a property a counter already carries.

**Combined fix.** Generalize the one working mechanism and delete the claims that cannot get one. Extend the generated, gate-checked region pattern from the synopsis to the protocol constants, the stdout-shape table, and the two grid ranges hoisted into `DanTermProtocol` as public constants interpolated into the help string; make `targetPolicy` a projection of the route's request method and enforce all three cases in `routeCLIInvocation`; drop `deniedTitle` so a doctor row has one subject-named title plus a stable id, add `--json`, and give `doctor` the `implicitAllowed` policy so it names the instance it queried. For the gate, promote `terminal-fence-accounting-lint.sh`'s `setup_fail` into a shared `scripts/lib` helper that reddens any lint whose named target is missing, extend `gate-test-coverage-lint.py` with the symmetric rule that every tracked lint script appears as a command word in the assembled gate or carries a written opt-out, widen `checkpoint-off-main-lint` to the whole `app/` tree, add the draw arm as a type-check-only build, and take the build out from under the PTY lane's deadline. Then delete the unenforceable statements outright: the durability promise, the census comment, the miscounted census unit, the plist key, the returned terminate action, the empty `Msg` arm, and the two elapsed-time thresholds, whose property `forcedQuiescenceCount == 0` already carries.

Symptoms: GATE-1, GATE-2, GATE-3, GATE-4, GATE-5, GATE-6, CLI-4, CLI-5, CLI-6, CLI-7, CLI-9, CLI-11, DRAW-3, GRID-5, SUPPORT-3, SUPPORT-4, SUPPORT-5, MOBAPP-5, UPDATE-9, IPC-2, PERSIST-7

Not themed: PARSE-6, and the pure-cost findings CLI-10, PTY-7, DRAW-9, SUPPORT-6, PROBE-1, MODEL-6, UPDATE-7, UPDATE-8, INPUT-6, MOBAPP-6, CLI-8 -- these are arithmetic, allocation, or capability gaps, and their own write-ups say so; forcing them under a modeling cause would be invention.

### Cost themes

#### C1. No cost question in this tree can be settled where it is asked: the instruments live outside the gate, and three probes accept inputs that void their own reports.

_Impact 4/5 -- 11 findings are symptoms._

**Root cause.** The benchmark arms and probes are the only things that can price a change, and nothing in `just test` or `just lint` compiles `scripts/`, so the headless draw arm silently stopped building at `13db5f73` when `drawRenderFrame` swapped `rows: [Int]?` for `restrictedTo: TerminalDamage?`. The probe CLIs share a `flagValue` helper that cannot fail, so a mistyped flag becomes the default; the memory probe then prints a zero-payload report and exits 0, and the occupancy probe divides by an iteration count it never validated. The browse benchmark puts its own instrument inside the timed bracket, and two lints print "passed" over a target that is not there. The effect is visible all through the corpus: DRAW-2 and DRAW-9 are blocked on a harness that does not build, and MODEL-3, MODEL-6, UPDATE-7 and MOBKIT-2 all say in their own words that no workload on the ladder drives the path they are about. So the work of deciding "is this expensive?" scales with the whole tree rather than with the change, which means it is not done, and the cost stays.

**Combined fix.** Make the gate own every instrument, and make an instrument unable to report what it did not measure. Store `TerminalDamage` in both copies of `PreparedDraw` with a non-optional context, and add `scripts/terminal-headless-draw-arm.swift` to `scripts/run-test-suite.sh` as a typecheck-only build (DRAW-3, PROBE-8). Replace `flagValue` with the positional parse loop the resize and retained-row probes already use (PROBE-2), then push the inputs into the report types so the invalid state is unrepresentable: validate geometry before any payload is built, make `OccupancySample` hold at least one measurement by construction, carry `payload` and `sampleCount` in `ResizeProbeReport`, and derive `retainedRowCount` from `storedCellCounts.count` (PROBE-3, PROBE-4, PROBE-5, PROBE-6). Hoist `planCellCoverage` out of `measureBrowsingPlan`'s bracket (PROBE-1). Then close the gate itself: a shared `scripts/lib` helper that fails any lint whose named target is missing (GATE-1), the symmetric rule in `gate-test-coverage-lint.py` that every tracked lint appears as a command word in the assembled gate (GATE-3), and the `swift build --build-tests` moved out from under the PTY lane's 180-second deadline so the guard bounds a wedged test and not a cold compile (GATE-2).

Symptoms: DRAW-3, PROBE-8, PROBE-1, PROBE-2, PROBE-3, PROBE-4, PROBE-5, PROBE-6, GATE-1, GATE-3, GATE-2

#### C2. A window drag is priced against every pane that exists and every cell it holds, because nothing pairs a pane's geometry with whether anyone can see it.

_Impact 4/5 -- 3 findings are symptoms._

**Root cause.** Every tab's container autoresizes with the content area and `SplitContainerView.layout()` re-solves the model layout on every AppKit pass, hidden or not. `setFrameSize` then calls `synchronizePresentation`, which submits a derived grid whenever the cell-boundary answer changes; it gates on a torn-down view, non-zero bounds and a window, and never on visibility. The authority is already there -- `syncPaneVisibility` pushes `session.setVisible(_:)` to every host -- but `setGridDimensions` ignores it, so a 300pt drag with twelve tabs open sends roughly forty submissions per hidden pane, and each one runs `TerminalPTYHost.applyResize`: `TIOCSWINSZ` and then a full `terminal.resize`, a reflow of that pane's whole scrollback inside DanTerm. The gate is awkward to add today because a pane's presentation is four correlated optionals (`currentMetrics`, `currentDimensions`, `currentGridPinned`, `displayedCellSize`) rather than one value. And each reflow that does happen allocates per live cell -- one `[GridCell]`, one `sourceOffsets` array, one `Set` insert, one dictionary insert -- to answer eleven questions: two tracked cursors and nine anchors.

**Combined fix.** Fold the four optionals into one `PanePresentation` assigned in `synchronizePresentation` (INPUT-3), then add the model-visibility gate to that folded value so a hidden pane records its geometry and submits exactly once at reveal (CHROME-3). That rewrites the hidden arm of the 2026-08-16 incident test in `tests-ui/SplitContainerViewTests.swift`, and it is a real behavior change -- a background program learns the new size at reveal, as under tmux -- so put it to the user rather than slipping it in. Inside the engine, carry each tracked cursor as a logical offset and record its destination when `pack`'s own running offset reaches it, deleting `cellDestinations`, `boundaryDestinations`, `retainedSourceKeys`, `sourceKey` and `ReflowUnit.sourceOffsets` (REFLOW-4, after the REFLOW-1/3/5 correctness fixes, and only if `TerminalResizeProbe --recipe wide` moves).

Symptoms: CHROME-3, INPUT-3, REFLOW-4

#### C3. A display row has no cheap form and no single owner, so a reader that wants one cell materializes a whole row -- once per cell.

_Impact 3/5 -- 4 findings are symptoms._

**Root cause.** `ProjectionRows`'s subscript is not an index: for a history row it binary-searches blocks and then paints the row, and both `paintedRow` and `materializedGridRow` build a throwaway `[GridCell]`, then a second array of default cells, then re-place every cell -- two allocations and two passes, with a third copy of the same builder in `pullBackOpenTailRemainder`. Two link paths call that subscript from inside a per-column loop, and `explicitLink` also materializes the whole soft-wrap chain into a `coordinates` array and finds the click in it with `firstIndex(of:)`. One module out, the frame planner shows the same shape on a different row-scoped fact: it answers "which match covers this column?" with a linear scan of the row's matches per cell, and re-projects every viewport match once per replanned row. Under all of it, the seam rule -- the last retained row is projected against the live grid's first cell -- is written out by hand at six sites, because no projector owns it and a stream row means two different things depending on the reader.

**Combined fix.** One builder, one seam, one cursor. Collapse `paintedRow` and `materializedGridRow` into `materializedRow(at:includeFill:)` that appends and places inside the fold walk, and share that builder with `pullBackOpenTailRemainder` (GRID-4). Put the seam rule and the alternate-screen rule in one private `projectedStreamRow` plus its cell-scoped twin that all six readers call, keeping the public `scrollbackRow(at:)` -- which `TerminalRetainedRowProbeSupport` needs -- as one of them (GRID-2). Then fix the callers: hoist `let projected = stream[row]` above the column loop in `activationIdentity`, give `explicitLink`'s expansion a row-scoped cursor that re-fetches only at a soft-wrap boundary, and carry one advancing index into the row's already-ascending match spans in `overlayState`, fixing the per-row `compactMap` in the same change (SELECT-3, DRAW-7). Order matters: GRID-4 is innermost, then GRID-2, then the two callers.

Symptoms: GRID-4, GRID-2, SELECT-3, DRAW-7

#### C4. The larger unit of work exists in the code but not as a value, so every inner call re-pays the setup the unit already established.

_Impact 3/5 -- 5 findings are symptoms._

**Root cause.** `flushInput` owns a write turn, but calls `prepareCurrentInputRecordForWrite` per loop iteration, which opens with an unconditional `tcgetattr` and, in canonical mode, re-runs `CanonicalInputDeliveryGate.isOversized` over the whole remaining tail -- so a multi-megabyte paste into a canonical reader scans quadratically on the owner queue that the render fence and every actor call wait behind. Both client transports own a connection with a single reader guaranteed by the session's `readLock`, yet allocate and zero a fresh 64 KiB buffer per `receive()`. `writeGroup` owns a batch: it learns the batch is over the 16MB frame bound by encoding it, throws that encode away, halves, and pays `(k+1) * N`. The packaged symbols face owns a coverage set, but resolves and measures a glyph per cell per frame while its four styled siblings resolve their tables once at construction. `IpcServer.dispatch` owns a request and computes `typedRequest.auditDescriptor` twice for a remote audited one. Each is the same missing value: nothing holds what the unit already knows, so the inner call re-derives it.

**Combined fix.** Hoist each invariant onto the unit that owns it. Read `termios` once at the top of `flushInput` and pass it down, and cache the canonical-oversize answer per head record per `c_iflag`, which the suffix argument makes sound -- the scan is the finding, the syscall is tidiness (PTY-7). Hold one `[UInt8]` on each transport instance with the single-reader rule restated at the property, released on the close path CLI-2 adds (CLI-10). Measure the encoded batch once and cut it into `ceil(measured / bound)` parts in one step, capping the cost at `2N` without any pre-encoded-bytes plumbing (SUPPORT-6). Delete `nominalGlyph`'s two per-call arrays, and only then measure whether a glyph-plus-bounds table built from `CTFontCopyCharacterSet`'s real coverage is worth its memory (DRAW-9). Take `let descriptor = typedRequest.auditDescriptor` once and pass it to both sites (IPC-3).

Symptoms: PTY-7, CLI-10, SUPPORT-6, DRAW-9, IPC-3

#### C5. Nothing carries what an event changed, so each consumer answers "did anything change?" by rebuilding the whole derived state and comparing it.

_Impact 3/5 -- 7 findings are symptoms._

**Root cause.** Every `send()` ends in `scheduleLightCheckpointIfNeeded`, which builds a complete `AppModelSnapshot` and deep-compares it against a baseline only to decide whether to arm a 2 s timer -- and the tree already grew `retractionIsLive` as a workaround to keep typing out of that path. The same habit runs through the reconcile sweep: `desiredContainerShapes` rebuilds a parallel `ContainerLayoutNode` tree per tab so `computeContainerOps` can diff it, three projections flatten `model.allPanes` into fresh arrays, and `update()`'s `defer` allocates two `Set<TabId>` and scans up to 100 alerts on every message before its early return. On the phone it repeats twice more: `projection(at:)` re-prepares every group, tab and pane title from the raw roster on each read -- twice per redraw -- and `MobileScrollDriver.replicaChanged` reflects the chrome after every published frame whether or not the mode moved. The audits knock most of the individual numbers down, so this is not a recovered millisecond; what is real is that the derived form is never the stored authority, so equality is always tested by reconstruction, and each new consumer inherits that.

**Combined fix.** Move each comparison to the one place that writes, and let a stored derived value be the authority. Drop the projection compare from `scheduleLightCheckpointIfNeeded`'s guard -- `performLightCheckpoint` already compares through `lightCheckpointCapture(current:baseline:)` at fire time -- and delete `retractionIsLive` with it (PERSIST-3). Hold the `SplitNodeModel` root in `ContainerShape` with a payload-skipping `sameContainerLayout`, deleting `ContainerLayoutNode` and `ContainerShape: Equatable` together (MODEL-3), and replace the three `model.allPanes` loops with `forEachPane` walks (MODEL-6). On the phone, store the prepared `MobilePaneOutline` at the two sites that write the roster and delete the raw list, and pass the already-built projection into `showArrowPad` / `layoutArrowPad` first as the cheap half (MOBKIT-2); compare the incoming `MobileScrollMode` in `replicaChanged` and return no action when equal (MOBKIT-4); guard both writes in `ConnectionStatusPillView.show` (MOBAPP-6). Build UPDATE-7's headless probe before touching the reducer's `defer` at all, and let its answer also decide UPDATE-2's ideal against its `tearDownPanes` fallback -- the two cannot both be right about that budget.

Symptoms: PERSIST-3, MODEL-3, MODEL-6, MOBKIT-2, MOBKIT-4, MOBAPP-6, UPDATE-7

### Correctness themes

#### R1. When a rule already has an owner, the caller restates it inline, and the inline copy is the one that runs.

_Impact 5/5 -- 10 findings are symptoms._

**Root cause.** `paneAlertCommands` owns "do not alert for the pane the user is looking at" and suppresses only while the app is *active*; the agent-waiting arm restates the test without the `isAppActive` half and returns first, so the owner's version is dead for that caller and the highest-value notification DanTerm can send is the one that never fires. `closeTabBody` asks the quit question before removing anything, while the `.closeTabs` arm restates the same rule after the removals, so cancelling the second prompt leaves a window with zero tabs. `GridRow.logicallyContinues` is documented as what every line-structure reader consumes in place of `isSoftWrapped`; the height-shrink trim is the last reader still on the raw claim, and it scrolls a visible content row into scrollback. The same shape repeats at every layer: HT leaves the wrap latch alone while CHT/CBT route through a primitive that clears it, `writeHello` reads the server-wide silence bound while `startReading` arms the per-connection one, `armExitBound` is armed by the human who asked to close rather than by entering the ladder, the badge decides its own visibility and the cell overwrites it, and the history/live seam predicate is written out by hand at six readers. The rule is never wrong where it is stated once; it is wrong in the copy, and nothing makes the copy fail.

**Combined fix.** At each site make the owner the only writer and delete the copy rather than align it: drop the agent-waiting arm's focused-pane guard so `paneAlertCommands` is the single suppression gate (put the behavior change to the user first); move the emptiness test ahead of the removals in `answerPendingConfirmation`'s `.closeTabs` arm; change the trim to `last.logicallyContinues == false`; route CHT and CBT through the same column-setting primitive HT uses; pass `state.livenessBound` into `writeHello` and let `IpcHello.params` omit `silenceSeconds` when it is nil; arm `armExitBound()` in the host's `.closeMaster` command arm as well as in `beginShutdown`; mint a `SessionCensus` that only `sessionMembers` can produce so no consumer re-filters by `getsid`. Then collapse the two structural duplicates the rest sit on: one private `Terminal.projectedStreamRow(_:at:)` plus its cell-scoped twin that all six seam readers call, and one `LogicalLineStore.materializedRow(at:includeFill:)` behind `paintedRow` and `materializedGridRow`.

Symptoms: UPDATE-1, UPDATE-5, REFLOW-7, PARSE-7, PTY-1, PTY-6, IPC-2, CHROME-5, GRID-2, GRID-4

#### R2. Reflow keeps a row's characters and rebuilds every other fact from a default, and every resize test asserts only characters.

_Impact 5/5 -- 5 findings are symptoms._

**Root cause.** `retainedContentEnd` scans for `.narrow`/`.wideHead` only, `pack` seeds each packed row from `makeBlankRow` at `Terminal.defaultStyleId`, and `resizeWidth` recreates every trailing row the same way, so a width change carries the text and drops the fill style -- while the alternate screen, which goes through `resizedRectangle`, keeps its colors, so the two screens disagree about what a resize does. The cursor gets the same treatment: parked in trailing blanks it is reduced to a scalar `distance` and then clamped into the last column instead of folded at the new width, and on an all-padding continuation row it loses its row entirely and resolves to `baseRow`. Both were reproduced against the live engine: `"abcd" CSI 6G` narrowed to four columns destroys the committed `d`, and `\e[41m\e[2J` widened by one erases the whole painted screen. Nothing caught either, because `TerminalResizeTests`, `TerminalLogicalLineFoldTests` and `TerminalPromptAnchorResizeSweepTests` assert projected text plus a cursor position that the clamp makes look plausible. There is no oracle over the facts that are not characters, so the anchor enum has grown two payloads (`allPaddingColumn`, `distance`) that exist only to smuggle a row-local fact past an anchor that already lost the row.

**Combined fix.** One change across `reconstructLogicalLines`, `reflowDestination` and `pack`. Carry each tracked cursor as a logical offset within its line and fold it (`row += desired / columns`, `column = desired % columns`, with `column == columns` spelled as `columns - 1` plus `isPendingWrap`), which deletes the `min(...)` clamp, the `distance == 0 &&` conjunction and the `retainedEnd == 0` branch together, and collapses `ReflowCursorAnchor` to `cell(key:)` and `boundary(offset:)` with `line` hoisted onto `.inLine`. Give the reflow its own content-end rule -- last cell with a visible effect, text *or* a non-default style id -- leaving `retainedContentEnd` on the text-only rule its other readers need; pass rows past `lastSourceRow` through `resizedRectangle`'s truncate-and-pad instead of reconstructing them; seed a packed row's fill style from the source row that started the line; and name one predicate for which line kinds wrap into a `.continuation` row that the printer, `pack`, and both `LogicalLineStore` materializers call. Pin it with assertions over `cell(row:column:)?.style.background` and the public cursor across a width change on both screens.

Symptoms: REFLOW-1, REFLOW-2, REFLOW-3, REFLOW-5, REFLOW-6

#### R3. No seam in this tree can refuse: an input that does not fit is repaired into a plausible value, and an operation that could not be performed returns the shape of one that succeeded.

_Impact 4/5 -- 13 findings are symptoms._

**Root cause.** The split ratio enters from a snapshot as a bare `CGFloat` and is repaired only at the layout projection, so a persisted `70` draws as a clamped split while `danterm ls` reports `70` and every later checkpoint writes `70` back -- the repair hides the bad value from the reader that fixed it and from nobody else. The probe CLIs' `flagValue` collapses "flag absent", "value missing" and "value unparsable" into one `else { return fallback }`, so `--columns eighty` prints a header naming the default; `runMatrix` `compactMap`s away a geometry the engine rejected and emits a well-formed schema-2 artifact carrying `"payloads": []` beside `"cellStrideBytes": 0` at exit 0; `OccupancySample` turns no measurements into a full set of zeros whose footer then claims the queue is "faster than this probe can time". `readBootstrapFailure` returns `nil` for both "the child exec'd" and "the child died without saying why". The light checkpoint advances `lightCheckpointBaseline` before the write and passes no completion, so a failed write is never rewritten. The phone skips a record it cannot decode, which leaves the replica's cursor one behind, which reports `.streamDesynchronized` -- the one failure whose `preservesResumePosition` is false -- so one malformed record discards the user's scrollback and blames the Mac.

**Combined fix.** Give each boundary a value that carries the refusal. Mint bounded types at admission: `SplitRatio` (failable, finite, `0...1`, `parseSplitNode` falls back to `.half`, `normalizedRatio` deleted) and `TodoText` (non-blank, carried by `todoAdd` and `todoEdit` alike so `editTodoText`'s `!trimmed.isEmpty` guard goes), and clamp the IPC-supplied wheel coordinates against `terminal.geometry` inside `decideTerminalWheel`. Replace `flagValue` in both probe CLIs with the positional parse loop the resize and retained-row probes already use (`exit(2)` on an unknown flag, a missing value, an unparsable value, or one outside the probe's range), validate the geometry in `runMatrix` before any payload is built so a zero-payload report is unconstructible, make `OccupancySample` hold at least one measurement by construction, and make `readRetainedRowShape` return nil on the first unreadable row with `retainedRowCount` derived from `storedCellCounts.count`. Turn the two-valued returns into three: `execSucceeded` / `failed` / `truncated` from `readBootstrapFailure`, with `truncated` mapped to `.systemError(EPROTO)`; a completion on the light `checkpointWriter.write` that sets `lightCheckpointBaseline = nil` on failure; one decode-and-lift function at the phone's edge whose failure is `end(with: .deviceSetup, ...)` for both `receive` arms; `SocketDescriptorLifetime.close()` when a write stops after emitting a byte; and `.matched(selected:total:)` built from `resolved` so the unreachable `?? matches.count - 1` disappears.

Symptoms: MODEL-4, SELECT-6, CLI-3, IPC-6, PROBE-2, PROBE-3, PROBE-4, PROBE-6, PTY-5, PERSIST-4, MOBKIT-1, CLI-2, SELECT-2

#### R4. What gets tested is decided by which directory the code sits in, and the gate cannot tell a check that passed from one that never ran.

_Impact 4/5 -- 11 findings are symptoms._

**Root cause.** `just test` compiles and runs `lib/`; it does not compile `scripts/`, it excludes `tests-ui` because that needs a WindowServer, `ios/DanTermMobileApp` has no test target at all, and the `app/` code behind `-DDANTERM_TERMINAL_BENCHMARK` is compiled by no test target in the tree. Every one of those places has accumulated wrong behavior with nothing to report it: the phone's `pressesBegan` makes the hardware-key decision in the untested shell and sends the unshifted byte for every Shift chord, `MobileSessionController`'s two effect interpreters return silently so the model waits forever for a response, the headless draw arm -- the instrument every DRAW cost finding names as its experiment -- has not compiled since `13db5f73` and its mirrored `PreparedDraw` frees the bitmap before releasing the context, and the sidebar's collapse and width live only in `NSSplitView`, outside the model, the snapshot and the CLI. The gate has the same hole one level up, which is why none of this surfaced: three lints print their success line and exit 0 when `rg` cannot find the path they name, `gate-test-coverage-lint.py` requires every self-test to appear in the assembled gate but makes no claim that the lint itself runs over the tree, SKILL.md's protocol constants are ungated prose that has already rotted to `"version":3` against a constant of 6, and two PTY tests assert an elapsed duration where a counter production maintains already carries the fact.

**Combined fix.** Close the gate's blind spots first, because they are what let the rest happen: promote `terminal-fence-accounting-lint.sh`'s `setup_fail` into a shared `scripts/lib/lint-targets.sh#lint_require_targets` (accepting a directory as well as a file) and source it from every lint that names a subject; extend `gate-test-coverage-lint.py` with the symmetric rule that every tracked `scripts/*-lint.{sh,py}` and `scripts/*-gate.{sh,py}` appears as a command word in the assembled gate or carries `# gate: opt-out`; repair the draw arm to store a `TerminalDamage` and pass it as `restrictedTo:`, then add it to `LINT_STEPS` as a type-check-only build; give SKILL.md generated, gate-checked regions for the protocol constants and the stdout-shape table (projected from `CLICommandCatalog` plus each route's `CLIOutputMode`); and delete the two `elapsed <` assertions in the PTY suites, leaving `forcedQuiescenceCount == 0` against the real 2-second bound. Then move the decisions out of the untestable targets into ones with suites: the whole press-to-event mapping into `DanTermMobileKit` as one pure function (a named key always dispatches; a character dispatches as a chord only under Ctrl or Alt), the two dropped shell effects into `dispatch(.connectionEnded(.deviceSetup))`, and the sidebar's `collapsed`/`width` into one model field written only by the reducer and driven through a projection.

Symptoms: MOBAPP-1, MOBKIT-6, DRAW-3, PROBE-8, GATE-1, GATE-3, GATE-4, GATE-6, CLI-7, CHROME-1, UPDATE-9

#### R5. Closed vocabularies are declared once but answered once per consumer, so a member nobody enumerated is indistinguishable from one the terminal refuses on purpose.

_Impact 4/5 -- 8 findings are symptoms._

**Root cause.** `DECPrivateMode` is a `UInt16`-raw-valued enum answered by three exhaustive switches -- `applyDECPrivateModes`, `decPrivateModeStatus`, and `appendControlState` -- and the setter drops an unlisted raw value with `else { continue }`. Exhaustiveness protects only members that were written down; nothing states what the enum is supposed to cover, so an omission produces silence in all three consumers at once and no failure anywhere. That is exactly how mode 47 and mode 1007 are both absent: a program that hardcodes the legacy `smcup` paints its full-screen UI onto the primary grid and into scrollback, a program that resets alternate scroll still gets synthetic arrow keys injected, and `DECRQM` answers "not recognized" for both. The same shape recurs wherever a closed set is transcribed per reader rather than declared as data: kitty keyboard flags are a bare `UInt16` masked by hand at each writer, the bootstrap stage ordinal is a hand-written `8` on the Swift side of a C enum whose reordering silently breaks the cwd fallback chain, the split direction is an enum on both ends and a re-parsed `String` in between, and the eight sprite family ranges are transcribed a second time inside the render planner, where the missing branch prices every box-drawing row at the pre-T14 full-cell halo.

**Combined fix.** Give the seven plain-Bool DEC private modes one declaration as data -- `(rawValue, WritableKeyPath<TerminalModes, Bool>)` -- and derive set, reset, DECRQM and state resynchronization from it, keeping explicit arms only for the nine that are not a plain Bool. Land GRID-1's `SwitchScreenMode` value carrying each mode's three answers (saves cursor, clears on entry, clears on exit) as the table's rows for 47/1047/1049 on ghostty's and xterm's clear edges, and `alternateScroll = 1007` as one more row read by `wheelRoute`. Add the roster test the table makes cheap: walk every raw value DanTerm claims through `CSI ? N h` -> `CSI ? N $ p` -> `stateSynchronization()`. Then apply the same move to each remaining second transcription -- a `TerminalKittyKeyboardFlags: OptionSet` whose init masks to the supported set once, a shared C ABI target declaring `bootstrap_stage` and `bootstrap_failure` that `TerminalPTYHost` imports, a `String`-raw-valued snapshot direction enum, and the exact-membership sprite predicate moved into `TerminalSpriteGeometry` where both `FramePlanner.plan` and `drawTextRuns` call it.

Symptoms: PARSE-1, GRID-1, SELECT-4, PARSE-4, PARSE-5, PTY-4, PERSIST-6, DRAW-2

#### R6. A behavior invented in-house was written into a plan and pinned by a test, and the reference check that would have caught the divergence was never made.

_Impact 3/5 -- 6 findings are symptoms._

**Root cause.** AGENTS.md makes `references/` the authority on compatibility, but nothing forces a reference read at the moment a behavior is chosen, so several rules were decided from first principles, recorded as policy, and pinned by an assertion. REP's row cap is written into `plans/impl/2026-07-18-1751-terminal-modes-tabs-saved-cursor-reset.md` as "repetition never wraps" and pinned by `TerminalRepeatTests`, while xterm, ghostty and foot all loop the raw count through their ordinary print path. The X10 mouse clamp is pinned by a case titled "X10 encodes ... bounded coordinates" asserting `0xFF, 0xFF` for column 300, where xterm emits a `0x00` past-end marker and ghostty and vte send nothing at all. `CSIEraseTests.eraseDisplayScrollback`'s title says ED 3 clears "pending motion state" and the slice-wide side-state policy states it twice, while all three references leave the wrap latch alone for a sequence that touches no live cell. A control-click is reported to a mouse-claiming program as button 2 by a deliberate `tests-ui` case, where ghostty returns nil from `menu(for:)` precisely so it reaches the program as button 0 with the Control bit. Each fix therefore has to delete an assertion whose preamble argues against it, which is why none has been made.

**Combined fix.** Adjudicate the divergences as one decision with the references in front of the user, then land the behavior and rewrite the assertion in the same commit. Delete the two capping expressions in `repeatLastPrintedCluster` and loop the requested count through `print`; pick one wire answer for an unencodable legacy mouse coordinate -- xterm's `0x00` marker or ghostty's and vte's silence -- and put it in one `legacyMousePositionByte(_:)` used for both axes, replacing three `UInt8(clamping:)` calls; decide whether the slice-wide side-state policy yields for a sequence that names no live-grid state and, if so, drop `clearPendingMotionState()` from `eraseDisplay` case 3; and forward the button AppKit delivered, deleting `PhysicalPointerButton` and the physical-vs-reported map. Where DanTerm keeps its own answer -- the 0700 PATH parent, whose test preamble states the choice on purpose -- record it as a numbered deviation beside D1-D6 naming the reference it departs from, so the next reader can tell a decision from an oversight without re-running the comparison.

Symptoms: PARSE-2, PARSE-3, SELECT-1, GRID-3, INPUT-1, SUPPORT-4

### Process themes

#### P1. A check that cannot find its subject still prints a success line, so "green" only means nothing objected.

_Impact 4/5 -- 10 findings are symptoms._

**Root cause.** The gate's checkers and the measurement tools share one failure mode: they name their subject by hand and treat "found nothing" and "read nothing" as the same result. Three lints hardcode a path, `rg` exits non-zero on a missing file, and `if rg ...; then` reads that as clean, so a rename turns the lint into a no-op that still reports passing -- and the supervisor discards a passing step's stderr, so even `rg`'s complaint is invisible. `gate-test-coverage-lint.py` closes only half the loop: it forces every `scripts/tests/*_test.sh` to appear in the assembled gate, but nothing forces the lint scripts themselves to run over the tree, so a rule can ship with only its self-test wired. `scripts/` Swift is compiled by nothing at all, which is how the headless draw arm -- the one tool that would decide this area's cost findings -- has been unbuildable since `13db5f73`, and how its copy of `PreparedDraw` drifted out of step with the library's. At the probe boundary the same shape produces a well-formed report from a measurement that never happened: `flagValue` collapses "flag absent", "flag has no value", and "value unparsable" into one silent default, an occupancy run with zero iterations recovers a `?? 0`, a zero-payload memory report exits 0, and the retained-row probe skips a row it cannot read.

**Combined fix.** One precondition per estate. Promote `terminal-fence-accounting-lint.sh#setup_fail` into `scripts/lib/lint-targets.sh#lint_require_targets` (accepting files and directories) and source it from `checkpoint-off-main-lint.sh`, `terminal-exit-concurrency-lint.sh`, and `reconcile-pass-lint.sh`; give `gate-test-coverage-lint.py` a `tracked_lint_scripts` twin of `tracked_script_tests` so every `scripts/*-lint.{sh,py}` and `*-gate.{sh,py}` is a command word in the gate or carries `# gate: opt-out`; widen `checkpoint-off-main-lint.sh` to `app/` with `JSONEncoder(` as a one-entry allowlist under that same stale-entry check. Add a type-check-only gate step so a compiler is the subject-check for `scripts/terminal-headless-draw-arm.swift` (with `TerminalDamage` replacing `[Int]?` in `PreparedDraw`), and build `app/` once under `-DDANTERM_TERMINAL_BENCHMARK` so the 31 Swift greps in `terminal-benchmark-harness_test.sh` gain a real witness instead of a text match; the three `justfile` recipe-name greps then just delete. On the probe side, delete both copies of `flagValue` for the positional parse loop `TerminalResizeProbe` and `TerminalRetainedRowProbe` already use (`exit(2)` on a missing, unparsable, or out-of-range value), make `OccupancySample` hold at least one measurement by construction, validate geometry in `runMatrix` before any payload is built, and have `TerminalRetainedRowProbeSupport` return nil on the first unreadable row with `retainedRowCount` derived from `storedCellCounts.count`.

Symptoms: GATE-1, GATE-3, GATE-5, GATE-6, DRAW-3, PROBE-8, PROBE-2, PROBE-3, PROBE-4, PROBE-6

#### P2. The purity rule runs one way only -- it keeps IO out of the core, but nothing keeps decisions out of the two shells, which are the code no gated test can reach.

_Impact 4/5 -- 9 findings are symptoms._

**Root cause.** `core-purity-lint.sh` polices one direction of the layer boundary and the test estate follows the same asymmetry: `lib/` has dense suites, `DanTermUITests` needs a WindowServer and is excluded from `just test` and CI, `ios/DanTermMobileApp` has no test target at all, and the CLI's end-to-end suite carries a sanctioned opt-out. Nothing states the reverse rule -- that a view or a controller may read a projection and report a fact, but may not compute one -- so rules keep migrating into exactly the layer with no oracle. That produces a shipped bug (a Shift-only hardware key sends the unshifted byte because the press-to-event decision is a switch in `MobileRootViewController` rather than in `MobileInputMapper`), two predicates re-derived in the shell from conditions the model already holds, a badge whose visibility is decided twice, a drag that resolves through the selected tab instead of the pane's own, an IME rect invented as `(0,0)` beside a published cursor, and two effect interpreters that return silently where they cannot act. The sidebar case shows the second cost: state that never enters the model is also unreachable from the `danterm` CLI, which AGENTS.md names as the app's control surface -- so the shell loses its last remaining test seam at the same moment it loses the model's.

**Combined fix.** State the reverse boundary and give it somewhere to land. Add the mirror of `core-purity-lint.sh` over `app/` and `ios/DanTermMobileApp` for the shapes that mark a decision (a `switch` over a domain enum, a multi-clause predicate over model-derived values) and give `ios/DanTermMobileApp` a test target so the rule has a fallback. Then move each rule to its owner: `MobileInputMapper` takes the whole press-to-event decision; `MobileSessionProjection` publishes `needsTarget` and an ordered typed list of menu actions; `SidebarGroupProjection.Rendered` carries `alertBadge`/`tabCountBadge` as `Int?` with `BadgeLabel.apply(_:)` forwarding; `PaneToolbarRender` carries `canDrag` and the drag resolves through `tabForPane`; the sidebar's collapsed flag and width become one model field written only by the reducer and projected to the divider; `SwiftTerminalSessionView.firstRect(forCharacterRange:)` reads `publishedFrame?.plan.cursor`; `MobileSessionController.beginStream`/`send` dispatch `.connectionEnded(.deviceSetup)` instead of returning. `IPC-1` is the same boundary read backwards and lands in the same sweep: `IpcServer.dispatch` answers its own decode failure with `writeErrorResponse` rather than routing a protocol constant through `Msg` and back.

Symptoms: MOBAPP-1, MOBAPP-2, MOBAPP-3, MOBKIT-6, CHROME-1, CHROME-5, CHROME-6, INPUT-2, IPC-1

#### P3. Compatibility is settled by a human reading `references/` at design time, and once a plan or a test writes the answer down, nothing ever re-asks.

_Impact 5/5 -- 10 findings are symptoms._

**Root cause.** AGENTS.md makes `references/` the authority on compatibility, and the audit shows the reading works -- every divergence here was found by grepping the pinned checkouts. What is missing is any standing artifact that keeps the answer true. `docs/terminal-capabilities.md` is the one machine-adjacent contract, and it enumerates the terminfo claims of `xterm-256color` with an evidence column, which means every sequence outside terminfo -- DEC private modes 47 and 1007, REP's wrap edge, the X10 past-end marker, CHT/CBT's wrap latch, ED 3's side state, horizontal wheel reporting, the control-click button -- has no row, no citation, and no test. The closed vocabularies make the gap silent rather than loud: `DECPrivateMode` is a `rawValue` enum whose setter drops anything unlisted, so a mode nobody enumerated is absent from the setter, from DECRQM, and from state resynchronization at once, with no compiler complaint. Worse, the process pins divergence: `plans/impl/2026-07-18-...` states "repetition never wraps" against all three references and `TerminalRepeatTests.inertWithoutAvailableCluster` now asserts it, and two `tests-ui` cases deliberately pin control-click as button 2, which no reference emulator does.

**Combined fix.** Make the sequence surface a declared table with its evidence attached, and check it. Land `PARSE-4`'s single keypath declaration for the plain-Bool DEC private modes and `GRID-1`'s `SwitchScreenMode` value carrying each screen-switch mode's three answers (saves cursor, clears on entry, clears on exit) for 47/1047/1049, add `alternateScroll = 1007` to that table, and derive set, reset, DECRQM, and `TerminalStateSynchronizationEncoder` from it so a mode cannot be half-declared. Give each row a reference citation and the name of the behavioral test that pins it, extend `docs/terminal-capabilities.md` from "terminfo claims" to that whole surface, and add a `--check` step beside `DanTermSkillSynopsisGenerator --check` that fails when a declared entry has no evidence or the code answers a sequence the table does not list. Fix the four one-expression divergences on the way through (REP's two caps, the legacy mouse coordinate helper, CHT/CBT routed through HT's column primitive, ED 3's `clearPendingMotionState()`), and rewrite the two tests that pin the divergent answers rather than working around them. Finally, make a reference check a required section of any plan that decides externally visible terminal behavior -- that is where both pinned divergences entered.

Symptoms: PARSE-1, PARSE-2, PARSE-3, PARSE-7, GRID-1, GRID-3, SELECT-1, SELECT-4, INPUT-1, INPUT-4

#### P4. Contracts live in prose -- doc comments, help strings, SKILL.md, agent-docs rules -- and exactly one prose artifact in the tree is generated and gate-checked.

_Impact 3/5 -- 9 findings are symptoms._

**Root cause.** The repo already knows the right shape: `CLISkillSynopsisRegion` is a marked region rendered from `CLICommandCatalog` with a `--check` step in the gate, so the command list cannot rot. Nothing else got that treatment, and the rest has rotted exactly as predicted. SKILL.md -- the file AGENTS.md calls the source of truth for the CLI -- prints `"version":3` nine lines after stating 6, and its "only these subcommands print to stdout" table omits `doctor` and `help`; `scripts/tests/danterm-cli_test.sh` even carries a comment recording the previous instance of this same literal drifting. The same pattern runs through the code's comments about itself: `multiScalarAllocationCount` documents one unit and the walk counts two, `writeAtomically` implies a durability its missing directory flush does not provide, `killOwnedSession`'s comment claims a census proved the whole session was signalled, a checkpoint merge rule is decided by prose rather than by which file owns the fact, and a reducer arm sits empty with nothing saying why. `agent-docs/` rules are in the same position: `test-timing.md` bans elapsed time as an acceptance threshold, and two PTY tests do it anyway, because only three invariants in this tree have a lint.

**Combined fix.** Extend the mechanism that already works and convert the rest into types. Add a second marked region to SKILL.md rendering the protocol constants it quotes (`paneTapeStreamVersion`, the sync-history budget, the follow cap) and a third projecting the stdout-shape table from `CLICommandCatalog` plus each route's `CLIOutputMode`, both under the existing `--check` step; move the two grid bounds into `DanTermProtocol` constants interpolated into `pane resize`'s help; correct `pane zoom`'s help to name the field SKILL.md tells callers to read. For the in-code half, replace the claim with the thing: restate `multiScalarAllocationCount` on the per-spill-table unit the landed plan chose and move the retained branch onto it, have `PrivateFile.writeAtomically` name the durability level it actually offers, give `killOwnedSession`'s census retry a deadline and a group-kill fallthrough so the comment becomes true, make `last-light.json` the only structure on disk with `last-enriched.json` a scrollback-only sidecar, and comment `.themeBrowserControlClicked` with what it drives while routing the click through `ReconcileFollowUps`. Then add the one lint `test-timing.md` lacks: no test may compare a measured elapsed duration against a constant, which deletes the four lines in `closeRacingPromptSpawnUsesTeardownLadder` and the three in `applicationTerminationDrainsRegistryWithoutMainProgress`.

Symptoms: CLI-7, CLI-9, CLI-11, GRID-5, SUPPORT-5, PTY-8, PERSIST-1, GATE-4, UPDATE-9

#### P5. Tests are often a symbol's last remaining caller, and nothing in the gate asks whether production still reaches it.

_Impact 3/5 -- 10 findings are symptoms._

**Root cause.** The tree tests at the message and value boundary, which is right, but it means an internal symbol keeps a live reference as long as one test names it -- so Swift's unused warnings never fire and the gate stays green over code production abandoned. A five-link close-request chain crosses the whole engine boundary with nothing entering it: `requestClose()` has no caller, and `Msg.sessionEnded`'s only senders are four test files, while `AppRuntime` carries a log arm for an event that can never be logged. `RecoveryCheckpointPolicy.terminate()` returns an action its one production caller discards, and two unit assertions pin the dirty rule the exit path deliberately disobeys. `AlertTab` survives on four helper tests that assert its shape. The same shape without the test crutch is just as common -- `TerminalDamage.withGlyphHalo` outlived the reach ledger, `RenderTheme.searchMatchBackground` is a public field its own initializer hard-codes, `WindowChromeView.updateSeparatorPosition` has no caller, and `decidePointerArm`'s second selection branch is unreachable behind the first. Nothing measures reachability, so each of these is discovered only when a human reads the file.

**Combined fix.** Add one reachability lint over the closed vocabularies the app dispatches on -- every case of `Msg`, `TerminalSessionEvent`, `Command`, and `ConfirmationKind` must appear outside `*Tests` paths, or be deleted -- and pair it with the convention that a test drives the message production actually emits. Then take the deletions in one sweep: the whole `requestClose`/`.closeRequested`/`.sessionEnded` chain and its `AppRuntime` log arm, with the four test files re-pointed at `.sessionProcessExited`; `terminate()` returning `Void` with the two shape assertions replaced by the one the exit path relies on; `AlertTab` inlined against `model.showAllAlerts`; `TerminalDamage.withGlyphHalo` and `TerminalDamageRowBits.haloed` folded into the frozen research probe; `RenderTheme.searchMatchBackground` moved into `RenderColorResolution.swift` beside the other three ladder seeds; `WindowChromeView.updateSeparatorPosition`, the duplicate `pointerOwners[.left]` test, `unreadAlertPaneIds` with its `@discardableResult`, `runnerThread`, and the unread `phase:` payload on `MobileConnectionFailure.transport`.

Symptoms: UPDATE-6, UPDATE-8, PERSIST-7, MODEL-7, DRAW-6, DRAW-8, SELECT-5, CHROME-7, MOBAPP-4, MOBKIT-5


## Findings

The reference half: every finding in full, by lane.


### Area: Terminal parser, control-sequence dispatch, and modes (`PARSE`)

_Scope: `lib/TerminalCore/Sources/TerminalCore/` -- `EscapeAbsorber.swift`,
`TerminalInputStream.swift`, `UTF8Decoder.swift`, `TerminalCharset.swift`,
`TerminalInputEncoding.swift`, `TerminalCapabilityQuery.swift`,
`TerminalSettingReport.swift`, `OSCPayload.swift`, the dispatch and mode half of
`Terminal.swift` (`dispatchCSI`, `dispatchEscape`, `dispatchOSC`, `dispatchDCS`,
`execute`, `applyANSIModes`, `applyDECPrivateModes`, `applySGR`, the reset and
saved-cursor paths), and `appendControlState` in
`TerminalStateSynchronizationEncoder.swift`. Cross-checked against
`references/xterm`, `references/ghostty`, `references/foot`, and
`references/kitty`._

**The auditor's read on the area.** The recognizer itself is in very good shape:
`EscapeAbsorber` is a faithful VT500 state machine with bounded, inline
parameter storage, its C1/CAN/SUB/ESC abort rules are right, its OSC and routed
DCS states are correctly carved out of the general control dispatch, and the
`synchronizationPrefix` normalizer genuinely reproduces next-byte behavior for
every state. The XTGETTCAP projection, DECRQSS roster, OSC 133 dialect, charset
translation, and the "no reflection of an attacker's query" rule are all
contract-backed and match their references where they claim to. What defects are
left share one shape: a *closed vocabulary that lives in more than one place*.
DEC private modes are a `rawValue` enum restated by three exhaustive switches, so
a mode nobody enumerated (47) is simply absent from all three; kitty keyboard
flags are a bare `UInt16` whose support mask is re-applied at each writer; the
DCS synchronization prefix rebuilds a header from a route rather than from the
value it retained, and loses the parameters that decide whether the request is
valid. The two remaining behavior divergences (REP's row cap, X10 mouse
past-end) are each one arithmetic expression that reference emulators do not
have. I deliberately did not audit grid mutation (`eraseCells`, `moveAndFillRows`,
reflow), `LogicalLineStore`, `TerminalSearch`, or the damage accumulator -- they
belong to other lanes -- and I looked at and dropped several suspected bugs
listed at the end, mostly because a reference check showed DanTerm already
matches xterm or foot.

<a id="parse-1"></a>

#### PARSE-1. Implement DEC private mode 47 alongside 1047 and 1049

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; merged into GRID-1

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#DECPrivateMode`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#applyDECPrivateModes`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#decPrivateModeStatus`

**Problem.** `CSI ? 4 7 h` and `CSI ? 4 7 l` -- the original xterm alternate
screen switch -- are silently discarded. The mode is not in `DECPrivateMode`, and
the setter drops any raw value that does not decode, so a program that uses the
legacy `smcup`/`rmcup` pair draws its full-screen UI over the primary screen and
never restores it on exit. `DECRQM` for 47 also answers "not recognized" rather
than reporting the alternate screen's real state.

**Evidence.** The vocabulary jumps straight from 1004 to 1047:

```swift
enum DECPrivateMode: UInt16, CaseIterable {
    case applicationCursorKeys = 1
    ...
    case sgrMouseEncoding = 1006
    case alternateScreen = 1047
    case savedCursor = 1048
    case alternateScreenAndSavedCursor = 1049
```

and the setter drops everything unlisted:

```swift
for rawMode in parameters {
    guard let mode = DECPrivateMode(rawValue: rawMode) else { continue }
```

All three references implement it. xterm has it as its own mode --
`references/xterm/charproc.c#dpmodes`, `case srm_ALTBUF:` -- doing
`ToAlternate(xw, False)` on set and `FromAlternate(xw, False)` on reset. ghostty
declares it in its mode table as `.{ .name = "alt_screen_legacy", .value = 47 }`
(`references/ghostty/src/terminal/modes.zig`). foot handles it in the same arm as
1047 and 1049: `case 47: case 1047: case 1049:` in
`references/foot/csi.c#decset_decrst`, and reports all three from one state in
`references/foot/csi.c#decrpm`.

**Ideal fix.** Add `case alternateScreenLegacy = 47` and give it foot's
treatment: the same arm as `.alternateScreen`, and the same
`isAlternateScreenActive ? 1 : 2` answer in `decPrivateModeStatus`. That is the
smallest structure in which the gap cannot recur only if PARSE-4 lands first --
with one declared table the new case has exactly one place to be written.

**By construction.** Nothing on its own. With PARSE-4 in front of it, "a mode
whose setter and whose DECRQM answer disagree" stops being representable.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `TerminalModeTests` (or `TerminalAlternateScreenTests`): feed
`"primary" ESC[?47h "alt" ESC[?47l`, assert `screenText` shows `primary` and
`isAlternateScreenActive == false`; feed `ESC[?47h` then `ESC[?47$p` and assert
the reply is `ESC[?47;1$y`; assert `ESC[?47h` then `ESC[?1049l` leaves the
primary live, matching foot's shared-state model.

**Risk.** Mode 47 in xterm does *not* save or restore the cursor and does not
clear the alternate on entry; wiring it to `.alternateScreenAndSavedCursor`
instead of `.alternateScreen` would silently corrupt cursor state for programs
that pair `?47h` with their own `ESC 7`. The behavioral test above pins that.

**Vetted.** I opened `Terminal.swift#DECPrivateMode` (809-826),
`#applyDECPrivateModes` (6655-6720) and `#decPrivateModeStatus` (6609-6629).
Both quoted blocks are verbatim, the setter really drops an unlisted raw value
with `else { continue }`, and `decPrivateModeStatus` really returns 0 -- "not
recognized" -- for 47. I followed all three reference citations and all three
hold: `references/xterm/ptyx.h:1199` defines `srm_ALTBUF = 47` and
`charproc.c:7754` calls `ToAlternate(xw, False)` / `FromAlternate(xw, False)`;
`references/ghostty/src/terminal/modes.zig:209` is
`.{ .name = "alt_screen_legacy", .value = 47 }`;
`references/foot/csi.c:498` is `case 47: case 1047: case 1049:` and `:657-659`
answers all three from `term->grid == &term->alt`. One prose slip: the enum
jumps from 1006, not 1004 (the quoted block itself is right). Reachability is
narrower than the text suggests -- DanTerm publishes `smcup=\E[?1049h`
(`TerminalCapabilityProjection.generated.swift:23`) and runs children with
`TERM=xterm-256color`, so only a program that hardcodes `?47h` rather than
reading terminfo is affected. I left impact at 3 to match GRID-1 rather than
score the same defect twice.

**Correction.** The ideal fix is wrong on one point. "Give it foot's treatment:
the same arm as `.alternateScreen`" routes 47 into DanTerm's
`switchAlternateScreen(enabled:)`, which blanks the alternate grid on every
entry. xterm passes `clearFirst = False` for 47 (`charproc.c:9523`
`ToAlternate(XtermWidget xw, Bool clearFirst)`, reached from `srm_ALTBUF` as
`ToAlternate(xw, False)`), and ghostty's `SwitchScreenMode` gives `.@"47"` an
empty body, so under both of them 47 shows whatever the alternate grid last
held. That contradicts this finding's own Risk paragraph, which already says
xterm's 47 "does not clear the alternate on entry". Only foot clears. So the
mode-47 case needs its own clear-edge answer, which is exactly the table
`GRID-1` proposes.

**Conflicts with.** `GRID-1`, which is the same defect stated with the clear-edge
rule attached and an `AlternateScreenSwitch` table to hold it; its vetting says
PARSE-1 should fold into it, and I agree -- implement GRID-1, not both. Also
`PARSE-4` and `SELECT-4`, which add or rewrite arms in the same three
`DECPrivateMode` switches.

<a id="parse-2"></a>

#### PARSE-2. Let REP repeat its count instead of stopping at the row edge

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#repeatLastPrintedCluster`

**Problem.** `CSI Ps b` (REP) caps the repeat count at what fits in the current
row, so characters the program asked for are dropped rather than wrapped onto the
next row. `CSI 20 b` at column 70 of an 80-column screen writes 10 cells, not 20.
Every reference emulator repeats the count through the ordinary print path, which
wraps and scrolls exactly like the same characters typed out.

**Evidence.**

```swift
let requestedCount = max(Int(parameters.first ?? 1), 1)
let repeatCount: Int
if screen.isPendingWrap {
    repeatCount = modes.isAutoWrapMode
        ? min(requestedCount, columnCount / cluster.cellWidth)
        : 1
} else {
    let availableColumns = columnCount - screen.cursor.column
    repeatCount = min(requestedCount, availableColumns / cluster.cellWidth)
}
```

xterm loops the raw count through `dotext`, its normal print entry point
(`references/xterm/charproc.c`, `case CASE_REP:`):

```c
count = one_if_default(0);
repeated[0] = (IChar) sp->lastchar;
while (count-- > 0) {
    dotext(xw, screen->gsets[(int) (screen->curgl)], repeated, 1);
}
```

ghostty is the same shape (`references/ghostty/src/terminal/Terminal.zig#printRepeat`):

```zig
pub fn printRepeat(self: *Terminal, count_req: usize) !void {
    if (self.previous_char) |c| {
        const count = @max(count_req, 1);
        for (0..count) |_| try self.print(c);
    }
}
```

The cap is deliberate, not accidental: `plans/impl/2026-07-18-1751-terminal-modes-tabs-saved-cursor-reset.md`
states "repetition never wraps: it stops when the whole cluster no longer fits in
the row's remaining columns", and `TerminalRepeatTests#countCapAndWideClusters`
pins it. That plan text is also now stale in its own terms -- it says "REP with
pending wrap already armed never wraps and leaves it armed", while the code and
`TerminalRepeatTests#inertWithoutAvailableCluster` both wrap in that case.

**Ideal fix.** Delete the two capping expressions and loop
`requestedCount` times, feeding each repeat through `print` exactly as today.
REP is already documented as a print-path member (D5 in the same plan), so the
wrap, scroll, insert-mode and DECAWM rules come for free from `print` and there
is no second place stating them. Update the plan's REP paragraph and the two
pinned tests in the same change.

**By construction.** Removes the only place in the dispatch layer that restates
"how far a print may go before it wraps"; after the change that rule exists once,
inside `print`.

**Cheaper fallback.** Keep the cap and record it as a deviation next to D1-D6.
That fails to remove the divergence itself: a program using terminfo `rep` for a
run that crosses a line boundary still loses characters, and nothing in the tree
tells a future reader that xterm and ghostty behave differently.

**Verification.** `TerminalRepeatTests`: on a 4x3 terminal feed `a` then
`ESC[10b`, assert `screenText == "aaaa\naaaa\naaa "` and the cursor is at
row 2 column 3. On a 4x2 terminal feed `a ESC[?7l ESC[10b` and assert the row
fills once and nothing wraps, so the DECAWM-off case is unchanged.

**Risk.** A hostile `CSI 65535 b` now does 65535 prints and can scroll the whole
region into scrollback, where today it does at most one row. That is the same
work a 65535-byte print run already costs, so it is not a new bound, but the
scrollback-eviction path is newly reachable from one short sequence; the
retained-history budget tests are the ones to watch.

**Vetted.** I opened `Terminal.swift#repeatLastPrintedCluster` (7501-7524); the
quoted block is verbatim, including both capping expressions. I followed all
three citations and added a third reference the finding does not name.
`references/xterm/charproc.c:6152` (`case CASE_REP:`) is exactly as quoted -- a
raw `while (count-- > 0)` around `dotext`, the normal print entry.
`references/ghostty/src/terminal/Terminal.zig:295` is verbatim, and ghostty pins
the wrapping case in its own suite (`test "Terminal: printRepeat wrap"`).
`references/foot/csi.c:794-818` does the same: `for (int i = 0; i < count; i++)
term_print(...)`, with no row bound. So all three references wrap and DanTerm
does not. The plan citation also holds: line 159 of
`plans/impl/2026-07-18-1751-terminal-modes-tabs-saved-cursor-reset.md` says
"repetition never wraps", line 163 says REP with pending wrap armed "never wraps
and leaves it armed", and `TerminalRepeatTests.inertWithoutAvailableCluster`
(lines 57-61) asserts the opposite -- `AB` then `ESC[1000b` gives `"AB\nBB"`. So
the plan really is stale in its own terms. Reachability is narrow and the
finding does not overclaim it: `rep` lives in the `ansi+rep` block of
`references/xterm/terminfo` and is not part of the `xterm-256color` entry
DanTerm advertises (`infocmp xterm-256color` has no `rep`), so a curses program
never emits REP here. Only a program that writes `CSI Ps b` itself is affected.
That caps this at impact 2; the evidence and the divergence are solid.

**Conflicts with.** Nothing. No other lane file names `repeatLastPrintedCluster`
or the print path's wrap rule.

<a id="parse-3"></a>

#### PARSE-3. Emit xterm's past-end marker for legacy mouse coordinates over 222

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift#encodeMouseReport`

**Problem.** In legacy (non-SGR) mouse reporting, a column or row past what one
byte can carry is clamped to `0xFF`, which a child decodes as column 222 -- a real
cell it was not pointing at. xterm emits `0x00` there, the documented past-end
marker, so a child can tell "off the encodable edge" from "column 222". Any pane
wider or taller than 223 cells with a legacy-mouse program is affected.

**Evidence.**

```swift
let legacyCode = isPressed ? code : 3 | (code & 0x1C)
return [
    0x1B, 0x5B, 0x4D,
    UInt8(clamping: legacyCode + 0x20),
    UInt8(clamping: column + 0x21),
    UInt8(clamping: row + 0x21),
]
```

xterm clamps the coordinate to the limit first
(`references/xterm/button.c#EditorButton`):

```c
if (mouse_limit > 0) {
    /* Limit to representable mouse dimensions */
    if (row > mouse_limit) row = mouse_limit;
    if (col > mouse_limit) col = mouse_limit;
}
```

with `#define MOUSE_LIMIT (255 - 32)`, and then emits the marker rather than a
byte (`references/xterm/button.c#EmitMousePosition`):

```c
if (value == mouse_limit) {
    line[count++] = CharOf(0);
} else {
    line[count++] = CharOf(' ' + value + 1);
}
```

with the comment "historically, it was possible to emit 256, which became zero by
truncation to 8 bits ... it's also somewhat useful as a past-end marker. We
preserve this behavior".

**Ideal fix.** Replace `UInt8(clamping:)` on the two coordinates with one
`legacyMousePositionByte(_:)` that returns `0` for any value at or past 223 and
`UInt8(value + 0x21)` otherwise -- one function, used for both axes, so the two
cannot drift. `UInt8(clamping:)` on the button byte is fine and stays.

**By construction.** Removes the only place where an out-of-range cell silently
becomes an in-range one. n/a beyond that: the axis type is still `Int`, because
the pane's real geometry is what supplies it.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `TerminalMouseEncodingTests`: with `mouseTracking: .click` and
`sgrMouseEncoding: false`, encode `.down(.left, column: 222, row: 0)` and assert
the fourth byte is `0xFF`; encode `.down(.left, column: 223, row: 400)` and
assert the coordinate bytes are `0x00, 0x00`. Assert the SGR path is untouched at
the same coordinates.

**Risk.** A child that today reads `0xFF` and clamps to its own last column would
start reading `0`, i.e. column -32 before its own clamp. That is exactly what
talking to xterm already does to it, so the risk is bounded by "matching the
reference", but it is a visible change for any such program.

**Vetted.** I opened `TerminalInputEncoding.swift#encodeMouseReport` (280-298);
the quoted block is verbatim and `UInt8(clamping:)` is the whole of the range
handling. The xterm citation checks out at both sites: `button.c:212` is
`#define MOUSE_LIMIT (255 - 32)`, `button.c:5516-5522` clamps `row` and `col` to
`mouse_limit` inside `EditorButton`, and `button.c:240-260`
(`EmitMousePosition`) emits `CharOf(0)` when `value == mouse_limit` with the
"past-end marker" comment quoted word for word. So the reference behaves as
claimed.

**Correction.** Two things the prose gets wrong. First, the divergence is a
recorded decision, not an oversight, and the fix must delete an assertion rather
than land beside it:
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalMouseEncodingTests.swift:29`,
in a case titled "X10 encodes buttons modifiers releases wheels and *bounded
coordinates*", asserts `encode(.down(.left, column: 300, row: 300)) == [0x1B,
0x5B, 0x4D, 0x20, 0xFF, 0xFF]`. Second, the Verification paragraph names the
wrong byte: the report is `ESC [ M button column row`, so at column 222 it is
the *fifth* byte that is `0xFF`; the fourth is the button byte `0x20`. The claim
that survives is the narrow one: past column 222 DanTerm reports a cell the
pointer was not on, and no reference terminal does that.

**Conflicts with.** `SELECT-1`, which is the same defect on the same function
with a mutually exclusive fix -- it proposes suppressing the report entirely
(`return []`), citing `references/ghostty/src/Surface.zig#mouseReport` and
`references/vte/src/vte.cc#feed_mouse_event`, both of which refuse rather than
mark. I confirmed both of those citations as well. Only one wire behavior can
land: xterm's `0x00` past-end marker (this finding) or ghostty's and vte's
silence (SELECT-1). Two of the three references suppress; xterm, whose terminfo
entry DanTerm publishes, marks. Adjudicate the pair together.
`INPUT-4` also edits `TerminalInputEncoding.swift` (the wheel-direction half),
but not this function, so it is adjacent rather than exclusive.

<a id="parse-4"></a>

#### PARSE-4. Declare each DEC private mode once, as data, instead of once per consumer

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#DECPrivateMode`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#applyDECPrivateModes`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#decPrivateModeStatus`,
`lib/TerminalCore/Sources/TerminalCore/TerminalStateSynchronizationEncoder.swift#appendControlState`

**Problem.** The closed set of DEC private modes is a `UInt16`-raw-valued enum,
and three separate exhaustive switches say what each case *means*: one writes the
mode into `TerminalModes`, one reads it back out for DECRQM, and one re-emits it
for state synchronization. For the eleven modes that are a single `Bool` on
`TerminalModes`, all three switches name the same stored property. Nothing
connects them, so a setter and its DECRQM answer can be wired to different
properties and every test still passes; and a mode nobody wrote into the enum is
absent from all three at once, which is exactly PARSE-1.

**Evidence.** The same eleven properties, three times. Setter:

```swift
case .applicationCursorKeys:
    modes.isApplicationCursorKeysMode = enabled
case .origin:
    modes.isOriginMode = enabled
```

Query:

```swift
case .applicationCursorKeys: modes.isApplicationCursorKeysMode ? 1 : 2
case .origin: modes.isOriginMode ? 1 : 2
```

Encoder:

```swift
case .applicationCursorKeys: enabled = modes.isApplicationCursorKeysMode
case .origin: enabled = modes.isOriginMode
```

The closed audit's `PARSE-3` ("Derive DEC/ANSI mode set, reset, query and
resynchronization from one mode table", landed as `038ba535 refactor(terminal):
make mode policy exhaustive`) shipped the exhaustiveness half of this -- every
switch now covers every case, so an *added* case fails the build -- but not the
table half, so the three switches still restate the mapping independently. I am
reporting the remainder rather than reopening the item.

**Ideal fix.** Split the vocabulary by what a mode actually is. Give the plain
ones a single declaration -- `(rawValue, WritableKeyPath<TerminalModes, Bool>)`,
either as a table or as one property on the enum -- and derive set, reset,
DECRQM and resynchronization from it. The five modes that are not a plain Bool
(`origin` also homes the cursor, the mouse triple is one exclusive enum, and
`alternateScreen`/`savedCursor`/`alternateScreenAndSavedCursor` are screen
operations) keep an explicit arm, but the switch shrinks to those five and the
one-Bool cases stop being restated at all.

**By construction.** "A mode whose DECRQM answer reads a different property than
its setter writes" and "a mode the setter knows about that state synchronization
forgets" both stop being expressible. It also deletes the encoder's
`enabled: Bool?` sentinel, whose `nil` currently means "not a plain mode" --
that distinction becomes the type's.

**Cheaper fallback.** Add a test that, for each `DECPrivateMode`, sets it,
reads it back with DECRQM, and asserts `1`; then resets and asserts `2`. That
catches a mis-wiring but leaves the three switches, so PARSE-1's failure mode --
a mode nobody enumerated -- is untouched, and every new mode still costs three
edits.

**Verification.** Behavioral, and structure-insensitive because it names only
wire sequences: a `TerminalModeTests` case that walks every raw mode value
DanTerm claims, feeds `CSI ? N h`, asserts `CSI ? N $ p` answers `1`, feeds
`CSI ? N l`, asserts it answers `2`, and asserts the same mode appears in
`stateSynchronization().bytes` with the value it was left in. That test passes
before and after the refactor and fails on any mis-wiring.

**Risk.** The keypath form has to keep the encoder's *ordering* -- mouse mode
neutralization before the selected mode, focus reporting conditionally omitted so
resynchronization does not inject a second focus report. A naive table walk that
loses that order corrupts replica state; the synchronization round-trip tests are
the ones that would show it.

**Vetted.** I opened all four sites: `Terminal.swift#DECPrivateMode` (809-826),
`#applyDECPrivateModes` (6655-6720), `#decPrivateModeStatus` (6609-6629), and
`TerminalStateSynchronizationEncoder.swift#appendModes` (292-345), which is what
`appendControlState` (196-235) calls. The three switches are real, all three are
exhaustive over the same enum, and every quoted line is verbatim.
`grep -rn DECPrivateMode lib/TerminalCore/Sources` finds no fourth consumer, so
three is the whole population. The commit citation is right: `038ba535
refactor(terminal): make mode policy exhaustive` is in the history.

**Correction.** Three numbers in the prose are wrong, and one claimed payoff is
not delivered. (1) Eleven modes are not restated identically; seven are --
`applicationCursorKeys`, `autoWrap`, `cursorBlink`, `cursorVisible`,
`sgrMouseEncoding`, `bracketedPaste`, `synchronizedOutput`. `origin` also homes
the cursor in the setter and `focusReporting` also emits a reply there and is
conditionally skipped by the encoder, so those two are plain in two switches out
of three. (2) The ideal fix says five modes keep an explicit arm; it is nine --
the mouse triple, the screen triple, plus `graphemeClusters` (setter no-op,
DECRQM answers a hardcoded 3, encoder skips), `origin`, and `focusReporting`. So
a keypath table absorbs seven of sixteen cases, not eleven. (3) "A mode nobody
wrote into the enum is absent from all three at once, which is exactly PARSE-1"
is true but is *not* fixed by this finding: a table keyed on the same enum still
requires someone to add the case. This refactor removes restatement, not
omission. The payoff that survives is a real one -- a setter and its DECRQM
answer can currently name different properties and compile, and every new plain
mode costs three edits instead of one -- but it does not subsume PARSE-1 or
GRID-1.

**Conflicts with.** `GRID-1`, `PARSE-1` and `SELECT-4` all add cases to
`DECPrivateMode` and answer them in these same three switches. They are not
mutually exclusive with this one, but the order matters: landing PARSE-4 first
turns each of them into fewer sites, and landing them first means rewriting
their arms. `GRID-1` additionally wants the three alternate-screen modes folded
into an `AlternateScreenSwitch` value, which is a second table over the same
enum -- design the two together so the enum does not end up with two competing
side tables.

<a id="parse-5"></a>

#### PARSE-5. Give kitty keyboard flags a type that cannot hold an unsupported bit

`structural` &middot; impact 1, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#pushKittyKeyboardFlags`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#setKittyKeyboardFlags`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#ScreenControlState`,
`lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift#TerminalInputModes`

**Problem.** The kitty keyboard stack is `[UInt16]` and DanTerm implements only
bit 0 (disambiguate). The "drop the bits we do not implement" rule is therefore
re-applied by hand at every writer, and the dispatch layer reads a `UInt16`
parameter straight off the wire. A writer that forgets the mask would put an
unimplemented flag on the stack, and `CSI ? u` would then report a capability
DanTerm does not have.

**Evidence.** The mask, twice:

```swift
private mutating func pushKittyKeyboardFlags(_ flags: UInt16) {
    var stack = screen.control.kittyKeyboardStack
    if stack.count == Self.kittyKeyboardStackDepth { stack.removeFirst() }
    stack.append(flags & 1)
```

```swift
private mutating func setKittyKeyboardFlags(_ flags: UInt16, mode: UInt16) {
    var stack = screen.control.kittyKeyboardStack
    let previous = stack.last ?? 0
    let masked = flags & 1
```

and the untyped storage and projection:

```swift
var kittyKeyboardStack: [UInt16] = []
```

```swift
/// Contains only keyboard protocol flags DanTerm actually implements.
public var kittyKeyboardFlags: UInt16
```

That doc comment states an invariant the type does not carry; `encodeTerminalKey`
then trusts it with `if modes.kittyKeyboardFlags != 0`.

**Ideal fix.** A `TerminalKittyKeyboardFlags: OptionSet` with
`static let disambiguateEscapeCodes`, an `init(reported rawValue: UInt16)` that
intersects with the supported set exactly once, and `RawRepresentable` for the
`CSI ? Nu` reply. The stack becomes `[TerminalKittyKeyboardFlags]`, the two
writers stop masking, `setKittyKeyboardFlags`'s three modes become
`union`/`subtracting`/assignment on the set, and `TerminalInputModes` carries the
set instead of a `UInt16`.

**By construction.** "A stack element holding a flag DanTerm does not
implement" and "a reply advertising an unimplemented flag" both become
unrepresentable, and the doc comment above `kittyKeyboardFlags` becomes the
type's job rather than a promise. Adding a second flag then means adding one
`static let` and using it -- no new mask sites.

**Cheaper fallback.** Fold the mask into one `private static func
supportedKittyFlags(_:)` and call it from both writers. That removes the
duplication but leaves the stack, the projection, and the encoder all trading in
a raw `UInt16`, so a future writer that skips the helper is still legal.

**Verification.** `TerminalKeyEncodingTests` / `TerminalQueryTests`: feed
`CSI > 15 u`, assert `CSI ? u` answers `ESC[?1u`; feed `CSI = 15 ; 2 u` on top of
it and assert the answer is still `ESC[?1u`; feed `CSI = 1 ; 3 u` and assert
`ESC[?0u` and that a subsequent Escape key encodes as the legacy `0x1B`. All
three assert only wire bytes.

**Risk.** `kittyKeyboardStack` is inside `ScreenControlState`, which participates
in `Terminal ==` and in the state-synchronization encoding; changing the element
type changes what a replica must reconstruct. The synchronization round-trip
test for kitty flags is the gate.

**Vetted.** I opened `Terminal.swift#pushKittyKeyboardFlags` (7595-7602),
`#setKittyKeyboardFlags` (7610-7626), `#popKittyKeyboardFlags` (7604-7608), the
`ScreenControlState` field (781), the `CSI ? u` reply (6415), `inputModes`
(1455-1466), and `TerminalInputEncoding.swift#TerminalInputModes` (24-50) with
its consumer at line 139. Every quote is verbatim: `flags & 1` appears once in
each writer, the stack is `[UInt16]`, the doc comment does state an invariant the
type does not carry, and `encodeTerminalKey` does trust it with
`if modes.kittyKeyboardFlags != 0`.

**Correction.** Impact drops to 1 on reachability. Both writers mask correctly
today, and they are the only two -- `popKittyKeyboardFlags` needs no mask, and
the three wire entry points (6440, 6444, 6448) all route through them. So no
unsupported bit can reach the stack in the tree as it stands; the finding is a
guard against a writer that does not exist yet, in a two-site vocabulary with one
member. That is a genuine but small structural win, and it is paid for with a
change to a type inside `ScreenControlState`, which `Terminal ==` and the
synchronization encoding both depend on. Everything else in the finding holds.

**Conflicts with.** Nothing. No other lane file mentions the kitty keyboard
stack. `SELECT-4` adds a field to `TerminalInputModes`, which this finding also
edits, but the two changes are independent members of the same struct.

<a id="parse-6"></a>

#### PARSE-6. Rebuild the routed-DCS synchronization prefix from the retained header, not from the route

`correctness` &middot; impact 1, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift#synchronizationPrefix`,
`lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift#DCSRoute`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#dispatchDECRQSS`

**Problem.** When a checkpoint is taken while a routed DCS body is still
collecting, the prefix that restores the parser is rebuilt from the *route*, not
from the header the absorber actually retained. The route carries only the
intermediate and the final, so any parameters are dropped. Both routed handlers
reject a parameterized header, so `ESC P 1 $ q m ESC \` split across a checkpoint
answers `DCS 1 $ r 0m ESC \` on the replica where the live terminal answers
`DCS 0 $ r ESC \`.

**Evidence.** The prefix is synthesized:

```swift
case .dcsPassthrough, .dcsEscape:
    bytes = [0x1B, 0x50] + (dcsRoute?.headerBytes ?? [0x71]) + controlStringPayload
        + (controlStringPayloadOverflowed ? [0x20] : [])
```

```swift
var headerBytes: [UInt8] {
    switch self {
    case .decrqss: [0x24, 0x71]
    case .xtgettcap: [0x2B, 0x71]
    }
}
```

while `beginDCSPassthrough` deliberately keeps the parameters alive for the
dispatch:

```swift
let route = DCSRoute(intermediates: intermediates, final: final)
let header = parameters
clearCollection()
if let route { dcsRoute = route; parameters = header }
```

and both handlers key off exactly those parameters:

```swift
guard sequence.parameters.isEmpty, let status = decrqssStatus(for: sequence.body) else {
    appendReply("\u{1B}P0$r\u{1B}\\")
```

`docs/terminal-capabilities.md` makes the parameterized case contract: "any `$ q`
header carrying a parameter -- replies `DCS 0 $ r ST`".

**Ideal fix.** Emit the retained parameters between `ESC P` and the route's
intermediate, reusing the existing `appendParameters(to:)` helper the CSI states
already use. The `?? [0x71]` fallback for the unrouted case stays as-is, since an
unrouted body is never collected.

**By construction.** n/a -- the header stays split across `dcsRoute` and
`parameters`, because the route is what decides whether to collect a body at all
and the parameters are what decides validity. This is a one-line omission in the
serializer, not a modelling error.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** In the state-synchronization suite: feed `ESC P 1 $ q m` into a
terminal, take a synchronization, feed it into a fresh terminal, then feed
`ESC \` into both and assert both drained reply streams equal
`ESC P 0 $ r ESC \`. The same shape with `ESC P $ q m` must yield the valid
reply on both sides.

**Risk.** Very low. A replica that resumes a mid-DCS body now sees a longer
prefix; the only readers are the absorber itself and the checkpoint size budget.

**Vetted.** I opened `EscapeAbsorber.swift#synchronizationPrefix` (274-329),
`#DCSRoute` (17-39), `#beginDCSPassthrough` (632-648),
`Terminal.swift#dispatchDECRQSS` (1937-1943) and `#dispatchXTGETTCAP`
(1924-1929). Every quote is verbatim. The mechanism is exactly as described: the
`.dcsPassthrough` / `.dcsEscape` arm is the one control-string state that
synthesizes its header from `dcsRoute.headerBytes` instead of replaying the
retained collection, while the neighbouring `.dcsParameter` and
`.dcsIntermediate` arms both call `appendParameters(to:)`. `beginDCSPassthrough`
really does restore `parameters = header` after `clearCollection()` for a routed
sequence only, and both handlers gate on `sequence.parameters.isEmpty`. The
prefix does reach the wire:
`TerminalInputStream.synchronizationPrefix` is `decoder.synchronizationPrefix +
absorber.synchronizationPrefix`, and `Terminal.swift:1202` feeds it into the
encoder as `inputSynchronizationPrefix`. The contract citation in
`docs/terminal-capabilities.md` also holds. Impact 1 is right, and if anything
generous: the divergence needs a checkpoint landing strictly inside a routed DCS
body *and* a header carrying a parameter, and a parameterized `$ q` or `+ q`
header is a malformed request in the first place -- so what differs is whether a
malformed request gets its "invalid" answer or a valid one. It is still a real
one-line omission in a serializer that otherwise reproduces every state exactly.

**Conflicts with.** Nothing. No other lane file names `EscapeAbsorber`'s
synchronization prefix; DRAW's only mention of the file is the unrelated
`InlineArray` line at 114.

<a id="parse-7"></a>

#### PARSE-7. Stop clearing the wrap latch on CHT and CBT

`correctness` &middot; impact 1, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#moveCursorAcrossTabStops`,
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#execute`

**Problem.** DanTerm treats HT (0x09) and CHT/CBT (`CSI I` / `CSI Z`) differently
for the pending-wrap latch, and only one of the two matches xterm. HT leaves the
latch alone; CHT and CBT route through `movePositionedCursor`, which calls
`clearPendingMotionState()`. In xterm all three are the same operation, and none
of them clears the wrap flag. So `"...last column" CSI 1 I "x"` overwrites the
last column in DanTerm and wraps to the next row in xterm.

**Evidence.** HT does not clear:

```swift
case 0x09:
    let previousColumn = screen.cursor.column
    screen.cursor.column = tabStops[members: (screen.cursor.column + 1)...].first
        ?? columnCount - 1
    if screen.cursor.column != previousColumn { clusterContext = nil }
```

CHT/CBT do:

```swift
movePositionedCursor(
    row: screen.cursor.row,
    column: column ?? (forward ? columnCount - 1 : 0)
)
```

```swift
private mutating func movePositionedCursor(row: Int, column: Int) {
    ...
    clearPendingMotionState()
}
```

xterm's tab primitive writes the column directly and never touches the wrap flag
(`references/xterm/tabs.c#TabToNextStop`):

```c
int next = TabNext(xw, xw->tabs, screen->cur_col);
...
set_cur_col(screen, next);
```

`references/xterm/charproc.c` reaches it from both `case CASE_TAB:` and its CHT
handler, so the two share the behavior. `plans/impl/2026-07-18-1751-terminal-modes-tabs-saved-cursor-reset.md`
records HT as a deliberate exception to the house "every non-print operation
clears side state" rule (D2) but does not mention CHT or CBT, so the split looks
unconsidered rather than chosen.

**Ideal fix.** Have CHT and CBT compute their target column and go through the
same primitive HT uses, so "a tab stop move" has one wrap-latch rule instead of
two. That deletes the inconsistency rather than restating it, and lands DanTerm
on xterm's behavior for all three.

**By construction.** After the change, "HT and CHT disagree about the wrap latch"
is not expressible, because there is one tab-motion path.

**Cheaper fallback.** Record the split as a new deviation next to D1-D6. That
costs nothing but keeps two rules for one concept, and keeps the divergence.

**Verification.** `TerminalModeTests` or a tab-stops suite: on a 9-column
terminal with the default every-8 stops, feed 9 characters so the cursor latches
at column 8, then `ESC[1I`, then `x`, and assert `x` landed on row 1 column 0.
The same stream with a bare `\t` in place of `ESC[1I` must already assert the
same thing today.

**Risk.** Programs that use CHT as a cheap "move to column N" while sitting at
the margin would newly wrap. That is xterm's behavior, so a program that works in
xterm is unaffected; a program written against DanTerm's current behavior is not.

**Vetted.** I opened `Terminal.swift#execute`'s `case 0x09:` (7259-7265),
`#moveCursorAcrossTabStops` (7145-7160), `#movePositionedCursor` (7128-7133) and
`#clearPendingMotionState` (7284-7287). All quotes are verbatim, and
`clearPendingMotionState` really clears `screen.isPendingWrap` as well as the
open cluster, so the split the finding describes is real. The xterm citation
holds and is stronger than stated: `tabs.c:145-159` (`TabToNextStop`) and
`:165-180` (`TabToPrevStop`) both end in `set_cur_col`, which is a plain
assignment (`xterm.h:1280` in the untraced build, `cursor.c:592-601` in the
traced one) and never touches `do_wrap`; `charproc.c:3745`, `:3754` and `:3763`
show `CASE_CBT`, `CASE_CHT` and `CASE_TAB` all reaching those two functions, so
the three genuinely share the behavior. Two further references agree, which the
finding does not mention: ghostty's `horizontalTab` / `horizontalTabBack`
(`Terminal.zig:1346-1371`) move through `cursorRight` / `cursorLeft`, neither of
which clears `pending_wrap`; and foot saves and restores the flag by hand around
CHT -- `references/foot/csi.c:1184-1186`, `bool lcf = term->grid->cursor.lcf; …
term->grid->cursor.lcf = lcf;` -- which is a deliberate statement that a tab must
not consume the latch. Three references, no dissent. The plan citation is also
right: D2 (lines 193-198) names HT as one of three exceptions and says nothing
about CHT or CBT.

**Conflicts with.** Nothing. No other lane file names `moveCursorAcrossTabStops`
or `movePositionedCursor`.

#### Dropped (PARSE)

- **C1 controls (0x80-0x9F) are never honored.** `TerminalInputStream.isIgnoredDecodedScalar`
  drops every decoded C1 scalar, so 8-bit CSI/OSC/DCS/ST do nothing. Deliberate and
  contract-backed: `docs/terminal-capabilities.md` denies `eight-bit-replies`, and
  a raw high byte in a UTF-8 stream is a decode error, not a control.
- **`CSI ? 5 n` answers `CSI ? 0 n`.** Matches xterm exactly
  (`references/xterm/charproc.c`, `case CASE_DSR:` -> `case 5:` sets `reply.a_param[0] = 0`).
- **DECRQM reports 3 for mode 2027.** Correct: 3 is "permanently set"
  (`references/foot/csi.c`, `DECRPM_PERMANENTLY_SET = 3`) and DanTerm always
  does grapheme clustering.
- **DECSET 1004 injects a focus report on enable.** Matches foot exactly
  (`references/foot/csi.c#decset_decrst`, `case 1004:`), and the code says so.
- **XTGETTCAP returns `\E` for `%`-parameterized capabilities but a raw ESC
  otherwise.** Looked like a generator bug; it is the documented xterm/kitty split
  and ghostty implements the identical rule
  (`references/ghostty/src/terminfo/Source.zig#xtgettcapMap`).
- **ECH clears the row's soft-wrap flag.** Matches xterm: ECH routes through
  `references/xterm/util.c#do_erase_char` -> `ClearRight`, which does
  `LineClrWrapped(ld)` and `ResetWrap(screen)`.
- **DECSTR resets bracketed paste, mouse tracking and focus reporting.** xterm
  does not (`references/xterm/charproc.c#ReallyReset`, the `else /* DECSTR */`
  arm) but foot does (`references/foot/terminal.c#term_reset` clears
  `bracketed_paste`, `focus_events`, `mouse_tracking` and the kitty stacks on a
  soft reset). Two references disagree and DanTerm picked one; not a defect.
- **HT does not clear the pending-wrap latch.** Correct -- see PARSE-7; xterm's
  `set_cur_col` leaves the flag alone. Only CHT/CBT diverge.
- **`?1047l` does not clear the alternate screen.** xterm clears on reset and
  DanTerm clears on set (`references/xterm/charproc.c#dpmodes`, `case
  srm_OPT_ALTBUF:`). No observable difference, because the buffer is blank on
  entry either way.
- **DA2, XTSAVE/XTRESTORE (`CSI ? Pm s|r`), modifyOtherKeys (`CSI > 4 ; Pm m`),
  DECNKM (mode 66), reverse wraparound (mode 45), X10 mouse (mode 9), and mouse
  encodings 1005/1015/1016 are all unimplemented.** DA2 is explicitly denied by
  the contract; the rest are unclaimed surface with no accepted workflow behind
  them, and each would be a feature request rather than a defect. Worth a note
  only because mode 47 (PARSE-1) is not in that class -- it is the legacy half of
  a family DanTerm does claim.
- **`UTF8Decoder.==` allocates two arrays to compare at most three bytes**
  (`lib/TerminalCore/Sources/TerminalCore/UTF8Decoder.swift`, the custom `==`
  calls `synchronizationPrefix` on both sides). Real, and trivially fixed by
  comparing `pendingCount` and the live bytes; dropped because `Terminal ==` is a
  test-time operation here and the win is unmeasurable in any production
  workload, which is exactly the kind of cost finding this audit is told not to
  pad with.
- **`EscapeAbsorber.synchronizationPrefix` copies a pending control-string
  payload twice** -- once into its own `[0x1B, 0x5D] + controlStringPayload`
  result and again in `TerminalInputStream.synchronizationPrefix`'s `+`. The
  payload can be 2 MB. Dropped as a cost finding rather than kept, because it
  only fires when a checkpoint lands strictly inside an OSC or routed DCS body;
  if it is ever worth deciding, the experiment is
  `swift test --package-path lib/TerminalCore --filter BoundedHistorySynchronization`
  over a corpus that checkpoints mid-`OSC 52` payload, and the number that must
  move is peak allocated bytes per `stateSynchronization()` call.
- **Every OSC dispatch reallocates the absorber's payload buffer.**
  `dispatchOSC` hands `controlStringPayload` to the event and then
  `clearCollection()` calls `removeAll(keepingCapacity: true)` on a now-shared
  buffer, which allocates. Dropped: the reallocated capacity tracks the payload
  just dispatched, not a high-water mark, so the steady-state waste is one
  allocation per OSC and OSC is not a hot path.


### Area: Grid, rows, cells, history, and scrollback storage (`GRID`)

_Scope: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` (GridCell, GridRow, ScreenState, ScreenOwnership and the alternate-screen switch, resize/refold, the scrollback admission and eviction seam, ProjectionRows, the memory census walk), `LogicalLineStore.swift`, `LogicalLineRecord.swift`, `RetainedHistory.swift`, `TerminalMemoryCensus.swift`. Cross-checked against `references/ghostty`, `references/foot`, `references/xterm`. Not audited: `TerminalDamage.swift` and the per-frame snapshot (FRAME's lane), `TerminalSearch.swift` (FIND's lane), the parser and `EscapeAbsorber.swift` (PARSE's lane), the Unicode tables._

**The auditor's read on the area.** The retained store is the strongest code in the tree. Doc 31's arena has already had its hand-maintained totals turned into derivations -- `bytesInUse`, `grandDisplayRowTotal` and `grandContentUnitTotal` are all read off the cursors or the block ring, with independent recount oracles beside them -- and the earlier construction audit's `STORE-1`, `STORE-4`, `HIST-2` and `ROW-2` are all landed in the tree I read. What is left is not in the bytes: it is at the seams above them. Two of my five findings are one shape -- a rule about the boundary between retained history and the live grid that is written out by hand at every reader instead of once, and a screen-switch vocabulary that a reader has to reconstruct from an `if enabled` chain rather than read off a table. The two correctness items are both "a mode does slightly more or less than the references say", not data loss. I looked at `GridRow`'s spill interning hard, because a cell word is only meaningful relative to its owning row, and found every cross-row move already going through `place` with resolved scalars; I dropped it. I did not run any probe or benchmark, per the brief.

<a id="grid-1"></a>

#### GRID-1. Accept DECSET/DECRST 47 and declare the three alternate-screen switch modes as one table

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#DECPrivateMode`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#applyDECPrivateModes`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#switchAlternateScreen`

**Problem.** DanTerm does not implement private mode 47. `ESC[?47h` is silently ignored, so a program that hardcodes the legacy alternate-screen switch -- rather than reading `smcup` out of terminfo -- draws its full-screen UI straight onto the primary grid and into scrollback, and its `ESC[?47l` restores nothing. All three references implement it. The second half is the same gap seen from the structure side: 1047 and 1049 differ only in *when* the alternate grid is cleared and whether the cursor is saved, and DanTerm expresses that difference as an `if enabled` chain inside `applyDECPrivateModes` plus an unconditional clear inside `switchAlternateScreen`, so adding the third mode means editing both instead of adding a row.

**Evidence.** The mode vocabulary has no 47:

```swift
enum DECPrivateMode: UInt16, CaseIterable {
    ...
    case alternateScreen = 1047
    case savedCursor = 1048
    case alternateScreenAndSavedCursor = 1049
```

and `applyDECPrivateModes` skips anything the enum does not name: `guard let mode = DECPrivateMode(rawValue: rawMode) else { continue }`. `TerminalAlternateScreenTests.switchSideStateAndUnsupportedMode` pins the omission as intended -- it feeds `"\u{1B}[?47h"` and `"\u{1B}[?47l"` and asserts `terminal == expected`.

The references all carry it. Ghostty registers it (`references/ghostty/src/terminal/modes.zig#entries`: `.{ .name = "alt_screen_legacy", .value = 47 }`) and gives the three modes one enum with the per-mode rule stated once (`references/ghostty/src/terminal/Terminal.zig#SwitchScreenMode`, dispatched by `#switchScreenMode`): `47` never clears, `1047` clears **on exit** (`.@"1047" => if (!enabled and self.screens.active_key == .alternate) { self.eraseDisplay(.complete, false); }`), `1049` saves the cursor and clears **on entry**. Foot handles all three in one case block (`references/foot/csi.c#csi_dispatch`, `case 47: case 1047: case 1049:`) and reports all three in DECRPM as "alt grid active". Xterm documents 47 in `references/xterm/ctlseqs.ms`.

DanTerm instead clears on every entry and never on exit:

```swift
private mutating func switchAlternateScreen(enabled: Bool) {
    recordFullDamage()
    if enabled {
        clearInspection()
        if isAlternateScreenActive == false { swapActiveScreen() }
        screen.rows = Deque((0..<rowCount).map { _ in
            makeBlankRow(columns: columnCount, styleId: backgroundEraseStyleId())
        })
```

That clear edge is where the references disagree -- ghostty and xterm clear 1047 on exit, foot clears it on entry -- so it is unobservable while 47 is missing and becomes observable the moment 47 lands, because 47 is the one mode that must show what the previous occupant left behind.

**Ideal fix.** One `AlternateScreenSwitch` value -- `case legacy` (47), `case clearingOnExit` (1047), `case savedCursorClearingOnEntry` (1049) -- carrying the three answers each mode gives (saves the cursor, clears on entry, clears on exit). `DECPrivateMode` maps its three raw values onto it, and `switchAlternateScreen(_ switch:enabled:)` reads the answers off the value. Take ghostty's and xterm's clear edges, since those two are the compatibility authority and foot is the outlier.

**By construction.** "Which mode clears when" stops being a control-flow property spread over two functions and becomes three rows a reader can check against `ctlseqs`. A fourth alternate-screen mode (or a change of clear edge) cannot be added to one site and missed at the other, and 47 cannot be half-supported -- the enum either has the row or it does not.

**Cheaper fallback.** Add `case alternateScreenLegacy = 47` and route it to the existing `switchAlternateScreen(enabled:)`. This buys the compatibility fix and leaves the clear rules where they are -- meaning 47 would clear the alternate grid on entry, matching foot but not xterm or ghostty, and the "when does each mode clear" question keeps having no single place to read the answer.

**Verification.** `TerminalAlternateScreenTests`, replacing the "unsupported" case for 47. Feed `ESC[?1049h` + `"ALT"` + `ESC[?1049l` + `ESC[?47h` and assert `screenText` still shows `ALT` (47 does not clear); feed `ESC[?1049h` + `"ALT"` + `ESC[?1047l` + `ESC[?47h` and assert the grid is blank (1047 cleared on the way out); assert `ESC[?47h` carries the live cursor and `ESC[?47l` returns the primary text; assert DECRQM `ESC[?47$p` answers `ESC[?47;1$y` while the alternate grid is active.

**Risk.** A program that uses 47 today gets its output on the primary grid, which lands in scrollback; after the fix that output is confined to the alternate grid and no longer retained. That is the correct behavior and the reason to make the change, but it is a visible change for any such program. Moving 1047's clear from entry to exit changes nothing observable unless 47 is also present, which is why the two halves belong in one change.

**Vetted.** I opened `Terminal.swift#DECPrivateMode` (809-826), `#applyDECPrivateModes` (6655-6720), `#decPrivateModeStatus` (6609-6629), `#switchAlternateScreen` (7346-7363) and `#swapActiveScreen` (7373-7391), plus `TerminalAlternateScreenTests.switchSideStateAndUnsupportedMode` (97-107). Every quote is verbatim. The enum really jumps 1006 -> 1047, the setter really drops an undecodable raw value with `else { continue }`, `decPrivateModeStatus` really answers 0 for 47, and the test really feeds `ESC[?47h` / `ESC[?47l` and asserts `terminal == expected`. I followed all three citations. Ghostty: `modes.zig:209` is `.{ .name = "alt_screen_legacy", .value = 47 }`, and `Terminal.zig#switchScreenMode` (2962-3030) with `#SwitchScreenMode` (3036-3053) states the three rules exactly as quoted -- `.@"47" => {}`, `.@"1047" => if (!enabled and ... .alternate) self.eraseDisplay(.complete, false)`, `.@"1049" => if (enabled) self.saveCursor()` then `eraseDisplay(.complete, false)` on entry. Its header comment says the behavior was read out of xterm's `charproc.c`. Foot: `csi.c:498-530` really is one `case 47: case 1047: case 1049:` block that clears with `term_erase(...)` on **entry** for all three. Xterm: `ctlseqs.ms:1539` documents 47 as "Use Alternate Screen Buffer", `:1747-1748` documents 1047's reset as "Clear the screen first if in the Alternate Screen Buffer", and `charproc.c#srm_ALTBUF` (7754) calls `ToAlternate`/`FromAlternate` with no clear while the `srm_OPT_ALTBUF` arm above it (7745-7749) clears on the way out. The finding stands.

**Correction.** Two changes to the prose above. First, the clear edge is **already observable today**, without 47: `swapActiveScreen` keeps the alternate grid's contents in `.primaryLive(alternate:)` after an exit, and DanTerm's 1049 clears on entry but not on exit, so `ESC[?1049h` + draw + `ESC[?1049l` + `ESC[?1047h` shows the leftover drawing under xterm's and ghostty's rules and a blank grid under DanTerm's. So the 1047 half is a live deviation on its own, not one that only wakes up when 47 lands. Second, the cost is three edits, not two: `DECPrivateMode` is switched exhaustively in `applyDECPrivateModes`, in `decPrivateModeStatus`, and again in `TerminalStateSynchronizationEncoder.swift#appendControlState` (330), so a new case fails the build in three places until each is answered -- which is the coupling PARSE-4 is about. One nuance the prose does not mention and should: xterm's 47 is dual-assigned (also DECGRPM, Graphic Rotated Print Mode) and is gated on the `titeInhibit` resource, so "xterm implements 47" is true of the default build, not unconditionally.

**Conflicts with.** `PARSE-1`, which is the mode-47 half of this finding reported independently by the parser lane -- implement once. GRID-1 is the fuller statement: PARSE-1 does not carry the clear-edge rule or the `SwitchScreenMode` table, so take GRID-1's shape and let PARSE-1 fold into it. Also `PARSE-4` (rebuilds the same three `DECPrivateMode` switches as a table -- land that first and this becomes one row) and `SELECT-4` (adds `alternateScroll = 1007` to the same enum and the same three switches).

<a id="grid-2"></a>

#### GRID-2. State the history/live seam once, and give a stream row one meaning

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#ProjectionRows`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#scrollbackRow(at:)`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#projectViewportRow`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#projectedViewportCell`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#projectPrimarySeam`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#projectionFollower`

**Problem.** One rule -- "the last retained display row is projected against the live grid's first cell, and may need the wrap spacer the store could not derive" -- is written out by hand in five places, beside a sixth helper (`projectPrimarySeam`) that exists to state it once for the array-materializing readers only. Worse, the conjunct `isAlternateScreenActive == false` appears in four of those copies for a reason that has nothing to do with the seam: "stream row" means two different things depending on the reader. In `ProjectionRows` a stream row is an index into retained history followed by the live rows, so an alternate-screen viewport row `r` is `historyRowCount + r`. In the per-frame viewport path (`viewportStreamRow`, `projectViewportRow`, `projectionFollower`) an alternate-screen stream row is just `r`. The `!alt` guards are there to stop the second convention from accidentally satisfying a test written for the first.

**Evidence.** Five statements of the same predicate. `ProjectionRows.subscript`:

```swift
return row.projected(
    columns: columns,
    follower: position == historyRows - 1 ? live.first?.cells.first : nil,
    fillsMissingWrapSpacer: position == historyRows - 1
        && history.openTailPendingMarginCell != nil,
    missingWrapMargin: history.openTailPendingMarginCell
)
```

`ProjectionRows.forEachRow` repeats the same four lines against a cursor instead of an index. `scrollbackRow(at:)` repeats them with `index` and adds `&& isAlternateScreenActive == false` twice. `projectViewportRow` repeats them with `streamRow`. `projectedViewportCell` repeats them again inside a `Terminal.projectedMarginCell` call. And the two-meanings problem is visible in `projectionFollower`, whose whole body is a fork on the convention:

```swift
private func projectionFollower(after streamRow: Int) -> GridCell? {
    guard isAlternateScreenActive == false else {
        return screen.rows.indices.contains(streamRow + 1)
            ? screen.rows[streamRow + 1].cells.first
            : nil
    }
    if streamRow == historyRowCount - 1 { return screen.rows.first?.cells.first }
```

`TerminalScrollbackRow` and `scrollbackRow(at:)` are `public` and have no caller outside `lib/TerminalCore/Tests` -- a whole public value type and a sixth copy of the seam kept alive for test assertions that `retainedRowForTesting(at:)` already serves.

**Ideal fix.** One private `projectedStreamRow(_ row: GridRow, at streamRow: Int) -> GridRow` on `Terminal`, and its cell-scoped twin, holding the seam rule and the alternate-screen rule together; every reader calls it. Behind that, one meaning for a stream row: the alternate-screen viewport path adopts the projection's convention (`historyRowCount + r`), which is what the anchor and inspection paths already use -- `invalidateInspectionState` computes `evictedRowCount + historyRowCount + range.lowerBound` for exactly this reason. Once a stream row means one thing, every `isAlternateScreenActive == false` conjunct in these five sites is deleted rather than reworded. Fold `scrollbackRow(at:)` into the internal test surface and delete `TerminalScrollbackRow`, or keep it and have it call the shared projector.

**By construction.** The seam rule cannot be applied at four sites and forgotten at the fifth, and "does this index count history?" stops being answerable two ways. The guards that exist only to disambiguate the index disappear with the ambiguity.

**Cheaper fallback.** Extend `projectPrimarySeam` into an index-taking form and call it from the five sites, leaving the two stream-row conventions alone. This removes the copies but keeps the `!alt` conjuncts, which is to say it keeps the hazard and only tidies its symptom.

**Verification.** No behavior should change, which is the assertion. `TerminalRetainedRowReadPathTests`, `TerminalLogicalLineFoldTests` and `TerminalSelectionTests` all pin the seam through the public readers: print a soft-wrapped line whose tail is a wide cluster so the open tail leaves a pending margin, then assert that the last retained row, the same row read through `selectAll()`'s text, the same row read through a double-click `logicalLineRange`, and the same row read through the per-frame viewport walk all agree on the final column -- with the alternate screen both inactive and active.

**Risk.** Changing the alternate-screen stream-row convention touches the per-frame viewport walk, which is the hottest read path in the engine; an off-by-`historyRowCount` there paints the wrong rows in a full-screen TUI. It is worth doing in its own commit with the fold tests green before and after.

**Vetted.** I opened `Terminal.swift#ProjectionRows` (537-620), `#scrollbackRow(at:)` (2863-2887), `#historyCursor(atStreamRow:)` (4147-4152), `#viewportStreamRow` (4154-4164), `#projectViewportRow` (4167-4177), `#projectedViewportCell` (4179-4195), `#projectionFollower` (4197-4208), `#projectPrimarySeam` (4297-4310), `#activeProjectionRows` (4319-4334), `GridRow#projected` (408-432) and `#retainedRowForTesting` (3048-3050). All six statements of the seam predicate are there, and the `projectionFollower` fork is verbatim. The two-conventions claim is real: `ProjectionRows` addresses an alternate-screen viewport row at `historyRows + r` (its `endIndex` is `historyRows + live.count`), while `viewportStreamRow` and `projectionFollower` address it at `r`. One thing the prose understates and I will add in the finding's favour: `projectedViewportCell` calls `Terminal.projectedMarginCell` directly and therefore **re-states by hand** the `row.logicallyContinues && row.marginProvenance == .wideWrap` disjunct that `GridRow.projected` holds internally (line 422). That is a live drift risk between the row-scoped and cell-scoped reads, and it is the strongest argument for the shared projector.

**Correction.** Two claims in the prose are wrong and the payoff shrinks with them. First: `TerminalScrollbackRow` and `scrollbackRow(at:)` are **not** test-only. `lib/TerminalCore/Sources/TerminalRetainedRowProbeSupport/TerminalRetainedRowProbeSupport.swift:392` calls `terminal.scrollbackRow(at: index)` from a separate module and reads `row.cells` as `[TerminalCell]` with resolved `TerminalStyle` and hyperlink target -- which is why the type is public and why `retainedRowForTesting(at:)` cannot replace it: that helper returns an unprojected `GridRow` carrying `StyleId`s, not resolved styles, and applies no seam at all. Delete the "fold it into the internal test surface and delete `TerminalScrollbackRow`" half of the ideal fix; the public reader stays and calls the shared projector. Second: the `isAlternateScreenActive == false` conjuncts do **not** all disappear with the ambiguity. In `scrollbackRow(at:)` and in `ProjectionRows` the index is already unambiguously a history index, and the guard there states a substantive rule -- when the alternate grid is live it is not the continuation of retained history, so the last retained row must not be projected against its first cell, and its `isSoftWrapped` must be forced false. Unifying the stream-row convention **centralizes** that rule inside the shared projector; it does not delete it. Only the two viewport sites (`projectViewportRow`, `projectedViewportCell`), where the guard really is disambiguating an index, lose their conjunct. So the finding is worth doing for the one-copy-of-the-seam payoff, and the convention change is a smaller, riskier second half than the prose suggests -- it should be optional, not load-bearing. Impact drops to 2 accordingly.

**Conflicts with.** `SELECT-3`, which already names this finding: it hoists the `ProjectionRows` subscript out of the two per-column link loops and depends on the seam rules staying inside the accessor. Sequence GRID-2 first so SELECT-3 hoists a call to the shared projector. `GRID-4`, which rewrites `paintedRow`/`materializedGridRow` -- the store-side materializer every one of these six sites is built on. `PROBE-6`, which changes `readRetainedRowShape`'s handling of a nil from `scrollbackRow(at:)`; it does not survive that reader being deleted, which is a further reason not to delete it.

<a id="grid-3"></a>

#### GRID-3. Leave the pending-wrap flag alone when ED 3 erases saved lines

`correctness` &middot; impact 2, confidence 3 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#eraseDisplay`

**Problem.** `ESC[3J` erases the scrollback and nothing else. DanTerm also clears the deferred-wrap flag, so a program that fills the last column, erases saved lines, and then prints one more character overwrites the last column instead of wrapping to the next row. Two references agree the flag must survive.

**Evidence.** DanTerm, in `eraseDisplay`:

```swift
case 3:
    mutateHistory { $0.removeAll() }
    syncHistoryEvictions()
    clearPendingMotionState()
```

and `clearPendingMotionState` is exactly `screen.isPendingWrap = false; clusterContext = nil`. Ghostty resets `pending_wrap` in every other ED branch and deliberately not in this one: `references/ghostty/src/terminal/Terminal.zig#eraseDisplay` ends `.scrollback => self.screens.active.eraseRows(.{ .history = .{} }, null),` with no `pending_wrap` line, while `.complete`, `.below` and `.above` each carry one (or assert it). Foot is the same: `references/foot/csi.c#csi_dispatch` sets `term->grid->cursor.lcf = false` in ED 0, 1 and 2 and its `case 3` is only `term_erase_scrollback(term);`. Xterm's `references/xterm/util.c#do_erase_display` case 3 touches `screen->savedlines` alone.

Nothing pins the current behavior: `CSIEraseTests` asserts `isPendingWrap == false` after an `ESC[3J` whose preceding `ESC[3;2H` had already cleared it, and its combining-mark case (`"A\u{1B}[3J\u{0301}"` still yielding `["A", "\u{0301}"]`) passes today even though `clearPendingMotionState` nils `clusterContext`, so the cluster half of the call is already dead weight on this path.

**Ideal fix.** Delete the `clearPendingMotionState()` call from `case 3`. ED 3 names a region that contains no live cursor state, so it has none to reset.

**By construction.** n/a -- this is a one-line deletion of a side effect that the sequence's definition does not have. The by-construction version of it is GRID-1's shape (an erase mode declared with the state it owns), which is not worth building for one case.

**Cheaper fallback.** None -- the ideal fix is a deletion.

**Verification.** `CSIEraseTests`. On a 3x1 terminal feed `"ABC"`, assert `geometry.cursor?.isPendingWrap == true`, feed `ESC[3J`, assert it is still `true`, then feed `"D"` and assert the screen text is `"D  "` (the wrap fired) rather than `"ABD"`.

**Risk.** A program that relied on ED 3 to shake off a stale wrap would now wrap. No reference behaves that way, so the risk is confined to tests that assert the current shape; I found none.

**Vetted.** I opened `Terminal.swift#eraseDisplay` (7035-7077) and `#clearPendingMotionState` (7284-7287). Both quotes are verbatim: `case 3` really is `mutateHistory { $0.removeAll() }`, `syncHistoryEvictions()`, `clearPendingMotionState()`, and that helper really is exactly the two assignments. All three citations check out. Ghostty `Terminal.zig#eraseDisplay` (2472-2597) ends `.scrollback => self.screens.active.eraseRows(.{ .history = .{} }, null),` with no `pending_wrap` line, while `.scroll_complete` and `.complete` each set `pending_wrap = false` and `.below` / `.above` each `assert(!... .pending_wrap)`. Foot `csi.c` sets `term->grid->cursor.lcf = false` in ED 0 (976), 1 (984) and 2 (991), and `case 3` (994-998) is only `term_erase_scrollback(term);`. Xterm `util.c#do_erase_display` `case 3` (2051-2057) touches `screen->savedlines` and the scrollbar thumb alone. The divergence is exactly as stated.

**Correction.** "Nothing pins the current behavior" is wrong, and it changes what this finding is. `CSIEraseTests.eraseDisplayScrollback` is titled "ED 3 clears only scrollback **and pending motion state**" and its Intent line says "without changing viewport, cursor, pen, or active region, **while ending deferred wrap and attachment** ... the slice-wide side-state policy". `TerminalScrollRegionTests.dispatchSideStateGate` states that policy directly -- "apply the slice-wide side-state policy at the dispatch gate", every recognized effective control clears deferred wrap and grapheme attachment. So the assertion is weak, as the auditor says, but the *intent* is written down twice and this is a deliberate house rule, not an oversight. That reframes the item: it is not a one-line deletion, it is a question about the policy's scope -- should the slice-wide rule yield for a sequence that names no live-grid state at all? The policy's own stated reason ("cursor-stationary scrolls can otherwise leak deferred wrapping into unrelated post-scroll content") does not apply to ED 3, which touches no live cell, so the reference behavior is probably right; but the decision belongs to the user with the policy in front of them, and whatever lands should say why ED 3 is the exception. Reachability is also thin: real ED 3 emitters are `clear`'s `E3` capability and terminal-history menu items, which send it from column 0 with no wrap pending. Confidence drops to 3 for the judgement, not the evidence -- I found every quoted line.

**Conflicts with.** `PARSE-7` ("Stop clearing the wrap latch on CHT and CBT"), which is the same slice-wide side-state policy questioned at a different sequence. They do not touch the same lines, but they are one decision and should be adjudicated together rather than one at a time.

<a id="grid-4"></a>

#### GRID-4. Materialize a retained display row once, in one function

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#paintedRow`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#materializedGridRow`

**Problem.** Two functions with the same twenty-line body differ only by `includeFill: true` versus `includeFill: false`. Each builds a throwaway `[GridCell]` during the fold walk, then builds a second array of default cells of the same length, then re-places every cell into it -- two allocations and two passes where one of each would do. This is the row materializer the whole non-frame read path goes through: selection, search's projection walk, copy, `truncateTail`'s hand-back, and every `paintedDisplayRows(in:)` caller.

**Evidence.** `materializedGridRow`:

```swift
var cells: [Terminal.GridCell] = []
cells.reserveCapacity(width)
forEachFoldedCell(at: cursor, includeFill: false) { _, cell in cells.append(cell) }

var row = Terminal.GridRow(cells: (0..<cells.count).map { _ in Terminal.GridCell() })
for column in cells.indices {
    row.place(
        cells[column],
        scalars: scalars(of: cells[column], recordIndex: cursor.recordIndex, record: record),
        at: column
    )
}
row.isSoftWrapped = isSoftWrapped(at: cursor)
```

`paintedRow(at:)` is the same text with `includeFill: true`. The file's own comment for `FoldedRow` says the fold has "the **one** definition of a display row's shape, so the materializing read and the two borrowing ones cannot drift apart" -- which is true of the shape and not of the two materializers built on it.

**Ideal fix.** One `materializedRow(at cursor:includeFill:)`, with `paintedRow` and `gridRow` as one-line callers. Build the row in the walk: append a default cell and `place` into the index just appended, so the intermediate `cells` array disappears with the second pass.

**By construction.** Two copies of "how a stored row becomes a `GridRow`" become one, so the content read and the painted read cannot drift on the spacer, the split seam, or the prompt stamping they both do by hand today.

**Cheaper fallback.** Collapse the duplication with a shared body and leave the two-pass materialization. That removes the drift risk and none of the per-row allocation.

**Verification.** `TerminalRetainedRowReadPathTests` and `TerminalLogicalLineFoldTests` unchanged: the painted read must still carry the trailing fill to the margin and the content read must still stop at the line's cells, for a row with a wide cluster at the fold boundary, a spilled multi-scalar cell, and a background-erase fill. For the cost half: `just test-perf`-style instrument counts are the wrong tool here; the deciding experiment is `swift test --package-path lib/TerminalCore --filter TerminalHistoryTailCostProbe` before and after, where the retained-row allocation count per materialized row must fall from two arrays to one.

**Risk.** `GridRow.place` writes through `cells[column]`, so the appended-then-placed order must be exact; a spilled cell placed at an index that does not yet exist traps. The existing fold tests cover the spill case.

**Vetted.** I opened `LogicalLineStore.swift#paintedRow` (1659-1680) and `#materializedGridRow` (2496-2522) side by side. They are the same twenty lines, differing only in `includeFill: true` versus `includeFill: false` -- same `record` fetch, same `reserveCapacity(width)`, same `(0..<cells.count).map { _ in Terminal.GridCell() }` second array, same `place` loop, same `isSoftWrapped`, same `rowWithinRecord == 0` prompt stamping. `gridRow(at:)` (1647-1649) is a one-line forward to the private one. Both quotes are verbatim, and the `FoldedRow` comment at 2590 says what the auditor quotes. The two-allocations-two-passes reading is right: one array from the walk, a second from the `map`, then a re-place over the first.

**Correction.** Two refinements, one of which enlarges the finding. There is a **third** copy of the same "build a `GridRow` from cells plus resolved scalars" shape at `LogicalLineStore.swift:1350`, inside `pullBackOpenTailRemainder` -- `let suffix = (last.start..<last.end).map { ... }` then `Terminal.GridRow(cells: (0..<suffix.count).map { _ in Terminal.GridCell() })` then the same `place` loop. It does not fold through `forEachFoldedCell`, so it cannot share `materializedRow(at:includeFill:)`, but it can and should share the builder underneath it; a `GridRow` initializer that takes (cell, scalars) pairs and places as it appends removes all three double-allocations at once. Second, the Verification's cost half names the wrong instrument: `TerminalHistoryTailCostProbe` is env-gated and measures wall clock, not allocation counts, so it cannot show "two arrays fall to one". That claim is structural and is settled by reading the resulting function, not by running the probe; keep the probe only as a no-regression check.

**Conflicts with.** `SELECT-3`, which already names this finding -- it hoists `ProjectionRows`'s subscript (and therefore `paintedRow`) out of two per-column loops, and the two edits meet in the same materializer. `GRID-2`, whose shared projector sits directly on top of `paintedRow` / `paintedDisplayRow`. Neither is exclusive; do GRID-4 first, since it is the innermost of the three.

<a id="grid-5"></a>

#### GRID-5. Make `multiScalarAllocationCount` count one thing

`correctness` &middot; impact 2, confidence 4 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalMemoryCensus.swift#multiScalarAllocationCount`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#memoryCensus`

**Problem.** The census field is documented as "Class-backed scalar storage allocations, one per multi-scalar cell", and the walk counts it two different ways: once per spilled *cell* for retained history, once per *row* that has any spill table for the live screens. The documented representation is also gone -- since spills moved into `GridRow`, a live row's spill storage is one outer array plus one array per payload, and none of it is class-backed. A reader adding the two halves gets a number that is neither cells nor allocations, and `agent-docs/measurement-discipline.md`'s bar is that a metric means one thing before anyone acts on a difference between two of them.

**Evidence.** Retained half:

```swift
history.store.forEachStoredCell { styleId, isSpilled in
    ...
    if isSpilled {
        census.multiScalarCellCount += 1
        census.multiScalarAllocationCount += 1
    }
}
```

Live half, in the same property:

```swift
for row in screens.flatMap({ $0 }) {
    census.cellCount += row.cells.count
    if row.hasSpillAllocation { census.multiScalarAllocationCount += 1 }
```

`GridRow.spillStorageBytes` shows what a live row actually holds -- `spills.capacity * MemoryLayout<[Unicode.Scalar]>.stride` plus a header and a payload buffer per entry -- so the true live allocation count is `1 + spills.count`, not `1`.

**Ideal fix.** Count allocations, uniformly: for a live row, one for the spill table plus one per payload array it holds; for a retained record, one per stored spill payload. Restate the doc comment as "heap allocations backing multi-scalar cell payloads, across live rows and retained records" and drop "class-backed". If a per-row number is separately wanted, it is a separate field with its own name, not the same field counted differently on one branch.

**By construction.** The `spillStorageBytes` accessor already knows the row's allocation shape; having the census ask the row for its count -- rather than restate a shape at the call site -- means the two cannot disagree the next time the spill representation moves.

**Cheaper fallback.** Fix only the doc comment to say what the code counts. That leaves a field whose unit changes by branch, which is the part that makes a census number unusable as evidence.

**Verification.** `TerminalMemoryCensusTests`. Print a row holding three distinct multi-scalar clusters, assert `multiScalarCellCount == 3` and `multiScalarAllocationCount == 4` (the table plus three payloads) while those cells are live; scroll the row into history and assert the count is 3 (one payload each, no per-row table in the arena) with `multiScalarCellCount` unchanged.

**Risk.** Any frozen threshold or recorded number that quotes this field moves. It is measurement-only -- no engine path reads the census -- so the blast radius is documents, and `agent-docs/measurement-discipline.md` requires a re-measure when a metric's definition changes.

**Vetted.** I opened `TerminalMemoryCensus.swift` (109-118), `Terminal.swift#memoryCensus` (2956-3038), `GridRow#spillStorageBytes` (301-309) and `#hasSpillAllocation` (311). Every quote is verbatim. The retained walk really does `census.multiScalarAllocationCount += 1` once per spilled cell (3008), the live walk really does it once per row with `row.hasSpillAllocation` (3020), and the doc comment really still reads "Class-backed scalar storage allocations, one per multi-scalar cell". So the two-units claim is established. I also checked the retained side's real shape: `LogicalLineStore.SideTables` holds `spillsBySequence: [Int: [[Unicode.Scalar]]]`, so a retained record with N spilled cells owns N payload arrays **plus** one outer array -- the auditor's proposed "one per stored spill payload" undercounts the retained side by one per record, the same way the live side is undercounted today.

**Correction.** The ideal fix as written contradicts a landed decision and must not be implemented. `plans/impl/2026-08-24-1610-trivially-copyable-live-cell.md` deliberately redefined this field: its contract line says "`multiScalarAllocationCount` counts live row spill allocations. Counting allocations alone cannot see one allocation whose capacity grows without bound, which is the shape I4 forbids", and its Scope line names "`TerminalMemoryCensus` (the live term of `cellStorageBytes` and **the meaning of** `multiScalarAllocationCount`)". Two tests pin that meaning: `TerminalMemoryProbeSupportTests.swift:93` asserts `multiScalarAllocationCount <= multiScalarCellCount`, and `TerminalCellRepresentationTests.swift:89` asserts it equals 1 for a single-cluster live row. Counting `1 + spills.count` per row -- and the Verification's expected `4` -- breaks both, and discards the growth-detection reason the per-row count was chosen for. Also drop the "none of it is class-backed" argument: a Swift `Array`'s buffer *is* a class instance, so the stale half of the comment is "one per multi-scalar cell", not "class-backed". What survives is real and worth fixing: one field carries two units. The right fix is the auditor's own fallback, done properly -- rename or restate the field to the unit the plan chose ("spill-table allocations, one per live row that holds one, one per retained record that holds one") and change the **retained** branch to that unit, rather than changing the live branch to the retained one. If a per-payload count is wanted for the growth check, it is a second field with its own name. Impact stays 2 (measurement hygiene, no engine path reads it); confidence stays 4 because the evidence is verified and the prescription is not.

**Conflicts with.** Nothing in the other lanes touches `memoryCensus` or `multiScalarAllocationCount` -- I grepped all fourteen. `PROBE-3` and `PROBE-6` consume census-derived numbers in the probe support but do not redefine this field, so they only need re-running after any unit change, per `agent-docs/measurement-discipline.md`.

#### Dropped (GRID)

- **`GridRow`'s spill index being row-relative.** A `GridCell`'s word can name a spill in a row that no longer owns it, which looked like the strongest by-construction target in the area. Every cross-row move in the tree already goes through `GridRow.place(_:scalars:at:)` with scalars resolved from the *source* row -- reflow's `ReflowUnit.headScalars`, `upgradeClusterToWide`, `resizedRectangle`'s same-row copy -- and `place` rebuilds the word from kind and style, so a stale index is not reachable. Dropped.
- **`place`'s undocumented ordering.** In its multi-scalar branch `place` clears `cells[column].word` *before* calling `intern`, because `intern` may compact and would otherwise re-point the target cell at a payload it is replacing. Correct, load-bearing, and uncommented -- worth a comment in whatever change next touches the function, not a finding.
- **Dead spill payloads after an erase.** Erasing a spilled cell writes a fresh `GridCell` straight into `cells`, so the payload lives on until the next `intern` triggers compaction. The `GridRow` doc states this as the amortization it chose, and the waste is bounded by the compaction threshold. Dropped.
- **`ED 3` and the open grapheme cluster.** `clearPendingMotionState` also nils `clusterContext`, which reads like a bug. `CSIEraseTests`'s `"A\u{1B}[3J\u{0301}"` case proves a recovery path re-attaches the mark, so only the pending-wrap half of GRID-3 is real. Recorded there rather than as its own finding.
- **`retainsRowsScrolledOffTop`.** DanTerm retains rows only when the scroll region's top is row 0 and the primary screen is live. Ghostty's `Terminal.zig#index` and `#scrollUp` gate scrollback on exactly `scrolling_region.top == 0` (plus full width, which DanTerm has no left/right margins to violate). Matches; dropped.
- **`admit`'s silent drop of an unfittable row.** `guard worstCase <= regionCapacityBytes else { return }` loses a display row, and the logical-line structure with it, when one row cannot fit a backing chunk. That needs roughly 4,090 columns at the 64 KiB chunk floor. The store documents the degenerate configuration as deliberately reachable-but-empty rather than a trap. Dropped as unreachable in practice.
- **`ProjectionRows` subscripting per row.** `logicalLineRange` walks a soft-wrap chain with `stream[first - 1]`, one `locate` and one full row materialization per row, so a double-click on a 200-row wrapped line pays 200 locates. This is the documented trade for point-local queries (`activeProjection()` versus `activeProjectionRows()`) and it is a pointer-gesture path, not a frame path. GRID-4 removes half the per-row cost anyway. Dropped as already owned by the design note.
- **STORE-1, STORE-4, HIST-2, ROW-2 from `docs/scratch/2026-08-18-construction-audit.md`.** All four are landed in the tree I read: `bytesInUse` is now a computed ring span, `originalCellOffset(recordIndex:retainedOffset:)` states the trim base once, `contentCellCount` short-circuits on `hasWideCells == false`, and `GridCell` is a `CellWord` plus two sentinel-0 ids with spills held by the row. Nothing re-reported.


### Area: Resize, reflow, and soft wrap (`REFLOW`)

_Scope: `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- `resize`,
`resizePrimaryScreen`, `resizeHeight`, `resizeWidth`, `reconstructLogicalLines`,
`pack`, `reflowDestination`, `resizedRectangle`, `resizeAlternateState`,
`clampScreenCursorState`, `resizeTabStops`, `retainedContentEnd`,
`makeBlankRow`, `projectedLiveRows`, and the `Reflow*` / `TrackedCursor` /
`WidthChangeAnchor` types; plus `TerminalGeometry.swift#TerminalRowStructure`.
Cross-checked against `references/ghostty/src/terminal/{PageList,Screen,Terminal,page}.zig`,
`references/kitty/kitty/{resize.c,screen.c}`,
`references/alacritty/alacritty_terminal/src/grid/row.rs`,
`references/wezterm/term/src/screen.rs`, `references/xterm/charproc.c`.
Every behavioral claim below was reproduced by feeding bytes to
`TerminalCore.Terminal` in a throwaway package outside the tree._

**The auditor's read on the area.** The hard parts are in good shape. Wide-cell
folding and unfolding round-trips exactly, the wrap spacer is rebuilt at the new
width rather than carried, the seam pull-back between history and the live
refold is carefully ordered, the saved cursor now rides the reflow (BUG-16 /
BUG-17 are genuinely landed), and the height-grow scrollback pull-back matches
ghostty's cursor-at-the-bottom rule. The defects that remain all share one
shape: **reflow decides what a row contains by looking only at cell `kind`, and
rebuilds everything else from a default.** `retainedContentEnd` calls a
background-colored blank "not content", so a width change erases every themed
blank on the primary screen; trailing rows are recreated by `makeBlankRow` at
the default style rather than carried; a cursor parked in a row's trailing
blanks is reduced to a scalar `distance` that is then clamped instead of
re-folded; a blank continuation row has no identity of its own, so a cursor on
it snaps to the head of its logical line. Cost has the same root: the refold
builds a per-cell destination dictionary and two heap arrays per cell so that
exactly two tracked cursors can be looked up. I did not audit the history side
(`LogicalLineStore#setWidth`, `truncateTail`) beyond the seam call sites -- doc
31 owns it and history no longer reflows. I looked at tab-stop resize and at the
scroll-region reset and dropped both; they match the references.

<a id="reflow-1"></a>

#### REFLOW-1. Re-fold the cursor's trailing-blank distance instead of clamping it into the last column

`correctness` &middot; impact 4, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#reflowDestination`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#reconstructLogicalLines`

**Problem.** When the cursor sits in a row's trailing blanks, reflow records
only `distance` -- how many cells past the content end it sat -- and then places
it at `min(contentEnd.column + distance, columns - 1)`. If the refolded line
fills the destination row exactly, that clamp parks the cursor **on** the last
committed character with no wrap armed, and the next printed scalar overwrites
committed output. The code already knows this: the `distance == 0` case was
fixed by arming `isPendingWrap`, and the comment names the exact regression
("some long long texX"). The identical regression is still live for
`distance >= 1`, because the pending-wrap spelling was bolted onto one value of
`distance` rather than onto the arithmetic.

**Evidence.** `Terminal.swift#reflowDestination`:

```swift
let desired = packed.contentEnd.column + distance
return ReflowDestination(
    row: baseRow + packed.contentEnd.row,
    column: min(desired, columns - 1),
    isPendingWrap: distance == 0 && packed.contentEnd.column == columns
)
```

`distance` comes from `Terminal.swift#reconstructLogicalLines`:
`.trailingPadding(line: rowMetadata.line, distance: max(0, tracked.column - rowMetadata.retainedEnd), allPaddingColumn: nil)`.

Probe, 6 columns x 3 rows. Feed `"abcd\u{1b}[6G"` (content ends at column 4,
cursor parked at column 5, so `distance == 1`), then `resize(columns: 4, rows: 3)`,
then feed `"X"`:

- observed: `|abcX| |    | |    |`, cursor `(row: 0, column: 3, isPendingWrap: true)`
- control with `\u{1b}[5G` (`distance == 0`): `|abcd| |X   |`, cursor `(row: 1, column: 1)`

The `d` is destroyed. The correct destination, by DanTerm's own logical model,
is `contentEnd + distance` folded at the new width: row 1, column 0.

Note for whoever fixes this: **this is not a reference divergence, it is a
divergence from DanTerm's own stated rule.** ghostty
(`references/ghostty/src/terminal/PageList.zig#ReflowCursor.reflowRow` --
`if (p.x >= cols_len) p.x = @min(p.x, self.page.size.cols - 1 - self.x)`) and
kitty (`references/kitty/kitty/resize.c#update_tracked_cursors` --
`if (t->dest_x > dest_xnum) t->dest_x = dest_xnum`) both clamp a
past-the-content pin into the destination row too. What makes DanTerm's case a
defect is the invariant `reflowDestination`'s own comment states: "DanTerm has
no one-past-the-end cursor column ... Reflow has to use that same spelling, or
the distinction is lost in the clamp." It uses that spelling for one value of
`distance` and the lossy clamp for every other.

**Ideal fix.** Delete the clamp. `contentEnd` and `distance` already give a
logical column; fold it: `let desired = packed.contentEnd.column + distance`,
then `row += desired / columns`, `column = desired % columns`, with the single
boundary rule "column `== columns` is spelled as `columns - 1` plus
`isPendingWrap`". That one rule replaces both the `min(...)` and the
`distance == 0 &&` special case. The stronger version, if the wide-cell
bookkeeping allows it, is to stop modelling the trailing blanks as a scalar at
all: append blank `ReflowUnit`s up to the tracked cursor's column so it resolves
through `cellDestinations` like any other cell (this is exactly ghostty's
`cols_len = @max(cols_len, p.x + 1)`), which deletes `.trailingPadding` outright.

**By construction.** A cursor column outside `0..<columns` stops being
reachable from reflow at all, rather than being made unreachable by a clamp
that silently changes which character the cursor is on. The
`distance == 0 && ...` conjunction -- a rule stated for one value of a variable
-- stops existing.

**Cheaper fallback.** Change the `isPendingWrap` condition to
`packed.contentEnd.column + distance >= columns`. Trade-off: it stops the
overwrite but still puts the cursor on the wrong cell for `distance >= 2` (all
of them collapse onto the margin), so a shell that repositions with `CSI n G`
still redraws in the wrong place. It does not remove the clamp.

**Verification.** `lib/TerminalCore/Tests/TerminalCoreTests/TerminalResizeTests.swift`.
At 6x3 feed `"abcd\u{1b}[6G"`, `resize(columns: 4, rows: 3)`, feed `"X"`;
assert `screenText` row 0 is `"abcd"` and row 1 starts `"X"`. Add the same for
`distance == 2` (`"abcd\u{1b}[7G"` at 8 columns narrowed to 4) asserting row 1
column 1. Both assert projected text and the public cursor, so they survive any
refactor of the anchor types.

**Risk.** Any test that pinned the clamped column. Grep `TerminalResizeTests`,
`TerminalSavedCursorResizeTests` and `TerminalPromptAnchorResizeSweepTests` for
cursor expectations after a narrowing; the saved cursor goes through the same
`placed(...)`, so its expectations move too.

**Vetted.** I opened `Terminal.swift#reflowDestination` (6253-6306) and
`#reconstructLogicalLines` (6082-6211). Both quotes are verbatim, including the
`isPendingWrap: distance == 0 && packed.contentEnd.column == columns`
conjunction and the `.trailingPadding(... distance: max(0, tracked.column -
rowMetadata.retainedEnd), allPaddingColumn: nil)` construction. I rebuilt the
probe in a throwaway SwiftPM package against `lib/TerminalCore` and reproduced
both runs exactly: 6x3 `"abcd\u{1b}[6G"` then `resize(columns: 4, rows: 3)`
lands the cursor on `(row: 0, column: 3, isPendingWrap: false)`, and the next
`"X"` yields `|abcX|` with the wrap then armed -- the committed `d` is gone. The
`\u{1b}[5G` control gives `|abcd| |X   |`. I also ran the `distance == 2` case
(8 columns, `"abcd\u{1b}[7G"`, narrow to 4): same `(0, 3)` landing, same `abcX`.
I followed both citations. ghostty's
`PageList.zig#ReflowCursor.reflowRow` line 1245 is exactly
`if (p.x >= cols_len) p.x = @min(p.x, self.page.size.cols - 1 - self.x);`, and
kitty's `resize.c#update_tracked_cursors` line 161 is exactly
`if (t->dest_x > dest_xnum) t->dest_x = dest_xnum;`. The finding's own framing --
this is a divergence from DanTerm's stated rule, not from the references -- is
therefore honest and holds.

**Correction.** Two numbers in the prose are wrong, and the verification section
inherits both. The cursor's logical position is `contentEnd + distance`, so for
`distance == 1` at width 4 the destination is offset 5, which folds to **row 1,
column 1** -- not "row 1, column 0", which is the `distance == 0` answer. For the
`distance == 2` case it is row 1, column 2, not column 1. Rewrite the
verification accordingly: after the narrowing and `"X"`, row 0 must still read
`"abcd"` and row 1 must read `" X"` (a leading blank), not `"X"` at column 0.
One reference the finding does not cite argues *for* the ideal fix rather than
merely permitting it: wezterm folds instead of clamping.
`references/wezterm/term/src/screen.rs#Screen.rewrap_lines` builds
`logical_cursor_x = cursor_x + prior.len()` from the raw cursor column
(trailing blanks included) and then resolves it with
`let num_lines = x / physical_cols; let last_x = x - (num_lines * physical_cols);`
-- literally the `desired / columns`, `desired % columns` the ideal fix
proposes. So the ideal fix has a working precedent, and the "everyone clamps"
reading of the references is incomplete.

**Conflicts with.** `REFLOW-3` and `REFLOW-5`, which restructure the same
`ReflowCursorAnchor` cases and the same `reflowDestination` switch; the three are
one edit, not three. `REFLOW-4`, which rewrites `reconstructLogicalLines` to
resolve cursors during the pack walk and deletes `sourceOffsets`/`cellDestinations`
outright -- do the anchor arithmetic first, or REFLOW-4 lands on top of a
`reflowDestination` that no longer exists in the shape it assumes.

<a id="reflow-2"></a>

#### REFLOW-2. Carry each row's fill style through the refold instead of rebuilding blanks at the default style

`correctness` &middot; impact 4, confidence 5 &middot; effort medium &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#retainedContentEnd`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#resizeWidth`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#pack`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#resizedRectangle`

**Problem.** A width change on the primary screen destroys every
background-colored blank. Three separate places do it: `retainedContentEnd`
scans for `.narrow`/`.wideHead` only, so trailing colored padding is outside
`iterationEnd` and never becomes a `ReflowUnit`; `pack` seeds each packed row
from `makeBlankRow(columns:)` at `Terminal.defaultStyleId`; and `resizeWidth`
re-creates every row below the content with the same default `makeBlankRow`.
The alternate screen, which goes through `resizedRectangle`, keeps its colors --
so the two screens disagree about whether a resize preserves a painted
background.

**Evidence.** `Terminal.swift#retainedContentEnd`:

```swift
guard let lastContent = row.cells.lastIndex(where: { cell in
    cell.kind == .narrow || cell.kind == .wideHead
}) else { return 0 }
```

`Terminal.swift#resizeWidth`:

```swift
for _ in 0..<trailingBlankRowCount {
    rebuiltRows.append(makeBlankRow(columns: newColumnCount))
}
```

and `Terminal.swift#pack`: `var packedRows = [makeBlankRow(columns: columns)]`.
Against `Terminal.swift#resizedRectangle`, which the alternate screen uses:
`var cells = Array(source.cells.prefix(columns))` -- the source cells, styles
included.

Probes:

- 4x3, feed `"\u{1b}[41m\u{1b}[2J\u{1b}[H"`, then `resize(columns: 5, rows: 3)`.
  Every cell's background is `.indexed(1)` before and `.default` after. The
  whole painted screen is gone.
- 6x3, feed `"\u{1b}[H\u{1b}[41mAB\u{1b}[K"`, then `resize(columns: 8, rows: 3)`.
  Row 0 backgrounds go from `[i1 x6]` to `[i1, i1, -, -, -, -, -, -]`.
- Control, same bytes as the first probe on the alternate screen
  (`\u{1b}[?1049h` first): after `resize(columns: 5, rows: 3)` the backgrounds
  are `[i1, i1, i1, i1, -]` -- preserved, with only the new column defaulted.
- Control, height-only `resize(columns: 4, rows: 4)`: the existing three rows
  keep `.indexed(1)`. Only the width leg loses them.

**What the references do.** ghostty preserves: `references/ghostty/src/terminal/page.zig#Cell.isEmpty`
returns `false` for `.bg_color_palette` / `.bg_color_rgb`, and
`references/ghostty/src/terminal/PageList.zig#ReflowCursor.reflowRow` computes
`cols_len` by trimming on `isEmpty()`, so a colored blank is copied like any
character and a row of them is not deferred as blank. alacritty preserves:
`references/alacritty/alacritty_terminal/src/grid/row.rs#Row.reset` sets
`self.occ = len` whenever the erase template's discriminant differs, and reflow
in `grid/resize.rs` folds up to `occ`. wezterm preserves:
`references/wezterm/term/src/screen.rs#Screen.rewrap_lines` appends whole `Line`s
and never trims trailing cells. kitty is the one that drops them --
`references/kitty/kitty/resize.c#init_src_line` trims while
`cpu_cells[x].ch_and_idx == BLANK_CHAR`, which ignores the background in
`gpu_cells`. Three to one, and DanTerm's own alternate screen sides with the
three.

**Who notices.** Any prompt or program that paints a background on the primary
screen and then the window is resized: a powerlevel10k / starship right prompt
that fills with `\e[K` under a themed background, `printf '\e[44m'; clear`,
`fastfetch`'s color bars, `ls --color` backgrounds followed by a resize. The
color vanishes and only a repaint brings it back -- and the shell has no reason
to repaint scrollback.

**Ideal fix.** Make the refold carry provenance instead of re-deriving a blank.
Two parts, both structural rather than a special case:

1. Give the reflow its own content-end rule -- "the last cell with a visible
   effect", text *or* a non-default style id -- and use that as `iterationEnd`
   for a hard-ended row. Do not widen `retainedContentEnd` itself: its other
   readers (`rowStructure.contentEnd`, prompt reclaim, the text projections)
   genuinely mean "last text cell", and conflating the two would change what
   Copy emits.
2. Stop rebuilding rows the refold does not fold. Rows past `lastSourceRow`
   should be passed through the same width adjustment the alternate screen
   already uses (`resizedRectangle`'s truncate-and-pad), not recreated. And
   `pack` should seed a packed row from the fill style of the source row that
   started the line, not from `Terminal.defaultStyleId`.

Part 2 is the one that matters most: a row nothing folded should not be
*constructed* at all.

**By construction.** "A row's fill color is whatever the last erase set" stops
having a second, contradictory answer produced by the resize path. The primary
and alternate screens stop disagreeing about a resize's effect on a painted
background, because both go through one width-adjustment rule for rows that do
not fold.

**Cheaper fallback.** Only fix part 2 (carry trailing rows through, seed packed
rows from the source style) and leave `iterationEnd` alone. Trade-off: the
whole-screen paint survives, but `\e[41mAB\e[K` still loses the red to the right
of `AB`, which is the case the themed right-prompt actually hits.

**Verification.** `lib/TerminalCore/Tests/TerminalCoreTests/TerminalCellStyleTests.swift`
or `TerminalResizeTests.swift`, asserted through the public
`Terminal.cell(row:column:)?.style.background`:
(a) 4x3, feed `"\u{1b}[41m\u{1b}[2J\u{1b}[H"`, `resize(columns: 5, rows: 3)`,
expect `.indexed(1)` at every original column and `.indexed(1)` at the new one
(the erase style is the row's fill);
(b) 6x3, feed `"\u{1b}[H\u{1b}[41mAB\u{1b}[K"`, `resize(columns: 8, rows: 3)`,
expect `.indexed(1)` across row 0;
(c) the alternate-screen control, so the two screens are pinned to agree.

**Risk.** `retainedContentEnd`-adjacent behavior is load-bearing for the text
projections and for prompt reclaim, so the fix must keep those on the text-only
rule -- if the reflow rule leaks into `rowStructure.contentEnd` or
`projectedCellEnd`, Copy starts emitting trailing spaces. Widening what counts
as content also means a colored-but-empty row is no longer trimmed as a trailing
blank on a width change, which shifts how many rows the viewport-fill pull-back
asks history for; `TerminalPromptAnchorResizeSweepTests` is the suite most
likely to move.

**Vetted.** I opened `Terminal.swift#retainedContentEnd` (6376-6389),
`#resizeWidth` (5655-5830), `#pack` (6308-6374) and `#resizedRectangle`
(5534-5562). All four quotes are verbatim: the `.narrow || .wideHead` scan, the
`makeBlankRow(columns: newColumnCount)` trailing-row loop, `var packedRows =
[makeBlankRow(columns: columns)]`, and `var cells = Array(source.cells.prefix(columns))`.
I ran all four probes and every one reproduced. 4x3 `"\u{1b}[41m\u{1b}[2J\u{1b}[H"`
then `resize(columns: 5, rows: 3)`: every background goes from `indexed(1)` to
`default` on every row -- the painted screen is erased. 6x3
`"\u{1b}[H\u{1b}[41mAB\u{1b}[K"` widened to 8: row 0 goes from six `indexed(1)`
to `indexed(1), indexed(1)` and six defaults. The alternate-screen control keeps
`indexed(1), indexed(1), indexed(1), indexed(1), default`, and the height-only
control keeps all four. So the primary/alternate disagreement is real and
measured, not inferred. One mechanical detail worth recording for whoever fixes
it: a *soft-wrapped* row is already safe, because `iterationEnd` is
`oldColumnCount` for it and its `.padding` cells become `ReflowUnit`s with their
style. Only hard-ended rows lose paint, which is why the `\e[K` case and the
whole-screen `\e[2J` case are the two shapes that break.

**Correction.** The reference tally is looser than the prose claims. ghostty is
exactly right: `page.zig#Cell.isEmpty` (2112-2124) returns `false` for
`.bg_color_palette` / `.bg_color_rgb`, and `PageList.zig#reflowRow` trims
`cols_len` on `isEmpty()`, so colored blanks copy like text. alacritty reaches
the same answer by a different route than the one cited: `Row.reset` sets
`self.occ = len` only to dirty the cells and then sets `self.occ = 0` on the way
out, and `grid/resize.rs` reads `occ` exactly once (line 352, constructing a new
`Row`). What actually preserves the paint is `term/cell.rs#Cell::is_empty`
(226-239), which requires `self.bg == Color::Named(NamedColor::Background)` --
so `Row::shrink` and `Row::is_clear` both treat a colored blank as occupied.
Same conclusion, wrong mechanism. wezterm is **mixed**, not a clean preserve:
`screen.rs#rewrap_lines` pushes a whole `Line` only while `line.len() <=
physical_cols`, and the wrapping path calls
`wezterm-surface/src/line/line.rs#Line::wrap` (214-246), which does
`cells.iter().rposition(|c| c.str() != " ")` and truncates -- dropping trailing
colored blanks, attributes ignored, on any narrowing that wraps. So the honest
tally is: ghostty and alacritty preserve, kitty drops, wezterm preserves on a
widen and drops on a wrapping narrow. That is still enough to justify the fix,
but the load-bearing argument is DanTerm's own alternate screen disagreeing with
its primary, which I reproduced -- not a 3-to-1 vote.

**Conflicts with.** `REFLOW-4` and `REFLOW-6`, which both rewrite the body of
`pack`; REFLOW-2 part 2 reseeds the packed row's fill style in the same lines
REFLOW-4 restructures. `REFLOW-7`, directly: REFLOW-7 asks for *one* blankness
predicate shared by `resizeHeight`'s trim, `rowContainsContent`, and
`retainedContentEnd(in:) == 0`, while REFLOW-2 insists the reflow gets its own
content-end rule and `retainedContentEnd` stays text-only. Decide which of the
two rules the unified predicate states before either lands, or the second one
re-splits what the first merged.

<a id="reflow-3"></a>

#### REFLOW-3. Give a cursor on a blank continuation row a row of its own instead of snapping it to the line head

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#reconstructLogicalLines`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#reflowDestination`

**Problem.** When the tracked cursor sits on a row that is entirely padding, the
attachment becomes `.trailingPadding(line:distance: 0, allPaddingColumn:)`, and
`reflowDestination` resolves that to `baseRow` -- the *first* row of the packed
logical line. If the blank row is a continuation of a soft-wrapped line above
it, `baseRow` can be several rows up, so the cursor lands on top of committed
text instead of on blank space. The all-padding case is the one branch that
ignores the row it came from entirely.

**Evidence.** `Terminal.swift#reconstructLogicalLines`:

```swift
} else if rowMetadata.retainedEnd == 0 {
    anchor = .trailingPadding(
        line: rowMetadata.line,
        distance: 0,
        allPaddingColumn: tracked.column
    )
}
```

`Terminal.swift#reflowDestination`:

```swift
if let allPaddingColumn {
    return ReflowDestination(
        row: baseRow,
        column: min(allPaddingColumn, columns - 1),
        isPendingWrap: false
    )
}
```

`baseRow` is `rebuiltRows.count` at the start of the line, not the row the
cursor was on. `rowMetadata.line` is shared by every row of a wrapped line, so
every blank continuation row of that line resolves to the same `baseRow`.

Probe, 4x4. Feed `"abcdefg"` (row 0 `abcd` soft-wrapped, row 1 `efg`), then
`"\u{1b}[2;1H\u{1b}[K"` (blank the continuation row, leaving row 0's wrap claim
standing), then `"\u{1b}[2;3H"`:

- before: cursor `(row: 1, column: 2)`, grid `|abcd| |    | |    | |    |`
- after `resize(columns: 6, rows: 4)`: cursor `(row: 0, column: 2)`, grid
  `|abcd  | |      |` -- the cursor is now on the `c`.

**What the references do.** ghostty keeps the row alive precisely for this:
`references/ghostty/src/terminal/PageList.zig#ReflowCursor.reflowRow` computes
`cols_len == 0` for a blank row and would defer it, but the tracked-pin block
runs first and raises `cols_len = @max(cols_len, p.x + 1)`, with the comment
"This ensures that blank rows with pins are processed, so that the pins can be
properly remapped." The pin therefore lands on its own row.

**Ideal fix.** Stop making the all-padding row a special anchor case. Once
REFLOW-1's arithmetic exists, a cursor on a blank continuation row is just a
logical offset within its line -- `rowMetadata.boundaryOffset + tracked.column`
-- folded at the new width, which naturally lands past the line's content. The
`allPaddingColumn` payload and the `retainedEnd == 0` branch both disappear.
Fixing REFLOW-1 and REFLOW-3 together is one change, not two.

**By construction.** `ReflowCursorAnchor` loses a case whose payload
(`allPaddingColumn`) exists only to smuggle a column past an anchor that already
lost the row it belonged to.

**Cheaper fallback.** Carry the cursor's row offset within its line
(`tracked.row - firstRowOfLine`) in the anchor and add it to `baseRow`.
Trade-off: it fixes the placement but keeps the three-case anchor enum and the
`min(..., columns - 1)` clamp, so the row offset is only right while the line's
row count does not change -- which is the one thing a width reflow does.

**Verification.** `TerminalResizeTests.swift`: the probe above, asserting the
public cursor is `(row: 1, column: 2)` after the widen, and that feeding `"X"`
afterwards leaves row 0 as `"abcd"`.

**Risk.** Low on its own. It shares a code path with REFLOW-1, so land them
together or the second one rewrites the first one's tests.

**Vetted.** Both quotes are verbatim -- the `retainedEnd == 0` branch at
`Terminal.swift` 6224-6230 and the `if let allPaddingColumn` block at 6278-6284
-- and `baseRow` really is `rebuiltRows.count` captured before the line is
packed (`resizeWidth`, line 5717). I reproduced the probe. At 4x4, `"abcdefg"`
then `"\u{1b}[2;1H\u{1b}[K"` then `"\u{1b}[2;3H"` gives cursor `(row: 1, column:
2)`; `resize(columns: 6, rows: 4)` gives `(row: 0, column: 2)` with row 0 reading
`"abcd  "`, so the cursor is sitting on the `c` and the next scalar overwrites
committed text. The ghostty citation is exact:
`PageList.zig#reflowRow` lines 1250-1253 are
`// We increase our col len to at least include this pin. / // This ensures that
blank rows with pins are processed, so that the pins can be properly remapped. /
cols_len = @max(cols_len, p.x + 1);`.

**Correction.** The verification's expected value is wrong. After the widen, the
cursor cannot be `(row: 1, column: 2)`: its logical offset within the line is
`boundaryOffset + column == 4 + 2 == 6`, which at width 6 folds to **row 1,
column 0**. (ghostty would answer row 0, column 5 instead, because it clamps the
pin into the destination row before raising `cols_len`; either answer is
defensible, `(1, 2)` is neither.) Assert the folded value, or assert only the
property that actually matters and is stable under either rule: after the widen,
printing `"X"` must leave row 0 reading `"abcd  "` unchanged.

**Conflicts with.** `REFLOW-1` and `REFLOW-5` -- same enum, same
`reflowDestination` switch, one edit between them, exactly as the Risk paragraph
says. `REFLOW-4`, which deletes the anchor-resolution machinery this finding
reshapes.

<a id="reflow-4"></a>

#### REFLOW-4. Resolve the tracked cursors during the pack walk instead of building a per-cell destination map

`cost` &middot; impact 2, confidence 4 &middot; effort medium &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#reconstructLogicalLines`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#pack`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#PackedReflowLine`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#ReflowUnit`

**Problem.** A width change builds, per live cell: one `[GridCell]` heap array,
one `[(key: Int, offset: Int)]` heap array, one `Set<Int>` insert, and one
`[Int: ReflowDestination]` dictionary insert -- so that at most two tracked
cursors and nine held anchors can be looked up. The work scales with how much
screen exists, not with what the resize needs to know. Live drag-resize runs
this per geometry step.

**Evidence.** `Terminal.swift#ReflowUnit` is
`{ cells: [GridCell]; headScalars: TerminalScalars; sourceOffsets: [(key: Int, offset: Int)] }`
and `reconstructLogicalLines` allocates one per cell:

```swift
currentLine.units.append(ReflowUnit(
    cells: [cell],
    headScalars: row.scalars(of: cell),
    sourceOffsets: [(key: key, offset: 0)]
))
retainedSourceKeys.insert(key)
```

`pack` then does, once per unit:

```swift
for source in unit.sourceOffsets {
    cellDestinations[source.key] = ReflowDestination(...)
}
...
boundaryDestinations[logicalOffset] = column == columns ? ... : ...
```

The consumers are `reflowDestination` (`packed.cellDestinations[key]`, called
for `trackedCursors.count == 2` entries) and the `captured` loop in
`resizeWidth` (`packed.boundaryDestinations[offset]`, at most the nine
`WidthChangeAnchor` slots). `retainedSourceKeys` is read exactly once, in
`retainedSourceKeys.contains(key)` for each tracked cursor. The wide branch also
inserts each key twice -- `retainedSourceKeys.insert(key)` and then
`for source in sources { retainedSourceKeys.insert(source.key) }` over a list
that already contains it.

`resizeWidth` additionally materializes `projectedLiveRows(Array(screen.rows[...lastSourceRow]))`
before reconstruction, so the grid is walked into three representations (rows ->
units -> packed rows) per resize.

**Ideal fix.** The reflow already knows each tracked cursor's source
`(row, column)` before it walks. Convert that to a logical offset within its
line during reconstruction -- the walk maintains `logicalOffset` already -- and
have `pack` record a destination when its own running `logicalOffset` reaches a
wanted one. That is one comparison against a two-element array per unit, and it
deletes `cellDestinations`, `boundaryDestinations`, `retainedSourceKeys`,
`sourceKey`, and `ReflowUnit.sourceOffsets` outright. `ReflowUnit.cells` can
become the head `GridCell` plus a width, since the only two-cell case is a wide
pair whose tail `pack` already synthesizes. This is not a cache -- it removes a
lookup structure rather than adding one; the authority (the pack walk) answers
directly.

**By construction.** The refold stops holding a key-to-destination table that
can disagree with the rows it packed, and `sourceKey`'s `row * columns + column`
encoding -- an ad-hoc flattening that must agree between two functions -- stops
existing.

**Cheaper fallback.** Keep the maps but `reserveCapacity` them and skip the
duplicate `retainedSourceKeys` inserts in the wide branch. Trade-off: it trims
the constant and leaves the per-cell allocation and the per-cell dictionary
growth in place, which is where the time is.

**Verification.** `swift run --package-path lib/TerminalCore -c release TerminalResizeProbe --recipe wide --samples 200`
(the committed saturated-history probe;
`lib/TerminalCore/Sources/TerminalResizeProbeSupport/TerminalResizeProbeSupport.swift`
documents the recipes). The `wide` payload is the full-width regime whose cost
is cell-dominated, which is exactly the term this finding attacks. The number
that must move is the per-resize wall-clock distribution -- median and p95 --
with the row and cell counts unchanged. Pair it with an allocation count under
`heaptrack`/Instruments Allocations on one resize at 200x60 to confirm the
per-cell arrays are gone. Correctness is held by the existing
`TerminalResizeTests`, `TerminalSavedCursorResizeTests`,
`TerminalLogicalLineFoldTests`, and `TerminalPromptAnchorResizeSweepTests`
suites, which assert projected text and cursors, not the maps.

**Risk.** The offset-based resolution must handle a wide pair straddling the new
margin, where `pack` inserts a spacer and the logical offset advances by two
while the destination column does not. `TerminalLogicalLineFoldTests` and the
wide-character resize cases are the workload that would catch a mistake. On
cost, nothing should get slower: the removed structures have no other reader. If
`ReflowUnit` is shrunk to a head cell plus a width, a line made entirely of wide
characters is the workload to re-check, since it now synthesizes tails in `pack`
for every unit.

**Vetted.** Every structural claim is in the tree. `ReflowUnit` (859-863) holds
exactly the three stored properties quoted; `reconstructLogicalLines` builds one
per cell in the `.narrow, .padding` branch (6168-6175) with a one-element
`cells:` array and a one-element `sourceOffsets:` array; `pack` writes
`cellDestinations[source.key]` per source offset and `boundaryDestinations[logicalOffset]`
per unit (6349-6362). The consumer count is right: `cellDestinations` is read
only at 6266 for the two `trackedCursors`, `boundaryDestinations` only at 6297
and in `resizeWidth`'s `captured` loop (5732), and `retainedSourceKeys` only at
6221. The duplicate insert in the wide branch is real -- `retainedSourceKeys.insert(key)`
at 6152 and `insert(tailKey)` at 6162, then `for source in sources { retainedSourceKeys.insert(source.key) }`
at 6164-6166 over a list that already holds both. `projectedLiveRows(Array(screen.rows[...lastSourceRow]))`
is at 5687, so the three-representation walk is real too. The ideal fix does
remove the structures it names, and the `sourceKey` flattening goes with them.

**Correction.** Rescored to impact 2. The code is confirmed, but the *payoff* is
not: this is a `cost` finding with no measurement behind it, and the auditor's
own dropped-item note (`projectedLiveRows` was "not the allocation cost I first
suspected") shows how easily this area misleads. The work is bounded by the live
grid alone -- history has not reflowed since doc 31, and `sourceRows` stops at
`lastSourceRow` -- so a 200x60 pane costs about 24k small allocations plus 24k
hash inserts per width step, once per geometry change rather than once per
frame. That is worth removing, but as a simplification with an allocation
benefit rather than as a latency defect; the honest sequencing is to run the
committed `TerminalResizeProbe --recipe wide` baseline *first* and drop the
finding if the distribution does not move. The by-construction half of the
argument -- deleting `cellDestinations`, `boundaryDestinations`,
`retainedSourceKeys`, `sourceKey`, and `ReflowUnit.sourceOffsets` -- stands on
its own regardless.

**Conflicts with.** `REFLOW-1`, `REFLOW-3` and `REFLOW-5`, which reshape the
anchor enum and `reflowDestination` that this finding deletes; land the three
correctness fixes first and let this one delete the result. `REFLOW-2` and
`REFLOW-6`, which both edit `pack`'s body. Also note that its verification
command runs through `lib/TerminalCore/Sources/TerminalResizeProbe/main.swift`,
which `PROBE-5` rewrites -- not a code conflict, but the recipe-override flags
this finding invokes are the ones PROBE-5 changes.

<a id="reflow-5"></a>

#### REFLOW-5. Hoist the reflow line index into the attachment once and split the trailing-padding anchor into its two real shapes

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#ReflowCursorAnchor`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#ReflowCursorAttachment`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#reflowDestination`

**Problem.** The reflow line index is stored twice, and the two copies are
consumed inconsistently. `.inLine(anchor:line:)` carries a `line`, and two of
the three `ReflowCursorAnchor` cases carry their own `line` as well.
`reflowDestination` matches the `.cell` case against the outer `cursorLine` and
the other two against the inner `line`, ignoring `cursorLine` entirely. They are
always assigned the same value today, so this is latent rather than live -- but
it is a hand-maintained mirror of a fact the attachment already owns, and it is
one of the two payload duplications in this small enum. The other is
`.trailingPadding(line:distance:allPaddingColumn:)`, which is really two
different anchors: "N cells past the content end" (`distance` meaningful,
`allPaddingColumn` nil) and "somewhere on a row with no content at all"
(`allPaddingColumn` meaningful, `distance` always the dead literal `0`).

**Evidence.** The declarations:

```swift
private enum ReflowCursorAnchor {
    case cell(key: Int)
    case trailingPadding(line: Int, distance: Int, allPaddingColumn: Int?)
    case boundary(line: Int, offset: Int)
}

private enum ReflowCursorAttachment {
    case inLine(anchor: ReflowCursorAnchor, line: Int)
    case belowContent(rowsBelow: Int, column: Int)
}
```

and the inconsistent consumption in `Terminal.swift#reflowDestination`:

```swift
guard case let .inLine(anchor, cursorLine) = attachment else { return nil }
switch anchor {
case let .cell(key) where lineIndex == cursorLine:
...
case let .trailingPadding(line, distance, allPaddingColumn) where line == lineIndex:
...
case let .boundary(line, offset) where line == lineIndex:
```

`reconstructLogicalLines` sets all three from the same `rowMetadata.line`, and
the `distance: 0` literal beside a non-nil `allPaddingColumn` is written out in
full in the `retainedEnd == 0` branch.

**Ideal fix.** `case inLine(line: Int, anchor: ReflowCursorAnchor)` with
`ReflowCursorAnchor` reduced to `case cell(key: Int)`, `case boundary(offset: Int)`,
`case pastContentEnd(distance: Int)`, `case blankRow(column: Int)`. The guard in
`reflowDestination` becomes one `guard line == lineIndex` before the switch,
rather than three per-case `where` clauses that can drift.

**By construction.** An attachment whose outer and inner line numbers disagree
stops being expressible, and so does a `.trailingPadding` carrying both a
distance and an all-padding column. Three `where` clauses collapse into one
guard. Note that REFLOW-1 and REFLOW-3 between them delete
`pastContentEnd`/`blankRow` anyway, so this is worth doing as part of that
change rather than on its own.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** No behavior change, so the proof is that the existing resize
suites stay green: `swift test --package-path lib/TerminalCore --filter Resize`
plus `TerminalLogicalLineFoldTests` and `TerminalSavedCursorResizeTests`. If any
of them changes, the refactor was not behavior-preserving.

**Risk.** None beyond a mechanical rewrite; the types are `private` to
`Terminal` and have no other reader.

**Vetted.** Both enum declarations are verbatim at `Terminal.swift` 879-883 and
898-901, and the three `where` clauses in `reflowDestination` are verbatim at
6264-6297: `.cell` is guarded by `lineIndex == cursorLine` (the outer payload)
while `.trailingPadding` and `.boundary` are guarded by `line == lineIndex` (the
inner one), so `cursorLine` is genuinely unread for two of three cases. I
checked the assignment site: `reconstructLogicalLines` builds all three anchors
from `rowMetadata.line` and then returns `.inLine(anchor: anchor, line:
rowMetadata.line)` (6222-6252), so the two copies cannot disagree today. The
"latent, not live" reading is correct, and the `distance: 0` literal beside a
non-nil `allPaddingColumn` is written out in full as claimed. `private` and no
other reader confirmed by grep. Nothing here needs correcting.

**Conflicts with.** `REFLOW-1` and `REFLOW-3`, which delete the two cases this
finding renames -- the finding says so itself, and it is right: do it as part of
that change. `REFLOW-4`, which deletes `.cell(key:)` and `sourceKey` too.

<a id="reflow-6"></a>

#### REFLOW-6. Stamp reflowed continuation rows by the same rule printing uses, not for every marked line

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#pack`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#stampSemanticContinuationAfterLineAdvance`

**Problem.** Printing stamps `.continuation` on a new row only when the shell is
inside a prompt or input region. Reflow stamps it on every wrapped row of any
line whose head carries *any* mark -- including `.output` and `.vacated`. So a
width change invents prompt-continuation rows in the middle of program output,
and a row's semantic mark stops being a function of what the shell said.

**Evidence.** `Terminal.swift#pack`, in both wrap branches:

```swift
if line.semanticPrompt != .none {
    packedRows[row].semanticPrompt = .continuation
}
```

against `Terminal.swift#stampSemanticContinuationAfterLineAdvance`:

```swift
} else if screen.semanticContent == .prompt || screen.semanticContent == .input {
    screen.rows[screen.cursor.row].semanticPrompt = .continuation
}
```

`.output` really is stamped on a row -- `Terminal.swift` line 2058,
`screen.rows[screen.cursor.row].semanticPrompt = .output` on OSC 133 C -- and
`.vacated` at line 2750, so both reach `pack` as `line.semanticPrompt`.

**Ideal fix.** Have `pack` reuse the printer's predicate rather than restating
it: continuation rows inherit `.continuation` only when the line's head is
`.prompt` (or the input equivalent), and inherit `.none` otherwise. Better, make
that predicate one named function on `SemanticPromptRow` (`wrapsAsContinuation`)
that both the printer and the packer call, so the two cannot drift again.

**By construction.** "Which line kinds wrap into a continuation row" stops being
a rule written twice, in two dialects (one over `screen.semanticContent`, one
over `line.semanticPrompt`).

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** I could not build a probe for this: `semanticPrompt` is not on
`TerminalRowStructure` or any other public projection, which is why confidence
is 4 and not 5. The honest test is a unit test in
`TerminalSemanticPromptInvariantTests.swift` asserting through whatever
prompt-region query the engine does expose -- feed OSC 133 A, a prompt, OSC 133 C,
enough output to wrap, then resize the width, and assert the reported prompt
region is unchanged. If no public query distinguishes them, the right first step
is to decide whether `.continuation` is observable at all; if it is not, this
becomes a pure simplification.

**Risk.** `topOfStalePromptHeads` and `clearPromptForResizeIfNeeded` both walk
these marks, so changing which rows carry `.continuation` changes where the
prompt-repaint vacate starts. `TerminalPromptAnchorResizeSweepTests` is the
suite that would show it.

**Vetted.** Both quotes are verbatim -- `pack` at 6325-6327 and 6338-6340,
`stampSemanticContinuationAfterLineAdvance` at 8365-8372 -- and both line
numbers for the other stamps are right to the line: `screen.rows[screen.cursor.row].semanticPrompt
= .output` on OSC 133 C at 2058, `.vacated` at 2750. `reconstructLogicalLines`
does carry them into `line.semanticPrompt` (6135-6137), so `pack` really does
stamp `.continuation` under an `.output` or `.vacated` head. Confidence raised
to 5, because the auditor's stated reason for holding it at 4 does not survive:
the mark **is** observable in-tree. `Terminal.semanticPromptRowsForTesting`
(3140-3157) projects it per row and four existing suites already assert through
it (`CSIEraseTests`, `TerminalSemanticPromptInvariantTests`,
`TerminalPromptAnchorResizeSweepTests`). It is observable outside the process
too: `TerminalStateSynchronizationEncoder#appendRowState` (580-591) emits
`OSC 133;S;mark=continuation` per row, and `Terminal.swift:2084` parses it back.
So this finding is testable exactly as written.

**Correction.** The prescribed fix is the wrong way round, and the "who
notices" claim is weaker than it reads. On impact: I walked both readers, and
`.continuation` and `.none` fall in the same branch of
`clearPromptForResizeIfNeeded` (`case .continuation, .none: start -= 1`, line
2718) while `topOfStalePromptHeads` tests `== .prompt` only. So no in-engine
behavior changes today; what leaks is the `mark=` field of a state-sync dump.
Impact 2 is right, but it is a naming-consistency defect, not a repaint defect.
On the fix: `pack` is not the outlier. `LogicalLineStore` states the same rule
twice more --
`row.semanticPrompt = record.semanticPrompt == .none ? .none : .continuation` at
1677 and 2519, plus the trimmed-head case at 1069 -- so the store's meaning of
`.continuation` is "a display row of a marked logical line that is not its
head", which is precisely what `pack` implements. Bending `pack` to the
printer's predicate would make the refold disagree with how retained lines
rematerialize, replacing one drift with another. The finding should read: pick
one meaning for `.continuation` across the printer, the packer, and the two
store materializers, and name it once; if the store's meaning wins, it is the
*printer* that needs the shared predicate.

**Conflicts with.** `REFLOW-2` and `REFLOW-4`, which rewrite the same `pack`
body. `GRID-4`, which merges `LogicalLineStore#paintedRow` and
`#materializedGridRow` -- the two sites holding the other copies of the
`.continuation` rule this finding is really about; do GRID-4 first so there is
one store-side copy to align with instead of two.

<a id="reflow-7"></a>

#### REFLOW-7. Have the height-shrink trim read `logicallyContinues`, like every other line-structure reader

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#resizeHeight`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#GridRow.logicallyContinues`

**Problem.** `GridRow` documents `logicallyContinues` as "what every
line-structure reader -- admission, reflow, the text projections -- consumes in
place of `isSoftWrapped`", with the raw claim kept only for xterm parity and for
`geometry`. The height-shrink trailing-blank trim reads the raw claim. A blank
row carrying a stale wrap claim (`isSoftWrapped == true`,
`marginProvenance == .erase`) therefore blocks the trim that `logicallyContinues`
says should proceed, and the shrink displaces a content row into scrollback
instead of dropping a blank one.

**Evidence.** `Terminal.swift#resizeHeight`:

```swift
while screen.rows.count > newRowCount,
      screen.rows.indices.last.map({ $0 > screen.cursor.row }) == true,
      let last = screen.rows.last,
      last.isSoftWrapped == false,
      last.cells.allSatisfy({ $0.kind == .padding })
```

`Terminal.swift#GridRow`:

```swift
var logicallyContinues: Bool { isSoftWrapped && marginProvenance != .erase }
```

The same function's own sibling path, `resizeWidth`, goes through
`projectedLiveRows` and `row.logicallyContinues`. This is the one resize reader
still on the raw claim.

**Ideal fix.** Change the condition to `last.logicallyContinues == false`. The
row's blankness test should also use the same rule the rest of the resize path
uses for "no content" rather than a third spelling of it (`allSatisfy { $0.kind == .padding }`
versus `Self.rowContainsContent` versus `retainedContentEnd(in:) == 0`); pick one
predicate and call it from all three.

**By construction.** The raw `isSoftWrapped` keeps exactly the two readers the
doc grants it (xterm-parity erase behavior and `geometry`), so a new reader
cannot quietly pick the ungated claim. One "is this row blank" predicate instead
of three.

**Cheaper fallback.** none -- the ideal fix is one identifier.

**Verification.** I did not manage to construct a probe where the stale claim
changes the observable outcome: reaching a last row that is blank, wrap-claiming
and above a row that must then displace needs a specific erase sequence I could
not land in the time available, so confidence is 4 on the rule violation and I
am explicitly not claiming a reproduced user-visible defect. Treat this as a
rule-conformance fix. The regression guard is the existing
`TerminalStaleWrapClaimTests.swift` plus a new case there: build a stale claim on
the last blank row, shrink the height, and assert `screenText` keeps the content
row that a raw-claim read would have displaced.

**Risk.** Trimming more rows than before on a height shrink changes how many
rows reach scrollback in the stale-claim case. `TerminalScrollbackTests` and
`TerminalStaleWrapClaimTests` are the suites to watch.

**Vetted.** Both quotes are verbatim: the trim loop at `Terminal.swift`
5594-5599 with `last.isSoftWrapped == false`, and
`GridRow.logicallyContinues` at 394. The doc comment above it (390-393) says
what the finding says it says, word for word: "what every line-structure reader
-- admission, reflow, the text projections -- consumes in place of
`isSoftWrapped`. The raw claim stays untouched for xterm parity and stays
visible through `geometry`; this is the only meaning it has anywhere else." I
grepped the resize path and confirmed this is the last raw-claim reader in it.

**Correction.** Rescored up to a reproduced correctness defect, impact 3,
confidence 5. The auditor could not build the probe; I did, twice, and the
outcome is a visible content row lost on a window shrink. The reachable state
needs a wrap claim on the *last* row, which a plain print cannot leave there --
but a scroll region that excludes the last row can, which is the case
`advanceToNextRow`'s own comment already names ("Reachable by inline-viewport
TUIs that pin a footer with `CSI 1;N r` and print below it"). At 4x3 columns x 4
rows: `"\u{1b}[1;1HXY"`, then `"\u{1b}[1;3r"`, then `"\u{1b}[4;1Habcde"` (the
print wraps onto the last row, which the region will not scroll, leaving
`isSoftWrapped == true` there), then `"\u{1b}[4;1H\u{1b}[2K"` (EL 2 blanks it and
sets `marginProvenance = .erase`), then `"\u{1b}[r\u{1b}[1;1H"`. `rowStructure`
confirms row 3 as `soft=false stale=true end=0`. Now `resize(columns: 4, rows: 3)`:
the trim declines, `"XY"` is displaced into scrollback (`scrollbackRowCount`
goes 0 -> 1), and the screen reads three blank rows. The control -- the same
build with the claim withdrawn -- keeps `"XY"` on row 0 and displaces nothing.
The same defect is reachable a second way with no scroll region at all, through
the state-synchronization restore spelling `OSC 133;S;mark=none;wrap=stale`,
which is a production path (`Terminal.swift:2098-2100`). So this is not a
rule-conformance tidy-up; it is a resize that scrolls visible content away, and
the new case belongs in `TerminalStaleWrapClaimTests` asserting `screenText` and
`scrollbackRowCount` together.

**Conflicts with.** `REFLOW-2`, on the "pick one predicate" half of the ideal
fix: REFLOW-2 requires the reflow's content-end rule to count a colored blank as
content while `retainedContentEnd` keeps meaning "last text cell", so a single
shared blankness predicate has to choose which of the two it states. The
one-identifier half (`last.isSoftWrapped` -> `last.logicallyContinues`) conflicts
with nothing and can land alone.

#### Dropped (REFLOW)

- **Tab stops across a width change.** `Terminal.swift#resizeTabStops` intersects
  with the new range and re-seeds defaults past the old width. That is exactly
  `references/kitty/kitty/screen.c#screen_resize`, which calls `init_tabstops`
  on a fresh buffer and then `memcpy`s the overlapping prefix. Correct as
  written.
- **Scroll region reset on resize.** `Terminal.swift#resize` sets
  `scrollRegion = nil` unconditionally. `references/ghostty/src/terminal/Terminal.zig#resize`
  resets `scrolling_region` to the full grid, and xterm's `ScreenResize` resets
  the margins. No divergence.
- **Saved cursor through resize.** BUG-16 and BUG-17 from the 2026-08-18 audit
  are landed: `resizeWidth` tracks the saved slot as `savedCursorIndex` through
  the same `reflowDestination`, and `resizeHeight`'s shrink and grow branches
  both displace `screen.control.savedCursor.position.row`. Verified in the tree,
  nothing live. (The saved cursor does inherit REFLOW-1 and REFLOW-3, since it
  goes through the same `placed(...)`.)
- **Height-grow scrollback pull-back condition.** `resizeHeight` pulls history
  back only when `screen.cursor.row == rowCount - 1`. That is
  `references/ghostty/src/terminal/PageList.zig#resizeWithoutReflow`'s
  `if (cursor.y >= self.rows - 1) break :cursor` -- "we don't want to pull down
  scrollback ... purely a UX feature". Matches.
- **Height-then-width ordering.** `resizePrimaryScreen` always runs
  `resizeHeight` before `resizeWidth`; ghostty's `PageList.resize` runs cols
  first when columns *grow*. I could not construct an observable difference --
  `resizeWidth`'s own `deficit` pull-back absorbs the widening case -- so I am
  not filing it. Worth a second look by anyone touching this path.
- **Wide-character folding and unfolding.** Probed 5 -> 4 -> 8 columns with a
  wrapped pair of `U+754C`: the `.spacerHead` is dropped on the way in
  (`pendingSpacerKeys`), rebuilt by `pack` when `columns - column == 1`, and the
  pair rejoins its line at the wider width. Correct.
- **Alternate-screen width resize.** `resizedRectangle` truncates and pads
  without reflow and clears every wrap claim on a width change, matching
  ghostty's `reflow = false` for the alternate. Correct -- and it is the *primary*
  path that diverges from it (REFLOW-2).
- **Reflow gated on DECAWM.** `references/ghostty/src/terminal/Terminal.zig#resize`
  passes `.reflow = self.modes.get(.wraparound)`; DanTerm always reflows the
  primary. With autowrap off there are no new wrap claims to fold, so I could
  not turn this into an observable defect and dropped it.
- **`repairClippedCells` / `clippedBlank`.** Reachable only from
  `resizedRectangle`, i.e. the alternate screen, where truncation really can
  split a wide pair. Correct and not dead.
- **`projectedLiveRows` copy in `resizeWidth`.** `GridRow.projected` returns
  `self` unchanged unless the margin cell differs, so copy-on-write keeps the
  cell arrays shared. Not the allocation cost I first suspected; folded into
  REFLOW-4 as a note rather than filed.


### Area: Render planning, render execution, and sprites (`DRAW`)

_Scope: `lib/TerminalCore/Sources/TerminalRenderPlanning/` (all 4 files),
`lib/TerminalCore/Sources/TerminalRenderExecution/` (all 15 files),
`lib/TerminalCore/Sources/TerminalSpriteGeometry/` (all 8 files),
`lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift`, the presentation
path in `app/SwiftTerminalSessionView.swift`, and the draw-benchmark harness in
`scripts/terminal-headless-draw-arm.swift` /
`scripts/terminal-headless-draw-compare.py`. Sprite families were checked scalar
by scalar against `references/ghostty/src/font/sprite/draw/`._

**The auditor's read on the area.** The sprite half is in very good shape. I
compared the Powerline set (including all eight diagonals and both caps), the
Geometric Shapes set, the Block Elements shade alphas, and the Legacy Computing
supported ranges against ghostty's pinned `draw/*.zig` and found no deviation --
the mappings, the triangle vertices, and the `0x40/0x80/0xc0` shade values all
agree. The damage bitset in `TerminalDamage.swift` is careful and I could not
break its barrel shift, its coverage predicates, or its halo. What the remaining
defects share is a single shape: **a fact that some other value already owns is
carried a second time, and the second copy has to be maintained.** Each run
carries the row index that the array holding it already is (DRAW-1); the planner
carries a hand-written model of the executor's routing that is missing a whole
branch (DRAW-2); the ANSI palette carries sixteen hand-written fields plus a
switch to index them (DRAW-4); the box-drawing table carries a nil slot per
scalar that a second switch has to answer for (DRAW-5). The other cluster is rot
in things the gate does not compile: the headless draw benchmark, the tool this
whole lane would be measured with, has not built since `13db5f73` (DRAW-3). I
deliberately did not re-derive the pure pixel geometry of each sprite family
against ghostty's rasterizer -- DanTerm's are stated as deliberate DanTerm
policies in `docs/terminal-sprites.md` and are covered by exhaustive geometry
tests, so comparing rasterized bitmaps was out of proportion to the return. I
also looked at and dropped the swapchain acquisition order and the incremental
erase/plan-set arithmetic in `renderApplyShape`: I worked both through by hand
and they are correct (see Dropped).

<a id="draw-1"></a>

#### DRAW-1. Delete the `row` field from the four run types, so a run's row is the array that holds it

`structural` &middot; impact 3, confidence 5 &middot; effort medium &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift#RenderBackgroundRun`, `#RenderOverlayRun`, `#RenderTextRun`, `#RenderDecorationRun`, `#RenderPlanRow`, `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift#FramePlanner.plan(for:searchReadout:reusing:damage:)`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift#RenderPlanRowSelection`

**Problem.** Commit `3bea76c5` made the plan row-indexed: `RenderFramePlan.rows`
is `[RenderPlanRow]`, and `rows[i]` is row `i` by construction. Every run inside
`rows[i]` nevertheless still stores its own `row: Int`, a hand-maintained mirror
of the index it lives at. Two costs follow. First, a state that should not be
representable is: a run whose `row` disagrees with its container's index -- and
the tree carries a test whose only job is to check that mirror agrees. Second,
the mirror has to be *rewritten* every time a row moves, so the reuse path pays
four array allocations and a full copy of every run in every shifted row, on
every scrolling frame, purely to renumber a field the destination index already
states.

**Evidence.** `RenderFramePlanner.swift` opens with four extensions whose sole
purpose is renumbering:

```swift
extension RenderBackgroundRun {
    fileprivate func translated(to row: Int) -> RenderBackgroundRun {
        RenderBackgroundRun(row: row, startColumn: startColumn, ...)
    }
}
```

and the reuse loop spends them per shifted row:

```swift
rows[row] = RenderPlanRow(
    backgroundRuns: sourceRow.backgroundRuns.map { $0.translated(to: row) },
    overlayRuns: sourceRow.overlayRuns.map { $0.translated(to: row) },
    textRuns: sourceRow.textRuns.map { $0.translated(to: row) },
    decorationRuns: sourceRow.decorationRuns.map { $0.translated(to: row) },
    inkClass: sourceRow.inkClass
)
```

The identity branch two lines above already shows what the shifted branch could
be: `rows[row] = reusable.rows[row]`. The mirror is what stops the shifted
branch from being the same statement. And
`lib/TerminalCore/Tests/TerminalRenderPlanningTests/RenderPlanAssertions.swift#assertCanonical`
pins the mirror four times:

```swift
for (rowIndex, row) in plan.rows.enumerated() {
    for run in row.backgroundRuns {
        #expect(run.row == rowIndex, comment, sourceLocation: sourceLocation)
```

Consumers all sit next to the index already: `drawRenderFrame` reads `run.row`
at sixteen sites, in loops of the form `for row in rows { for run in
row.backgroundRuns { ... row: run.row ... } }` -- the row index is one variable
away in every one of them.

**Ideal fix.** Remove `row` from `RenderBackgroundRun`, `RenderOverlayRun`,
`RenderTextRun`, and `RenderDecorationRun`. Make `RenderPlanRowSelection` yield
`(index, RenderPlanRow)` pairs instead of bare rows, and have the four drawing
loops and `drawDecorationRuns` take the row from the pair. The planner's
`translated(to:)` extensions and the whole shifted-copy branch disappear:
`rows[row] = reusable.rows[source]`, one array-element copy, four retains,
whatever the shift. The four `#expect(run.row == rowIndex)` assertions in
`assertCanonical` disappear because the property they test becomes a type-level
fact.

**By construction.** "A run whose `row` disagrees with the `RenderPlanRow` index
that holds it" stops being expressible, and with it the class of bug where a
reuse path forgets to renumber one of the four layers -- exactly the bug the
four near-identical `translated(to:)` bodies exist to avoid making. It also
removes the `Int` from four public `Equatable` values, so plan equality stops
depending on a redundant field.

**Cheaper fallback.** Keep the field and only fast-path the shift by reusing
`sourceRow` wholesale when `delta` happens to be zero. That is nearly free to
write and removes nothing: the mirror stays representable, the four renumbering
extensions stay, the four assertions stay, and the real scroll case (`delta !=
0`, which is every scroll) still pays the copy.

**Verification.** `swift test --package-path lib/TerminalCore --filter
TerminalRenderPlanningTests` and `--filter TerminalRenderExecutionTests`.
The behavioral pins that must stay green without editing their assertions:
`PaneFramePlanningTests`' reuse-across-scroll cases (the reused plan must equal
a freshly planned one for the same terminal state), and
`BitmapTestSupport`'s redraw-equivalence check -- an incremental scroll render
must produce byte-identical pixels to a full redraw. Those two together prove
the renumbering was load-bearing only as bookkeeping.

**Risk.** Touches every public run type, so `lib/TerminalHostTools`
(`GlyphPreview/main.swift`), `TerminalBenchmarkMarkers`, and the four
`RenderFramePlan+FlatTestAccessors.swift` copies must move in the same change.
The row-carrying `.row` predicates in `PaneFramePlanningTests` (lines 272-360)
are structure-sensitive and will need rewriting to index rows instead -- which
is the point, but it is churn.

**Vetted.** I opened all four run types in
`TerminalRenderPlanning.swift` (`RenderBackgroundRun` line 326,
`RenderOverlayRun` 358, `RenderTextRun` 396, `RenderDecorationRun` 445): each
really does store `public let row: Int`, and `RenderPlanRow` (line 241) really
does hold them per row inside `RenderFramePlan.rows` (line 281). The four
`translated(to:)` extensions are verbatim at `RenderFramePlanner.swift:159-206`,
and the reuse loop at lines 306-323 is verbatim, including the identity branch
`rows[row] = reusable.rows[row]` two lines above the shifted branch. The four
`#expect(run.row == rowIndex)` assertions are at
`RenderPlanAssertions.swift:20, 34, 48, 64`. `RenderPlanRowSelection.Iterator`
(`TerminalRenderExecution.swift:568-584`) already carries `private var index`
and increments it before yielding, so handing out `(index, row)` is a two-line
change -- the ideal fix's one load-bearing precondition holds. `PaneFramePlanner`
is the live caller (`app/SwiftTerminalSessionView.swift` publishes through it),
so the shifted branch runs on real scroll frames rather than only in tests.

**Correction.** Two numbers in the prose are off, both in the finding's favour
being *smaller* than stated. `drawRenderFrame` and `drawDecorationRuns` read
`run.row` at nineteen sites, not sixteen. And the cost half is more modest than
"four array allocations and a full copy of every run" suggests: the copy is four
`map`s over short arrays whose payloads ride along by reference, so a 66-row
viewport scrolled by one pays on the order of 260 small array allocations and a
few hundred retain/release pairs -- tens of microseconds on a scroll frame, not
a dominant cost. The finding stands on its structural half. That is why impact
moves from 4 to 3: the mirror is currently correct at every site, pinned by a
test, and what the fix removes is a maintenance hazard plus a modest allocation,
against churn across roughly a hundred `.row` reads in tests, five
`RenderFramePlan+FlatTestAccessors.swift` copies, and
`TerminalBenchmarkMarkers`.

**Conflicts with.** `PROBE-7`, directly: it rewrites
`lib/TerminalCore/Sources/TerminalBenchmarkMarkers/TerminalBenchmarkMarkers.swift#scan(_:limitedToRows:)`
around the exact line this finding must change
(`guard rows == nil || rows!.contains(run.row)`, line 128). Only one of the two
can define that guard; land them together. `DRAW-2` and `DRAW-7` edit the same
`FramePlanner.plan` row body but different statements, so those three are
independent modulo merge noise.

<a id="draw-2"></a>

#### DRAW-2. Classify a sprite cell's ink as the cell band, not as unmeasured font ink

`cost` &middot; impact 3, confidence 5 &middot; effort medium &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift#FramePlanner.plan(for:searchReadout:reusing:damage:)`, `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift#RenderRowInkClass`, `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderInkReach.swift#renderRowReaches(of:envelope:cellHeightPixels:)`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift#spriteClassificationMinimumScalar`

**Problem.** `RenderRowInkClass` is the planner's model of which draw path a
row's cells will take, and the reach ledger sizes every incremental erase from
it. The model has three branches and is missing a fourth. A single-scalar cell
that is not printable ASCII is classified `.generalText`, which
`renderRowReaches` prices as a full cell of ink above *and* below the row. But
every box-drawing, block-element, braille, powerline, branch-drawing, and legacy
computing cell is a sprite: the executor draws it as contained rects or as a path
explicitly clipped to its own cell, so its ink never leaves the band. Result: on
exactly the content the terminal is fastest at -- a TUI made of box borders,
blocks, and braille -- every row claims the pre-T14 worst-case halo, and each
damaged row erases and replans three rows' worth of pixels instead of one band
plus a few measured pixels.

**Evidence.** The planner's classification, in the per-cell body:

```swift
if scalars.count == 1, let scalar = scalars.first {
    if scalar.value >= 0x20, scalar.value <= 0x7E {
        inkClass.insert(.asciiText)
    } else {
        inkClass.insert(.generalText)
    }
} else {
    inkClass.insert(.band)
}
```

`RenderInkReach.swift#renderRowReaches` then prices `.generalText` at the
full-cell fallback:

```swift
if row.inkClass.contains(.generalText) {
    include(row: rowIndex, lower: -cellHeight, upper: 2 * cellHeight)
}
```

The executor, meanwhile, never sends those scalars to a font at all.
`drawTextRuns` routes them by family before the font path is even considered
(`if scalar.value >= spriteClassificationMinimumScalar { switch scalar.value {
case BoxDrawingSprite.coarseRange: ... classifiedAsSprite = true` ...), and the
resulting geometry is either appended to `spriteRects` / `shadedSpriteRects` /
`legacySpriteRects` -- contained rect geometry, per each family's containment
contract in `docs/terminal-sprites.md` -- or drawn through a path helper that
opens with `clip(to: CGRect(origin: ..., size: metrics.cellSize))`
(`drawGeometricShapeTriangle`, `drawPowerlinePath`, `drawBranchDrawingGeometry`,
`drawBoxDrawingStroke`). Either way the reach is the band.

**Ideal fix.** Declare the sprite vocabulary once, where both layers can read
it, and let the planner ask instead of guess. `TerminalSpriteGeometry` depends
on nothing and is a sibling of `TerminalRenderPlanning` in
`lib/TerminalCore/Package.swift`, so the exact-membership predicate (the coarse
range *and* the family's `pattern(for:)`, because a gap inside a coarse range
legitimately falls through to the font) can move there and be called from both
`FramePlanner.plan` and `drawTextRuns`. The planner then inserts `.band` for a
sprite cell and `.generalText` only for a scalar that will genuinely reach the
unmeasured cmap. One vocabulary, one classifier, and the executor's routing
switch and the planner's ink class can no longer disagree.

**By construction.** "The planner believes a cell draws through the font while
the executor draws it as a sprite" stops being representable, because there is
one membership answer rather than two independently written ones. It also
removes the standing hazard `spriteClassificationMinimumScalar`'s own comment
names -- "This duplicates where the families actually start, so it can drift out
from under them" -- by giving the floor and the ranges one home.

**Cheaper fallback.** Add a fourth ink class computed from a copy of the coarse
ranges inside `TerminalRenderPlanning`. Small diff, and it creates a *third*
transcription of the family ranges that must track the other two; it also cannot
see the interior gaps (a scalar such as U+1FBB0 that sits in a coarse range but
returns nil from `pattern(for:)` really does go to the font), so it would
under-price those rows' reach -- a correctness regression, not just a
duplication.

**Verification.** This is a cost finding, so the number first: `just
benchmark-headless-draw 8` with `--workload btop-shaped --clip-rows 1` -- the
sprite workload, one damaged row, which is exactly the incremental case this
changes. The per-draw time for the clipped arm must fall; the full-frame arm
(`--clip-rows 0`) must not move, because a full render erases everything anyway.
Note DRAW-3 must land first, or the harness does not build. Correctness is
pinned by the existing redraw-equivalence coverage in
`lib/TerminalCore/Tests/TerminalRenderExecutionTests/BitmapTestSupport.swift`:
feed a grid of box-drawing and braille glyphs, damage one row, and assert the
incremental render is byte-identical to the full redraw. That test is what
catches a family whose geometry actually overscans its cell.

**Risk.** If any rect-emitting family's geometry escapes its cell, narrowing its
reach to the band leaves stale pixels behind on an incremental render. The
containment assertions live in the geometry tests per
`docs/terminal-sprites.md`'s test contract, so a violation should already be a
red test; the byte-equality check above is the backstop. Moving the classifier
also changes the layering the sprite doc states ("Classification stays beside
render execution"), so the doc must move with it.

**Vetted.** The classification block is verbatim at
`RenderFramePlanner.swift:481-489`, and `renderRowReaches`' pricing of
`.generalText` at `-cellHeight ..< 2 * cellHeight` is verbatim at
`RenderInkReach.swift:83-85`. I checked the containment claim rather than taking
it: all four path helpers open with a clip to the cell --
`drawGeometricShapeTriangle` (line 1257), `drawPowerlinePath` (1295),
`drawBranchDrawingGeometry` (1346), `drawBoxDrawingStroke` (1401) -- and the
rect-emitting families append cell-local rects translated by the cell origin.
The routing switch is verbatim at lines 962-1066, gated by
`spriteClassificationMinimumScalar = 0x2500` (line 749) with its drift comment
as quoted. The path is live, not theoretical:
`TerminalFrameBackingStore.apply` (lines 143-212) is the app's incremental
render, and it sizes both the erase spans and the plan set from this ledger, so
a sprite row really does erase and replan roughly three rows' worth of pixels
where it should erase one band. `TerminalSpriteGeometry` really has no
dependencies and `TerminalRenderPlanning` depends only on `TerminalCore`
(`lib/TerminalCore/Package.swift:64-81`), so the shared-predicate direction
creates no cycle.

**Correction.** Two things the prose overstates. First, `.generalText` is not
only wrong for sprites: a single-scalar private-use cell the base face cannot map
is drawn through `drawPackagedSymbol` under `clip(to: span)`
(`TerminalRenderExecution.swift:1208`), and any other unmappable single-scalar
cell falls to `drawTextCell`, which also clips (line 1443). Both are band
content today priced as a full-cell halo. But the planner cannot compute either
one -- both depend on the runtime font's cmap, which is an execution-layer fact.
So the fourth branch the planner can honestly add is the sprite set and nothing
else, and `.generalText` remains the right answer for the rest. Second, the
"standing hazard" the fix is said to remove is already caught:
`SpriteRoutingGuardTests#floorMatchesLowestFamilyRangeStart` asserts the floor
equals the minimum `coarseRange` lower bound across all eight families and that
no family sits below it. The finding's real payoff is the planner/executor
membership disagreement, which nothing tests. Effort is closer to large than
medium: the exact-membership answer lives in eight `pattern(for:)` functions and
their tables inside `TerminalRenderExecution`, so a shared predicate means moving
all eight, not adding one function.

**Conflicts with.** `DRAW-5`, which restructures
`BoxDrawingSprite.pattern(for:)` and `lineMappings` -- the same decoder this
finding proposes to move into `TerminalSpriteGeometry`. Do `DRAW-5` first and
move the finished total table, or the two rewrite each other. Also blocked on
`DRAW-3` for its stated verification, since the harness that would produce the
number does not build.

<a id="draw-3"></a>

#### DRAW-3. Repair the headless draw benchmark arm, which has not compiled since the plan went row-indexed

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; confirmed

**Files.** `scripts/terminal-headless-draw-arm.swift#PreparedDraw.draw`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift#drawRenderFrame`, `justfile#benchmark-headless-draw`

**Problem.** The one measurement tool this lane has -- the paired headless draw
comparison, the thing that resolves a draw-path difference below 3% -- fails to
build at `HEAD`. `drawRenderFrame` lost its `rows: [Int]?` parameter and gained
`restrictedTo: TerminalDamage?` in commit `13db5f73`, and the benchmark arm was
never updated. Nothing in `just test` or `just lint` compiles `scripts/`, so the
breakage is silent. Every cost finding in this area names this harness as the
experiment that would decide it, so it is worth more than its size.

**Evidence.** The arm still calls the old signature:

```swift
    func draw() {
        drawRenderFrame(plan, rows: restrictedRows, metrics: metrics, in: context)
    }
```

and stores `private let restrictedRows: [Int]?` to feed it. The only
`drawRenderFrame` in the tree is
`TerminalRenderExecution.swift:591`:

```swift
public func drawRenderFrame(
    _ plan: RenderFramePlan,
    restrictedTo restriction: TerminalDamage? = nil,
    metrics: TerminalRenderMetrics,
    in context: CGContext
)
```

`git show 3bea76c5:.../TerminalRenderExecution.swift` shows the arm was written
against `rows restrictedRows: [Int]? = nil`, which existed then and does not now.
`scripts/terminal-headless-draw-compare.py` copies this file verbatim into both
generated arm targets, and `justfile:224` is the recipe that runs it.

**Ideal fix.** Store `TerminalDamage?` instead of `[Int]?` in `PreparedDraw` --
`clipRows <= 0 ? nil : TerminalDamage(rows: 0..<clipRows, rowCount:
full.rowCount)` -- and pass it as `restrictedTo:`. Then make the rot impossible
to repeat: the arm is Swift that must compile against `lib/TerminalCore`, so add
it to the lint pass as a type-check-only build (`swiftc -typecheck` against the
built modules, or a tiny SwiftPM target the gate builds but never runs). A tool
that only two people ever run is exactly the one that needs the compiler
watching it.

**By construction.** Nothing at the type level -- this is rot, not a modelling
error. What stops being possible is the *silent* version of it: a signature
change in `TerminalRenderExecution` that leaves the benchmark unbuildable
without a red gate.

**Cheaper fallback.** Fix the call and leave the arm out of the gate. That
restores the tool today and guarantees the same breakage on the next signature
change, which is how it got here.

**Verification.** `just benchmark-headless-draw 2` completes and prints a paired
spread. As an A/A control against the same checkout the reported difference must
sit inside the calibrated spread (`scripts/terminal-benchmark-calibration.py`),
which is the harness's own proof that it measured anything at all.

**Risk.** The compare script builds one arm source against two *different*
`TerminalCore` checkouts, so an arm written to the new signature cannot measure
a baseline older than `13db5f73`. That is already true today (it measures
nothing at all), but it should be said out loud in the file header rather than
discovered.

**Vetted.** The arm really does store `private let restrictedRows: [Int]?`
(`scripts/terminal-headless-draw-arm.swift:30`) and really does call
`drawRenderFrame(plan, rows: restrictedRows, metrics: metrics, in: context)`
(line 98). There is exactly one `drawRenderFrame` in the tree
(`TerminalRenderExecution.swift:591`) and its second parameter is
`restrictedTo restriction: TerminalDamage? = nil` -- no `rows:` label exists at
any arity, so the call cannot resolve and the arm cannot compile. `13db5f73` is
`perf(render): carry damage across the apply seam` (2026-08-20), whose message
says the executor's row restriction became "a shift-free damage value", which is
exactly the change that orphaned the arm. `justfile:224` is the recipe, as
cited. This is the one finding in the lane whose defect is present rather than
latent, and the reason its impact is 3 despite the small diff is that `DRAW-2`
and `DRAW-9` both name this harness as the experiment that decides them.

**Conflicts with.** `PROBE-8`, which rewrites the same
`scripts/terminal-headless-draw-arm.swift#PreparedDraw` -- its own `Correction`
paragraph says the script's copy must gain a `deinit` fix in the same `draw()`
region this finding rewrites. Land the two as one edit to that file. The lint
half of the ideal fix adds a step beside `scripts/run-test-suite.sh#LINT_STEPS`,
which `GATE-1` and `GATE-3` also edit; adjacent, not conflicting.

<a id="draw-4"></a>

#### DRAW-4. Store the ANSI palette in an `InlineArray<16, RenderColor>`, deleting the sixteen fields, the switch, and the trap

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift#RenderANSIColors`

**Problem.** `RenderANSIColors` spells "sixteen colors" as sixteen stored
properties, a sixteen-arm initializer, a sixteen-element projection, and a
sixteen-case subscript ending in `preconditionFailure`. That is roughly ninety
lines to say what the language now says in one, and the trap at the bottom is
reachable only through an index the one caller has already proven is in range.

**Evidence.** The whole type, in outline:

```swift
public struct RenderANSIColors: Equatable, Sendable {
    private let color0: RenderColor
    ... fourteen more ...
    private let color15: RenderColor

    public init?(exactly colors: [RenderColor]) {
        guard colors.count == 16 else { return nil }
        color0 = colors[0]
        ... fifteen more assignments ...
    }

    public subscript(index: Int) -> RenderColor {
        switch index {
        case 0: color0
        ...
        default: preconditionFailure("ANSI palette index out of range: \(index)")
        }
    }
}
```

The sole caller cannot reach the `default`:
`RenderColorResolution.swift#resolveColor` reads it as `case let .indexed(index)
where index < 16: return theme.ansiColors[Int(index)]`, with `index` a `UInt8`.
The tree already uses the replacement --
`lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift:114` holds `private
var storage = InlineArray<24, UInt16>(repeating: 0)` -- so the language feature
is in use and the toolchain (Swift 6.3.3, tools 6.2) supports it.

**Ideal fix.** One stored `InlineArray<16, RenderColor>`. `init?(exactly:)`
keeps its arity guard and fills the array in a loop. The subscript becomes a
direct index. `colors` becomes a small loop or is dropped if its two
diagnostic callers can take the subscript. The doc comment's promise -- "at
fixed arity so a complete theme cannot carry a missing or extra indexed color" --
is then made by the type rather than by hand.

**By construction.** Fixed arity moves from "sixteen fields plus a guard" to the
storage type itself. The `preconditionFailure` is deleted rather than reworded,
and the class of bug where one of sixteen mechanical assignments or switch arms
is transposed (`case 11: color12`) stops existing.

**Cheaper fallback.** None -- the ideal fix is small. The one thing to check is
`Equatable`: if `InlineArray` does not carry a conditional conformance in this
toolchain, the synthesized `==` is replaced by a four-line element-wise loop,
which is still a net deletion of eighty lines.

**Verification.** `swift test --package-path lib/TerminalCore --filter
TerminalRenderPlanningTests`. The behavioral pin is the existing indexed-color
resolution coverage in `RenderColorResolutionTests`: SGR `38;5;N` for every `N`
in `0...15` must resolve to the same `RenderColor` before and after. That is
index-by-index and structure-insensitive.

**Risk.** `RenderANSIColors` is public and `Equatable`, and `RenderTheme`
equality gates plan reuse in `PaneFramePlanner`. A hand-written `==` that
compares fewer than sixteen entries would silently make reuse accept a changed
palette. The test above, run per index, is what catches that.

**Vetted.** I read the whole type
(`TerminalRenderPlanning.swift:30-102`): sixteen `private let color0...color15`,
a sixteen-assignment `init?(exactly:)` behind `guard colors.count == 16`, the
sixteen-element `colors` projection, and the sixteen-case subscript ending in
`preconditionFailure("ANSI palette index out of range: \(index)")` -- all
verbatim. `resolveColor` reads it exactly as quoted
(`RenderColorResolution.swift:365-366`), with `index` a `UInt8` already narrowed
by `where index < 16`, so the trap is unreachable from shipped code. The
replacement is in use: `CSIParameters` holds
`private var storage = InlineArray<24, UInt16>(repeating: 0)`
(`EscapeAbsorber.swift:114`) and the toolchain is Swift 6.3.3.

**Correction.** Two details. The `colors` projection has no production callers at
all -- its only two readers are `RenderColorResolutionTests.swift:95` and `:104`
-- so it can be deleted outright rather than rewritten, which makes the fix
smaller than described. And the `Equatable` question the finding leaves open is
already answered in the tree, in the negative: `CSIParameters` is `Equatable` and
hand-writes `static func == (lhs:rhs:) { lhs.elementsEqual(rhs) }`
(`EscapeAbsorber.swift:143-145`) precisely because `InlineArray` carries no
conditional `Equatable` here. So the hand-written element-wise `==` is not a
contingency -- it is part of the work, and the `Risk` paragraph's warning about
`RenderTheme` equality gating plan reuse applies for certain, not conditionally.

**Conflicts with.** Nothing. `RenderANSIColors` has one production reader
(`RenderColorResolution.swift:366`) and one production constructor
(`app/ThemeRenderBridge.swift:9`), and no other lane file names either.

<a id="draw-5"></a>

#### DRAW-5. Make the box-drawing table total, deleting its nil slots and the unreachable trap

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalRenderExecution/BoxDrawingSprite.swift#BoxDrawingSprite.pattern(for:)`, `#lineMappings`

**Problem.** The 128 scalars of U+2500-U+257F are decoded twice: a 128-entry
`[BoxDrawingLines?]` table whose nineteen nil slots mean "not a line form", and a
switch that must supply exactly those nineteen. The two are matched by hand, and
the mismatch case is a `preconditionFailure` in the per-cell draw path -- a
printable character crashing the terminal if the pairing ever slips.

**Evidence.**

```swift
if let lines = lineMappings[Int(value - 0x2500)] { return .lines(lines) }
return switch value {
case 0x2504: .dashed(axis: .horizontal, weight: .light, count: 3)
...
case 0x2573: .diagonal(.cross)
default: preconditionFailure("complete Box Drawing mapping for \(String(value, radix: 16))")
}
```

I extracted the table and checked it: 128 entries, with nils at exactly
`2504-250B`, `254C-254F`, `256D-2573` -- precisely the nineteen the switch
answers, so the trap is unreachable today. The nil is the only thing holding the
two halves apart.

**Ideal fix.** Make `lineMappings` a total `[BoxDrawingPattern]` of 128 entries:
the nineteen former nil slots hold their `.dashed` / `.arc` / `.diagonal` value
inline, beside the neighbours they share a codepoint block with.
`pattern(for:)` becomes the range guard plus one index. The switch, the
`Optional`, and the `preconditionFailure` all go.

**By construction.** "A scalar the table declines and the switch does not
answer" stops existing: the table is total, so there is no second decoder to
disagree with and no default arm to trap in. It also puts each glyph's meaning
at its own codepoint offset instead of splitting nineteen of them into a
separate list ordered differently from the block.

**Cheaper fallback.** Replace the trap with `return nil` (fall through to the
font). Smaller, and it swaps a crash for a silent wrong glyph -- the sprite doc's
step 4 warns about exactly that failure mode ("renders from the font instead of
its sprite, silently").

**Verification.** `swift test --package-path lib/TerminalCore --filter
BoxDrawing`. The pin is the existing exhaustive mapping test: every scalar in
`0x2500...0x257F` must return the same `BoxDrawingPattern` before and after,
asserted per scalar. That is a behavioral, structure-insensitive check of the
whole finite range.

**Risk.** A transcription slip while inlining nineteen entries into the table
would change a glyph. The exhaustive mapping test is exactly the shape that
catches it, so the risk is bounded by running it.

**Vetted.** `pattern(for:)` and the switch are verbatim at
`BoxDrawingSprite.swift:10-35`, and I re-derived the table's shape myself
(`#lineMappings`, lines 82-110) rather than trusting the count. It is exactly 128
entries: 12 on the first physical line (offsets 0-11, with nils at 4-11),
fifteen lines of four (12-71), a line of eight ending in four nils (72-79, nils
at 76-79), seven lines of four (80-107), a line of `e(d,d,d,d)` plus seven nils
(108-115, nils at 109-115), and three final lines of four (116-127). Converted to
codepoints the nils are `2504-250B`, `254C-254F`, `256D-2573` -- nineteen slots,
matching the nineteen switch arms one for one, so the auditor's count and
positions are right and the `preconditionFailure` is unreachable today.

**Correction.** The prose reads as though the trap could fire ("a printable
character crashing the terminal if the pairing ever slips"). It cannot fire at
`HEAD` and nothing outside this file can make it fire -- both halves are static
`let`s in the same enum. This is a simplification with a latent hazard, not a
live crash, and it should be weighed as such.

**Conflicts with.** `DRAW-2`, whose ideal fix moves the exact-membership answer
-- this decoder -- out of `TerminalRenderExecution` and into
`TerminalSpriteGeometry`. The two rewrite the same function. This one is the
smaller and the prerequisite: make the table total here, then move the finished
version.

<a id="draw-6"></a>

#### DRAW-6. Put the four overlay seeds in one place, and stop pretending one of them is a theme input

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift#RenderTheme`, `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderColorResolution.swift#resolveOverlayFill`

**Problem.** The overlay ladder has four seeds. One of them lives as a public
stored property of `RenderTheme`; the other three are literals in the middle of
`resolveOverlayFill`. The theme one is not configurable: the initializer hard-codes
it and ignores every caller. So a public field advertises an input that does not
exist, and a reader looking for the ladder's constants finds a quarter of them in
one file and three quarters in another.

**Evidence.** `RenderTheme` declares it as an input:

```swift
    /// Hue seed adapted into the active find-match background for each cell.
    public let searchMatchBackground: RenderColor
```

and the only initializer refuses to take one:

```swift
    public init(ansiColors: ..., cursorText: RenderColor) {
        ...
        searchMatchBackground = RenderColor(red: 175, green: 128, blue: 20)
```

Its siblings are inline in `resolveOverlayFill`:

```swift
    let combinedActiveMatch = resolveBrightnessSeparatedColor(
        seed: RenderColor(red: 80, green: 127, blue: 235), ...
    let quietMatch = resolveBrightnessSeparatedColor(
        seed: RenderColor(red: 110, green: 90, blue: 45), ...
```

A repo-wide grep for `searchMatchBackground` finds four hits: the declaration,
the assignment, the one read, and a test asserting two themes agree on it --
which is the test writing down that it is a constant.

**Ideal fix.** Delete the field and name all four seeds together as `private let`
constants in `RenderColorResolution.swift`, beside the three separation
thresholds that already live there. The ladder then reads in one place, in
order, and `RenderTheme` carries only what a caller can actually choose. If the
seed should one day be themeable, that is a deliberate change to the ladder, not
a field already sitting there half-wired.

**By construction.** A public field that ignores its would-be input stops
existing, so a caller cannot be misled into "setting" it. It also drops a
constant out of `RenderTheme`'s synthesized `Equatable`, which
`RenderPresentation` equality -- the gate on cross-frame plan reuse in
`PaneFramePlanner` -- compares on every frame.

**Cheaper fallback.** Move the other three seeds onto `RenderTheme` instead.
Same colocation, but it grows the public surface with three more fields nobody
can set, so it multiplies the defect rather than removing it.

**Verification.** `swift test --package-path lib/TerminalCore --filter
RenderColorResolutionTests`. The behavioral pin is the existing ladder
separation coverage: for a set of backgrounds, the five `RenderOverlayState`
fills must remain pairwise separated by at least
`overlayFillMinimumBrightnessSeparation` and must be unchanged colors. Purely a
move, so every resolved value must be identical.

**Risk.** None beyond the mechanical: the value is a compile-time constant with
one reader.

**Vetted.** Every quote holds. `public let searchMatchBackground: RenderColor` is
at `TerminalRenderPlanning.swift:123` with the doc comment as given; the sole
initializer assigns `RenderColor(red: 175, green: 128, blue: 20)` at line 174
and takes no such parameter (its signature is `ansiColors`,
`defaultForeground`, `defaultBackground`, `selectionForeground`,
`selectionBackground`, `cursor`, `cursorText`). The two sibling seeds are inline
at `RenderColorResolution.swift:215` and `:223`, in `resolveOverlayFill` as
described, and the fourth seed is `theme.selectionBackground`, which *is* a real
theme input. The repo-wide grep gives exactly the four hits claimed: the
declaration, the assignment, the one read at
`RenderColorResolution.swift:208`, and `RenderColorResolutionTests.swift:159`.

**Correction.** Impact drops from 2 to 1. The defect is real but its whole
surface is one field with one reader, and the secondary payoff the prose claims
-- dropping a constant out of `RenderTheme`'s synthesized `Equatable`, which
`PaneFramePlanner` compares per frame -- is three bytes of a comparison that
already walks a sixteen-colour palette. What is left is the honest half: a public
field advertising an input no caller can supply. Worth doing, worth doing
cheaply, not worth ranking above the rest.

**Conflicts with.** Nothing. No other lane file names `RenderTheme` or
`RenderColorResolution.swift`.

<a id="draw-7"></a>

#### DRAW-7. Resolve a row's search overlays with an advancing cursor instead of a scan per column

`cost` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift#overlayState(at:selected:matches:)`, `#FramePlanner.plan(for:searchReadout:reusing:damage:)`

**Problem.** While a search is live, the planner asks "which match covers this
column?" once per cell, and answers it with a linear scan of the row's match
list. A row with `C` columns and `K` matches on it costs `O(C*K)` predicate
calls -- and `K` is largest precisely when the user types a short needle, which
is when the frame has to be replanned on every keystroke.

**Evidence.**

```swift
private func overlayState(
    at column: Int,
    selected: Range<Int>?,
    matches: [(columns: Range<Int>, isActive: Bool)]
) -> RenderOverlayState? {
    let isSelected = selected?.contains(column) == true
    guard let match = matches.first(where: { $0.columns.contains(column) }) else {
```

and its caller runs once per visited cell:

```swift
let state = rowHasOverlays
    ? overlayState(at: column, selected: selected, matches: matches)
    : nil
```

The row's `matches` are built once per row just above, by projecting
`searchReadout.viewportMatches` into row-local column spans.

**Ideal fix.** Cells are visited in ascending column order and the row's match
spans are disjoint, so the row body can carry one index into `matches` and
advance it past any span whose `upperBound <= column`. `overlayState` then
answers in amortized `O(1)` and the row costs `O(C + K)`. That needs the
projected list ascending, which is a one-line `sort` where the row projects it
(cheap: `K log K` once per row rather than `C*K` per row) -- or, better,
`TerminalSearchStatus.viewportMatches` states its ascending order in its doc
comment, since the search already produces matches in stream order.

**By construction.** Nothing stops being representable; this is arithmetic, not
modelling. Worth saying plainly rather than dressing it up.

**Cheaper fallback.** None needed -- the ideal fix is small. The alternative
worth *not* doing is a per-row column-to-state lookup table, which is a mirror
of the match list sized to the row.

**Verification.** Cost finding, so the number: extend
`lib/TerminalCore/Sources/TerminalBrowseBenchmarkSupport` (or add a case to the
draw-benchmark producer) with a "search-dense" workload -- an 80x25 grid of
repeated `e`, needle `e`, so `K` is about `C/2` per row -- and measure
`planFrame` wall time per frame before and after. That per-frame number must
fall roughly with `K`; the no-search workload must not move. Behavior is pinned
by the existing `SearchMatchRenderPlanningTests`: the overlay runs for a row with
several matches, one of them active, must be identical.

**Risk.** If `viewportMatches` is ever unsorted or ever overlapping, an
advancing cursor skips a match that a full scan would have found. Sorting the
row-local projection removes the ordering half of that risk; overlapping matches
would already make `first(where:)` order-dependent today, so the fix does not
make that worse -- but it does make the assumption explicit, which is why the
ordering belongs in the readout's doc comment.

**Vetted.** `overlayState(at:selected:matches:)` is verbatim at
`RenderFramePlanner.swift:227-243`, `matches.first(where:)` included, and its
per-cell call site behind `rowHasOverlays` is verbatim at lines 381-383. The
row-local projection is built once per replanned row at lines 341-352.
Confidence goes up, not down, because I settled the ordering question the
auditor left open, which is the one thing the ideal fix depends on:
`TerminalSearch#readout` (`TerminalSearch.swift:125-157`) starts from
`searchMatchLowerBound` into the sorted match array, walks forward, and breaks
at `match.start.row >= absoluteRows.upperBound`, so `viewportMatches` is
ascending in stream order; `compactMap` preserves that order, and matches do not
overlap. An advancing cursor is therefore correct as written.

**Correction.** The sort the ideal fix budgets for is not needed. The row-local
projection is already ascending and disjoint for the reason above, so the change
is the cursor plus a doc comment on
`TerminalSearchReadout.viewportMatches` stating the order that already holds --
smaller than the finding says. Against that, the prose is too quick to drop the
sibling cost: the `searchMatchRanges.compactMap` at lines 341-352 runs over
*every* viewport match for *every* replanned row, which is `O(rows x M)` with
`M ~ rows x K`, the same order as the `O(rows x C x K)` scan this finding names
and with a per-row array allocation on top. Fixing one and not the other halves
the payoff. Both belong in the same change. Magnitude for scale: an 80x25
viewport with a one-character needle is a few hundred microseconds per full
replan -- real on a keystroke-driven replan, negligible on an ordinary damaged-row
frame.

**Conflicts with.** `SELECT-2`, which folds `activeMatch` into
`TerminalSearchStatus.matched` and reshapes `TerminalSearchReadout` -- the type
this finding reads (`match == activeSearchMatchRange`) and proposes to document.
Also `SELECT-7`, which deletes `hoveredColumns` in favour of `columns` inside the
same `FramePlanner.plan` row body this finding rewrites; separable statements,
but the same hunk.

<a id="draw-8"></a>

#### DRAW-8. Delete `withGlyphHalo` and its bitset routine, which the reach ledger replaced

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift#TerminalDamage.withGlyphHalo(rowCount:)`, `#TerminalDamageRowBits.haloed(rowCount:)`

**Problem.** The global one-row glyph halo was the pre-T14 way of covering
unclipped glyph ink, and the reach ledger in `RenderInkReach` /
`TerminalFrameBackingStore` replaced it with a measured per-row answer. The old
mechanism is still public API on the core damage type, with its own precondition
and its own word-level bitset routine, and no production code calls it.

**Evidence.** The public entry point:

```swift
    /// Expands row damage so unclipped glyph ink crossing a row boundary is
    /// repainted. Shift-free values only: fold the shift first.
    public func withGlyphHalo(rowCount: Int) -> TerminalDamage {
        precondition(shift == nil, "halo a folded value; a shift is not row damage")
```

A repo-wide grep for `withGlyphHalo` outside tests returns exactly two hits,
both in `scripts/research/33/t5-scroll-amplification-probe.swift` -- a frozen
research probe, not a shipping path. `haloed(rowCount:)` in
`TerminalDamageRowBits` has no other caller. The replacement is documented in
place: `renderApplyShape`'s own comment says the measured shape's "worst case is
the pre-T14 halo shape".

**Ideal fix.** Delete both, and the halo cases in `TerminalDamageSpanTests`. If
the research probe should keep running, it can fold the halo locally -- it
already reaches for `expandingShift().rowIndices` and builds its own row sets.

**By construction.** Removes a second, coarser answer to "which rows must be
repainted for ink that crosses a row boundary", so there is one derivation of
that fact rather than two that could disagree. It also removes a public
precondition from the core damage type.

**Cheaper fallback.** Mark it internal and leave it. That keeps the duplicate
derivation and its tests alive, and leaves the next reader of `TerminalDamage`
choosing between two halo stories.

**Verification.** `swift test --package-path lib/TerminalCore` -- the whole
`TerminalCoreTests` and `TerminalRenderExecutionTests` suites must stay green
with only the halo-specific cases in `TerminalDamageSpanTests` removed. In
particular the redraw-equivalence coverage in `BitmapTestSupport` must be
untouched, which is the proof that the reach ledger, not the halo, is what keeps
incremental renders byte-exact.

**Risk.** Deleting the probe's dependency changes a research script. It is
frozen output, so it should either be updated in the same change or its header
should record that it no longer builds -- silently leaving a third broken script
beside DRAW-3's would be the wrong trade.

**Vetted.** `withGlyphHalo(rowCount:)` is verbatim at
`TerminalDamage.swift:145-149`, precondition included, and
`TerminalDamageRowBits.haloed(rowCount:)` at lines 547-564 has no caller but it.
I ran the grep myself over `lib/`, `app/`, and `scripts/`: outside tests the only
two hits are `scripts/research/33/t5-scroll-amplification-probe.swift:369` and
`:373`. Nothing in `TerminalRenderPlanning`, `TerminalRenderExecution`,
`TerminalFrameBackingStore`, or `app/` calls either. The replacement is the
measured ledger, and `TerminalFrameBackingStore.apply`'s comment does say the
worst case "is the pre-T14 halo shape" (line 178). The probe is compiled by
`t5-scroll-amplification.py` against a *patched* copy of the engine sources, not
against `lib/` at `HEAD`, which supports the finding's read that it is frozen
output rather than a live dependency.

**Conflicts with.** Nothing hard. `PROBE-7` also touches `TerminalDamage.swift`,
but at `rowIndices` (line 114), a different member this finding leaves alone.

<a id="draw-9"></a>

#### DRAW-9. Give the packaged symbols face the same eager glyph resolution the styled faces get

`cost` &middot; impact 1, confidence 3 &middot; effort medium &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift#TerminalFace.nominalGlyph`, `#CGContext.drawPackagedSymbol`, `#TerminalFace.init`

**Problem.** The four styled faces resolve their glyphs once at construction,
and the file argues carefully why that is sound. The packaged symbols face gets
none of it: every private-use cell costs a live `CTFontGetGlyphsForCharacters`
to find its glyph and a live `CTFontGetBoundingRectsForGlyphs` to fit it, on
every frame that draws it, plus a `saveGState`/`clip`/`CTFontDrawGlyphs` per
cell rather than one batched submission. A Nerd-Font prompt or a file tree with
icons pays this for every icon, every frame.

**Evidence.** The per-cell lookup, called from the fallback branch of
`drawTextRuns`:

```swift
    func nominalGlyph(_ scalarValue: UInt32) -> CGGlyph? {
        guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
        var characters = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
```

-- note the two array allocations per call -- and the per-cell measurement and
submission:

```swift
    func drawPackagedSymbol(_ glyph: CGGlyph, face: TerminalFace, in span: CGRect) {
        var measuredGlyph = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(face.font, .horizontal, &measuredGlyph, nil, 1)
        ...
        CTFontDrawGlyphs(face.font, &drawnGlyph, &position, 1, self)
```

driven one cell at a time by `for symbolsCell in symbolsCells { saveGState()
... restoreGState() }`. Contrast `TerminalFace.init`, which resolves and
measures the whole ASCII table in two batched calls and stores the results.

**Ideal fix.** Resolve the symbols face the same way its siblings are resolved:
at construction, for the scalar set it is actually consulted for. That set is
already bounded -- `isPrivateUse` gates entry, and the packaged resource is a
symbols-only Nerd Font whose coverage is a known, finite list -- so a table of
glyph plus ink bounds, built with the same two batched CoreText calls
`TerminalFace.init` already makes, removes both per-cell lookups. Per-cell
`clip` stays, because the fit is per-cell by design.

**By construction.** Nothing; this is cost, and the structure it adopts is one
the file already justifies for the styled faces.

**Cheaper fallback.** Memoize the two lookups in a dictionary on first use. That
is the shape this codebase spends its structural findings undoing -- mutable
state inside a `Sendable` value, which `TerminalFace`'s own doc comment
explicitly rejects ("The alternative, a memo filled during draws, would put
mutable state inside a `Sendable` value; this stays immutable").

**Verification.** Cost finding: add a `symbols-shaped` workload to
`scripts/terminal-headless-draw-arm.swift` alongside `btop-shaped` and
`text-shaped` -- a grid of U+E0xx/U+F0xx private-use scalars the base font
cannot map -- and run `just benchmark-headless-draw 8 --workload symbols-shaped
--clip-rows 0`. Per-draw time must fall; `btop-shaped` and `text-shaped` must
not move, since neither reaches the symbols path. Requires DRAW-3 first.
Correctness is pinned by the existing packaged-symbol bitmap coverage: a
rendered private-use cell must be byte-identical before and after.

**Risk.** A precomputed table sized to the whole private-use area would cost
real memory per metrics instance (the bounds array dominates). The set must be
bounded to what the packaged face actually maps, read from the font's own
character set at construction, or the fix trades time for a worse memory
footprint -- which `agent-docs/measurement-discipline.md` says must be measured,
not assumed.

**Vetted.** Every quote is verbatim: `nominalGlyph`
(`TerminalRenderExecution.swift:353-359`) with its two per-call array
allocations, `drawPackagedSymbol` (lines 788-800) with the per-cell
`CTFontGetBoundingRectsForGlyphs`, and the driving loop
`for symbolsCell in symbolsCells { saveGState() ... restoreGState() }` at lines
1200-1211. `TerminalFace.init` (lines 318-345) really does resolve and measure
the whole ASCII table in two batched calls, and the face's doc comment really
does reject a draw-time memo in the words quoted. I traced the entry path: the
symbols face is consulted only after the batched cmap call returns glyph zero
for a private-use single-scalar cell (lines 1153-1159), so this is the fallback
of a fallback.

**Correction.** Impact drops from 2 to 1, and the ideal fix should not be
recommended as stated. The path costs two CoreText calls plus two small array
allocations per icon cell per redrawn row -- on the order of one microsecond a
cell, so a prompt with a handful of icons pays single-digit microseconds and a
30-icon file listing pays tens, and only on the rows a frame actually redraws.
Against that, the fix as written builds a glyph-plus-bounds table for the
packaged face's whole coverage; a symbols-only Nerd Font maps on the order of ten
thousand scalars, and a `CGRect` per entry is roughly 340KB per metrics instance,
which is per pane and per font size. Trading hundreds of kilobytes for tens of
microseconds is the trade `agent-docs/measurement-discipline.md` exists to
refuse. The defensible version is narrower: delete the two array allocations
inside `nominalGlyph` (it resolves at most two UTF-16 units, so fixed storage
does), and only then measure whether the two CoreText calls are worth a table
built from `CTFontCopyCharacterSet`'s real coverage. Confidence stays 3 -- the
code is exactly as quoted, but the payoff is not.

**Conflicts with.** Nothing. No other lane file names `TerminalFace`,
`nominalGlyph`, or `drawPackagedSymbol`. Blocked on `DRAW-3` for the workload it
would be measured with.

#### Dropped (DRAW)

- **Powerline, Geometric Shapes, Block Elements, Legacy Computing scalar mappings.** Checked every one against `references/ghostty/src/font/sprite/draw/powerline.zig`, `geometric_shapes.zig`, `common.zig#Shade`, and `symbols_for_legacy_computing.zig`. All eight Powerline diagonal triangles and both caps match vertex for vertex; the four filled and four outlined corner triangles match; the shade alphas are ghostty's `0x40/0x80/0xc0`; the supported legacy ranges are exactly ghostty's `1FB00-1FBAF`, `1FBBD-1FBBF`, `1FBCE-1FBEF`. No finding.
- **`renderApplyShape`'s plan-set candidate window.** `span.lowerBound / cellHeight - 1` and `(span.upperBound - 1) / cellHeight + 1` looked like off-by-one bait. Worked through the boundary cases at exact and off-by-one-pixel span edges: correct, given the reach clamp its comment cites, which `measuredInkEnvelope`'s `clamped(_:)` really does enforce.
- **`TerminalFrameSwapchain.acquireIndex` preferring `max` by `lastPresented`.** Reads backwards ("least-stale" answered with `max`) but is right: the most recently presented buffer has accumulated the least stale damage since.
- **Sprite family coarse-range overlap in `drawTextRuns`' routing switch.** The switch tests `LegacyComputingSupplementSprite.coarseRange` before `LegacyComputingSprite.coarseRange`, so an overlap would silently shadow a family. Checked all eight: `2500-257F`, `2580-259F`, `25E2-25FF`, `2800-28FF`, `E0B0-E0D4`, `F5D0-F60D`, `1CC1B-1CEAF`, `1FB00-1FBEF` -- pairwise disjoint. No finding.
- **`TerminalDamageRowBits.translate`'s in-place barrel shift.** The trickiest code in the lane. Traced both iteration directions against its stated invariant (each written word reads only source words not yet overwritten); it holds.
- **`terminalRows(intersecting:metrics:rowCount:)` as dead public API.** It looked dead after the row-indexed refactor, but `lib/TerminalHostTools/Sources/GlyphPreview/main.swift:161` still calls it. Not dead.
- **Per-row `searchMatchRanges.compactMap` allocation in the planner.** Runs only for replanned rows, and an empty result allocates nothing. Real but too small to name beside DRAW-7, which is the same code path with the actual cost in it.
- **`String(scalar).utf16.count` per candidate cell in the batched cmap loop.** A plane test (`scalar.value > 0xFFFF ? 2 : 1`) would say the same thing without building a String. Correct as written and genuinely micro; not worth a finding.
- **`resolveCellStyle`'s `dim` as a halving of each component,** where several references blend toward the background instead. That is a rendering policy, not a control-sequence compatibility question, so it is the user's call rather than a defect -- and the references disagree among themselves.


### Area: Selection, search, hyperlinks, pointer semantics, and the viewport projection (`SELECT`)

_Scope: `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift`, `TerminalInteractionVocabulary.swift`, `TerminalInteractionApply.swift`, `TerminalInputEncoding.swift` (mouse half), `TerminalSearch.swift`, `TerminalSearchStatus.swift`, `ActivatableWebURI.swift`, the selection / link / scroll-projection regions of `Terminal.swift` (lines ~500-1000, 2500-2900, 3400-4000, 4480-4700), `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift`, and the call sites in `app/SwiftTerminalSessionView.swift` and `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`._

**The auditor's read on the area.** The interaction layer is the best-structured part of the engine I read. `TerminalPointerEvent` now carries the whole normalized `TerminalViewportCell` including its measured insideness, `decideTerminalPointer` owns the off-grid override so no caller sends a second cancellation message, the selection mutation carries its granularity inside the case, and `applyTerminalPointerDecision` is the single door from a decision to terminal state. `TerminalSearchStatus` and `isActivatableWebURI` are both carefully closed. What is left divides into three shapes: two places where the *external* protocol is not what the reference emulators do (a legacy mouse coordinate that is clamped instead of suppressed, and DECSET 1007 missing entirely), a few places where a pair of values can disagree because a tag and its payload are stored side by side rather than folded into one case, and per-cell loops that re-materialize a whole history row on every iteration through `ProjectionRows`'s subscript. I deliberately did not audit `LogicalLineStore`'s fold/reflow internals, `NeedleWindow`'s matcher, or the search index's record-coordinate maintenance beyond confirming `INTERACT-1`'s funnel (`RetainedHistory.swift`) has landed. I looked at `SettledSelection.isCaret` and `selectionRequiresNonemptyReflowResult` as candidate mirrors and dropped both: they are genuine provenance about which door the selection came through, and are not derivable from the stored extent.

<a id="select-1"></a>

#### SELECT-1. Suppress a legacy mouse report whose coordinates do not fit, instead of clamping the byte

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift#encodeMouseReport`, `lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift#encodeTerminalMouse`

**Problem.** The X10 mouse report encodes a coordinate as one byte, `32 + coordinate + 1`, which can only carry columns and rows up to 222 (zero-based). DanTerm clamps the byte instead of refusing the report. Past column 222 every column reports as the same cell, and at a wide enough grid the byte saturates at `0xFF`, which is not even a valid UTF-8 byte for the child to read. A 4K display with a small font is comfortably past 223 columns, so this is reachable, not theoretical.

**Evidence.** The encoder:

```swift
let legacyCode = isPressed ? code : 3 | (code & 0x1C)
return [
    0x1B, 0x5B, 0x4D,
    UInt8(clamping: legacyCode + 0x20),
    UInt8(clamping: column + 0x21),
    UInt8(clamping: row + 0x21),
]
```

`UInt8(clamping:)` is the whole of the range handling; nothing above it in `encodeTerminalMouse` tests the coordinate, and `modes.sgrMouseEncoding == false` is the only thing that selects this branch.

Two references refuse the report rather than clamping it. `references/ghostty/src/Surface.zig#mouseReport`, in its `.x10` arm: `if (viewport_point.x > 222 or viewport_point.y > 222) { log.info("X10 mouse format can only encode X/Y up to 223", .{}); return; }`. `references/vte/src/vte.cc#Terminal::feed_mouse_event` gates the legacy branch itself: `} else if (cb <= 223 && cx <= 223 && cy <= 223) { /* legacy mode */ ... }` -- with no `else`, so an out-of-range cell sends nothing. No DanTerm test pins the current clamp (`TerminalMouseEncodingTests` only covers small coordinates).

**Ideal fix.** Make the unencodable case unrepresentable at the encoder's exit: `encodeMouseReport` returns `[UInt8]` already, so give the legacy branch the range test and return `[]`, exactly as the two references do. The `UInt8(clamping:)` calls then become `UInt8(...)` on values the guard has proven fit -- a guard added and three lossy conversions deleted.

**By construction.** "A legacy mouse report whose coordinate byte does not mean the cell it was built from" stops being producible. The tracker still advances, so the next in-range motion reports correctly.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `swift test --package-path lib/TerminalCore --filter TerminalMouseEncoding`. New test: a terminal at 300 columns with `CSI ?1000 h` and SGR off; feed `.down(.left, column: 250, row: 0)` and assert the encoder returns `[]`; feed `.down(.left, column: 222, row: 0)` and assert `[0x1B, 0x5B, 0x4D, 0x20, 0xFF, 0x21]` -- the last encodable column. Then assert the same 250 press under `CSI ?1006 h` still returns `ESC [ < 0 ; 251 ; 1 M`, since SGR has no such limit.

**Risk.** A child that today receives a saturated byte and treats it as "the far right edge" would stop receiving anything at all past column 222. That is what both references do, and a wrong cell is worse than no cell for a click.

**Vetted.** I opened `TerminalInputEncoding.swift` lines 200-296 and read
`encodeTerminalMouse` and `encodeMouseReport` whole. The three
`UInt8(clamping:)` calls are exactly as quoted, `modes.sgrMouseEncoding` is the
only selector for the legacy branch, and no arm of `encodeTerminalMouse` tests a
coordinate. Both reference citations check out at the lines named:
`references/ghostty/src/Surface.zig:3711` returns early on `> 222`, and
`references/vte/src/vte.cc:6150` gates the legacy branch on `cb <= 223 && cx <=
223 && cy <= 223` with no `else`. The clamp is reachable -- `Terminal.resize`
puts no upper bound on `columns`.

**Correction.** The evidence's last sentence is wrong. A test does pin the
current clamp, and pins it deliberately:
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalMouseEncodingTests.swift:29`,
inside a case titled "X10 encodes buttons modifiers releases wheels and
**bounded coordinates**", asserts `encode(.down(.left, column: 300, row: 300))
== [0x1B, 0x5B, 0x4D, 0x20, 0xFF, 0xFF]`. So this is a decision that was written
down, not an oversight, and the fix must delete or invert that assertion rather
than land underneath it. The "not even a valid UTF-8 byte" argument also proves
nothing: `0xFF` is already what every reference emits for column 222, because
the legacy report is binary and vte feeds it with `feed_child_binary`. What
survives is the narrower and still correct claim: past column 222 DanTerm
reports a cell the pointer was not on, and no reference terminal does that.
Impact drops to 2 because the legacy branch is reached only by a program that
requests 1000/1002/1003 without 1006, which modern software does not do.

**Conflicts with.** `PARSE-3` -- the same defect on the same function, with a
mutually exclusive fix. `PARSE-3` cites `references/xterm/button.c`
(`EmitMousePosition`, `MOUSE_LIMIT (255 - 32)`) and proposes emitting xterm's
`0x00` past-end marker; I confirmed that citation at
`references/xterm/button.c:238-260`. `SELECT-1` proposes suppressing the report,
as ghostty and vte do. Both cannot land. Adjudicate the two together and pick
one wire behavior; two of the three references suppress.

<a id="select-2"></a>

#### SELECT-2. Fold the active match into `TerminalSearchStatus.matched` so a counter cannot exist without the match it counts

`structural` &middot; impact 2, confidence 3 &middot; effort medium &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalSearchStatus.swift#TerminalSearchReadout`, `lib/TerminalCore/Sources/TerminalCore/TerminalSearch.swift#readout`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#searchReadout`

**Problem.** `TerminalSearchStatus` was made an enum precisely so that "matches exist but none is selected" is unrepresentable -- its own file header says so. `TerminalSearchReadout` then reintroduces that state one level up, by putting `status` and an *optional* `activeMatch` side by side. The find overlay can therefore be handed "3 of 7" together with no range to highlight, and the render planner will draw seven quiet matches and no active one. The seam that produces the pair even carries a `?? default` that exists only because the type permits the state.

**Evidence.** `TerminalSearch.swift#readout`:

```swift
let status: TerminalSearchStatus = if matches.isEmpty {
    .empty
} else {
    .matched(
        selected: matches.count - 1 - (resolved?.index ?? matches.count - 1),
        total: matches.count
    )
}
...
return (status, resolved?.match, result)
```

`resolvedSearchMatch` opens with `guard matches.isEmpty == false else { return nil }` and returns non-nil on every other path, so inside this `else` branch `resolved` is never nil: `?? matches.count - 1` is a default that no input reaches. The optionality is not free, though, because `Terminal.swift#searchReadout` then re-derives it through a second failure:

```swift
return TerminalSearchReadout(
    status: readout.0,
    activeMatch: readout.1.flatMap(publicRange),
    viewportMatches: readout.2.compactMap(publicRange)
)
```

`publicRange` returns nil for any anchor outside `evictedRowCount..<evictedRowCount + streamCount`, so a `.matched(selected:total:)` status can legitimately arrive at the host with `activeMatch == nil`, and `viewportMatches` can silently drop entries the `total` still counts.

**Ideal fix.** `case matched(selected: Int, total: Int, active: TerminalTextRange)`, and let `readout` build the case from `resolved` directly rather than from `matches.count`. `Terminal.searchReadout` then does the `publicRange` fold once, and a failure there resolves the whole readout to `.empty` (or to `nil`) instead of to a half-populated pair. `TerminalSearchReadout` loses its `activeMatch` field entirely; the render planner reads the range out of the case it is already switching on.

**By construction.** "A search counter with no match to point at" stops being representable, and with it the unreachable `?? matches.count - 1`. The `flatMap` at the `Terminal` seam stops being able to produce a partially-resolved readout.

**Cheaper fallback.** Delete just the `?? matches.count - 1` and force-read `resolved.index` inside the non-empty branch. That removes the dead default but leaves the `Terminal.searchReadout` `flatMap` free to hand the host a counter with no highlight, which is the half that can actually be observed.

**Verification.** `swift test --package-path lib/TerminalCore --filter Search`. Behavioral test: run a query with several matches, navigate to one, and assert that `searchReadout` reports a status and a highlight that agree -- specifically that the range named by the status is one of `viewportMatches` whenever the selected match is on screen, and that no state exists in which `status` is `.matched` and the frame plans no active-match overlay. Structure-insensitive because it asserts over the public readout, not over the enum's shape.

**Risk.** Touching the public vocabulary shared with the app and render layers; the find overlay's rendering of "n of m" must be re-read. No terminal behavior changes.

**Vetted.** I opened `TerminalSearchStatus.swift` whole (45 lines),
`TerminalSearch.swift#readout` (lines 124-156) and `#resolvedSearchMatch` (lines
860-895), and `Terminal.swift#searchReadout` (lines 3506-3519) and
`#publicRange` (lines 4488-4499). Every quote appears verbatim. The dead-default
argument holds: `resolvedSearchMatch` opens with `guard matches.isEmpty == false
else { return nil }` and every remaining path returns a tuple, so inside
`readout`'s non-empty `else` branch `resolved` cannot be nil and `?? matches.count
- 1` is unreachable.

**Correction.** The finding's headline claim -- that the find overlay "can
therefore be handed 3 of 7 together with no range to highlight" -- is
representable but I could not reach it. Every range `publicRange` is asked about
comes from `resolvedSearchMatchRange`, which builds prefix anchors from
`context.history.position(of:)` (a `preconditionFailure` fires if that retired)
and takes suffix anchors from a live scan of the grid; both are inside
`base..<base + streamCount` by construction. The sibling claim that
`viewportMatches` "can silently drop entries the `total` still counts" is a
misreading: `total` counts every match in retained history and `viewportMatches`
is deliberately the viewport subset, so the two are not meant to agree.

The ideal fix also has a cost the prose does not name.
`TerminalSearchStatus` is not only a render input -- it is the value the app
layer publishes as the overlay counter (`SwiftTerminalSessionView#publish`,
which switches on `.matched(selected, total)` and emits two integers) and the
value `TerminalPaneSession#emitSearchStatusIfNeeded` uses as its change key
(`guard status != lastEmittedSearchStatus`). Folding a `TerminalTextRange` into
`.matched` makes that gate fire whenever the selected match's coordinates shift
under eviction, republishing an unchanged counter. Either the fix keeps the
counter and the range in separate values -- which is what the tree already does
-- or it must give the session a narrower change key. That trade belongs in the
finding. What is left unambiguously worth doing is the cheaper fallback: delete
the unreachable `?? matches.count - 1` and read `resolved.index` directly.

**Conflicts with.** `DRAW-1` and `DRAW-7`, both of which edit
`RenderFramePlanner#plan(for:searchReadout:reusing:damage:)` -- the one consumer
of `searchReadout.activeMatch` (line 301). Same function body, so they must be
sequenced. No conflict on `TerminalSearchStatus.swift` itself.

<a id="select-3"></a>

#### SELECT-3. Materialize a projection row once per row, not once per cell, in link resolution

`cost` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#activationIdentity`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#explicitLink`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#ProjectionRows`

**Problem.** `ProjectionRows`'s subscript is not an index into an array. For a history row it runs a binary search over blocks and then paints the whole row -- two `width`-sized allocations plus per-cell scalar resolution. Two link paths call that subscript from inside a per-*column* loop, so resolving one hyperlink repaints the same row once per cell of the link. The work scales with the width of the link and the depth of history, not with what the pointer did.

**Evidence.** `activationIdentity`, which runs on every hover and every arm:

```swift
for row in range.start.row...range.end.row where stream.indices.contains(row) {
    let start = row == range.start.row ? range.start.column : 0
    let end = row == range.end.row ? range.end.column : columnCount
    for column in max(0, start)..<min(columnCount, end) {
        identity = max(identity, Int(stream[row].cell(at: column).contentIdentity ?? 0))
    }
}
```

`stream[row]` is inside the column loop. `explicitLink` does the same thing in both expansion walks:

```swift
while lower > 0 {
    let candidate = coordinates[lower - 1]
    guard stream[candidate.row].cell(at: candidate.column).hyperlinkId == id else { break }
    lower -= 1
}
```

And the subscript it calls, for any history row:

```swift
guard var row = history.paintedDisplayRow(at: position) else {
    preconditionFailure("the projection addressed a display row history does not hold")
}
```

`LogicalLineStore#paintedDisplayRow` is `locate(displayRow:)` (a binary search over `blocks`, instrumented as `Instrument.displayRowLocate`) followed by `paintedRow(at:)`, which builds `cells` with `reserveCapacity(width)` and then a second `GridRow` of the same width. `explicitLink` additionally materializes a `coordinates: [TerminalTextPosition]` array over the whole soft-wrap chain and finds the click in it with `coordinates.firstIndex(of:)`, a linear scan, when the walk only ever needs to step outward from one cell.

**Ideal fix.** Give both walks a row-scoped cursor, the shape `terminalTokenRange` already uses: `ProjectionCursor` carries `rowUnits` exactly so "a step within the row is allocation-free; crossing a row projects exactly one more row". Concretely, hoist `let projected = stream[row]` above the column loop in `activationIdentity`, and rewrite `explicitLink`'s expansion to hold the current row's `GridRow` and re-fetch only when it crosses a soft-wrap boundary -- which also deletes the `coordinates` array and the `firstIndex(of:)` scan.

**By construction.** With the row held in a local, "a per-cell loop that re-locates history" has no way to be written at these two sites. Making it structural everywhere would mean routing all of these through `ProjectionRows.forEachRow`, which already exists and already owns the seam rules.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** Cost finding, so the experiment: `swift test --package-path lib/TerminalCore --filter Hyperlink` with a new instrumented case. Workload: a terminal at 200 columns with ~5,000 rows of scrollback, one OSC 8 link 180 cells wide sitting on a *history* row; scroll it into view and call `activatableLink(at:)` once on a cell in the middle of it. The number that must move: `Instrument.displayRowLocate` count across that one call, read through the counter API `InstrumentTests` already uses. Today it should be on the order of the link's cell count (~180 for the identity pass, plus the expansion walk); after the fix it should be a small constant times the number of rows the link spans.

**Risk.** The rows must still be fetched through the same `ProjectionRows` accessor, or the alternate-screen seam rule and the open-tail wrap-spacer fill it applies are lost -- that rule is the reason the subscript is not a plain concatenation. A hand-rolled fetch from `history` directly would give a different last-history-row than the projection does.

**Vetted.** I opened `Terminal.swift#ProjectionRows` (lines 537-600),
`#activationIdentity` (lines 3946-3960), `#explicitLink` (lines 3785-3837), and
`LogicalLineStore.swift#locate` (1580), `#paintedRow` (1659-1680) and
`#paintedDisplayRow` (1682-1685). Every quote is verbatim. `paintedRow` really
does make two width-sized allocations -- `cells.reserveCapacity(width)` and then
`GridRow(cells: (0..<cells.count).map { _ in GridCell() })` -- and
`locate(displayRow:)` really does open with `Instrument.displayRowLocate.record()`
before its binary search, so the proposed experiment reads a counter that exists.
`explicitLink`'s `coordinates` array and its `firstIndex(of:)` scan are both
there, as is `stream[candidate.row]` inside each expansion `while`.

**Correction.** Two qualifiers change the size of the prize. First,
`activationIdentity` does not run "on every hover": the only caller path is
`TerminalInteractionPolicy#hoverMutation`, which opens `guard
modifiers.contains(.command)` (line 579), so link resolution runs only while
Command is held. That still means a per-move cost during a Command-drag, but not
an idle-mouse cost. Second, the *live-screen* case is cheap -- the subscript's
`position < historyRows` arm hits `live[i].projected(...)`, which is a
copy-on-write `GridRow` with at most one margin-cell write, no binary search and
no row paint. The expensive path is the history arm, which needs the viewport
scrolled back far enough that the link's row is retained. Both halves of the fix
are still right and still small; the payoff is a Command-hover over scrollback,
not a general one. Note also that `ProjectionRows`'s own doc comment already
declares its per-subscript materialization a deliberate milestone-1 scope line
deferred to a follow-up plan -- the fix here is orthogonal to that, since it
hoists two call sites rather than changing the subscript.

**Conflicts with.** `GRID-2`, which rewrites `ProjectionRows.subscript` and the
five hand-written copies of the history/live seam rule -- same type, and the seam
rule is exactly what `SELECT-3`'s risk paragraph says the walks must keep going
through. `GRID-4`, which collapses `paintedRow` and `materializedGridRow` into
one function with a single allocation: it halves the per-subscript cost this
finding is trying to stop paying per cell, so landing `GRID-4` first shrinks
`SELECT-3`'s measured payoff without removing the defect.

<a id="select-4"></a>

#### SELECT-4. Implement DECSET 1007 and gate the alternate-screen wheel route on it

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#wheelRoute`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#DECPrivateMode`, `lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift#TerminalInputModes`

**Problem.** While the alternate screen is active and mouse tracking is off, DanTerm always converts wheel motion into cursor-key bytes. That behavior is supposed to be under the child's control through DEC private mode 1007 (alternate scroll). DanTerm does not parse 1007 at all, so a program that explicitly turns it off still gets synthetic arrow keys injected into its input, and a DECRQM for `?1007` answers "not recognized" rather than set/reset.

**Evidence.** The route is chosen with no mode consulted:

```swift
private func wheelRoute(for event: TerminalWheelEvent, terminal: Terminal) -> TerminalWheelRoute {
    if event.modifiers.contains(.shift) { return .localViewport }
    if terminal.inputModes.mouseTracking != .off { return .mouseReport }
    return terminal.isAlternateScreenActive ? .alternateScreen : .localViewport
}
```

`Terminal.DECPrivateMode` -- described in its own comment as "every DEC-private mode accepted by set/reset, query, and synchronization" -- lists `mouseClick = 1000`, `mouseDrag = 1002`, `mouseAnyMotion = 1003`, `focusReporting = 1004`, `sgrMouseEncoding = 1006`, and then jumps to `alternateScreen = 1047`. `grep -n 1007` over `TerminalCore/Sources` hits only the two generated Unicode tables.

Both references gate on the mode and default it on. `references/ghostty/src/terminal/modes.zig`: `.{ .name = "mouse_alternate_scroll", .value = 1007, .default = true }`, consumed in `references/ghostty/src/Surface.zig#scrollCallback` as `self.io.terminal.screens.active_key == .alternate and self.io.terminal.flags.mouse_event == .none and self.io.terminal.modes.get(.mouse_alternate_scroll)`. `references/foot/csi.c` handles 1007 in set/reset, in `decrpm` (`case 1007: return decrpm(term->alt_scrolling);`), and in both XTSAVE and XTRESTORE.

**Ideal fix.** Add `alternateScroll = 1007` to `DECPrivateMode` and a matching `alternateScroll: Bool = true` to `TerminalInputModes`, then make `wheelRoute` read it: `return terminal.isAlternateScreenActive && terminal.inputModes.alternateScroll ? .alternateScreen : .localViewport`. `DECPrivateMode` is already the single closed vocabulary that set/reset, DECRQM, and state synchronization all enumerate from, so one enum case buys the query answer and the save/restore behavior with no further edits.

**By construction.** n/a -- this is a missing member of an existing closed vocabulary, not a representable-state problem. Adding it to `DECPrivateMode` is what keeps the three consumers from needing separate edits.

**Verification.** `swift test --package-path lib/TerminalCore --filter Wheel` (and the DECRQM suite). Byte stream: enter the alternate screen with `ESC [ ? 1049 h`, send `ESC [ ? 1007 l`, then feed a one-row-up wheel event and assert `decideTerminalWheel` returns `route == .localViewport` with `inputBytes == []` and `localRowDelta == 0` (the alternate screen has no local scroll). Re-enable with `ESC [ ? 1007 h` and assert the same event returns `route == .alternateScreen` with `ESC [ A`. Separately assert `ESC [ ? 1007 $ p` answers `ESC [ ? 1007 ; 1 $ y` by default and `; 2` after the reset.

**Risk.** Programs that rely on the mode being on by default are unaffected -- the default matches ghostty's. A program that turned 1007 off and had been silently receiving arrows may change behavior; that is the point.

**Vetted.** I opened `TerminalInteractionPolicy.swift#wheelRoute` (lines
620-624), `Terminal.swift#DECPrivateMode` (lines 809-826),
`#decPrivateModeStatus` (6609-6629), `#applyDECPrivateModes` (6655-6720),
`TerminalStateSynchronizationEncoder.swift#appendControlState` (295-340), and
`TerminalInputEncoding.swift#TerminalInputModes` (14-44). `wheelRoute` is
verbatim and consults no mode; `DECPrivateMode` jumps from `sgrMouseEncoding =
1006` to `alternateScreen = 1047`; `grep -rn 1007 lib/TerminalCore/Sources`
hits only `CanonicalCaseless.generated.swift`. Both reference citations verify:
`references/ghostty/src/terminal/modes.zig:218` is `.{ .name =
"mouse_alternate_scroll", .value = 1007, .default = true }`, consumed at
`references/ghostty/src/Surface.zig:3484-3486` in the three-way condition the
finding quotes; `references/foot/csi.c` handles 1007 at lines 445, 650, 698 and
743 exactly as described.

**Correction.** "One enum case buys the query answer and the save/restore
behavior with no further edits" is wrong. `decPrivateModeStatus`,
`applyDECPrivateModes`, and `appendControlState` are three *exhaustive* switches
over `DECPrivateMode`; adding a case makes all three fail to compile until each
gets an arm, and the mode also needs a stored `Bool` on `TerminalModes`, a field
plus init parameter on `TerminalInputModes`, and a line in `Terminal.inputModes`.
Seven edits, all compiler-forced -- which is the real value of the closed
vocabulary, and still "effort small", but the finding should say so. Impact drops
to 2 on reachability: `wheelRoute` tests `mouseTracking != .off` *before* the
alternate-screen arm, so a program that wants the wheel itself and enables mouse
tracking never reaches the 1007 branch at all. The population that observes the
bug is programs that reset 1007 and leave mouse tracking off.

**Conflicts with.** `PARSE-4`, which replaces the three exhaustive
`DECPrivateMode` switches with one data table -- land that first and `SELECT-4`
becomes a one-row addition instead of a seven-site edit. `PARSE-1` (mode 47) and
`GRID-1` (modes 47/1047/1049 as one table) add cases to the same enum and edit
the same two switches; three separate "add a missing mode" findings should be
sequenced or batched. `INPUT-4` also edits `wheelDecision`'s `.mouseReport` arm
but not `wheelRoute`, so that one is adjacent rather than exclusive.

<a id="select-5"></a>

#### SELECT-5. Delete the unreachable second selection branch in the pointer-move arm

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#decidePointerArm`

**Problem.** The `.move` case tests `state.pointerOwners[.left]?.consumption == .selection` twice. The first test returns on every path through it, so the second one is dead code. A reader has to work that out to know which of the two selection behaviors is the real one -- and they differ: the live one passes `dragHover` and extends the selection, the dead one passes `hover` and does not.

**Evidence.** In order, inside `case let .move(cell, modifiers)`:

```swift
if state.pointerOwners[.left]?.consumption == .selection {
    let dragHover = hoverMutation(cell: cell, modifiers: modifiers, terminal: terminal)
    guard let anchorUnit = terminal.selectionAnchorUnit,
          let granularity = terminal.selectionGranularity
    else {
        return pointerDecision(.selection, hoverMutation: dragHover)
    }
    return selectionDecision(...)
}
let hover = hoverMutation(cell: cell, modifiers: modifiers, terminal: terminal)
if state.pointerOwners.values.contains(.report) {
    return pointerDecision(.report, bytes: reportBytes, hoverMutation: hover)
}
if state.pointerOwners[.left]?.consumption == .selection {
    return pointerDecision(.selection, hoverMutation: hover)
}
```

Both arms of the first `if` return, and nothing between the two tests writes `state.pointerOwners`.

**Ideal fix.** Delete the second `if`. Nothing else moves.

**By construction.** n/a -- this is dead vocabulary, not a representable state.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** The existing `TerminalInteractionPolicyTests` suite must stay green with no test edited: `swift test --package-path lib/TerminalCore --filter TerminalInteractionPolicy`. If any test changes behavior, the branch was not dead and the finding is wrong.

**Risk.** None if the reachability argument holds, which the quoted control flow settles.

**Vetted.** I read `decidePointerArm`'s `.move` case whole
(`TerminalInteractionPolicy.swift` lines 299-350). The two tests are at lines
320 and 344, in the order quoted. Between them sit only
`hoverMutation(cell:modifiers:terminal:)` -- which takes no `state` -- and
`state.pointerOwners.values.contains(.report)`, a read. The `encodeTerminalMouse`
call above line 320 mutates `state.mouseTracker`, not `state.pointerOwners`. The
first test's `guard` arm and its fall-through arm both `return`. The branch at
line 344 is dead. Confirmed as written.

**Correction.** Impact drops to 1. This is three lines of dead code in a
well-commented policy file, with no behavior attached and no test to change; it
is worth doing and it is worth almost nothing next to the correctness items in
this lane.

**Conflicts with.** None. No other lane file names `decidePointerArm`.

<a id="select-6"></a>

#### SELECT-6. Carry the normalized `TerminalViewportCell` into `TerminalWheelEvent` instead of loose column and row

`structural` &middot; impact 1, confidence 4 &middot; effort medium &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionVocabulary.swift#TerminalWheelEvent`, `app/SwiftTerminalSessionView.swift#scrollWheel`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#decideTerminalWheel`

**Problem.** `TerminalPointerEvent` was deliberately changed to carry `TerminalViewportCell` whole, because destructuring it at the seam drops the measured insideness and forces the receiver to be told about it a second time. `TerminalWheelEvent` still carries `column: Int, row: Int`. The view has a real `TerminalViewportCell` in hand and takes it apart to build the event, so the wheel's mouse reports are encoded from coordinates the policy cannot check, and a wheel over an off-grid point reports a clamped cell as if the pointer were on it.

**Evidence.** The vocabulary:

```swift
public struct TerminalWheelEvent: Equatable, Sendable {
    public let rowDelta: Double
    /// Zero-based pointed viewport column.
    public let column: Int
    /// Zero-based pointed viewport row.
    public let row: Int
```

and `TerminalPointerEvent` directly above it, whose comment states the rule the wheel does not follow: "One shape for every case is what keeps the clamped coordinates and the measured insideness they were clamped from travelling together: a case that carried loose scalars would drop insideness at the event boundary."

The view destructures right at the seam:

```swift
guard isTornDown == false, let cell = normalizedCell(for: event) else { return }
...
controller.sendWheel(
    .init(rowDelta: rows, column: cell.column, row: cell.row, ...)
```

and the policy hands the loose scalars straight to the encoder in `wheelMetadata` and `wheelDecision` (`column: event.column, row: event.row`), with no counterpart to `decideTerminalPointer`'s `isOnGrid` check. A second producer, the IPC-driven `terminalWheelEvent(_:column:row:)`, builds one from numbers that never passed through `terminalCell(at:)` at all.

**Ideal fix.** Replace `column`/`row` on `TerminalWheelEvent` with `cell: TerminalViewportCell`, exactly as `TerminalPointerEvent` carries it. The IPC producer then has to route through `terminalCell(at:)` or state its insideness explicitly, and `decideTerminalWheel` gains the same on-grid question `decideTerminalPointer` already answers.

**By construction.** "A wheel report encoded from a cell nobody measured against the grid" stops being expressible, and the two producers can no longer diverge in how much validation they did.

**Cheaper fallback.** Leave the shape and clamp `event.column`/`event.row` against `terminal.geometry` inside `decideTerminalWheel`. That stops an out-of-range coordinate reaching the encoder but keeps two vocabularies for one concept and still cannot tell an on-grid cell from a clamped off-grid one.

**Verification.** `swift test --package-path lib/TerminalCore --filter Wheel`. Assert that a wheel event whose cell reports `isInsideGrid == false` produces no mouse-report bytes under `CSI ?1000 h`, and that an in-grid one at the same clamped coordinates produces `ESC [ < 64 ; c ; r M`. The mechanical half is the event literals in the policy tests and the two producers.

**Risk.** Same shape of churn as `INTERACT-2`: a wide, mechanical edit across the wheel test literals and both producers. No behavior changes for on-grid wheels.

**Vetted.** I opened `TerminalInteractionVocabulary.swift` whole (181 lines),
`SwiftTerminalSessionView.swift#scrollWheel` (739-757) and
`#terminalWheelEvent(_:column:row:)` (1057-1071), and
`TerminalInteractionPolicy.swift#wheelMetadata` / `#wheelDecision` (626-710).
Every quote is verbatim, including the `TerminalPointerEvent` doc comment. I also
followed the IPC producer down to `IpcRequest.swift#inputCellCoordinate` (lines
1022-1033): it validates only `Int(exactly:)` and `coordinate >= 0`, with no
upper bound, and the value reaches `encodeMouseReport` untouched through
`wheelDecision`.

**Correction.** The stated problem does not hold. The claim is that the wheel
lacks "any counterpart to `decideTerminalPointer`'s `isOnGrid` check", implying
the pointer path suppresses off-grid mouse reports. It does not.
`decidePointerArm`'s own doc comment (line 181) says so in as many words: "Off-grid
events still reach it, so selection keeps its clamped-edge semantics; `onGrid`
gates only the link work its caller then overrides." Every arm of
`decidePointerArm` builds `reportBytes` from the clamped `cell.column` /
`cell.row` unconditionally, and `decideTerminalPointer`'s off-grid override
rewrites only `hoverMutation`, `openLink` and `armMutation`. So the wheel and the
pointer already agree on off-grid reporting, and the proposed verification --
"assert that a wheel event whose cell reports `isInsideGrid == false` produces no
mouse-report bytes" -- would introduce a rule the pointer path deliberately
rejects. The `isInsideGrid` argument is also weaker for the wheel than for the
pointer: the vocabulary comment justifies carrying the whole cell by the link
work that reads insideness, and the wheel arm resolves no link and no character
boundary, so `offsetX` and `isInsideGrid` would both be dead fields on it.

What is real, and all that is real, is the second half of the evidence: the
IPC-driven producer builds a `TerminalWheelEvent` from numbers that were never
measured against any grid, and `wheelDecision` hands them straight to the
encoder. A `danterm` CLI wheel at column 100000 under `CSI ?1000h CSI ?1006h`
emits `ESC [ < 64 ; 100001 ; ... M` to the child; under legacy encoding it lands
on `SELECT-1`'s clamp. The fix that matches the pointer path is the finding's own
cheaper fallback -- clamp `event.column`/`event.row` against `terminal.geometry`
inside `decideTerminalWheel`, or route the IPC producer through
`terminalCell(at:)` -- not a change to the event's shape. Restated: **clamp the
IPC-supplied wheel coordinates to the grid before they reach the encoder.**
Impact 1: self-inflicted through a controlled surface, no keyboard or trackpad
path reaches it.

**Conflicts with.** `INPUT-4`, directly and exclusively. It adds `columnDelta:
Double` to `TerminalWheelEvent`, changes `scrollWheel`'s construction of that
event, and adds a second emission loop to `wheelDecision`'s `.mouseReport` arm --
the same three symbols this finding proposes to reshape. Only one of the two can
define the wheel event's fields; `INPUT-4` is the larger and better-motivated of
the pair, so fold the coordinate clamp into it rather than landing them
separately.

<a id="select-7"></a>

#### SELECT-7. Collapse the two copies of "project a stream range onto one viewport row" in the frame planner

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift#hoveredColumns`, `lib/TerminalCore/Sources/TerminalRenderPlanning/RenderFramePlanner.swift#columns`

**Problem.** The same rule -- clip a half-open stream range to one viewport row's column span -- is written twice, a few lines apart, with two subtly different endings. One rejects empty ranges and clamps the result into `0..<columns`; the other accepts an empty range and does not clamp. Selection and search matches go through the strict one, hover through the loose one, and nothing in either doc comment says why they differ.

**Evidence.** `hoveredColumns`:

```swift
let start = streamRow == range.start.row ? range.start.column : 0
let end = streamRow == range.end.row ? range.end.column : columns
guard start <= end else { return nil }
return start..<end
```

`columns`:

```swift
guard let selection = range, selection.start != selection.end else { return nil }
...
let clampedStart = min(max(start, 0), columns)
let clampedEnd = min(max(end, 0), columns)
guard clampedStart < clampedEnd else { return nil }
return clampedStart..<clampedEnd
```

Both are called from the same row body in `planFrame`, over ranges from the same coordinate space, and a hovered link range is never empty -- `Terminal#setInteractionLink` admits only a resolved link over at least one cell.

**Ideal fix.** Keep `columns` and delete `hoveredColumns`, calling `columns(for: hoveredLinkRange, ...)` at the one hover call site. One rule, one clamp, one emptiness policy.

**By construction.** "Two row-clipping rules that can disagree at an edge" stops existing. n/a beyond that -- this is duplication, not a representable state.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `just test-ui` plus `swift test --package-path lib/TerminalCore --filter RenderFrame`. Behavioral assertion: hover a link that ends exactly at the last column of a row and one that spans a soft-wrap seam, and assert the planned underline decoration covers the same columns before and after. A test that fails here proves the two rules did differ and the finding needs the difference documented instead.

**Risk.** If a hovered link range can legitimately be empty or out of range, the strict version would drop an underline the loose one drew. The confidence is 4 rather than 5 for exactly that: I read the admission path but did not exhaustively enumerate every producer of a hover range.

**Vetted.** I opened `RenderFramePlanner.swift#hoveredColumns` (579-592) and
`#columns` (595-610); both are verbatim, and both are called from the same row
body at lines 334 and 340. I did the enumeration the auditor did not, which is
why confidence goes up rather than down. The planner's hover range is
`terminal.hoveredLink?.range` (line 300), which is
`Terminal#resolvedInteractionLink` → `publicRange(state.range)`, and its only two
producers are `Terminal#explicitLink` (end is `last.column + 1`, with `upper >=
lower`) and `Terminal#detectedLink` (end is `lastUnit.end`, with `end > start`).
Neither can produce an empty range, and neither can exceed `columnCount`, so
`columns`'s two extra guards are no-ops on this input. The one remaining
difference -- `hoveredColumns` returning `0..<0` where `columns` returns `nil` for
a link ending at column 0 of its last row -- is also invisible: the consumer is
`hovered?.contains(column) == true` (line 383), and an empty range contains
nothing. The substitution is behavior-preserving today.

**Correction.** Impact drops to 1. This deletes fourteen lines and one
redundant rule; it changes no pixel and guards no failure. It is worth doing
alongside another edit in this file, not on its own.

**Conflicts with.** `DRAW-7` and `DRAW-1`, which both rework
`RenderFramePlanner#plan(for:searchReadout:reusing:damage:)` -- `DRAW-7` replaces
`overlayState(at:selected:matches:)` with an advancing cursor over the same row
body that calls `hoveredColumns` and `columns`. Same function, so sequence them;
they are not mutually exclusive.

#### Dropped (SELECT)

- **`SettledSelection.isCaret` as a derivable tag.** It is not derivable: `setSelection(anchorUnit:focus:granularity:)` computes it, but the other setters deliberately store `false` for an empty range so a programmatic empty selection stays visible and Copy-enabling. Real provenance about which door the selection came through.
- **`selectionRequiresNonemptyReflowResult` as a mirror.** Same reason -- the file's own comment says coordinate distance cannot distinguish a deliberate blank-cell selection from one whose content was later erased.
- **`TerminalScrollProjection.isFollowing` as a mirror of `topRow == totalRows - windowRows`.** Not a mirror: a browsing anchor can clamp to `maximumTop` after eviction, which is pinned at the bottom without following.
- **`hoveredLinkRevisionCounter` beside `hoveredLinkRange` in `DamageActionSnapshot`.** Looks like a mirror, is not: the comment at `recordDamage(from:to:)` names the two independent reasons a hovered run needs repainting, and `TerminalHyperlinkInteractionTests` pins the case where the range is unchanged and the target is not.
- **`INTERACT-6` (key wheel-remainder storage by its enum) still live in the tree.** `TerminalInteractionState` still holds `localWheel`/`reportWheel`/`alternateWheel` as three fields with three switch helpers (`wheelRemainder`, `setWheelRemainder`, `resetWheelRemainder`). Owned by the closed audit; not re-raised here.
- **`isActivatableWebURI` boundary arithmetic.** I walked the percent-encoding, IPv6-compression, bracketed-host, and port-range paths against RFC 3986 looking for an off-by-one and found none. The `colon + 2 < scalars.count` and `index + 2 < values.count` guards are both correct.
- **`hasHTTPSPrefix`'s `index + 8 <= scalars.count` guard.** Reads like an off-by-one for the bare `https://` case; traced it through and the resulting URI is rejected by `isActivatableWebURI` anyway (empty authority), so there is no behavior to fix.
- **Missing DEC private mode 9 (X10 press-only mouse) and modes 1005/1015/1016.** Absent, but ghostty and vte both treat 9 as legacy and DanTerm's `.click`/`.drag`/`.anyMotion` enum is a cleaner closed vocabulary than adding a fourth mode nothing modern requests. Raise with the user rather than audit-driving it.
- **`logicalLineRange(at:in:)` indexing `stream[last]` when the projection is empty.** `target` would be `-1`. I could not construct a reachable empty `activeProjection()` -- `rows >= 1` is enforced by `resize` -- so it is a latent trap with no caller, not a defect.
- **Selection surviving child overwrites of the text under it.** DanTerm anchors selection to absolute stream rows and does not clear on a write into the range. Ghostty behaves comparably for scrollback pins; this reads as a decision, not a bug, and I found no reference disagreement worth citing.

#### Pruned (SELECT)

None. All seven findings survive verification with their evidence intact; six
were rescored and one (`SELECT-6`) was rewritten around a different defect. The
verification pass corrected four factual claims: `SELECT-1` asserts no test pins
the clamp and one does, `SELECT-2` asserts a reachable half-populated readout and
I could not reach it, `SELECT-4` asserts a one-site edit and it is a seven-site
compiler-forced one, and `SELECT-6` asserts an on-grid check on the pointer path
that the pointer path deliberately does not perform. `SELECT-3`'s and
`SELECT-7`'s evidence held up in full.


### Area: PTY process lifecycle, the read/write path, and the flight recorder (`PTY`)

_Scope: `lib/TerminalPTY/Sources/TerminalPTYHost/` (host, spawner, in-flight launch,
resize coalescer, canonical input gate, child exit probe, flight recorder),
`lib/TerminalPTY/Sources/PaneProcessLifecycle/` (reducer, launch policy),
`lib/TerminalPTY/Sources/PTYSessionBootstrap/main.c`, and the delivery boundary in
`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift`. Read
`docs/scratch/2026-08-18-construction-audit.md` for PTY-1..PTY-6 and XPORT-1..XPORT-4;
all are landed or explicitly skipped._

**The auditor's read on the area.** The read turn, the source registry, and the
`InFlightLaunch` rendezvous are the strongest parts of this tree -- each one has a written
argument for why the shape is what it is, and each argument holds up against the code. The
partial-write bookkeeping is also correct: every counter I traced (`pendingInputByteCount`,
`pendingInputHeadOffset`, the reject paths) balances. The defects that remain all sit at the
*end* of a lifecycle rather than in its steady state: a teardown ladder that is bounded only
when a human asked for it, a session sweep that fires once per stage and then stops, a
recorder guard that traps where the same file already has a total classifier, and a
launch handshake that reads "no payload" as "success". Two more are pure vocabulary
duplication across the C/Swift boundary and inside the session census. I deliberately did
not re-open the flight recorder's per-event `[UInt8]` payload: `XPORT-2` measured the whole
recorder at 0.211% inclusive CPU and skipped the byte ring on that number, and nothing I
read changes that verdict. I also looked at the `TerminalPTYUpdateSignal.accumulate`
quadratic claim and dropped it -- the merge really is bounded.

<a id="pty-1"></a>

#### PTY-1. Arm the teardown bound when the ladder starts, not when a human asks to close

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#beginShutdown`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#armExitBound`,
`lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift#beginTeardown`

**Problem.** The host has exactly one mechanism that guarantees teardown finishes:
`armExitBound`, whose timer runs `exitBoundElapsed` and forces quiescence by killing the
whole session and reaping the leader. It is armed from one place, `beginShutdown`. But the
teardown ladder has two entrances. The other one -- a child that exits on its own -- reaches
`beginTeardown` through `.childExited` with no bound armed at all. On that path, if the
session never drains, the host polls `sessionMembers` every 10ms forever: it never runs
`finishTeardown`, never calls `report(...)`, so the pane is never told its child exited, and
`TerminalPaneTerminationRegistry` keeps the handle retained.

**Evidence.** `armExitBound()` appears at exactly one call site in the whole file:

```swift
private func beginShutdown(completion: (@Sendable () -> Void)?) {
    ...
    shutdownRequested = true
    descriptorOwnershipSealed = true
    armExitBound()
    process(.requestClose)
}
```

The natural path never touches it. `handleRunning` takes `.childExited` straight into the
ladder:

```swift
case .childExited(let status):
    if outputEOF {
        return beginTeardown(result: .exited(status), leaderStatus: status, reapLeader: true)
    }
    storage = .drainingOutput(status)
    return [.drainOutput]
```

and the result only reaches the consumer at the far end of the ladder, in
`finishTeardown(_:)`, which is reached only from `.sessionDrained`:

```swift
private mutating func finishTeardown(_ context: TeardownContext) -> [PaneProcessLifecycleCommand] {
    storage = .finished
    var commands: [PaneProcessLifecycleCommand] = [.cancelGrace]
    if let result = context.result { commands.append(.report(result)) }
    commands.append(.finishTeardown)
    return commands
}
```

So "the session never drains" and "the pane never learns the child exited" are the same
state. The bound that exists to break exactly that state is not armed.

**Ideal fix.** Make the bound a property of being in the ladder rather than of who asked to
enter it: arm it in the host's `execute(.closeMaster)` arm, which every entrance into
`.tearingDown` emits (`beginTeardown` always appends `.closeMaster`). `beginShutdown`'s call
then disappears, because the `.requestClose` it processes reaches `.closeMaster` anyway.
One arm site, one cancel site, no path into the ladder that can skip it.

**By construction.** "A host in `.tearingDown` with no bound armed" stops being
representable. The `shutdownRequested` flag stops being a proxy for "bounded".

**Cheaper fallback.** Add a second `armExitBound()` call in the `.closeMaster` command arm
while leaving `beginShutdown`'s in place. That fixes the symptom but keeps two arm sites and
the same class of omission for whatever the third entrance turns out to be.

**Verification.** `TerminalPTYHostTests`: launch a host against a fake session whose census
never empties (the existing `applicationExitBound: .milliseconds(1)` injection at
`TerminalPTYHostTests.swift:3279` already shows the shape), drive `.childExited` rather than
`requestShutdown`, and assert that `whenQuiescent` fires and `resourceSnapshot().isReleased`
becomes true inside the injected bound, with `census.forcedQuiescenceCount == 1`. Today that
test hangs.

**Risk.** Arming the bound on every natural exit means a slow-but-honest drain that would
have finished at, say, 2.5s now gets forced instead. The default bound is 2 seconds and the
ladder's own grace timers total 300ms, so the margin is large; the workload that would show
a regression is a pane whose session holds a member in an uninterruptible wait, which is the
exact case the forcing is for.

**Vetted.** I opened `TerminalPTYHost.swift` (`beginShutdown` 898, `armExitBound` 909,
`cancelExitBound` 921, `exitBoundElapsed` 1026, `performForcedCleanupAfterMasterClose` 1041,
the `.closeMaster` arm 1676) and `PaneProcessLifecycle.swift` (`handleRunning` 326,
`beginTeardown` 422, `finishTeardown` 440). Every quote is in the tree and says what the
finding says it says. `armExitBound()` has exactly one call site. The natural exit really is
unbounded: `.childExited` with `outputEOF` reaches `beginTeardown` -> `.closeMaster` ->
`.masterClosed` -> the hangup/terminate/kill ladder, and `.report` is emitted only by
`finishTeardown(_:)`, which only `.sessionDrained` reaches. The producer the finding leaves
unnamed matters, because the obvious candidate does not work: the probe's "resistant" job
(`PTYProbe/main.c#spawn_job`) only sets `SIG_IGN` for SIGHUP and SIGTERM and dies at `.kill`,
so that ladder converges. What does not converge is a member `kill(2)` refuses -- a
setuid-root background job left by `sudo ... &` -- because `applySessionCensus` never sees the
census empty and nothing else ends the poll. Plausible in a developer terminal, so the finding
stands; narrower than impact 4, and app quit still rescues the process-ownership half because
`requestShutdown` arms the bound on a host already in the ladder.

**Correction.** The ideal fix cannot be "arm in the `.closeMaster` arm, and `beginShutdown`'s
call then disappears". `beginShutdown` also has to bound the window where the reducer is in
`.idle` or `.spawning`, neither of which emits `.closeMaster`: `handleSpawning(.requestClose)`
moves to `.closingWhileSpawning` and only a later `.spawnSucceeded` reaches `beginTeardown`.
The bound is what rescues that window -- `exitBoundElapsed` ->
`performForcedCleanupAfterMasterClose` -> `inFlightLaunch?.abandon()`, which kills the leader
so the blocking handshake read returns, a coupling `PTYSpawner.swift:207-211` tells the reader
to keep intact. Removing the shutdown-request arm would leave a bootstrap that stalls before
`execve` unbounded. So the fix is additive: arm in the `.closeMaster` arm *and* keep
`beginShutdown`'s arm (`armExitBound` already cancels first, so re-arming is safe). What the
auditor filed as the cheaper fallback is the correct fix; "one arm site" is not on offer.

**Conflicts with.** Nothing in this lane blocks it. Cross-lane, GATE-4 rewrites the exit-bound
assertions in `TerminalPTYHostTests.swift#closeRacingPromptSpawnUsesTeardownLadder`, which is
the suite this finding adds to and whose meaning changes once the bound is armed on the
natural path; land them in one order and re-read the other.

<a id="pty-2"></a>

#### PTY-2. Sweep the session census against the members already signalled, not against a one-shot per-stage latch

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applySessionCensus`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#signalSession`,
`lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift#handleTeardown`

**Problem.** `sessionPollStageSignaled` is a boolean that means "this stage has already been
swept". Once it is true, every later poll of the same stage enumerates the session and
signals nothing. `.hangup` and `.terminate` each get a fresh sweep when the grace timer
advances the stage, but `.kill` is the last rung: `handleTeardown` emits
`[.signalSession(.kill)]` with no `scheduleGrace`, so there is no later stage and no later
sweep. A session member that appears between the kill census and the kill sweep -- a fork the
census did not see -- is never signalled, while the 10ms poll keeps running and the ladder
keeps waiting for a census that will never be empty.

**Evidence.**

```swift
private func applySessionCensus(_ members: [pid_t], sessionID: pid_t) -> Bool {
    guard members.isEmpty == false else {
        cancelSessionPoll()
        return true
    }
    guard sessionPollStageSignaled == false, let stage = sessionPollStage else { return false }
    ...
    for pid in members where getsid(pid) == sessionID {
        _ = kill(pid, signal)
        if stage != .kill { _ = kill(pid, SIGCONT) }
    }
    sessionPollStageSignaled = true
    return false
}
```

and the last rung of the ladder, which never schedules another grace:

```swift
case .terminate:
    next.stage = .kill
    storage = .tearingDown(next)
    return [.signalSession(.kill)]
case .kill:
    return []
```

The forced-quiescence path in the same file already rejects this design for itself --
`killOwnedSession` re-censuses and re-kills in a loop precisely because one sweep is not
enough:

```swift
/// The census is retried rather than treated as optional: it is the only way to
/// see background and stopped jobs, which routinely sit in process groups of
/// their own.
```

**Ideal fix.** Delete `sessionPollStageSignaled` and hold, instead, the set of pids already
signalled at the current stage. Each poll signals `members` minus that set and unions them
in; advancing a stage clears the set. Then "signal every member of the session at this stage"
is a fact about the members rather than a fact about time, and a member that appears late is
signalled on the next poll for free -- including at `.kill`, where there is no next stage to
rescue it. It also removes the current double-signal of a process that was already killed,
which the latch exists to prevent.

**By construction.** "A live session member the current stage has never signalled" stops
being reachable while the poll is armed. The `stage != .kill` special case for `SIGCONT`
stays, but the latch and its `clearSessionPollTracking` companion go away.

**Cheaper fallback.** Sweep unconditionally at `.kill` only (`sessionPollStageSignaled` still
latches `.hangup`/`.terminate`). SIGKILL is idempotent so nothing breaks, but the same hole
stays open for a member that appears during the `.hangup` or `.terminate` window and is then
carried into `.kill` -- and the reader still has to know which stages latch and which do not.

**Verification.** `TerminalPTYHostTests` with an injected census witness: return a member
list, let the ladder reach `.kill` and sweep, then have the *next* census return a different
pid. Assert that a kill reaches the new pid and that the host reaches quiescence. Today the
new pid is never signalled and the test times out.

**Risk.** With the per-stage set, a process that ignores SIGHUP is no longer re-signalled at
that stage (same as today), but a process that the census loses and regains -- for example
during a `proc_listallpids` capacity retry -- would be re-signalled. For `.hangup` and
`.terminate` that means a second SIGHUP/SIGTERM to a process mid-cleanup. Keying the set by
pid makes that only happen when the census genuinely lost sight of the process.

**Vetted.** I opened `applySessionCensus` (2384), `signalSession` (2368), `sessionMembers`
(2404), `sessionPollFired` (2460), `clearSessionPollTracking` (2473), and
`PaneProcessLifecycle.swift#handleTeardown` (370-411). Both code quotes and the
`killOwnedSession` comment quote are exact. The latch is real and `.kill` really is the rung
with no successor sweep.

**Correction.** The hole is narrower than the prose implies. Everything alive at the moment of
the `.kill` census is signalled; the only member that escapes is one created *after* that
enumeration, which means its parent forked in the window between `sessionMembers` returning
and the `for pid in members` loop reaching that parent -- microseconds, and its parent is
about to be SIGKILLed. A member that survives `.kill` for any other reason (EPERM on a
root-owned process, an uninterruptible wait) is not rescued by re-sweeping either, so the
per-stage set does not help it. Rate this as closing a narrow race with an unbounded
consequence, not as a routinely reachable stall. Separately, the Risk paragraph's
"`proc_listallpids` capacity retry" is dead code: the syscall returns a *byte* count
(`references/xnu/bsd/kern/proc_info.c:478-480` sets `*retval = n * sizeof(int)`; iTerm2 divides
by `sizeof(int)` at `references/iterm2/sources/iTermLSOF.m:221`), while `sessionMembers`
compares it against an element capacity, so `count < capacity` holds by a 4x margin and the
doubling loop never runs. See PTY-6 for what that means for the census value itself.

**Conflicts with.** PTY-6 (it deletes the `sessionID:` parameter and changes the type this
finding's set hangs off -- the auditor says as much, and they should land together, PTY-6
first) and PTY-9 (both rewrite `signalSession`'s body).

<a id="pty-3"></a>

#### PTY-3. Place a follow subscription's cursor through the recorder's own classifier instead of trapping on it

`structural` &middot; impact 2, confidence 4 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift#addFollowSubscription`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift#cursorPlacement`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift#cursorSnapshot`

**Problem.** The recorder already owns a total, non-trapping answer to "can this coordinate
name a position in my lifetime": `cursorPlacement` checks the lifetime id, both byte
watermarks, the sequence ceiling, and retained-position agreement, and returns
`.unplaceable` rather than failing. `addFollowSubscription` does not use it. It asserts one
of those same conditions as a `precondition`, so a coordinate the recorder is perfectly able
to reject instead kills the process. The registration path is also the one place a cursor
crosses a queue hop and a `sessionLookup` re-resolution before it is used
(`app/PaneTapeBroker.swift#finishPreparedFollow` takes `opening.nextCursor` from a fence
taken earlier, off the main queue, then re-looks-up the session by pane id), which is exactly
where a cursor from a different recorder lifetime can arrive.

**Evidence.**

```swift
package func addFollowSubscription(
    id: UUID,
    from cursor: TerminalFlightRecordingCursor,
    ...
) -> Bool {
    precondition(followSubscriptions[id] == nil)
    precondition(cursor.nextSequence <= nextSequence)
    guard followSubscriptions.count < Self.maximumFollowSubscriptions else { return false }
```

Note the shape: the function already returns `Bool` to mean "refused", and already uses
`guard ... else { return false }` for the cap immediately below. The classifier it should be
calling sits 90 lines away and checks a strict superset of the same condition:

```swift
package func cursorPlacement(from cursor: TerminalFlightRecordingCursor)
    -> TerminalFlightRecordingCursorPlacement
{
    guard cursor.recorderLifetimeId == lifetimeId,
          ...
          cursor.nextSequence <= nextSequence,
          ...
    else { return .unplaceable }
```

`cursorSnapshot` has a third copy of the rule, spelled as a `preconditionFailure`:

```swift
guard case .placed(let snapshot) = cursorPlacement(from: cursor) else {
    preconditionFailure("cursor must be placed before taking a snapshot")
}
```

**Ideal fix.** Change `addFollowSubscription` to take the cursor through `cursorPlacement`
and return `false` on `.unplaceable`, and delete the `precondition`. The caller already
handles a `false` return (`SwiftTerminalSessionView.swift#addPaneTapeFollowSubscription` reads
`accepted`), so the refusal has a destination. Better still, give the subscription a
`PlacedCursor` type that only `cursorPlacement` can mint, so `pushFollowSubscription` no
longer routes an arbitrary coordinate into `cursorSnapshot` and that
`preconditionFailure` goes with it.

**By construction.** A subscription holding a coordinate the recorder cannot place stops
being representable, and the "cursor must be placed" rule is stated once instead of three
times.

**Cheaper fallback.** Turn the `precondition` into a `guard ... else { return false }` in
place. That removes the trap but keeps three copies of the placement rule, and keeps
`pushFollowSubscription` calling `cursorSnapshot`, whose `preconditionFailure` is then the
next trap in line.

**Verification.** `TerminalFlightRecorderTests`: build a recorder, record a few events, then
call `addFollowSubscription` with a cursor whose `recorderLifetimeId` is a different UUID and
whose `nextSequence` exceeds the recorder's. Assert it returns `false` and that
`hasFollowSubscription(id:)` is false. Today it traps.

**Risk.** A registration that used to be accepted on a technically-invalid-but-harmless
cursor now gets refused, so the client sees a failed follow instead of a stream that starts
at a wrong offset. That is the better failure, but it is a behavior change on the IPC
surface and `integrations/danterm/SKILL.md` should say so.

**Vetted.** I opened `TerminalFlightRecorder.swift`: `addFollowSubscription` (492-511),
`cursorPlacement` (580-594), `cursorSnapshot` (567-578), `pushFollowSubscription` (536-556),
and `coordinatesMatchRetainedPosition` (695-714). Every quote is exact, and
`pushFollowSubscription` does route a stored cursor into `cursorSnapshot`, so the
`preconditionFailure` is the second trap the finding says it is. I then traced the whole
production producer chain: `PaneTapeBroker.beginFollow` -> `finishPreparedFollow` ->
`TerminalSession.addPaneTapeFollowSubscription` ->
`SwiftTerminalSessionView.swift:1318-1332` -> `recorderCursor` -> the host's
`addFlightRecordingFollowSubscription` fence.

**Correction.** No production producer can hand `addFollowSubscription` a cursor the recorder
cannot place, so the trap is not reachable and the finding is not a correctness issue. A
client-supplied cursor reaches the recorder only through `streamFence`, which classifies it and
substitutes a recorder-minted cursor on `.unplaceable`; every `nextCursor` an opening can carry
(`PaneTapeStreamState.swift:204, 240, 266, 304, 342, 412`) is a snapshot cursor minted by this
recorder. Eviction cannot spoil a minted cursor either: `coordinatesMatchRetainedPosition`
takes the `cursor.nextSequence < firstRetainedSequence` branch and compares the watermarks with
`<=`. The queue hop the finding points at only matters if `sessionLookup` can return a
different recorder for one `PaneId`, and `paneHosts[paneId]` is written exactly once per pane
(`AppRuntime.swift#installPane`, the only write). So the finding as it should read: the
placement rule is stated three times, once as a `precondition` in a function that already
returns `Bool` to mean refused. Keep the fix -- route through `cursorPlacement`, return
`false`, and mint a `PlacedCursor` so `cursorSnapshot`'s `preconditionFailure` goes too -- and
drop both the reachability claim and the Risk paragraph: no registration that is accepted today
would be refused, so `integrations/danterm/SKILL.md` needs no edit.

**Conflicts with.** Nothing. No other lane file touches `TerminalFlightRecorder`'s subscription
path (MOBKIT reads the recorder only in its Dropped list; SUPPORT's `PaneTapeBroker` finding is
in `writePaneTapeRecords`, not the follow path).

<a id="pty-4"></a>

#### PTY-4. Share the bootstrap stage vocabulary between the C child and its Swift parent instead of hardcoding 8

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalPTY/Sources/PTYSessionBootstrap/main.c#bootstrap_stage`,
`lib/TerminalPTY/Sources/TerminalPTYHost/PTYSpawner.swift#BootstrapStage`,
`lib/TerminalPTY/Sources/TerminalPTYHost/PTYSpawner.swift#spawn`

**Problem.** The child writes a stage number down the status pipe; the parent decides from
that number whether the failure is retryable with a different working directory. The number
is an implicit ordinal of a C enum, and the parent's copy of that ordinal is a hand-written
literal. Inserting any stage before `bootstrap_stage_working_directory` shifts it, and
nothing catches the shift: the parent classifies a cwd failure as `.systemError`, the
reducer's `.spawnFailed(.systemError)` arm ends the launch instead of retrying, and the
`requested -> home -> /` fallback chain silently stops working. The C enum's first
enumerator, `bootstrap_stage_usage = 1`, is dead -- the `argc < 6` path calls `_exit(127)`
without ever writing it -- so today's literal 8 is set by an enumerator that has no other
effect at all.

**Evidence.** The child:

```c
enum bootstrap_stage {
    bootstrap_stage_usage = 1,
    bootstrap_stage_cloexec,
    ...
    bootstrap_stage_working_directory,
    bootstrap_stage_exec
};
```

The parent, in a different language and a different target:

```swift
/// Only cwd failures are retryable by the pure launch-attempt chain.
private enum BootstrapStage: Int32 {
    case workingDirectory = 8
}
```

used as:

```swift
if bootstrapFailure.stage == BootstrapStage.workingDirectory.rawValue {
    return .failure(.workingDirectoryUnavailable)
}
```

The consequence of a mismatch is the retry chain in
`PaneProcessLifecycle.swift#handleSpawning`, which only advances `attemptIndex` for
`.spawnFailed(.workingDirectoryUnavailable)`.

**Ideal fix.** Give `PTYSessionBootstrap` a public header declaring `enum bootstrap_stage`
and `struct bootstrap_failure`, and have `TerminalPTYHost` depend on that header target and
import it. Then `bootstrap_stage_working_directory` is one declaration read by both sides,
`BootstrapFailure`'s Swift redefinition disappears with it, and the enumerator can be
reordered freely. While the header exists, drop the dead `bootstrap_stage_usage` and make
the `argc < 6` path report `bootstrap_stage_usage` properly or delete the enumerator.

**By construction.** "The two sides disagree about what stage 8 means" stops being
representable, and so does the second definition of the pipe payload struct.

**Cheaper fallback.** Add a lint that greps the C enum and asserts the ordinal matches the
Swift literal. That catches the drift but keeps two declarations and adds a script to the
gate, which is more machinery than the header it is standing in for.

**Verification.** `TerminalPTYHostTests` already spawns real children through
`PTYSessionBootstrap`. Add a case that launches into a working directory that does not
exist and asserts the pane lands in one of the fallback directories rather than reporting
`launchFailed(.systemError(...))`. That test passes today and keeps passing after the fix --
its value is that it fails the moment an enumerator is inserted, which is the whole point.

**Risk.** Adding a C header target touches `Package.swift`; read
`docs/design/2026-08-17-package-owns-its-targets.md` first. The bootstrap executable itself
must keep compiling with no new dependency.

**Vetted.** I opened `PTYSessionBootstrap/main.c` (the enum at 12-22, `fail_bootstrap` 29-45,
`main` 47-81), `PTYSpawner.swift` (`spawn` 41-172, `BootstrapFailure` 245-248, `BootstrapStage`
250-252), `handleSpawning` in the reducer, and `lib/TerminalPTY/Package.swift`. Every quote is
exact and the ordinals do line up today: `usage` 1, `cloexec` 2, `setsid` 3, `open_slave` 4,
`controlling_terminal` 5, `standard_streams` 6, `foreground_group` 7, `working_directory` 8,
`exec` 9. `bootstrap_stage_usage` is dead, and the literal `8` really is set by an enumerator
with no other effect. Dropped impact to 2 because nothing is wrong now: the defect is a hazard
that needs a future edit to become one, and the cwd fallback chain works today.

**Correction.** The ideal fix costs a little more than the write-up allows. SwiftPM will not
build a header-only C target, so the shared ABI has to be a small target carrying the header
plus a placeholder source, added to `Package.swift` beside `PTYSessionBootstrap` (declared at
lines 49-52 today with no dependencies) and depended on by both it and `TerminalPTYHost`. That
is still the right shape -- one declaration, and `BootstrapFailure`'s Swift redefinition goes
with it -- but read `docs/design/2026-08-17-package-owns-its-targets.md` before writing it, and
expect the diff to touch four targets rather than two.

**Conflicts with.** PTY-5. Both findings edit `main.c#main`'s `argc < 6` path and the failure
classification in `PTYSpawner.swift#spawn`, and they disagree about
`bootstrap_stage_usage`: this one says delete it or make it live, PTY-5 says make it live.
Decide the enumerator once, in whichever lands first.

<a id="pty-5"></a>

#### PTY-5. Make an absent bootstrap-failure payload a launch failure, not a launch success

`correctness` &middot; impact 1, confidence 4 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/PTYSpawner.swift#readBootstrapFailure`,
`lib/TerminalPTY/Sources/TerminalPTYHost/PTYSpawner.swift#spawn`,
`lib/TerminalPTY/Sources/PTYSessionBootstrap/main.c#main`

**Problem.** The handshake has three outcomes -- the child exec'd (pipe closed by
`FD_CLOEXEC`), the child failed and said why (a complete payload), and the child died
without saying anything (a short read or a write that failed partway). `readBootstrapFailure`
folds the third into the first by returning `nil`, and `spawn` reads `nil` as success. The
host then adopts a master and a leader for a child that is already dead, and the user gets a
pane that opens and immediately reports exit status 127 instead of a launch failure. The
`argc < 6` path in the child produces exactly this: it calls `_exit(127)` without writing.
So does a bootstrap killed by a signal, and so does a partial `write` on the status pipe,
which `fail_bootstrap` tolerates with `break`.

**Evidence.** The reader collapses two outcomes:

```swift
return received == expected ? failure : nil
```

The caller reads `nil` as success and falls straight through to adoption:

```swift
let bootstrapFailure = readBootstrapFailure(statusPipe[0])
Darwin.close(statusPipe[0])
statusPipe[0] = -1
if let bootstrapFailure { ... return .failure(...) }

let currentFlags = fcntl(master, F_GETFL)
```

and the child's one silent exit:

```c
int main(int argc, char *argv[], char *envp[]) {
    if (argc < 6) {
        _exit(127);
    }
```

`bootstrap_stage_usage` exists in the enum for this case and is never written.

**Ideal fix.** Return a three-case value from the handshake -- `execSucceeded` (0 bytes read,
clean EOF), `failed(BootstrapFailure)` (complete payload), `truncated` (any nonzero count
short of the payload, or a read error) -- and have `spawn` map `truncated` to
`.failure(.systemError(EPROTO))`. `nil` currently carries two meanings and the call site
cannot tell them apart; a case per outcome makes the distinction the reader's job rather
than the caller's guess. Make the child's `argc < 6` path call `fail_bootstrap(status_fd,
bootstrap_stage_usage, EINVAL)` in the same change, so the dead enumerator becomes live.

**By construction.** "A partially written failure payload read as a successful launch" stops
being representable, because the value the reader returns names which of the three things
happened.

**Cheaper fallback.** Treat `received > 0 && received < expected` as a failure and leave
`received == 0` as success. That closes the partial-write hole and leaves the
`_exit(127)`-with-no-write hole open, and the `nil` overload survives.

**Verification.** `TerminalPTYHostTests` with a bootstrap executable stub that writes four
bytes and exits: assert the host reports `.launchFailed(.systemError(_))` rather than
`.exited(...)`. Today it reports an exit.

**Risk.** A child that legitimately closes the status pipe without exec'ing would now be a
failure. Nothing in `main.c` does that -- every path either `fail_bootstrap`s or `execve`s --
so the new classification has no other producer.

**Vetted.** I opened `readBootstrapFailure` (212-229), the `spawn` call site (147-158),
`main.c#main` (47-50), `fail_bootstrap` (29-45), and `resolveLaunchPlan` in
`LaunchPolicy.swift`. Every quote is exact, and `nil` really does carry both "the pipe closed
cleanly" and "a short read".

**Correction.** Neither producer the finding names is reachable. `resolveLaunchPlan` always
builds `arguments: [argv0]` -- exactly one element (`LaunchPolicy.swift:191`) -- so
`bootstrapArguments` is always six entries and `argc < 6` is never true; `.spawn` only ever
carries a `plan.attempts[i]`, so no other spec exists. The partial write is eight bytes to a
pipe, well under `PIPE_BUF`, and the parent holds the read end open until
`readBootstrapFailure` returns, so `fail_bootstrap`'s `break` needs a hard descriptor error to
fire. What is left is a bootstrap killed by an outside signal between `posix_spawn` and
`execve`: the pane then opens and reports an exit rather than a launch failure. That is real
but small, hence impact 1. The design argument -- one return value naming which of three things
happened -- stands on its own and is still worth the change; the child-side half ("make the
`argc < 6` path report `bootstrap_stage_usage`") is dead-code maintenance, not a fix.

**Conflicts with.** PTY-4, which edits the same `argc < 6` path and the same
`stage`-classification arm in `spawn`, and which proposes deleting the enumerator this finding
proposes to start writing.

<a id="pty-6"></a>

#### PTY-6. Let the session census carry the session it enumerated, so no consumer re-filters it

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#sessionMembers`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applySessionCensus`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#killOwnedSession`

**Problem.** `sessionMembers(sessionID:)` returns `[pid_t]` and has already guaranteed that
every element is in that session. Both consumers then re-derive the same guarantee with the
same `getsid` call, and `applySessionCensus` additionally takes the session id back as a
parameter so it can. The rule "a member is a pid whose `getsid` is this session" is written
three times over about forty lines, and the return type says nothing about it, so a fourth
consumer has no way to know whether it is expected to re-filter.

**Evidence.** The producer already filters:

```swift
return pids.prefix(Int(count)).filter { pid in
    pid > 0 && getsid(pid) == sessionID
}
```

The first consumer filters again, with the session handed back in:

```swift
private func applySessionCensus(_ members: [pid_t], sessionID: pid_t) -> Bool {
    ...
    for pid in members where getsid(pid) == sessionID {
```

and so does the second:

```swift
if let members = sessionMembers(sessionID: sessionID) {
    for pid in members where getsid(pid) == sessionID {
        _ = kill(pid, SIGKILL)
    }
```

**Ideal fix.** Return a small `SessionCensus { let sessionID: pid_t; let members: [pid_t] }`
that only `sessionMembers` can mint. Both loops become plain `for pid in census.members`, the
`sessionID:` parameter on `applySessionCensus` disappears, and the rule lives in one place.
Note this pairs with PTY-2: once the census is a value that names its session, hanging the
"already signalled at this stage" set off it is natural.

**By construction.** "A pid list whose session is not stated" stops being passed around, and
the double `getsid` per member per poll goes with it.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** Behavioral coverage already exists: the teardown-ladder tests in
`TerminalPTYHostTests` assert that every session member is signalled at each stage and that
the host reaches quiescence. This is a pure refactor and must keep them green.

**Risk.** None beyond an ordinary refactor. The `getsid` re-check is a TOCTOU either way, so
removing it changes no real guarantee.

**Vetted.** I opened `sessionMembers` (2404-2420), `applySessionCensus` (2384-2402), and
`killOwnedSession` (1061-1077). All three quotes are exact, the producer does filter, and both
consumers do re-filter with the session handed back in. Pure duplication; the refactor is
right and the existing ladder tests cover it.

**Correction.** The mint should carry one more fact than the finding asks for, because
`sessionMembers` currently reads its own syscall in the wrong unit. `proc_listallpids` returns
a *byte* count, not a pid count -- `references/xnu/bsd/kern/proc_info.c:478-480` sets
`*retval = n * sizeof(int)`, and the null-buffer probe at 380-382 likewise returns
`(nprocs + 20) * sizeof(int)`; iTerm2 divides by `sizeof(int)` at
`references/iterm2/sources/iTermLSOF.m:221`. `sessionMembers` treats that byte count as an
element count in both places it uses it: `pids.prefix(Int(count))` takes about 4x too many
elements, and `count < capacity` compares bytes against elements. It is accidentally safe today
-- the buffer is zero-filled so the padding fails `pid > 0`, and the 4x skew makes
`count < capacity` always true, which is also why the capacity-doubling retry can never run.
Fix it inside `SessionCensus`'s mint (`members = pids.prefix(Int(count) / MemoryLayout<pid_t>.size)`)
so the unit is stated once, in the one place that reads the syscall.

**Conflicts with.** PTY-2 (its per-stage set hangs off this value and it rewrites
`applySessionCensus`'s parameter list; land this first), PTY-8 (it changes what
`killOwnedSession` does with this return, and my correction changes when that return is nil),
and PTY-9 (both edit `signalSession`).

<a id="pty-7"></a>

#### PTY-7. Read the tty mode once per write turn instead of once per write syscall

`cost` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#flushInput`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#prepareCurrentInputRecordForWrite`,
`lib/TerminalPTY/Sources/TerminalPTYHost/CanonicalInputDeliveryGate.swift#isOversized`

**Problem.** `flushInput` calls `prepareCurrentInputRecordForWrite` at the top of every loop
iteration, and that function opens with an unconditional `tcgetattr`. So the write path costs
two syscalls per write instead of one, and every iteration after the first re-reads a tty
mode that cannot have changed without the child running, which it cannot do while the owner
queue is inside this loop. When the tty *is* canonical, the same iteration also re-runs
`CanonicalInputDeliveryGate.isOversized` over the whole remaining tail of the head record, so
a large paste into a canonical-mode tty scans O(n) bytes per 64 KiB written.

**Evidence.**

```swift
while let record = pendingInputRecords.first, writtenThisTurn < turnLimit {
    guard prepareCurrentInputRecordForWrite() else { return }
    let result = record.bytes.withUnsafeBytes { ... Darwin.write(masterFD, ...) }
```

```swift
private func prepareCurrentInputRecordForWrite() -> Bool {
    guard let record = pendingInputRecords.first else { return true }
    var attributes = termios()
    guard tcgetattr(masterFD, &attributes) == 0 else { ... }
    guard attributes.c_lflag & tcflag_t(ICANON) != 0 else {
        cancelCanonicalInputHold()
        return true
    }
    let isOversized = CanonicalInputDeliveryGate.isOversized(
        record.bytes[pendingInputHeadOffset...],
        inputFlags: attributes.c_iflag
    )
```

Contrast the read side, where the turn constant and its cost are argued explicitly in
`readReady`'s comment; the write side's `let turnLimit = 64 * 1024` is an unexplained local.

**Ideal fix.** Read `termios` once at the top of `flushInput` and pass it down, so the tty
mode is a turn fact like the read turn's byte cap is. The canonical scan then keys off the
head record's own remaining length, which only shrinks, so it can start from
`pendingInputHeadOffset` rather than rescanning from it -- the gate's answer for a suffix
never becomes "oversized" once its prefix was not.

**By construction.** "Two iterations of one write turn disagreeing about the tty mode" stops
being representable. `n/a` for the scan half, which is a cost fix rather than a structural
one.

**Cheaper fallback.** Hoist only the `tcgetattr` and leave the scan as it is. That halves the
syscalls and leaves the quadratic canonical scan, which is the half that scales.

**Verification.** This is a cost finding, so the experiment, not a result: run the existing
`just test-ui`-independent host suite with `dtrace`/`ktrace` counting `tcgetattr` calls
while sending one 4 MB paste through `sendPaste` into a raw-mode child, and require the
count to drop from "one per write syscall" (roughly 64, at the 64 KiB turn limit and typical
kernel buffer sizes, times the number of turns) to one per turn. For the scan half, time
`sendPaste` of 4 MB of 80-column lines into a `cat` in canonical mode and require wall time
to fall; the metric that must move is total time from submission to the `.delivered`
completion.

**Risk.** Hoisting the mode read means a child that flips ICANON mid-turn is not noticed
until the next turn. The window is one turn of the owner queue and the child cannot run
inside it, so the exposure is a child that flipped the mode *before* the turn started and
whose `tcsetattr` landed between two of this loop's iterations -- which the current code
would also handle only by accident of timing.

**Vetted.** I opened `flushInput` (1877-1912), `prepareCurrentInputRecordForWrite` (1915-1948),
`CanonicalInputDeliveryGate.isOversized`, and `readReady`'s comment (2085-2114). Every quote is
exact, and the contrast with the read side holds: `readTurnLimit` has a measured argument,
`turnLimit` is an unexplained local.

**Correction.** Lead with the scan, not the syscall. `tcgetattr` is one cheap ioctl per
iteration on a path that already does a `write` syscall per iteration, so hoisting it buys
almost nothing measurable -- that half is tidiness. The scan is the finding. `isOversized`
early-returns only when a run reaches 1024, so for a paste of ordinary short lines it walks the
*entire* remaining tail every iteration, and each iteration writes at most about one clist
buffer into a canonical input queue capped at `TTYHOG` (the same 1024 the `readReady` comment
cites for the read direction). A multi-megabyte paste into a canonical-mode reader therefore
costs thousands of iterations and quadratic byte scanning, all on the owner queue that the
render fence and every actor call wait behind. The auditor's suffix argument is sound -- no run
in a suffix can exceed the run it was cut from, so a record that scanned "not oversized" once
never becomes oversized -- which means the answer can simply be cached per record per
`c_iflag` and never recomputed while that record is the head.

**Conflicts with.** Nothing. No other finding in this lane or another touches `flushInput` or
the canonical gate.

<a id="pty-8"></a>

#### PTY-8. Give forced quiescence's kill loop a way to stop, or stop claiming it enumerated the session

`correctness` &middot; impact 2, confidence 3 &middot; effort medium &middot; rewritten

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#killOwnedSession`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#sessionMembers`,
`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneTerminationHandle.swift#requestShutdownAndWait`

**Problem.** `exitBoundElapsed` exists to put a ceiling on teardown, and the first thing it
does after the ceiling elapses is enter an unbounded loop. `killOwnedSession` spins
`while true` on the owner queue, sleeping 1ms between attempts, and exits only when
`sessionMembers` returns non-nil. `sessionMembers` returns nil whenever `proc_listallpids`
returns a negative count -- which it can do for reasons the host cannot fix by retrying.
`TerminalPaneTerminationRegistry.requestShutdownAndWait` then blocks the app's exit on a
`DispatchGroup.wait()` with no timeout, so the process cannot quit. The loop's stated
guarantee is also not the one it delivers: even on a successful census, a member forked after
the enumeration is neither seen nor signalled, so "every process group in the session has
actually been enumerable and signalled" is true of a moment, not of the session.

**Evidence.**

```swift
private func killOwnedSession() {
    guard let sessionID else { return }
    while true {
        if let members = sessionMembers(sessionID: sessionID) { ... return }
        // Keep making progress against the portion addressable without a
        // census, but do not report quiescence until every process group in
        // the session has actually been enumerable and signalled.
        _ = kill(-sessionID, SIGKILL)
        if let leaderPID { _ = kill(leaderPID, SIGKILL) }
        usleep(Self.forcedCensusRetryInterval)
    }
}
```

`sessionMembers` gives up after three tries and returns the nil this loop treats as
"retry forever":

```swift
guard count >= 0 else { return nil }
...
return nil
```

and the app-exit waiter has no bound of its own:

```swift
for handle in snapshot {
    completions.enter()
    handle.requestShutdown { completions.leave() }
}
completions.wait()
```

**Ideal fix.** Separate the two things the loop is conflating. Retrying a census that failed
for a transient reason is worth doing and should be bounded -- give the retry a deadline
derived from the same clock the exit bound uses. Retrying because the census is
*unavailable* is not progress at all, and the honest answer there is the one the loop already
falls back to: `kill(-sessionID, SIGKILL)` reaches the leader's process group, which is the
part of the session this process actually owns, and `reapLeaderAfterKill` proves the leader
is collected. Report quiescence on that, and record the unenumerated case in
`TerminalPTYLifecycleCensus` beside `forcedQuiescenceCount` so it is visible rather than
silent.

**By construction.** "Forced quiescence blocked forever inside the path that exists to force
quiescence" stops being representable. The census stops being load-bearing for termination
and becomes what it actually is -- a best-effort widening of the kill.

**Cheaper fallback.** Put a deadline on the loop and fall through to the group kill when it
elapses. That removes the hang and keeps the census as the preferred path, but leaves the
comment's guarantee overstated, since a post-census fork is still missed.

**Verification.** `TerminalPTYHostTests` with an injected census witness that always fails:
call `forceExitBoundForTesting()` and assert `whenQuiescent` fires and
`resourceSnapshot().isReleased` is true. Today the test never returns. Pair it with a case
where the census fails twice and then succeeds, asserting every member is killed.

**Risk.** Reporting quiescence without a complete census means a stopped background job in a
process group of its own could survive the host. That is a real regression in the failure
case and is why the finding says to surface it in the census rather than hide it -- but it
trades a leaked process for an unkillable app, which is the right direction.

**Vetted.** I opened `killOwnedSession` (1061-1077), `sessionMembers` (2404-2420),
`exitBoundElapsed` (1026-1037), `performForcedCleanupAfterMasterClose` (1041-1053), and
`TerminalPaneTerminationRegistry.requestShutdownAndWait` (53-65). All three quotes are exact:
the loop is `while true`, it exits only on a non-nil census, and the app-exit waiter has no
timeout.

**Correction.** The hang is a hypothetical, not a live defect, so score it as one. It needs
`sessionMembers` to return nil forever, and I followed that to xnu: under `PROC_ALL_PIDS`,
`proc_listpids` can only fail through `proc_security_policy` -- which returns 0 immediately for
the null target `LISTPIDS` passes, short of a MACF/sandbox denial
(`references/xnu/bsd/kern/proc_info.c:3192-3207`) -- or `ENOMEM` from `kalloc_data`. `ENOMEM` is
transient and the retry loop is exactly the right response to it. The capacity path cannot
produce nil either, for the unit reason recorded under PTY-6. So an unsandboxed DanTerm does
not reach the unbounded case, and the finding's own headline claim about
`requestShutdownAndWait` follows it down. What survives verbatim is the second half: even a
successful census misses a process forked after the enumeration, so the comment's "every
process group in the session has actually been enumerable and signalled" is true of a moment
and not of the session. Read this as "bound the retry and stop overstating the guarantee",
which is the auditor's own cheaper fallback plus a comment fix, at effort small.

**Conflicts with.** PTY-6, which changes the type this loop consumes and (with my correction)
when it is nil.

<a id="pty-9"></a>

#### PTY-9. Enqueue `.sessionDrained` through `process`, not by writing the reducer's queue directly

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#signalSession`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#process`,
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#sessionPollFired`

**Problem.** There are two spellings for handing an event to the reducer.
`sessionPollFired` uses `process(.sessionDrained)`. `signalSession` writes
`pendingEvents.append(.sessionDrained)` directly, in two places. The two are equivalent only
because `signalSession` is always called from inside a reduction, where `process` would
append and return anyway. Nothing in the type system or the function's signature says so,
and a later caller that reaches `signalSession` from a source callback would append an event
that no reduction ever drains -- the ladder would simply stop, with no crash and no log.

**Evidence.**

```swift
private func signalSession(_ stage: TeardownStage) {
    guard let sessionID else {
        pendingEvents.append(.sessionDrained)
        return
    }
    ...
    if applySessionCensus(members, sessionID: sessionID) {
        pendingEvents.append(.sessionDrained)
    }
}
```

against the other producer of the same event:

```swift
private func sessionPollFired() {
    ...
    if applySessionCensus(members, sessionID: sessionID) {
        process(.sessionDrained)
    }
}
```

and `process`, which already does the right thing in both contexts:

```swift
private func process(_ event: PaneProcessLifecycleEvent) {
    pendingEvents.append(event)
    guard isReducing == false else { return }
    isReducing = true
```

**Ideal fix.** Call `process(.sessionDrained)` in both arms of `signalSession` and make
`pendingEvents` private to `process`. One entry point, correct from anywhere.

**By construction.** "An event queued where no reduction will drain it" stops being
reachable, and the reader stops having to prove `signalSession`'s call context to know the
ladder advances.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** The existing teardown-ladder tests in `TerminalPTYHostTests` cover the
behavior (a session that is already empty at `.hangup` must reach quiescence without waiting
for a poll). This is a pure refactor and must keep them green.

**Risk.** None. Inside a reduction the two spellings are identical; outside one, the new
spelling is the only correct behavior.

**Vetted.** I opened `signalSession` (2368-2382), `sessionPollFired` (2460-2466), and `process`
(1440-1454). All three quotes are exact, and the duplicate spelling is real. I also checked the
call context the finding rests on: `signalSession` has exactly one caller,
`execute(.signalSession)`, which always runs inside `process`'s drain loop, so today's code is
correct and this is purely about removing a property the signature cannot state. One half of
the ideal fix is not expressible -- Swift has no way to scope a stored property to one function
-- so "make `pendingEvents` private to `process`" reduces to leaving `process` as the only
writer and saying so.

**Conflicts with.** PTY-2 and PTY-6, which both rewrite `signalSession`'s body.

#### Dropped (PTY)

- **Flight recorder's per-event `[UInt8]` payload and the per-turn `Array(...)` copy in
  `takeOutputTurn`.** This is exactly `XPORT-2`, which the construction audit marked
  `skip` on measurement: "two idle post-XPORT-1 traces put the whole recorder at 0.211%
  inclusive CPU; residual allocation churn is only a subset and does not justify the
  high-risk rewrite". Nothing I read changes that number.
- **`TerminalPTYUpdateSignal.accumulate` rebuilding `newer.semanticEvents` on every merge.**
  I expected the documented quadratic to still be live, but it is not: `newer` is always a
  single host turn's signal, so the map-append-sort it triggers is over that turn's events
  only. The in-place merge does what its comment claims.
- **`TerminalFlightRecordingEvent.init`'s paired preconditions ("a recorded write must
  state who chose its bytes" / "only a write has a chooser to name") and
  `record(_:)`'s `preconditionFailure`.** Real guards over a representable-invalid state,
  but every fix I could construct either mirrors `NeutralTerminalRecordingEvent`'s
  vocabulary into a second enum or pushes `writeAttribution` into the replay event, which
  the file's own comment rules out ("it never enters `NeutralTerminalRecordingEvent`, so no
  replay and no pane-tape record can depend on it"). No fix here is better than the guards.
- **`writeAttribution(of:)`'s `?? .pane` for an unknown submission id.** It looks like a
  default hiding a lost identity, but the only producer of a nil id is the reducer's launch
  input, which really is pane-chosen. The two cases agree, so there is nothing to separate.
- **`drainCommittedOutput`'s `FIONREAD` bound as a second end-of-output mechanism beside the
  read loop's own `EAGAIN`.** It reads as redundant vocabulary, but it is the only thing
  bounding a drain against a slave descriptor another session member still holds open. It
  earns its place.
- **`prepareCurrentInputRecordForWrite`'s recursive `flushInput()` after rejecting a
  canonical-timeout head.** I traced the interleaving looking for a leaked write source or a
  lost `writtenThisTurn` budget; neither happens. `cancelWriteSource()` runs before the
  rejection on every path, and the nested call re-runs the tail bookkeeping.
- **`ResizeCoalescer`'s sealed-run retirement.** I checked the out-of-order query path the
  comment describes; the failure mode really is "one extra reflow", never a skipped one.
- **`InFlightLaunch`'s unbounded `workerFinished.wait()`.** Deliberate and argued in the
  file: `posix_spawn` is uninterruptible, so a bound would let quiescence be reported over a
  child still arriving. I agree with the trade.
- **`PaneProcessLifecycleReducer` never reporting an exit after `.requestClose`.** The
  teardown context's `result` stays nil on that path, so a child that exits during a
  user-requested close is not reported. Reading the states, this is intentional: a closed
  pane has no consumer for the result.


### Area: Benchmark and probe harness (`PROBE`)

_Scope: `lib/TerminalHostTools/Sources/` (TerminalMemoryProbe, GlyphPreview) and the
benchmark/probe targets under `lib/TerminalCore/Sources/`: `TerminalCoreBenchmark`,
`TerminalCoreBenchmarkSupport`, `TerminalBrowseBenchmark(+Support)`,
`TerminalDrawBenchmark(+Support)`, `TerminalOccupancyProbe(+Support)`,
`TerminalResizeProbe(+Support)`, `TerminalRetainedRowProbe(+Support)`,
`TerminalMemoryProbeSupport`, `TerminalBenchmarkCoverage`, `TerminalBenchmarkMarkers`,
`TerminalBenchmarkTopology`, `TerminalCoreRecording`. Read against
`agent-docs/measurement-discipline.md` and `agent-docs/terminal-performance.md`, with
`scripts/terminal-benchmark-validation.py` and `app/TerminalBenchmark.swift` consulted
where they are the other half of a contract._

**The auditor's read on the area.** The *collected* side is in very good shape. Every
report type carries its own denominators, `ResizeProbeDistribution` refuses to turn an
empty sample list into zeros, `TerminalBenchmarkPresentationCoverageRecorder` counts
rather than latches, and `TerminalBenchmarkDamageTopologyRecorder.contracts` is
cross-checked field for field by `scripts/terminal-benchmark-validation.py` so a drift
between the two invalidates the block instead of passing. The remaining defects all sit
one layer out, at the *input* boundary: three CLIs accept a parameter that makes their
own measurement meaningless and then print a well-formed report anyway, and one recipe is
rebuilt field-by-field where the compiler cannot catch an omission. There is one
measured-bracket defect (`PROBE-1`) on the ladder's tightest-threshold workload. I did
not audit `scripts/*.py` (another lane's collector), the app-side observer beyond the two
call sites that consume `TerminalBenchmarkMarkers`, or `GlyphPreview` in depth -- it is a
debug viewer that reports no number, so nothing it does can be a misleading measurement.

<a id="probe-1"></a>

#### PROBE-1. Hoist the browse benchmark's plan checksum out of its timed loop

`cost` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalBrowseBenchmarkSupport/TerminalBrowseBenchmarkSupport.swift#measureBrowsingPlan`, `lib/TerminalCore/Sources/TerminalBrowseBenchmarkSupport/TerminalBrowseBenchmarkSupport.swift#planCellCoverage`

**Problem.** `retained-browse` decides on `planNanosecondsPerFrame`, and its timed region
contains the instrument as well as the thing being measured. Every measured iteration
runs `planCellCoverage`, which walks the whole plan a second time to sum covered cells.
The value it produces carries no information the loop could not get once: the plan is
deterministic across iterations, so the checksum is exactly `measuredCount x perFrame`,
and the suite already asserts that. So the workload with the ladder's tightest threshold
(1.05%, against 1.50-2.15% for the draw cells) charges an instrument term to the
quantity it decides on. Two consequences: the term dilutes any real planner effect, and
because the walk iterates *runs* rather than cells, a representation change that alters
run counts moves the instrument's own cost and gets attributed to planning.

**Evidence.** The measured loop:

```swift
let started = now()
for _ in 0..<measuredCount {
    checksum &+= planCellCoverage(planFrame(for: terminal, presentation: presentation))
}
let elapsed = now() &- started
```

`planCellCoverage` is a second full traversal, and each `for run in row.textRuns` element
copy retains the run's `cells` array:

```swift
for row in plan.rows {
    for run in row.textRuns { total &+= UInt64(run.cells.count) }
    for run in row.backgroundRuns { total &+= UInt64(run.columnCount) }
}
```

The checksum's redundancy is already pinned by the suite --
`lib/TerminalCore/Tests/TerminalBrowseBenchmarkSupportTests/TerminalBrowseBenchmarkSupportTests.swift:77`:

```swift
#expect(measured.planCellChecksum == perFrame &* 3)
```

`agent-docs/measurement-discipline.md` names the general form ("It includes the
instrument, which on `incremental-mixed` is a large term"), and
`agent-docs/terminal-performance.md` records that `retained-browse`'s run-to-run scatter
is 0.06-0.28 points -- a margin small enough for a per-frame instrument term to matter.

**Ideal fix.** Compute the checksum once, outside the bracket, from a single plan, and
state it as `perFrameCoverage &* UInt64(measuredCount)`. The measured loop then holds one
`planFrame` call and a minimal consume (`checksum &+= UInt64(plan.rowCount)` or
`withExtendedLifetime`) that cannot scale with the plan's run structure. The checksum
obligation -- both arms planned the same cells -- is kept exactly, because the per-frame
coverage is what proves it and the multiplication is arithmetic.

**By construction.** The measured quantity stops being able to contain a traversal whose
size depends on the representation under test. `planCellChecksum` becomes a function of
one plan and a count rather than an accumulator whose cost lands in the timer.

**Cheaper fallback.** Keep the loop and subtract nothing -- accept that both arms pay the
same term. That is the status quo and it fails to remove the representation sensitivity:
a change that halves the run count makes the instrument cheaper on one arm only.

**Verification.** `swift test --package-path lib/TerminalCore --filter
TerminalBrowseBenchmarkSupportTests` must still pass line 77's checksum identity
unchanged -- that is the structure-insensitive assertion, since it states the *value*, not
where it is computed. For the cost claim: build
`swift build -c release --package-path lib/TerminalCore --product TerminalBrowseBenchmark`
at HEAD and with the hoist applied, run each `--measured 2000` five times on an idle
machine, and compare `planNanosecondsPerFrame`. The number that must move is
`planNanosecondsPerFrame`, downward, by more than the ~0.3-point run-to-run scatter
`agent-docs/terminal-performance.md` records for this cell. If it does not move by more
than that, the change stands as a simplification and the dilution claim is withdrawn.

**Risk.** None to correctness: no arm's plan changes, and the emitted checksum value is
identical. A comparison whose baseline predates the hoist and whose candidate follows it
would read the hoist's own saving as a planner win -- so the first paired run after this
lands must have both arms on the same side of it, which the harness's immutable-tree
capture already guarantees for any baseline chosen after the commit.

**Vetted.** I opened `measureBrowsingPlan` and `planCellCoverage` in
`lib/TerminalCore/Sources/TerminalBrowseBenchmarkSupport/TerminalBrowseBenchmarkSupport.swift`
and found both quoted blocks verbatim, and the checksum identity at
`lib/TerminalCore/Tests/TerminalBrowseBenchmarkSupportTests/TerminalBrowseBenchmarkSupportTests.swift:77`
exactly as quoted. The 1.05% threshold is real
(`scripts/terminal-benchmark-validation.py:200` and `:274`) and so is the 0.06-0.28-point
scatter (`agent-docs/terminal-performance.md:382-386`). One citation is misattributed: "It
includes the instrument, which on `incremental-mixed` is a large term" is
`agent-docs/terminal-performance.md:309`, not `measurement-discipline.md`, and in context it
is about the uncalibrated auxiliary CPU metric rather than a deciding one.

**Correction.** The size of the term does not support the claim. The stimulus is plain ASCII
-- about 44 printable columns on each of 66 viewport rows -- and `RenderPlanRow` emits text
runs per style span with background runs only for *non-default* backgrounds, so one plan
carries roughly 66 text runs and no background runs. `planCellCoverage` is therefore about
130 loop steps and a few hundred refcount operations per frame, against the ~350,000 ns per
frame this workload records (`docs/research/28-retained-row-optimizations/findings.md:1797`)
-- an instrument on the order of 0.1-0.5%, not one that can dilute a paired estimate. It is
also the *same* term on both arms by the workload's own construction: the checksum
obligation is that both arms cover the same cells, so moving the instrument's cost requires
a planner change that alters run boundaries without altering coverage, which shifts it by a
fraction of the 0.3-point scatter. The dilution and representation-sensitivity claims do not
survive. What survives is the plain rule that the instrument does not belong inside the
bracket, and a simplification worth taking on that ground alone -- so the finding is a
`simplification` in substance and is rescored to impact 2. One thing to keep when hoisting:
`planFrame` is a public, non-`@inlinable` function in a separate module
(`TerminalRenderPlanning`), so the call itself cannot be eliminated, but the minimal consume
must still exist so the returned plan's release traffic stays inside the bracket.

**Conflicts with.** Nothing in this lane. `DRAW-1` deletes the `row` field from the four run
types that `planCellCoverage` walks, and `DRAW-7` proposes adding a "search-dense" workload
to this same directory; both are separate functions in separate files and can land
independently of this hoist.

<a id="probe-2"></a>

#### PROBE-2. Make the probe CLIs reject a flag value instead of falling back to the default

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalHostTools/Sources/TerminalMemoryProbe/main.swift#flagValue`, `lib/TerminalCore/Sources/TerminalOccupancyProbe/main.swift#flagValue`

**Problem.** Both probe CLIs parse numeric flags through a helper that cannot fail. A
value the helper cannot parse, or a flag written with the value missing, silently yields
the default. So `just terminal-memory-probe "--columns 80 --rows 24"` and
`just terminal-memory-probe "--columns eighty --rows 24"` both print a header that says
`179x66` for the first and `179x24` for the second, and nothing in either output says a
flag was discarded. The occupancy probe has the same helper for `--columns`, `--rows`,
`--lines` and `--iterations`. The failure is silent and always in the direction of "the
run looked fine", which is the exact shape `agent-docs/measurement-discipline.md` opens
with.

**Evidence.** The helper, duplicated verbatim in both executables:

```swift
func flagValue(_ name: String, default fallback: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count,
          let value = Int(CommandLine.arguments[index + 1])
    else { return fallback }
    return value
}
```

There are three failure conditions collapsed into one `else` that returns the default:
flag absent (legitimate), flag present with no value (a usage error), and flag present
with an unparsable value (a usage error). It also imposes no range: `--lines -5` reaches
`makeOccupancyTerminal` unchecked. Contrast the same repo's `TerminalResizeProbe`, which
does this correctly -- `guard arguments.count >= 2, let value = Int(arguments[1]), value
>= 1 else { ...; exit(2) }` -- and `TerminalRetainedRowProbe`, which does the same.

**Ideal fix.** Delete the helper and use the positional walk the resize and retained-row
probes already use: consume `arguments` two at a time, switch on the flag name, and
`exit(2)` with usage on an unknown flag, a missing value, an unparsable value, or a value
outside the range the probe accepts. That is four executables all parsing flags the same
way, and it removes the fallback branch entirely rather than rewording it.

**By construction.** "Flag was given but ignored" stops being representable: after the
parse loop, every flag in `CommandLine.arguments` has either been consumed into a
validated value or ended the process.

**Cheaper fallback.** Make `flagValue` return `Int?` and have each call site
`exit(2)` on `nil`. Smaller, but it leaves the range check ("`--iterations` must be at
least 1") at each call site rather than in one parse, which is what `PROBE-4` is about.

**Verification.** No unit suite covers either `main.swift` (both are executables). The
behavioral check is a shell assertion in the style of
`scripts/tests/terminal-benchmark-harness_test.sh`: run each probe binary with
`--columns eighty`, `--rows` (no value) and `--lines -1` and assert exit code 2 and a
usage line on stderr; run it with `--columns 80 --rows 24` and assert the header names
`80x24`. Structure-insensitive: it states only what the process does with an argv.

**Risk.** A caller currently relying on a typo being ignored starts failing. That is the
intent. No measured number changes for a correct invocation.

**Vetted.** I opened both `main.swift` files. `flagValue` is present verbatim and byte-identical
in `lib/TerminalHostTools/Sources/TerminalMemoryProbe/main.swift:12-18` and
`lib/TerminalCore/Sources/TerminalOccupancyProbe/main.swift:17-23`, feeding `--columns`,
`--rows`, `--lines`, `--chunk` in the first and `--columns`, `--rows`, `--lines`,
`--iterations` in the second. The contrast the finding draws is real: `TerminalResizeProbe`
and `TerminalRetainedRowProbe` both walk `arguments` two at a time and `exit(2)` on a bad
flag, value, or range.

**Correction.** The headline example is wrong. `just` does not quote `{{flags}}` -- the recipe
line goes to `sh` and word-splits -- so `just terminal-memory-probe "--columns 80 --rows 24"`
delivers four argv words and prints `80x24`, not `179x66`. I confirmed this by running a
throwaway recipe with the same interpolation. `justfile:110` and `justfile:131` ship that exact
invocation as documentation, which is the second reason it works. The failure that is real is
the other two the helper collapses into the legitimate one: an unparsable value
(`--columns eighty` yields 179) and a flag written with its value missing (a trailing `--rows`
yields 66). Both print a header naming the default and say nothing about the discarded flag.
The range half is weaker than stated too. On the occupancy probe `--columns 1` reaches
`makeOccupancyTerminal`, whose body is
`preconditionFailure("occupancy probe requires a representable geometry")`, and `--lines -5`
traps forming `0..<(-5)`. Those are loud, not silent -- the range check is worth adding for
the message it prints, not because a wrong number escapes. Rescored to impact 2: two
hand-run tools with one recipe each, and what survives is a swallowed typo.

**Conflicts with.** `PROBE-3` (same file, `TerminalMemoryProbe/main.swift`: it adds a geometry
rejection to the parse this finding rewrites) and `PROBE-4` (same file,
`TerminalOccupancyProbe/main.swift`; `PROBE-4`'s ideal fix names this parse as where
`iterations >= 1` is validated). Land this one first and fold the other two onto it.

<a id="probe-3"></a>

#### PROBE-3. Fail the memory probe when a payload could not be measured, instead of printing an empty report

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalMemoryProbeSupport/TerminalMemoryProbeSupport.swift#runMatrix`, `lib/TerminalCore/Sources/TerminalMemoryProbeSupport/TerminalMemoryProbeSupport.swift#measure`

**Problem.** `measure` returns `nil` when the geometry is one no `Terminal` accepts, and
`runMatrix` drops that nil with `compactMap`. A geometry the engine rejects therefore
produces a syntactically valid report with zero payloads, a `cellStrideBytes` of `0` from
a `?? 0`, and exit status 0. `just terminal-memory-probe "--columns 1"` prints
`terminal memory probe -- 1x66, budget 15.00 MB, stride 0 B, feed chunk 4096` followed by
four correctly formatted tables containing no rows. Nothing says the probe measured
nothing. This is the "a missing field is not a zero" rule inverted: a missing *measurement*
renders as a zero-row table.

**Evidence.** `Terminal`'s failable initializer
(`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:1805`) rejects the geometry:

```swift
guard columns >= 2, rows >= 1, scrollbackBudgetBytes >= Self.minimumScrollbackBudgetBytes
else {
    return nil
}
```

`measure` propagates that as nil -- `guard var terminal = Terminal(columns: columns, rows:
rows) else { return nil }` -- and `runMatrix` swallows it:

```swift
let reports = MemoryProbeMatrix
    .payloads(columns: columns, lineCount: lineCount, named: only)
    .compactMap { measure(payload: $0, ...) }
return MemoryProbeReport(
    schemaVersion: 2,
    ...
    cellStrideBytes: reports.first?.census.cellStrideBytes ?? 0,
    payloads: reports
)
```

The CLI validates the *payload name* carefully (it builds the known-name list and exits 2
on a mismatch) and then does not check that any payload was actually measured. The
neighbouring probe gets this right: `TerminalRetainedRowProbe/main.swift` guards the same
kind of nil and calls `fail("retained-row probe rejected geometry \(columns)x\(rows)\n",
code: 1)`.

**Ideal fix.** Validate the geometry once, before any payload is built, and construct the
terminal from a value that cannot be invalid. Concretely: `runMatrix` takes a geometry it
has already accepted (or returns `MemoryProbeReport?` / throws), so `measure` has no nil
return path and `compactMap` becomes `map`. `cellStrideBytes` then comes from a measured
payload rather than a `?? 0`, and the CLI exits 2 on the rejected geometry the way it
already does on an unknown payload name.

**By construction.** A report with zero payloads stops being constructible, and the
`?? 0` on `cellStrideBytes` -- the field most likely to be read as "the cell got smaller"
-- is deleted rather than reworded.

**Cheaper fallback.** Add `guard report.payloads.isEmpty == false else { exit 1 }` in the
CLI. It removes the silent exit-0 but leaves `runMatrix` able to return a report that
claims a stride of zero, and leaves the failure discovered after the payload bytes were
built rather than before.

**Verification.** `lib/TerminalCore/Tests/TerminalMemoryProbeSupportTests`: assert that
`runMatrix(columns: 1, rows: 66)` does not return a report whose `payloads` is empty and
whose `cellStrideBytes` is 0 -- with the ideal fix it returns nil or throws, which the
test states directly. Plus the shell assertion from `PROBE-2`: the binary exits nonzero
for `--columns 1`.

**Risk.** A caller that today gets an empty report and treats it as "no payloads
requested" would start seeing a nonzero exit. No such caller exists -- `justfile:111` is
the only invocation.

**Vetted.** Every quote checks out. `Terminal`'s failable initializer carries the exact guard
at `lib/TerminalCore/Sources/TerminalCore/Terminal.swift:1805`; `measure` propagates the nil
with `guard var terminal = Terminal(columns: columns, rows: rows) else { return nil }`;
`runMatrix` swallows it with `compactMap` and fills `cellStrideBytes` from
`reports.first?.census.cellStrideBytes ?? 0`. `TerminalRetainedRowProbe/main.swift` really
does `fail("retained-row probe rejected geometry \(columns)x\(rows)\n", code: 1)` for the
same shape, and `justfile:111` is the only invocation. The path is reachable: `--columns 1`
or `--rows 0` gives a header reading `1x66, budget 15.00 MB, stride 0 B` and exit 0.

**Correction.** The run is less quiet than the prose implies, and that changes where the fix
earns its keep. All four tables lose every row and the two closing notes still print, so a
human at the terminal sees an obviously empty run and will not read a number off it. What
nobody sees is the `--json` artifact: `"payloads": []` beside `"cellStrideBytes": 0` under
`"schemaVersion": 2` is a well-formed schema-2 report that a later reader can diff against a
real one, and *that* is the thing worth refusing to construct. Rescored to impact 2 on
reachability -- a hand-typed geometry on a single-call-site tool -- not on the shape of the
fix, which is right as written.

**Conflicts with.** `PROBE-2`: both rewrite the argument handling in
`lib/TerminalHostTools/Sources/TerminalMemoryProbe/main.swift`, and this finding's CLI-side
`exit 2` belongs in the parse loop `PROBE-2` introduces.

<a id="probe-4"></a>

#### PROBE-4. Reject an occupancy run with no iterations, and delete the statistics' `?? 0`

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalOccupancyProbeSupport/OccupancyReport.swift#OccupancySample`, `lib/TerminalCore/Sources/TerminalOccupancyProbe/main.swift`

**Problem.** `OccupancySample` turns an empty sample list into a full set of zero
statistics, and the probe's default table then reports those zeros as a measurement. With
`--iterations 0` every case prints `0.00 / 0.00 / 0.00`, and the footer -- which is the
one line a reader is meant to act on -- prints "Held Enter sustains **faster than this
probe can time**". That sentence is generated by the very `nil` that is supposed to mean
"too fast to time": a zero mean is below `rateResolutionMilliseconds`, so an unmeasured
run and a cache-hit run produce the same words. The doc comment on
`operationsPerSecond` explicitly reasons about the cache-hit case and does not consider
the no-samples case, which reaches the same branch.

**Evidence.** The three `?? 0` / `isEmpty ? 0` fallbacks:

```swift
public var iterations: Int { milliseconds.count }
public var meanMilliseconds: Double {
    milliseconds.isEmpty ? 0 : milliseconds.reduce(0, +) / Double(milliseconds.count)
}
public var minMilliseconds: Double { milliseconds.min() ?? 0 }
public var maxMilliseconds: Double { milliseconds.max() ?? 0 }
```

feeding:

```swift
public var operationsPerSecond: Double? {
    let mean = meanMilliseconds
    return mean >= Self.rateResolutionMilliseconds ? 1000 / mean : nil
}
```

and the CLI turning that nil into prose:

```swift
let rate = quiet.operationsPerSecond
    .map { String(format: "%.1f presses/second", $0) }
    ?? "faster than this probe can time"
```

`--iterations` reaches this unchecked through `flagValue` (`PROBE-2`). The default table
prints no iteration count, so nothing in the human-readable output distinguishes the two
cases; only `--json` carries `"iterations": 0`. Note that the sibling probe already
solved exactly this class of problem in code --
`TerminalResizeProbe/main.swift` rejects a degenerate `--alternate-columns` with a usage
error precisely because it "would time `sampleCount` no-op resizes and print a full
distribution of near-zero nanoseconds with nothing marking it unmeasured."

**Ideal fix.** Validate `iterations >= 1` and `lines >= 1` in the parse (see `PROBE-2`),
and make `OccupancySample` hold at least one sample by construction -- take
`(first: Double, rest: [Double])`, or a failable init. `meanMilliseconds`,
`minMilliseconds` and `maxMilliseconds` then return a real `Double` with no fallback, and
`operationsPerSecond`'s `nil` recovers its single documented meaning: the operation was
measured and was too fast to time.

**By construction.** A sample with no measurements stops existing, so the three
fallbacks and the ambiguity in `operationsPerSecond`'s nil are deleted rather than
documented.

**Cheaper fallback.** Add an `iters` column to the default table so a reader can see the
zero. That leaves the misleading footer sentence in place and leaves the fallbacks for the
next reader to trip over.

**Verification.** `lib/TerminalCore/Tests/TerminalOccupancyProbeSupportTests`: assert
that an `OccupancySample` cannot be built with no measurements (the failable init returns
nil, or the type does not compile with an empty list). Plus the `PROBE-2` shell
assertion that `--iterations 0` exits 2.

**Risk.** None to a valid run: every shipped invocation in `justfile:128-132` passes
`--iterations` at 10 or leaves it at the default 40.

**Vetted.** I opened
`lib/TerminalCore/Sources/TerminalOccupancyProbeSupport/OccupancyReport.swift` and found the
four fallbacks and `operationsPerSecond` verbatim, including the doc comment that reasons only
about the cache-hit case. The CLI's `?? "faster than this probe can time"` is verbatim in
`TerminalOccupancyProbe/main.swift`, and `TerminalResizeProbe/main.swift` carries the quoted
sentence about no-op resizes word for word. `runOccupancyProbe` builds all six sample lists
with `for _ in 0..<iterations` and appends each unconditionally, so `--iterations 0` really
does produce six empty lists, six rows of `0.00 / 0.00 / 0.00`, and the held-Enter footer
claiming the queue serves presses faster than the probe can time. The default table prints no
iteration count; only `--json` carries `"iterations": 0`.

**Correction.** One note on the authority cited. `agent-docs/measurement-discipline.md`'s own
prescription for this shape is "Emit a count beside every aggregate ... Assert a floor on that
count where the number drives a decision" -- which is this finding's *cheaper fallback* (an
`iters` column plus a floor), not the unrepresentable-empty-sample fix. The ideal fix is still
the better one and I keep it, but the doc does not command it and the finding should not
claim it does. Rescored to impact 2: the only way in is a hand-typed `--iterations 0` or a
negative, on a probe with one recipe, no collector, and no scheduled run.

**Conflicts with.** `PROBE-2`: this finding's ideal fix is stated as "validate `iterations >= 1`
and `lines >= 1` in the parse (see `PROBE-2`)", so the two edit the same loop in
`lib/TerminalCore/Sources/TerminalOccupancyProbe/main.swift` and cannot be implemented
independently.

<a id="probe-5"></a>

#### PROBE-5. Let the resize CLI mutate the recipe instead of rebuilding it field by field

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/TerminalCore/Sources/TerminalResizeProbe/main.swift`, `lib/TerminalCore/Sources/TerminalResizeProbeSupport/TerminalResizeProbeSupport.swift#ResizeProbeRecipe`

**Problem.** `ResizeProbeRecipe` is a frozen-data value whose whole job is that "a
changed shape is a changed identity". The CLI overrides one field of it by calling the
memberwise initializer with all nine fields restated -- twice, once per flag. Two of those
fields, `name` and `payload`, have *default values* in the initializer. So the compiler
cannot catch a field that a future edit forgets to carry: adding a tenth field with a
default, or dropping `payload:` from one of the two copies, silently resets it. Dropping
`payload:` from the `--samples` branch would make `just terminal-resize-probe "--recipe
sparse --samples 40"` feed dense program-output lines while reporting
`saturated-sparse-resize-v1` in `recipeIdentity` -- a probe whose identity claims one
content regime and whose numbers came from another. That is the one failure the identity
string exists to prevent.

**Evidence.** The two rebuilds, `lib/TerminalCore/Sources/TerminalResizeProbe/main.swift:46-61`:

```swift
case "--samples":
    recipe = ResizeProbeRecipe(
        columns: recipe.columns, rows: recipe.rows, lineCount: recipe.lineCount,
        scrollbackBudgetBytes: recipe.scrollbackBudgetBytes,
        alternateColumns: recipe.alternateColumns,
        sampleCount: value, warmupCount: recipe.warmupCount,
        name: recipe.name, payload: recipe.payload
    )
case "--alternate-columns":
    recipe = ResizeProbeRecipe(
        ... alternateColumns: value, ...
        name: recipe.name, payload: recipe.payload
    )
```

against the initializer that makes the omission legal:

```swift
public init(
    columns: Int, rows: Int, lineCount: Int, scrollbackBudgetBytes: Int,
    alternateColumns: Int, sampleCount: Int, warmupCount: Int,
    name: String = "saturated-resize-custom",
    payload: ResizeProbePayload = .dense
) {
```

And `payload` is not carried into `ResizeProbeReport` at all -- it survives only inside
`name`, via `identity`, so a reset payload would leave no trace in the artifact.

**Ideal fix.** Make `ResizeProbeRecipe`'s stored properties `var` (it is a `struct`, so
each named recipe stays an immutable `static let` and the CLI's local copy is its own
value) and have each flag branch assign one field: `recipe.sampleCount = value`. Nine
restated fields become one assignment, and adding a field to the type cannot change what
a flag does. Carry `payload` into `ResizeProbeReport` alongside the other recipe fields
so the artifact states the content regime directly rather than by name convention.

**By construction.** "A flag override that also changed a field it did not name" stops
being expressible: the CLI has exactly one write per flag, and the compiler enforces that
every other field survives untouched.

**Cheaper fallback.** Drop the default values from `init` so every construction must
restate every field. That makes an omission a compile error, but keeps the nine-field
restatement at each site and makes every *other* caller (four static recipes plus the
tests) noisier for it.

**Verification.** `lib/TerminalCore/Tests/TerminalResizeProbeSupportTests`: assert that
overriding `sampleCount` on `.sparseSaturating` leaves `payload == .sparse` and
`identity` unchanged apart from nothing -- stated as behavior over the recipe value, so it
survives any change to how the override is spelled. Add a report-level assertion that
`ResizeProbeReport` names the payload for each of the four shipped recipes.

**Risk.** `ResizeProbeRecipe`'s `Equatable`/`Sendable` conformances are unaffected by
`let` to `var`. Adding `payload` to `ResizeProbeReport` changes the JSON shape; nothing
schedules or pairs this probe's output (`main.swift` says so explicitly), so no collector
breaks.

**Vetted.** Both quotes are verbatim: the two nine-field rebuilds at
`lib/TerminalCore/Sources/TerminalResizeProbe/main.swift:46-61`, and the initializer with
defaults for `name` and `payload` at
`lib/TerminalCore/Sources/TerminalResizeProbeSupport/TerminalResizeProbeSupport.swift:191-196`.
`ResizeProbeReport` (`:270-298`) does carry neither `payload` nor `sampleCount`, and
`identity` is `"\(name)-\(lineCount)-lines-\(columns)x\(rows)-to-\(alternateColumns)"`, so the
recipe's name really is the only trace of the content regime in the artifact. Two of the four
shipped recipes (`sparseSaturating`, `wideSaturating`) pass a non-default `payload`, so a
dropped `payload:` would silently reset them to `.dense`.

**Correction.** No artifact is wrong today: both rebuild sites carry `name:` and `payload:`
correctly, so this is a compile-time hazard rather than a defect, and it is rescored to impact
2 on that basis. Two additions to the ideal fix. First, `--recipe` is resolved before the flag
loop and *replaces the whole value* (`main.swift:23-37`) precisely so a later `--samples` is
not overwritten; the `var`-and-assign rewrite must keep that ordering, and a test should state
it. Second, `sampleCount` is missing from `ResizeProbeReport` for the same reason `payload`
is, and it is the field the CLI's other flag overrides -- add both, not just `payload`.

**Conflicts with.** `REFLOW-4` names
`swift run --package-path lib/TerminalCore -c release TerminalResizeProbe --recipe wide
--samples 200` as the measurement that decides it and quotes that JSON's distribution. This
finding changes that JSON's shape. They are not mutually exclusive, but a `REFLOW-4` baseline
captured before this lands gains fields after it, so run `REFLOW-4`'s pair entirely on one
side of this change.

<a id="probe-6"></a>

#### PROBE-6. Stop the retained-row probe from silently skipping a row it cannot read

`structural` &middot; impact 1, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalRetainedRowProbeSupport/TerminalRetainedRowProbeSupport.swift#readRetainedRowShape`, `lib/TerminalCore/Sources/TerminalRetainedRowProbeSupport/TerminalRetainedRowProbeSupport.swift#RetainedRowShapeReport`

**Problem.** The per-row loop skips an unreadable row with `continue`. That makes
`storedCellCounts.count` silently smaller than `retainedRowCount`, and the report then
mixes the two denominators: `allocatedBytes` and `requestBytes` sum over
`storedCellCounts`, while `fullWidthAllocatedBytes`, `blankRowFraction` and
`packedPayloadBytesPerRow` divide by `retainedRowCount`. Every ratio the probe exists to
produce -- `realizedSavingFraction`, `paperSavingFraction`,
`sharedBlankCeilingFractionOfAllocated` -- is then wrong in the flattering direction, and
still printed as a number. `derivationMatchesCensus` does go false, but it is one boolean
beside a dozen confident-looking fractions, which is exactly the arrangement the
discipline doc warns produces a reassuring answer at the moment the instrument is blind.

**Evidence.**

```swift
for index in 0..<terminal.scrollbackRowCount {
    guard let row = terminal.scrollbackRow(at: index) else { continue }
```

and the two denominators, `allocatedBytes` over the derived list:

```swift
self.allocatedBytes = storedCellCounts.reduce(0) {
    $0 + rowAllocation(storedCells: $1, cellStrideBytes: cellStrideBytes).allocated
}
```

against `fullWidthAllocatedBytes` over the reported count:

```swift
public var fullWidthAllocatedBytes: Int {
    let perRow = rowAllocation(storedCells: columns, cellStrideBytes: cellStrideBytes)
    return retainedRowCount * perRow.allocated
}
```

**Ideal fix.** Make `readRetainedRowShape` return `RetainedRowShapeReport?` (or throw) and
return nil on the first unreadable row -- a retained row index below
`scrollbackRowCount` that the reader refuses is a broken engine invariant, not a runtime
condition the probe should paper over. `main.swift` already has the `fail(...)` path for
exactly this shape. Then delete `retainedRowCount` as a separately stored field and
derive it as `storedCellCounts.count`, so the two denominators cannot disagree.

**By construction.** A report whose per-row arrays are shorter than its row count stops
existing, and the divergence between the two denominators is removed by removing one of
them.

**Cheaper fallback.** Keep the `continue` and add a `skippedRowCount` field. That makes
the blindness visible but leaves the fractions computable and wrong, which is a worse
artifact than one that refuses to be produced.

**Verification.** `lib/TerminalCore/Tests/TerminalRetainedRowProbeSupportTests`: assert
`report.storedCellCounts.count == report.retainedRowCount` for each fed stimulus, and
that `derivationMatchesCensus` is true -- both are behavioral statements about the report
value and survive any change to how the rows are read.

**Risk.** None: on a healthy engine the reader never returns nil, so no shipped run
changes. If one does start returning nil, the probe fails loudly instead of publishing an
understated saving.

**Vetted.** Both quotes are verbatim in
`lib/TerminalCore/Sources/TerminalRetainedRowProbeSupport/TerminalRetainedRowProbeSupport.swift`,
and the two denominators really do differ: `allocatedBytes` and `requestBytes` reduce over
`storedCellCounts`, while `fullWidthAllocatedBytes`, `blankRowFraction` and
`packedPayloadBytesPerRow` divide by the stored `retainedRowCount`. I traced the nil:
`Terminal.scrollbackRow(at:)` (`Terminal.swift:2863`) forwards to
`LogicalLineStore.paintedDisplayRow(at:)` (`:1682`) and `locate(displayRow:)` (`:1580`), which
bounds-checks against `grandDisplayRowTotal` -- the same quantity `scrollbackRowCount` returns
-- and after that returns nil only when no block claims a row the grand total says exists.
That is a broken engine invariant, exactly as the finding says.

**Correction.** The harm is not the one the prose states. `just terminal-retained-row-probe`
runs `scripts/terminal-retained-row-shape.py` (`justfile:208`), and that script re-derives
every fraction this finding names from `storedCellCounts` alone: `retainedRowCount: len(counts)`
at `:274`, `fullWidthAllocatedBytes: len(counts) * good_size(...)` at `:283`, and the same
`len(counts)` inside `paperSavingFraction` and `realizedSavingFraction` at `:287-290`. The
printed table therefore uses one denominator throughout and is immune to a skipped row. A
repo-wide grep shows the Swift `realizedSavingFraction`, `paperSavingFraction`,
`sharedBlankCeilingFractionOfAllocated`, `fullWidthAllocatedBytes` and
`packedPayloadBytesPerRow` have no consumer at all in `lib`, `app`, or `scripts` -- only a
single `blankRowFraction` expectation in the test suite. Nothing diverging "is still printed
as a number". What remains is a real but inert two-denominator split inside one Swift type,
behind a `continue` that a healthy engine cannot reach. Rescored to impact 1. The ideal fix is
still the right shape and is cheap, and the Python already agrees with it -- but note that
turning `retainedRowCount` into a computed property drops it from the synthesized `Codable`
output, which is a JSON break (harmless here, since the script does not read that field) and
should be stated rather than discovered.

**Conflicts with.** Nothing. No other lane touches
`TerminalRetainedRowProbeSupport.swift` or the Python driver.

<a id="probe-7"></a>

#### PROBE-7. Let the marker scan take the damage value instead of a `Set<Int>` rebuilt from it

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/TerminalCore/Sources/TerminalBenchmarkMarkers/TerminalBenchmarkMarkers.swift#scan(_:limitedToRows:)`, `app/TerminalBenchmark.swift#scanMarkers(_:damage:)`

**Problem.** The scanner asks its caller for a `Set<Int>?` of rows, when the caller
already holds a `TerminalDamage` that answers `contains(row:)` directly. The caller
therefore materializes the damage twice per pre-block frame -- once into an array, once
into a set -- to hand over a mirror of a fact the damage owns. `TerminalDamage.rowIndices`
carries an explicit comment saying it is a "materializing convenience for tests and
diagnostics; hot paths use `forEachRow` or `maximalContiguousSpans`", and this is the
one call site in shipped code that ignores it. The parameter is also wider than the
callee's needs: a `Set<Int>` can express row sets no damage value can, and `nil` versus
`.full` are two spellings of the same condition.

**Evidence.** The callee, which uses only membership:

```swift
public mutating func scan(_ plan: RenderFramePlan, limitedToRows rows: Set<Int>?) -> ... {
    ...
    guard rows == nil || rows!.contains(run.row) else { continue }
```

and the caller, `app/TerminalBenchmark.swift:1177-1180`:

```swift
markerScanner.scan(
    plan,
    limitedToRows: damage.isFull ? nil : Set(damage.expandingShift().rowIndices)
)
```

`TerminalDamage` already provides everything needed
(`lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift:114`):

```swift
public func contains(row: Int) -> Bool { bits.contains(row) }
```

**Ideal fix.** `scan(_ plan: RenderFramePlan, limitedTo damage: TerminalDamage)`, with the
body asking `damage.isFull || damage.contains(row: run.row)`. The call site becomes
`markerScanner.scan(plan, limitedTo: damage.expandingShift())`. The optional and the
`rows!` force-unwrap both disappear, `.full` becomes the "scan everything" case with no
second spelling, and the array plus set materialization per frame go with them.

**By construction.** The scan can no longer be asked about a row set that no damage value
could produce, and "scan everything" has exactly one representation.

**Cheaper fallback.** Keep the `Set<Int>?` and hoist a reusable scratch set on the
observer. That removes the allocation but keeps two spellings of "everything" and the
mirror.

**Verification.** `lib/TerminalCore/Tests/TerminalBenchmarkMarkersTests` already states
the behavior at lines 265-269 and 293 -- restate the same four expectations against a
`TerminalDamage` built from the same rows. The assertions are about which markers a
restricted scan reports, which is what must not change.

**Risk.** Low. This scan runs only before a block opens (`guard startNanoseconds == nil
else { return }` at `app/TerminalBenchmark.swift:600`), so no measured block's numbers
move either way -- which is also why the cost half of this is worth little and the
structural half is the reason to do it. `just test-terminal-benchmark-gui` is the check
that block opening still works, since `DanTermAppTests` does not compile the observer.

**Vetted.** Every quote is verbatim: the scan signature and its `guard rows == nil ||
rows!.contains(run.row)` at
`lib/TerminalCore/Sources/TerminalBenchmarkMarkers/TerminalBenchmarkMarkers.swift:118-134`,
the call site at `app/TerminalBenchmark.swift:1177-1180`, and `contains(row:)` at
`lib/TerminalCore/Sources/TerminalCore/TerminalDamage.swift:114` with the "materializing
convenience for tests and diagnostics" comment on `rowIndices` at `:118-119`. The
no-argument `scan(_:)` overload passes `nil` (`:104-106`), so `nil` really is a second
spelling of "everything" beside `.full`. I confirmed the reachability caveat the finding
already makes: `scanMarkers(_:damage:)` is called only after `guard startNanoseconds == nil
else { return }`, so no measured block's numbers move.

**Vetted (fix cost).** One step the ideal fix needs that the finding does not name.
`TerminalBenchmarkMarkers` declares `dependencies: ["TerminalRenderPlanning"]`
(`lib/TerminalCore/Package.swift:184-188`) and its file header calls the module "pure,
dependency-free"; `TerminalDamage` lives in `TerminalCore`. Taking a `TerminalDamage`
parameter therefore means adding `TerminalCore` to that target, which the sibling
`TerminalBenchmarkTopology` already does (`:190-194`). That is a one-line change and not a
layering break -- but it belongs in the plan, because the alternative reading of the
`Set<Int>?` is that it exists deliberately to keep the engine out of this module.

**Conflicts with.** `DRAW-1` (delete the `row` field from the four run types) rewrites this
exact loop -- it names `TerminalBenchmarkMarkers` as a target that must move in the same
change, and with `run.row` gone the row identity comes from the enclosing `plan.rows` index
instead of the run. The two fixes are the same edit to the same lines and cannot be
implemented independently; sequence them.

<a id="probe-8"></a>

#### PROBE-8. Give `PreparedDraw` a non-optional context so a zero-cost draw is unrepresentable

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalCore/Sources/TerminalDrawBenchmarkSupport/TerminalDrawBenchmarkSupport.swift#PreparedDraw`

**Problem.** `PreparedDraw` stores its `CGContext` as a mutable optional and `draw()`
returns silently when it is nil. The initializer throws on every path that fails to build
a context, so nil is unreachable today -- but the guard means that if it ever became
reachable, `measureDurationStable` would keep calling `draw()`, see near-zero batches,
scale `batchCount` upward until the floor was met, and report a plausible per-draw
duration for a benchmark that drew nothing. The optional exists for a real reason (the
deinit must drop the context's reference before `storage.deallocate()`, since the context
does not own that buffer) and that reason is not written down anywhere in the file.

**Evidence.**

```swift
private var context: CGContext?
...
deinit {
    context = nil
    storage.deallocate()
}

func draw() {
    guard let context else { return }
    drawRenderFrame(plan, restrictedTo: restriction, metrics: metrics, in: context)
}
```

`measureDurationStable` cannot tell a fast batch from an empty one -- it only compares
totals against `targetNanoseconds`:

```swift
guard let shortest = totals.min(), shortest < targetNanoseconds else {
    return (batchCount, totals)
}
```

**Ideal fix.** Move the buffer's ownership into the context's own lifetime: allocate the
storage and pass a `releaseCallback` to `CGContext(data:...)` so libCG frees it when the
context is released, then store the context as a `let` and delete the deinit and the
guard. That is the structure in which "a `PreparedDraw` with no context" cannot be
written down, and `draw()` has no early return at all. If the release callback is judged
too subtle, the smaller version of the same idea is `let context: CGContext` plus a
`deinit` that does `withExtendedLifetime(context) { storage.deallocate() }` -- still no
optional, still no guard.

**By construction.** A `PreparedDraw` that draws nothing stops being constructible, so
the benchmark loses its one path to a confident number for work it did not do.

**Cheaper fallback.** Replace `return` with `preconditionFailure`. Loud rather than
silent, but `agent-docs/measurement-discipline.md`'s preference is to remove the state,
and the audit brief prefers deleting a guard to rewording one.

**Verification.** `lib/TerminalCore/Tests/TerminalDrawBenchmarkSupportTests`: assert that
a measured sample's `sampleDurationNanoseconds` minimum clears the target floor and that
`surface.drawnCellCount` is nonzero for each grid and workload -- a behavioral statement
that a batch which drew nothing cannot satisfy. Run the existing suite unchanged to prove
the lifetime change did not regress; a use-after-free on the storage would surface as a
crash or an ASan report there.

**Risk.** This touches manual memory management. A release callback that is wired wrong
frees the buffer twice or never; the suite plus a run under Address Sanitizer
(`swift test --package-path lib/TerminalCore --sanitize=address --filter
TerminalDrawBenchmarkSupportTests`) is what settles it. The safer `withExtendedLifetime`
variant carries none of that risk and still removes the optional.

**Vetted.** I read `PreparedDraw` end to end
(`lib/TerminalCore/Sources/TerminalDrawBenchmarkSupport/TerminalDrawBenchmarkSupport.swift:266-356`).
Every quote is verbatim, including `measureDurationStable`'s return guard at
`lib/TerminalCore/Sources/TerminalCoreBenchmarkSupport/TerminalCoreBenchmarkSupport.swift:117-121`.
`context` is assigned exactly once at the end of `init` and set to nil only in `deinit`, and
`init` throws on all four failure paths (`invalidMetrics`, `invalidFrame` twice,
`allocationFailed`), so `draw()`'s guard cannot fail while the object is alive. Confidence
raised to 5 -- I read every line quoted.

**Correction.** The finding rests on "if it ever became reachable", and it cannot become
reachable without someone editing this class. That is not a risk; it is a hypothetical, and
it should not be what carries the finding. What I did find is worth more.
`scripts/terminal-headless-draw-arm.swift:28-97` holds a *second* `PreparedDraw`, whose header
says it "mirrors the private one in TerminalDrawBenchmarkSupport" -- and that copy stores
`private let context: CGContext` with `deinit { storage.deallocate() }` and no guard at all.
So the two copies disagree about the exact ordering the optional exists for, and the mirror is
the one that gets it wrong: a `deinit` body runs before stored properties are released, so the
script's arm frees the bitmap while the context still points at it. The finding should read as
"one undocumented lifetime ordering, spelled two different ways in two copies, neither saying
why", and the fix is `let context: CGContext` plus
`deinit { withExtendedLifetime(context) { storage.deallocate() } }` and a comment naming the
reason -- applied to **both** copies. The release-callback variant should not be the
recommendation: it buys nothing here and adds a double-free surface to a hand-run tool.

**Conflicts with.** `DRAW-3` rewrites `scripts/terminal-headless-draw-arm.swift#PreparedDraw.draw`
and its stored restriction -- the same class this correction says must also change, and the
same `deinit`/`draw()` region. Land them together.

#### Dropped (PROBE)

- **`decodeBenchmarkChunks` indexes `Data` by offset rather than by index.** `data[offset..<end]` assumes `startIndex == 0`, which is true for `readDataToEndOfFile()` and for every call in the tree, but would trap on a `Data` slice. No caller passes one, and the public surface is consumed by two executables and one test. Not worth a finding on its own; fold it into any edit that touches the function.
- **`TerminalBenchmarkDamageTopologyRecorder.contracts` duplicates the Python `BLOCK_CONTRACTS` shapes.** Looks like a closed vocabulary enumerated twice, but it is not: `scripts/terminal-benchmark-validation.py:1512` compares `topology.get("allowedEngineDamageShapes") != expected_shapes` field for field and invalidates the block on a mismatch. The duplication is a checked cross-reference, which is the right structure.
- **`measureDurationStable`'s unbounded retry loops.** Both `while` loops can in principle spin, but `scaledBatchCount` guarantees `max(current + 1, ...)` on every step, so both terminate. No defect.
- **`measureFeedBatch` excludes terminal construction from its bracket.** Checked because it could have been an attribution error; it is correct -- `now()` is read after `makeTerminal()` and the previous iteration's terminal is released before the next bracket opens.
- **`MemoryProbePayloadReport.footprintCoverageOfCellStorage` returns 0 for a zero delta.** Same family as `PROBE-3`/`PROBE-4`, but the zero-delta case only arises for the `empty` payload, where the reader is already looking at a table of zeros. Left as part of `PROBE-3`'s fix rather than a finding.
- **`NeutralTerminalRecording.replay` ignores `.input` and `.paste` events.** Correct for a PTY-captured tape: a key press reaches the terminal only as the child's echoed `feed` bytes, and replaying both would double the input. The `.write` case documents this; `.input` and `.paste` do not, which is a one-line comment gap, not a defect.
- **`GlyphPreview`.** Read in full. It is a debug AppKit viewer that reports no measured quantity, so nothing it does can produce a misleading number. Its `NSScreen.main?.backingScaleFactor ?? 2` fallback is a display default, not an instrument default.
- **`TerminalBenchmarkPresentationCoverageRecorder`.** Audited specifically for the "measured zero vs not measured" defect it exists to prevent, and it is correct: `sampleCount` advances on a lapsed sample, and the counters are cumulative rather than latched.
- **`ResizeProbeDistribution`'s empty case.** Looked like a `?? 0` family defect and is the opposite -- it is the reference implementation of the rule, keeping `sampleCount == 0` beside the zeros so a reader can tell the two apart. `PROBE-4` is what the occupancy probe would look like if it copied this.
- **`docs/scratch/2026-08-18-construction-audit.md` overlap.** Checked; that document is entirely about control-sequence behavior against `references/`. Nothing in it touches the benchmark or probe harness, and none of its items are live here.


### Area: Core domain model and projections (`MODEL`)

_Scope: `lib/DanTermCore/Sources/DanTermCore/` -- Model.swift, ModelOperations.swift,
Projections.swift, PaneLayout.swift, PaneGridOverride.swift, PaneDropResolution.swift,
PaneRosterProjection.swift, PaneStripGeometry.swift, DisplayLine.swift, DropZone.swift,
DragDropInput.swift, EntityTitle.swift, SidebarItemStore.swift, ScrollbarMath.swift,
TerminalMetadataBounds.swift, AgentSession.swift, Persistence.swift, IpcEntityEncoder.swift,
TabTodo.swift, plus `DanTermProtocol/ChipKind.swift`. I read Update.swift,
app/SidebarView.swift, app/SidebarReconcileDriver.swift, app/Reconcile.swift,
app/PreferencesPanel.swift, app/ScrollableTerminalView.swift and app/PaneStripView.swift only
to establish reachability for defects whose home is in my files._

**The auditor's read on the area.** The centre of this area is genuinely strong.
`PaneTree` makes an ownerless pane unrepresentable, `PaneGridOverride` fails instead
of clamping, `DisplayLine` is a tight boundary type with a real fast path,
`PaneLayout` and `PaneDropResolution` share one geometry so drop targeting cannot
disagree with what is drawn, and every item the 2026-08-18 construction audit filed
under `MODEL` has landed. The defects that remain share one shape: a rule that is
stated in one place and silently depended on somewhere else -- the sidebar op script
assuming the store did not remount a group, the confirmation projection restating the
reducer's retraction rule, the container diff building the exact parallel tree its own
comparison exists to avoid building, a ratio repaired at projection rather than at
ingress. I did not audit Update.swift, IpcDispatch.swift, PaneTapeStreamState.swift or
KeybindingPreferences.swift as subjects. I looked at `ScrollbarMath.scrollbarOffsetY`'s
`total - offset - len` UInt64 subtraction and dropped it for the same reason the prior
audit did: `Terminal.scrollProjection` sets `topRow <= max(0, totalRows - rowCount)` and
`windowRows == rowCount`, so the subtraction cannot underflow.

<a id="model-1"></a>

#### MODEL-1. Stop emitting tab row ops for a group the same script just remounted

`correctness` &middot; impact 2, confidence 4 &middot; effort small &middot; rewritten

**Files.** `lib/DanTermCore/Sources/DanTermCore/Projections.swift#computeSidebarRowOps`,
`lib/DanTermCore/Sources/DanTermCore/Projections.swift#sidebarSequenceOps`,
`lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift#apply`

**Problem.** `computeSidebarRowOps` decomposes a group reorder into
`removeGroup` + `insertGroup`. `SidebarItemStore.insertGroup` rebuilds that group's
whole child list from the *new* projection. The level-2 tab diff that runs afterwards
does not know this: it diffs the group's *old* tab list against its new one and emits
`insertTab` / `removeTab` ops with indices that describe a list the store no longer
holds. The level-2 loop already skips brand-new groups (`guard let oldGroup ... else
continue`) for exactly this reason -- a remounted group needs the same treatment and
does not get it. A group reorder plus any tab insert or remove inside that group in
the same coalesced sweep therefore duplicates a sidebar row or removes the wrong one,
and the outline stays wrong until the next `reloadAll`.

**Evidence.** `Projections.swift#computeSidebarRowOps` runs the group diff first:

```swift
  if !new.isSingleGroupMode {
    ops += sidebarSequenceOps(
      old: old.groups.map(\.id), new: new.groups.map(\.id),
      insert: { id, idx in .insertGroup(id: id, index: idx) },
      remove: { idx in .removeGroup(index: idx) })
  }
  let oldGroupById = Dictionary(uniqueKeysWithValues: old.groups.map { ($0.id, $0) })
  for newGroup in new.groups {
    guard let oldGroup = oldGroupById[newGroup.id] else { continue }  // inserted group: handled above
    ops += sidebarSequenceOps(
      old: oldGroup.tabs.map(\.id), new: newGroup.tabs.map(\.id), ...)
  }
```

`sidebarSequenceOps` turns a reorder into remove+insert by construction:
`if let k = work.firstIndex(of: new[j]) { ops.append(remove(k)); work.remove(at: k) }
ops.append(insert(new[j], j))`. `SidebarItemStore.swift#apply`'s `.insertGroup` arm then
rebuilds the children from the new projection:
`childItems[id] = group.tabs.map { makeFreshTabItem(for: $0) }`.

Worked case. `old = [A(t1), B(t2)]`, `new = [B(t2, t3), A(t1)]`. Level 1 yields
`[.removeGroup(index: 1), .insertGroup(id: B, index: 0)]`; the store then holds
`childItems[B] == [t2, t3]`. Level 2 sees `oldGroupById[B]` and appends
`.insertTab(id: t3, groupId: B, index: 1)`, which the store applies to a list that
already contains `t3` -- two rows for one tab, and `app/SidebarView.swift#applyRowOp`
mirrors it into `outlineView.insertItems`. The reverse case (a tab removed from the
reordered group) removes whichever row now sits at the stale index.

**Ideal fix.** Have `sidebarSequenceOps` report the ids it re-inserted, and let
`computeSidebarRowOps` treat a re-inserted group exactly like a newly inserted one --
`continue` before the tab diff, because an inserted group already arrives carrying its
`new` tabs. Making the set an output of the diff, rather than a fact the caller has to
remember, is what stops the two levels from disagreeing again.

**By construction.** A tab op whose index describes a list the store has already
replaced stops being expressible: the only groups that reach the tab diff are the ones
whose child rows survived level 1 untouched.

**Cheaper fallback.** Return `[.reloadAll]` whenever the group id order changes at all.
That is two lines and provably correct, but it throws away every row's cell and any
in-progress inline rename on a plain group drag, which is the churn the incremental
script exists to avoid.

**Verification.** `lib/DanTermCore/Tests/DanTermCoreTests/ReconcileTests.swift` already
has the executable spec: `checkRowOps` applies the op script to a copy of `old` and
requires it to equal `new`, and its `applySidebarRowOps` harness models `.insertGroup`
as `work.groups.insert(newGroup(id), at: index)` -- the same "arrives with its new
tabs" behavior the store has. Add one case beside
`"reorder groups (isFirst flips)"`: `checkRowOps(two-groups[A:[t1], B:[t2]],
two-groups[B:[t2, t3], A:[t1]], "group reorder plus a tab added to the moved group")`.
It fails today and passes after the fix, and it is structure-insensitive -- it asserts
the resulting outline, not the op sequence.

**Risk.** Skipping the tab diff for a remounted group is only correct if the store
really rebuilds children from the new projection on every `insertGroup` path; that is
true today for both the multi-group arm and the `reloadAll` fallback, and the
model-apply test is what keeps it true.

**Vetted.** I opened `Projections.swift:1017-1085` (`computeSidebarRowOps`) and
`:980-1010` (`sidebarSequenceOps`), and `SidebarItemStore.swift:59-184`. Every quote is
exact. `.insertGroup` really does `childItems[id] = group.tabs.map { makeFreshTabItem(for:
$0) }` from the *new* projection (line 86), and level 2 really does run for any group
present in `oldGroupById` (line 1041). I hand-ran the auditor's worked case against the
test harness at `ReconcileTests.swift:1046` (`applySidebarRowOps`, whose `.insertGroup`
arm is `work.groups.insert(newGroup(id), at: index)` -- the same "arrives with its new
tabs" behavior): ops are `[.removeGroup(1), .insertGroup(B,0), .insertTab(t3,B,1)]` and
the result is `[B(t2,t3,t3), A(t1)]`, so the proposed test does fail today. The pure
defect is real.

Then I chased reachability and could not close it. `computeSidebarRowOps` only emits
`.insertGroup` for a group that was already in `old` when the *group id order* changes.
The only writer of group order in the tree is `Update.swift:1098` `.reorderGroup`
(`grep` for `model.groups.insert|append|sort|swapAt` returns exactly three sites: two
appends and that one insert), and its arm changes nothing but position. Every other
group mutation is a removal (`removeGroupIfEmpty`, `deleteGroupBody`, the delete-group
confirm arm at `Update.swift:1498`), and a removal preserves the surviving order, so
`sidebarSequenceOps` emits `remove` only. So no single message produces both a reorder
and a tab-membership change in the same group.

Nor does a sweep batch several messages. `AppRuntime.dispatchInFrame` reconciles per
message unless `Msg.coalescesReconcile` is true, and that set
(`Msg.swift:270-296`) is only `.searchTotalReported`, `.searchSelectionReported`,
`.sessionBell`, `.sessionNotification` and the cosmetic `.sessionReport` cases -- none
of which touch group order or tab membership. `ReconcileOutbox.drain` dispatches one
queued message at a time, each opening its own frame and its own sweep. The sidebar pass
is never skipped (`Reconcile.swift:245` guards only on `sidebarView` being unset, which
is true only before launch finishes), and `SidebarReconcileDriver` is re-constructed on
teardown (`AppRuntime.swift:1557`) so a restore starts from `.reloadAll`.
`advanceSidebarCache` retains old *payloads* for unpainted rows but always advances
group and tab id order to `new`, so the cache cannot lag the store structurally.

**Correction.** The defect is in the pure diff, not on screen. `computeSidebarRowOps`
produces an op script that does not reach `new` when a group both moves and changes its
tab list, and the repo's own model-apply harness proves it; but no message sequence
reachable today feeds it that input, because `.reorderGroup` is the sole writer of group
order and it changes nothing else. Read this as a latent trap with a two-line fix and a
one-line test, not as a duplicated sidebar row a user can hit. The moment any reducer
arm reorders groups alongside a tab move -- a drop that lands a tab and hoists its group,
say -- the symptom goes live with no other warning. Score it as a cheap guard against a
future edit; the auditor's ideal fix (make the re-inserted ids an output of
`sidebarSequenceOps`) and its test are both right.

**Conflicts with.** [CHROME-4](CHROME.md#chrome-4) ("Keep one record of the last applied
sidebar projection") edits the same pass -- `SidebarReconcileDriver.reconcile`,
`SidebarView.applySidebarOps`, `advanceSidebarCache` -- but not
`computeSidebarRowOps` or `sidebarSequenceOps`. The two are implementable
independently; land whichever first and rebase the other.

<a id="model-2"></a>

#### MODEL-2. Make an emptied Font Size field mean "no `font.size` key"

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#PreferencesDraft`,
`lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredPreferencesPanel`,
`lib/DanTermCore/Sources/DanTermCore/Update.swift` (`.prefSet(.fontSize)`, `.prefSave`)

**Problem.** `PreferencesDraft.fontSizeText` is `String?`, where `nil` means "the config
has no `font.size` key" and `""` means "the user cleared the field". The projection
renders both as the empty string, and the panel draws the built-in default as the
field's placeholder -- so an empty field tells the user the default is in effect. Save
disagrees: empty text fails the parse guard, so the previously committed size is kept
and the panel goes on showing an empty field over a size that is still 16. There is no
way to remove the key from Settings, and the two states the model can hold are
indistinguishable on screen. The neighbouring optional text setting already has the
opposite rule: `resolveFontFamilyDraft` normalizes blank text to `nil`.

**Evidence.** `Model.swift#PreferencesDraft`: `var fontSizeText: String?` with
`/// Raw font-size entry; nil = no `fontSize` key, so the built-in default applies.`
and `self.fontSizeText = config.fontSize.map(configFontSizeText)`.
`Projections.swift#desiredPreferencesPanel`: `fontSizeText: draft.fontSizeText ?? ""` --
`nil` and `""` project identically. `Update.swift` `.prefSave`:

```swift
        let parsedFontSize: Double? = draft.fontSizeText.flatMap { Double($0) }
        let validFontSize = draft.fontSizeText == nil
            || (parsedFontSize.map { $0.isFinite && $0 > 0 } ?? false)
        if validFontSize {
            newConfig.fontSize = parsedFontSize.map(DanTermConfig.boundedFontSize)
        }
```

`Double("")` is `nil`, so `validFontSize` is `false` for cleared text and the whole
assignment is skipped. `app/PreferencesPanel.swift` makes the promise the save breaks:
`fontSizeField.placeholderString = configFontSizeText(DanTermConfig.default.resolvedFontSize)`,
and unlike `themeField` the size field is editable, so clearing it is a real gesture.
The rule that should apply is stated one file over, in
`ModelOperations.swift#resolveFontFamilyDraft`: blank text means "no `font.family` key".

**Ideal fix.** Make `fontSizeText` a plain `String` -- the empty string is the whole
"no key" state -- and give it a `resolveFontSizeDraft(_:) -> Double?` peer of
`resolveFontFamilyDraft` that returns `nil` for blank text and a bounded size
otherwise, with `.prefSave` writing that result unconditionally. Unparseable non-blank
text stays the one rejected case.

**By construction.** The `nil`-versus-`""` pair collapses to one value, so a draft that
renders as an empty field but saves as "keep the old size" stops being representable,
and the `?? ""` in the projection goes away.

**Cheaper fallback.** Leave the optional and add `|| draft.fontSizeText?.isEmpty == true`
to the `validFontSize` condition. That fixes the behavior in one line but keeps two
model states that no surface can tell apart, so the next reader has to rediscover which
one the panel is showing.

**Verification.** A reducer test in the preferences suite: seed a config with
`fontSize: 16`, open the draft, send `.prefSet(.fontSize(""))` and `.prefSave`, then
assert `model.config.fontSize == nil` and that `desiredPreferencesPanel(in: model)?
.fontSizeText == ""`. Pair it with the existing unparseable-text case
(`.prefSet(.fontSize("abc"))` leaves `config.fontSize` untouched) so the two are pinned
apart.

**Risk.** A user who clears the field and saves loses their configured size instead of
keeping it. That is the intended reading of the placeholder, but it is a behavior
change and should be stated in the commit.

**Vetted.** I opened `Model.swift:456-483` (`PreferencesDraft`), `Projections.swift:147`
and `:208` (`fontSizeText: draft.fontSizeText ?? ""`), `Update.swift:648-700`
(`.prefSet(.fontSize)` and `.prefSave`), `ModelOperations.swift:29-41`
(`resolveFontFamilyDraft`, `configFontSizeText`), and all of `PreferencesPanel.swift`'s
`fontSize` sites. Every quoted line is exact, including the `validFontSize` block and
the placeholder at `PreferencesPanel.swift:161`.

The claim built on top of them is wrong. `PreferencesPanel.swift:675` is
`runtime?.send(.prefSet(.fontSize(text.isEmpty ? nil : text)))` -- the panel already
normalizes an emptied field to `nil` before the message leaves AppKit, exactly as the
line below it does for `fontFamily`. So clearing the field gives `draft.fontSizeText ==
nil`, `validFontSize` is `true`, `newConfig.fontSize = nil`, and the key *is* removed.
The behavior the finding asks for is the behavior that ships. `grep` for
`prefSet(.fontSize` over the non-test tree returns that one line, so nothing else can
produce `""` either: the `""` state is representable but unreachable.

**Correction.** There is no user-visible bug here. What remains is an altitude problem
worth one point, not two: `fontSizeText: String?` carries a `""` case no surface can
reach, and the rule that makes it unreachable ("blank means no key") is written in
AppKit, one layer below the core that states the same rule for `font.family` in
`resolveFontFamilyDraft`. The ideal fix stands as written -- collapse the optional to a
plain `String` and add a `resolveFontSizeDraft` peer -- but its payoff is that the core
becomes the authority and the `?? ""` in the projection goes away, not that a save starts
working. The Risk paragraph is void: clearing and saving already drops the key. The one
residual oddity is whitespace-only text (`" "` is non-empty, fails the parse, keeps the
old size and stays on screen), which is the same intended "correct your typo" behavior
as `"abc"` and below the reporting bar; the ideal fix would trim it away for free.

**Conflicts with.** Nothing. No other lane file names `PreferencesDraft`, `.prefSave` or
`desiredPreferencesPanel` as a subject.

<a id="model-3"></a>

#### MODEL-3. Diff container shape against the split tree itself and delete `ContainerLayoutNode`

`cost` &middot; impact 1, confidence 5 &middot; effort medium &middot; rescored

**Files.** `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#ContainerLayoutNode`,
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#containerLayoutNode`,
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#containerShape`,
`lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredContainerShapes`

**Problem.** `desiredContainerShapes` builds a fresh `ContainerLayoutNode` tree for
every tab on every reconcile sweep, purely so `computeContainerOps` can compare it with
the cached one. `ContainerLayoutNode` is an `indirect enum`, so every node is a heap
box: the sweep allocates one box per pane plus one per split, for every tab in the
model, and discards all of them the moment the diff decides nothing changed. The work
scales with how much state exists, not with what changed. The file already names this
cost as the thing to avoid -- in the doc comment of the comparison that reads the tree.

**Evidence.** `ModelOperations.swift#sameContainerStructure`:

```swift
/// Compares in place rather than deriving a ratio-free tree per call: building
/// one would heap-allocate a box per node on every diff, which is the cost this
/// comparison exists to avoid.
```

and directly above it, `indirect enum ContainerLayoutNode` with
`func containerLayoutNode(_ node: SplitNodeModel) -> ContainerLayoutNode` rebuilding
the tree node by node, called from `containerShape(of:visible:)`
(`layout: containerLayoutNode(tab.paneTree.root)`), called from
`Projections.swift#desiredContainerShapes` for `for group in model.groups { for tab in
group.tabs { ... } }`, which `app/Reconcile.swift:147` runs on every sweep.

**Ideal fix.** Hold `let root: SplitNodeModel` in `ContainerShape` instead of the
parallel tree, and give the diff a payload-skipping `sameContainerLayout(_:_:)` beside
the existing `sameContainerStructure(_:_:)` -- ids, directions and ratios, never pane
payload -- so `computeContainerOps`'s `oldShape.layout != shape.layout` becomes
`!sameContainerLayout(...)`. `ContainerLayoutNode` and `containerLayoutNode` are then
deleted outright, and the projection allocates nothing per tab. Nothing compares
`ContainerShape` with `==` today (`app/Reconcile.swift` only stores and re-reads it),
so the synthesized conformance is not load-bearing.

**By construction.** A layout value that disagrees with the tree it was copied from
stops existing, because there is no copy: the shape holds the tree. It also removes the
standing hazard that a future field added to `SplitNodeModel` is forgotten in
`containerLayoutNode`.

**Cheaper fallback.** Keep `ContainerLayoutNode` and skip rebuilding it for tabs whose
`paneTree` is `===`-unchanged. Swift values have no identity, so this needs a stored
generation counter on `PaneTree` -- a hand-maintained mirror, which is the shape this
audit exists to undo.

**Verification.** This is a cost finding, so the honest report is that no workload on
the ladder drives reconcile sweeps: the deciding observable is a
`just benchmark-sample btop-scroll 20` profile checking whether
`ContainerLayoutNode` box allocations appear under `desiredContainerShapes`; the
code-level quantity is (panes + splits) heap boxes per sweep, allocated and freed.
Correctness is carried unchanged by the existing container-op model-apply tests in
`ReconcileTests.swift`, which assert the op script and the resulting presence and
visibility map.

**Risk.** The shape cache would retain `PaneModel` payloads (titles, cwds, todos) for
one sweep after a pane is gone. That is small and bounded -- scrollback is not in the
model -- but it is a real change in what the cache holds and should be stated.

**Vetted.** I opened `ModelOperations.swift:1032-1107` -- `ContainerLayoutNode`,
`ContainerShape`, `containerLayoutNode`, `sameContainerStructure`, `containerShape(of:
visible:)` -- and `Projections.swift:1204-1268` (`desiredContainerShapes`,
`computeContainerOps`). Every quote is exact, including the `sameContainerStructure` doc
comment about the heap box per node. The projection really does rebuild one
`ContainerLayoutNode` tree per tab per sweep, and `computeContainerOps:1257` really is
`oldShape.layout != shape.layout`, so a `sameContainerLayout` peer is what would replace
it. Nothing compares `ContainerShape` itself with `==`: the only other readers are
`visibleTabId` and `containerOpsStrandVisible`, which read fields.

The cost side does not hold up at the claimed size. Sweeps are not continuous:
`AppRuntime.dispatchInFrame` reconciles once per non-coalescing message, and the coalesced
path is capped at one sweep per `reconcileCoalesceInterval = 0.075`
(`AppRuntime.swift:233`), so the ceiling is about 13 sweeps a second under a title or
bell storm. At human-scale tab and pane counts that is a few hundred small boxes a
second, allocated and freed -- below anything a profile would separate from noise. The
auditor's own Verification concedes no workload on the ladder drives this.

**Correction.** Read this as a small structural cleanup, not a cost win. The payoff that
survives is the deletion of a hand-maintained parallel tree that must be kept in step with
`SplitNodeModel` -- a real but one-point win -- and the allocation saving should not be
claimed until a profile shows it. The ideal fix also gives something up that the current
type buys: `containerLayoutNode` is documented as "Drops pane payload while retaining
every input to the pane layout function", so today a shape that carries pane payload is
unrepresentable. Holding `SplitNodeModel` reverses that, and the synthesized `==` on
`ContainerShape` would silently start comparing titles, cwds and todos. Trading one
unrepresentable state for another is the honest framing; if this lands, drop
`ContainerShape: Equatable` in the same change so no caller can pick up the payload
comparison by accident.

**Conflicts with.** [CHROME](CHROME.md)'s dropped item "`ContainerLayoutNode`
materialized per tab per sweep" is the same code with the opposite verdict, and reaches
it by the same reasoning I did (human-scale node counts; storing the model tree retains
pane payload, "a worse trade"). That lane declines it outright. Both lanes agree the
allocation claim is unmeasured; treat MODEL-3 at impact 1 as the reconciled reading.

<a id="model-4"></a>

#### MODEL-4. Make the split ratio a bounded type so a corrupt one cannot be stored or reported

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#SplitNodeModel`,
`lib/DanTermCore/Sources/DanTermCore/Model.swift` (`parseSplitNode`),
`lib/DanTermCore/Sources/DanTermCore/PaneLayout.swift` (`normalizedRatio`),
`lib/DanTermCore/Sources/DanTermCore/IpcEntityEncoder.swift#splitNode`

**Problem.** `SplitNodeModel.split` carries a bare `CGFloat` ratio with no invariant.
The restore builder accepts whatever the init file says -- `5.0`, `-1`, `NaN` -- and
stores it. Only the layout projection repairs it, at the point of use, so the model
keeps the bad value and both the other readers pass it straight through: the snapshot
codec writes it back to disk unchanged, and the IPC encoder reports it to a client. A
`danterm ls` then names a ratio that does not describe what is on screen, and the bad
value survives every save. `PaneGridOverride` in the same lane already shows the right
answer for this exact question: fail at admission rather than repair at use.

**Evidence.** `Model.swift` `parseSplitNode`, split arm:
`return .split(id: splitId, direction: direction, first: firstNode, second: secondNode,
ratio: CGFloat(ratio ?? 0.5))` -- no bound on `ratio`.
`PaneLayout.swift#normalizedRatio`: `guard ratio.isFinite else { return 0.5 }; return
min(max(ratio, 0), 1)` -- the repair, at projection.
`Persistence.swift#toSplitNodeSnapshot`: `ratio: Double(ratio)` -- written back raw.
`IpcEntityEncoder.swift#splitNode`: `"ratio": .number(Double(ratio))` -- reported raw.
The live drag path is already clean: `app/PaneDividerView.swift` computes through
`PaneLayout.swift#paneSplitRatio`, which returns a clamped value.

**Ideal fix.** A `SplitRatio` value type with a failable init that admits only a finite
value in `0...1`, in the shape of `PaneGridOverride`. `SplitNodeModel.split` carries it,
`parseSplitNode` falls back to `.half` when the persisted number does not admit,
`Msg.splitRatioChanged` carries it, and `normalizedRatio` is deleted -- the projection
can no longer be handed a number it has to repair.

**By construction.** "A split whose stored ratio is not a ratio" stops being
representable, which deletes the `?? 0.5` and the `guard ratio.isFinite` at the
projection boundary and removes the disagreement between what the wire reports and what
the layout draws.

**Cheaper fallback.** Clamp inside `parseSplitNode` and inside
`PaneTree.updateRatio`. Two lines, and it stops bad values entering the model, but it
leaves `normalizedRatio` in place as a second statement of the same rule and leaves the
type as wide as `CGFloat`, so the next ingress is free to skip the clamp.

**Verification.** A persistence test: load an init file whose split node carries
`"ratio": 5.0`, then assert `toSnapshot(model)` round-trips a ratio inside `0...1` and
that `paneLayout(in:tree:zoomedPaneId:)` gives the same rectangles as the equivalent
`0.5` tree. Both assertions are behavioral: they read the exported document and the
projected geometry, not the enum's payload.

**Risk.** Ratio touches the snapshot codec, the IPC `ls` reply shape and every split
construction site, so the change is wide even though each edit is small. The wire
number stays a JSON number, so no external compatibility is at stake.

**Vetted.** I opened `Model.swift:1283-1318` (the `parseSplitNode` split arm, ending in
`ratio: CGFloat(ratio ?? 0.5)`), `PaneLayout.swift:274-278` (`normalizedRatio`),
`Persistence.swift:145` (`ratio: Double(ratio)`), `IpcEntityEncoder.swift:179`
(`"ratio": .number(Double(ratio))`), `Model.swift:406-409` (`PaneTree.updateRatio`, no
clamp) and `Update.swift:1139-1146` (`.splitRatioChanged`, no clamp). Every quote is
exact and every reader passes the stored number straight through.

I checked the drag path the auditor calls clean and it is: `paneSplitRatio`
(`PaneLayout.swift:137-164`) returns `firstExtent / usableExtent` after `guard
usableExtent > 0` and `clampedFirstExtent`, whose bound is
`min(max(rounded, effectiveMinimum), usableExtent - effectiveMinimum)` with
`effectiveMinimum = min(finiteMinimum, usableExtent / 2)`. That upper bound is always
at least the lower one, so the result is finite and inside `0...1` for any pointer
position, including a non-finite one. The only ingress that can store an out-of-range
ratio is the snapshot builder.

Reachability is real, not theoretical: `validateAndBuildDetailed`'s own comment at
`Model.swift:1096` says "Hand-authored snapshots can omit ids as a user-facing
convenience", so hand-written init files are a supported surface, and a typed `70` for
`0.7` is an ordinary slip. The precedent argument is stronger than the auditor states --
the same function bounds `fontSizeSteps` at ingress ("bounded here rather than at
projection, so the restored pane responds to the next adjustment exactly as one the user
zoomed to that bound would") and rejects a bad `gridOverride` at ingress, both within
forty lines of the ratio that gets neither.

**Correction.** Drop `NaN` from the list of admissible corrupt values. The snapshot is
JSON, which has no `NaN` or infinity literal, and `JSONDecoder` rejects non-conforming
floats by default, so the reachable corruption is a finite number outside `0...1`. That
is enough: with `"ratio": 70` the layout draws a clamped split while `danterm ls` reports
`70` and every subsequent checkpoint writes `70` back, which is the disagreement the
finding is about. Nothing traps or throws.

**Conflicts with.** [PERSIST-2](PERSIST.md#persist-2) ("Declare `Direction: String,
Codable`") rewrites the same `parseSplitNode` split arm and the same
`SplitNodeSnapshot.split` case; the two edits collide line-for-line and should land in
one change or in a stated order. PERSIST also *drops* this exact item, on the reasoning
that "`normalizedRatio` ... cannot be deleted anyway, since divider drags feed the same
field". That reason is wrong on the facts: `paneSplitRatio` already clamps, as shown
above, so `normalizedRatio` has no live caller that needs it once the ingress is bounded.
MODEL-4 supersedes that drop.

<a id="model-5"></a>

#### MODEL-5. Delete the existence guards from `desiredConfirmation` and let the reducer own retraction

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredConfirmation`,
`lib/DanTermCore/Sources/DanTermCore/Update.swift` (`reconcilePendingConfirmation`)

**Problem.** "A confirmation whose subject no longer exists is retracted" is written
twice: once in the reducer, which runs it after *every* message from `update()`'s
unconditional `defer`, and again in the projection, which returns `nil` for three of
the six arms. The copies have already drifted -- the projection guards
`closeOtherPanes`, `closeTab` and `deleteGroup` but not `closePane` or `closeTabs`, for
no stated reason. Worse, the projection's version cannot actually retract anything: it
only hides the panel while `model.pendingConfirmation` stays set, so the model and the
screen disagree about whether a transaction is open.

**Evidence.** `Update.swift#update` opens with
`defer { reconcileTabState(&model); ...; reconcilePendingConfirmation(&model, env: env); ... }`,
and `Update.swift#reconcilePendingConfirmation` covers every arm, including the two the
projection skips: `case .closePane(let paneId, _, _): if model.pane(paneId) == nil {
model.pendingConfirmation = nil }` and `case .closeTabs(let tabIds, _, _): if
tabIds.isEmpty || tabIds.contains(where: { tabById($0, in: model) == nil }) { ... }`.
The projection then restates a subset:
`case .closeOtherPanes(let retainedPaneId, let impact): guard model.pane(retainedPaneId)
!= nil else { return nil }` and `case .closeTab(let tabId, ...): guard tabById(tabId,
in: model) != nil else { return nil }`.

**Ideal fix.** Delete the three `guard ... else { return nil }` lines from
`desiredConfirmation`, leaving it a total function of `model.pendingConfirmation`. The
reducer stays the single writer of the retraction rule, and the projection's `nil`
regains one meaning: no transaction is pending.

**By construction.** "The panel is hidden while a confirmation is still pending" stops
being reachable, because the projection has no path to `nil` other than an absent
transaction.

**Cheaper fallback.** Add the two missing guards instead, so the six arms are at least
consistent. That removes the drift but keeps two copies of the rule and keeps the
model-versus-screen disagreement the projection guards create.

**Verification.** The reducer suite already asserts retraction (close the confirmed
pane through another path and expect `model.pendingConfirmation == nil`). Add the
mirror assertion that whenever `model.pendingConfirmation != nil` after `update`,
`desiredConfirmation(in: model) != nil` -- a behavioral invariant over the pair, not a
structural one.

**Risk.** `.deleteGroup` reads `group.name` and the destination group's name out of the
live model. Its reducer arm re-emits rather than clearing when the destination
disappears, so the guard there must be traced once more before removal; if it turns out
to be load-bearing, keep that one arm and say why.

**Vetted.** I opened `Update.swift:20-26` (the unconditional `defer`, which does call
`reconcilePendingConfirmation(&model, env: env)`), `Update.swift:1629-1664`
(`reconcilePendingConfirmation`, all six arms as quoted), `Update.swift:1524-1547`
(`emitDeleteGroupConfirmation`) and `Projections.swift:1419-1525`
(`desiredConfirmation`). Every quote is exact, and the drift the auditor names is real:
the projection guards `.closeOtherPanes` (line 1451), `.closeTab` (line 1471) and
`.deleteGroup` (lines 1503-1508), and guards neither `.closePane` nor `.closeTabs`.

I traced the `.deleteGroup` risk the auditor flagged. `emitDeleteGroupConfirmation`
either clears `pendingConfirmation` outright or writes one whose `groupId` and
`destinationGroupId` are both read out of the live `model.groups` in the same statement,
so the re-emit path cannot leave a stale destination standing. Combined with the defer
running after every message, and with `pendingConfirmation` defaulting to `nil`
(`Model.swift:635`) so a restored model never carries one, all three projection guards
are dead: `desiredConfirmation` is only ever called from `Reconcile.swift:100`, on a
model the reducer has already reconciled.

**Correction.** The "model and screen disagree" symptom is unreachable, so this is
tidying, not a defect -- impact 1. The ideal fix also does not compile as written for
`.deleteGroup`: that arm's guards are not defensive, they are how the projection obtains
`group.name` and `destination.name` for its copy. Making it total means freezing both
names into `DeleteGroupConfirmation` the way `.closeTab` already freezes `tabTitle`, then
deleting the guard. That is the version to write down -- it is a better fix than the
auditor's, because it removes the projection's last read of live model state and makes
the panel's copy immune to a rename while it is open. The other two guards are plain
deletions.

**Conflicts with.** [UPDATE-3](UPDATE.md#update-3) ("Fold `ConfirmationSubject` into
`ConfirmationKind`") rewrites `ConfirmationKind`'s four close cases into a single
`case close(target:title:impact:quitAuthorized:)`, which rewrites the same switch in
`desiredConfirmation` and the same switch in `reconcilePendingConfirmation`. These cannot
be implemented independently; UPDATE-3 should land first and MODEL-5 becomes a two-line
follow-up on the result. MODEL-5 also depends on `update()`'s `defer` staying
unconditional -- [UPDATE-7](UPDATE.md#update-7) proposes making that sweep cheaper, which
is compatible, but any change that makes it conditional would revive the guards.

<a id="model-6"></a>

#### MODEL-6. Walk the tree in the per-pane projections instead of materializing `allPanes` three times a sweep

`cost` &middot; impact 1, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredFocusBorders`,
`lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredSearchOverlays`,
`lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredPaneConfig`,
`lib/DanTermCore/Sources/DanTermCore/Model.swift#AppModel.allPanes`

**Problem.** Three of the per-pane projections iterate `model.allPanes`, which flattens
every tab's split tree into a new array of whole `PaneModel` values -- each one copying
an optional `SessionModel` of six strings, a `todos` array and a `PaneLiveState`
dictionary. Every reconcile sweep therefore builds and throws away three full pane
arrays, at a size set by how many panes exist rather than by what changed. The
non-allocating shape already exists and is already used one function away:
`desiredPaneToolbar` walks `forEachPane(in: tab.paneTree.root)`.

**Evidence.** `Model.swift#AppModel.allPanes`:
`groups.flatMap { $0.tabs.flatMap { panesInNode($0.paneTree.root) } }`, where
`ModelOperations.swift#panesInNode` is `var result: [PaneModel] = []; forEachPane(in:
node) { result.append($0) }; return result`. The three callers are
`for pane in model.allPanes` in `desiredFocusBorders`, `desiredSearchOverlays` and
`desiredPaneConfig`. `desiredReportedTerminalFocus` does the id-array version:
`Dictionary(uniqueKeysWithValues: model.allPaneIds.map { ... })`. Contrast
`desiredPaneToolbar`, which needs the owning tab anyway and so already reads
`for group in model.groups { for tab in group.tabs { forEachPane(in: tab.paneTree.root)
{ pane in ... } } }`.

**Ideal fix.** Give the three projections the same `forEachPane` walk. `desiredFocusBorders`
and `desiredPaneConfig` need nothing per-tab beyond what they already resolve, and
`desiredSearchOverlays` only reads `pane.live.search`. `AppModel.allPanes` then survives
for the two callers that genuinely want a list (`desiredConfirmation`'s quit rollup),
or disappears entirely.

**Cheaper fallback.** None -- the ideal fix is a three-line edit per projection.

**Verification.** Cost finding, so the deciding observable, not a result: no workload on
the ladder drives reconcile sweeps at rate, so a `just benchmark-sample btop-scroll 20`
profile is what would show `panesInNode` / array-growth frames under
`reconcile`. The code-level quantity is three array allocations plus 3N `PaneModel`
copies per sweep, N = live pane count. Behavior is carried by the existing projection
tests, which assert the returned dictionaries key-for-key.

**Risk.** None identified: the walk order is the same left-to-right tree order, and all
three projections build a dictionary whose contents do not depend on order.

**Vetted.** I opened `Model.swift:681-690` (`allPanes`, `allPaneIds`),
`ModelOperations.swift:171-175` (`panesInNode`), and the three call sites --
`Projections.swift:574` (`desiredFocusBorders`), `:708` (`desiredSearchOverlays`), `:754`
(`desiredPaneConfig`) -- plus `desiredPaneToolbar` at `:635-644`, which does already walk
`forEachPane(in: tab.paneTree.root)` inside a group/tab loop because it needs `hasSplits`
per tab. Every quote is exact, and the fourth `allPanes` reader is
`desiredConfirmation`'s quit rollup at `:1432`, which only runs while a quit panel is
pending. The proposed edit works: `desiredFocusBorders` needs only the selected tab,
`desiredSearchOverlays` reads only `pane.live.search`, and `desiredPaneConfig` needs no
per-tab fact.

The cost is smaller than the finding implies, for the same reason as MODEL-3: sweeps run
once per non-coalescing message and at most once per 75 ms otherwise
(`AppRuntime.swift:233`), so this is three small array builds on a discrete user action,
not a per-frame charge.

**Correction.** This is not news to the codebase, and the finding should say so. The
comment directly above these projections (`Projections.swift:483-489`) names the same
three walks and points at `docs/design/2026-05-27-model-driven-view-reconciliation.md`,
whose "Projection Scan Cost" section accepts the cost explicitly and closes with "Do not
precompute further reconcile inputs speculatively ... especially `allPanes`". MODEL-6 is
not what that sentence forbids -- it removes a materialization rather than adding a
shared context bag, so it is compatible with the ADR's rule and does not need a
measurement to justify a three-line-per-site edit. But it is a tidy-up worth one point,
not a cost win, and if it lands the stale half of the `:483` comment ("pane toolbar ...
still walk `model.allPanes`", which stopped being true when `desiredPaneToolbar` moved to
`forEachPane`) should be corrected in the same change.

**Conflicts with.** [CHROME](CHROME.md)'s dropped item on the same `allPanes` scans,
which declines them citing that ADR section. No implementation conflict -- that lane
proposes no edit -- but the two lanes should not both be read as independent evidence.

<a id="model-7"></a>

#### MODEL-7. Delete `AlertTab` and read the alert filter off the model's own flag

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#AlertTab`,
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#filteredAlerts`,
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#alertsEmptyText`,
`lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredAlertsPopover`

**Problem.** `AlertTab` is a two-case enum with `Int` raw values that exists only inside
one function. `model.showAllAlerts` is the authority; the projection converts it to an
`AlertTab`, hands that to two single-caller helpers, and then reports the original
`Bool` back out in the projection anyway. The raw values are read nowhere -- they are a
leftover index vocabulary from a segmented control that no longer exists.

**Evidence.** `ModelOperations.swift`: `enum AlertTab: Int { case unread = 0, history = 1 }`.
Every non-test reference in the tree is inside `Projections.swift#desiredAlertsPopover`:
`let tab: AlertTab = model.showAllAlerts ? .history : .unread`, `let displayed =
filteredAlerts(model.alerts, tab: tab)`, `emptyText: displayed.isEmpty ?
alertsEmptyText(tab: tab) : nil`, and two lines later `showAll: model.showAllAlerts`.
`grep -rn "AlertTab"` over the non-test tree returns only those three lines plus the two
helper definitions; no site reads `.rawValue`.

**Ideal fix.** Inline both helpers against `model.showAllAlerts`
(`let displayed = model.showAllAlerts ? model.alerts : model.alerts.filter(\.isUnread)`,
and the two empty strings picked by the same flag) and delete `AlertTab`,
`filteredAlerts` and `alertsEmptyText`.

**By construction.** One fewer vocabulary that has to be kept in step with
`showAllAlerts`; the flag becomes the only spelling of "which alerts are shown".

**Cheaper fallback.** None -- the ideal fix is a deletion.

**Verification.** The existing `desiredAlertsPopover` cases in `ProjectionsTests.swift`
(they set `model.showAllAlerts` and assert `rows` and `emptyText`) carry this unchanged;
that is the whole behavioral surface.

**Risk.** None. The enum is not `public` and does not cross a module boundary.

**Vetted.** I opened `ModelOperations.swift:955-969` (`AlertTab`, `filteredAlerts`,
`alertsEmptyText`) and `Projections.swift:461-478` (`desiredAlertsPopover`). Every quote
is exact. `grep` for `AlertTab|filteredAlerts|alertsEmptyText` over the non-test tree
returns exactly the five lines the auditor names -- three in `desiredAlertsPopover`, two
definitions -- and no site anywhere reads `.rawValue` or constructs from one, so the
`Int` raw values are genuinely vestigial. `desiredAlertsPopover` does report
`showAll: model.showAllAlerts` two lines after converting the same flag into an
`AlertTab`, as described.

**Correction.** One amendment to the Verification. `ProjectionsTests.swift:140`
("desiredAlertsPopover filters unread vs show-all rows") does carry the behavior, but
`UpdateAlertTests.swift:862-916` holds four tests that call `filteredAlerts` and
`alertsEmptyText` directly with an `AlertTab` argument, so the deletion removes those
too. That is the right outcome under this repo's own bar -- they assert the shape of
private helpers rather than observable behavior -- but the commit should delete them
knowingly rather than discover them, and should confirm the popover cases already cover
both empty strings before the helper tests go.

**Conflicts with.** Nothing. No other lane file names `AlertTab`, `filteredAlerts` or
`alertsEmptyText`.

#### Dropped (MODEL)

- `ScrollbarMath.scrollbarOffsetY`'s `total - offset - len` UInt64 subtraction:
  `Terminal.swift#scrollProjection` sets `topRow = min(..., max(0, totalRows - rowCount))`
  and `windowRows = rowCount`, so `topRow + windowRows <= totalRows` holds and the
  subtraction cannot underflow. Same verdict as the prior audit.
- An emptied **Theme** field writing `"theme": {"default": ""}` while
  `DanTermConfigDocument.projectConfig` rejects an empty name on read: not reachable.
  `app/PreferencesPanel.swift` sets `themeField.isEditable = false`, and the only writer
  is the picker sheet, which emits catalog names. The same asymmetry is live for
  `fontSize` and is reported as MODEL-2.
- `paneStripPlan`'s `Int(floor((width + spacing) / slot))` trapping when `slot == 0`:
  `slot = chipWidth + spacing` and the one caller passes `chipWidth: ChipArtwork.paneRowSize`
  with `spacing: 3`, both positive constants, so the division cannot produce infinity.
- `ConfirmationKind` and `ConfirmationSubject` as two parallel vocabularies for the same
  close subjects (`emitConfirmation` maps subject to kind, `desiredConfirmation` maps it
  back for `closeConfirmationCopy`): the split is load-bearing. `closeOtherPanes` has no
  `quitAuthorized` and `closeTab` carries a frozen title, so a single
  `.close(subject:impact:quitAuthorized:)` would reintroduce states the current pair
  makes unrepresentable. Prior audit's MODEL-1 landed this shape deliberately.
- `AppModel.updateSession`'s `guard var session = pane.session else { return (pane.id,
  false) }`: dead, because the predicate it runs under is `$0.session?.id == id`. One
  line, no behavior, not worth a finding.
- `TabTodo.swift#tabTodoTargetId` -- a private one-line function that returns
  `target.id`, called twice. Noise, below the reporting bar.
- `SidebarProjection`'s `isSingleGroupMode`, `canDeleteGroups` and
  `singleGroupDropTargetId` all derived from `model.groups.count`: three flags for one
  fact, but the projection is deliberately the complete render input and the derivation
  is stated once, in `desiredSidebar`. No drift possible.

#### Still live from the closed 2026-08-18 audit

- [LOOKUP-6](../2026-08-18-construction-audit.md#lookup-6) ("Resolve each sidebar row's
  chrome once per sweep") is marked *closed without a code change* and every symptom it
  names is still in the tree: `desiredSidebar` walks each tab four times through
  `tabDisplayTitle`, `tabSubtitle` (via `windowTitle`), `tabChipKind` and
  `tabPaneChips`, and `ModelOperations.swift#abbreviateHome` still evaluates
  `NSHomeDirectory()` per call as its default argument. It owns that item; I am not
  re-reporting it.

#### Pruned (MODEL)

None. All seven findings survived vetting as filed. Two needed their claims rewritten
rather than removed: MODEL-1's defect is in the pure diff but its on-screen symptom is
not reachable today, and MODEL-2's correctness claim is void because
`app/PreferencesPanel.swift:675` already normalizes an emptied field to `nil` -- what
survives there is a one-point altitude point about where that rule is written.


### Area: The reducer, messages, and commands (`UPDATE`)

_Scope: `lib/DanTermCore/Sources/DanTermCore/Update.swift`, `Msg.swift`, `Command.swift`, `CoreEnvironment.swift`, `PaneLifecycleReducer.swift`, `PaneLifecycleConsumers.swift`, `PaneLifecycleIpcAdapter.swift`, `ReconcileFollowUps.swift`, `AlertPresentation.swift`, `TerminalBackendBoundary.swift`, `TodoInputCommand.swift`, `KeybindingPreferences.swift`, plus the confirmation / close-impact / todo / tab-state helpers in `Model.swift` and `ModelOperations.swift` that the reducer arms call. Cross-checked against `app/AppRuntime.swift`, `app/IpcServer.swift`, `app/SwiftTerminalSessionView.swift`, `app/TerminalSession.swift` for producers and consumers, and against `lib/DanTermCore/Tests/DanTermCoreTests/` for what is pinned._

**The auditor's read on the area.** The large structure is genuinely good: `Command` carries no projection cases, the `defer` block is a real chokepoint, `ConfirmationKind` is now an enum that carries exactly its own payload (MODEL-1/REDUCE-1 landed), `reconcileFocusedPaneAlerts` is in the sweep (REDUCE-3 landed), and `AgentActivityState` couples the wait generation to the `waiting` case so a generation without a wait cannot exist. The remaining defects share one shape: a rule that has an owner, restated by hand somewhere it does not need to be. A pane-teardown ritual written five times, a close-subject vocabulary written twice, an alert-suppression rule written twice with the two copies disagreeing, and a "what survives a restore" rule written in three places and silently short of the fields it needs. Two more are plain subtraction. I did not audit `IpcDispatch.swift`, `Projections.swift`, `Persistence.swift`, `PaneTapeStreamState.swift`, or `SidebarItemStore.swift` beyond the declarations reducer arms call -- they belong to other lanes. I read `KeybindingPreferences.swift#updateKeybindingPreferences` end to end and dropped it: the `model.preferencesDraft!` force-unwraps are all guarded at the top of the function and no invalid editor state is reachable through them.

<a id="update-1"></a>

#### UPDATE-1. Let one rule decide whether a focused pane's alert is suppressed, so an agent waiting for input notifies a backgrounded app

`correctness` &middot; impact 4, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#update` (the `.sessionReport` / `.agentActivityChanged(_, .waiting)` arm), `lib/DanTermCore/Sources/DanTermCore/Update.swift#paneAlertCommands`

**Problem.** "Do not alert for the pane the user is looking at" is one rule, and `paneAlertCommands` owns it: it suppresses only when the app is *active* and the pane is the selected tab's focused pane. The agent-waiting arm restates the rule without the `isAppActive` half, so it suppresses whenever the pane is focused, active or not. The result is that the highest-value notification DanTerm can send -- "your agent is waiting for you" -- is the one notification you never get, because it fires exactly when you have gone to another app and left that pane focused. An OSC 9 notification from the same pane in the same second does deliver.

**Evidence.** The arm, `Update.swift:564-577`:

```swift
case .agentActivityChanged(_, .waiting):
    guard mutation.didChange else { return [] }
    if case .attached(_, .waiting) = priorAgent { return [] }
    guard selectedTab(in: model)?.paneTree.focusedPaneId != mutation.paneId else { return [] }
    let presentation = alertPresentation(...)
    return paneAlertCommands(model: &model, paneId: mutation.paneId, kind: .desktopNotification, ...)
```

The rule's owner, `Update.swift#paneAlertCommands`:

```swift
guard model.pane(paneId) != nil, tabForPane(paneId, in: model) != nil else { return [] }
if model.isAppActive, let tab = selectedTab(in: model), tab.paneTree.focusedPaneId == paneId {
    return []
}
```

The arm's guard is strictly stronger, so the owner's guard is dead for this caller. Both behaviors are pinned, side by side, in the same suite -- and the second test's own rationale argues against the first:

`lib/DanTermCore/Tests/DanTermCoreTests/UpdateSessionEventTests.swift:723` -- `@Test("agent waiting stays silent for the focused pane while the app is inactive")` sets `model.isAppActive = false` and asserts `model.alerts.isEmpty`.

`lib/DanTermCore/Tests/DanTermCoreTests/UpdateSessionEventTests.swift:742` -- `testDesktopNotificationOnFocusedPaneWhileInactiveCreatesAlertAndNotification`, whose preamble reads "a backgrounded app cannot rely on focused-pane visibility, so OSC notifications must keep their backing alert for notification-click navigation." That reason applies to an agent wait word for word.

This is a decision to revisit rather than an oversight, in the sense of the 2026-08-18 audit's "pinned by a test" category. Nothing in the tree says why the two kinds should differ.

**Ideal fix.** Delete the arm's `guard selectedTab(in: model)?.paneTree.focusedPaneId != mutation.paneId` line. `paneAlertCommands` is already the single admission gate for every pane alert; with the copy gone there is one statement of the suppression rule and every alert kind gets the same answer. Rewrite the pinning test to assert the opposite (a wait raised on the focused pane while inactive produces one unread alert and one `.sendNotification`), and keep the active-app case pinned exactly as it is.

**By construction.** A second, disagreeing definition of "the user can see this pane" stops existing, so a future alert kind cannot pick up the wrong one. The `AlertKind` throttle in `throttledNotification` is untouched and still keeps a wait storm to one banner per second.

**Cheaper fallback.** Add `model.isAppActive` to the arm's guard and leave both copies standing. Same user-visible behavior, but the rule is still written twice and the next alert source has two candidates to copy from.

**Verification.** `swift test --package-path lib/DanTermCore --filter UpdateSessionEventTests`. Behavioral test: `model.isAppActive = false`; attach an agent to the selected tab's focused pane; send `.sessionReport(.agentActivityChanged(session:activity: .waiting))`; assert the returned commands contain one `.sendNotification` for that pane and `model.alerts.count == 1` with `isUnread`. Keep the existing active-app leg green: with `isAppActive = true` the same report must return no commands and add no alert.

**Risk.** A user who leaves an agent pane focused, backgrounds DanTerm, and runs an agent that reports `waiting` repeatedly gets more banners than today. `throttledNotification` already caps that at one per pane per kind per second, and the "repeat of an already-visible wait raises none" guard above it stays. This is a deliberate behavior change and the user should confirm it.

**Vetted.** I opened both arms. `Update.swift:564-583` is the agent-waiting arm and carries `guard selectedTab(in: model)?.paneTree.focusedPaneId != mutation.paneId else { return [] }` with no `isAppActive` term, exactly as quoted. `Update.swift:2087-2090` is `paneAlertCommands`, and its admission gate is `guard model.pane(paneId) != nil, tabForPane(paneId, in: model) != nil` followed by `if model.isAppActive, let tab = selectedTab(in: model), tab.paneTree.focusedPaneId == paneId { return [] }`. The two predicates resolve the focused pane through the same two calls, so the arm's guard does subsume the owner's for this caller. Both cited tests exist verbatim at `UpdateSessionEventTests.swift:723` and `:742`, including the preamble sentence the finding quotes. I also confirmed the counterpart delivery claim: `.sessionNotification` (`Update.swift:723-735`) and `.sessionBell` (`:711-720`) both route straight into `paneAlertCommands` with no extra focus guard, so an OSC 9 from the same pane in the same second does raise an alert and a notification while the app is inactive. `model.isAppActive` has only two writers, `.appBecameActive` and `.appResignedActive` (`Update.swift:792`, `:796`), so the inactive-and-focused state is ordinary, not a transient.

**Correction.** Call this a policy decision the user must settle, not a defect the plan can land on its own judgement. The ideal fix and the cheaper fallback change user-visible behavior identically -- both start delivering a wait banner on a focused pane while DanTerm is inactive -- so there is no "fix the duplication without changing behavior" option, and doing nothing means writing down why waits are silent where bells and OSC 9 are not. The score stands because the harm is concrete for this repo's own workflow, but the plan must put the question to the user before the test is rewritten. One detail the prose omits: `paneAlertCommands` calls `markAlertsReadForPane` before it inserts, and `reconcileFocusedPaneAlerts` marks the focused pane read on the next message once the app is active again -- so the lasting effect of the change is the banner, not a badge that piles up.

**Conflicts with.** None. No other lane file names `paneAlertCommands`, the agent-waiting arm, or `reconcileFocusedPaneAlerts`. [UPDATE-7](#update-7) reads `reconcileFocusedPaneAlerts` but proposes no edit to the suppression rule.

<a id="update-2"></a>

#### UPDATE-2. Prune a departing pane's pending work from one pass instead of repeating the ritual at five teardown sites

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#update` (`.sessionCreationFailed`), `lib/DanTermCore/Sources/DanTermCore/Update.swift#deleteGroupBody`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#closePaneBody`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#closeOtherPanesBody`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#closeTabRemoval`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#rejectPendingIpcWork`

**Problem.** Whenever a pane leaves the tree, three things must happen: its pending IPC work is rejected, its alerts are dropped from the global feed, and any popover anchored to it is closed. That ritual is hand-written at five sites and the three sites carry different subsets. Every new removal path has to remember all three, and the code already shows what forgetting looks like -- two of the five omit the popover half.

**Evidence.** The five sites, all in `Update.swift`: `.sessionCreationFailed` (lines 765-773), `deleteGroupBody` (1576-1581), `closePaneBody` (1708-1716), `closeOtherPanesBody` (1738-1746), `closeTabRemoval` (1984-1998). Three carry the popover clear:

```swift
removeAlertsForPane(paneId, in: &model)
if model.todoPopover == .pane(paneId) {
    model.todoPopover = nil
}
```

and two do not. The two that omit it are correct anyway, which is the real finding: `reconcileTodoPopover` already runs in `update()`'s `defer`, and `ModelOperations.swift#todoPopoverAnchorIsEligible` returns false for `.pane(paneId)` unless `containsPane(selectedTab.paneTree.root, paneId)` -- so a popover whose pane left the tree is retracted by the sweep on the very same message. All four popover lines (three `.pane`, one `.tab` in `closeTabRemoval`) are dead work restating what the chokepoint already decides. The alert half is in the same position: `AlertModel.paneId` is non-optional and `model.allPaneIds` is the authority on which panes exist, so "an alert whose pane is gone" is answerable without being told.

**Ideal fix.** Make the reconcile chokepoint able to return commands, and give it a pane-existence pass. Restructure `update()` from `defer { ... }` to `let commands = updateBody(&model, msg, env: env); return commands + reconcileModel(&model, env: env)`, and add one pass that, for every entry in `model.alerts`, `model.pendingSessionCreations`, and `model.pendingInputSubmissions` whose pane is not in `model.allPaneIds`, drops it and (for the two pending maps) emits the `.ipcError`. All five hand-written rituals delete, along with the four popover lines and `rejectPendingIpcWork` itself. Note the pass must key on `model.allPaneIds`, not on one tab -- `.movePaneToTab` and `.movePaneToNewTab` move a pane between tabs and must not trigger teardown, and the whole-model authority gets that right for free.

**By construction.** "A removal path forgot one of the three" stops being expressible: a pane that is not in the tree cannot own an alert, a pending creation, or a pending input, because the only thing that decides ownership is the tree itself.

**Cheaper fallback.** One `tearDownPanes(_ paneIds: [PaneId], in: &model, cause:) -> [Command]` helper called by all five sites. It removes the drift but keeps the "did you remember to call it" obligation on every future removal path, which is the class the ideal deletes. It also keeps the four dead popover lines unless they are deleted separately.

**Verification.** `swift test --package-path lib/DanTermCore`. Behavioral tests that must stay green: `UpdateIpcTests`' pending-creation rejection on pane close and on `.sessionCreationFailed` (both wordings), and the alert-feed pruning in `UpdateAlertTests`. New test for the class: register a pending `pane.input` submission against a pane, delete the pane's whole group through `.deleteGroup(id:moveTabs:false)`, and assert an `.ipcError` comes back for that request -- and a second test that `.movePaneToTab` moving that pane to another tab emits no error and keeps the submission pending.

**Risk.** The `PendingIpcRejectionCause` distinction (`"pane closed before its process started"` vs `"pane process failed to start"`) is lost unless the failure cause is carried some other way -- the existence pass sees only that the pane is gone. That wording is in IPC error text, which `integrations/danterm/SKILL.md` does not pin, but it is user-visible. Say so in the plan rather than reintroducing a per-pane cause field, which would be exactly the mirror this fix removes. Turning `defer` into an explicit tail also changes what happens if an arm returns early -- audit every `return` in `update()` when making the change.

**Vetted.** I grepped every `todoPopover`, `removeAlertsForPane` and `rejectPendingIpcWork` occurrence in `Update.swift` and found exactly the five sites named: `.sessionCreationFailed` (749-787), `deleteGroupBody` (1571-1588), `closePaneBody` (1708-1716), `closeOtherPanesBody` (1738-1746), `closeTabRemoval` (1984-1999). Three carry a `.pane` popover clear and `closeTabRemoval` carries a fourth, `.tab`, line; `.sessionCreationFailed` and `deleteGroupBody` carry none. The dead-work claim holds: `ModelOperations.swift:1135-1155` is `todoPopoverAnchorIsEligible` / `reconcileTodoPopover` as quoted, the `.pane` arm requires `containsPane(selectedTab.paneTree.root, paneId)` and the `.tab` arm requires `tabId == selectedTabId`, and `reconcileTodoPopover` sits in the unconditional `defer` at `Update.swift:20-26`. A popover can only be anchored inside the selected tab in the first place, so every removal path either leaves the anchor outside the selected tab (the explicit line was already false) or empties it (the sweep retracts on the same message). All four lines are dead, including the `.tab` one, because `reconcileTabState` runs first in the same `defer` and repairs `selectedTabId` away from a closed tab. I also confirmed `.movePaneToTab` (300-341) and `.movePaneToNewTab` (343-400) remove and re-attach the pane inside one body with no nested `update()` call in between, so a defer-time existence pass would not see them as teardown -- the auditor's note about keying on `model.allPaneIds` is right.

**Correction.** The ideal fix does not work as written for `pendingSessionCreations`, and the finding overstates what is at stake. `PendingSessionCreation` is `{ requestId, result }` (`Model.swift:76-79`) -- it carries no `PaneId`, and the map is keyed by `SessionId`. `rejectPendingIpcWork` only reaches it by walking `model.pane(paneId)?.session?.id` *while the pane is still in the tree*, which is why `deleteGroupBody` runs the rejection before `model.groups.remove(at: idx)`. A pass that runs after removal has no pane to walk from, so the pass has to be a *session*-existence pass for that map (`model.pane(owning: sessionId) == nil`) and a pane-existence pass for `pendingInputSubmissions` and `alerts` -- two authorities, not the one the prose claims. That is still writable (`deferCreationReply`, `IpcDispatch.swift:535-555`, only ever stores an entry for a pane already in the tree, so no legitimate in-flight state looks dead), but it is a different design and the plan must say which authority answers for which map.

Second, there is no live bug here. The auditor says so himself about the popover half, and the alert and IPC halves are complete at all five sites. This is drift-proofing, not repair, so impact drops to 2. Third, the pass adds an `model.allPaneIds` walk plus a scan of up to 100 alerts to *every* message, which is the same per-message budget [UPDATE-7](#update-7) argues is already too expensive -- the plan cannot claim both. The cheaper fallback (one `tearDownPanes` helper) delivers most of the drift protection at none of that cost, and should be the recommendation unless the probe in UPDATE-7 shows the sweep budget has room.

**Conflicts with.** [UPDATE-7](#update-7) -- directly opposed on the same `defer` block: UPDATE-2 adds a per-message pass, UPDATE-7 wants the per-message passes cheaper. [MODEL-5](MODEL.md#model-5) states that it depends on `update()`'s `defer` staying unconditional; UPDATE-2 restructures that `defer` into an explicit tail, so the two must be sequenced and MODEL-5's dependency re-checked afterwards. [UPDATE-3](#update-3) also edits `deleteGroupBody`'s neighbourhood but not the same statements.

<a id="update-3"></a>

#### UPDATE-3. Fold `ConfirmationSubject` into `ConfirmationKind` so the close vocabulary is declared once

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#ConfirmationSubject`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#ConfirmationKind`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#emitConfirmation`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#closeImpact`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#closeSubjectHasGrown`

**Problem.** The same closed vocabulary -- pane, other-panes, tab, tabs -- is declared twice, once as `ConfirmationSubject` and once as four of the six `ConfirmationKind` cases, and the reducer translates between them in both directions on every confirmation. This is the half of REDUCE-1 / MODEL-1 (`docs/scratch/2026-08-18-construction-audit.md#reduce-1`) that did not land: that finding's ideal explicitly said "Split `ConfirmationSubject` so `CloseSubject` holds only pane/tab/tabs", and what shipped kept both types side by side. The cost shows up as two `return false` arms for combinations that cannot occur.

**Evidence.** `ModelOperations.swift#emitConfirmation` maps subject to kind:

```swift
switch subject {
case .pane(let paneId):
  kind = .closePane(paneId: paneId, impact: impact, quitAuthorized: quitAuthorized)
case .otherPanes(let retainedPaneId):
  kind = .closeOtherPanes(retainedPaneId: retainedPaneId, impact: impact)
...
```

and `Update.swift#closeSubjectHasGrown` maps it straight back, plus an arm for the two kinds that are not close subjects at all:

```swift
case .closePane(let paneId, let impact, _):
    subject = .pane(paneId)
    snapshot = impact
...
case .quit, .deleteGroup:
    return false
```

`answerPendingConfirmation` pays the same tax in reverse: each close arm re-dispatches its own request message (`.requestClosePane`, `.requestCloseOtherPanes`, `.requestCloseTab`, `.requestCloseTabs`) after `closeSubjectHasGrown`, four near-identical blocks.

**Ideal fix.** Delete `ConfirmationSubject`. Give `ConfirmationKind` a nested `Close` enum that names the four close targets, and make the close cases one case: `case close(target: Close, title: DisplayLine?, impact: CloseImpact, quitAuthorized: Bool)`. `closeImpact(for:)` takes `ConfirmationKind.Close`, `emitConfirmation` builds the kind directly with no translation, and `closeSubjectHasGrown` takes the `Close` value it is handed. Both `return false` arms disappear because a quit or delete-group confirmation can no longer be passed to a function that only accepts close targets.

**By construction.** "Ask whether a quit confirmation's subject has grown" stops being a call you can write. The parameter narrows to exactly the set the callee accepts, which is what removes the guard rather than rewording it.

**Cheaper fallback.** Keep both types but give `ConfirmationKind` a `var closeSubject: ConfirmationSubject?` accessor so the translation is written once. The two vocabularies still drift independently, and adding a fifth close target still means editing two enums.

**Verification.** `swift test --package-path lib/DanTermCore --filter CloseConfirmationTests` plus `CloseOtherPanesTests`. Every existing behavioral assertion must hold unchanged: a close whose subject grew while the panel was open re-prompts instead of closing; a quit confirmation answered with confirm terminates; a delete-group confirmation answered with the plain confirm answer does nothing. The last one becomes a compile-time fact rather than a runtime `default: return []`.

**Risk.** Touches the app-side confirmation panel, which reads the kind to build its copy (`closeConfirmationCopy` switches on the subject). The `.otherPanes` branch of that function has its own copy rules and must be re-pointed at the new target enum.

**Vetted.** Every quote is in the tree. `ConfirmationSubject` is the four-case enum at `Model.swift:522-527`; `ConfirmationKind` is the six-case enum at `Model.swift:562-574`. `emitConfirmation` (`ModelOperations.swift:795-825`) maps subject to kind in the four arms quoted, `closeSubjectHasGrown` (`Update.swift:1594-1624`) maps it straight back and closes with `case .quit, .deleteGroup: return false`, and `closeImpact(for:)` (`ModelOperations.swift:762-793`) takes a `ConfirmationSubject`. `answerPendingConfirmation` (`Update.swift:1408-1475`) does carry four close arms, each re-dispatching its own request message after `closeSubjectHasGrown`. The prior-audit citation is accurate: `docs/scratch/2026-08-18-construction-audit.md:3187` reads "Split `ConfirmationSubject` so `CloseSubject` holds only pane/tab/tabs", and that half did not ship. Two small imprecisions: it is one `return false` arm covering two cases, not two arms; and `ConfirmationSubject` has five non-test readers, not the three the Files line names -- `Update.swift:162`, `:252`, `:1348`, `:1359` build subjects at the call sites, and `closeConfirmationCopy` (`ModelOperations.swift:850`) takes one, reached from four places in `Projections.swift` (1437, 1452, 1472, 1486).

**Correction.** The ideal fix as written is a regression in representability and must be restated. `case close(target: Close, title: DisplayLine?, impact: CloseImpact, quitAuthorized: Bool)` gives every close target an optional title and a `quitAuthorized` slot, but today `closeOtherPanes` has neither and `closeTab` has a non-optional `DisplayLine` -- so the flattened case newly admits "a pane close carrying a tab title" and "an other-panes close that authorizes quit", which is precisely the class MODEL-1 removed. The MODEL lane dropped this same finding for that reason (`MODEL.md:704-709`) and the objection is correct on the facts. The version to write down is `ConfirmationKind.close(Close)` with `Close` a nested enum whose four cases carry their own payloads unchanged: the payloads stay exact, `ConfirmationSubject` still deletes, `closeImpact(for:)` and `closeSubjectHasGrown` narrow to `Close` so the `.quit, .deleteGroup: return false` arm goes, and both mapping switches go. What does *not* happen is the collapse the prose promises: `answerPendingConfirmation`'s four blocks call four different bodies (`closePaneBody`, `closeOtherPanesBody`, `closeTabBody`, and the inline batch), so they stay four blocks. With the real payoff at "delete a four-case enum, two translation switches and one dead arm", this is impact 2.

**Conflicts with.** [MODEL-5](MODEL.md#model-5) -- it declares the conflict from its side and the sequencing it names is right: UPDATE-3 rewrites the same switch in `desiredConfirmation` and the same switch in `reconcilePendingConfirmation`, so UPDATE-3 lands first and MODEL-5 becomes a follow-up. Also note MODEL's Dropped list argues against doing UPDATE-3 at all; the corrected nested-enum form is the version that answers that objection.

<a id="update-4"></a>

#### UPDATE-4. Separate the process-scoped half of `AppModel` from the session half so a restore cannot drop it

`correctness` &middot; impact 3, confidence 5 &middot; effort large &middot; rescored

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#update` (the `.restoreSession` arm), `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#carryingLiveAppearance`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#AppModel`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#validateAndBuildDetailed`

**Problem.** `.restoreSession` assigns a whole new `AppModel` over the live one. The model built from a snapshot sets only two fields -- `AppModel(groups: parsedGroups, selectedTabId: selectedTabId)` -- so every other field takes its default. The rule for what survives a restore is then written in three unconnected places: the runtime carries two fields before dispatching, the arm carries two more, and everything else silently resets. Two fields that should survive do not, and the field list will grow again the next time someone adds process-scoped state.

**Evidence.** The arm, `Update.swift:919-926`:

```swift
case .restoreSession(var restored):
    restored.noticeQueue = model.noticeQueue
    restored.isAppActive = model.isAppActive
    model = restored
    return [.installStagedRestoreSession]
```

`ModelOperations.swift#carryingLiveAppearance` carries `config` and `resolvedFontFamily` at the call site. `Model.swift:1186` is the only `AppModel(` construction on the restore path: `model: AppModel(groups: parsedGroups, selectedTabId: selectedTabId)`. Two live consequences:

*Tailnet status.* `AppModel.tailnetStatus` defaults to `.disabled(reason: "no tailnet listener was started")`. `app/AppRuntime.swift:334` dispatches `.tailnetStatusChanged(server.initialTailnetStatus)` inside `init`, before any restore. Both restore entry points run later: `importState(from:)` at `AppRuntime.swift:1308` from the File menu, and `bootstrapFromValidatedRestore` at `AppRuntime.swift:1452`, reached from the `.resolveLaunchRestore` command through `DispatchQueue.main.async`. The restore wipes the value, and `app/IpcServer.swift:324` never re-sends it: `guard status != tailnetStatus else { return }` -- the server's own copy is unchanged, so there is no transition to publish. After any recovery restore or import, `danterm tailnet status` and the preferences "Listener" row report no listener for the rest of the process's life.

*Pending IPC work.* `pendingSessionCreations` and `pendingInputSubmissions` are dropped with no reply. `.runtimeWillShutdown` shows what the same situation is supposed to produce -- an `.ipcError` per waiting request -- and the restore path produces nothing, so a `danterm tab new` or `danterm pane input` in flight when a restore commits waits forever.

**Ideal fix.** Split `AppModel` into the session half (`groups`, `selectedTabId`, and the per-session ephemera a restore legitimately resets) and one nested value holding the process-scoped facts: `config`, `resolvedFontFamily`, `tailnetStatus`, `isAppActive`, `noticeQueue`, `pendingSessionCreations`, `pendingInputSubmissions`. Then `Msg.restoreSession` carries only the session half, the arm becomes `model.session = restored`, and `carryingLiveAppearance` deletes. Whether a new field survives a restore is decided once, by which half it is declared in, and the pending maps stay live so their requests are still answerable by the ordinary completion path.

**By construction.** "A restore forgot to carry field X" stops being expressible -- the restore message no longer has a slot for X at all.

**Cheaper fallback.** Add the five missing carries to the arm. It fixes today's two bugs and leaves the same trap for the sixth field. If the pending maps are instead rejected rather than carried, say so explicitly and reuse `.runtimeWillShutdown`'s wording.

**Verification.** `swift test --package-path lib/DanTermCore --filter UpdateRestoreTests`. Behavioral test: dispatch `.tailnetStatusChanged(.listening(...))`, then `.restoreSession(modelBuiltFromASnapshot)`, then assert `model.tailnetStatus` still reports listening. Second test: register a pending session creation, restore, and assert either the reply survives (ideal) or an `.ipcError` is returned (fallback) -- never silence. `swift test --package-path lib/DanTermCore --filter SnapshotTests` guards the snapshot round trip.

**Risk.** Reshaping `AppModel` touches every reader in `app/` and `lib/`, including `toSnapshot` and the projection layer. The `isAppActive` carry has a stated reason in the arm's comment that must survive the move. If the process-scoped half ends up on the wrong side of the snapshot boundary, restore starts persisting config -- `SnapshotTests` is the guard.

**Vetted.** Confidence raised to 5: I found every quoted line and traced the tailnet claim end to end. The arm is `Update.swift:919-926` exactly as printed, `carryingLiveAppearance` (`ModelOperations.swift:81-88`) carries only `config` and `resolvedFontFamily`, and `Model.swift:1186` is the sole `AppModel(groups:selectedTabId:)` on the restore path, so every other field of the 24 declared at `Model.swift:595-640` takes its default. `AppModel.tailnetStatus` (`Model.swift:616`) defaults to `.disabled(reason: "no tailnet listener was started")`; the only writer is `.tailnetStatusChanged` (`Update.swift:616-617`); and `IpcServer.publish` (`IpcServer.swift:323-327`) opens with `guard status != tailnetStatus else { return }` over the server's own copy, so nothing re-sends a value the server has not changed. `model.tailnetStatus` is read by the `tailnet.status` reply (`IpcDispatch.swift:84-88`) and by the preferences projection (`Projections.swift:228-229`), so both surfaces do go stale.

Reachability is narrower than the prose implies, and one of the three paths is clean. `AppDelegate.swift:173-189` orders launch as: `--init` calls `bootstrapFromSnapshot` *before* `startIpcServer()`, so that path restores first and then receives the real status -- no bug. The recovery-prompt path does have it: `requestRestorePrompt` calls `startIpcServer()` (`AppRuntime.swift:1464`) while the prompt is up, and the answer runs `bootstrapFromValidatedRestore` later through `.resolveLaunchRestore`'s `DispatchQueue.main.async` (`AppRuntime.swift:874-885`), so the restore lands after the status. `importState(from:)` (`AppRuntime.swift:1302`) is unconditionally later. So: two of three paths, and only for a user whose listener is actually up. The pending-IPC half is real but the window is small -- both live restore paths are user-initiated, and `.runtimeWillShutdown` (`Update.swift:931-947`) shows the answer that is missing.

**Correction.** Effort is large, not medium. `AppModel` has 24 stored properties and the split has to classify all of them, not the seven the prose lists: `preferencesDraft`, `installedFontFamilies`, `availableThemeNames`, `alertsPopoverOpen`, `themeBrowserOpen`, `showAllAlerts`, `mruCycle`, `jumpMode`, `pendingConfirmation`, `todoPopover`, `sidebarRename` and `alerts` all need a side chosen and a reason recorded, and every reader in `app/`, `lib/DanTermCore` and the projection layer moves with them. Given that, the cheaper fallback deserves the top billing the prose gives the ideal: adding the missing carries fixes both live bugs today, and the split is a separate, larger piece of work that should be planned on its own evidence rather than smuggled in behind two narrow bugs.

**Conflicts with.** [PERSIST-5](PERSIST.md#persist-5) -- it deletes `ValidatedAppRestore.snapshot` and `bootstrapFromSnapshot`, while UPDATE-4's ideal changes the type of what `Msg.restoreSession` and `ValidatedAppRestore.model` carry. Same struct and same two call sites; sequenceable, not independent. No conflict with the fallback form.

<a id="update-5"></a>

#### UPDATE-5. Ask the quit question before the batch close removes the tabs, the way the single close does

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#answerPendingConfirmation` (the `.closeTabs` arm), `lib/DanTermCore/Sources/DanTermCore/Update.swift#closeTabBody`

**Problem.** "Closing this would leave DanTerm with nothing, so ask before you do it" is one rule with two implementations that disagree about ordering. The single-tab path asks first and removes nothing until authorized. The batch path removes every tab, notices the app is now empty, and only then asks. Cancel that dialog and you are left looking at a window with zero tabs -- a state no other path can produce.

**Evidence.** `closeTabBody` checks before removing:

```swift
guard tabLocation(id, in: model) != nil else { return [] }
if wouldQuitFromClose(model) {
    guard quitAuthorized else {
        return emitQuitConfirmation(&model, env: env)
    }
    return closeTabRemoval(&model, id: id) + [.terminate]
}
```

The batch arm removes first (`Update.swift:1466-1475`):

```swift
for tabId in normalized {
    commands.append(contentsOf: closeTabRemoval(&model, id: tabId))
}
guard model.hasAnyTab == false else { return commands }
if quitAuthorized {
    return commands + [.terminate]
}
return commands + emitQuitConfirmation(&model, env: env)
```

The state is reachable and pinned: `lib/DanTermCore/Tests/DanTermCoreTests/CloseConfirmationTests.swift:539` (`paneAndBatchThatBecomeAppEmptyingAsk`) closes an outside tab while a two-tab batch confirmation is open, then asserts `#expect(batchModel.hasAnyTab == false)` alongside a fresh quit confirmation -- while the pane leg of the same test asserts the opposite, `#expect(paneModel.pane(subjectPaneId) != nil)`. `reconcilePendingConfirmation`'s `.closeTabs` arm only retracts when one of the *named* tabs disappears, so an unrelated close leaves the confirmation standing and the path open.

**Ideal fix.** Move the emptiness test ahead of the removals in the batch arm: compute whether `normalized.count == totalTabCount(model)`, and when it is and `quitAuthorized` is false, `return emitQuitConfirmation(...)` without removing anything. That makes both paths state one rule -- nothing is removed until the quit question is answered -- and the pinned assertion flips from `hasAnyTab == false` to `hasAnyTab == true`.

**By construction.** A model with zero tabs and a live window stops being reachable from any close path, which is what makes "what should the app show with no tabs" a question nobody has to answer.

**Cheaper fallback.** None -- the ideal fix is small. The only alternative is to decide the empty state is fine and delete the second quit prompt, which is a worse answer because it discards the user's chance to cancel.

**Verification.** `swift test --package-path lib/DanTermCore --filter CloseConfirmationTests`. Rewrite `paneAndBatchThatBecomeAppEmptyingAsk`'s batch leg to assert `batchModel.hasAnyTab == true` and both subject tabs still present, with a fresh quit confirmation up; add a leg that answers that quit confirmation with `.cancel` and asserts both tabs survive.

**Risk.** A batch close of literally every tab already arrives with `quitAuthorized == true` from `.requestCloseTabs`, so the ordinary path is unaffected. Only the race -- another tab closing while the batch confirmation is open -- changes.

**Vetted.** This is the best-evidenced finding in the lane. `closeTabBody` (`Update.swift:1666-1684`) tests `wouldQuitFromClose(model)` before it removes anything and returns `emitQuitConfirmation` unauthorized; the `.closeTabs` arm (`Update.swift:1460-1475`) removes every tab in the loop first and only then reads `model.hasAnyTab`. `.requestCloseTabs` (`Update.swift:176-187`) freezes `quitAuthorized: normalized.count == totalTabCount(model)` at emission time, so a two-of-three batch freezes `false` and stays false however the tab count moves. `reconcilePendingConfirmation`'s `.closeTabs` arm (`Update.swift:1643-1647`) retracts only when a *named* tab id is gone, and `closeSubjectHasGrown` returns true only for a new pane or a changed running command, so an unrelated close leaves the confirmation standing. The state persists after the second dialog: `answerPendingConfirmation`'s cancel path (`:1416-1419`) just clears `pendingConfirmation` and returns, and neither the arm nor any sweep emits `.terminate`, so the window is left with zero tabs.

The pinning test is exactly as described. `CloseConfirmationTests.swift:539-570` is `paneAndBatchThatBecomeAppEmptyingAsk`, and the asymmetry sits inside one test body: the pane leg asserts `#expect(paneModel.pane(subjectPaneId) != nil)` and the batch leg asserts `#expect(batchModel.hasAnyTab == false)`, both alongside `testConfirmationKind(...) == .app`. Nothing in the file explains why the two legs differ. The scenario needs a race (an unrelated tab closing while a multi-tab confirmation is open), which is what keeps impact at 2 rather than 3; the ideal fix is a two-line reordering and removes it outright.

**Conflicts with.** [UPDATE-3](#update-3) -- it rewrites the `case (.closeTabs(...), .confirm)` pattern this fix reorders, in the same arm of the same switch. Land UPDATE-5 first (it is small and behavioral) and rebase UPDATE-3 on it.

<a id="update-6"></a>

#### UPDATE-6. Delete the `closeRequested` / `sessionEnded` chain, which nothing emits

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `app/TerminalSession.swift#requestClose`, `app/SwiftTerminalSessionView.swift#requestClose`, `lib/DanTermCore/Sources/DanTermCore/TerminalBackendBoundary.swift#TerminalSessionEvent`, `lib/DanTermCore/Sources/DanTermCore/Msg.swift#Msg`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`

**Problem.** A five-link vocabulary crosses the whole engine boundary and nothing enters it. `Msg.sessionEnded` exists beside `Msg.sessionProcessExited`, is handled by the same combined arm, and is reachable only from tests.

**Evidence.** The chain: `TerminalSession.swift:259` declares `func requestClose()` as a protocol requirement; `SwiftTerminalSessionView.swift:1441-1443` implements it as `callbackGate.emit(.closeRequested)`; `TerminalBackendBoundary.swift:44-45` maps `.closeRequested` to `[.sessionEnded(sessionId: sessionId)]`; `Update.swift:748` handles it in a combined arm with the message that is actually produced:

```swift
case .sessionProcessExited(let sessionId), .sessionEnded(let sessionId):
    guard let paneId = model.pane(owning: sessionId)?.id else { return [] }
    return update(&model, .closePane(paneId: paneId), env: env)
```

`requestClose()` has no caller anywhere in `app/`, `lib/`, `ios/`, `integrations/`, or `cli/` -- the `PaneProcessLifecycleEvent.requestClose` hits in `lib/TerminalPTY/Tests/` are a different type. The only `.sessionEnded` senders are `UpdatePaneTests`, `SessionReportTests`, and `TerminalBackendBoundaryTests`. `AppRuntime.swift:33-34` carries a log-description arm for the event that can never be logged.

**Ideal fix.** Delete `TerminalSession.requestClose`, `SwiftTerminalSessionView.requestClose`, `TerminalSessionEvent.closeRequested`, `Msg.sessionEnded`, its half of the combined arm, and the `AppRuntime` log arm. Re-point the three tests at `.sessionProcessExited`, which is the message production actually sends.

**By construction.** n/a -- this is subtraction, not a representability change. It does remove one trap: `.sessionEnded` routes to `.closePane`, not `.requestClosePane`, so a future caller wiring a UI "close this pane" gesture to it would silently skip the running-command confirmation.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** `swift test --package-path lib/DanTermCore` after re-pointing the three tests; `UpdatePaneTests#sessionEndedBackgroundTabPaneIsRemoved` (the ghost-pane regression) must keep asserting the same behavior under the new message name. The tree must build with no reference to the deleted symbols, which is the real proof.

**Risk.** If some future engine wants a "the terminal asked to be closed" event distinct from "the process exited", it has to reintroduce a message. That is the right cost: today's version routes both to the same handler anyway.

**Vetted.** I ran the grep the finding rests on over `app/`, `lib/`, `ios/`, `integrations/` and `cli/` and the chain is exactly five links with nothing entering it. `TerminalSession.swift:259` declares `func requestClose()` as a protocol requirement; `SwiftTerminalSessionView.swift:1441-1443` is its only implementation and its body is `callbackGate.emit(.closeRequested)`; `TerminalBackendBoundary.swift:16` declares `case closeRequested` and `:44-45` maps it to `[.sessionEnded(sessionId: sessionId)]`; `Msg.swift:158` declares `case sessionEnded(sessionId: SessionId)`; `Update.swift:748-750` is the combined arm as quoted. There is no call to `requestClose()` anywhere -- the many `.requestClose` hits in `lib/TerminalPTY` are `PaneProcessLifecycleEvent.requestClose` (`PaneProcessLifecycle.swift:96`), a different type reached from `TerminalPTYHost.swift:906`, and no code path connects the two. `AppRuntime.swift:33-34` does carry the unloggable description arm.

**Correction.** Four test files send `.sessionEnded`, not three: `UpdatePaneTests.swift:722`, `SessionReportTests.swift:107` and `:129`, `TerminalBackendBoundaryTests.swift:110-111`, and `UpdateSessionEventTests.swift:1038` (an assertion that `sessionEnded` on the last pane flips `pendingConfirmation`). The `TerminalBackendBoundaryTests` case does not re-point -- it asserts the mapping that is being deleted, so it deletes with it. Budget the re-point across the other four sites.

**Conflicts with.** None. Other lanes edit `app/SwiftTerminalSessionView.swift` ([INPUT-1](INPUT.md#input-1) through INPUT-4, [CHROME-3](CHROME.md#chrome-3)) but none touch `requestClose`, the callback gate, or `TerminalSession`'s protocol surface. [GATE-6](GATE.md#gate-6) greps that file's text in the harness self-test for `observeTitle(title)`, which this change does not move.

<a id="update-7"></a>

#### UPDATE-7. Stop the per-message repair sweep from scaling with the tab and alert count

`cost` &middot; impact 1, confidence 3 &middot; effort medium &middot; rescored

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#update` (the `defer` block), `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#reconcileTabState`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#liveTabIds`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#reconcileFocusedPaneAlerts`

**Problem.** Every message pays for repairs proportional to how much state exists, not to what the message changed. The two expensive passes run first and unconditionally, and the messages that arrive most often -- title, cwd and progress reports from a busy TUI -- cannot change anything either pass repairs. `Msg.coalescesReconcile` defers only the whole-model *view* sweep; `update()` and this `defer` still run inline for every event.

**Evidence.** `reconcileTabState` opens with `let liveTabs = liveTabIds(in: model)`, which builds a fresh `Set<TabId>` over every tab in every group, then `tabStateIsCanonical` allocates a second `Set<TabId>` (`var seen = Set<TabId>(); seen.reserveCapacity(liveTabs.count)`) to check the MRU order -- two heap allocations and 2N hashes on every message before the early return. `reconcileFocusedPaneAlerts` then runs for the default config (`DanTermConfig.alertClearMode` defaults to `.focus`, `lib/DanTermProtocol/Sources/DanTermProtocol/DanTermConfig.swift:44`):

```swift
guard model.config.alertClearMode == .focus, model.isAppActive,
      let paneId = selectedTab(in: model)?.paneTree.focusedPaneId else { return }
markAlertsReadForPane(paneId, in: &model)
```

`selectedTab` walks groups and tabs, and `markAlertsReadForPane` iterates `model.alerts.indices` -- capped at 100 by `paneAlertHistoryLimit` -- on every message, whether or not the message could have raised one.

**Ideal fix (to be decided by the measurement, not before it).** Two candidates, neither a cache. First: keep `reconcileTabState` but make its canonical check allocation-free -- compare `model.mruOrder.count` against `totalTabCount(model)` and walk `mruOrder` against the groups without materializing either set, so the common "already canonical" answer costs no allocation. Second: give `AlertModel`s their `isUnread` bit only where the authority can answer -- a pane's unread state is a question about `model.alerts`, and `markAlertsReadForPane`'s scan is only unavoidable because the feed is a flat array. Nothing here should become a dirty flag or a cached tab set; the audit's own rule is that this shape is what most structural findings exist to undo.

**Verification (the experiment, not a result).** Build a headless probe in the shape of `just checkpoint-projection-cost` (`scripts/checkpoint-projection-cost.py`, a fixed 64/128/256-pane fixture with the required `-O` whole-module build): construct an `AppModel` at 8, 32 and 128 tabs with a full 100-entry alert feed and `alertClearMode == .focus`, then time 100k dispatches of `.sessionReport(sessionId:report: .title("x"))` against one pane. The number that must move is nanoseconds per dispatch, and the claim is falsified if the 8-tab and 128-tab figures are within noise of each other -- that would mean the sweep is not what the message costs. Read `agent-docs/measurement-discipline.md` before acting on any difference between two numbers.

**Risk.** Rewriting `tabStateIsCanonical` to avoid allocation risks getting the canonical predicate subtly wrong, and a false "canonical" leaves `selectedTabId` or `mruOrder` unrepaired -- `UpdateMruTests` and `UpdateTabTests` are the net. On the cost side, an allocation-free walk is O(N) either way, so the win is bounded by allocator time; at realistic tab counts it may be too small to keep. That is what the probe decides.

**Vetted.** The mechanics are all there. `reconcileTabState` (`ModelOperations.swift:1180-1205`) does open with `let liveTabs = liveTabIds(in: model)`, `liveTabIds` (`:559-567`) builds a fresh `Set<TabId>` over every tab in every group, and `tabStateIsCanonical` (`:1214-1225`) allocates a second set with `var seen = Set<TabId>(); seen.reserveCapacity(liveTabs.count)` before its early return. `reconcileFocusedPaneAlerts` (`Update.swift:1929-1935`) is quoted exactly, `DanTermConfig.alertClearMode` defaults to `.focus` (`DanTermConfig.swift:44`), and `markAlertsReadForPane` (`Update.swift:1919-1927`) scans `model.alerts.indices` with the 100-entry cap at `Update.swift:2076`. `Msg.coalescesReconcile` (`Msg.swift:270-296`) has exactly one reader, `ModelOperations.swift:1128`, and it gates only the view sweep -- the `defer` is unconditional. So every mechanical claim survives.

**Correction.** The cost claim does not survive, and the score has to say so. The budget this pass sits in is per-`Msg`, and `Msg.coalescesReconcile`'s own comment puts the worst case at "30-60 Hz". At 60 Hz the sweep costs two small-set allocations plus O(tabs) hashes plus a 100-element array scan -- single-digit microseconds per message even at 128 tabs, so well under a tenth of a percent of a core. The auditor's falsification test ("the 8-tab and 128-tab figures within noise of each other") is the right test and is likely to fire. Two further reasons to expect a null: the sweep is not the dominant per-`Msg` cost -- `model.pane(owning:)` and `model.updateSession` already walk the whole pane tree *before* the arm runs, which the auditor's own Dropped list notes -- and `markAlertsReadForPane` writes nothing in the steady state, because `reconcileFocusedPaneAlerts` cleared the focused pane on the previous message. Impact 1, confidence 3: the code is confirmed, the cost is not, and nothing should be changed here before the probe reports.

**Conflicts with.** [UPDATE-2](#update-2) -- opposed on the same `defer` block: UPDATE-2 adds a per-message existence pass over `model.allPaneIds` and `model.alerts`, which is more of exactly what UPDATE-7 is trying to measure away. Run this probe before UPDATE-2's ideal is chosen over its fallback. [MODEL-5](MODEL.md#model-5) records a one-way dependency: it needs the `defer` to stay unconditional, which the two candidates here preserve.

<a id="update-8"></a>

#### UPDATE-8. Delete the accumulate-then-discard bookkeeping in the two alert-clearing arms

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/Update.swift#update` (`.clearAlertsForTabs`, `.clearAlertsForPane`), `lib/DanTermCore/Sources/DanTermCore/Update.swift#unreadAlertPaneIds`

**Problem.** Both arms build a "was anything affected" answer, guard on it, and then return the same empty command list on both sides of the guard. The bookkeeping is a leftover from when these arms returned view-refresh commands; the projection took that over, and the computation was never removed.

**Evidence.** `Update.swift:417-431`:

```swift
var affectedPaneIds: [PaneId] = []
for id in validIds {
    let paneIds = paneIdsForTab(id, in: model)
    let unreadPaneIds = unreadAlertPaneIds(for: paneIds, in: model)
    if !unreadPaneIds.isEmpty {
        affectedPaneIds.append(contentsOf: unreadPaneIds)
        for pid in unreadPaneIds { markAlertsReadForPane(pid, in: &model) }
    }
}
guard !affectedPaneIds.isEmpty else { return [] }
return []
```

and `Update.swift:886-890`:

```swift
let hadUnread = model.alerts.contains { $0.paneId == paneId && $0.isUnread }
guard hadUnread else { return [] }
markAlertsReadForPane(paneId, in: &model)
return []
```

`unreadAlertPaneIds` (line 1937) has no other caller.

**Ideal fix.** `.clearAlertsForTabs` becomes: for each valid tab id, `markAlertsReadForPane` for each of its panes. `.clearAlertsForPane` becomes one `markAlertsReadForPane` call. `unreadAlertPaneIds` deletes.

**By construction.** n/a -- `markAlertsReadForPane` is already idempotent, so "did anything change" was never a question these arms needed answered.

**Cheaper fallback.** None -- the ideal fix is small.

**Verification.** `swift test --package-path lib/DanTermCore --filter UpdateAlertTests`. The existing assertions -- clearing a tab's alerts leaves them read, clearing a tab with nothing unread changes nothing -- hold unchanged, which is exactly the point.

**Risk.** None beyond a mis-transcribed loop; the behavior is a pure model write with no command surface.

**Vetted.** Both blocks are in the tree verbatim: `.clearAlertsForTabs` at `Update.swift:417-431` (the `affectedPaneIds` accumulator, the `guard !affectedPaneIds.isEmpty else { return [] }`, and the `return []` immediately after it) and `.clearAlertsForPane` at `:888-892` (the `hadUnread` `contains` scan, the guard, and the same empty return on both sides). `unreadAlertPaneIds` is `Update.swift:1937-1946` and I confirmed by grep that `.clearAlertsForTabs` is its only caller. `markAlertsReadForPane` is idempotent as the finding says -- it only clears an `isUnread` bit that is already set.

**Correction.** One more thing deletes with it. `markAlertsReadForPane` is declared `@discardableResult ... -> Bool` (`Update.swift:1919-1927`), and no caller anywhere reads the result -- all seven call sites discard it. The `-> Bool` and the `@discardableResult` exist only to feed the accumulate-then-discard bookkeeping this finding removes, so the function should return `Void` after the change. That is the check that the cleanup was complete.

**Conflicts with.** [MODEL-7](MODEL.md#model-7) touches the alert filter but not these arms or `markAlertsReadForPane`, so no conflict. [UPDATE-2](#update-2) and [UPDATE-7](#update-7) both propose changes around `model.alerts`, but neither edits these two arms.

<a id="update-9"></a>

#### UPDATE-9. Say why `.themeBrowserControlClicked` has an empty arm, or remove the message

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/Msg.swift#Msg`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `app/ThemeBrowserView.swift`

**Problem.** The message changes no model state and returns no command. Its entire effect is the reconcile sweep that `update()` runs afterward. Nothing in the tree says so, so it reads as dead vocabulary -- and deleting it, which is the obvious cleanup, would silently break whatever the sweep repairs after a click in the theme browser.

**Evidence.** `Update.swift:815-816`:

```swift
case .themeBrowserControlClicked:
    return []
```

`Msg.swift:104` declares it with no comment, between two documented cases. Its only producers are `app/ThemeBrowserView.swift:183` and `:191`, both `onUserClick` hooks on the search field and the table. Compare `.alertsAgeRefreshTick`, which is the same "empty arm, exists to trigger a sweep" shape but whose name carries its reason.

**Ideal fix.** If the sweep is genuinely the point, name it: rename to something that says what the click has to repair (focus, most likely, given the two producers are both first-responder-taking controls) and put a one-line `///` on the case and a comment on the arm. If the repair is really a focus fact the view discovered, the honest form is to report it through `ReconcileFollowUps` like the other view-discovered facts, and delete the message.

**By construction.** n/a.

**Cheaper fallback.** A comment alone. That stops the accidental deletion without answering whether the round trip is needed at all.

**Verification.** `just test-ui` -- click the theme browser's search field and its table with a terminal pane focused, and confirm keyboard focus lands where it should. Whichever behavior that is, it needs a test before the message is touched, since nothing pins it today.

**Risk.** Removing the message without first establishing what the sweep repairs would regress theme-browser focus, and no headless test would catch it.

**Vetted.** All three quotes hold. `Update.swift:814-815` is `case .themeBrowserControlClicked: return []`, `Msg.swift:104` declares the case with no comment between `toggleThemeBrowser` and `adjustPaneFontSize`, and `ThemeBrowserView.swift:182` and `:190` are the only two producers, both `onUserClick` hooks. The two hook owners (`ThemeBrowserSearchField.mouseDown` at `:15-18`, `ThemeBrowserTableView.mouseDown` at `:32-35`) each call `super.mouseDown` first and then report, with the doc comment "Reports the gesture after its tracking loop has settled first responder."

**Correction.** The finding asks what the sweep repairs and guesses "focus, most likely". I can answer it, and the answer makes the message load-bearing rather than dead vocabulary, so the plan should not open with "or remove the message". The repair is in the *app-side* reconcile, not the reducer's `defer`: `Reconcile.swift:113-115` runs `reconcilePaneFocus()` then `reconcileReportedTerminalFocus()` at the end of every sweep, and both go through `paneFocusClaimant()` (`PaneFocusReconciliation.swift:57-80`), which reads the live `window.firstResponder` rather than anything in the model. Clicking the theme browser's search field or table moves first responder out of the pane tree, so the claimant becomes `.nonPane`, and `reconcileReportedTerminalFocus` is what tells the terminal session `setFocused(false)`. Nothing else would run that sweep, because the click changes no model state -- so without this message the pane keeps reporting itself focused (cursor, and DEC 1004 focus reporting to the child process). `reconcilePaneFocus`'s `case .nonPane: return` is what stops the same sweep stealing focus back.

That makes the honest fix the second half of the ideal, not the first: the click is a view-discovered focus fact, so it belongs in `ReconcileFollowUps` alongside the other view-discovered facts, and `SearchOverlayView.swift:105-108` shows the shape already in use for the same gesture (`.searchFieldBecameFirstResponder(paneId:)`, which does carry a payload). Until that lands, the comment is mandatory, not optional -- deleting the case would silently break focus reporting for every pane, and the auditor is right that no headless test catches it.

**Conflicts with.** None. No other lane file names `themeBrowserControlClicked`, `ThemeBrowserView.swift`, or `PaneFocusReconciliation.swift`. [INPUT-1](INPUT.md#input-1) and [INPUT-2](INPUT.md#input-2) touch pointer and IME handling in `SwiftTerminalSessionView`, not the focus reconcile pipeline.

#### Dropped (UPDATE)

- **`.moveTodo` cross-bucket move.** Read it line by line looking for an index bug when source and destination share a tab. `destinationCount` is read before the removal, but the `sameBucket` guard makes source and destination distinct collections, so the removal cannot shift the destination. Correct as written.
- **`deleteGroup` destination rule stated twice.** `answerPendingConfirmation`'s `.deleteGroup` confirm path appends to `frozen.destinationGroupId` inline, while `deleteGroupBody(moveTabs: true)` re-derives the destination with `adjacentGroupIndex`. Real duplication, but the frozen value came from `adjacentGroupIndex` in the first place and `reconcilePendingConfirmation` re-emits the confirmation when the frozen destination disappears, so no disagreement is reachable. Not worth a finding on its own; fold it into UPDATE-3 if that lands.
- **`closeSubjectHasGrown` ignores todo growth.** It re-prompts when a pane gains a running command but not when the user adds an uncompleted todo while the panel is open. `CloseImpact`'s doc comment scopes the freeze to command text ("so later work cannot hide behind equal command text"), so this reads as the stated policy rather than a miss.
- **`SessionReport` enumerated three times** (`TerminalMetadataBounds#isAdmitted`, `Msg#coalescesReconcile`, and the `.sessionReport` arm). Each switch answers a different question -- is it within bounds, is its view sweep throttleable, does it raise an alert -- so this is three consumers of one vocabulary, not three copies of one rule. Swift's exhaustiveness makes adding a case fail all three loudly. Left alone.
- **`model.preferencesDraft!` force-unwraps in `.prefSet` and `updateKeybindingPreferences`.** All of them sit under a `guard model.preferencesDraft != nil` at the top of their scope. Style, not a defect.
- **`.sessionBell` bypassing `alertPresentation`.** It passes a fixed `AlertPresentation(title: "DanTerm", subtitle: nil)` while every other alert derives title and location. Checked `AlertPresentationTests` -- a bell has no sender title to resolve and the difference is deliberate, so this is a UX question for the user, not a defect.
- **`AppModel.pane(_:)` and `pane(owning:)` walking the whole tree on every session callback.** Genuinely O(all panes) per message, but `Model.swift` states the trade explicitly ("Lookups are O(tree size) but run per-`Msg`, never on a render frame ... NO stored index is kept"), and the only fix that helps is the index that comment refuses. Left to UPDATE-7's probe, which measures the same per-message budget from the other side.
- **`applySelectTab` being a one-line helper.** It writes `selectedTabId` and returns `[]`; every repair is the sweep's. Looked for a reason to inline it and found one against: it is the single point three callers share, and the name is where the "selection is view-owned" comment lives.


### Area: Persistence, snapshots, and recovery (`PERSIST`)

_Scope: `lib/DanTermCore/Sources/DanTermCore/{Persistence,CheckpointCapture,RecoveryCheckpointPolicy,AgentSession}.swift`, the snapshot types and `validateAndBuildDetailed` in `lib/DanTermCore/Sources/DanTermCore/Model.swift`, `lib/DanTermSupport/Sources/DanTermSupport/{RecoveryStore,CheckpointWriter,InstancePaths}.swift`, `lib/PrivateFile/Sources/PrivateFile/PrivateFile.swift`, `app/{LaunchRecovery,AppLaunchPolicy,DanTermConfigStore,PaneHost}.swift`, the checkpoint/restore/export sections of `app/AppRuntime.swift`, `app/main.swift`, `app/AppDelegate.swift`, and `lib/DanTermProtocol/Sources/DanTermProtocol/{DanTermConfig,DanTermConfigDocument}.swift`._

**The auditor's read on the area.** The codec is in good shape. `toSnapshot` is the single definition of what persists, `LightCheckpointProjection` reuses that exact value as the dirty test so the two cannot disagree, `CheckpointCapture` pairs a model snapshot with the per-pane reads taken beside it so two in-flight checkpoints cannot cross, `PrivateFile.writeAtomically` makes a partial file unreadable by construction, and the config document keeps unknown keys and number tokens verbatim. The remaining defects share one shape: a fact that lives in two places and is reconciled by a rule written in prose rather than in the types -- structure lives in two checkpoint files and a comment picks the winner; the agent-session string is validated twice with two different failure policies; the `--init` snapshot is validated twice and one result is thrown away; a split direction is an enum on both ends and a `String` in between. I did not audit the pane-tape stream state (`PaneTapeRecords.swift`, `PaneTapeStreamState.swift`) -- it is a live wire protocol, not disk persistence, and the closed construction audit already reworked it (PERSIST-5, PERSIST-6, WIRE-2). I read the config store and document closely and found nothing worth a finding.

<a id="persist-1"></a>

#### PERSIST-1. Give the restore structure one source on disk, and write it on the exit path

`correctness` &middot; impact 3, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `app/AppRuntime.swift#performLightCheckpoint`, `app/AppRuntime.swift#prepareRecoveryForApplicationExit`, `app/AppRuntime.swift` (`case .terminate` in `perform`), `lib/DanTermCore/Sources/DanTermCore/Persistence.swift#mergeCheckpoints`, `app/LaunchRecovery.swift#loadLaunchCheckpoints`

**Problem.** Both checkpoint tiers carry a full `AppModelSnapshot`, and `mergeCheckpoints` always takes structure from the light tier. Nothing keeps the light tier newer. On a clean quit the light tier is deliberately abandoned: the `.terminate` command cancels the armed light timer without flushing it, and `applicationWillTerminate` then writes only the enriched file -- which captures the final model. So the state of the last light window (up to 2 s of tab closes, renames, splits, colours, todos, theme changes) is on disk in `last-enriched.json` and is discarded at load in favour of the older `last-light.json`. The worst case is the common one: closing the last tab produces the model edit and the `.terminate` command in the same frame, so the offered restore always shows the session as it was before that edit.

**Evidence.** The exit sequence cancels and never flushes:

```swift
// app/AppRuntime.swift, case .terminate
cancelCoalescedReconcile()
lightCheckpointTimer.cancel()
enrichedCheckpointTimer.cancel()
```

```swift
// app/AppRuntime.swift#prepareRecoveryForApplicationExit
enrichedCheckpointTimer.cancel()
for host in paneHosts.values { host.session.fenceForApplicationExit() }
_ = recoveryPolicy.terminate()
performEnrichedCheckpoint(async: false)
```

`performEnrichedCheckpoint` captures a fresh model: `captureEnrichedCheckpoint()` calls `toSnapshot(model)`. `flushPendingCheckpoint()` -- the only thing that would close the light window -- is called from exactly one place, `case .appResignedActive` inside `send`. The merge then throws that fresh structure away:

```swift
// lib/DanTermCore/Sources/DanTermCore/Persistence.swift#mergeCheckpoints
/// Light is authoritative for structure/model (a pane only in enriched is ignored;
/// a pane only in light keeps nil scrollback).
var mergedPaneSnapshots = light.paneSnapshots
```

and `loadLaunchCheckpoints` reaches it unconditionally when both files decode. The rule is pinned as spec by `lib/DanTermCore/Tests/DanTermCoreTests/CheckpointTests.swift#mergeCheckpointsLightMetadataWinsOverEnriched`, with no test stating the freshness invariant it depends on. The same inversion is reachable on a crash: the enriched window is `RecoveryCheckpointPolicy(window: UInt64(600 * NSEC_PER_SEC))`, so an enriched write that fires right after a structural change lands before that change's 2 s light window closes.

**Ideal fix.** One file owns structure; the other owns scrollback only. Keep `last-light.json` as the `AppInitFile` (structure, no scrollback) and make `last-enriched.json` a `[PaneId: String]` scrollback sidecar with its own version. Then write the structure file on the exit path -- `prepareRecoveryForApplicationExit` flushes it before capturing scrollback -- because it is the only structure there is. `mergeCheckpoints` becomes "graft the sidecar's text into the structure's pane map", the `(nil, enriched?)` branch in `loadLaunchCheckpoints` disappears, and "light is authoritative" stops being a rule anyone can get wrong.

**By construction.** Two disagreeing structures on disk stop being representable, so the choice between them, the comment that states it, and the "a pane only in enriched is ignored" clause all go away. The enriched file also shrinks to the bytes it is actually for.

**Cheaper fallback.** Call `flushPendingCheckpoint()` at the top of `prepareRecoveryForApplicationExit`. That fixes the quit case only. It leaves two structures on disk, leaves the crash-window inversion, and leaves the merge rule true only by timing.

**Verification.** `lib/DanTermCoreTests` plus a `app`-level test over `loadLaunchCheckpoints` against a temp `DanTermInstancePaths`: write a light checkpoint holding two tabs and an enriched one holding one tab, load, and assert the restore has one tab. Today it has two. Pair it with a runtime test that sends a tab close followed by `.terminate` and asserts the structure file on disk no longer names the closed tab.

**Risk.** A corrupt structure file now means no restore at all, where today an intact enriched file could still restore a stale session. That is the honest trade: scrollback without structure restores nothing anyway. Splitting the sidecar also means the exit path does two writes instead of one, both inside the existing `queue.sync` fence.

**Vetted.** I opened every cited symbol. The three quotes are exact: `AppRuntime.swift:1000-1005` (`case .terminate` cancelling both timers with no flush), `AppRuntime.swift:1143-1150` (`prepareRecoveryForApplicationExit`), and `Persistence.swift:174-176` (the `mergeCheckpoints` comment plus `var mergedPaneSnapshots = light.paneSnapshots`). `flushPendingCheckpoint` really does have one caller, `AppRuntime.swift:520` under `if case .appResignedActive = msg`. `LaunchRecovery.swift:31-33` reaches the merge unconditionally when both tiers decode, and `CheckpointTests.swift:87-100` pins the precedence as spec with no freshness test beside it.

I also traced the exit ordering, which the finding depends on and did not show. `Command.terminate` runs `ports.terminateApp()` (`AppRuntimePorts.swift:48-50`), which sets `quitConfirmed = true` and calls `NSApp.terminate(nil)` synchronously inside `perform`, so `applicationWillTerminate` runs before `dispatchInFrame` reaches its trailing `scheduleLightCheckpointIfNeeded()`. `applicationShouldTerminate` returns `.terminateNow` on the second pass. Nothing can deliver `.appResignedActive` in between. The inversion is real and the model handed to `performEnrichedCheckpoint` is the post-edit one.

The crash half of the evidence is much narrower than the prose suggests. `recoveryPolicy` is `RecoveryCheckpointPolicy(window: UInt64(600 * NSEC_PER_SEC))` as quoted, so an enriched write happens at most about once per ten minutes of primary-history mutation. Light writes within 2 s of any structural change. The inversion on a crash therefore needs the structural change to land inside the 2 s before one of those ten-minute deadlines: a real race, but not a case worth planning around.

**Correction.** The finding's worst case is backwards. Closing the last tab does emit the removal and `.terminate` in the same frame (`Update.swift:1677`, `Update.swift:1703`), but the resulting model has zero tabs, and `validateAndBuildDetailed` refuses that: `guard !parsedGroups.isEmpty, !allTabIds.isEmpty else { ... return nil }` (`Model.swift:1172-1175`). The exit-written enriched file then fails `loadValidatedInitFile`, counts as absent, and `loadLaunchCheckpoints` returns light alone. In that scenario "light is authoritative" is what saves the restore, not what breaks it.

State the finding on the case that does bite: any structural edit that is not the final quit-triggering one, made inside the 2 s before the process exits. Close two tabs of three and press Cmd-Q immediately, and the next launch offers all three back. Rename a tab, recolour it, add a todo, then quit inside the window, and the offered restore has none of it. The loss is bounded at one light window, which is why this is impact 3 rather than 4.

The correction also lands on the fix. Writing the structure file on the exit path -- the ideal fix, and the cheaper fallback equally -- overwrites `last-light.json` with the empty model on the close-last-tab quit, so the next launch validates nothing and offers no restore at all. Today it offers the session. Either the exit write must be skipped when the model has no tabs, or the loader must keep the last structure that validates; whichever is chosen has to be written into the plan, because both proposals as stated regress a working behaviour and neither says so.

**Conflicts with.** [PERSIST-3](#persist-3) and [PERSIST-4](#persist-4) rewrite the same `scheduleLightCheckpointIfNeeded` / `performLightCheckpoint` pair and the same `lightCheckpointBaseline`; the three should land in one change or in a stated order. PERSIST-4 also gets more load-bearing if this lands: once the light file is the only structure on disk, a light write that fails and never retries costs the whole restore, not a stale half of it. [CHROME-1](CHROME.md#chrome-1) adds a sidebar field to `toSnapshot` and asserts it "survives `toSnapshot` / restore", which is the structure file here -- compatible, but the two touch the same snapshot round trip.

<a id="persist-2"></a>

#### PERSIST-2. Drop an invalid persisted agent session like every other corrupt pane field, instead of rejecting the whole restore

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#parseSplitNode`, `lib/DanTermCore/Sources/DanTermCore/AgentSession.swift#recoveryReplayText`, `lib/DanTermCore/Sources/DanTermCore/Model.swift` (`PaneSnapshot.init(from:)`)

**Problem.** One bad `agentSession` value anywhere in a checkpoint fails the whole load, so the user loses every group, tab, and pane. Every neighbouring corrupt field degrades locally instead: a bad `gridOverride` becomes no override, a bad `fontSizeSteps` is clamped, a bad todo id drops that todo, an unknown `focusedPaneId` falls back to the first leaf. The agent session is the least valuable field in the file -- it produces one hint line appended to the replay text -- and it is the only fatal one. The validation is also already duplicated: `recoveryReplayText` re-validates the same DTO and drops the hint when it fails, so the fatal guard removes nothing the local path does not already handle.

**Evidence.** The fatal guard:

```swift
// lib/DanTermCore/Sources/DanTermCore/Model.swift#parseSplitNode
if let snapshot = ps.agentSession {
    guard let agent = AgentSession(kind: snapshot.kind, sessionId: snapshot.sessionId) else {
        print("[init] Invalid agent session")
        return nil
    }
```

The local path, on the same data:

```swift
// lib/DanTermCore/Sources/DanTermCore/AgentSession.swift#recoveryReplayText
let hint = agentSession
    .flatMap { AgentSession(kind: $0.kind, sessionId: $0.sessionId) }?
    .recoveryMessage
```

Both policies are pinned side by side in `lib/DanTermCore/Tests/DanTermCoreTests/SnapshotTests.swift`: `recoveryReplayDefensivelyValidatesDirectAgentSnapshot` asserts `sessionId: "bad;id"` yields the scrollback alone, while `invalidAgentSessionValueRejectsRestore` asserts the same `"bad;id"` inside a file throws `AppInitFileLoadError.invalidSnapshot`. The decode layer has the same split: `agentSession = try container.decodeIfPresent(AgentSessionSnapshot.self, ...)` is strict, so `{"kind": 42}` fails the entire file (`malformedAgentSessionSnapshotRejectsRestore`), while `todos` goes through `decodeLossyTodoSnapshotsIfPresent`, which keeps a malformed id local. This loader is also the `--init` and Import State path (`app/AppRuntime.swift#importState`), so a hand-authored file with one typo'd session id is refused whole.

**Ideal fix.** Give `agentSession` the todo treatment at both layers: decode it through a lossy wire value that yields nil on a type error, and in `parseSplitNode` write `persistedAgent = ps.agentSession.flatMap { AgentSession(kind: $0.kind, sessionId: $0.sessionId) }`. The `guard`, the `print`, and the `return nil` all go. `AgentSession`'s failable init still guarantees the model never holds an invalid one.

**By construction.** "One optional hint field can veto a whole session" stops being representable. The file-level and field-level validators stop being able to disagree about the same string.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `swift test --package-path lib/DanTermCore --filter SnapshotTests`. Rewrite `invalidAgentSessionValueRejectsRestore` to assert the opposite: the file loads, the tab and pane are present, and the restored pane's `session?.lastAgentSession` is nil. Add the `{"kind": 42}` case with the same expectation.

**Risk.** A user who relies on a rejected checkpoint to signal a corrupt file loses that signal; they now get the session back minus one resume hint. Nothing else reads `lastAgentSession` for control flow -- it feeds `ChipKind` and the replay text.

**Vetted.** Both quotes are exact: `Model.swift:1219-1228` (the `guard let agent = AgentSession(...) else { print(...); return nil }` arm) and `AgentSession.swift:92-95` (`recoveryReplayText`'s `flatMap`). The decode split is real too -- `Model.swift:1007` is `todos = try container.decodeLossyTodoSnapshotsIfPresent(forKey: .todos)` and `Model.swift:1008` is the strict `agentSession = try container.decodeIfPresent(AgentSessionSnapshot.self, forKey: .agentSession)`, one line apart. Both tests are where the finding says: `SnapshotTests.swift:914-924` and `:958-979`, asserting opposite policies over the same `"bad;id"`. I confirmed the neighbouring fields degrade locally as claimed (`clampedPaneFontSizeSteps` at `:1269`, `gridOverride.flatMap` at `:1273`, the `focusedPaneId` fallback at `:1141-1145`). `importState` at `AppRuntime.swift:1302-1317` does go through the same loader. Readers of `lastAgentSession` are exactly the three the finding names.

**Correction.** Rescored to impact 2, because the app cannot produce the state the guard rejects. `toPaneSnapshot` (`Persistence.swift:120`) writes `pane.session?.lastAgentSession`, which is an already-validated `AgentSession`, and `PaneLifecycleReducer.swift:154` is the only other writer. So a checkpoint DanTerm wrote never trips this. The reachable inputs are a hand-authored `--init` file, an imported state file, and on-disk corruption that happens to keep the JSON well formed. The first two are supported surfaces and the papercut is real -- one typo'd session id costs the whole file -- but on those paths the user gets a diagnostic (`[init] Invalid agent session` plus the `--init` fallback message, or `importErrorMessage`'s "failed snapshot validation"), not the silent whole-session loss the prose implies. The consistency argument stands on its own and the fix is three lines; the failure it prevents is not one users hit from normal use.

**Conflicts with.** Nothing in this lane. The `parseSplitNode` leaf arm this rewrites is a different arm from the split arm [PERSIST-6](#persist-6) and [MODEL-4](MODEL.md#model-4) contend over, so the three do not collide line-for-line, but all three edit `parseSplitNode` and should be sequenced.

<a id="persist-3"></a>

#### PERSIST-3. Arm the light-checkpoint window without snapshotting the whole model on every message

`cost` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `app/AppRuntime.swift#scheduleLightCheckpointIfNeeded`, `app/AppRuntime.swift#currentLightCheckpointProjection`, `app/AppRuntime.swift#retractionIsLive`

**Problem.** Every `send()` ends in `scheduleLightCheckpointIfNeeded()`, and whenever no window is armed that builds a complete `AppModelSnapshot` -- every group, tab, pane, todo, title, cwd, command and theme -- and deep-compares it to the baseline, only to decide whether to arm a 2 s timer. Messages that change nothing persisted (bells, alert ticks, search reports, delivered input) never arm the timer, so they pay that full snapshot on every single message, forever. The work scales with how much session exists, not with what changed. The cost is already acknowledged in the tree: `retractionIsLive` exists purely to keep typing out of `send()` for this reason.

**Evidence.**

```swift
// app/AppRuntime.swift#scheduleLightCheckpointIfNeeded
guard lightCheckpointTimer.isArmed == false,
      schedulingLifecycle.isActive,
      currentLightCheckpointProjection() != lightCheckpointBaseline
else { return }
```

```swift
// app/AppRuntime.swift#currentLightCheckpointProjection
LightCheckpointProjection(snapshot: toSnapshot(model))
```

and the workaround it forced:

```swift
/// Drops a delivered-input occurrence that can retract nothing before it reaches
/// `send()`, which snapshots and compares the whole model for every message. Typing
/// is the highest-rate producer of session events, and almost none of it answers a
/// wait.
private func retractionIsLive(_ event: TerminalSessionEvent, sessionId: SessionId) -> Bool {
```

**Ideal fix.** Drop the projection compare from the arming guard and arm on any message: `guard lightCheckpointTimer.isArmed == false, schedulingLifecycle.isActive else { return }`. `performLightCheckpoint` already re-projects and compares at fire time through `lightCheckpointCapture(current:baseline:)` and writes nothing when they match, so the only comparison left is one per 2 s window instead of one per message. Nothing observable changes, and `retractionIsLive` -- whose own doc says deleting it changes nothing observable -- loses its reason to exist and can go with it.

**By construction.** The persisted-state comparison happens in exactly one place, the place that writes, instead of in two places with two triggers.

**Cheaper fallback.** none -- the ideal fix deletes code.

**Verification.** Build an `AppModel` with 20 tabs and 40 panes, drive 1000 messages that change nothing persisted (`.sessionBell`) through `send()`, and count `toSnapshot` calls plus main-thread time. The decisive number is the call count: it must drop from 1000 to at most one per elapsed 2 s window. `just test` must stay green -- especially `CheckpointCaptureTests` and the runtime checkpoint tests -- because no write behaviour may change.

**Risk.** A timer now arms and fires during long stretches of non-persisting traffic and finds nothing to write. That is one `DispatchSourceTimer` per 2 s of activity; the workload that would show a regression is an idle-but-chatty session, and it would show up as timer churn, not as writes.

**Vetted.** All three quotes are exact: the guard at `AppRuntime.swift:1083-1088`, `currentLightCheckpointProjection` at `:1243-1245`, and `retractionIsLive`'s doc block and signature at `:1687-1699`. The trailing `scheduleLightCheckpointIfNeeded()` really does close every send frame (`:512`). Swift's `guard a, b, c` short-circuits in order, so the snapshot is taken only when no window is armed and the lifecycle is active -- the quote is not misleading about that.

I checked the mechanism the fix leans on and it holds. `performLightCheckpoint` re-projects at fire time and routes the decision through `lightCheckpointCapture(current:baseline:)` (`CheckpointCapture.swift:69-76`), which returns nil on equality, so removing the compare from the arming guard cannot cause a write that does not happen today. I also checked the claim that `retractionIsLive` loses its reason: `Msg.coalescesReconcile` (`Msg.swift:285-292`) lists `.userInputDelivered` among the coalescing reports, so a keystroke that reaches `send()` schedules a deferred sweep rather than an inline one. The light snapshot really is the only per-message whole-model cost typing pays, and the function's doc is accurate about that. It can go with the guard.

**Correction.** Rescored to impact 2, because this cost has already been measured. `scripts/checkpoint-projection-cost-probe.swift` and `just checkpoint-projection-cost` exist for exactly this path, and the closed 2026-08-18 audit ran them: medians of 131,584 / 257,542 / 510,667 ns per complete snapshot-build-and-compare at 64 / 128 / 256 panes, all inside its fixed 417,000 ns limit at 128 panes. That is a quarter of a millisecond per message on a session far larger than a real one, and the message classes that pay it are bounded by human and TUI rates -- a title or cwd report arms the window and makes the next two seconds free, so the steady pathological producer is a `.progress`, `.agentActivityChanged`, or bell stream with no persisted change beside it. Sub-1% of the main thread even at 256 panes.

The finding still deserves to be taken: it deletes code, it removes a workaround from the hot event path, and it moves the persisted-state comparison to the one place that writes. But its value is the deletion, not a recovered millisecond, and the write-up should say so rather than lead with "forever". Use the existing probe as the instrument -- the proposed `toSnapshot` call count is the right decisive number, and `agent-docs/measurement-discipline.md` governs anything beyond it.

**Conflicts with.** [PERSIST-1](#persist-1) and [PERSIST-4](#persist-4) edit the same light-checkpoint block (`scheduleLightCheckpointIfNeeded`, `performLightCheckpoint`, `lightCheckpointBaseline`). None of the three contradicts the others, but they overlap line-for-line and want one change or a stated order.

<a id="persist-4"></a>

#### PERSIST-4. Advance the light-checkpoint baseline only when the write actually succeeded

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `app/AppRuntime.swift#performLightCheckpoint`, `lib/DanTermSupport/Sources/DanTermSupport/CheckpointWriter.swift#CheckpointWriteOutcome`

**Problem.** The light tier advances its baseline at handoff and passes no completion, so it never learns whether the write landed. A failed write (a full disk, a recovery directory that briefly loses permissions) leaves the on-disk structure stale, and because the baseline already moved past it, that state is never rewritten -- the tier waits for the *next* difference. The enriched tier does the opposite through `RecoveryCheckpointPolicy.writeCompleted(revision:succeeded:at:)`, which retries. Two tiers, one job, two rules.

**Evidence.**

```swift
// app/AppRuntime.swift#performLightCheckpoint
lightCheckpointBaseline = projection
checkpointWriter.write(
    to: instancePaths.lightCheckpointFile,
    async: async,
    encode: capture.encoder()
)
```

No `completion:` argument, so the `CheckpointWriteOutcome` this call produces is dropped -- even though the writer already reports it and documents why the reason is carried: "state export shows the reason to the user, and 'it failed' is not something a person can act on".

**Ideal fix.** Pass a completion and, on failure, set `lightCheckpointBaseline = nil`. The property is already `LightCheckpointProjection?` and nil already means "nothing known to be on disk", the exact meaning wanted here -- it is simply never produced today. `lightCheckpointCapture(current:baseline:)` returns a capture unconditionally against a nil baseline, so the next window rewrites. Advancing at handoff stays correct for the ordering reason its comment gives; only the failure edge changes.

**By construction.** "The baseline claims a state is on disk that is not" stops being representable, and both tiers end up with the same retry rule.

**Cheaper fallback.** none -- the ideal fix is a completion closure and one assignment.

**Verification.** An `AppRuntime`-level test with a `CheckpointWriter` pointed at an unwritable directory: dirty the model, flush, restore writability, dirty nothing further, and force the next window. Assert a light checkpoint file appears. Today none ever does.

**Risk.** One extra write after a transient failure. The failure is still invisible to the user -- reporting it is a separate product decision I am not proposing here.

**Vetted.** The quote is exact (`AppRuntime.swift:1210-1215`): baseline assigned, then `checkpointWriter.write(to:async:encode:)` with no `completion:`. `CheckpointWriter.write`'s completion parameter defaults to nil (`CheckpointWriter.swift:52-57`), so the `CheckpointWriteOutcome` is built and dropped, and the doc sentence the finding quotes is in the file verbatim. The asymmetry with the enriched tier is real: `AppRuntime.swift:1177-1192` passes a completion and feeds `recoveryPolicy.writeCompleted(revision:succeeded:at:)`, whose `succeeded: false` arm (`RecoveryCheckpointPolicy.swift:57-71`) schedules another deadline rather than advancing `coveredRevision`. `lightCheckpointBaseline` is already `LightCheckpointProjection?` (`:175`), and `lightCheckpointCapture` returns a capture unconditionally against a nil baseline, so the proposed nil really does force the next window to rewrite.

Reachability is the weak half, and the finding is honest about that: the trigger is a failed write, which in the common case (full disk, read-only recovery directory) also fails the retry. What survives is the structural point -- two tiers doing the same job under two rules, one of which cannot learn it lost data. Impact 2 is right.

**Correction.** One mechanical note for the plan. The enriched tier's completion is guarded by `schedulingLifecycle.arm(.deferredCallback)` before the write and run through `schedulingLifecycle.run(token)`; a light completion that writes `lightCheckpointBaseline` should do the same rather than relying on `[weak self]` alone, or the two tiers end up with two lifetime rules in place of the two retry rules this finding removes. Note also that on the `async: false` path the writer still delivers through `DispatchQueue.main.async`, so a flush at `appResignedActive` will not see its own outcome before the app is suspended -- the retry lands on the next window, which is what the finding wants anyway.

**Conflicts with.** [PERSIST-1](#persist-1) and [PERSIST-3](#persist-3) edit the same light-checkpoint block. [SUPPORT-1](SUPPORT.md#support-1) rewrites `CheckpointWriter.write`'s body and possibly its signature (removing `PrivateFile.createDirectory`); the two changes are independent in substance but land on the same function and the same call site.

<a id="persist-5"></a>

#### PERSIST-5. Carry the validated restore from launch into bootstrap instead of validating the `--init` snapshot twice

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `app/main.swift`, `app/AppDelegate.swift` (`applicationDidFinishLaunching`), `app/AppRuntime.swift#bootstrapFromSnapshot`, `lib/DanTermCore/Sources/DanTermCore/Persistence.swift#ValidatedAppRestore`

**Problem.** `main.swift` runs the full validate-and-build for a `--init` file, then keeps only the input half and throws the built model away; `bootstrapFromSnapshot` builds it again on the other side of launch. The second build carries a "validation failed" fallback that cannot fire, because the same snapshot already validated -- a guard that only looks like it guards something. The recovery path does this correctly already (`bootstrapFromValidatedRestore`), and so does Import State.

**Evidence.**

```swift
// app/main.swift
let loaded = try loadValidatedInitFile(from: data)
initSnapshot = loaded.snapshot
```

```swift
// app/AppRuntime.swift#bootstrapFromSnapshot
guard let built = validateAndBuildDetailed(snapshot) else {
    print("[init] Snapshot validation failed, falling back to default startup")
    send(.createTabInSelectedGroup())
    return
}
bootstrapFromValidatedRestore(
    ValidatedAppRestore(snapshot: snapshot, model: built.model, paneSnapshots: built.paneSnapshots)
)
```

Note also that `validateAndBuildDetailed` mints fresh ids for id-less entries ("Snapshot Decode Nondeterministic ID Mints"), so the two builds of a hand-authored file are not even the same value -- the first set of minted ids is discarded.

**Ideal fix.** Have `main.swift` hand `AppDelegate` the `ValidatedAppRestore` for the `--init` path as it already does for recovery, and delete `bootstrapFromSnapshot`. `ValidatedAppRestore.snapshot` then has no reader at all -- `bootstrapFromValidatedRestore` uses only `model` and `paneSnapshots`, and `mergeCheckpoints` only passes it through -- so the field goes too, and the value stops carrying a copy of what its other two fields already encode.

**By construction.** A validated restore stops being convertible back into an unvalidated one, so no future caller can re-validate it, and the unreachable fallback disappears with the second validation.

**Cheaper fallback.** none -- the ideal fix is a field deletion and a call-site swap.

**Verification.** `swift test --package-path lib/DanTermCore --filter SnapshotTests` stays green after `ValidatedAppRestore.snapshot` is removed (the tests that read it move to `model`). Behaviour is unchanged by definition; a launch with `--init` pointing at an id-less snapshot must still open the described tabs.

**Risk.** None behavioural. `sessionSummary` already reads `restore.model`, not the snapshot.

**Vetted.** Both quotes are exact: `main.swift:83-84` (`let loaded = try loadValidatedInitFile(from: data)` / `initSnapshot = loaded.snapshot`) and `AppRuntime.swift:1435-1443` (`bootstrapFromSnapshot`, with the unreachable fallback and the re-wrapped `ValidatedAppRestore`). `AppDelegate.swift:174-178` is the only caller. `main.swift:105-108` already builds the recovery restore the validated way and `main.swift:106` comments that the recovered structure "is validated exactly once, at launch, and not again at bootstrap" -- so the `--init` path is the odd one out by the file's own stated rule.

I checked the claim that the field would have no reader after the change, which is what carries the "By construction" half. Grepping `ValidatedAppRestore(` across the tree gives one production construction outside `Persistence.swift` (`AppRuntime.swift:1442`, the one being deleted) plus four test helpers, and the only two reads of `.snapshot` anywhere are `main.swift:84` and `Persistence.swift:180`, where `mergeCheckpoints` copies it through without inspecting it. `sessionSummary` (`AppDelegate.swift:237-243`) reads `restore.model` as stated. So the field really does become dead.

The fallback is unreachable for the reason given -- `loadValidatedInitFile` and `bootstrapFromSnapshot` both call `validateAndBuildDetailed` with the default `.live` env over the same value -- with one pedantic exception: the builder mints UUIDs for id-less entries and rejects a collision, so the second build could in principle fail where the first succeeded. That is a UUID collision, not a branch worth keeping.

**Conflicts with.** [UPDATE-4](UPDATE.md#update-4) reshapes `AppModel` and changes what `Msg.restoreSession` carries, touching `bootstrapFromValidatedRestore` and `stageValidatedRestore` -- the same restore entry the `--init` path would be routed into. Independently implementable, but both edit the launch restore path and want a stated order.

<a id="persist-6"></a>

#### PERSIST-6. Persist a split's direction as its own enum, not as a string re-parsed on load

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/Model.swift#SplitNodeSnapshot`, `lib/DanTermCore/Sources/DanTermCore/Persistence.swift#toSplitNodeSnapshot`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#parseSplitNode`

**Problem.** `SplitNodeModel.Direction` is a two-case enum in the model, and a `String` in the snapshot. Both halves of the mapping are written by hand: the encoder switches enum to string, the loader switches string back and rejects the entire snapshot for anything else. A closed two-value vocabulary is enumerated three times (the enum, the encode switch, the decode switch) instead of once as data.

**Evidence.**

```swift
// lib/DanTermCore/Sources/DanTermCore/Persistence.swift#toSplitNodeSnapshot
let dirStr: String
switch direction {
case .horizontal: dirStr = "horizontal"
case .vertical: dirStr = "vertical"
}
```

```swift
// lib/DanTermCore/Sources/DanTermCore/Model.swift#parseSplitNode
let direction: SplitNodeModel.Direction
switch dirStr {
case "horizontal": direction = .horizontal
case "vertical": direction = .vertical
default:
    print("[init] Unknown direction: \(dirStr)")
    return nil
```

**Ideal fix.** Declare `SplitNodeModel.Direction: String, Codable` with cases `horizontal` and `vertical`, and give `SplitNodeSnapshot.split` a `direction: SplitNodeModel.Direction`. The two switches and the `return nil` go; `JSONDecoder` rejects an unknown token at the field, and the on-disk strings are unchanged.

**By construction.** A snapshot that names a direction the model does not have stops being constructible in memory at all. The failure moves from a whole-file rejection to the one field, matching PERSIST-2's rule.

**Cheaper fallback.** none -- the ideal fix is a raw-value conformance and two deletions.

**Verification.** `swift test --package-path lib/DanTermCore --filter SnapshotTests`. Assert the round trip still writes `"direction": "horizontal"` (external shape unchanged), and that a file with `"direction": "sideways"` fails to load. Today that produces `invalidSnapshot`; afterwards `decodeFailed` -- both are "no restore", so pick one and pin it.

**Risk.** The error class for a bad direction changes, which `app/AppRuntime.swift#importErrorMessage` turns into different user-facing text. No other consumer distinguishes them.

**Vetted.** Both switches are in the tree verbatim -- `Persistence.swift:132-137` (encode) and `Model.swift:1294-1300` (decode, ending in `print("[init] Unknown direction: \(dirStr)")` / `return nil`). `SplitNodeModel.Direction` is the two-case enum at `Model.swift:235-238`, and `SplitNodeSnapshot.split` carries `direction: String` at `Model.swift:860`. The vocabulary really is written out three times.

`SplitNodeSnapshot` has a hand-rolled `Codable` (`Model.swift:866-902`), so the fix is a one-word change at `:878` (`try container.decode(SplitNodeModel.Direction.self, forKey: .direction)`) plus the two switch deletions; a `String`-raw-valued enum encodes as the same bare token, so the on-disk shape is unchanged as claimed. `importErrorMessage` (`AppRuntime.swift:1701-1710`) does give `.decodeFailed` and `.invalidSnapshot` different text, so the stated risk is real and the finding is right to ask for one of them to be pinned.

**Correction.** Prefer a snapshot-owned `enum SplitDirectionSnapshot: String, Codable` over making the model's `SplitNodeModel.Direction` itself `Codable`. Everything the finding wants -- one closed vocabulary, no hand-written switches, a field-level decode failure -- comes either way, and the DTO version keeps the split this area already states deliberately elsewhere: `AgentSession`'s own doc says "The live value is intentionally not Codable: checkpoints use a strict DTO." Conforming a model enum to `Codable` so a wire type can embed it walks that back for no gain. If the model enum is conformed anyway, say why in the plan rather than by accident.

**Conflicts with.** [MODEL-4](MODEL.md#model-4) ("Make the split ratio a bounded type") rewrites the same `parseSplitNode` split arm and the same `SplitNodeSnapshot.split` case; the two edits collide line-for-line and should land together or in a stated order. MODEL-4's own vetting names this conflict but cites it as "PERSIST-2" -- it means this finding, PERSIST-6. MODEL-4 also supersedes this lane's dropped "unbounded persisted split `ratio`" bullet, and it is right to: `PaneLayout.swift#paneSplitRatio` already clamps the drag path, so `normalizedRatio` has no live caller that needs it once the ingress is bounded, and the reason given for dropping the item does not hold. [PERSIST-2](#persist-2) edits the neighbouring leaf arm of the same function.

<a id="persist-7"></a>

#### PERSIST-7. Make `terminate()` mark termination and stop returning an action no one applies

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/RecoveryCheckpointPolicy.swift#terminate`, `app/AppRuntime.swift#prepareRecoveryForApplicationExit`

**Problem.** `terminate()` computes and returns `.write(revision:)` or `.none` depending on whether the policy is dirty. Its only production caller discards the result and writes unconditionally. So the dirty rule the method states is exercised only by its unit test, and the exit path deliberately contradicts it -- correctly, since the exit write also refreshes the model snapshot, which the policy knows nothing about.

**Evidence.**

```swift
// app/AppRuntime.swift#prepareRecoveryForApplicationExit
_ = recoveryPolicy.terminate()
performEnrichedCheckpoint(async: false)
```

```swift
// lib/DanTermCore/Sources/DanTermCore/RecoveryCheckpointPolicy.swift
mutating func terminate() -> RecoveryCheckpointAction {
    guard isTerminated == false else { return .none }
    isTerminated = true
    scheduledDeadline = nil
    writeInFlightRevision = nil
    return isDirty ? .write(revision: latestRevision) : .none
}
```

`lib/DanTermCore/Tests/DanTermCoreTests/RecoveryCheckpointPolicyTests.swift` asserts `clean.terminate() == .none` and `dirty.terminate() == .write(revision: 1)` -- a rule production does not follow.

**Ideal fix.** Make `terminate()` return `Void`. It keeps its real job: setting `isTerminated` so a post-exit mutation cannot arm another timer, and clearing the deadline and in-flight revision. Update the two tests to assert what the exit path actually relies on -- that a mutation after `terminate()` yields `.none`.

**By construction.** A returned action that the runtime is not allowed to apply stops existing, so no future caller can apply it and skip the exit write.

**Cheaper fallback.** none -- the ideal fix is a return-type change.

**Verification.** `swift test --package-path lib/DanTermCore --filter RecoveryCheckpointPolicyTests`, with the two assertions replaced by "a mutation after terminate schedules nothing".

**Risk.** None; the value is already discarded at the only production call site.

**Vetted.** Both quotes are exact: `AppRuntime.swift:1149-1150` (`_ = recoveryPolicy.terminate()` immediately followed by `performEnrichedCheckpoint(async: false)`) and `RecoveryCheckpointPolicy.swift:74-81`. `_ = recoveryPolicy.terminate()` is the only production call anywhere in the tree. The test assertions are at `RecoveryCheckpointPolicyTests.swift:58-68`, exactly as quoted, including the trailing `#expect(dirty.mutation(at: 20) == .none)` -- which is the assertion the finding wants kept, and which already exists. So the rewrite is two deleted `#expect` lines, not two rewritten ones.

The reasoning for why production is right to ignore the return value holds: the exit write also refreshes the model snapshot through `captureEnrichedCheckpoint`, and the policy tracks only primary-history revisions, so a clean policy does not mean a clean file. Nothing today is broken; what the change removes is a stated rule that the one caller must disobey. Impact 2, confidence 5.

**Conflicts with.** Nothing. `terminate()`'s only caller is the two lines in `prepareRecoveryForApplicationExit` that [PERSIST-1](#persist-1) also edits, so the two want the same commit or a stated order, but neither constrains the other's design.

#### Dropped (PERSIST)

- **Restore does not bring back a zoomed pane.** `PaneTree.isZoomed` is live state, `TabSnapshot` has no field for it, and `validateAndBuildDetailed` rebuilds with the default `false`. Real, but no doc or test states zoom as persisted, and the closed construction audit's LOOKUP-1 explicitly decided to keep persistence membership field-enumerated rather than typed. It is a product question, not a defect.
- **`todos` as `[TodoSnapshot]?` where nil and `[]` mean the same thing.** The optional is a deliberate compaction -- writing `"todos": []` on every pane would grow every checkpoint -- and the `// nil for backward compat` comments are merely stale now that `appInitFileVersion` is checked for exact equality. Comment rot, not structure.
- **Unbounded persisted split `ratio`.** `parseSplitNode` does `CGFloat(ratio ?? 0.5)` with no bound, unlike the neighbouring `clampedPaneFontSizeSteps`. But `PaneLayout.swift#normalizedRatio` is documented as the repair for exactly this ("Repairs persisted or caller-supplied ratios before they influence geometry") and cannot be deleted anyway, since divider drags feed the same field. No guard is removable, so there is no win.
- **Orphaned `.partial` files.** A crash between `PrivateFile.createFile` and its `rename` leaves `.last-light.json.<uuid>.partial` in the recovery directory, and only `scrollbackReplayDirectory` is swept at launch. Real but tiny -- one small file per hard crash mid-write, in a directory nothing enumerates.
- **`DanTermConfigStore.load` reads `url` while `save` and `seedIfMissing` write through `resolvedTransactionURL`.** The asymmetry is intentional and safe: `Data(contentsOf:)` follows the symlink, so both paths see the same bytes, and the resolution exists to keep the atomic rename from replacing the user's symlink.
- **`ConfigJSONParser` and `SplitNodeSnapshot` decode recursively with no depth limit.** A crafted, deeply nested config or checkpoint would overflow the stack. Both files are the user's own, written by this app; `docs/scratch/2026-08-25-terminal-security-audit.md` is the right home for a hostile-input argument.
- **Synchronous encode on the main thread at `appResignedActive`.** `flushPendingCheckpoint` calls `performLightCheckpoint(async: false)`, which blocks the caller through `queue.sync`. That is the stated point of the flush (do not lose the last 2 s when the app backgrounds), and the encode is structure-only.
- **Deferred scrollback reads drifting from their snapshot.** I checked: `SwiftTerminalSessionView.primaryHistoryTailReader` calls `controller.synchronizeState()` and closes over a copy taken on the main actor, so neither the export path nor the checkpoint queue reads a live buffer. Correct as written.
- **Pane-tape stream and record code.** Live wire protocol, not disk persistence, and already reworked by the closed construction audit (PERSIST-5, PERSIST-6, WIRE-2, WIRE-3).

#### Pruned (PERSIST)

None. Every finding's evidence appears in the tree at the symbol named and says
what the auditor says it says, and every one describes a problem something can
reach. Three were rescored and three carry a correction; see each finding's
**Vetted.** paragraph.

One item the auditor *dropped* should not have been. The unbounded persisted
split `ratio` was dropped because "`normalizedRatio` ... cannot be deleted
anyway, since divider drags feed the same field". That reason is wrong on the
facts: `PaneLayout.swift#paneSplitRatio` already returns a clamped, finite value
for any pointer position, so the snapshot builder is the only ingress that can
store a ratio outside `0...1`, and `normalizedRatio` has no live caller that
needs it once that ingress is bounded. [MODEL-4](MODEL.md#model-4) states the
item correctly and supersedes the drop.


### Area: IPC dispatch and the wire protocol (`IPC`)

_Scope: `lib/DanTermProtocol/Sources/DanTermProtocol/` (`IpcRequest.swift`,
`IpcAuditDescriptor.swift`, `IpcLineFramer.swift`, `IpcRefusal.swift`,
`IpcLiveness.swift`, `Envelope.swift`, `Methods.swift`, `JSONValue.swift`),
`lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift` and
`IpcEntityEncoder.swift`, `app/IpcServer.swift`, plus the reply and transport
sites it drives (`app/AppRuntime.swift`, `app/PaneTapeBroker.swift`,
`lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift`,
`lib/DanTermClient/Sources/DanTermClient/DanTermClientSession.swift`) and the
protocol test suite._

**The auditor's read on the area.** This is one of the better-constructed parts
of the tree. `IpcLineFramer` is correct on the corners I could find (slice-based
line emission, oversize resynchronization, `memchr` scanning of a `Data` whose
`startIndex` is not zero). `IpcRequest` is a real closed catalog: `decode` is
typed-throws, targets are phantom-typed, and mutually exclusive request forms
(`IpcPaneResize`, `IpcPaneSplitTarget`, `IpcTabTarget`, `IpcPaneInput`) are sum
types rather than optional pairs. `IpcRequestTests.everyCLIRequestRoundTripsThroughCatalog`
forces one round-tripping fixture per catalog method, and I could not find a
single encode/decode drift. The construction audit's `IPC-1`..`IPC-6` have all
landed and I found none of them still live. What remains is smaller and shares
one shape: **a fact that already has an owner is restated somewhere else** -- the
hello restates a per-connection bound from a server-wide field, the audit
descriptor is derived twice from the same request, a protocol-level decode error
is carried through the model to be turned back into the constant it already was,
and one wire object has four spellings. I deliberately did not audit the CLI
argument parsing (`CLIParser`, `CLICommandCatalog`) beyond checking that the
shapes it builds decode, nor the pane-tape record vocabulary, which has its own
lane. I looked at and dropped the audit-log writer's thread safety, the framer,
and the reply-shape typing; reasons in **Dropped**.

<a id="ipc-1"></a>

#### IPC-1. Answer a decode failure on the server, not through the Elm model

`structural` &middot; impact 3, confidence 5 &middot; effort small &middot; confirmed

**Files.** `app/IpcServer.swift#IpcServerRuntimeMessage`,
`app/IpcServer.swift#IpcServer.dispatch`,
`app/AppRuntime.swift#makeIpcDispatch`,
`lib/DanTermCore/Sources/DanTermCore/Msg.swift#Msg.ipcRequestDecodeFailed`,
`lib/DanTermCore/Sources/DanTermCore/Update.swift`

**Problem.** When `IpcRequest.decode` rejects a line, the server already holds
everything the answer needs: the JSON-RPC id and an `IpcRequestDecodeError` that
carries its own `code` and `message`. Instead of writing that answer, the server
registers a transport, wraps the error in a second enum, hops to the main actor,
sends a `Msg` into the pure core, and the core's only job is to hand the constant
back. The sibling failure -- a line that is not a JSON-RPC envelope at all -- is
answered directly by the server two functions above. So one class of protocol
error has two reporting paths, and the more common one cannot be answered while
the main actor is busy.

**Evidence.** The core arm is a pure function of the error, with no `model`
reference at all (`Update.swift:41`):

```swift
case .ipcRequestDecodeFailed(let reqId, let error):
    return [.ipcError(reqId: reqId, code: error.code, message: error.message)]
```

The error already owns both values (`IpcRequest.swift#IpcRequestDecodeError`):

```swift
public var code: Int {
    switch self {
    case .methodNotFound: return -32601
    case .invalidParams: return -32602
    }
}
```

The transport it needs exists on the server (`IpcServer.swift#IpcServer.dispatch`):

```swift
} catch let error {
    try? auditWriter.append(.requestDecodeFailed(...))
    connection.rememberRequest(reqId: reqId, rpcId: rpcId)
    await dispatchToRuntime(.decodeFailed(error), connection: connection, reqId: reqId, audit: nil)
    return
}
```

while the neighbouring malformed-line path answers inline
(`IpcServer.swift#IpcServer.recordMalformedRequest`):

```swift
connection.writeErrorResponse(id: .null, code: -32700, message: "parse error")
```

**Ideal fix.** In `dispatch`'s catch arm, write
`connection.writeErrorResponse(id: rpcId, code: error.code, message: error.message)`
and return. Then delete `IpcServerRuntimeMessage` (`serve` takes
`IpcCallerIdentity` and `IpcRequest` directly), `Msg.ipcRequestDecodeFailed`, and
its `Update` arm.

**By construction.** A request that reached the runtime is now always a decoded
request: `AppRuntimeIpcDispatch.serve` has no "failed" shape to carry, so no
runtime or core code can be written that branches on one. It also removes the
state "a decode failure is waiting on the main actor to be told what its own
error code is".

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `app-tests/IpcServerRemoteTests.swift`-style test: build a
server with a runtime dispatch whose `serve` closure records nothing, send
`{"jsonrpc":"2.0","id":1,"method":"no.such.method"}`, and assert the response
line is `error.code == -32601` and that `serve` was never called. Ordering is
covered by an existing-style test: send a valid `ping` then a bad method on one
connection and assert the two responses arrive in that order.

**Risk.** Reply ordering on a connection. It is safe: the reader thread blocks on
each event until `handle` returns, and `serve` performs the reply synchronously
inside its own main-actor frame, so answering inline occupies the same slot in
the timeline that `recordMalformedRequest` already does.

**Vetted.** I opened `IpcServer.swift:74-77` (`IpcServerRuntimeMessage`, both
cases), `:560-616` (`dispatch`, including the catch arm verbatim as quoted),
`:527-535` (`recordMalformedRequest`, the `-32700` inline answer as quoted),
`:618-631` (`dispatchToRuntime`), `AppRuntime.swift:669-688` (`makeIpcDispatch`,
the two-case switch on the message), `Msg.swift:128`, `Update.swift:41-42`, and
`IpcRequest.swift:311-331` (`IpcRequestDecodeError`). Every quoted line is in the
tree, at the symbol named, saying what the prose says. The ordering argument also
holds: `serve` calls `AppRuntime.send`, which is `dispatch(msg)` ->
`outbox.withFrame { dispatchInFrame(msg) }` -> `perform(command)` with no await
(`AppRuntime.swift:474-498`), so the reply is written inside `serve`'s own
main-actor body. Two things the fix must own that the prose does not mention.
First, `dispatchToRuntime` is the sole incrementer of `servedRequests`
(`IpcServer.swift:627`), so answering a decode failure inline stops counting it
toward the connection's close-time `servedRequests` -- a durable audit field.
Nothing pins it (`IpcServerRemoteTests.swift:519`, `:595`, `:1166` all use valid
methods), and "served" arguably should not count a request that was never
dispatched, but the plan should state the decision rather than land it silently.
Second, `Msg.ipcRequestDecodeFailed` has a second consumer the prose misses: the
`DanTermCoreTests` helper at `UpdateIpcTests.swift:3557-3574`, which many
bad-params tests route through. Deleting the `Msg` case means rewriting that
helper's catch arm to build `.ipcError` itself -- still small, but it is a test
edit the "delete three things" list omits.

**Conflicts with.** None. The `UPDATE` lane owns `Update.swift` and `Msg.swift`
but no finding there touches the IPC arms (`UPDATE-9` edits `Msg.swift` for
`.themeBrowserControlClicked`, a different case), and `UPDATE-4` cites
`IpcServer.swift:324` only as evidence, not as a site it edits.

<a id="ipc-2"></a>

#### IPC-2. Advertise in `hello` the silence bound the connection is actually under

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `app/IpcServer.swift#IpcServer.beginService`,
`lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift#IpcConnection.writeHello`,
`lib/DanTermProtocol/Sources/DanTermProtocol/IpcLiveness.swift#IpcHello.params`

**Problem.** Each connection decides once, at admission, whether it lives under
the liveness contract: `ConnectionState.livenessBound` is `nil` for every local
caller and the server's bound for a tailnet peer. Two adjacent lines then read
two different values for that one fact. The hello states the server-wide bound
unconditionally, so a local connection is told it is under a 30-second silence
contract that the server never arms on it. The wire says one thing and the socket
does another.

**Evidence.** `IpcServer.swift#IpcServer.beginService`, consecutive lines:

```swift
state.connection.writeHello(appVersion: appVersion, livenessBound: livenessBound)
state.connection.startReading(livenessBound: state.livenessBound) { [weak self] event, connection in
```

`livenessBound` is the server-wide `private let`; `state.livenessBound` is the
per-connection decision, documented on `ConnectionState` as "Nil exempts it,
which is what every local caller gets". `writeHello` has no way to say "none"
(`IpcConnection.swift#IpcConnection.writeHello` takes a non-optional
`IpcLivenessBound` and always passes it to `IpcHello.params`). The client side
already anticipates omission -- `DanTermClientSession.handshake` returns
`DanTermServerHello(appVersion:livenessBound:)` whose field is documented as "The
silence bound this server advertised, or nil when it advertised none this client
can use", and a test pins the nil case
(`lib/DanTermClient/Tests/DanTermClientTests/ClientSessionTests.swift:224`).

**Ideal fix.** Make the hello's bound optional and pass the connection's own:
`writeHello(appVersion:livenessBound: state.livenessBound)`, with
`IpcHello.params` omitting `IpcLivenessBound.wireKey` when the bound is nil.
Then `ConnectionState.livenessBound` is the single source for both the
advertisement and the arming, and `DanTermClientSession`'s "a contract stream
with no advertised bound is an unusable hello" rule becomes a statement about
the same value the server enforces.

**By construction.** The state "advertised bound disagrees with armed deadline"
stops being representable: one value feeds both calls. It also removes the
possibility of a future local-socket client honouring an advertised bound and
pinging, or reconnecting, for a contract nobody is enforcing.

**Cheaper fallback.** Leave the wire alone and add a comment saying the local
hello's bound is decorative. That fails to remove the disagreement and leaves
`DanTermServerHello.livenessBound`'s documented nil case unreachable in
production, so the client's own contract stays untested against a real server.

**Verification.** In `app-tests/IpcServerRemoteTests.swift`: connect over the
local Unix socket, read the first line, and assert
`IpcLivenessBound.read(from: hello.params) == nil`; connect over the tailnet
fixture and assert it equals the server's bound. Existing remote liveness tests
pin the non-nil half already.

**Risk.** Any peer that requires `silenceSeconds` on a local hello would break.
`DanTermClientSession` only requires it when its transport declares
`.underContract`, which the Unix transport does not, so nothing in this tree
does. This is an external-compatibility change to a protocol both ends of which
ship in this repo, and the protocol version already exists to gate it.

**Vetted.** I opened `IpcServer.swift:497-499` (the two consecutive lines,
verbatim as quoted), `:151-159` (`ConnectionState.livenessBound` with the
documented "Nil exempts it, which is what every local caller gets"), `:411-424`
(`acceptLocal`, `livenessBound: nil`), `:470-480` (`acceptRemote`,
`livenessBound: livenessBound`), `:182` (the server-wide `private let`),
`IpcConnection.swift:163-174` (`writeHello`, non-optional bound, always passed
through), `IpcLiveness.swift#IpcHello.params` (always writes
`IpcLivenessBound.wireKey`), `DanTermClientSession.swift:48-55` and `:129-160`
(the documented nil case and the `if let monitor` guard), and
`ClientSessionTests.swift:219-225` (the nil-bound test). Every quote holds. This
is the lane's only `correctness` finding and it cites no `references/` emulator,
so there was no external behavior claim to re-check -- the compatibility question
is internal, both ends shipping from this repo.

**Correction.** The prose understates the harm and overstates the reach, and the
two cancel out at a lower score. Understated: a local client that believed the
advertised bound would not merely ping needlessly. `DanTermClientSession`'s
watchdog also reports `peerSilent` when no byte *arrives*, so adopting a 30-second
bound on a local socket would tear down an idle local follow after 30 seconds of
no output -- exactly what the exempt policy exists to permit ("An exempt stream
has no watchdog at all, which is what lets a local follow idle for as long as it
likes", `DanTermClientSession.swift:87-89`). Overstated: nothing reads it today.
`UnixSocketTransport.livenessPolicy` is `.exempt` (`UnixSocketTransport.swift:39`,
pinned by `ClientLivenessTests.swift:210`), so the local client never builds a
monitor and never applies the number. The disagreement is latent, not live: there
is no observable defect in the shipped tree, only a wire statement the socket does
not honour. Impact moves 3 -> 2 on that basis. The fix is still right and still
small.

**Conflicts with.** None. No other lane file touches `writeHello`, `IpcHello`, or
`IpcLiveness.swift`; `GATE.md:438` cites `pingInterval` as background only, and
`SUPPORT-6` edits `IpcConnection.writeGroup`, a different function.

<a id="ipc-3"></a>

#### IPC-3. Build the audit descriptor once, and without materializing the wire params

`cost` &middot; impact 1, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `app/IpcServer.swift#IpcServer.dispatch`,
`lib/DanTermProtocol/Sources/DanTermProtocol/IpcAuditDescriptor.swift#IpcRequest.auditDescriptor`,
`lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#IpcRequestProjection.input`

**Problem.** `auditDescriptor` is a computed property that runs the whole
`projection` switch. For a remote audited request the server runs it twice, and
each run rebuilds the complete JSON-RPC parameter object the server has just
finished decoding -- for `pane.input` that means re-encoding every input event
into `JSONValue` -- only to keep three scalars and throw the rest away. The
projection was unified so the audit target cannot drift from the wire target
(`IPC-1` in the 2026-08-18 audit), which is right; the accident is that the audit
path now has to build request content it is explicitly forbidden to retain.

**Evidence.** Two independent computations of the same value, in one function
(`IpcServer.swift#IpcServer.dispatch`, lines 590 and 598):

```swift
let audit = isAudited
    ? IpcRequestAudit(writer: auditWriter, caller: state.caller,
                      request: typedRequest.auditDescriptor,
                      isRemote: state.holdsRemoteSlot)
    : nil
if isAudited, state.holdsRemoteSlot {
    do {
        try auditWriter.append(.requestStarted(
            caller: state.caller,
            request: typedRequest.auditDescriptor
        ))
```

What each run does for pane input (`IpcRequest.swift#IpcRequestProjection.input`):

```swift
case .events(let events):
    params = ["input": .array(events.map(inputEventJSON))]
    accounting = .eventCount(events.count)
```

`params` is discarded by `auditDescriptor`, which reads only `targetEntries`,
`auditCommand`, `auditCwd`, and `auditInput`
(`IpcAuditDescriptor.swift#IpcRequest.auditDescriptor`).

**Ideal fix.** Two parts. (1) In `dispatch`, take `let descriptor =
typedRequest.auditDescriptor` once and pass it to both `requestStarted` and
`IpcRequestAudit`. (2) Change `IpcRequestProjection.params` from a stored
dictionary to a stored `@Sendable () -> [String: JSONValue]` builder, so the one
exhaustive switch still authors both projections but `auditDescriptor` never
calls the builder. `IpcRequest.params` calls it exactly once.

**By construction.** After (2) the audit path physically cannot materialize wire
content -- the closure that would build it is never invoked on that path -- which
is the guarantee `IpcAuditDescriptor.swift`'s header already claims ("excluding
terminal content and input details before any filesystem code sees them"). After
(1) the state "two descriptors for one request that could disagree" is gone.

**Cheaper fallback.** Do only (1). That halves the work and is a two-line change,
but leaves the audit projection structurally able to build a pasted-text or
event-array params object, so the header's claim stays a convention rather than
a property.

**Verification.** This is a cost claim; the deciding experiment is a micro
benchmark on `IpcRequest.auditDescriptor` alone, not a full-app run. Build a
`.paneInput(pane:input: .events(events))` with 4096 key events, call
`auditDescriptor` 10_000 times under `swift test --package-path lib/DanTermProtocol`
with a timing harness, and require the per-call allocation count to drop to zero
`JSONValue` allocations (measure with `heaptrack`-equivalent or a counting
`inputEventJSON` shim). Behaviourally, the existing
`IpcRequestTests.everyAuditDescriptorAdmitsOnlyApprovedWireFacts` and
`everyAuditTargetAgreesWithWireParams` must stay green unchanged -- they are the
proof the two projections still agree.

**Risk.** Making `params` a closure moves work later; a caller that reads
`request.params` twice now pays twice where it used to pay once. The only
production reader is `makeCLIRequest` in `Envelope.swift`, which reads it once.
The workload that would show a regression is CLI request construction, which is
one request per process.

**Vetted.** I opened `IpcServer.swift:585-599` (the two `typedRequest.auditDescriptor`
reads, at 590 and 598 exactly as quoted), `IpcAuditDescriptor.swift#IpcRequest.auditDescriptor`
(it does call `projection` and reads only the four audit fields, as claimed),
`IpcRequest.swift:254-307` (`IpcRequestProjection`, `params` a stored
`[String: JSONValue]`, and `input(_:pane:)` verbatim as quoted), `:620-627`
(`IpcRequest.params`), and both readers of `params`: `Envelope.swift:79-85` via
`CLIParser.swift:29`, and `MobileSessionController.swift:276` and `:304`. The
evidence is all there. The two named tests exist
(`IpcRequestTests.swift:140-152` and `:154-162`). The double computation is real
and happens only for a remote audited request -- a local caller builds the
descriptor once, and a heartbeat not at all.

**Correction.** The cost claim does not survive, and part (2) should be dropped.
The only remote producer of `pane.input` is the phone, and every keystroke path
in `MobileInputMapper` builds a one-element array (`:73`, `:174`, `:184`, `:185`)
or a single paste string (`:82`); the one multi-event path is alternate-screen
wheel scroll, `Array(repeating: wheel, count: count)` over the rows of one
gesture (`:163`). So the work being done twice is two one-element `JSONValue`
arrays per remote keystroke, not 4096 events. The micro benchmark the
Verification prescribes would measure a workload nothing in the tree produces,
and running it would prove nothing about the app. Part (2)'s "by construction"
claim is wrong on its own terms as well: the header's promise is about what
reaches the audit *writer*, and the descriptor never carried content either way;
the wire params were already resident in this process as the JSON line the
request was decoded from, so declining to rebuild them hides nothing that was
otherwise exposed. What is left is part (1): take
`let descriptor = typedRequest.auditDescriptor` once and pass it to both sites.
That is a two-line simplification, correctly motivated by "one request, one
descriptor", and the category should read `simplification` rather than `cost`.
Part (2) trades a stored dictionary for a stored closure in a `Sendable` struct
and buys nothing measurable.

**Conflicts with.** None. No other lane edits `IpcServer.dispatch`,
`IpcAuditDescriptor.swift`, or `IpcRequestProjection`.

<a id="ipc-4"></a>

#### IPC-4. Make `AppRuntimeIpcDispatch` non-optional on the server

`structural` &middot; impact 1, confidence 5 &middot; effort small &middot; rewritten

**Files.** `app/IpcServer.swift#IpcServer.runtimeDispatch`,
`app/IpcServer.swift#IpcServer.dispatchToRuntime`,
`app/IpcServer.swift#IpcServer.close`, `app/IpcServer.swift#IpcServer.publish`

**Problem.** The server's runtime handle is optional purely so tests can build a
server with no runtime behind it. In that configuration the server completes the
whole admission path -- remembers the JSON-RPC id, writes the write-ahead
`requestStarted` audit record, counts the request as served -- and then never
answers, so the peer hangs. Production never passes nil, so the `?` buys nothing
but three optional-chains and one un-answerable state.

**Evidence.** The declaration and its three consumers
(`IpcServer.swift`): `private let runtimeDispatch: AppRuntimeIpcDispatch?`, then

```swift
connections[connection.id]?.servedRequests += 1
if let runtimeDispatch {
    await runtimeDispatch.serve(connection, reqId, audit, message)
}
```

and `if let runtimeDispatch { await runtimeDispatch.connectionClosed(connection.id) }`
in `close`, and `await runtimeDispatch?.tailnetStatusChanged(status)` in
`publish`. The only nil call sites are tests:
`app-tests/IpcServerOwnershipTests.swift:277`,
`app-tests/IpcServerRemoteTests.swift:112,136,174,198,226`; the sole production
site is `app/AppRuntime.swift:331`, `runtimeDispatch: makeIpcDispatch()`.

**Ideal fix.** Make the field and the `init` parameter non-optional, and give the
tests a `AppRuntimeIpcDispatch` of no-op or recording closures -- it is a struct
of three `@Sendable` closures, so the fixture is three lines and is strictly more
useful than nil (a recording dispatch lets the remote tests assert what reached
the runtime instead of only what reached the socket).

**By construction.** "A server that admits a request, audits it, counts it, and
then answers nothing" stops being constructible. Three `if let` guards disappear.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** The existing `app-tests/IpcServerRemoteTests.swift` suite must
pass unchanged in behaviour after the fixtures swap nil for a no-op dispatch; the
tests that today assert only the refusal/hello bytes assert exactly the same
bytes. No new production behaviour to pin.

**Risk.** None to production behaviour -- the production path already always
supplies a dispatch. The change is confined to the test fixtures.

**Vetted.** I opened `IpcServer.swift:180` (`private let runtimeDispatch:
AppRuntimeIpcDispatch?`), `:218`, `:228`, and all three consumers: `:326`
(`await runtimeDispatch?.tailnetStatusChanged(status)`), `:547-549` (the `if let`
in `close`), and `:626-630` (`servedRequests += 1` then the `if let` in
`dispatchToRuntime`) -- all verbatim as quoted. `AppRuntime.swift:331` is the
sole production site. `AppRuntimeIpcDispatch` is indeed a struct of three
`@MainActor @Sendable` closures (`IpcServer.swift:56-70`), so the fixture the fix
prescribes is cheap to write.

**Correction.** Two claims need correcting. First, the nil count is understated:
`runtimeDispatch: nil` appears 18 times in `app-tests/IpcServerRemoteTests.swift`
and once in `app-tests/IpcServerOwnershipTests.swift`, not the six sites listed.
The fixture's `makeServer` (`IpcServerRemoteTests.swift:1401-1431`) takes it as a
required parameter, so a default there absorbs most of the churn -- the effort
stays small, but the diff is wider than the prose suggests. Second, the "By
construction" claim is false, and the fix the finding proposes is itself the
counterexample: a server holding a no-op `AppRuntimeIpcDispatch` still admits the
request, writes the write-ahead `requestStarted` record, increments
`servedRequests`, and answers nothing. That is the exact state the finding says
stops being constructible. Answering is a property of `serve`'s body -- production's
closure registers the transport at `AppRuntime.swift:673` before sending the
`Msg` -- not of the handle's optionality. What the change actually buys is three
fewer optional chains and remote tests that can assert what reached the runtime
instead of only what reached the socket. Worth doing; not a construction
guarantee, so impact moves 2 -> 1.

**Conflicts with.** None.

<a id="ipc-5"></a>

#### IPC-5. Give the `ok` reply and the todo wire object one spelling each

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift#okResult`,
`lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift#todoJSON`,
`lib/DanTermCore/Sources/DanTermCore/IpcEntityEncoder.swift#IpcEntityEncoder.todo`,
`lib/DanTermCore/Sources/DanTermCore/Update.swift`

**Problem.** Two wire objects are each written out in more than one place. The
acknowledgement object has a named builder, `okResult()`, which five dispatch
arms use and four other reply sites open-code. The todo item object -- three
fields, one of them the wire spelling of a phantom-typed id -- exists twice, once
for the todo replies and once for the `ls` projection. Neither duplicate is
covered by a test that would catch a one-sided edit.

**Evidence.** `IpcDispatch.swift#okResult` is `.object(["ok": .bool(true)])`, and
the same literal appears three times in the agent arms, e.g.

```swift
return commands + [.ipcReply(reqId: reqId, result: .object(["ok": .bool(true)]))]
```

in `.agentAttach`, `.agentActivity`, and `.agentDetach`, and a fourth time in
`Update.swift`'s `.inputSubmissionCompleted` arm:

```swift
return [.ipcReply(reqId: requestId, result: .object(["ok": .bool(true)]))]
```

The todo object is written twice, identically. `IpcDispatch.swift#todoJSON`:

```swift
.object([
    "id": .string(item.id.rawValue.uuidString),
    "text": .string(item.text),
    "isDone": .bool(item.isDone),
])
```

and `IpcEntityEncoder.swift#IpcEntityEncoder.todo`, byte for byte the same body.

**Ideal fix.** Delete `IpcDispatch.swift#todoJSON` and route `todoResult` and
`todoListResult` through `IpcEntityEncoder`, which is the file whose stated job
is "Builds wire documents from live model entities so IPC reply shape cannot
drift". Replace the four `.object(["ok": .bool(true)])` literals with
`okResult()`, and move `okResult` beside the encoder so `Update.swift` can reach
it too.

**By construction.** After this there is exactly one producer of each of the two
objects, so `danterm ls` and `danterm todo list` cannot report a todo
differently, and no reply can acknowledge with a differently spelled object.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `lib/DanTermCore/Tests/DanTermCoreTests/UpdateIpcTests.swift`:
add or keep an assertion that the todo object returned by `todo.list` for a pane
is identical to the todo object that same pane carries inside the `ls` reply.
Every existing `ok`-asserting test must stay green.

**Risk.** None: the two spellings are already identical, so consolidating cannot
change a byte on the wire.

**Vetted.** I opened `IpcDispatch.swift:632-643` (`todoResult`, `todoListResult`,
`okResult`) and `:657-664` (`todoJSON`), and `IpcEntityEncoder.swift:244-250`
(`IpcEntityEncoder.todo`). The two todo bodies are byte-identical, including key
order. `okResult()` has exactly five call sites (`:51`, `:71`, `:370`, `:522`,
`:529`) and the literal `.object(["ok": .bool(true)])` appears four more times
(`IpcDispatch.swift:115`, `:132`, `:145`, and `Update.swift:962` in the
`.inputSubmissionCompleted` `.delivered` arm) -- the counts in the prose are
right. I grepped `lib/DanTermCore/Tests/DanTermCoreTests/` for any test comparing
the `ls` todo object against the `todo.list` one and found none, so the coverage
claim holds too. One mechanical detail the fix must handle that the prose skips:
`IpcEntityEncoder.todo` is `private` on a struct that carries `home`, and
`okResult` is a file-scope `private func` in `IpcDispatch.swift`, so both need
their visibility widened before `todoResult` and `Update.swift` can call them.

**Conflicts with.** `CLI-3` (`CLI.md`). Its ideal fix threads a validated
`TodoText` through `IpcRequest.todoAdd` / `.todoEdit` and rewrites the same
`.todoEdit` dispatch arm whose reply IPC-5 re-routes through `IpcEntityEncoder`.
The two are compatible in intent but edit the same lines of `IpcDispatch.swift`;
land `CLI-3` first, then consolidate the reply builders on top of it.

<a id="ipc-6"></a>

#### IPC-6. Stop rejecting the empty pane-input text that the catalog can express

`structural` &middot; impact 1, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#decodePaneInput`,
`lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#IpcPaneInput`,
`lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift`

**Problem.** `IpcPaneInput.text` accepts any `String`, so
`IpcPaneInput.text("")` is a constructible catalog value that
`IpcRequest.params` will happily encode -- and that `IpcRequest.decode` then
refuses. Meanwhile the other spelling of "no input", `input: []`, decodes
cleanly and dispatch answers it `ok`. So one encoding of an empty request is a
`-32602` and the other is a success, and the catalog can build a request that
does not survive its own wire format.

**Evidence.** The decoder's emptiness guard
(`IpcRequest.swift#decodePaneInput`):

```swift
case (.some(.string(let text)), .none) where text.isEmpty == false:
    return .text(text)
case (.some, .none): throw invalid("invalid text")
```

The type imposes no such rule
(`IpcRequest.swift#IpcPaneInput`): `case text(String)`. And the empty event list
is accepted and acknowledged (`IpcDispatch.swift`, `.paneInput` arm):

```swift
guard submissionIds.isEmpty == false else {
    return [.ipcReply(reqId: reqId, result: okResult())]
}
```

**Ideal fix.** Drop the `text.isEmpty == false` condition, so `.text("")`
decodes and dispatch's existing empty-submission arm answers it `ok` the same way
`input: []` is answered. That makes `decode(params(request)) == request` total
over the catalog, which is what the round-trip test claims to establish.

**By construction.** The set of values `IpcRequest` can build becomes exactly the
set `IpcRequest.decode` accepts, so no future request case can be added that
encodes into something the daemon refuses. Removes a guard rather than adding a
type.

**Cheaper fallback.** The other direction -- make `IpcPaneInput.text` carry a
non-empty string type -- also closes the gap but adds a type and leaves the two
"no input" spellings answering differently. Named as the trade-off because it
preserves today's refusal; it costs a new wrapper type and a second validation
site.

**Verification.** `lib/DanTermProtocol/Tests/DanTermProtocolTests/IpcRequestTests.swift`:
add `.paneInput(pane:input: .text(""))` to the fixture list used by
`everyCLIRequestRoundTripsThroughCatalog` and assert it decodes back equal.
`lib/DanTermCore/Tests/DanTermCoreTests/UpdateIpcTests.swift`: assert
`pane.input` with `text: ""` replies `ok` and emits no `.submitPaneInput`
command.

**Risk.** A caller that today relies on `""` being rejected would now see a
success. No such caller exists in the tree: neither the CLI
(`CLIParser.swift#parsePaneInputCommand` builds `.events`) nor the iOS client
(`MobileInputMapper`) produces the text form.

**Vetted.** I opened `IpcRequest.swift:954-968` (`decodePaneInput`, the two quoted
cases verbatim), `:204-209` (`IpcPaneInput`, `case text(String)` with no
constraint), `IpcDispatch.swift:321-378` (the `.paneInput` arm, with the
`guard submissionIds.isEmpty == false` early `ok` at `:369-371` as quoted), and
`IpcRequestTests.swift:122-138`. The asymmetry is exactly as described: `.text("")`
encodes to `{"text": ""}` and comes back `-32602 invalid text`, while
`{"input": []}` decodes to `.events([])` and is answered `ok`.

**Correction.** The Risk paragraph is wrong, which makes the finding stronger
than its own prose. The iOS client does produce the text form:
`MobileInputMapper.paste(_:)` returns `.send(.text(text))`
(`MobileInputMapper.swift:80-83`), reached from `MobileSessionModel.swift:333-334`
(`.pasted`), reached from `TerminalInputView.paste(_:)`, which forwards
`UIPasteboard.general.string` with no emptiness check
(`TerminalInputView.swift:99-102`). An empty pasteboard string therefore sends
`pane.input {"text": ""}` over the tailnet and gets a `-32602` back where the
same gesture with one character is a no-op-shaped success. Rare and harmless, but
reachable in production rather than hypothetical, and that is the ground the fix
should be argued on. Second, the round-trip test does not claim what the prose
says it claims: `everyCLIRequestRoundTripsThroughCatalog` asserts one
representative fixture per `IpcRequestMethod`
(`#expect(Set(fixtures.map(\.command.method)) == Set(IpcRequestMethod.allCases.map(\.rawValue)))`),
not `decode(params(r)) == r` over every catalog value. Adding `.text("")` to the
fixture list is still the right pin. Impact stays 1: the worst outcome is an
error reply for an empty paste.

**Conflicts with.** None that block it. `CLI-3` (`CLI.md`) also edits
`IpcRequest.swift`, but a different decoder (`todoAdd` / `todoEdit`) and a
different fixture list entry, so the two land independently.

#### Dropped (IPC)

- **`IpcLineFramer` correctness.** I checked slice-backed `Data` input (nonzero
  `startIndex`), the `memchr` offset arithmetic, oversize resynchronization with
  and without a newline in the same chunk, and the exact-`maxLineBytes`
  boundary. All correct. No finding.
- **Audit writer thread safety.** `IpcRequestTransport.writeSuccess` /
  `writeError` are called from a background queue by `PaneTapeBroker.streamFinite`
  and `beginFollow`, so `IpcAuditLogWriter.append` runs off the main actor. It is
  guarded by `private let lock = Mutex<Void>(())` around both `prepare` and
  `append`. Safe.
- **Double audit record for one request.** `IpcConnection.writeSuccess` /
  `writeError` drop a reply whose id was already taken (`takeResponseId`), while
  `IpcRequestTransport` records the audit outcome unconditionally beforehand. I
  traced every reply site (`AppRuntime.perform`, `PaneTapeBroker`,
  `subscribeToRoster`, `runtimeWillShutdown`, pane-failure fan-out) and could not
  reach a second reply for one `reqId`: `takeIpcConnection` removes the transport
  on the first take. Not reachable, so not a finding.
- **Untyped reply shapes.** Every IPC result is an ad-hoc `JSONValue` built in
  `IpcDispatch.swift`, `IpcEntityEncoder.swift`, and `AppRuntime.swift`. That
  looks like a missing result catalog, but it has no second consumer to drift
  against: the CLI prints results as JSON (`cli/main.swift#printResult`) and the
  iOS client consumes only the already-typed `PaneRoster` and pane-tape records.
  Nothing re-parses `ls`, `pane.info`, or `tab.new` anywhere in the tree, so a
  result catalog would add types with no drift to prevent. IPC-5 covers the one
  case where a shape genuinely has two producers.
- **`IpcConnectionRejectionReason.notification(livenessBound:)` takes a bound
  three of its four cases ignore.** Real, and the parameter is wider than the
  callee accepts. But the alternative -- an enum with an associated bound on
  `connectionLimit` -- loses the plain `String` raw value that the client reads
  back through `init?(notification:)`, so it would need a separate raw tag plus a
  payload struct. The current shape is documented as a deliberate choice on
  `notification(livenessBound:)`. Not worth the churn.
- **Encode/decode variant coverage.** `everyCLIRequestRoundTripsThroughCatalog`
  forces one fixture per `IpcRequestMethod` but not per variant of the sum types
  inside a request, so `IpcPaneSplitTarget.tab` and
  `PaneTapeStartPosition.cursor` never round-trip there. I hand-checked both and
  they are symmetric, so there is no live drift -- only a coverage gap, and a
  weaker finding than the six above.
- **`Methods` is stringly typed while `IpcRequestMethod` is an enum.** Four
  server-to-client method names live as `public static let` strings rather than a
  raw-value enum. There are only four, all compared with `==` against the same
  constants, and no exhaustiveness is wanted (a client must tolerate an unknown
  notification). No defect to remove.
- **Unbounded write queueing for a stalled local subscriber.** A local roster
  subscriber that stops reading parks its connection's serial write queue
  (`IpcConnection.write(line:)` has no `SO_SNDTIMEO`) and queues rosters. Remote
  peers are reclaimed by the silence bound and `forceClose`; local peers are
  exempt by design. Rosters are coalesced by `lastEnqueuedRoster != roster`, so
  growth is bounded by real layout changes. Too speculative to score.
- **2026-08-18 construction audit.** `IPC-1` (`65032e40`), `IPC-2`
  (`6abec045`, `b1a3f6a2`, `286227e0`), `IPC-3` (`177c07ef`), `IPC-4`
  (`65718d58`), `IPC-5` (`c62bcb72`), and `IPC-6` (`2ce4107b`) are all landed and
  I found none of them still live in the tree. IPC-3 above is the residue of that
  file's `IPC-1`: the unified projection landed, but its two call sites in
  `IpcServer.dispatch` were not collapsed.


### Area: Portable side effects and file creation (`SUPPORT`)

_Scope: `lib/DanTermSupport/Sources/DanTermSupport/` (all 9 files), `lib/PrivateFile/Sources/PrivateFile/PrivateFile.swift`, `lib/ChipArtwork/Sources/ChipArtwork/` (all 3 files), plus the call sites in `app/` that these entry points serve: `app/AppRuntime.swift`, `app/SessionLockHandshake.swift`, `app/LaunchInstancePaths.swift`, `app/DanTermConfigStore.swift`, `app/PaneTapeBroker.swift`, and the two lints `scripts/private-file-mode-lint.sh` and `scripts/ambient-identity-lint.sh`._

**The auditor's read on the area.** The layer is in good shape and its two structural invariants hold: both lints pass on the tree today, every create in `app/`, `lib/`, `cli/`, and `ios/` routes through `PrivateFile` or an allowlisted call site with a written reason, and `DanTermInstancePaths` really is the only thing that turns an identity into a path. The seams themselves -- `bindSocket` returning a bound-and-moded descriptor before `listen`, `writeAtomically` staging a private sibling, `ControlSocketListener` recording the bound path's inode -- are careful and well tested. The defects that remain share one shape: a seam that is right for the artifact it was written for gets pointed at an artifact it was not, and nothing in the type says which artifact it is looking at. `PrivateFile.createDirectory` narrows whatever directory it is handed, and the checkpoint writer hands it a folder the user picked in a save panel (SUPPORT-1). The doctor probe carries a `homeDirectory` and a `configFilePath` that are resolved from two different notions of "home" (SUPPORT-2). The installer's two branches create the same PATH directory at two different modes (SUPPORT-5). I did not audit `lib/ChipArtwork` deeply beyond confirming its isolation contract, because the artwork file is generated and the renderer names no side effect; the only structural remark it earned (the string-keyed `ChipArtwork.all` beside the exhaustive `ChipKind.artwork` switch) is in Dropped. I read `IpcConnection` and `TailnetWhoisResolver` end to end and found their lifetimes and error paths sound; their findings are one duplicated rule and one cost.

<a id="support-1"></a>

#### SUPPORT-1. Stop the checkpoint writer from creating the destination's parent, so a state export cannot chmod the user's folder to 0700

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/CheckpointWriter.swift#CheckpointWriter.write(to:async:encode:completion:)`, `lib/PrivateFile/Sources/PrivateFile/PrivateFile.swift#PrivateFile.createDirectory(at:)`, `app/AppRuntime.swift#perform` (the `.exportState` arm)

**Problem.** `CheckpointWriter.write` creates the parent directory of whatever URL it is given, and `PrivateFile.createDirectory` narrows an already-existing directory to 0700. The same writer serves two very different destinations: the recovery checkpoints, whose directory DanTerm owns, and the state export, whose destination the user picks in an `NSSavePanel`. So exporting state into any existing folder silently changes that folder's mode to 0700 -- a shared project directory, `/Users/Shared/...`, a synced folder, a volume the user shares with another account. DanTerm did not create that directory and has no business restating its mode. The call is also redundant on the recovery path: `claimSessionLock` already creates the recovery directory at launch, before anything else fallible runs.

**Evidence.** The writer creates the parent unconditionally:

```swift
// CheckpointWriter.write(to:async:encode:completion:)
let data = try encode()
try PrivateFile.createDirectory(at: url.deletingLastPathComponent())
try PrivateFile.writeAtomically(data, to: url)
```

The seam narrows an existing directory, and its own test pins that:

```swift
/// Create `url` and any missing parent, and narrow `url` itself if it already exists.
public static func createDirectory(at url: URL) throws {
    try makeDirectory(at: url, narrowingExisting: true)
}
```

```swift
// lib/PrivateFile/Tests/PrivateFileTests/PrivateFileTests.swift:47
func createDirectoryNarrowsAnExistingDirectory() throws {
    // Intent: an existing 0755 directory comes out of `createDirectory` at 0700.
```

The export reaches that writer with a user-chosen URL:

```swift
// app/AppRuntime.swift, case .exportState
let exportWriter = exportWriter
ports.selectExportDestination(window) { [weak self] url in
    guard let self, let url else { return }
    exportWriter.write(to: url, async: true, encode: capture.encoder(prettyPrinted: true))
```

And the recovery directory already exists by the time any checkpoint runs:

```swift
// app/SessionLockHandshake.swift#claimSessionLock
try writeSessionLockFile(paths: paths)   // -> PrivateFile.createDirectory(at: paths.recoveryDirectory)
```

**Ideal fix.** Take directory creation out of `CheckpointWriter` entirely. A writer writes to a path whose directory its owner has already made: the recovery owner makes `recoveryDirectory` once at launch (it does today), and the export makes nothing because the user already picked a folder that exists. `CheckpointWriter.write` then does exactly two things -- encode, and atomically write -- and cannot touch any directory.

**By construction.** A destination the user named can no longer be moded by DanTerm, because no code on the export path calls a directory creator at all. The "which kind of directory is this parent?" question stops being answerable at that call site -- it is no longer asked.

**Cheaper fallback.** Add a `createsDirectory: Bool` (or a second entry point) to `CheckpointWriter.write` and pass false from the export arm. That fixes today's bug but keeps the writer able to mode a directory, so the next caller with a user-chosen destination reintroduces it by taking the default.

**Verification.** In `lib/DanTermSupport/Tests/DanTermSupportTests/CheckpointWriterTests.swift`: stage an existing directory at 0755 with a file inside, write a checkpoint to a URL in it, and assert the directory's mode is still 0755 afterwards (`PosixMode.swift` already reads modes in that suite). The test fails today and passes after the fix. Pair it with an existing-behavior test that a checkpoint written into a directory that does exist still lands, so the removal is proven not to break recovery.

**Risk.** If the launch lock claim fails (`SessionLockHandshake.claimFailure` non-nil) the recovery directory may not exist, and checkpoints would then fail for that run instead of recreating it. That failure is already surfaced to the user by the handshake, and a run whose lock could not be written already has degraded crash detection -- but the change makes the dependency real, so the handshake's failure path deserves a look in the same commit.

**Vetted.** I opened `CheckpointWriter.swift:58-63` (the encode / `createDirectory` / `writeAtomically` sequence is verbatim), `PrivateFile.swift:33-36` and its `makeDirectory` `EEXIST` arm at `:184-190` (`chmod(path, directoryMode)` on an existing directory, `directoryMode = 0o700`), `AppRuntime.swift:846-872` (the `.exportState` arm), `AppRuntimePorts.swift:32-44` (`NSSavePanel`, `canCreateDirectories = true`), and `SessionLockHandshake.swift` plus `RecoveryStore.swift:41-51`. The recovery-path redundancy claim holds: `writeSessionLockFile` calls `PrivateFile.createDirectory(at: paths.recoveryDirectory)` and `claimSessionLock` runs before any other fallible launch work, and both checkpoint files are children of `recoveryDirectory` (`InstancePaths.swift:38-52`). The bug is reachable, not merely representable: the only two `CheckpointWriter` instances are `checkpointWriter` and `exportWriter` (`AppRuntime.swift:198,203`), and the export one is handed a raw `panel.url`.

**Correction.** Two things the prose gets short. First, the silent chmod is only the milder half. `chmod` on a directory the user can write but does not own returns `EPERM`, so exporting into, say, `/Users/Shared` fails the whole export with "Operation not permitted" even though the write itself would have succeeded -- a visible functional failure, not just a permission surprise. Second, the fix is not a pure deletion: two existing tests pin the behavior being removed. `CheckpointWriterTests.swift:193` ("a checkpoint write narrows a world-readable destination") asserts the writer narrows a 0755 destination directory, for the upgraded-instance case; that guarantee survives at `writeSessionLockFile`, so the test moves to `RecoveryStoreTests` rather than disappearing. `InstancePathsTests.swift:70-97` writes both checkpoints on a fresh temp root *before* `writeSessionLockFile`, so it needs its statements reordered or it starts failing with `ENOENT`. Impact drops to 3: in the common case the user picks a folder in their own home, which is both owned by them and already 0700, so neither symptom fires.

**Conflicts with.** [PERSIST-4](PERSIST.md#persist-4) -- it adds a `completion:` argument at `AppRuntime.swift#performLightCheckpoint` and reasons about `CheckpointWriter.write`'s signature; this finding rewrites that same function's body. Independent in substance, but one function and one call site, so they want a stated order. PERSIST.md already names this conflict from its side.

<a id="support-2"></a>

#### SUPPORT-2. Derive the doctor probe's config path from the probe's own home, so one run has one home

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift#DoctorProbeEnv.live`, `lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift#DanTermConfigPaths.configFilePath()`, `scripts/tests/danterm-cli_test.sh#run_doctor_with_temp_home`

**Problem.** `DoctorProbeEnv` holds two independently resolved answers to "where is home". `homeDirectory` honors `$HOME` on purpose; `configFilePath` comes from `DanTermConfigPaths.configFilePath()`, which reads `NSHomeDirectory()`, and `NSHomeDirectory()` ignores `$HOME` on macOS. So a `danterm doctor` run under an overridden HOME probes agent homes, skills, and hooks inside the fixture home while probing the config file in the real user's home. The CLI test suite runs doctor exactly that way, so the font row it exercises reads the developer's real `~/.config/danterm/config.json`.

**Evidence.** The two resolutions sit four lines apart:

```swift
// DoctorProbeEnv.live
homeDirectory: liveHomeDirectory(environment: environment),
argv0: CommandLine.arguments.first ?? "",
installerDeps: .default,
configFilePath: DanTermConfigPaths.configFilePath(),
```

```swift
/// Honors a CLI-provided HOME first so local doctor runs and smoke tests probe
/// the same home directory the process environment exposes.
private func liveHomeDirectory(environment: [String: String]) -> URL {
    if let home = environment["HOME"]?...
```

```swift
// DanTermConfigPaths.configFilePath()
"\(NSHomeDirectory())/.config/danterm/config.json"
```

`NSHomeDirectory()` ignoring `$HOME` is not an assumption -- `HOME=/tmp/fakehome swift h.swift` with `print(NSHomeDirectory())` printed `/Users/dan` on this machine. And the harness that trips it:

```sh
# scripts/tests/danterm-cli_test.sh:183
if HOME="$doctor_home" CODEX_HOME="$doctor_home/.codex" "$CLI_PATH" "$@" >"$out" 2>"$err"; then
```

**Ideal fix.** Give `DanTermConfigPaths` the same shape `DanTermInstancePaths` has: it takes the home it means as an explicit input and defaults nothing (`configFile(home: URL) -> URL`). `DoctorProbeEnv.live` then composes it from its own `homeDirectory`, and `DanTermConfigStore`'s default composes it from the app's home at the one place the app resolves that. The `configFilePath` field on `DoctorProbeEnv` disappears, because a path derived from a value the struct already holds is not a second field.

**By construction.** A probe cannot hold two homes that disagree, because it holds one home and derives the path. The class of bug where a test overrides HOME and half the probe follows it stops existing.

**Cheaper fallback.** Set `configFilePath: liveHomeDirectory(environment: environment).appendingPathComponent(".config/danterm/config.json").path` in `.live` and leave the field. That fixes doctor but leaves `DanTermConfigPaths.configFilePath()`'s ambient `NSHomeDirectory()` as the app's only spelling, so the app and a HOME-overridden CLI still resolve different files.

**Verification.** In `scripts/tests/danterm-cli_test.sh`, write a `config.json` naming a font that is certainly not installed into `$doctor_home/.config/danterm/`, run doctor under that HOME, and assert the report names that font. Today the row reports on the real user's config and the assertion fails regardless of the fixture.

**Risk.** If any packaging or launch context sets `HOME` to something other than the user's real home while expecting DanTerm's config to stay at the real home, this moves the file doctor reports. Only the doctor probe changes if the fallback is taken; taking the ideal fix also moves `DanTermConfigStore`'s default and needs a check that the app process's `$HOME` and `NSHomeDirectory()` agree at launch (they do for a normally launched `.app`).

**Vetted.** I opened `DoctorProber.swift:8-28` (the two resolutions are four lines apart, verbatim), `:445-452` (`liveHomeDirectory` and its doc comment), `:65-66` (`gatherConfigFontFacts` reads `env.configFilePath` directly), `DanTermConfigPaths.swift` in full (`"\(NSHomeDirectory())/.config/danterm/config.json"`), and `scripts/tests/danterm-cli_test.sh:180-188`. I reran the `NSHomeDirectory()` probe myself: with `HOME=/tmp/fakehome`, `NSHomeDirectory()` and `FileManager.default.homeDirectoryForCurrentUser.path` both printed `/Users/dan` while `environment["HOME"]` printed `/tmp/fakehome`. The two-homes claim is exact.

**Correction.** The consequence is smaller than the prose implies, which is why the score moves to 2. The CLI harness runs `doctor` under the fixture HOME but asserts nothing about the font row, and `evaluateConfigFont` (`cli/Doctor.swift:321-347`) can only return `skip`, `warn`, or `ok` -- never `error` -- while `doctorExitCode` (`:145`) fails only on `error`. So the developer's real config cannot make the suite fail; it just makes one row report a fact from outside the fixture. In production the divergence never happens either: the app carries no sandbox entitlement, so `NSHomeDirectory()` and `$HOME` name the same directory for both the app and a normally invoked `danterm`. What is left is exactly a structural finding -- one struct holding two independently resolved homes, and a doctor row the CLI suite cannot cover -- not a reachable user-facing bug. The finding as it should read: *make the probe hold one home so the font row becomes testable, and so the app's config path stops being resolved by an ambient call.*

**Conflicts with.** [CLI-4](CLI.md#cli-4) and [CLI-6](CLI.md#cli-6) touch `danterm doctor`, but on the other side of the seam -- CLI-4 changes how the app-owned permission rows get their target and CLI-6 changes row titles and adds a JSON projection, while this finding changes `DoctorProbeEnv`'s field set. They can land in either order. Nothing in another lane touches `DanTermConfigPaths` or `DanTermConfigStore`'s default URL: PERSIST scopes `DanTermConfigStore.swift` but its only remark on it is in Dropped.

<a id="support-3"></a>

#### SUPPORT-3. State the `sun_path` capacity rule once, instead of once per Unix-socket caller

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/TailnetWhoisResolver.swift#TailnetWhoisResolver.unixSocketAddress(for:)`, `lib/PrivateFile/Sources/PrivateFile/PrivateFile.swift#PrivateFile.unixSocketAddress(for:)`

**Problem.** The `sockaddr_un` construction and its length check exist twice, character for character apart from the thrown error. `PrivateFile` publishes the helper and documents it as the shared one -- `ControlSocketListener`'s liveness probe already borrows it -- but `TailnetWhoisResolver` keeps a private copy. Two copies of a rule about a fixed-size C buffer is exactly the kind of duplication that goes wrong quietly: the next person who fixes one (a `strncpy` bound, an off-by-one on `maximumLength - 1`) will not know the other exists.

**Evidence.** `PrivateFile`:

```swift
/// Builds the Darwin address while enforcing `sockaddr_un.sun_path` capacity. It sits with
/// the socket creator rather than with the listener because binding is where the length
/// limit is discovered, and `ControlSocketListener`'s liveness probe borrows it from here.
public static func unixSocketAddress(for url: URL) throws -> sockaddr_un {
```

`TailnetWhoisResolver`:

```swift
private static func unixSocketAddress(for url: URL) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maximumLength = MemoryLayout.size(ofValue: address.sun_path)
    guard url.path.utf8.count < maximumLength else { throw Error.invalidResponse }
```

`DanTermSupport` already depends on `PrivateFile` (`lib/DanTermSupport/Package.swift`), so nothing structural stands in the way.

**Ideal fix.** Delete the private copy and call `PrivateFile.unixSocketAddress(for:)`, mapping its throw into the resolver's own `Error` at the one call site. Three call sites, one rule.

**By construction.** There is exactly one expression of the capacity bound in the product, so the two spellings cannot drift.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `TailnetWhoisResolverTests`: point a resolver at a socket path longer than `sun_path` and assert it fails rather than truncating and connecting somewhere else. The existing suite plus `ControlSocketListenerTests` covers the seam side.

**Risk.** The thrown error type at that path changes unless it is mapped; the test above pins the observable outcome so the mapping is verified rather than assumed.

**Vetted.** I diffed the two bodies by eye: `PrivateFile.swift:145-161` and `TailnetWhoisResolver.swift:242-255` are identical apart from the `guard`'s throw (`CocoaError(.fileWriteInvalidFileName)` against `Error.invalidResponse`) and the access level. The three call sites are real -- `PrivateFile.swift:124` (`bindSocket`), `ControlSocketListener.swift:129`, and `TailnetWhoisResolver.swift:104`, of which only the last uses the private copy. `lib/DanTermSupport/Package.swift:28,35` does declare the `PrivateFile` dependency, so the fix is `import PrivateFile` plus a `do`/`catch` map at one call site.

**Correction.** Two notes that change the argument without changing the recommendation. The "goes wrong quietly" case is weaker than the prose says: the production socket path is the fixed literal `/var/run/tailscaled.socket` (`TailnetWhoisResolver.swift:45`), so the length guard can never fire outside a test that passes its own `socketPath:` to `init(socketPath:timeout:)`. The value of the fix is deleting fourteen duplicated lines of `strncpy`-into-a-fixed-C-buffer, not preventing a live drift. Pointing the other way: the private copy also throws `Error.invalidResponse` for a *path length* problem, which is a mislabel -- an over-long socket path is not a response at all. The mapping the ideal fix has to write is therefore an improvement rather than a cost, and it should not reuse `invalidResponse`.

**Conflicts with.** Nothing. No other lane file names `TailnetWhoisResolver` or `PrivateFile.unixSocketAddress`. [SUPPORT-1](#support-1) and [SUPPORT-5](#support-5) also touch `PrivateFile.swift`, but different declarations.

<a id="support-4"></a>

#### SUPPORT-4. Give the PATH parent directory one mode, whichever install branch creates it

`structural` &middot; impact 2, confidence 4 &middot; effort small &middot; rescored

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/CLIPathInstaller.swift#CLIPathInstaller.ensureDestinationParentDirectoryExists`, `lib/DanTermSupport/Sources/DanTermSupport/CLIPathInstaller.swift#CLIPathInstaller.installCommand(sourceURL:)`

**Problem.** Installing the `danterm` CLI can create `/usr/local/bin`, and the two branches create it at two different modes. The unprivileged branch routes through the private seam and makes it 0700, owned by the user. The privileged branch shells out to `/bin/mkdir -p` under `osascript` and makes it root-owned 0755. So the mode of a directory on the user's PATH depends on whether the first install happened to need administrator rights. 0700 on a PATH directory is also the wrong answer on its own terms: the directory holds a symlink the file's own comment calls "one of the three artifacts the user reads and manages directly", it carries no terminal content, and other accounts and tools legitimately traverse it.

**Evidence.** Unprivileged:

```swift
private func ensureDestinationParentDirectoryExists() throws {
    let parentURL = deps.destinationURL.deletingLastPathComponent()
    ...
    try PrivateFile.createDirectory(at: parentURL)
}
```

Privileged, in the same file:

```swift
return "/bin/mkdir -p \(Self.shellQuoted(parentPath)) && " +
```

And the symlink beside it is explicitly umask-default:

```swift
// Umask default, deliberately: the CLI link is one of the three artifacts the user
// reads and manages directly, and it names an executable rather than holding any
// terminal content.
try FileManager.default.createSymbolicLink(at: deps.destinationURL, withDestinationURL: sourceURL)
```

`docs/design/2026-05-28-pure-core-support-split.md` names this parent as a CLI installation artifact -- an umask-default class -- but only for the privileged branch: "any destination parent the privileged install branch creates by shelling out under `osascript` ... while the unprivileged branch's parent does [route through the seam]". The split is recorded; its consequence, two modes for one directory, is not.

**Ideal fix.** The destination parent belongs to the umask-default class in both branches, exactly as the symlink it holds does. Create it with a plain `FileManager.createDirectory` at the same call site, with the same "umask default, deliberately" comment the symlink carries -- `CLIPathInstaller.swift` is already on the private-file lint's allowlist for precisely this class, so nothing new is exempted. The classification then follows the artifact, not the privilege level of the branch that made it.

**By construction.** The artifact has one mode, so no code path can produce the other one. The doc's carve-out collapses from "the privileged branch's parent" to "the destination parent", which is a statement about the artifact rather than about a code path.

**Cheaper fallback.** Leave it and amend the ADR to say the two branches disagree on purpose. That keeps a 0700 directory on a PATH the user shares with other tools, and keeps the mode dependent on an accident of which branch ran first.

**Verification.** `CLIPathInstallerTests`: with `destinationURL` pointed at a nonexistent subdirectory of a temp root, install and assert the created parent's mode is the umask default (0755 under the suite's umask), using the existing `PosixMode.swift` helper. Today it asserts 0700.

**Risk.** A directory the user created before this change keeps whatever mode it has -- neither branch narrows an existing parent, since `ensureDestinationParentDirectoryExists` returns early when it exists. So the change affects only fresh creates.

**Vetted.** Every quote is in the tree: `CLIPathInstaller.swift:201-208` (`ensureDestinationParentDirectoryExists`, early return on an existing directory, then `PrivateFile.createDirectory(at: parentURL)`), `:275-280` (`installCommand`'s `/bin/mkdir -p ... && /bin/rm -f ... && /bin/ln -s ...`), `:171-176` (the "Umask default, deliberately" comment above `createSymbolicLink`), and the ADR sentence at `docs/design/2026-05-28-pure-core-support-split.md:371-378`, word for word. `CLIPathInstaller.swift` is on the private-file lint's allowlist (`scripts/private-file-mode-lint.sh`, the `ALLOWLIST` array), with a comment naming the privileged `mkdir` as the reason, so the ideal fix does exempt nothing new. (The area summary at the top of this file cites this finding as SUPPORT-5; it is SUPPORT-4.)

**Correction.** The prose's central claim -- "the split is recorded; its consequence, two modes for one directory, is not" -- is false, and that is why confidence drops to 4. `CLIPathInstallerTests.swift:111-128` is a test named "a bin directory the installer has to create is owner-only" whose preamble states the decision outright: "the installer creates it at 0700 rather than at whatever the umask allows ... the symlink itself is one of the three artifacts that stay at the umask default, and it would be easy to read that as covering the directory too." So 0700 is a written, tested choice that anticipates exactly the reading proposed here. The finding survives as the narrower true thing -- the two branches disagree, and only one of them was decided on purpose -- but it is a disagreement to put to the user, not a defect to fix silently, and the fix deletes a test whose preamble argues against it. Two further notes for whoever takes it up. Reachability is thin: `deps.destinationURL` is the fixed `/usr/local/bin/danterm`, and the unprivileged branch only creates the parent when `/usr/local` is user-writable *and* `/usr/local/bin` is absent -- otherwise `mkdir` returns `EACCES`, `isPermissionDenied` catches it, and the privileged branch runs instead. And the only coherent unification is the umask-default one the finding proposes: making both branches 0700 would leave a root-owned `drwx------` on the PATH, which is strictly worse than either mode today.

**Conflicts with.** Nothing in production code. [SUPPORT-2](#support-2)'s ideal fix touches `DoctorProbeEnv`, which carries `installerDeps: CLIPathInstaller.Dependencies`, but neither change alters that type.

<a id="support-5"></a>

#### SUPPORT-5. Make the atomic write durable by flushing the directory entry, or stop claiming durability

`correctness` &middot; impact 2, confidence 3 &middot; effort small &middot; rewritten

**Files.** `lib/PrivateFile/Sources/PrivateFile/PrivateFile.swift#PrivateFile.writeAtomically(_:to:)`, `lib/PrivateFile/Sources/PrivateFile/PrivateFile.swift#PrivateFile.createFile(_:at:)`

**Problem.** `createFile` fsyncs the staged file's contents, and `writeAtomically` then renames it into place -- but nothing flushes the parent directory, so the rename that publishes the content is not durable. After a power loss or a kernel panic the file's bytes are on disk under a name that may not be, which means the checkpoint the fsync was paid for can be the previous one or absent. The fsync of the content is only worth its cost if the entry that names it is flushed too; today the product pays the expensive half and skips the half that makes it mean something.

**Evidence.** The whole publish step:

```swift
public static func writeAtomically(_ data: Data, to url: URL) throws {
    let staged = url
        .deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
    try createFile(data, at: staged)
    guard rename(staged.path, url.path) == 0 else {
```

and the content flush it builds on, inside `createFile`:

```swift
guard fsync(descriptor) == 0 else { throw privateFileError() }
```

No `open`/`fsync` of `url.deletingLastPathComponent()` appears anywhere in the file. The artifact this serves is the crash checkpoint: `DanTermInstancePaths.recoveryDirectory` is documented as "everything that must survive a crash".

**Ideal fix.** After a successful `rename`, open the parent directory `O_RDONLY` and `fsync` it, inside the seam so every atomic write gets it and no caller can omit it. If that cost is judged not worth paying for a checkpoint written every few seconds, then say so at the seam and drop the content `fsync` with it -- what is not defensible is paying for one half.

**By construction.** Durability becomes a property of `writeAtomically`, not of what each caller remembers to do after it, so the two flushes cannot be separated.

**Cheaper fallback.** none -- the ideal fix is a few lines. The real decision here is whether durability is wanted at all, and that is a decision to record, not a cheaper implementation.

**Verification.** This one cannot be proven by a unit test without a power cut; the honest test is the ordering, not the outcome. Assert at the level of the contract instead: a `PrivateFileTests` case that writes atomically over an existing file and reads back either the old complete content or the new complete content is what already holds, and stays holding. Record the durability decision in the seam's doc comment so the next reader knows which behavior is intended.

**Risk.** A directory fsync per checkpoint adds a synchronous metadata flush on the checkpoint queue. That queue is `.utility` and off the main actor, so it costs latency on the checkpoint, not on drawing -- but on a slow or network volume it is measurable, and the quit checkpoint (`async: false`) fences on it.

**Vetted.** The code is exactly as quoted: `PrivateFile.swift:73-84` (`writeAtomically` stages, `createFile`s, `rename`s) and `:52` (`fsync(descriptor)` inside `createFile`). I searched the whole file: there is no second `Darwin.open` of a directory and no other `fsync`, so the parent entry is never flushed. `InstancePaths.swift:36-37` does document `recoveryDirectory` as holding "everything that must survive a crash". The POSIX half of the claim -- a `rename` is not durable until the containing directory is flushed -- is correct as stated.

**Correction.** The reasoning on top of that evidence does not hold, which is why this is rewritten and confidence drops to 3. Three things.

First, the reference check the finding never ran. `references/xnu/bsd/sys/fcntl.h:305` defines `F_FULLFSYNC` as "fsync + ask the drive to flush to the media", and `references/xnu/bsd/kern/kern_descrip.c:3960` spells it out further: "F_FULLFSYNC: // fsync + flush the journal + DKIOCSYNCHRONIZE". So on Darwin plain `fsync` neither flushes the journal nor the drive's own cache. Adding a directory `fsync` therefore does *not* buy power-loss durability either -- both halves would need `fcntl(F_FULLFSYNC)`, at a much higher cost than the finding budgets for. "Pay for the other half" is not a small change.

Second, the two flushes are not two halves of one guarantee. The content `fsync` buys something the directory flush does not: it keeps a torn or short file from becoming reachable under the destination name, which matters on every crash, not only a power cut. So the finding's alternative -- "drop the content `fsync` with it" -- would give up a real property to save a syscall, and should not be carried into a plan.

Third, the harm needs a power cut or a kernel panic, and the artifact this protects is a session-restore checkpoint whose own doc comment means an app crash by "crash". An app crash or a `kill` leaves the rename already in the VFS, so the checkpoint is there. A power cut costs at most one checkpoint generation, with the previous one still on disk.

The finding as it should read: *`writeAtomically` states no durability level, and the two calls it does make imply one it does not deliver. Decide what level the recovery checkpoint wants -- almost certainly "survives an app crash", which the code already gives -- and say so in the seam's doc comment.* That is a documentation commit, not a correctness fix, and it is what this finding's own Verification paragraph already lands on.

**Conflicts with.** [SUPPORT-1](#support-1) and [SUPPORT-3](#support-3) edit `PrivateFile.swift`, but different declarations, so all three are independent. Nothing in another lane touches `writeAtomically`; PERSIST cites it only as evidence that a partial file is unreadable.

<a id="support-6"></a>

#### SUPPORT-6. Split an oversized IPC batch by measured element size instead of re-encoding the whole batch per halving

`cost` &middot; impact 2, confidence 4 &middot; effort medium &middot; rewritten

**Files.** `lib/DanTermSupport/Sources/DanTermSupport/IpcConnection.swift#IpcConnection.writeGroup(method:group:params:)`, `app/PaneTapeBroker.swift#writePaneTapeRecords`

**Problem.** When a batch's encoded line would pass the 16MB framing bound, `writeGroup` halves the group and recurses -- and each level re-encodes from scratch, on top of the full-size encode that discovered the problem. A batch that needs k halvings is encoded roughly 2^k+1 times its own size in total, and `params:` also copies the slice into a fresh `Array` at every level. The path this hits is the pane-tape sync, which the file's own comment describes as opening "with multi-megabyte sync chunks", so it is the large batches -- the ones already the most expensive to encode -- that pay the multiplier.

**Evidence.** The split:

```swift
if line.count - 1 > IpcLineFramer.maxLineBytes, group.count > 1 {
    let middle = group.startIndex + group.count / 2
    let first = writeGroup(method: method, group: group[group.startIndex..<middle], params: params)
    guard first == .flushed else { return first }
    return writeGroup(method: method, group: group[middle...], params: params)
}
```

The bound it measures against:

```swift
// lib/DanTermProtocol/Sources/DanTermProtocol/IpcLineFramer.swift:16
public static let maxLineBytes = 16 * 1024 * 1024
```

and the per-level copy at the caller:

```swift
// app/PaneTapeBroker.swift#writePaneTapeRecords
params: { group in
    PaneTapeEventNotification(subscription: subscription, records: Array(group))
},
```

**Ideal fix.** Encode each element once, keep its byte length, and cut the group at the running sum that fits inside the bound minus the envelope's own overhead. Then every element is encoded exactly once no matter how many lines the batch takes, and the split point is the largest that fits rather than a power of two. It needs the params wrapper to be able to take pre-encoded element bytes, which is the design change that makes this medium rather than small.

**By construction.** The number of encodes stops depending on how far over the bound a batch is; it becomes exactly one per element, so the pathological case disappears rather than being made rarer.

**Cheaper fallback.** Keep halving but stop discarding the work: when a half fits, its encoded line is already in hand -- today it is re-encoded inside the recursive call. Memoizing the per-half encode removes the outermost redundant pass but leaves the total super-linear in the number of splits.

**Verification.** Cost claim, so the experiment, not a result: follow a pane whose scrollback encodes to well over 16MB (`danterm tape follow` against a pane replayed from a large scrollback), and instrument `writeGroup` to count total bytes handed to `encodeIpcLine` for one delivery. The number that must move is total encoded bytes per delivered batch: it should equal roughly the sum of the lines actually written, instead of today's multiple of it. Wall-clock time to first complete sync on the follower is the user-visible number.

**Risk.** Wire order and the framing bound are the guarantees here, and a size-summed split must keep both -- in particular the envelope overhead must be accounted for, or a group that measured as fitting produces a line the reader refuses. The existing `IpcConnectionWriteTests` split coverage is the guard.

**Vetted.** The three quotes are exact: `IpcConnection.swift:364-387` (`writeGroup`, the `line.count - 1 > IpcLineFramer.maxLineBytes, group.count > 1` guard, and the two recursive calls), `IpcLineFramer.swift:16` (`maxLineBytes = 16 * 1024 * 1024`), and `PaneTapeBroker.swift:369-376` (`params:` closing over `Array(group)`). The path is reachable, and I found the mechanism the finding did not name: `PaneTapeStreamState.swift:434` chunks a sync payload at `IpcLineFramer.maxLineBytes / 4`, so a large opening arrives as N records of about 4MB each, base64-expanded to roughly 5.3MB apiece in JSON. Four such records already pass the bound, so an ordinary `danterm tape follow` against a pane with a big retained tape does take the split branch.

**Correction.** The cost model is wrong, and it is the load-bearing sentence. "A batch that needs k halvings is encoded roughly 2^k+1 times its own size" would be true if the recursion re-encoded the full batch at every node; it does not. Each *level* of the recursion encodes each element at most once, so the levels sum to at most N bytes each and the total is `(k+1) * N`, with `k = ceil(log2(N / 16MB))`. A 53MB batch (ten 4MB sync records) encodes about 160MB, not 480MB: a 3x waste, logarithmic in the overshoot, not exponential. The finding survives at the same score because 3x of a multi-megabyte base64 JSON encode on a stream open is still worth removing, but "the pathological case" language should go -- there is no pathological case, only a small constant factor.

That also opens a fix the finding does not consider, and it is much cheaper than the "medium" ideal. Splitting the group into `ceil(measured / bound)` equal parts in one step, instead of halving recursively, caps the total at `2 * N` for any overshoot: one full-size encode to measure, then one encode per element. It needs no pre-encoded-bytes plumbing through the `params` wrapper and no change to `PaneTapeEventNotification`, so it is a small change that captures most of the win. The per-element-length ideal still beats it (`1 * N` versus `2 * N`) and still gives the largest-fitting split; the question for the user is whether the params redesign is worth the second halving of an already logarithmic cost. Note too that `Array(group)` is a shallow element copy, not a deep one, so the copy the finding lists beside the encode is the smaller term.

**Conflicts with.** Nothing. PTY's lane already checked this and says so explicitly at `PTY.md:365-367` -- SUPPORT's `PaneTapeBroker` finding is in `writePaneTapeRecords`, not the follow path. IPC's lane read `IpcLineFramer` and `IpcConnection` but produced no finding on `writeGroup` or `writeBatchedNotification`; its `IpcLineFramer` remark is in Dropped.

#### Dropped (SUPPORT)

- **`IpcAuditEvent`'s tag beside nine optional payloads.** It looks like the canonical "tag plus optionals" shape, but `init` is `private` and every construction goes through a named factory, so the invalid combinations are already unrepresentable at construction. The only remaining cost is that a decoder must handle every optional, and nothing in the product decodes the log -- it is read by humans and `jq`. An enum with associated values would need a hand-written `Codable` to keep the same flat JSON, which is more code for no removed state.
- **`IpcAuditLogWriter` stats the log with `FileManager.attributesOfItem` on every append.** Real per-append work that a `stat` on the path (or `fstat` after open) would do more cheaply, but each append also does an `open`, a full-line `write`, and an `fsync`. The fsync dominates by orders of magnitude, so the dictionary build is not a cost worth a finding.
- **`ChipArtwork.all` is a string-keyed list beside the exhaustive `ChipKind.artwork` switch.** A chip added to `chips.json` but not to `ChipKind` would be silently unreachable. But `ChipArtwork.swift` is generated and deliberately names CoreGraphics only -- `scripts/chip-artwork-isolation-gate.sh` keeps it that way -- so it cannot name `ChipKind`, and the string list is the seam that isolation buys. The `ChipKind` switch is exhaustive, so the dangerous direction (a kind with no artwork) is already a compile error.
- **`DanTermInstancePaths.ipcAuditDirectory` is an alias for `recoveryDirectory`.** A second name for the same value, which usually reads as dead vocabulary -- but here it states an intent ("the audit log lives with the recovery files on purpose") at the one place the intent could otherwise be lost. Keeping it.
- **`PrivateFile.makeDirectory` uses `stat` rather than `lstat` on the `EEXIST` branch**, so a symlink pointing at a directory is accepted and `chmod` lands on its target. Reachable only by something that can already write into DanTerm's own Application Support or Caches tree, which is the same privilege the artifacts themselves have. Not worth a finding on its own; worth a line if that branch is ever touched.
- **`TailnetBindAddress.resolve` checks `host == "::"` after splitting on the last colon**, which that split can never produce. Dead vocabulary in one guard, too small to spend a finding on.
- **`app/AppRuntime.swift#writeReplayFile` uses `writeAtomically` for a freshly minted UUID filename** where `createFile` would do, paying a staged sibling and a rename for a name nothing can be racing. Correct as written, and the extra syscalls are noise against writing a whole scrollback.


### Area: AppKit runtime: reconcile, panes, splits, and the sidebar (`CHROME`)

_Scope: `app/Reconcile.swift`, `app/ReconcileOutbox.swift`, `app/SidebarReconcileDriver.swift`,
`app/SidebarView.swift`, `app/SidebarCellViews.swift`, `app/PaneStripView.swift`,
`app/PaneHost.swift`, `app/PaneWrapperView.swift`, `app/SplitContainerView.swift`,
`app/PaneDividerView.swift`, `app/PaneDragCoordinator.swift`, `app/PaneDragOverlayView.swift`,
`app/PaneLayoutRectBridge.swift`, `app/PaneFocusReconciliation.swift`,
`app/AppPresentationLifecycle.swift`, `app/AppRuntime.swift`, `app/DialogSurfaces.swift`,
`app/SwitcherPanel.swift`, `app/WindowChromeView.swift`, `app/BadgeLabel.swift`,
`app/AppDelegate.swift` (window and split-view assembly only), plus the pure partners in
`lib/DanTermCore/Sources/DanTermCore/PaneLayout.swift`, `Projections.swift`,
`ModelOperations.swift`, `ReconcileFollowUps.swift`._

**The auditor's read on the area.** The model-owned pane geometry decision has landed
cleanly: `paneLayout` is the sole producer of pane rectangles, `SplitContainerView` is flat,
the divider reports rather than moves, and the drag resolves the drop from the pure layout.
The outbox discipline for view-discovered facts is the strongest thing in the tree -- one
ingress, one drain, no send on a reporting stack. The defects that remain share one shape:
a fact that some value already owns is written a second time by hand next to it -- the
sidebar's collapsed width lives only in `NSSplitView`, a badge's visibility is decided by
the badge and then overwritten by the cell, the "last applied sidebar projection" is kept
by two objects with the same name and different values, and a container is built in two
steps so it exists briefly in a state its tab contradicts. The one cost item is the mirror
image: eager mounting sends every hidden tab's child process a resize on every frame of a
window drag. I did not audit the terminal view's own rendering, the todo popovers, the
preferences form, or the theme browser beyond their reconcile seams -- other lanes own
them. I looked at the per-sweep whole-model projection scans and dropped them: the
reconciliation ADR names that cost and explicitly declines to precompute further.

<a id="chrome-1"></a>

#### CHROME-1. Give the sidebar's collapse and width a model slot instead of leaving them in `NSSplitView`

`correctness` &middot; impact 3, confidence 5 &middot; effort medium &middot; confirmed

**Files.** `app/AppDelegate.swift#toggleSidebar`, `app/AppDelegate.swift#splitViewDidResizeSubviews`, `app/WindowChromeView.swift#syncWithSidebarState`, `lib/DanTermCore/Sources/DanTermCore/CommandCatalog.swift#toggleSidebar`

**Problem.** Every other piece of window chrome is a projection reconciled from the model.
The sidebar's collapsed state and its width are not: they live in the `NSSplitView` and are
mutated directly from a menu action. Two things follow. The user's dragged width is thrown
away on the next collapse -- reopening always restores the 200pt minimum, so a sidebar
widened to 300pt comes back at 200pt. And the state is outside the model entirely, so it is
not in the snapshot, not restored after a crash, and not reachable from the `danterm` CLI,
which AGENTS.md says must be able to drive the app.

**Evidence.** The toggle is the whole implementation, and it has no memory:

```swift
@objc func toggleSidebar(_ sender: Any?) {
    if splitView.isSubviewCollapsed(sidebarView) {
        sidebarView.isHidden = false
        splitView.setPosition(Self.minSidebarWidth, ofDividerAt: 0)
        chromeView.syncWithSidebarState(collapsed: false, sidebarWidth: Self.minSidebarWidth)
    } else {
        splitView.setPosition(0, ofDividerAt: 0)
        chromeView.syncWithSidebarState(collapsed: true, sidebarWidth: 0)
    }
}
```

`Self.minSidebarWidth` is `200` (`app/AppDelegate.swift:11`) and doubles as both the drag
minimum (`splitView(_:constrainMinCoordinate:ofSubviewAt:)` returns it) and the restore
width, while `constrainMaxCoordinate` allows 300. `splitViewDidResizeSubviews` reads
`sidebarView.frame.width` and pushes it straight into the chrome; it stores nothing.
Grepping the tree for a stored width or collapsed flag finds only these call sites -- no
model field, no `Msg`, no projection, no snapshot key.

**Ideal fix.** One model field, `sidebarPresentation: SidebarPresentation` holding
`collapsed: Bool` and `width: CGFloat`, written only by `update()` from
`.sidebarToggled` / `.sidebarWidthDragged(width:)`. A `desiredSidebarChrome` projection in
`Projections.swift` and a `reconcileSidebarChrome` pass set the divider position and call
`syncWithSidebarState`; `splitViewDidResizeSubviews` reports the dragged width through the
outbox rather than painting the chrome itself. Collapse then restores the stored width by
construction, and the field rides the existing snapshot and CLI machinery for free.

**By construction.** "Collapsed" and "how wide it was" stop being two independent facts
held by AppKit that only a menu handler keeps in step. The chrome can no longer be told a
width the split view does not have, because one projection is the only writer of both.
`minSidebarWidth` goes back to meaning only the minimum.

**Cheaper fallback.** Store the last non-collapsed width in an `AppDelegate` property and
restore it in `toggleSidebar`. It fixes the visible bug and nothing else: the state is still
invisible to the model, still not persisted, still not scriptable, and the chrome is still
synced by hand from three call sites.

**Verification.** A `DanTermCore` test on the reducer: send `.sidebarWidthDragged(280)`,
then `.sidebarToggled` twice, and assert the model reports collapsed then 280pt again. A
`tests-ui` test drives `AppDelegate.toggleSidebar` twice after setting the divider to 280
and asserts `sidebarView.frame.width == 280`. A snapshot round-trip test asserts the field
survives `toSnapshot` / restore.

**Risk.** The reconcile pass now writes the divider position, so a pass that runs mid-drag
could fight the user's pointer; the drag must report on `splitViewDidResizeSubviews` and the
pass must skip a position it already produced (the same rule the pane divider follows). A
restored snapshot with a width outside 200-300 must clamp on the way in.

**Vetted.** I opened `AppDelegate.swift:732-748` (`toggleSidebar`,
`constrainMinCoordinate`), `:750-752` (`constrainMaxCoordinate`, returns `300`),
`:765-772` (`splitViewDidResizeSubviews`), `:11` (`minSidebarWidth = 200`), and
`WindowChromeView.swift:206-219` (`syncWithSidebarState`). Every quoted line is in the
tree verbatim. `toggleSidebar` really is the whole implementation and really does
restore `Self.minSidebarWidth` unconditionally, so a sidebar dragged to 280 comes back
at 200 -- the user-visible bug is real and one menu keystroke away.
`splitViewDidResizeSubviews` reads `sidebarView.frame.width` and stores nothing.

I checked the two supporting claims. There is no stored width anywhere: `grep` for
`autosaveName` over `app/` returns nothing at all, so `NSSplitView`'s own autosave is
not in play either. And the launch path is a third writer of the same fact --
`AppDelegate.swift:154-155` hard-sets `setPosition(Self.minSidebarWidth)` and syncs the
chrome after the window is ordered front -- so a dragged width does not survive a
relaunch either, which the finding does not say and which strengthens it. The CLI half
holds as written: `grep` for `sidebar` over `IpcDispatch.swift` returns nothing, so no
IPC command reads or writes it. `view.toggle-sidebar` does exist in `CommandCatalog`
(`:12`, `:109`) but that is the menu and keybinding surface, not the CLI.

**Conflicts with.** [CHROME-7](#chrome-7) -- both edit `app/WindowChromeView.swift`, and
CHROME-1's ideal fix makes `syncWithSidebarState` a projection-driven setter while
CHROME-7 deletes its dead twin. They compose (CHROME-1 names CHROME-7 itself); land
CHROME-7 first, it is two lines.

<a id="chrome-2"></a>

#### CHROME-2. Give `SplitContainerView` one presentation entry point that takes the tree and the zoom together

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; rescored

**Files.** `app/SplitContainerView.swift#rebuild`, `app/SplitContainerView.swift#ensureLaidOut`, `app/SplitContainerView.swift#setRootNode`, `app/SplitContainerView.swift#setZoomedPane`, `app/AppRuntime.swift#buildAndInsertContainer`, `app/Reconcile.swift#reconcileContainers`

**Problem.** The container takes its tree in `init` but not its zoom, so it is constructed
in a state its tab may contradict, and the builder has to remember a second call to repair
it. That leaves four public ways to ask for the same layout, two of which have identical
bodies, and it makes the build path solve the layout twice -- once for the unzoomed tree,
once for the zoom. The reconcile executor then carries two arms that differ only in how they
spell the same guard.

**Evidence.** Two names for one method:

```swift
/// Reconciles all direct children for a new or restored tab.
func rebuild() { applyModelLayout() }
...
/// Keeps the old reveal call idempotent while hidden tabs now lay out eagerly.
func ensureLaidOut() { applyModelLayout() }
```

The builder repairs the missing constructor argument after the fact, laying out twice:

```swift
container.rebuild()
container.setZoomedPane(tab.paneTree.zoomedPaneId)
tabContainers[tab.id] = container
```

and the executor spells one operation twice:

```swift
case .setTree(let tabId):
    guard let tab = tabById(tabId, in: model),
          let container = tabContainers[tabId] else { break }
    container.setRootNode(tab.paneTree.root)
case .setLayout(let tabId):
    guard let tab = tabById(tabId, in: model) else { break }
    tabContainers[tabId]?.setRootNode(tab.paneTree.root)
```

**Ideal fix.** `init(tree:zoomedPaneId:wrapperLookup:runtime:frame:)` plus one
`func present(tree: SplitNodeModel, zoomedPaneId: PaneId?)`. `rebuild()`, `ensureLaidOut()`,
`setRootNode(_:)` and `setZoomedPane(_:)` all become that one call; the `.setTree`,
`.setLayout` and `.setZoomedPane` arms of `reconcileContainers` become the same line, and
the reveal arm passes the tab's current tree and zoom instead of relying on the container's
stored copy being fresh. The `ContainerOp` cases stay distinct -- `containerOpsEditVisibleTree`
needs `.setTree` and `.setZoomedPane` to cancel a pane drag while `.setLayout` does not -- but
their executors stop being three different spellings.

**By construction.** A container with a tree but no zoom stops being representable, so no
caller can forget the follow-up and no build can assign a pane the unzoomed rectangle for the
length of one statement. The "two names for `applyModelLayout`" vocabulary disappears.

**Cheaper fallback.** Add the zoom argument to `init` and delete `rebuild()`, leaving
`setRootNode` / `setZoomedPane` / `ensureLaidOut` as they are. That removes the double
layout on build but keeps three entry points and the two duplicated executor arms.

**Verification.** `tests-ui/SplitContainerViewTests.swift`: construct a container for a
two-pane tab zoomed on pane A and assert, without any second call, that pane A's frame is
the container bounds and pane B is hidden. The existing zoom, reveal, tree-edit and
ratio-drag assertions in that file must keep passing through the single entry point --
they are the behavioral net for the change, though the calls themselves have to be
rewritten, which is where the medium effort sits.

**Risk.** Purely mechanical, but `tests-ui/SplitContainerViewTests.swift` drives the old
API roughly 60 times, so the rewrite touches every test in the file. A container that
stops carrying its own tree would break `currentPaneLayout()`, which the drag coordinator
calls outside any pass -- the stored tree has to stay.

**Vetted.** I opened `SplitContainerView.swift:1-125` end to end and
`Reconcile.swift:145-184` and `AppRuntime.swift:1778-1796`. Every quote is exact:
`rebuild()` and `ensureLaidOut()` really are two names for `applyModelLayout()`; `init`
really takes `rootNode` and not the zoom; the builder really calls `rebuild()` then
`setZoomedPane(...)`; and the `.setTree` / `.setLayout` arms really do differ only in
whether the container is bound by `guard let` or by optional chaining. I counted the
test-file exposure: `grep -cE '\.(rebuild\(\)|ensureLaidOut\(\)|setRootNode|setZoomedPane)'`
over `tests-ui/SplitContainerViewTests.swift` gives 56, so the auditor's "roughly 60"
is right and the medium effort is real. `currentPaneLayout()` does read the stored
`rootNode` and is called from the drag coordinator outside any pass, so the Risk note
holds.

**Correction.** Drop the "makes the build path solve the layout twice" half of the
problem statement; it is very nearly vacuous. `setZoomedPane` opens with
`guard zoomedPaneId != paneId else { return }`, and a container is constructed with
`zoomedPaneId == nil`, so the second `applyModelLayout()` fires only when the tab being
built is already zoomed -- that is a snapshot restore, not tab creation. Even then the
container has not yet been through an AppKit layout pass, so, as the lane's own Dropped
list already establishes, both solves coalesce and no false grid reaches a child. What
survives is the vocabulary: four public entry points for one operation, two of them
byte-identical, a constructor that cannot express the zoom, and three executor arms
spelling one call three ways. That is worth a 2, not a 3.

**Conflicts with.** [MODEL-3](MODEL.md#model-3) replaces `ContainerShape.layout` and the
`oldShape.layout != shape.layout` comparison in `computeContainerOps`; CHROME-2 keeps the
`ContainerOp` cases and rewrites only their executors in `Reconcile.swift`. Independent,
but both land in the container-op machinery -- rebase whichever goes second.
[CHROME-3](#chrome-3) names `SplitContainerView#layout` and
`Reconcile#reconcileContainers` in its Files line; its actual edit is in
`SwiftTerminalSessionView`, so the two do not collide in practice.

<a id="chrome-3"></a>

#### CHROME-3. Stop submitting a new grid to every hidden tab's child process on every frame of a window resize

`cost` &middot; impact 3, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `app/AppRuntime.swift#buildAndInsertContainer`, `app/SplitContainerView.swift#layout`, `app/SwiftTerminalSessionView.swift#setFrameSize`, `app/Reconcile.swift#reconcileContainers`

**Problem.** Every tab's container is mounted eagerly and autoresizes with the content area,
so a window drag re-frames the panes of every tab, not just the selected one. A pane frame
change reaches the terminal view's `setFrameSize`, which synchronously derives a grid and
pushes it to the child. With twelve tabs open, one window drag sends a `TIOCSWINSZ` storm to
every shell and TUI the user cannot see, once per resize frame, for the whole drag. Nothing
observes those intermediate sizes: the panes are hidden, and the ADR's justification for not
debouncing -- "a stream of true sizes during live window resize remains valid" -- is about
what the user is watching.

**Evidence.** The container follows the content area unconditionally:

```swift
container.autoresizingMask = [.width, .height]
```

and re-solves the layout on every AppKit layout pass, hidden or not:

```swift
override func layout() {
    super.layout()
    applyModelLayout()
}
```

The submission is synchronous with the frame assignment:

```swift
override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    ...
    synchronizePresentation()
}
```

and `synchronizePresentation` gates only on a torn-down view, non-zero bounds and a window --
not on `setVisible` -- before calling `controller.setGridDimensions(dimensions, pinned:)`.

**Ideal fix.** Let the pane's model visibility decide when a derived grid is submitted: a
pane the model reports hidden records its geometry and submits nothing, and the transition
to visible submits once. The pane already receives that fact -- `syncPaneVisibility` pushes
`session.setVisible(_:)` to every host -- so the authority exists and no new mirror is
needed; what is missing is that `setGridDimensions` ignores it. Note this is a real behavior
choice, not only an optimization: a program in a background tab would then learn the new
window size when its tab is revealed rather than while the user drags. That is what tmux
does, but it is a change worth stating out loud rather than slipping in.

**By construction.** Nothing new becomes unrepresentable; this is a cost finding. It does
remove the situation where a resize's cost scales with how many tabs exist rather than with
what the user is looking at.

**Cheaper fallback.** Leave the submissions and accept them: pane counts are human-scale and
a SIGWINCH is cheap. What that fails to remove is the redraw each background program does in
response -- the cost is paid in the children, not in DanTerm, so DanTerm's own profile will
never show it.

**Verification.** Instrument `controller.setGridDimensions` with a per-pane counter behind
the existing `DANTERM_TERMINAL_BENCHMARK` build flag. Open one tab with two panes, then
twelve tabs with two panes each; in both cases drag the window's right edge across 300
points at a fixed rate. The number that must move is grid submissions for panes in
non-selected tabs: today it should scale with (resize frames x hidden panes); after the fix
it must be 0 during the drag and exactly one per pane at reveal. Submissions for the
selected tab's panes must not change at all.

**Risk.** A background program that queries its size between the resize and the reveal reads
a stale one. A pane whose grid is claimed by a client (`gridOverride`) already pins its
dimensions and must keep behaving identically. Getting the reveal transition wrong would
show up as a background tab that draws at the old grid after being selected -- exactly the
class the pane-geometry ADR exists to prevent, so the reveal path has to be tested directly.

**Vetted.** I opened `AppRuntime.swift:1780-1795` (`autoresizingMask = [.width, .height]`),
`SplitContainerView.swift:51-54` (`layout()` -> `applyModelLayout()`),
`SwiftTerminalSessionView.swift:693-700` (`setFrameSize` -> `synchronizePresentation`),
`:1539-1584` (`synchronizePresentation`), `TerminalPaneSession.swift:734-746`
(`setGridDimensions`, `setVisible`), and `TerminalPTYHost.swift:2284-2304`
(`applyResize`). Every quoted line is verbatim.

I raised confidence to 5 because the tree proves the mechanism rather than leaving it to
inference. `tests-ui/SplitContainerViewTests.swift:178-227` ("Claude Code 2026-08-16
nested split submits only true model slots") runs its whole body under
`for hidden in [false, true]`, sets `container.isHidden = hidden`, and asserts a hidden
container's panes still receive exactly one grid each. A hidden pane really does submit.
`setVisible` really does gate only planning (`if visible, isRenderingAvailable {
planIfNeeded(...) }`), so `setGridDimensions` really ignores it and the authority the
ideal fix wants really is already on the session.

**Correction.** Two things in the prose above are wrong, one in each direction.

The rate is overstated. `synchronizePresentation` does not submit on every frame: it
computes `geometryChanged = dimensions != currentDimensions || pinned != currentGridPinned`
and calls `controller.setGridDimensions` only inside `if geometryChanged`. So a hidden
pane submits once per *cell-boundary crossing*, not once per resize frame -- for a 300pt
horizontal drag over a ~7pt cell that is on the order of 40 submissions per hidden pane,
not hundreds. The evidence paragraph's "gates only on a torn-down view, non-zero bounds
and a window" omits that guard and should say so.

The cost is understated. The Cheaper fallback claims "the cost is paid in the children,
not in DanTerm, so DanTerm's own profile will never show it." That is false.
`TerminalPTYHost.applyResize` does the `TIOCSWINSZ` *and then*
`terminal.resize(columns:rows:)` plus a flight-tape record and
`markFrameUpdatePendingIfNeeded()` -- a full reflow of that pane's grid and scrollback,
inside DanTerm, per submission. The charge is (boundary crossings x hidden panes) reflows
of arbitrarily large scrollbacks, off the main actor but not free, and the fix collapses
them into one reflow at reveal. That is what keeps this at impact 3 despite the lower
rate.

One thing the Risk paragraph misses: the incident test quoted above pins the current
behavior for hidden containers deliberately, naming the 2026-08-16 Claude Code incident.
The fix must rewrite that test's hidden arm, which means re-deciding what the incident's
guarantee means for a background tab. Treat that as part of the "behavior choice, not
only an optimization" the finding already flags, and do not let the rewrite quietly
weaken what the visible arm asserts.

**Conflicts with.** [INPUT-3](INPUT.md#input-3) restructures the same method:
it folds `currentMetrics` / `currentDimensions` / `currentGridPinned` / `displayedCellSize`
into one `PanePresentation` value assigned in `synchronizePresentation`, which is exactly
where CHROME-3 adds its visibility gate. Textually incompatible; the intents are
independent, so land INPUT-3 first and add the gate to the folded value.

<a id="chrome-4"></a>

#### CHROME-4. Keep one record of the last applied sidebar projection, not one in the driver and one in the view

`structural` &middot; impact 1, confidence 5 &middot; effort small &middot; rewritten

**Files.** `app/SidebarReconcileDriver.swift#reconcile`, `app/SidebarView.swift#applySidebarOps`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#advanceSidebarCache`

**Problem.** Two objects each keep a field called `appliedProjection` for the same pass, both
written inside the same call, and they deliberately hold different values. The driver stores
the *merged* projection, which retains the old row values for rows the view could not paint;
the view stores the *raw new* projection. Nothing states or enforces the relationship, and
the view's field is documented as "the projection that supplied the mounted row", which is
false for exactly the rows the merge exists to handle.

**Evidence.** The driver:

```swift
let advancedProjection = advanceSidebarCache(
    old: appliedProjection,
    new: newProjection,
    suppressedRenameTarget: sidebarView.activeRenameTarget,
    unappliedTabIds: unapplied.tabs,
    appliedGroupRenders: unapplied.groupRenders)
appliedProjection = advancedProjection
```

The view, at the top of the same call, before any op runs:

```swift
let priorFocusedTabId = appliedProjection?.selectedTabId
let priorRename = appliedProjection?.rename
appliedProjection = projection
```

`advanceSidebarCache` is explicitly a merge -- `retainTabProjection(id)` writes `oldTab`
back over `merged` for every id in `unappliedTabIds` -- so the two fields diverge whenever a
visible row has no materialized cell.

**Ideal fix.** The view owns the single record and the driver reads it. `applySidebarOps`
returns what it could not apply; the driver computes the merged projection and hands it back
with one `sidebarView.setAppliedProjection(merged)` at the end of the pass, and the driver's
own field is deleted. The view's two "prior" reads happen before that write, so they are
unaffected. One writer, one value, and the field's name becomes true.

**By construction.** "Two records of what the sidebar shows" stops being representable, the
way `ActiveRenameSlot.take()` already made "two records of who owns the field editor"
unrepresentable a few lines away in the same file.

**Cheaper fallback.** Rename the view's field to `lastOfferedProjection` and document the
divergence. That fixes the lie and leaves the duplication.

**Verification.** `tests-ui/SidebarSelectionCacheTests.swift` style: run a pass with a
visible row whose cell is not materialized, then assert the view's stored projection equals
the driver's `SidebarReconcileResult.appliedProjection`. The existing retry behavior --
a second pass still repaints the unapplied row -- must keep passing.

**Risk.** The context menus and drop validation read the view's field. Switching them from
the raw projection to the merged one changes what a menu reports for a row whose cell was
never materialized: it would name the row's painted state rather than the model's latest.
If that is wrong for menus, the fix is to have menus read the model through the runtime, not
to keep a second projection.

**Vetted.** I opened `SidebarReconcileDriver.swift` end to end, `SidebarView.swift:240`
(the view's `appliedProjection`) and `:374-388` (the top of `applySidebarOps`), and
`Projections.swift:1143-1195` (`advanceSidebarCache`). Both quotes are exact, both fields
really are named `appliedProjection`, both really are written inside the same call, and
`retainTabProjection` / `retainGroupRenderedValue` really do write old values back over
`merged`. The duplication is real.

**Correction.** The finding overstates both the lie and the divergence, and its ideal fix
does not stand up on its own.

The doc comment it calls a lie is not on the field. `SidebarView.swift:240` carries no
comment at all; "the projection that supplied the mounted row" is at `:1025-1026`, on
`contextMenu(forGroupId:)`, describing where that menu reads enablement.

The divergence is narrower than "whenever a visible row has no materialized cell".
`advanceSidebarCache` starts from `var merged = new` and only ever writes back
`merged.groups[gi].tabs[ti]` and `merged.groups[gi].rendered`. Every top-level field is
`new` in both records -- and those are what the view actually reads:
`selectedTabId` (`:835`, `:856`), `rename` (`:386`), `isSingleGroupMode` (`:257`),
`singleGroupDropTargetId` (`:976`, `:1009`), `canDeleteGroups` (`:1042`). Not one of them
can diverge. The single reader that touches a retained value is
`contextMenu(forTabId:clickedRow:)` (`:1096`), which pulls `SidebarTabProjection` values
out of `projection.groups` to build its labels.

Which is exactly the reader the auditor's own Risk paragraph concedes the merge would
make *worse*. So the stated ideal fix -- view owns the merged record, driver reads it --
buys one deleted field and pays for it by feeding the one divergent reader the staler of
the two values. The fix that survives is the one the Risk paragraph names in passing:
have the tab context menu read `tabForPane` / the model through the runtime, after which
the view's copy has no reader that cares and the two records collapse for free. Until
that is done, the honest change is the "cheaper fallback" -- rename the view's field to
`lastOfferedProjection`. Scored down to 1 on that basis: the duplication is a naming
hazard, not a defect with a clean removal.

**Conflicts with.** [MODEL-1](MODEL.md#model-1) edits the same pass
(`computeSidebarRowOps` / `sidebarSequenceOps`) but not `applySidebarOps` or the
`appliedProjection` fields; that lane has already checked and reports them independently
implementable. I agree.

<a id="chrome-5"></a>

#### CHROME-5. Let one owner decide a badge's visibility instead of the badge deciding and the cell overwriting

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `app/BadgeLabel.swift#updateBadge`, `app/SidebarCellViews.swift#SidebarGroupCellView.apply`

**Problem.** `BadgeLabel.updateBadge` owns both the text and the hidden flag. The group cell
calls it and then writes `isHidden` again with a different rule, and separately drives the
tab-count badge by assigning `stringValue` directly and hiding it by hand. So one badge has
two writers of one flag and the correct result depends only on statement order, while a
second badge of the same type bypasses the badge's own update method entirely.

**Evidence.**

```swift
/// Updates the displayed count and hides zero counts.
func updateBadge(count: Int) {
    stringValue = "\(count)"
    isHidden = count == 0
}
```

```swift
alertBadge.updateBadge(count: group.unreadAlertCount)
alertBadge.isHidden = group.unreadAlertCount == 0 || !group.isCollapsed
tabCountBadge.stringValue = "\(group.tabCount)"
tabCountBadge.isHidden = !group.isCollapsed
```

Move the `isHidden` line above the `updateBadge` line and an expanded group with unread
alerts shows a badge it must not show. Nothing in the type prevents that.

**Ideal fix.** `BadgeLabel.apply(_ count: Int?)`, where `nil` means "not shown", and make it
the only writer of `stringValue` and `isHidden` (the `stringValue` override can become
private). The projection decides: `SidebarGroupProjection.Rendered` already carries
`unreadAlertCount` and `isCollapsed`, so it can carry `alertBadge: Int?` and
`tabCountBadge: Int?` instead, and the cell just forwards them. The pane toolbar's
`alertBadge.updateBadge(count: render.unreadAlertCount)` becomes
`alertBadge.apply(render.unreadAlertCount == 0 ? nil : render.unreadAlertCount)` -- or the
toolbar projection carries the optional too.

**By construction.** A badge whose text and visibility disagree stops being representable,
and the rule for when a group's alert badge is shown is stated once, in the pure projection
that is already unit-tested, rather than in an AppKit cell.

**Cheaper fallback.** Add a `updateBadge(count:visible:)` overload and route both call
sites through it. Fewer moving parts, but the visibility rule stays in the view.

**Verification.** `lib/DanTermCore` projection test: a group with unread alerts that is
expanded projects a nil alert badge; the same group collapsed projects the count. A
`tests-ui` cell test asserts the rendered badge's `isHidden` matches, driven from the
projection alone.

**Risk.** `ToolbarDragHandleView.mouseDown` reads `!badge.isHidden` to decide whether a
press landed on the pane's alert badge, so the flag must keep meaning exactly what it means
today for the pane toolbar.

**Vetted.** I opened `BadgeLabel.swift` end to end and `SidebarCellViews.swift:216-224`.
Both quotes are exact: `updateBadge(count:)` writes `stringValue` and `isHidden`, and
`SidebarGroupCellView.apply` really does overwrite `isHidden` on the next line with a
different rule and drive `tabCountBadge` by assigning `stringValue` and `isHidden`
directly, never through `updateBadge`. The Risk is real too --
`ToolbarDragHandleView.mouseDown` (`PaneWrapperView.swift:709`) and `mouseUp` (`:723`)
both gate on `!badge.isHidden`. The tab cell (`:115`) and the chrome bell (`:245`) use
`updateBadge` unmodified, so the two-writer shape exists only in the group cell.

No live bug: today's statement order gives the correct result, and nothing else writes
either flag. This is a latent-order hazard plus one badge that bypasses its own type's
update method.

**Correction.** The "By construction" claim is half unenforceable and the ideal fix as
written does not compile.

`stringValue` is an override of an open `NSTextField` property, so it cannot be made
`private` -- Swift requires an override to be at least as accessible as the declaration
it overrides. And `isHidden` is inherited from `NSView`, so no `BadgeLabel` API can ever
be its "only writer": any holder of the badge can still assign it, which is precisely
what the group cell does today and what `ToolbarDragHandleView` reads. A badge whose text
and visibility disagree does *not* stop being representable.

What the fix does deliver, and it is the part worth having: the rule for when a group's
alert badge is shown moves out of an AppKit cell and into `SidebarGroupProjection.Rendered`
as `alertBadge: Int?` / `tabCountBadge: Int?`, where it is pure and already unit-tested,
and both badges then go through one `apply(_:)` by convention rather than by type. Keep
the finding at 2 for that; state the payoff as "one stated rule in tested pure code",
not as unrepresentability.

**Conflicts with.** None. Nothing else in the corpus touches `BadgeLabel` or
`SidebarCellViews`. [CHROME-4](#chrome-4) edits `SidebarView`/`SidebarReconcileDriver`
and [MODEL-1](MODEL.md#model-1) edits `computeSidebarRowOps`; neither reaches the cell's
`apply` or the group projection's `Rendered` fields.

<a id="chrome-6"></a>

#### CHROME-6. Decide whether a pane drag may start from the pane's own toolbar projection, not from the selected tab

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `app/PaneWrapperView.swift#ToolbarDragHandleView.mouseDragged`, `app/AppRuntime.swift#startPaneDrag`, `app/PaneWrapperView.swift#applyToolbarRender`

**Problem.** The drag handle re-derives "does this pane's tab have splits" by reaching into
the model for the *selected* tab, even though the wrapper it lives in already holds a
`PaneToolbarRender` carrying `hasSplits` for the pane the handle belongs to. `startPaneDrag`
makes the same substitution a second time to find the container. The two are equivalent only
because a non-selected tab's container is hidden and therefore untouchable; nothing in the
types says so, and the rule is written twice more than it needs to be.

**Evidence.**

```swift
guard let tab = selectedTab(in: runtime.model) else { return }
let hasSplits: Bool
if case .split = tab.paneTree.root { hasSplits = true } else { hasSplits = false }
guard hasSplits || totalTabCount(runtime.model) > 1 else { return }
```

while the same view already applies, and stores, the projected answer:

```swift
private var lastToolbarRender: PaneToolbarRender?
...
zoom.isEnabled = hasSplits || isZoomed
```

and the runtime repeats the substitution:

```swift
func startPaneDrag(paneId: PaneId) {
    cancelPaneDrag()
    guard let contentArea = contentArea else { return }
    guard let tab = selectedTab(in: model) else { return }
    guard let container = tabContainers[tab.id] else { return }
```

**Ideal fix.** Put `canDrag` on `PaneToolbarRender` -- the pure projection already knows the
pane's tab, its tree, and the tab count -- and have the handle read the render it was given.
`startPaneDrag` resolves the container through `tabForPane(paneId, in: model)`, so it names
the pane's own tab rather than assuming it is the selected one.

**By construction.** The drag-eligibility rule stops existing in an AppKit event handler at
all, so it cannot drift from the menu's `Zoom Pane` enablement, which is computed from the
projection. The "selected tab is the pane's tab" assumption stops being load-bearing in two
places.

**Cheaper fallback.** Leave the eligibility rule where it is and change only
`selectedTab(in:)` to `tabForPane(paneId:in:)` at both sites. That removes the wrong
authority without removing the duplicated rule.

**Verification.** `lib/DanTermCore` projection test: a lone pane in the only tab projects
`canDrag == false`; the same pane once a second tab exists projects `canDrag == true`; a
split pane projects true either way. `tests-ui/PaneWrapperViewTests.swift` drives a drag
past the 5pt threshold on a wrapper whose applied render says false and asserts no
`startPaneDrag`.

**Risk.** The render is applied by a reconcile pass, so a wrapper that has never been
reconciled has `lastToolbarRender == nil` and must fail closed (no drag) rather than open.
A newborn pane is reconciled in the same sweep that creates it, so the window is one frame,
but the nil case still needs an explicit answer.

**Vetted.** I opened `PaneWrapperView.swift:736-756` (`ToolbarDragHandleView.mouseDragged`),
`:58` (`lastToolbarRender`), `:386-388` and `:428-431` (`applyToolbarRender` and the zoom
button), `:565-576` (the pane menu), and `AppRuntime.swift:1321-1332` (`startPaneDrag`).
Every quote is exact. `PaneToolbarRender` does carry `hasSplits` and `isZoomed`
(`Projections.swift:609-610`), and `tabForPane(_:in:)` does exist
(`ModelOperations.swift:574`), so the ideal fix is buildable as described. Confidence
raised to 5 on that basis.

**Correction.** Two claims need adjusting, and the finding is smaller than they make it
sound.

There is no reachable defect, and the code is not silent about why. The lines directly
above the guard spell the assumption out in a five-line comment ("Allow the drag unless
there's nowhere to drop ... A zoomed pane always has splits ..."). A non-selected tab's
container is hidden, so no drag handle in one can receive a `mouseDragged`; the
substitution is sound today. Read this as vocabulary, not a latent bug.

The "cannot drift from the menu's `Zoom Pane` enablement" payoff does not exist, because
they are not the same rule. Zoom enablement is `hasSplits || isZoomed` (`:568`); drag
eligibility is `hasSplits || totalTabCount(model) > 1` (`:755`). They share one term and
were never at risk of converging. State the payoff as what it actually is: one
eligibility rule moved out of an AppKit event handler into the pure, tested projection,
and one wrong authority (`selectedTab`) replaced by the right one (`tabForPane`) at two
sites.

Note that `canDrag` is a genuinely new field -- `PaneToolbarRender` carries `hasSplits`
but not the tab count -- and `desiredPaneToolbar` already walks `group -> tab ->
forEachPane`, so it has both facts in hand and the addition is cheap.

**Conflicts with.** [MODEL-6](MODEL.md#model-6) edits `desiredFocusBorders`,
`desiredSearchOverlays` and `desiredPaneConfig` in the same file but not
`desiredPaneToolbar`, which is the one CHROME-6 extends. Same file, disjoint functions;
independent.

<a id="chrome-7"></a>

#### CHROME-7. Delete `WindowChromeView.updateSeparatorPosition`

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; confirmed

**Files.** `app/WindowChromeView.swift#updateSeparatorPosition`

**Problem.** The method has no caller. Its two lines are duplicated verbatim inside
`syncWithSidebarState`, which is what the divider drag actually goes through, so the file
carries a second entry point for chrome geometry that no longer exists as a path.

**Evidence.**

```swift
/// Keep the title position aligned with the NSSplitView divider during drag.
func updateSeparatorPosition(_ sidebarWidth: CGFloat) {
    borderLeadingConstraint.constant = sidebarWidth
    titleLeadingOffset.constant = sidebarWidth + 8
}
```

`grep -rn "updateSeparatorPosition" app lib integrations` returns only this definition.
`AppDelegate.splitViewDidResizeSubviews`, the drag path the doc comment describes, calls
`syncWithSidebarState(collapsed:sidebarWidth:)` instead.

**Ideal fix.** Delete it. If CHROME-1 lands, the surviving setter is driven by the chrome
projection and this shape does not come back.

**By construction.** `n/a` -- this is dead vocabulary, not a representable bad state.

**Cheaper fallback.** `none -- the ideal fix is small.`

**Verification.** The build is the test: nothing references it. `just lint` and
`tests-ui/` stay green.

**Risk.** None.

**Vetted.** I grepped the whole repo, not just `app lib integrations`:
`grep -rn "updateSeparatorPosition"` excluding `.build`, `references` and `.git` returns
`app/WindowChromeView.swift:221` and nothing else outside this report -- no test, no
doc, no `#selector`. The method is at `:220-224` exactly as quoted, and its two lines
are the `else` branch of `syncWithSidebarState` (`:212-214`) verbatim.
`splitViewDidResizeSubviews` (`AppDelegate.swift:765-772`) does call
`syncWithSidebarState`, so the doc comment describes a path that goes elsewhere.
Straight deletion, nothing to weigh.

**Conflicts with.** [CHROME-1](#chrome-1) -- same file, and CHROME-1 rewrites the
surviving `syncWithSidebarState` call sites. No real collision: delete this first.

#### Dropped (CHROME)

- **Per-sweep whole-model projection scans** (`desiredContainerShapes`,
  `effectivePaneVisibility`, `desiredPaneToolbar`, `desiredSidebar`, ... each walk every tab
  and pane on every reconcile). Owned and explicitly declined by
  `docs/design/2026-05-27-model-driven-view-reconciliation.md#Projection Scan Cost`: "Do not
  precompute further reconcile inputs speculatively."
- **`ContainerLayoutNode` materialized per tab per sweep.** `containerLayoutNode` allocates
  one indirect-enum box per split node for every tab on every sweep purely so the result can
  be compared. Real, but the node count is (tabs x splits) at human scale, and storing the
  model tree in the cache instead would retain pane payload -- a worse trade. Not worth a
  finding without a measurement.
- **`applyDiff` rebuilds each cache dictionary every call** (`cache = cache.filter { ... }`,
  five caches per sweep). Allocation is real but tiny, and the alternative is a guard rather
  than a better structure.
- **Divider double-click then drag.** `PaneDividerView.mouseDown` returns early on
  `clickCount == 2` without setting `dragOffset`, so a drag continuing out of a double-click
  uses the raw pointer position. The error is bounded by half the 7pt hit strip, and the
  divider has just been recentred to 0.5 anyway. Below the bar.
- **`preconditionFailure` sites in `Reconcile.swift`** (missing alerts anchor, missing pane
  or tab TODO anchor) and `fatalError("contentArea unavailable")` in
  `buildAndInsertContainer`. I tried to reach each of them: the popover projections are
  ephemeral model state that cannot survive a restore, and the passes run after
  `reconcileContainers` and `reconcileSessionExistence` have made the anchors real. They
  look genuinely unreachable, so rewording them buys nothing.
- **`ContainerShape.zoomedLeaf`'s comment** still says "focusedPaneId while zoomed" though
  the field is assigned `tab.paneTree.zoomedPaneId`. Doc drift from MODEL-3, not a defect;
  worth a one-line fix in whatever commit next touches the file.
- **`SplitContainerView` mutating `dividerViews` while iterating `dividerViews.keys`.**
  Checked: the keys view holds a second reference to the storage, so the removal triggers
  copy-on-write and the iteration completes over the original snapshot. Correct as written.
- **Divider drag round-trip arithmetic.** Verified `mouseDown`'s `dragOffset` against
  `paneSplitRatio`'s inversion for both directions: the ratio computed at the moment of the
  press reproduces the divider's current position exactly, in both the horizontal
  (`frame.minX`, `position - splitBounds.minX`) and vertical (`frame.maxY`,
  `splitBounds.maxY - position`) cases. No jump, no drift. ADR D3 holds.
- **Build-time double layout submitting a false grid.** I expected
  `buildAndInsertContainer`'s `rebuild()` + `setZoomedPane()` pair to hand a zoomed pane a
  split-sized grid first. It does not: the wrapper's terminal view is placed by Auto Layout
  through `ScrollableTerminalView.layout()`, so both frame assignments coalesce into one
  deferred layout pass and only the final geometry reaches the child. The double solve is
  still worth removing -- that is CHROME-2 -- but it is not a correctness defect.


### Area: Input, focus, pointer, menus, and drag-and-drop (`INPUT`)

_Scope: `app/SwiftTerminalSessionView.swift`, `app/PaneInputOrigin.swift`,
`app/PaneFocusReconciliation.swift`, `app/PaneDragCoordinator.swift`,
`app/PaneDragOverlayView.swift`, `app/DragDropPasteboard.swift`,
`app/MenuCommandPolicy.swift`, `app/CommandMenuItemFactory.swift`,
`app/ScrollableTerminalView.swift`, `app/SearchOverlayView.swift`,
`app/PaneDividerView.swift`, `app/PaneWrapperView.swift` (drag handle),
`app/AppRuntime.swift` (the one local NSEvent monitor), `app/AppDelegate.swift`
(menu build, dispatch, validation), read against
`lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift`,
`TerminalInputEncoding.swift`, `TerminalInteractionVocabulary.swift` and
`lib/DanTermCore/Sources/DanTermCore/CommandCatalog.swift`._

**The auditor's read on the area.** The pointer path is the strongest part: the
press/release pairing in `forwardedPressButtons`, the on-grid decision moved
into `decideTerminalPointer`, and the `menu(for:)`/`mouseDown` split for
control-clicks are all careful and documented, and the AppKit-side tests in
`tests-ui/SwiftTerminalSessionViewTests.swift` pin real gestures rather than
internals. The defects that remain share one shape: **a fact the view already
holds is not carried to the place that needs it, so the boundary invents a
substitute.** The cursor is in the published plan but the IME asks the view and
gets `(0,0)`; a control-click knows it was the left button but is re-labelled
right; the horizontal half of a scroll event is measured by AppKit and thrown
away even though the engine has the buttons for it; the presentation geometry is
one computation stored as four independent optionals, so five readers each
invent a `?? 0` or a multi-clause guard; a command's identity is an enum but
travels through the menu as a raw string, so one consumer crashes on a bad value
and another silently ignores it. I did not audit the render/present half of
`SwiftTerminalSessionView` (swapchain, `synchronizePresentation` beyond the
geometry it stores), the todo popover key handling, or `PreferencesPanel` --
other lanes own them. I read `PaneDragCoordinator`/`PaneDragOverlayView` and the
drag handle in full and found nothing worth a finding: the coordinator holds no
geometry, resolves through the pure `resolvePaneDrop`, and the overlay is
hit-test transparent.

<a id="input-1"></a>

#### INPUT-1. Report a claimed control-click as the left button, and delete the physical-vs-reported button split

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `app/SwiftTerminalSessionView.swift#mouseDown`,
`app/SwiftTerminalSessionView.swift#forwardPointerDown`,
`app/SwiftTerminalSessionView.swift#PhysicalPointerButton`,
`app/SwiftTerminalSessionView.swift#forwardedPressButtons`

**Problem.** When a terminal program claims the mouse, DanTerm reports a
control-click to it as **button 2 (right)** with the Control modifier bit set.
Both reference macOS terminals report it as **button 0 (left)** with the Control
bit, because a macOS control-click *is* a left press. A program that
distinguishes the two -- tmux, vim's `ttymouse`, htop, any TUI with a
right-click menu -- gets a right-click where the user made a Control-click, and
there is no way to send it a genuine Control+left at all. The unclaimed case is
unaffected: `menu(for:)` answers it with the pane menu and no lifecycle reaches
the engine.

**Evidence.** The view relabels the button before it forwards:

```swift
override func mouseDown(with event: NSEvent) {
    forwardPointerDown(
        event,
        physical: .left,
        reportedAs: event.modifierFlags.contains(.control) ? .right : .left
    )
```

and the relabelling is exactly what forces a second button vocabulary:

```swift
/// The button the user physically pressed, which is not what the press is reported as:
/// a control-click enters through `.left` and is reported to the engine as `.right`.
private enum PhysicalPointerButton { case left, right, middle }
private var forwardedPressButtons: [PhysicalPointerButton: TerminalMouseButton] = [:]
```

The encoder then sends `code = button.rawValue` with the Control bit or'd in
(`TerminalInputEncoding.swift#encodeTerminalMouse`, where
`TerminalMouseButton.right = 2`), so the wire bytes are "right press, ctrl held".

Ghostty maps the same AppKit entry point to the left button and lets the
modifier carry Control --
`references/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift#mouseDown`:

```swift
override func mouseDown(with event: NSEvent) {
    guard let surface = self.surface else { return }
    let mods = Ghostty.ghosttyMods(event.modifierFlags)
    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
}
```

iTerm2 agrees, keyed on the event type alone --
`references/iterm2/sources/PTYMouseHandler.m#mouseReportingButtonNumberForEvent`:

```objc
case NSEventTypeLeftMouseDragged:
case NSEventTypeLeftMouseDown:
case NSEventTypeLeftMouseUp:
    return MOUSE_BUTTON_LEFT;
```

The current behavior is pinned by a deliberate test, so this is a decision to
revisit rather than an oversight:
`tests-ui/SwiftTerminalSessionViewTests.swift` -- "an unclaimed control-click
both focuses the pane and offers the menu" asserts
`.down(.right, ..., modifiers: [.control], clickCount: 1)` for the claimed case.

**Ideal fix.** Forward the button AppKit delivered. `forwardPointerDown` loses
its `reportedAs:` parameter, `PhysicalPointerButton` disappears, and
`forwardedPressButtons` becomes `Set<TerminalMouseButton>`. Update the pinned
test's claimed-case assertion to `.down(.left, ..., modifiers: [.control])`.

**By construction.** "A press reported to the engine as a different button from
the one whose release will pair with it" stops being representable: there is one
button vocabulary, the map from physical identity to reported identity is
gone, and the doc comment's "letting go of Control mid-click cannot turn a
`.right` press into a `.left` release" describes a hazard that no longer exists.

**Cheaper fallback.** Keep the relabelling behind a config flag. It fails to
remove anything -- both button vocabularies survive, and the default still has
to be one of the two answers.

**Verification.** In the existing UI suite, the claimed control-click case
asserts the pointer event is `.down(.left, cell:, modifiers: [.control],
clickCount: 1)` followed by `.up(.left, ...)`. At the byte level, in
`TerminalInteractionPolicyTests`, feed `CSI ?1000h CSI ?1006h`, then a
`.down(.left, ..., modifiers: [.control])` and assert the emitted bytes are
`ESC [ < 16 ; c ; r M` (button 0 + ctrl bit 16), not `ESC [ < 18 ; c ; r M`.

**Risk.** A user who relies on control-click reaching a mouse-claiming program
as a right-click loses that. Shift+control-click still reaches the pane menu
unchanged (`terminalClaimsRightButton` refuses on Shift), and a real right
button still reports `.right`.

**Vetted.** I opened `SwiftTerminalSessionView.swift` lines 194-215 (the property
and its doc comment), 759-775 (`mouseDown`), 787-805 (the right and middle entry
points), 850-882 (`menu(for:)` and `terminalClaimsRightButton`), and 1738-1785
(`PhysicalPointerButton`, `forwardPointerDown`, `forwardPointerUp`). Every quote
is verbatim. `TerminalInputEncoding.swift` lines 90-94 confirm
`TerminalMouseButton.right = 2`, and line 232 confirms `code = button.rawValue`,
so the wire bytes are what the finding says. Both reference citations are real
and I read them in place: ghostty's `mouseDown` at
`SurfaceView_AppKit.swift:879-883` sends `GHOSTTY_MOUSE_LEFT` with the raw mods,
and iTerm2's `mouseReportingButtonNumberForEvent` at `PTYMouseHandler.m:1372-1376`
returns `MOUSE_BUTTON_LEFT` for every left event type regardless of Control. The
pinned test is where the finding says it is.

**Correction.** Two things in the prose need adjusting. First, the iTerm2 half of
the citation is weaker than stated. iTerm2 does not report a control-click at all
by default: `iTermTextViewContextMenuHelper.m:69-76` only bypasses the context
menu when `kPreferenceKeyControlLeftClickBypassesContextMenu` is on, and
`iTermPreferences.m:620` defaults that key to `@NO`. So iTerm2 answers a
control-click with its context menu even under mouse reporting, and only reports
it -- as button 0 -- once the user opts in. Ghostty is the citation that carries
the claim, and it carries it exactly: `SurfaceView_AppKit.swift:1456-1476` returns
nil from `menu(for:)` when `surfaceModel.mouseCaptured`, precisely so the
control-click falls through to `mouseDown` and reaches the program as the left
button. What no reference does is report button 2 for it, so the divergence is
real. Second, the ideal fix touches a second pinned test the prose does not name:
`tests-ui/SwiftTerminalSessionViewTests.swift` -- "a release names the button its
own press was reported as" -- whose stated intent is that "a control-click
released after Control comes back up still reports `.right`". That test's premise
disappears with the relabelling, so it has to be rewritten, not just re-asserted.
Third, one consequence the risk paragraph misses: `claimsMouseButtons` reads a
cached snapshot that "can lag the engine by one consumed update"
(`TerminalPaneSession.swift:845-852`). In that lag window the press reaches
`pointerGesture` with tracking already `.off`, where `.right` is `.ignored` but
`.left` is `.selection`. After the fix a control-click in that window starts a
selection instead of doing nothing. That is defensible -- it is what a plain left
click does -- but it is a behavior change, not a no-op.

**Conflicts with.** None hard. `SELECT-1` edits `encodeMouseReport` /
`encodeTerminalMouse` in `TerminalInputEncoding.swift`, but this finding changes
only the view's choice of button, not the encoder, so the two land
independently.

<a id="input-2"></a>

#### INPUT-2. Answer `firstRect(forCharacterRange:)` from the published cursor so the IME panel follows the caret

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `app/SwiftTerminalSessionView.swift#firstRect(forCharacterRange:actualRange:)`,
`app/SwiftTerminalSessionView.swift#publishedFrame`,
`lib/TerminalCore/Sources/TerminalRenderPlanning/TerminalRenderPlanning.swift#RenderCursor`

**Problem.** The view answers AppKit's "where is the text you are editing?"
question with a zero-width rect at the pane's top-left corner, whatever the
cursor is doing. Every IME candidate window -- Japanese, Chinese, Korean, and
the Emoji picker -- therefore opens pinned to the corner of the pane instead of
under the caret. The information needed to answer correctly is already in the
view: the last published plan carries the cursor's row and column, and
`displayedCellSize` is the pane-space cell box the pointer path already maps
with.

**Evidence.**

```swift
func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let window else { return .zero }
    let viewRect = NSRect(x: 0, y: 0, width: 0, height: displayedCellSize?.height ?? 0)
    return window.convertToScreen(convert(viewRect, to: nil))
}
```

`x` and `y` are literals. The published plan already holds the answer --
`publishedFrame = (frame.plan, metrics)` in
`SwiftTerminalSessionView.swift#publish(_ frame:)`, and
`RenderFramePlan.cursor: RenderCursor?` carries `row`, `column`, and
`columnWidth`. The view is `isFlipped`, so the rect is a direct multiply.

Ghostty asks its engine for exactly this point --
`references/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift#firstRect(forCharacterRange:actualRange:)`:

```swift
// Ghostty will tell us where it thinks an IME keyboard should render.
...
ghostty_surface_ime_point(surface, &x, &y, &width, &height)
```

**Ideal fix.** Build the rect from the one presentation value (see INPUT-3) and
`publishedFrame?.plan.cursor`:
`NSRect(x: cell.width * column, y: cell.height * row, width: cell.width *
columnWidth, height: cell.height)`, converted to screen. With no published
frame, or with a hidden cursor (`plan.cursor == nil`), keep the current
top-left rect -- that is the only case where the view genuinely does not know.

**By construction.** n/a -- this is a missing read, not a representable bad
state. It does delete one `?? 0`, which INPUT-3 removes anyway.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** UI suite (`tests-ui/SwiftTerminalSessionViewTests.swift`):
mount a pane, feed enough output to put the cursor at a known row/column, and
assert `firstRect(forCharacterRange:)` converted back into view coordinates has
origin `(cellWidth * column, cellHeight * row)` and height `cellHeight`. A
second case with the cursor hidden (`CSI ?25l`) asserts the fallback rect.

**Risk.** Very low. A wrong sign on the flipped axis would move the panel to the
wrong row; the assertion above catches it. Nothing else calls this method.

**Vetted.** I opened `SwiftTerminalSessionView.swift:979-983` (`firstRect`, quoted
verbatim, `x` and `y` are literal zeros), line 360 (`isFlipped` is true), lines
220 and 1713 (`publishedFrame` is assigned `(frame.plan, metrics)` in `publish`),
and `TerminalRenderPlanning.swift:290` and `481-496` (`RenderFramePlan.cursor:
RenderCursor?` carrying `row`, `column`, `columnWidth`). I followed the cursor
down to its producer to check the fallback case is the one the finding claims:
`RenderFramePlanner.swift:260` sets `cursorSpan = presentation.isCursorVisible ?
terminal.cursorPlacement : nil`, `isCursorVisible` is the DECTCEM mode alone
(`Terminal.swift:6671`) and not a focus flag, and `Terminal.swift:4962-4970`
returns nil when the cursor row falls outside the viewport window. So `plan.cursor
== nil` means exactly "hidden or scrolled out of view", which is the case the
fallback is written for. The ghostty citation is verbatim at
`SurfaceView_AppKit.swift:1902-1932`.

**Correction.** The payoff is half of what the prose implies, and the lane's own
Dropped list says why without connecting it: `setMarkedText` stores the
composition into `markedText` (line 956) and nothing reads it back out --
`grep -n markedText` over the file returns only the store, the length test, and
`unmarkText`. So the preedit text is invisible in the grid today. Moving the
candidate window under the caret makes the panel land in the right place over a
caret that shows no composition. It is still the right fix and still strictly
better than a corner-pinned panel, but "every IME candidate window opens pinned
to the corner" is not the whole of what is broken for a CJK user, and fixing it
alone does not make composing usable. Pair it with the dropped preedit-rendering
item when scheduling.

**Conflicts with.** `INPUT-3`, softly: the ideal fix here reads the cell box that
`INPUT-3` moves into `PanePresentation`, and deletes the `?? 0` that `INPUT-3`
also deletes. Land `INPUT-3` first, or write this rect against whichever shape
exists at the time.

<a id="input-3"></a>

#### INPUT-3. Store the pane's resolved presentation geometry as one value instead of four correlated optionals

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; rescored

**Files.** `app/SwiftTerminalSessionView.swift#synchronizePresentation`,
`app/SwiftTerminalSessionView.swift#normalizedCell(at:)`,
`app/SwiftTerminalSessionView.swift#scrollWheel(with:)`,
`app/SwiftTerminalSessionView.swift#presentationGeometryForTesting`,
`app/SwiftTerminalSessionView.swift#state`

**Problem.** `currentMetrics`, `currentDimensions`, `currentGridPinned` and
`displayedCellSize` are four independent optional properties that are computed
together, assigned together, and never assigned apart. Nothing in the type says
so, so every reader re-establishes the invariant by hand: two-clause guards, a
three-clause guard, and two `?? 0` defaults for a cell height that is nil only
in a state the caller has already excluded. The `?? 0` in `scrollWheel` is the
clearest symptom -- it can only fire in a case `normalizedCell` has already
rejected on the line above.

**Evidence.** One assignment site, four properties:

```swift
currentMetrics = metrics
currentDimensions = dimensions
currentGridPinned = pinned
displayedCellSize = CGSize(
    width: metrics.cellSize.width * metrics.displayScale / scale,
    height: metrics.cellSize.height * metrics.displayScale / scale
)
```

and the readers, each re-deriving the correlation:

```swift
private func normalizedCell(at locationInWindow: NSPoint) -> TerminalViewportCell? {
    guard let cellSize = displayedCellSize, let dimensions = currentDimensions else { return nil }
```

```swift
guard isTornDown == false, let cell = normalizedCell(for: event) else { return }
let rows = wheelNormalizer.rows(
    delta: Self.verticalScrollDelta(for: event),
    isPrecise: event.hasPreciseScrollingDeltas,
    cellHeight: Double(displayedCellSize?.height ?? 0)
)
```

```swift
guard let metrics = currentMetrics,
      let cellSize = displayedCellSize,
      let dimensions = currentDimensions
else { return nil }
```

`benchmarkGeometry` guards two of them, `state` reads `displayedCellSize?.height`,
and `firstRect` carries the second `?? 0`.

**Ideal fix.** One `private struct PanePresentation { let metrics:
TerminalRenderMetrics; let dimensions: TerminalDimensions; let pinned: Bool; let
displayedCellSize: CGSize }` stored as a single `private var presentation:
PanePresentation?`, built and assigned in the one place
`synchronizePresentation` already computes all four. Every reader binds it once;
the two `?? 0` defaults and the multi-clause guards collapse to one `guard let
presentation`.

**By construction.** "A pane that knows its grid but not its cell box" (and the
three other mixed combinations) stops being representable, and with it the
question every `?? 0` was answering.

**Cheaper fallback.** Replace just the two `?? 0` reads with the value already
bound on the line above. It fixes the two worst readers and leaves the four
optionals -- the next reader writes the fifth guard.

**Verification.** Behavior must not move, so the existing UI suite is the test:
`presentationGeometryForTesting`, the pointer-mapping cases
(`paneCellPoint(...)`-based tests), and the wheel cases stay green unchanged. Add
nothing -- a refactor that keeps behavior must keep the tests passing.

**Risk.** A mechanical change with one hazard: the assignment currently happens
even when only some inputs moved, and `metricsChanged`/`geometryChanged` are
computed against the old values before assignment. The single-value version must
compare the whole old value against the whole new one and keep both flags, or a
divider drag will re-emit state on every frame.

**Vetted.** I opened all five readers and the one writer.
`SwiftTerminalSessionView.swift:194-204` declares the four properties;
`1561-1573` is the single assignment site and both change flags, quoted verbatim;
`1724-1736` is `normalizedCell(at:)`; `739-745` is `scrollWheel` with its `?? 0`;
`327-341` is `presentationGeometryForTesting` with the three-clause guard;
`350-357` is `benchmarkGeometry` with the two-clause one; `294` is `state`'s
`displayedCellSize?.height`; `981` is `firstRect`'s second `?? 0`. Every quote
matches. I checked the unreachability claim myself: `displayedCellSize` is
assigned only at line 1570 and never set back to nil, so once `normalizedCell`
has returned non-nil on the line above, the `?? 0` in `scrollWheel` cannot fire.
Same for `firstRect`, where the `?? 0` is reachable but only before the first
layout pass, and the rect is a placeholder in that state anyway.

**Correction.** Impact moved from 3 to 2 for two reasons the prose does not
weigh. There is no live defect here -- both `?? 0` defaults are provably dead or
harmless, so the change buys readability and a closed state space, not a fixed
bug. And one of the five readers does not collapse: `state`'s `cellHeight:
displayedCellSize?.height` feeds a genuinely optional field on
`TerminalSessionState`, and stays optional after the refactor. The "five readers
each invent a `?? 0` or a multi-clause guard" count is four, not five. The risk
paragraph is right and is the real work: `metricsChanged` and `geometryChanged`
are computed against the old values before assignment and must stay two separate
comparisons against the stored value's fields, not one whole-value `!=`.

**Conflicts with.** `INPUT-2` (reads the same cell box and deletes the same
`?? 0`); `INPUT-4` (edits `scrollWheel`, the reader carrying the clearest `?? 0`);
`SELECT-6` (also edits `scrollWheel`); and softly `CHROME-3`, whose fix changes
who calls `setFrameSize` and therefore how often `synchronizePresentation` runs,
though it does not edit the assignment itself.

<a id="input-4"></a>

#### INPUT-4. Report horizontal wheel motion instead of discarding it

`correctness` &middot; impact 2, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `app/SwiftTerminalSessionView.swift#verticalScrollDelta(for:)`,
`app/SwiftTerminalSessionView.swift#scrollWheel(with:)`,
`lib/TerminalCore/Sources/TerminalCore/TerminalInteractionVocabulary.swift#TerminalWheelEvent`,
`lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift#TerminalMouseWheelDirection`

**Problem.** A horizontal scroll -- two-finger sideways on a trackpad, a tilt
wheel -- reaches the pane and is dropped. The view reads only `scrollingDeltaY`,
except for one narrow Shift-wheel case where AppKit has already projected line
ticks onto the X axis. A program with mouse reporting on therefore never sees a
horizontal wheel report, even though the engine already has the two buttons for
it and the encoder already knows how to send them. `TerminalMouseWheelDirection.left`
and `.right` have no producer anywhere in the tree.

**Evidence.** The view's only horizontal read is the Shift special case:

```swift
private static func verticalScrollDelta(for event: NSEvent) -> Double {
    let vertical = Double(event.scrollingDeltaY)
    // AppKit projects Shift-wheel line ticks onto the horizontal axis before dispatch.
    if event.modifierFlags.contains(.shift), vertical == 0 {
        return Double(event.scrollingDeltaX)
    }
    return vertical
}
```

`TerminalWheelEvent` carries one axis (`public let rowDelta: Double`), and
`grep -rn "scrollingDeltaX" app lib ios` returns exactly the one line above.
The engine's vocabulary is complete but half-unreachable:

```swift
public enum TerminalMouseWheelDirection: Int, Equatable, Sendable {
    case up = 64
    case down = 65
    case left = 66
    case right = 67
}
```

and `TerminalInteractionPolicy.swift#wheelDecision` only ever mints two of the
four: `let direction = rows < 0 ? TerminalMouseWheelDirection.up : .down`.

Ghostty accumulates both axes and reports the horizontal one as buttons six and
seven -- `references/ghostty/src/Surface.zig#scrollCallback`:

```zig
for (0..@abs(x.delta)) |_| {
    const pos = try self.rt_surface.getCursorPos();
    try self.mouseReport(switch (x.direction()) {
        .up_right => .six,
        .down_left => .seven,
    }, .press, self.mouse.mods, pos);
}
```

iTerm2 reports the same buttons from `scrollingDeltaX`
(`references/iterm2/sources/PTYMouseHandler.m#mouseReportingButtonNumberForEvent`
logs both axes for a scroll-wheel event and the reporting path emits buttons
6/7).

**Ideal fix.** Give `TerminalWheelEvent` a `columnDelta: Double` beside
`rowDelta`, feed it from `scrollingDeltaX` normalized by the cell *width* the
same way rows are normalized by the cell height, and give
`wheelDecision`'s `.mouseReport` arm a second loop emitting `.left`/`.right`.
Only the `.mouseReport` route consumes it -- horizontal motion has no local
viewport meaning in a grid that never scrolls sideways, and no alternate-screen
arrow equivalent -- so the other two routes ignore it and the Shift special case
in `verticalScrollDelta` stays exactly as it is.

**By construction.** Two of the four wheel directions stop being unreachable
vocabulary: every case of `TerminalMouseWheelDirection` gets a producer.

**Cheaper fallback.** Delete `.left`/`.right` from the enum and declare
horizontal scroll unsupported. That is honest about today's behavior and cheap,
but it makes DanTerm the only one of the reference terminals that cannot report
a horizontal wheel, and the compatibility rule in AGENTS.md puts that on the
wrong side.

**Verification.** `TerminalInteractionPolicyTests`: with `CSI ?1000h CSI ?1006h`
set, a wheel event carrying `columnDelta: +1` at column `c` row `r` emits
`ESC [ < 67 ; c+1 ; r+1 M`, and `columnDelta: -1` emits `66`. A second case
asserts a `columnDelta` with mouse reporting off emits no bytes and moves no
viewport row. Remainder behavior gets the same treatment the vertical axis has:
two half-cell samples produce one report.

**Risk.** A trackpad delivers both axes on nearly every gesture, so a naive
threshold would emit spurious horizontal reports during a vertical scroll. The
per-route remainder in `consumeWheelRows` already solves this for rows; the
column accumulator must use the cell width, not the height, or diagonal drift
will report. Workload that would show it: two-finger vertical scrolling in
`less -S` under mouse reporting.

**Vetted.** I opened `SwiftTerminalSessionView.swift:1877-1884`
(`verticalScrollDelta`, verbatim) and `739-757` (`scrollWheel`), and re-ran the
grep: `scrollingDeltaX` appears exactly once in `app`, `lib`, and `ios`, at line
1881. `TerminalInteractionVocabulary.swift:155-180` confirms `TerminalWheelEvent`
carries one axis. `TerminalInputEncoding.swift:97-102` is the four-case enum,
verbatim, and `TerminalInteractionPolicy.swift:691` mints only two of them. Both
references check out and I read them in place: ghostty's `Surface.zig:3517-3532`
loops over `y` then `x` and reports `.six`/`.seven` for the horizontal axis, and
`3444-3462` shows the `x` accumulator normalized by `self.size.cell.width` with
its own `pending_scroll_x` remainder -- exactly the shape the ideal fix
prescribes. iTerm2's `PTYMouseHandler.m:1402-1425` returns
`MOUSE_BUTTON_SCROLLLEFT`/`SCROLLRIGHT` from `scrollingDeltaX`.

**Correction.** The "no producer anywhere in the tree" claim is false, and with
it the "By construction" payoff. `TerminalMouseWheelDirection.left` and `.right`
do have a producer:
`lib/TerminalCore/Sources/TerminalCoreRecording/NeutralTerminalRecording.swift#neutralWheelDirection`
maps a recorded button through `TerminalMouseWheelDirection(rawValue: button +
60)`, and `applyNeutralTerminalMouse` feeds it to
`decideTerminalMouseWheelReport`, so a corpus recording carrying button 6 or 7
replays as a horizontal report today. `TerminalMouseEncodingTests.swift:22`
covers all four directions. So the enum is not dead vocabulary; what is missing
is a *live input* path -- the AppKit view drops the horizontal axis before the
engine ever sees it. State the finding that way: DanTerm can encode and replay a
horizontal wheel report but can never originate one from a real gesture. Two
further notes on the fix. The two references disagree on shape and the plan
should pick deliberately: ghostty reports both axes from one gesture, while
iTerm2 picks the dominant axis (`fabs(scrollingDeltaX) > fabs(scrollingDeltaY)`)
and reports only that one -- a simpler answer to the diagonal-drift risk than a
second remainder accumulator. And iTerm2 carries a sign correction the plan does
not mention: macOS reverses horizontal direction under natural scrolling, and
iTerm2 flips left/right back unless
`naturalScrollingAffectsHorizontalMouseReporting` is set, citing its issue 10881.
Whichever way DanTerm goes, that decision has to be made explicitly rather than
inherited from `scrollingDeltaX`'s raw sign.

**Conflicts with.** `SELECT-6` -- hard conflict. It replaces
`TerminalWheelEvent`'s `column`/`row` with a whole `TerminalViewportCell` and
rewrites the same `scrollWheel` call site this finding adds `columnDelta` to;
both edit the same struct and the same construction expression. `SELECT-4` edits
`wheelRoute` in the same file as `wheelDecision` and should be sequenced with
this one. `INPUT-3` also edits `scrollWheel`.

<a id="input-5"></a>

#### INPUT-5. Carry the typed `ConfigurableCommand` through the menu item instead of a raw id string

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; rewritten

**Files.** `app/CommandMenuItemFactory.swift#commandDescriptor(id:)`,
`app/CommandMenuItemFactory.swift#items(for:)`,
`app/AppDelegate.swift#performConfiguredCommand`,
`app/AppDelegate.swift#validateMenuItem`,
`app/MenuCommandPolicy.swift#isEnabled(commandID:windowIsLive:)`

**Problem.** A command's identity is already a closed enum
(`ConfigurableCommand`, whose completeness against the catalog is tested), but
the menu layer moves it around as a `String`. `NSMenu.addCommand` takes a
stringly `KeybindingActionID`, the item stores `descriptor.id.rawValue` in
`representedObject`, and the two consumers then disagree about what an
unrecognized value means: dispatch silently ignores it, validation crashes the
app. One menu id is even *computed* from another enum's raw value, so adding a
`TabColor` case without a catalog entry is a launch-time
`preconditionFailure`, not a compile error.

**Evidence.** The lookup and its crash:

```swift
func commandDescriptor(id: KeybindingActionID) -> CommandDescriptor {
    guard let descriptor = commandCatalog.first(where: { $0.id == id }) else {
        preconditionFailure("unknown configurable command \(id.rawValue)")
    }
    return descriptor
}
```

The computed id, in `AppDelegate.swift`:

```swift
let item = colorSubmenu.addCommand(KeybindingActionID(rawValue: "tab.color-\(color.rawValue)"))[0]
```

The two consumers, on the same untyped channel:

```swift
@objc func performConfiguredCommand(_ sender: NSMenuItem) {
    guard let rawID = sender.representedObject as? String,
          let command = ConfigurableCommand(rawValue: rawID)
    else { return }                     // silently ignores
```

```swift
func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if let rawID = item.representedObject as? String {
        return MenuCommandPolicy.isEnabled(
            commandID: KeybindingActionID(rawValue: rawID),   // -> commandDescriptor -> crash
```

The enum that should have been the parameter all along already exists and is
already exhaustively checked against the catalog --
`lib/DanTermCore/.../CommandCatalog.swift#ConfigurableCommand` plus
`CommandCatalogTests#catalogCoverage`:
`#expect(Set(commandCatalog.map(\.action)) == Set(ConfigurableCommand.allCases))`.

**Ideal fix.** Type the whole path: `NSMenu.addCommand(_ command:
ConfigurableCommand)`, `item.representedObject = command` (the enum boxed, or a
small `@objc` wrapper), `commandDescriptor(_ command: ConfigurableCommand) ->
CommandDescriptor` backed by a `[ConfigurableCommand: CommandDescriptor]` built
once from the catalog -- with the coverage test above making the lookup total,
so the `preconditionFailure` is deleted rather than reworded. The tab-color loop
maps `TabColor -> ConfigurableCommand` through one exhaustive `switch`, which
the compiler then forces a new colour to update. This is the same move
`CHROME-3` already landed for the sidebar ("Carry typed ids in sidebar menu
items instead of bare UUIDs", `db4b5a06`).

**By construction.** "A menu item naming a command that does not exist" stops
being representable, along with the divergence where one consumer ignores it and
another traps. The `as? String` sniff -- on a `representedObject` channel that
four different subsystems already use for four different payload types --
disappears with it.

**Cheaper fallback.** Keep the strings and make `commandDescriptor` return an
optional so validation matches dispatch. That removes the crash and leaves every
typo, including the interpolated colour id, to fail silently as a dead menu item
-- strictly worse to debug.

**Verification.** `DanTermCoreTests`: assert every `ConfigurableCommand` resolves
to a descriptor and that the tab-colour mapping covers `TabColor.allCases`
(compile-time exhaustive switch plus one case-count assertion). UI suite: a menu
item built for each catalog command dispatches to its action and validates
without trapping. The behavioral shape is unchanged, so the existing menu tests
must stay green.

**Risk.** `representedObject` is `Any?`; boxing a Swift enum there is fine, but
`ConfigurableMenuBindingSurface#reapplyForCurrentInputSource` filters items with
`$0.representedObject as? String == rawID` and must be updated in the same
change or every hidden alternate twin stops being found.

**Vetted.** I read `app/CommandMenuItemFactory.swift` whole (157 lines) and
`app/MenuCommandPolicy.swift` whole (43 lines), plus `AppDelegate.swift:429-449`
(`performConfiguredCommand`), `827-835` (`validateMenuItem`), and `349-374` (the
tab-colour loop). Every quote is verbatim. `CommandCatalog.swift:5-21` is the
enum, `71` derives `id` from `action.rawValue`, and `122-129` holds the eight
colour entries against `Model.swift:412-414`'s seven `TabColor` cases plus
`colorNone`. `KeybindingActionID` is a `RawRepresentable` string wrapper in
`DanTermProtocol/KeybindingConfig.swift:4`. The cited precedent commit is real:
`db4b5a06 refactor(sidebar): carry the message itself in context-menu items`,
though it carries a `Msg`, not a typed id.

**Correction.** The stated problem overstates what is reachable. I grepped every
`representedObject` write in `app/`: `ThemeBrowserView` stores a `MenuPayload`,
`SidebarView` a `SidebarMenuAction`, `PaneWrapperView` `self`, and
`CommandMenuItemFactory` a catalog `descriptor.id.rawValue`. No subsystem writes
a foreign `String`, so the `as? String` sniff in `validateMenuItem` can only ever
see a catalog id, and `commandDescriptor(id:)` can only ever find it. The
"validation crashes the app" branch and the "dispatch silently ignores it" branch
are both unreachable with any value the tree can produce -- they are a latent
divergence in how two consumers would treat a bad id, not a live one. The one
genuinely reachable failure is the interpolated colour id, and it is not a
validation crash either: `NSMenu.addCommand` calls `commandDescriptor(id:)`
eagerly at menu-build time, so a new `TabColor` case with no catalog entry traps
during `applicationDidFinishLaunching`, on the first launch after the edit, in
front of the developer who made it. That is a fail-fast developer error, not a
user-facing defect. So read this as what it is: a typed-channel refactor whose
payoff is compile-time exhaustiveness on the `TabColor -> ConfigurableCommand`
map, matching a precedent the sidebar already set -- not a crash fix. Impact 2.

**Conflicts with.** `CHROME-1` also edits `app/AppDelegate.swift` and
`CommandCatalog.swift`, but at `toggleSidebar` rather than
`performConfiguredCommand` or the catalog's colour block, so the two are
independent. `PERSIST`'s launch-sequence finding touches
`applicationDidFinishLaunching`, which is where the menu is built; sequence them
rather than landing both blind.

<a id="input-6"></a>

#### INPUT-6. Delete the input-source observer that rebuilds the menu bindings identically

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `app/CommandMenuItemFactory.swift#ConfigurableMenuBindingSurface`,
`app/CommandMenuItemFactory.swift#reapplyForCurrentInputSource`,
`app/CommandMenuItemFactory.swift#keyEquivalent(_:)`

**Problem.** The binding surface subscribes to
`NSTextInputContext.keyboardSelectionDidChangeNotification` and, on every
keyboard-layout switch, walks the whole command catalog, re-assigns each primary
item's key equivalent, removes every hidden alternate item, and re-creates them.
None of that work depends on the input source: `keyEquivalent(_:)` is a pure
function of the chord. The method's name claims a behavior the body does not
have, and a reader looking for layout-aware shortcuts will believe it exists.

**Evidence.** The observer:

```swift
notificationCenter.addObserver(
    self,
    selector: #selector(inputSourceDidChange(_:)),
    name: NSTextInputContext.keyboardSelectionDidChangeNotification,
    object: nil
)
```

The body it triggers reads only stored bindings and the catalog -- no input
source, no layout:

```swift
private func reapplyForCurrentInputSource() {
    guard let menu else { return }
    for descriptor in commandCatalog {
        ...
        let chords = lastBindings[descriptor.id] ?? descriptor.defaultChords
        CommandMenuItemFactory.configure(primary, chord: chords.first)
        for extra in existing.dropFirst() { parent.removeItem(extra) }
```

and the equivalent it writes is layout-free:

```swift
static func keyEquivalent(_ chord: KeyChord) -> String {
    let token = chord.compact.split(separator: "+").last.map(String.init) ?? ""
    switch token { ... default: return chord.modifiers.contains(.shift) ? token.uppercased() : token }
}
```

**Ideal fix.** Delete the observer, the `notificationCenter` dependency, the
`deinit`, and `inputSourceDidChange`; rename `reapplyForCurrentInputSource` to
`applyBindings` and call it from `apply(_:)` only. If layout-aware equivalents
are actually wanted, that is a feature with its own design (AppKit already
localizes the *display* of a key equivalent; only the character mapping would
need work), and it should be built deliberately rather than implied by a
notification name.

**By construction.** n/a -- this removes a concept, not a state. It does delete
an observer whose lifetime is managed by hand (`addObserver` in `init`,
`removeObserver` in `deinit`), which is one fewer thing for the AppKit-lifetime
rules to cover.

**Cheaper fallback.** Leave it and rename the method to say what it does. That
keeps a periodic menu-item churn nobody needs and keeps a reader wondering what
the notification is for.

**Verification.** `tests-ui`: applying a binding map produces the expected
primary and hidden-twin items with the expected equivalents; posting
`NSTextInputContext.keyboardSelectionDidChangeNotification` afterwards changes
nothing observable. If that second assertion holds today, the observer is dead
and the deletion is safe.

**Risk.** If a real layout dependency exists that I did not find -- some AppKit
caching of `keyEquivalent` per input source -- shortcuts could stop updating on
a layout switch. The test above is what settles it: post the notification and
assert the item state is identical either way.

**Vetted.** I read `app/CommandMenuItemFactory.swift` whole rather than by
symbol, because the claim is about what a body does *not* read. All three quotes
are verbatim (the observer at lines 92-97, `reapplyForCurrentInputSource` at
108-133, `keyEquivalent` at 47-69). I traced every input the method reads: `menu`,
`commandCatalog`, `lastBindings`, and `CommandMenuItemFactory.configure`, which
calls `keyEquivalent` and `modifierMask`. `keyEquivalent` reads only
`chord.compact` and `chord.modifiers`; `modifierMask` reads only
`chord.modifiers` and `chord.key`. Nothing in the transitive set touches
`NSTextInputContext`, `TISInputSource`, or any layout API. The rebuild is
idempotent: it re-assigns the same equivalent to the same primary item and
removes then re-creates twins with the same chords, so the post-notification
state is identical to the pre-notification state. Confidence raised to 5 -- I
found every quoted line and closed the "does anything here read the layout?"
question by reading the whole file, which is what the auditor's own 4 was
hedging.

**Conflicts with.** `INPUT-5`, hard. Its ideal fix changes
`representedObject` from a `String` to a typed value, and this file's
`reapplyForCurrentInputSource` is the filter that reads it back
(`$0.representedObject as? String == rawID`). Whichever lands first, the other
edits the same method. If `INPUT-6` lands first the method is smaller and
renamed, which makes `INPUT-5`'s edit easier -- that is the order to prefer.

<a id="input-7"></a>

#### INPUT-7. Stop the jump-mode monitor from swallowing modified chords, and drop its no-op `flagsChanged` arm

`correctness` &middot; impact 1, confidence 4 &middot; effort small &middot; rewritten

**Files.** `app/AppRuntime.swift#installSwitcherEventMonitor`,
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#classifyJumpInput`,
`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#JumpInputKind`

**Problem.** While tab-jump mode is active, the app's one local NSEvent monitor
classifies every `keyDown` by `charactersIgnoringModifiers` alone, with no look
at the modifiers. A local monitor sees the event before the menu system does, so
`Cmd+Q`, `Cmd+W`, or any other chord typed during jump mode is consumed as a
jump label and the real command never runs. In the same handler, the
`.flagsChanged` arm calls the classifier and throws the answer away, because
`JumpInputKind.flagsChanged` can only ever be `.passthrough` -- a case that
exists solely to be ignored.

**Evidence.** The classification, modifiers unread:

```swift
case .keyDown:
    let character = event.charactersIgnoringModifiers?.lowercased().first
    let action = classifyJumpInput(
        kind: event.keyCode == 0x35 ? .escape : .keyDown(character: character),
        jumpActive: true
    )
    switch action {
    ...
    case .commit(let char):
        self.send(.jumpModeKeyPressed(char: char))
        return nil          // event consumed
```

The discarded call:

```swift
case .flagsChanged:
    _ = classifyJumpInput(
        kind: .flagsChanged,
        jumpActive: true
    )
    return event
```

and the arm it reaches, which has one answer:

```swift
switch kind {
case .flagsChanged:
    return .passthrough
```

**Ideal fix.** Give `classifyJumpInput` the modifiers as an input and let it
answer `.passthrough` for anything carrying Command, Control, or Option -- jump
labels are plain characters, so a modified chord is by definition not one.
Delete `JumpInputKind.flagsChanged` and the monitor arm that feeds it; a
modifier press is already `default: return event`.

**By construction.** One case of the input vocabulary that has exactly one
possible answer stops existing, and "a jump-mode classification whose result the
caller must ignore" becomes unrepresentable.

**Cheaper fallback.** Filter the chord at the monitor
(`event.modifierFlags.isDisjoint(with: [.command, .control, .option])`) and leave
the classifier alone. It fixes the swallowing but puts the rule in AppKit code
instead of in the pure classifier that exists to hold it, and leaves the dead
case.

**Verification.** `DanTermCoreTests`: `classifyJumpInput(kind: .keyDown(character:
"q"), modifiers: [.command], jumpActive: true) == .passthrough`, while the same
call with no modifiers is `.commit(char: "q")`. Confidence is 3 rather than 5
because the user-visible half of the claim rests on local monitors running
before menu key-equivalent dispatch; the pure-classifier half is proven by the
quoted code either way.

**Risk.** A user who expects a modified key to still pick a jump label loses
that; no label is generated with modifiers, so there is nothing real to lose.

**Vetted.** I opened `AppRuntime.swift:344-388` (the whole monitor handler; both
quotes verbatim, including the discarded `.flagsChanged` call) and
`ModelOperations.swift:1301-1354` (`JumpInputKind`, `JumpAction`, and
`classifyJumpInput`, verbatim). The pure half of the claim is exactly as stated:
`.flagsChanged` has one answer, and `.keyDown` with a non-nil character always
commits regardless of modifiers, so `Cmd+Q` in jump mode classifies as
`.commit(char: "q")` and the handler returns nil. I traced the consequence
through `Update.swift:1854-1864`: `jumpModeCommit` clears `model.jumpMode` and
does nothing when no tab carries that label, so the usual outcome is one lost
keystroke and an exited mode, and the bad outcome is a tab switch instead of the
chord's real command. I did not run the app to confirm that a local
`NSEvent` monitor precedes menu key-equivalent dispatch, so confidence stays at
4: the ordering rests on documented AppKit behavior, not a probe here.

**Correction.** The risk paragraph has it backwards, and the ideal fix as written
can make things worse. Jump mode is entered by `cmd+shift+f`
(`CommandCatalog.swift:119`). A user who is still holding Command when they type
the label -- which is the natural thing a fraction of a second after that chord
-- currently commits the label correctly. Under `.passthrough`, that same
keystroke stops being consumed, falls through to the menu system, and fires
whatever `Cmd+<letter>` command exists: `Cmd+W` closes the tab instead of jumping
to it. That is a worse failure than the one being fixed. Answer `.cancel` for a
modified chord rather than `.passthrough`: jump mode exits, the label is not
taken, and the chord still reaches the menu -- one consistent rule, and the mode
never sits open swallowing input. Impact drops to 1 either way: the window is a
transient, explicitly-entered mode, and the worst live outcome is one keystroke
that has to be repeated. The `JumpInputKind.flagsChanged` deletion is the solid
half of the finding and stands on its own.

**Conflicts with.** None. No other lane file names `classifyJumpInput` or
`installSwitcherEventMonitor`.

<a id="input-8"></a>

#### INPUT-8. Set the divider drag offset on every press, so a double-click followed by a drag does not jump

`correctness` &middot; impact 1, confidence 5 &middot; effort small &middot; rescored

**Files.** `app/PaneDividerView.swift#mouseDown(with:)`,
`app/PaneDividerView.swift#mouseDragged(with:)`

**Problem.** `mouseDown` returns early on a double-click to reset the split,
leaving `dragOffset` nil. If the user keeps the button down after that second
click and drags -- a common accident -- `mouseDragged` takes the no-offset
branch and moves the divider so its edge lands on the pointer, jumping it by
however far the press was from the divider edge. The optional is carrying two
meanings: "no drag in progress" and "grab point unknown".

**Evidence.**

```swift
override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
        resetToEvenSplit()
        return                      // dragOffset left nil
    }
    guard let placement, let superview else { return }
    let point = superview.convert(event.locationInWindow, from: nil)
    dragOffset = switch placement.direction { ... }
}

override func mouseDragged(with event: NSEvent) {
    guard let placement, let superview else { return }
    var point = superview.convert(event.locationInWindow, from: nil)
    if let dragOffset { ... }       // nil -> raw pointer position
    drag(to: point)
}
```

**Ideal fix.** Compute and store the grab offset first, unconditionally, then
handle the double-click reset. `dragOffset` becomes a plain `CGFloat` set on
every press, and the `if let` in `mouseDragged` becomes a subtraction.

**By construction.** The "drag with an unknown grab point" state disappears, and
with it the branch that guesses one.

**Cheaper fallback.** none -- the ideal fix is two moved lines.

**Verification.** `tests-ui/SplitContainerViewTests.swift`: send a
`clickCount: 2` press at a point offset from the divider's edge, then a drag to a
known position, and assert the reported ratio equals the one a `clickCount: 1`
press at the same two points produces.

**Risk.** None beyond the divider itself; `resetToEvenSplit` still runs on the
double-click, and a press with no `placement` still stores nothing.

**Vetted.** I read `app/PaneDividerView.swift` whole (136 lines). Both quotes are
verbatim, and the sequence is real: AppKit delivers down(1), up, down(2), up, and
`mouseUp` clears `dragOffset` before the second press returns early, so a drag
continuing out of that second press takes the no-offset branch. Confidence raised
to 5 -- I found every quoted line.

**Correction.** Two things. The magnitude is small and the prose does not bound
it: the grab offset is measured inside a 7pt hit strip
(`hitThickness = 7`, centred on the visual divider), so the jump is at most about
4pt, not "however far the press was from the divider edge" in any open-ended
sense. And the ideal fix cannot make `dragOffset` a plain `CGFloat` as written:
`mouseDown` still returns without storing anything when `placement` or
`superview` is nil, which the finding's own risk paragraph concedes. Either keep
it optional and just move the computation above the double-click branch, or
default it to zero on that path and say so.

**Conflicts with.** None in code, but this is the same defect the `CHROME` lane
found and dropped ("Divider double-click then drag", in its Dropped list), with
the same magnitude estimate and one extra argument: the divider has just been
recentred to 0.5 by the double-click, so the gesture is already discontinuous.
Two independent readings, one at impact 1 and one below the bar -- if the parent
is trimming, this is the first to go.

#### Dropped (INPUT)

- **`forwardPointerUp` removes the press record before it can bail on a nil
  cell.** Looked like a stuck-button bug, but `displayedCellSize` and
  `currentDimensions` are only ever assigned (never cleared), so after a press
  that reached the engine the cell always resolves. The only remaining bail is
  `isTornDown`, where the engine is going away anyway. Not live.
- **Mouse buttons 4 and above are dropped** (`otherMouseDown` guards
  `event.buttonNumber == 2`). Real divergence -- iTerm2 maps buttons 3-6 to
  backward/forward/10/11 -- but `TerminalMouseButton` has only three cases, so
  the fix is an engine-vocabulary change outside this lane, and back/forward
  buttons in a terminal are a thin use case.
- **IME preedit text is never rendered.** `setMarkedText` stores the string and
  no renderer draws it, so composing Japanese shows nothing until commit.
  Genuine, but it is a renderer feature (ghostty threads a preedit string into
  its frame), not an input-layer fix, and it belongs to whoever owns
  `TerminalRenderPlanning`.
- **`paneFocusClaimant()` is O(panes) and runs twice per reconcile sweep,**
  walking `isDescendant(of:)` chains and, on the search-field path, every pane's
  wrapper. Pane counts are in the tens and sweeps are model-message-driven, not
  per-frame; there is no workload where this would show up.
- **The hovered-link cursor is set two ways** (`resetCursorRects` derives it from
  `hoveredLink`, and `updateHoveredLinkChrome` also calls `NSCursor.set()`
  directly). The direct set exists for immediacy inside a tracking loop, which
  cursor rects cannot give; not duplication worth undoing.
- **`ToolbarDragHandleView` leaves the closed-hand cursor set when a drag session
  starts** (its `mouseUp` never arrives, and `endedAt` does not restore it).
  Self-correcting on the next `resetCursorRects`, and only visible for the length
  of the drag.
- **`draggingEntered` has no `draggingUpdated` companion.** Checked the contract:
  AppKit reuses the `draggingEntered` answer when the destination does not
  implement `draggingUpdated`, and the accepted-type set cannot change mid-drag.
  Correct as written.
- **Shift+wheel projected onto the X axis** (`verticalScrollDelta`). Verified
  against the policy: `wheelRoute` sends any Shift-modified wheel to
  `.localViewport`, so treating the projected X delta as vertical rows is exactly
  right and must survive INPUT-4.
- **`PaneInputOrigin`, `DragDropPasteboard`, `PaneDragCoordinator`,
  `PaneDragOverlayView`, `MenuCommandPolicy`.** Read in full, nothing found.
  `PaneInputOrigin`'s two-case split (system event time vs app entry) is the kind
  of distinction this audit exists to ask for, and the drag coordinator holds no
  geometry of its own.
- **`INTERACT-2` from the 2026-08-18 construction audit** is landed: the pointer
  events carry `TerminalViewportCell`, and `decideTerminalPointer` checks both
  `cell.isInsideGrid` and the geometry range in `isOnGrid`, exactly as the
  vetted correction prescribed. Nothing left live there.


### Area: iOS client kit (`MOBKIT`)

_Scope: `ios/DanTermMobileKit/Sources/DanTermMobileKit` (all 29 files) and the shell
that performs its effects -- `ios/DanTermMobileApp/Sources/DanTermMobileApp`
(`MobileSessionController.swift`, `TerminalSurfaceView.swift`,
`TerminalScrollChromeView.swift`, `MobileRootViewController.swift`,
`MobileSession.swift`, `TerminalInputView.swift`). Cross-checked the producer side
of the tape contract in `lib/DanTermCore/Sources/DanTermCore/PaneTapeStreamState.swift`,
`PaneTapeRecords.swift`, `lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeRecord.swift`
and `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift`._

**The auditor's read on the area.** The pure core is in very good shape. The
lifecycle enum makes serving-only facts unspellable elsewhere, the two-entry-point
split really does make a resize unspellable from an ordinary branch, and the replica's
cursor accounting is exact against the recorder -- I checked `advancedCursor`'s
asymmetric `originElapsedNanoseconds` rule against
`TerminalFlightRecorder#append` and it is right, not an oversight. The defects that
remain share one shape: **the boundary between the model and its shell leaks**. One
of them silently drops a record the shell could not read and lets the replica
desynchronize instead (MOBKIT-1); one round-trips every applied record back through
the shell to learn a fact the model already had (MOBKIT-3); two more make the shell
re-derive or re-write whole values that did not change (MOBKIT-2, MOBKIT-4); and two
carry a value the callee never reads (MOBKIT-5, MOBKIT-6). I did not audit the pure
arithmetic values that already have dense suites and no shell contact
(`MobileArrowPad`, `MobileDisplayText`'s selector rule, `MobileLaunchPlan`,
`MobileSmokeInputScript`) beyond reading them -- nothing in them was wrong. I looked
at `MobileObserveSurface`'s per-grid font re-resolution and dropped it: the previous
audit's `MOBILE-1` decided that boundary deliberately and the file says so.

<a id="mobkit-1"></a>

#### MOBKIT-1. End the stream on a record the phone cannot decode instead of skipping it

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rescored

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#receive`,
`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#take`,
`ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift#applyEvent`

**Problem.** Two adjacent lines in the same function treat the same class of problem
in opposite ways. A record that decodes but carries an event this build cannot read
ends the connection, with a stated reason. A record that does not decode at all is
skipped, and the stream carries on. Skipping is the worse of the two: a skipped
`.event` record leaves the replica's cursor one behind, so the very next record fails
`record.sequence == cursor.nextSequence` and the replica reports `.gap(.detected)`.
The model then ends the connection with `.streamDesynchronized`, which is the one
failure whose `preservesResumePosition` is false -- so the phone also throws away the
stored checkpoint and resumes from nothing. One malformed record costs the user their
scrollback and is reported as "Stream out of step with the Mac", which blames the Mac
for something the phone could not parse.

**Evidence.** `MobileSessionModel.swift#receive`, notification arm:

```swift
// One notification can carry a whole delivered batch. Each record is taken in
// wire order, exactly as it would have been had the producer sent them one at a
// time, and a record that will not decode is skipped rather than ending the rest.
var effects: [MobileSessionEffect] = []
for record in notification.records {
    guard let decoded = decodePaneTapeRecord(record) else { continue }
    effects += take(decoded, env: env)
}
```

and `MobileSessionModel.swift#take`, four lines below, on the same failure class:

```swift
/// An event this build cannot read ends the connection rather than being skipped. The
/// phone would otherwise render across a recorder event it does not understand and go
/// on claiming the replica is exact.
...
else {
    return end(with: .deviceSetup, detail: "Stream carried an unreadable event", env: env)
}
```

The desync that follows is `PaneReplica.swift#applyEvent`:

```swift
guard record.sequence == cursor.nextSequence else {
    state = .gap(.detected)
    syncAssembler = PaneTapeSyncAssembler()
    return
}
```

and `MobileReconnectEpisode.swift#preservesResumePosition` is what then discards the
checkpoint: `case .streamDesynchronized: false`.

`decodePaneTapeRecord` does not return nil for a record kind the build does not know
-- that decodes to `.unknown`
(`lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeRecord.swift#decodePaneTapeRecord`:
"A record kind this build does not know is not a failure: it decodes to `.unknown`").
Nil means malformed, so the `continue` cannot be a forward-compatibility allowance.

The same silent drop is in the response arm of `receive`, where it is worse still:

```swift
guard let value = response.result, let record = decodePaneTapeRecord(value) else {
    return []
}
```

That is the tape subscription's own success reply. A reply the phone cannot read
leaves the model in `.serving`, showing "Connected", with no stream and no timer that
will ever notice.

**Ideal fix.** Decode the record and lift its event in one step at the model's edge,
so there is exactly one verdict for "this build cannot read what arrived", and that
verdict is `end(with: .deviceSetup, detail: ...)`. Concretely: give `take` a
`JSONValue` and let it do both the `decodePaneTapeRecord` and the `mapEvent`, then
call it from both arms. The `continue` and the bare `return []` both disappear, and
the two arms stop being able to disagree.

**By construction.** "A record the phone could not read was applied to nothing and
nobody was told" stops being representable: every path from wire bytes to the replica
runs through one function with one failure return. It also removes a second way to
reach `.streamDesynchronized` -- afterwards that state means only what its doc comment
says it means, a real disagreement between two readable views of the stream.

**Cheaper fallback.** Replace `continue` with `return end(with: .deviceSetup, ...)`
and leave the response arm alone. Trade-off: the response arm keeps a path that parks
the phone in a permanently silent `.serving`, and the two arms still state the rule
twice.

**Verification.** `swift test --package-path ios/DanTermMobileKit --filter MobileSessionModelTests`.
New behavioral test: drive the model to `.serving`, then feed a
`.frameReceived(.notification(...))` whose `records` array holds one well-formed
`.event` record followed by a malformed one (`["kind": .string("event")]` with no
`sequence`), and assert the effects end with a disconnect and that
`projection(at:).status.text` contains the unreadable-stream wording -- not
"out of step". A second case: feed the malformed record alone and assert the resume
position is still trusted afterwards (drive a reconnect and assert the
`.attachPane` effect still carries `resumesFromStoredCheckpoint: true`), which is the
part that pins the checkpoint no longer being thrown away.

**Risk.** A Mac that emits a record shape this phone build does not understand now
drops the connection instead of limping. That is the intended trade and it matches
what `take` already does for events, but it means a protocol addition that changes an
existing record's required fields becomes a hard break rather than a soft one. It
cannot be triggered by a *new* record kind, which decodes to `.unknown`.

**Vetted.** I opened `MobileSessionModel.swift:600-613` (the notification arm, with the
comment and the `guard let decoded = decodePaneTapeRecord(record) else { continue }`
verbatim), `:588-591` (the response arm's `guard let value = response.result, let record
= decodePaneTapeRecord(value) else { return [] }`), `:633-647` (`take`, with the doc
comment and the `end(with: .deviceSetup, detail: "Stream carried an unreadable event")`
arm verbatim), `PaneReplica.swift:209-215` (`applyEvent`'s sequence guard, verbatim),
`MobileReconnectEpisode.swift:72-77` (`preservesResumePosition`, `.streamDesynchronized:
false`), and `PaneTapeRecord.swift:500-637` (`decodePaneTapeRecord`: `case nil: return
.unknown(kind: kind)` at :635, so nil really does mean malformed and never means an
unknown kind). Every quote is in the tree at the symbol named. `MobileStatus.swift:157`
confirms the wording is "Stream out of step with the Mac". The desync chain is real:
`.gap(.detected)` reaches the model as `.replicaStateChanged`, whose arm at
`MobileSessionModel.swift:311-313` returns `end(with: .streamDesynchronized)`, and
`MobileResumePolicy.connectionEnded` then sets `distrustsStoredPosition`.

I traced the response arm to the producer and it is worse than the prose says.
`app/PaneTapeBroker.swift:145-148` writes the tape reply's result as the `.start`
record itself, so an unreadable reply means the replica never gets a start, never
becomes exact, and no later notification can fix it -- `applyEvent` bails on `guard
state == .exact, var terminal, let cursor`. The model stays `.serving` with detail
"Connected to DanTerm <version>" and there is no request timeout and no socket receive
timeout (`MobileSession.swift:46-52` passes `receiveTimeout: nil` on purpose). And
`MobileConnectionFailure.deviceSetup`'s own doc comment at
`MobileReconnectEpisode.swift:43-46` names "a reply with neither result nor error" as
one of the things it is for -- which is exactly this branch, returning `[]`.

This is the lane's one `correctness` finding and it cites no `references/` emulator, so
there is no external behavior claim to re-check.

**Correction.** Impact 4 overstates the reachability. Both silent drops need
`decodePaneTapeRecord` to return nil, and the producer is this repo's own encoder
reached over a framed JSON-RPC transport, so the JSON always parses -- nil means a
semantic mismatch about required fields. On matched Mac and phone builds neither branch
can fire. The trigger is build skew: a phone binary installed before a Mac-side change
to a record's required fields. That is a real condition for this project (the phone is
installed separately by `just ios-app`) and it will happen during development, where the
symptom -- "Stream out of step with the Mac", scrollback discarded -- actively
misdirects the person debugging it. Harm high, reachability narrow: impact 3.

Two smaller notes on the fix. Handing `take` a `JSONValue` does not delete the response
arm's nil check outright, because `response.result` is itself optional; that arm still
needs `guard let value = response.result` before it can call the one function. And the
one-verdict claim only holds for `.event` records among the skipped kinds -- a skipped
`.sync`, `.gap` or `.start` desynchronizes nothing, so the "one malformed record costs
the user their scrollback" chain is specific to `.event`, as the prose says.

**Conflicts with.** MOBKIT-3. Both rewrite `MobileSessionModel#take` -- MOBKIT-1 changes
its parameter to `JSONValue` and moves the decode inside, MOBKIT-3 adds the `.end` branch
to its body. Either order works, but the second one to land has to be rebased onto the
first; they cannot be implemented independently.

<a id="mobkit-2"></a>

#### MOBKIT-2. Build the pane outline where the roster arrives, not on every projection read

`cost` &middot; impact 2, confidence 5 &middot; effort medium &middot; rescored

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#projection`,
`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileDisplayText.swift#MobilePaneOutline`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift#showArrowPad`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift#layoutArrowPad`

**Problem.** `projection(at:)` rebuilds the entire pane outline from the raw roster
every time it is read: one `MobilePaneGroup` per group, one `MobilePaneTab` per tab,
one `MobilePaneEntry` per pane, and one `MobileDisplayText(preparing:)` -- a
per-`Character` scan that builds a new string -- for every group, tab and pane title
in the whole roster. The roster changes in two places. The projection is read far
more often than that, including on paths that want one `PaneId` out of it, and
including from `viewDidLayoutSubviews`, which runs every frame of a keyboard
animation.

**Evidence.** `MobileSessionModel.swift#projection` builds it unconditionally:

```swift
public func projection(at now: TimeInterval) -> MobileSessionProjection {
    let selectedPaneId = selectedPaneId
    let outline = MobilePaneOutline(items: panes, selectedPaneId: selectedPaneId)
```

`MobileDisplayText.swift#MobilePaneEntry` prepares a title per pane, and
`MobileDisplayText#init(preparing:)` is a per-cluster loop:

```swift
for cluster in raw {
    prepared.append(cluster)
    if let selector = terminalPresentationSelectorToAppend(for: cluster.unicodeScalars) {
        prepared.unicodeScalars.append(selector)
    }
}
```

The shell reads the whole projection for one field in five places.
`MobileRootViewController.swift#showArrowPad` says outright that it runs per redraw,
and then reads the projection twice, because `layoutArrowPad` reads it again:

```swift
/// It resolves the placement itself rather than asking for a layout pass: this runs on
/// every redraw, and one `setNeedsLayout` per published frame would put a whole layout
/// pass behind the terminal's output.
private func showArrowPad() {
    let shown = session.projection.selectedPaneId.map(arrowPads.isVisible) ?? false
    ...
    layoutArrowPad()
}

private func layoutArrowPad() {
    guard arrowPad.isHidden == false, arrowPadDrag == nil else { return }
    guard let pane = session.projection.selectedPaneId else { return }
```

and `viewDidLayoutSubviews` calls `layoutArrowPad()` on its own. The same
one-field-from-a-whole-projection read is in `terminalInput.onTap`,
`bottomBar.onToggleArrowPad`, `arrowPad.onMoveToCorner`, and `sessionMenuItems`.

**Ideal fix.** The model stores `panes: [PaneRosterItem]` -- the raw wire list -- and
re-derives the prepared outline from it on every read. Store the prepared outline
instead, built at the two sites that write the roster (the `.attemptSucceeded` arm and
the `PaneRosterNotification` arm), and delete the raw array. This is not a cache beside
an authority; it changes which representation *is* the authority, and the raw list has
exactly two writers. Two things have to move for it to be possible, and both are
improvements on their own: `initiallyExpandedTabId` depends on the selection, so it
leaves the stored value and becomes `outline.initiallyExpandedTabId(for:)` called by
the sheet; and `attemptSucceeded`'s default-pane choice reads `isSelectedTab` /
`isFocused`, which the outline does not carry, so the outline gains one
`defaultPaneId` field decided where the roster arrives. Then add
`MobileSessionModel.selectedPaneId` and a `MobileSessionController.selectedPaneId`
so the shell stops reading a projection to get one id.

**By construction.** The raw roster list and the prepared outline stop both being
representable in the model, so they cannot disagree about the roster. `MobilePaneOutline`
also stops mixing a structural fact (the rows) with a selection fact
(`initiallyExpandedTabId`), which is what makes its `Equatable` conformance mean
"the same rows" -- exactly what `PaneSheetViewController#show` and
`rowsNeedingRefresh` want it to mean.

**Cheaper fallback.** Leave the model alone and add
`MobileSessionController.selectedPaneId` reading a new cheap model accessor, so only
the five one-field shell reads stop paying. Trade-off: the outline is still rebuilt on
every `.redraw`, which is every accessory key press and every latch change, and the
raw/prepared duplication stays.

**Verification.** This is a cost finding, so it names an experiment, not a result.
Command: build the kit's outline path in isolation --
`swift test --package-path ios/DanTermMobileKit --filter PaneOutlineRefreshTests` plus a
new throwaway measurement harness in the same package that constructs a
`MobileSessionModel`, feeds it a roster of 40 panes across 8 tabs in 3 groups, and
calls `projection(at:)` 10_000 times. The number that must move is the wall time of
that loop, and the allocation count under `MobileDisplayText.init(preparing:)`, which
must fall to zero for reads that follow a roster that did not change. Behavior is held
by the existing `PaneOutlineRefreshTests` and `MobileSessionModelTests`, which must
stay green unchanged apart from the `initiallyExpandedTabId` call site.

**Risk.** The outline stops being recomputed against the current selection, so any
consumer that relied on `MobilePaneOutline` inequality to notice a selection change
has to read the selection beside it. `PaneSheetViewController#show` already does
(`guard self.outline != outline || selectedPaneId != selected`), and
`rowsNeedingRefresh` already takes both selections as parameters, so the two live
consumers are covered -- but that is the thing to check first.

**Vetted.** I opened `MobileSessionModel.swift:119-132` (`projection(at:)`, building
`MobilePaneOutline(items: panes, selectedPaneId:)` unconditionally, verbatim),
`MobileDisplayText.swift:24-34` (the per-cluster loop, verbatim), `:38-48`
(`MobilePaneEntry.init` preparing a title per pane), `:60-67` and `:76-90` (per-tab and
per-group prepares), `:99-114` (`MobilePaneOutline.init` and `initiallyExpandedTabId`
computed from the selection), and `MobileRootViewController.swift:314-320`,
`:349-357`, `:70-85`, `:110`, `:117`, `:124`, `:166`, `:253-291`, `:390`. Every quote
is there. The one-field reads are six, not five: `showArrowPad`, `layoutArrowPad`,
`terminalInput.onTap`, `bottomBar.onToggleArrowPad`, `arrowPad.onMoveToCorner`, and
`dragArrowPad`'s `.began` arm. `PaneSheetViewController.swift:55-56` and `:121` confirm
the risk analysis: `show` already guards on `self.outline != outline || selectedPaneId
!= selected`, so dropping `initiallyExpandedTabId` from the outline does not break it.

**Correction.** The rate argument in **Problem** and **Evidence** is wrong, and the cost
survives only by a different route. The projection is not rebuilt per published frame.
`didPublishFrame` calls `scrollChrome.refresh()` and nothing else; `.replicaAdvanced`
(`MobileSessionModel.swift:321-325`) returns only `.armCheckpointTimer`, never
`.redraw`; and `.surfaceChanged` (`:401-402`) guards on `facts != surface` before it
redraws. `showArrowPad`'s comment cited as proof of the rate says "on every redraw" and
only mentions "per published frame" hypothetically, about a `setNeedsLayout` it declines
to schedule. `layoutArrowPad` also early-returns on `arrowPad.isHidden` before it reads
the projection, so the keyboard-animation path costs nothing while the pad is hidden,
which is its default.

The real driver is roster pushes. `IpcRequest.swift:32-36` documents `roster` as a
subscription, and `AppRuntime.swift#pushRosterIfChanged` sends a `roster.event` whenever
the roster differs -- which `rowsNeedingRefresh`'s own doc comment says happens "several
times a second" for an agent that renames its pane. Each one sets `panes` and returns
`.redraw`. That is a genuine several-times-a-second rebuild of every prepared string in
the roster. The waste on top of it is that one redraw builds the outline twice:
`render(_:)` takes a projection at `:253` and then calls `showArrowPad()` at `:290`,
which builds a second whole projection for one `PaneId` -- a third when the pad is shown
and `layoutArrowPad` reads it again.

That double build inside a single `render` is the cheap, high-value part of this
finding, and it is not the "cheaper fallback" as written: passing the already-built
projection into `showArrowPad`/`layoutArrowPad` removes one or two full outline builds
per redraw for a few lines, with no model change at all. Do that first and measure
before spending medium effort restructuring the model's authority. The structural half
of the ideal fix -- raw list and prepared outline both representable -- is real and I
agree with it, but it is a `structural` argument wearing a `cost` label: the measured
saving is a few thousand `Character` iterations a few times a second on a phone that is
simultaneously running a terminal renderer. Impact 2.

**Conflicts with.** MOBAPP-2, which adds a `MobileSessionMenu` value to
`MobileSessionProjection` and rewrites `MobileRootViewController#render` and
`#sessionMenuItems` -- the same projection type and the same two functions this finding
restructures. MOBAPP-6 also edits `render` (guarding the pill write), so it needs the
same rebase, though it does not contend for the same lines.

<a id="mobkit-3"></a>

#### MOBKIT-3. Decide a stream's end where the record is decoded, and delete the record round trip

`simplification` &middot; impact 3, confidence 5 &middot; effort small &middot; confirmed

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionEvent.swift#MobileSessionEvent`,
`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileSessionModel.swift#take`,
`ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift#apply`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift#perform`

**Problem.** Every applied record makes a full round trip out to the shell and back
into the model, so the model can learn one thing it already knew when it produced the
record: whether the record was an `.end`. The record carries the feed bytes. The
shell learns nothing from the trip, the replica does nothing with an `.end` record,
and the model's own arm discards every other kind.

**Evidence.** The model emits the record, gets it back, and reads one case:

```swift
case .recordApplied(let record):
    guard case .serving = lifecycle else { return [] }
    guard case .end(let reason) = record else { return [] }
    return end(with: .streamEnded(reason: reason?.rawValue), env: env)
```

The shell's only job on the way is to hand it back:

```swift
case .applyRecord(let record):
    do {
        try surfaceView.apply(record)
        dispatch(.recordApplied(record))
    } catch {
        dispatch(.replicaRejectedRecord)
    }
```

and the replica does nothing with the case that is the entire reason for the trip --
`PaneReplica.swift#apply`: `case .end, .unknown: break`. The failure half of the trip
is already reported separately, by `.replicaRejectedRecord`, and an `.end` record
cannot make `apply` throw.

**Ideal fix.** Read the end in `take`, where the record is already typed and in hand:

```swift
noteRecordPinnedness(typed)
if case .end(let reason) = typed {
    return end(with: .streamEnded(reason: reason?.rawValue), env: env)
}
return [.applyRecord(typed)]
```

Then delete `MobileSessionEvent.recordApplied` and the shell's `dispatch` of it. The
effect order the phone observes is unchanged: the ending effects are what followed the
apply before, and the apply itself was a no-op for an end record.

**By construction.** "The shell told the model about a record the model authored"
stops being representable -- there is one `MobileSessionEvent` fewer, and one fewer
place where the shell can be believed about the stream. It also removes a whole-record
value from the shell's event queue on the hot path.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `swift test --package-path ios/DanTermMobileKit --filter MobileSessionModelTests`.
The existing end-record test must pass unchanged if it drives `.applyRecord` through
a shell stub; if it dispatches `.recordApplied` directly it has to be rewritten to
assert on the effects returned from `.frameReceived` carrying an end record, which is
the structure-insensitive form and the one that should have been written anyway.

**Risk.** If any future shell needs to know that a record reached the replica, the
event is gone and has to come back. Nothing today needs it: the surface's own
callbacks (`didAdvanceReplica`, `didChangeReplicaState`, `didChangeReplicaFacts`)
already report every replica fact the model consumes.

**Vetted.** I opened `MobileSessionModel.swift:299-302` (the `.recordApplied` arm,
verbatim), `MobileSessionEvent.swift:85` (`case recordApplied(MobilePaneTapeRecord)`),
`MobileSessionController.swift:200-206` (the `.applyRecord` arm and its
`dispatch(.recordApplied(record))`, verbatim), `PaneReplica.swift:113-127` (`apply`, with
`case .end, .unknown: break` at :125), and `MobileSessionEffect.swift:29-31`. Every quote
is there. `apply` can only throw from `applyStart` and `replace`, so an `.end` record
genuinely cannot make it throw, and the failure half of the trip is already reported by
`.replicaRejectedRecord`. Grepping the whole `ios/` tree, `recordApplied` appears in
exactly four places -- the enum case, the model arm, the effect's doc comment, and the
shell dispatch -- so the round trip has no other consumer.

The `.end` case is more isolated than the prose says, which strengthens the finding.
`recordApplied` appears in no test at all, and no test in
`MobileSessionModelTests` reaches `.streamEnded` -- the only `streamEnded` hits in the
suite are in `ReconnectEpisodeTests`, `ResumePolicyTests`, `ConnectionStateTests` and
`StatusLineTests`, all of which construct the failure directly. So the model's whole
end-of-stream path is reachable today only through the shell, which has no test target.
Moving the decision into `take` makes it testable from `.frameReceived`, which is the
best argument for this change and is not stated above.

**Correction.** "The effect order the phone observes is unchanged" needs one
qualification. `receive`'s notification arm accumulates effects across a whole batch, so
today an end record in the middle of a batch is applied, the records after it are also
applied, and only then does the queued `.recordApplied(end)` end the connection. After
the fix, `take` ends the connection at the end record and every later record in that
batch returns `[]` on its `guard case .serving` -- so those records are dropped rather
than applied. I checked the producer: `app/PaneTapeBroker.swift:152` and `:327` and
`lib/DanTermCore/.../PaneTapeRecords.swift:157` all put `.end` last in its batch, so no
record can follow one in practice. The change is safe, and arguably more correct, but
it is a behavior change on a batch the producer does not emit rather than a no-op.

The **Verification** paragraph should be rewritten: there is no existing end-record test
to keep passing. The test named there has to be written from scratch -- drive the model
to `.serving`, feed `.frameReceived(.notification(...))` carrying an end record, and
assert the effects end the connection with `.streamEnded`.

**Conflicts with.** MOBKIT-1. Both rewrite `MobileSessionModel#take`; see that finding's
note. No conflict with MOBKIT-6 or IPC-3, which touch `MobileSessionController#beginStream`
and `#send` rather than the `.applyRecord` arm.

<a id="mobkit-4"></a>

#### MOBKIT-4. Reflect the scroll chrome only when the mode it describes moved

`cost` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileScrollDriver.swift#replicaChanged`,
`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileScrollDriver.swift#reflection`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/TerminalScrollChromeView.swift#refresh`

**Problem.** `refresh()` runs after every published frame, so on a pane producing
output it runs at display-link rate. Whenever the interaction latch is open --
which is whenever the user is not touching the screen, i.e. almost always -- the
driver answers with a reflection unconditionally, whether or not anything about the
chrome moved. The shell then writes `showsVerticalScrollIndicator` and `contentSize`
on a `UIScrollView` every frame. On the alternate screen the reflection is the same
two constants every time, and it re-seeds the delta baseline every frame too.

**Evidence.** `MobileScrollDriver.swift#replicaChanged` ends with an unconditional
return:

```swift
let flipped = next.kind != mode.kind
mode = next
if flipped, interaction.isActive { gestureModeIsStale = true }
guard interaction.isActive == false else { return [] }
return [reflection()]
```

`reflection()` is a pure function of `mode` -- in `.delta` it does not read anything
else at all:

```swift
case .delta:
    lastNamedTopRow = nil
    delta = MobileScrollDelta(baseline: Self.deltaCenter)
    return .reflect(
        contentHeight: Self.deltaContentHeight,
        offset: Self.deltaCenter,
        showsIndicator: showsIndicator
    )
```

and the shell performs it without a guard on the two writes that are not offset:

```swift
case .reflect(let contentHeight, let offset, let showsIndicator):
    showsVerticalScrollIndicator = showsIndicator
    contentSize = CGSize(width: 0, height: contentHeight)
    if contentOffset.y != offset { contentOffset = CGPoint(x: 0, y: offset) }
```

The caller's own comment confirms the rate --
`TerminalScrollChromeView.swift#refresh`: "Called after every published frame, local
scroll, layout pass, and pane attach."

**Ideal fix.** `replicaChanged` already holds the authority for what the reflection
would say: `mode`. Compare the incoming mode with the held one and answer nothing when
they are equal, so a frame that moved no scroll fact produces no action. No new state
is added -- the comparison is against the value the type already stores, and
`MobileScrollMode` is already `Equatable`. `interactionChanged`'s return-to-idle
reflection stays unconditional, because there the offset moved under the driver's feet
and only a reflection reconciles it.

**By construction.** "The chrome was rewritten with the values it already held"
stops being representable from the driver's side, which is where every other scroll
rule already lives; the shell keeps translating actions and deciding nothing.

**Cheaper fallback.** Guard the two unguarded writes in the shell
(`if contentSize.height != contentHeight`, `if showsVerticalScrollIndicator != ...`).
Trade-off: the decision moves into the untested app target, the driver still allocates
and returns an action array per frame, and the delta baseline is still re-seeded per
frame.

**Verification.** Cost finding, so this names the experiment. Behavior first:
`swift test --package-path ios/DanTermMobileKit --filter MobileScrollTests` must stay
green, plus one new test asserting that a second `replicaChanged` with an identical
projection, row height and screen mode returns `[]` while the first returns one
`.reflect`. For the cost claim: run the app against a slot with `just ios-app`, run
`yes` in the pane so frames publish continuously, and count `contentSize` setter calls
per second on `TerminalScrollChromeView` (a counter in a debug build, or an Instruments
time profile of `UIScrollView.setContentSize:`). The number that must move is calls per
second on the alternate screen and on a repainting primary screen, which must fall to
zero while the projection is unchanged.

**Risk.** A reflection that today happens to repair a `contentOffset` UIKit moved for
its own reasons would stop happening. `resizeViewport` is the one thing that could
provoke that, and it only changes the chrome's height when `windowRows` or `rowHeight`
changed -- both of which live inside `MobileScrollGeometry` and therefore change the
mode, which still reflects. Worth confirming on a rotation with the keyboard up, where
the frame moves and the height does not.

**Vetted.** I opened `MobileScrollDriver.swift:80-95` (`replicaChanged`, ending in the
unconditional `return [reflection()]`, verbatim), `:142-167` (`reflection()`, with the
`.delta` arm verbatim), `:99-108` (`interactionChanged`, which produces only on the
return to idle), `TerminalScrollChromeView.swift:61-77` (`refresh` and its "Called after
every published frame, local scroll, layout pass, and pane attach" comment, verbatim),
`:103-125` (`perform`, with the two unguarded writes verbatim), and
`MobileScrollGeometry.swift:82-129` (`MobileScrollMode` and `select`). Every quote is
there, and `MobileSessionController.swift:78` confirms `didPublishFrame` calls
`scrollChrome.refresh()` on every frame.

I checked whether skipping the reflection can leave state stale, which is the thing the
finding does not test. It cannot. `lastNamedTopRow` and `delta`'s baseline are read only
by `offsetChanged`, which bails immediately unless `interaction.isActive`; and the latch
always closes through `interactionChanged`, which reflects and re-seeds both. `mode`
equality also covers the geometry: `.projected` carries the whole
`TerminalScrollProjection`, and `.delta`/`.inert` reflect constants, so an equal mode
really does imply an identical reflection. `resizeViewport` can change the view's frame
under an unchanged mode only in `.delta` and `.inert`, where the content height is
100_000 or 0 and no clamp of `contentOffset` is reachable. The ideal fix is sound.

**Correction.** The payoff is narrower than **Problem** and **Verification** claim.
`.projected(geometry)` holds the projection itself, so on a primary screen producing
output the `topRow` and `totalRows` move every frame, the mode compares unequal every
frame, and the reflection still happens. The verification's target -- "calls per second
on ... a repainting primary screen, which must fall to zero" -- is unreachable by
construction, and asking for it would make a correct implementation look like a failure.
What the change actually removes is the per-frame reflection on the alternate screen,
where the mode is a constant `.delta(rowHeight)`, and on any idle-but-republishing
primary screen whose projection did not move. The alternate screen is the phone's common
heavy case, so the saving is real -- two `UIScrollView` property writes and one array per
frame -- but it is two property writes, not a category of work. Impact 2. Write the
experiment as "alternate-screen `contentSize` setter calls per second must fall to zero"
and drop the primary-screen half of the claim.

**Conflicts with.** Nothing. No other lane file in this directory names
`MobileScrollDriver.swift` or `TerminalScrollChromeView.swift`.

<a id="mobkit-5"></a>

#### MOBKIT-5. Carry the connection phase only on the failure that reads it

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileReconnectEpisode.swift#MobileConnectionFailure`,
`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileConnectionState.swift#establishmentFailure`

**Problem.** `MobileConnectionFailure.transport` takes a `MobileConnectionPhase` that
no reader ever consults, so `.transport(.peerClosed, phase: .establishing)` and
`.transport(.peerClosed, phase: .established)` are two distinct, `Equatable`-different
values that mean exactly the same thing everywhere they are used. Every producer has
to pick one, every test has to spell one, and the choice decides nothing.

**Evidence.** All three consumers of the transport case discard the phase.
`MobileConnectionFailure#state`:

```swift
// A transport failure words the same in both phases: none of them is silence, and
// each already names a condition rather than a stage.
case .transport(let error, _): MobileConnectionState.failure(error)
```

`MobileConnectionFailure#retryClass`: `case .transport(let error, _):`.
`MobileConnectionFailure#preservesResumePosition` lists the case without binding
anything: `case .transport, .conversation, .streamEnded, .requestRefused, .deviceSetup: true`.
The comment above the `state` arm states the fact and then keeps the parameter anyway.
The phase is read in exactly one place, on the conversation case, and there it feeds a
one-error rule --
`MobileConnectionState.swift#establishmentFailure`: `error == .peerSilent ? .serverUnreachable : failure(error)`.

**Ideal fix.** Drop the associated value from `.transport`, so the case is
`transport(TCPSocketTransportError)`. The phase stays on `.conversation`, where it is
the difference between "the Mac never answered" and "the connection was lost", and
`establishmentFailure` keeps its one reader. Six call sites in
`MobileSession.swift`/`MobileConnectionRunner.swift` and about a dozen test literals
drop an argument.

**By construction.** Two failure values that mean the same thing stop being spellable,
so a test that pins a phase on a transport failure cannot pass for a reason the
product does not have, and a new producer cannot agonize over a choice with no
consequence.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `swift test --package-path ios/DanTermMobileKit --filter ReconnectEpisodeTests`
and `--filter ResumePolicyTests`. Both suites already enumerate every transport error
against its expected `retryClass` and `state`; the expectations must be unchanged
after the parameter is removed, which is the proof that nothing read it.

**Risk.** If a future rule does need to tell an establishing transport failure from an
established one -- a connect timeout worded differently from a mid-stream read timeout
-- the parameter has to come back. That rule does not exist, and the comment on the
`state` arm argues it should not.

**Vetted.** I opened `MobileReconnectEpisode.swift:34-46` (the enum, `case
transport(TCPSocketTransportError, phase: MobileConnectionPhase)` at :35), `:50-63`
(`state`, with the comment and `case .transport(let error, _)` verbatim), `:72-77`
(`preservesResumePosition`, listing `.transport` unbound), `:80-110` (`retryClass`, `case
.transport(let error, _)` at :82), and `MobileConnectionState.swift:53-61`
(`establishmentFailure`, `error == .peerSilent ? .serverUnreachable : failure(error)`
verbatim). Every quote is there. I then grepped every consumer of
`MobileConnectionFailure` in `ios/`: the model stores it in `.failed` and reads it only
through `failure.state`, `MobileResumePolicy.connectionEnded` reads only
`preservesResumePosition`, and `MobileReconnectEpisode#standing(after:at:)` reads only
`retryClass`. Nothing else destructures the case. The phase on `.transport` genuinely has
no reader.

**Correction.** The call-site count is off. There are six production sites, but four are
in `MobileSession.swift` (`:73`, `:95`) and `MobileConnectionRunner.swift` (`:49`, `:51`)
and two are in `MobileSessionController.swift` (`:280`, `:307`), which the **Ideal fix**
paragraph does not mention. The test count is larger than "about a dozen": `.transport(`
appears 33 times across `ios/DanTermMobileKit/Tests`. The change stays small, but plan
for the third file.

**Conflicts with.** MOBKIT-6 and IPC-3. All three edit
`MobileSessionController#beginStream` and `#send`: this finding drops an argument from
the `.transport(.writeFailed, phase: .established)` literals at `:280` and `:307`,
MOBKIT-6 rewrites the guards those two functions open with, and IPC-3 makes
`IpcRequest.params` a closure, which changes `:276` and `:304` in the same two bodies.

<a id="mobkit-6"></a>

#### MOBKIT-6. Report the two effects the shell cannot perform instead of dropping them

`structural` &middot; impact 2, confidence 4 &middot; effort small &middot; confirmed

**Files.** `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift#beginStream`,
`ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift#send`

**Problem.** Two effect interpreters can decline to do their job and tell nobody. The
model believes the request went out and waits for a response that will never arrive;
there is no timeout on a request, so the phone shows "Connected" forever with no
stream and no way back except the user noticing.

**Evidence.** `beginStream` returns without a word when the session is gone:

```swift
private func beginStream(requestId: MobileRequestId, request: IpcRequest) {
    guard let session = pendingSession else { return }
```

The model has already moved to `.serving(ServingConnection(pane:tapeRequestId:detail:))`
by the time this effect is performed, and only a response on `tapeRequestId` or a
`connectionEnded` can move it off. `send` has the same hole through optional chaining:

```swift
try runner?.send(JsonRpcRequest(...))
```

A nil `runner` is not an error, so the `catch` that would report
`.connectionEnded(.transport(.writeFailed, phase: .established))` never runs.

I traced both guards and could not reach either from the current event order --
`drain()` runs synchronously on the main actor, so nothing interleaves between
`.attemptSucceeded` and `.paneAttached`, and every path that nils `runner` also moves
the lifecycle out of `.serving`. That is why confidence is 4, not 5: the defect is the
silent drop, not a reproducible hang today.

**Ideal fix.** Make both interpreters total. Replace each guard with a report:
`dispatch(.connectionEnded(.deviceSetup))` -- which is exactly what that failure is
documented for, "the phone could not make sense of ... its own setup". For `send`,
bind the runner (`guard let runner else { ...; return }`) so the nil case is a stated
branch rather than a swallowed one.

**By construction.** No state stops being representable -- the shell's `runner`
optional is genuinely a shell fact. What stops being representable is a *silent*
divergence: after the change, every branch of the effect interpreter either performs
the effect or hands the model a cause, so the model's belief about its own stream can
only be wrong for a reason it was told about.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** The app target has no test target, which is the reason this defect
survives. The behavioral check has to be the model's: a test in
`MobileSessionModelTests` asserting that `.connectionEnded(.deviceSetup)` while
`.serving` ends the connection and words the status as a device-setup failure -- so
that the shell has a correct thing to call. The shell change itself is confirmed by
reading it, plus a smoke run (`just ios-app simulator --slot N`) that still attaches
and streams.

**Risk.** Almost none: the two branches are unreachable today, so the change is
observable only if one of them ever fires, which is precisely the case it is for.

**Vetted.** I opened `MobileSessionController.swift:269-297` (`beginStream`, opening on
`guard let session = pendingSession else { return }`, verbatim) and `:299-309` (`send`,
with `try runner?.send(JsonRpcRequest(...))` inside the `do`, verbatim). Both quotes are
there. The lifecycle claim holds: `MobileSessionModel.swift:280-303` shows `.paneAttached`
setting `lifecycle = .serving(ServingConnection(...))` and then returning
`[.beginStream(...)]`, so the model is already serving when the guard runs.

I re-ran the reachability trace and it holds. `drain()` (`:152-171`) pops one event,
performs its effects in order, and any `dispatch` from inside a `perform` only appends to
`pendingEvents` because `isDraining` is set -- so nothing interleaves between
`.attemptSucceeded` and `.paneAttached`. `pendingSession` is assigned at `:247`
immediately before `dispatch(.attemptSucceeded)` and is cleared only by `disconnect()`
(`:257-266`), which runs only on the `.disconnect` effect, which `end()`
(`MobileSessionModel.swift:521-529`) always emits first. `runner` is set in `beginStream`
and nilled in the same `disconnect()`. I also chased the one path that looked like it
might reach the `send` hole -- `beginStream`'s `catch` leaves `runner` nil while
`.driveSmokeInput` runs synchronously through `TerminalInputView.drive` -- and it does
not: the `.connectionEnded` dispatched at `:280` is queued ahead of the smoke input's
events, so by the time a `.textEntered` is handled the lifecycle is `.failed` and no
`.send` effect is produced. Confidence 4 is right: this is a total-function defect, not
a live bug.

The `deviceSetup` remedy is the correct one. `MobileReconnectEpisode.swift:43-46`
documents that case as "The phone could not make sense of what it got, or of its own
setup", `retryClass` maps it to `.manual`, and `preservesResumePosition` keeps the
checkpoint -- which is what a shell-side hole should do.

**Conflicts with.** MOBKIT-5 and IPC-3, for the reason given under MOBKIT-5: all three
edit the bodies of `beginStream` and `send`. MOBAPP-4 deletes `runnerThread` from the
same file but touches neither function, so it can land independently.

#### Dropped (MOBKIT)

- **Per-grid font re-resolution in `MobileObserveSurface.init`.** Every distinct
  remote grid resolves a second `TerminalRenderMetrics` at the fitted scale, so a
  Mac-side drag-resize costs one CoreText font set per resize event. Dropped: the
  previous audit's `MOBILE-1` drew this exact boundary, and the file states the
  decision ("The second resolution below is genuinely per-grid: the fitted scale
  depends on the columns and rows, which no layout pass knows"). Revisiting it is a
  decision to reopen, not a defect.
- **`MobileFramePresenter.tick` clearing `isDrainPending` when the replica is not
  exact.** Looked like lost damage. It is not: exactness only ever returns through
  `PaneReplica#replace`, which builds a fresh terminal, and the record that carried
  the sync calls `noteDrainPending` on its way out of `TerminalSurfaceView#apply`.
- **`PaneReplica#applyStart` leaving a checkpoint-restored replica `.exact` after a
  cursor-less start record.** Traced to the producer: a synchronization opening with
  an unplaceable cursor always precedes the sync with `.gap(.total)`
  (`lib/DanTermCore/Sources/DanTermCore/PaneTapeStreamState.swift#reconstructibleOpening`),
  and `.now` is only requested when there is no checkpoint to restore. No observable
  window.
- **`PaneReplica#advancedCursor` requiring `originElapsedNanoseconds == nil` for
  `.feed` but allowing it for `.write`.** Correct, not an oversight: the recorder
  passes an origin only on the write path
  (`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift#append`
  is called with `origin: nil` for everything else).
- **`MobileTargetDraft#validate` accepting port 0 and not trimming the port field.**
  Real but cosmetic; the field label already says "from 0 to 65535", and a bad port
  fails the connect with a transport cause the user can read.
- **`items.first!` in `MobilePaneTab.init` and `MobilePaneGroup.init`.** The grouping
  loops in `MobilePaneOutline.init` cannot produce an empty slice, and making the
  inits failable would add a nil case no caller can reach -- a guard added, not
  deleted.
- **`.surfaceChanged` renewing a standing claim without returning `.redraw`.** Chased
  it: the only projection field a renewal can move is `claim.claim`, which is non-nil
  before and after (the grid changed, it did not vanish), so nothing renders stale.
- **`MobileConnectionRunner` reporting every cause with `phase: .established`.**
  Correct by construction -- the runner only exists after `beginStream`, so the
  connection is established by definition.
- **No deadline on `.gap(.declared)`.** The producer has already sent the replacement
  sync by contract, and a timer here would be a second silence rule beside the
  session's own liveness watchdog, which is the shape `MobileSessionAttempt` already
  argues against in a comment.


### Area: iOS app shell (`MOBAPP`)

_Scope: `ios/DanTermMobileApp/Sources/DanTermMobileApp/` (all 14 files), `ios/DanTermMobileApp/Info.plist`, `ios/DanTermMobileApp/Package.swift`. Read as context, not audited as my lane: `ios/DanTermMobileKit/Sources/DanTermMobileKit/{MobileInputMapper,MobileArrowPad,MobileLaunchPlan,MobileSessionModel}.swift`, `app/SwiftTerminalSessionView.swift`, `lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift`._

**The auditor's read on the area.** The shell is in unusually good shape for a
UIKit layer: the views hold no session fact, every redraw states a whole control
rather than patching it, the arrow pad's geometry is a pure tested value in the
kit, and almost every UIKit write that dirties layout is guarded with a comment
saying why. The remaining defects share one shape -- a decision that belongs in
`DanTermMobileKit` (where it would have a test) is made instead in the app
target, which has no test target at all. That is what produces the hardware-key
mapping bug, the menu-offered predicate, and the launch-sheet rule: three rules
stated twice, once in a tested value and once in a switch or a boolean in the
shell. I did not audit the connect/replica networking (`MobileSession.swift` is
a thin thread wrapper over `DanTermClient`, which is another lane), the frame
presentation path inside `TerminalSurfaceView` (owned by the closed audit's
`MOBILE-1`/`MOBILE-2`, both landed), or the build scripts. I looked at
`window?.screen.scale ?? traitCollection.displayScale` and dropped it: the
fallback is load-bearing before the view enters a window, and `UIWindow.screen`
is not deprecated in the iOS 26.5 SDK.

<a id="mobapp-1"></a>

#### MOBAPP-1. Send the shifted character a hardware key would insert, and decide that in the kit

`correctness` &middot; impact 4, confidence 5 &middot; effort medium &middot; confirmed

**Files.** `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift#pressesBegan`, `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift#mobileModifiers`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileInputMapper.swift#hardwareCharacter`

**Problem.** With a hardware keyboard attached, a Shift-only chord sends the
*unshifted* character. `pressesBegan` handles any press whose modifier set is
non-empty, and Shift alone is a non-empty set. It then reads
`charactersIgnoringModifiers`, which the SDK documents as always lowercase and
as ignoring Shift by definition, lowercases it again, and dispatches it with
`[.shift]`. The owner encodes `.key(.character(c), [.shift])` by writing the
scalar's own UTF-8, so Shift+A puts `a` in the pane and Shift+2 puts `2`, not
`@`. Because the press is marked `handled`, `super.pressesBegan` is never
called, so nothing further up the chain can supply the shifted text. The
symmetric hazard is that UIKit's text-input system may insert `A` through
`UIKeyInput.insertText` for the same press, in which case the pane gets both
`A` and `a`; either way the shell's own path cannot produce the right byte.

**Evidence.** The gate and the lookup, in `MobileRootViewController#pressesBegan`:

```swift
} else if modifiers.isEmpty == false,
          let character = key.charactersIgnoringModifiers.lowercased().first
{
    session.dispatch(.hardwareCharacterPressed(character, modifiers))
    handled = true
}
```

The SDK states what those two properties mean
(`iPhoneSimulator26.5.sdk/.../UIKit.framework/Headers/UIKey.h`):
`characters` is "a string representing what would be inserted into a text field
... if shift is held on a Latin keyboard, this will contain capital letters",
and `charactersIgnoringModifiers` is "not taking shift key into account ...
expect this to be always in lowercase". So `.lowercased()` is a no-op on the
value it is applied to, and the shifted form is discarded.

The encoder confirms the byte:
`lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift#encodeLegacyKey`
has `case .character(let scalar): base = modifiers.contains(.control) ?
legacyControlBytes(for: scalar) : Array(String(scalar).utf8)` -- Shift is not
consulted at all for a character key, by design, because Shift is supposed to
have been resolved into the character before it gets there.

DanTerm's own Mac surface is the authority for the right gate.
`app/SwiftTerminalSessionView.swift#terminalKey(for:)` refuses to build a
character key event unless Control or Option is held:

```swift
guard event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option),
      let text = event.characters(
          byApplyingModifiers: event.modifierFlags.intersection(.shift)
      )?.lowercased(),
```

A Shift-only press on the Mac never reaches that path; it goes through
`interpretKeyEvents` as text. The phone's gate is `modifiers.isEmpty == false`,
which is strictly wider than the set the callee can encode correctly.

**Ideal fix.** Move the whole decision into `DanTermMobileKit` as one pure
function over the facts UIKit hands over -- `(keyCode-derived NamedKey?,
characters, charactersIgnoringModifiers, modifiers)` -> `MobileSessionEvent?`
-- and give it the Mac's rule: a named key always dispatches; a character
dispatches as a *chord* only when Control or Alt is held, using
`charactersIgnoringModifiers`; a Shift-only or unmodified press dispatches the
inserted text `characters` (or returns nil and lets the text-input system
insert it, whichever the probe shows UIKit actually does). Then the parameter
handed to `MobileInputMapper.hardwareCharacter` is narrowed to the modifier
sets it can encode, and the two UIKit lookup tables (`mobileNamedKey`,
`mobileModifiers`) move to the kit where a test can reach them.

**By construction.** `hardwareCharacter` stops accepting a Shift-only modifier
set, so "a character key event whose Shift is silently dropped by the encoder"
becomes unrepresentable. The `.lowercased()` call disappears with it, because
the only value that reaches the chord path is already lowercase by contract.

**Cheaper fallback.** Narrow the `else if` to
`modifiers.contains(.ctrl) || modifiers.contains(.alt)` in place, one line. It
fixes the wrong byte and the possible double insert, but it leaves the whole
hardware-key vocabulary in a target with no tests, so the next edit to it is
again unverifiable.

**Verification.** A test in `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/InputMappingTests.swift`
driving the new pure mapper: Shift+A yields the event that ends as the byte
`0x41`, Ctrl+A yields `.key(.character("a"), .ctrl)` (`0x01`), Shift+2 yields
`@`, and Shift alone yields nothing. Run `swift test --package-path
ios/DanTermMobileKit`. End to end, `just ios-app simulator` with a hardware
keyboard and `printf` in the pane shows `A` rather than `a` or `Aa`.

**Risk.** If UIKit does deliver hardware text through `insertText` for
unmodified presses, dispatching `characters` from `pressesBegan` too would
double every letter. The probe above settles which of the two arms is right
before the arm is written; the test must be written from the observed
delivery, not from the assumption.

**Vetted.** I opened `MobileRootViewController.swift:87-103` (`pressesBegan`,
the `else if modifiers.isEmpty == false` gate at `:95-99` and
`if handled == false { super.pressesBegan(...) }` at `:102`, both verbatim),
`:497-506` (`mobileModifiers`, which does insert `.shift`), `:508-528`
(`mobileNamedKey`, which has no letter or digit case, so a letter press always
falls to the character arm), `MobileInputMapper.swift:124-129`
(`hardwareCharacter`) and `:177-186` (`inputCharacter`, which returns
`.key(.character(c), modifiers)` for any non-empty modifier set), and
`TerminalInputEncoding.swift:349-352` -- the character case is verbatim as
quoted and consults only `.control`. Line 79 of that file states the intent
outright: "Selects shifted terminal forms without implying text case
conversion." So `.key(.character("a"), [.shift])` is `0x61` by design. The Mac
gate at `SwiftTerminalSessionView.swift:1902-1915` is verbatim as quoted. I
read the SDK header at
`/Applications/Xcode.app/.../iPhoneSimulator26.5.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIKey.h:19-29`:
both quoted sentences are there word for word, including "If only a modifier
key was pressed, this property will contain an empty string" -- which is why a
bare Shift press already dispatches nothing, as the finding's test expects.
The path is reachable: `TerminalInputView` is the first responder and overrides
none of the `presses*` methods, so `UIResponder`'s default forwarding carries
every hardware press up to this controller, which is also how the hardware
Escape, Tab and arrows reach the pane at all. The only kit tests that touch
these two events (`MobileSessionModelTests.swift:149-150`, `:689-690`, `:718-719`)
pass an empty or Ctrl modifier set, so the Shift-only arm is untested as well as
wrong.

**Correction.** Two small overstatements in the prose, neither of which changes
the finding. First, the SDK hedges -- "for Latin based languages, expect this to
be always in lowercase" is guidance, not a guarantee -- so `.lowercased()` is a
no-op in practice rather than by contract, and keeping it on the chord path
after the fix would be harmless. Second, the shift bit is not useless once the
gate is narrowed: `encodeLegacyKey` ignores it for a character, but the Kitty
arm at `TerminalInputEncoding.swift:433-438` folds it into the CSU modifier
parameter, so Ctrl+Shift+A must keep carrying `.shift`. The fix is to reject a
modifier set with no Ctrl and no Alt, not to strip `.shift`.

**Conflicts with.** None. No other lane file edits `pressesBegan`,
`MobileInputMapper#hardwareCharacter`, or `TerminalInputEncoding#encodeLegacyKey`
-- `INPUT`, `PARSE` and `SELECT` all touch only the mouse and mode halves of
`TerminalInputEncoding.swift`, and `IPC` reads `MobileInputMapper` without
editing it.

<a id="mobapp-2"></a>

#### MOBAPP-2. Offer the overflow menu from the item list itself, not from a second copy of its conditions

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift#render`, `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift#sessionMenuItems`

**Problem.** The session's action vocabulary is enumerated twice in one file.
`sessionMenuItems()` builds an item for each of three conditions;
`render` re-states the same three conditions as an `||` chain to decide whether
the button is enabled. Nothing ties them together, so a fourth action added to
the item list leaves a menu the user cannot open, and a condition edited on one
side leaves an enabled button that opens an empty menu.

**Evidence.** In `render`:

```swift
bottomBar.setMenuOffered(
    projection.canCreatePane
        || projection.claim.claim != nil
        || projection.claim.release != nil
)
```

and in `sessionMenuItems`, the same three tests, one per item:
`if projection.canCreatePane {`, `if claim.claim != nil {`,
`if claim.release != nil {`.

**Ideal fix.** Declare the vocabulary once as data in `DanTermMobileKit`: a
`MobileSessionMenu` value on the projection, holding an ordered list of typed
actions (`.newPane`, `.claim`, `.release`), each carrying the event it sends.
The shell draws the list and enables the button on `isEmpty == false`, and the
model's own tests cover which actions are offered in which lifecycle state --
which is where `canCreatePane` and `MobileClaimControl` already live.

**By construction.** "Menu offered" stops being a separate boolean, so an
offered-but-empty and an unoffered-but-populated menu both stop being
representable. The shell keeps no rule about session actions at all.

**Cheaper fallback.** `bottomBar.setMenuOffered(sessionMenuItems().isEmpty ==
false)` in `render`. One line, removes the disagreement, and costs building up
to three closures per redraw. It leaves the vocabulary itself in the untested
target.

**Verification.** With the ideal: a `MobileSessionModelTests` case asserting the
projected menu is empty while disconnected, holds exactly `.newPane` while
serving without a claim, and holds `.release` once a claim is confirmed. With
the fallback there is no test that can reach it, which is itself the argument
for the ideal.

**Risk.** Low. The button's enabled state is the only visible behavior, and its
height is fixed, so nothing in the terminal's geometry moves either way.

**Vetted.** I opened `MobileRootViewController.swift:165-188` (`sessionMenuItems`,
with `if projection.canCreatePane`, `if claim.claim != nil` and
`if claim.release != nil`, one per item) and `:279-284` (the `setMenuOffered`
call, verbatim as quoted). The duplication is exactly as described. I also read
`TerminalBottomBarView.swift:107-136`: `setMenuOffered` already guards on change
before writing `overflowButton.isEnabled`, and the menu itself is a
`UIDeferredMenuElement.uncached` that calls `menuItems?()` when it opens, so the
item list is genuinely built only on open today. That is what makes the cheaper
fallback a real cost -- it moves that build onto every redraw, which is every
keystroke -- and it is why the ideal fix is the one worth doing.

**Correction.** I lowered impact from 3 to 2. The two conditions agree exactly
today, so there is no live defect, and the worst failure the drift can produce
is a button that opens an empty menu -- visible on the first tap and harmless.
The auditor's own Dropped list rejects the `"serverHost"`/`"serverPort"`
duplication on the same "two statements in one file" grounds; what keeps this
one alive is that the menu vocabulary will grow while a pair of `UserDefaults`
keys will not. Also, "The shell keeps no rule about session actions at all" is
too strong: after the fix the shell still maps each action case to a title and
an SF Symbol name. The gain is that the mapping becomes an exhaustive `switch`
the compiler checks, so a fourth action fails the build instead of silently
missing from the menu.

**Conflicts with.** `MOBKIT-2`, which rewrites `MobileSessionModel#projection`
and the `MobileSessionProjection` initializer this finding adds a field to; and
`MOBAPP-3`, which adds a second field to the same two places. All three are
additive, so they can land in any order, but not in parallel branches. `MOBAPP-6`
also edits `MobileRootViewController#render`, a few lines away.

<a id="mobapp-3"></a>

#### MOBAPP-3. Ask the model whether the launch needs a target, instead of re-deriving it in the shell

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift#viewDidAppear`, `ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileLaunchPlan.swift#MobileLaunchPlan`

**Problem.** `MobileLaunchPlan` already decides, as a tested value, whether a
launch names a server: `connectsImmediately = host != nil`. The shell does not
read that decision -- the model never publishes it -- so `viewDidAppear`
recomputes it from the projected draft. Two statements of one rule, in two
targets, one of which has no tests. The controller's own comment claims the
opposite of what the code does: "whether a sheet is *wanted* is read from the
model each time".

**Evidence.** The shell:

```swift
let launched = session.projection
guard launched.draft.host == nil || launched.draftProblem != nil else { return }
presentConnectSheet()
```

The model, in `MobileLaunchPlan.init(inputs:)`:
`connectsImmediately = host != nil`, and `MobileSessionModel#handle` for
`.launched`: `guard plan.connectsImmediately else { return [.redraw] }`.
`MobileSessionProjection` (all nine fields quoted in
`MobileSessionModel.swift#MobileSessionProjection`) carries no such field, so
`draft.host == nil` is the shell's substitute for it.

**Ideal fix.** Put the fact on the projection -- `needsTarget`, true while the
session has no target it can attempt and is not attempting one -- and reduce
`viewDidAppear` to `guard session.projection.needsTarget else { return }`. The
model already holds `lifecycle` and `draftProblem`, so it can answer directly;
no new state is stored anywhere.

**By construction.** The shell stops holding any rule about what makes a launch
connectable, so the two cannot drift. It also makes the affordance reusable:
the same fact could later offer the sheet after a target is cleared, which the
current one-shot `hasAnsweredLaunch` cannot express.

**Cheaper fallback.** Leave it and fix the comment. That is honest but keeps
the duplicate rule, and the rule is exactly the kind the launch plan's own file
header says a shell "reads once and gets wrong silently".

**Verification.** `MobileSessionModelTests`: after `.launched` with an
environment host, `projection.needsTarget` is false; with no host anywhere it
is true; with a host and a port the model refuses it is true. Run
`swift test --package-path ios/DanTermMobileKit`.

**Risk.** Low, and confined to which launches raise the sheet. A wrong
`needsTarget` in the connecting state would stall the smoke run behind a form,
which the smoke script would catch on the first run.

**Vetted.** I opened `MobileRootViewController.swift:57-68` (`viewDidAppear`;
the two quoted lines are verbatim), `MobileLaunchPlan.swift:56-68`
(`connectsImmediately = host != nil`, verbatim), `MobileSessionModel.swift:187-192`
(the `.launched` arm with `guard plan.connectsImmediately else { return [.redraw] }`,
verbatim), and `MobileSessionProjection` at `MobileSessionModel.swift:17-31` --
nine fields, none of them a launch decision. The ordering also holds:
`viewDidLoad` calls `session.start()`, which dispatches `.launched` synchronously
through `drain()` (`MobileSessionController.swift:72-100`, `:152-171`), so by
`viewDidAppear` the draft is already the plan's draft.

**Correction.** I lowered impact from 3 to 2, and two claims in the prose need
softening. First, the shell's test is not a restatement of `connectsImmediately`
but a superset of its negation: `draft.host == nil` is exactly
`connectsImmediately == false`, and `draftProblem != nil` has no counterpart in
the launch plan at all -- it covers a host the model itself refused. So the fix
has to answer both, which is what the proposed `needsTarget` does, but "two
statements of one rule" understates the shell's condition. Second, the
controller's comment does not "claim the opposite of what the code does": the
code really does read the model in `viewDidAppear`, so what the comment gets
wrong is that the *decision*, not the inputs, is the shell's -- and that "each
time" is defeated by `hasAnsweredLaunch`, which runs the body once per process.
Finally, "the same fact could later offer the sheet after a target is cleared"
is speculative: `hasAnsweredLaunch` would still gate the second offer, so that
payoff needs its own change and should not be counted here. What survives is a
plain one-boolean duplication across a module boundary with a low-severity
failure mode -- a launch sheet shown or withheld -- which is a 2.

**Conflicts with.** `MOBKIT-2` (rewrites `MobileSessionModel#projection`, the
function this finding adds `needsTarget` to) and `MOBAPP-2` (adds its own field
to the same projection). Additive, so orderable, but not parallelizable.

<a id="mobapp-4"></a>

#### MOBAPP-4. Delete the unread `runnerThread` property

`simplification` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift#runnerThread`

**Problem.** The controller stores the stream reader's `Thread` and never reads
it. It is written in two places and read in none, so it reads as a handle the
teardown path uses when the teardown actually goes through `runner.cancel()`.
A reader has to check the whole file to learn the thread is not joined,
signalled, or inspected.

**Evidence.** `grep -rn "runnerThread" ios --include=*.swift` returns exactly
three lines: the declaration `private var runnerThread: Thread?`, `runnerThread
= nil` in `disconnect()`, and `runnerThread = thread` at the end of
`beginStream`. `disconnect()` ends the reader with `runner?.cancel()`; the
thread reference plays no part.

**Ideal fix.** Delete the property and both writes. `let thread = Thread {
runner.run() }; thread.name = ...; thread.start()` is complete on its own -- a
started `Thread` retains itself until its body returns.

**By construction.** n/a -- this deletes dead vocabulary rather than a state.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `swift build --package-path ios/DanTermMobileApp` (the
compiler proves nothing read it), plus one `just ios-app simulator` run that
connects, backgrounds, and returns, to show the reader still ends and restarts.

**Risk.** None beyond the build. Nothing observes the property.

**Vetted.** I read `MobileSessionController.swift` end to end. `runnerThread`
appears exactly three times and in the three places named:
`private var runnerThread: Thread?` (`:54`), `runnerThread = nil` in
`disconnect()` (`:265`), and `runnerThread = thread` at the end of `beginStream`
(`:296`). There is no read anywhere in the file, and no read anywhere else in
`ios/` -- the property is `private`, so the file is the whole search space.
`disconnect()` really does end the reader through `runner?.cancel()` (`:263`),
and `isolated deinit` does the same (`:113`); neither touches the thread. The
property is also not keeping the thread alive: `beginStream` starts it at `:295`,
and a started `Thread` retains itself until its body returns, so the local
binding is enough. Confirmed as written.

**Conflicts with.** `MOBKIT-6`, which edits the same `beginStream` and `send`
in this file to report the two dropped effects. The two edits are on different
lines of `beginStream` and are independent in substance, but they will collide
textually if written on separate branches.

<a id="mobapp-5"></a>

#### MOBAPP-5. Declare the scene delegate once

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; rescored

**Files.** `ios/DanTermMobileApp/Info.plist`, `ios/DanTermMobileApp/Sources/DanTermMobileApp/AppDelegate.swift#application(_:configurationForConnecting:options:)`

**Problem.** The one scene configuration is declared in two places that must
agree by hand: the `UIApplicationSceneManifest` names
`"Default Configuration"` with `UISceneDelegateClassName` of
`DanTermMobileApp.SceneDelegate`, and `AppDelegate` builds a configuration with
the same name and assigns the same `delegateClass`. Renaming the class or the
configuration in one of the two leaves the other silently wrong -- and the
plist's spelling is a string the compiler never checks.

**Evidence.** The plist holds
`<key>UISceneConfigurationName</key><string>Default Configuration</string>`
and `<key>UISceneDelegateClassName</key><string>DanTermMobileApp.SceneDelegate</string>`.
`AppDelegate` holds:

```swift
let configuration = UISceneConfiguration(
    name: "Default Configuration",
    sessionRole: connectingSceneSession.role
)
configuration.delegateClass = SceneDelegate.self
```

**Ideal fix.** Keep the code, delete the plist's `UISceneDelegateClassName`
(and, if nothing else needs the entry, the manifest's configuration array),
because the code names the class as a symbol the compiler checks. Deleting the
`AppDelegate` method instead also removes the duplication but leaves the only
statement of the delegate class in an unchecked string.

**By construction.** After the fix there is exactly one place that names the
scene delegate, so the plist and the code cannot disagree.

**Cheaper fallback.** none -- the ideal fix is a deletion.

**Verification.** `just ios-app simulator` launches and shows the terminal
screen; a scene that failed to find its delegate would come up as a blank
window, which is unmissable.

**Risk.** If UIKit needs the manifest entry for something else (the app does
declare `UIApplicationSupportsMultipleScenes`), removing too much of the array
breaks launch. Remove only the delegate-class key first and relaunch.

**Vetted.** I opened `ios/DanTermMobileApp/Info.plist:33-49` -- the manifest
holds `UISceneConfigurationName` = `Default Configuration` and
`UISceneDelegateClassName` = `DanTermMobileApp.SceneDelegate`, both verbatim --
and `AppDelegate.swift:7-18`, where the quoted four lines are verbatim. I also
read `main.swift`, which passes `NSStringFromClass(AppDelegate.self)` to
`UIApplicationMain`, so the app delegate is named in code and this method is
always the one UIKit asks, and `scripts/ios-app.sh:157-158`, which rewrites only
`CFBundleSupportedPlatforms` and `DTPlatformName` and never touches the manifest.
The duplication is real.

**Correction.** I lowered impact from 2 to 1, because the failure mode the
problem statement describes does not exist. `configuration.delegateClass =
SceneDelegate.self` is assigned after the configuration is constructed, and the
configuration the app delegate returns is the one UIKit uses, so the code always
wins and the plist string is inert. Renaming `SceneDelegate` therefore leaves a
stale plist string that changes nothing -- the compiler-checked symbol still
decides. What is left is a reader hazard: two places name the delegate and only
one of them is load-bearing, and nothing in the tree says which. That is worth a
one-key deletion and no more, and against it stands a small nonzero launch risk
in editing a manifest the app cannot start without. The finding is tidiness, not
a hazard, and should be argued that way.

**Conflicts with.** None. No other lane file names `Info.plist` or
`AppDelegate.swift`.

<a id="mobapp-6"></a>

#### MOBAPP-6. Write the status pill only when the status changes

`cost` &middot; impact 1, confidence 2 &middot; effort small &middot; rescored

**Files.** `ios/DanTermMobileApp/Sources/DanTermMobileApp/ConnectionStatusPillView.swift#show`, `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileRootViewController.swift#render`

**Problem.** Every keystroke produces a `.redraw`, and every redraw writes the
pill's label text and color unconditionally. `UILabel.text` does not compare
before invalidating, so a keystroke that changes nothing about the connection
still dirties the pill's intrinsic size and schedules a layout pass over the
whole root view -- including `TerminalSurfaceView.layoutSubviews`. Every
neighbouring write in this file is guarded for exactly this reason, each with a
comment saying so (`statusPill.isHidden`, `paneRow.show`, `setMenuOffered`,
`setLatchedModifiers`, `setArrowPadShown`, `setKeyboardShown`); the pill is the
one that is not.

**Evidence.** `MobileSessionModel.swift#handleKeyShapedInput` ends
`return effects + [.redraw]`, so text entry redraws. `render` then runs
`statusPill.show(status: projection.status.text, color: color)` with no guard,
against `ConnectionStatusPillView#show`:

```swift
func show(status: String, color: UIColor) {
    statusLabel.text = status
    statusLabel.textColor = color
}
```

The sibling two lines below it carry the rule this one is missing: "Written
only on a change, because `isHidden` dirties its superview's layout even when
it is given the value it already holds."

**Ideal fix.** Guard both writes inside `show` on inequality with what the
label already holds. The view still states the whole pill on every call -- the
guard is an equality test against the authority (the label), not a remembered
mirror.

**By construction.** n/a -- this removes redundant work, not a representable
state.

**Cheaper fallback.** none -- the ideal fix is three lines.

**Verification.** Cost, so an experiment rather than a result: run
`just ios-app simulator --slot <n>`, attach Instruments' Core Animation /
Time Profiler, and hold a key down in a quiet pane for 10 seconds. The number
that must move is the count of `-[UIView layoutSubviews]` calls on the root
view per second of typing; it should fall to the passes the keyboard and the
surface actually need. If it does not move, the pill was not the source and
this finding is wrong.

**Risk.** A stale pill if the guard compares the wrong thing -- for instance
comparing only the text while the severity color changed. Guard both fields
independently, and the existing colour test (a `connecting` pill turning grey
to red on failure) covers it by eye.

**Vetted.** I opened `ConnectionStatusPillView.swift:36-39` -- `show` is
verbatim as quoted, two unguarded writes -- and `MobileRootViewController.swift:253-290`,
where `statusPill.show(...)` at `:258` is unguarded while the six neighbours
named in the prose are all guarded, each with the comment the prose quotes. I
also confirmed `MobileSessionModel.swift:694` ends `return effects + [.redraw]`,
so text entry does redraw. The evidence is all there; what does not hold up is
the cost.

**Correction.** The finding's own experiment names the state that disproves it.
`MobileStatus.swift:100` sets `isResting = connection.standing == .serving &&
parts.count == 1`, and `render` at `:263-264` hides the pill whenever the status
rests -- so "hold a key down in a quiet pane" is exactly the state in which the
pill is off screen. A hidden `UILabel` is not drawn, and re-solving its
constraints to the identical intrinsic size changes no frame, so no frame change
propagates and `TerminalSurfaceView.layoutSubviews` is not reached. The claim
that this "schedules a layout pass over the whole root view" is asserted, not
shown, and I could not show it either: unlike `isHidden` and `UIButton.isEnabled`,
whose layout effects the neighbouring comments state, `UILabel.setText` with an
equal string has no documented invalidation behavior I can confirm from the SDK,
and I did not run the experiment. Confidence drops to 2 on that ground and
impact to 1. What survives is not a cost argument at all but a consistency one:
this is the only view write in `render` that does not state its own guard, and
three lines would make the file uniform. Judge it as a `simplification` worth
doing when the file is next open, not as a redraw cost.

**Conflicts with.** `MOBAPP-2`, which edits `MobileRootViewController#render`
five lines below the `statusPill.show` call. Both are small and independent in
substance.

#### Dropped (MOBAPP)

- `TerminalSurfaceView#measuredContentBox`'s `window?.screen.scale ?? traitCollection.displayScale`. Looks like a `?? default` worth deleting, but `traitCollection.displayScale` is 0 before the view is in a window and the box would then be refused; `UIWindow.screen` is not deprecated in the iOS 26.5 SDK, and the view re-lays out on `didMoveToWindow`. The pair is deliberate.
- `TerminalSurfaceView#displayLinkTarget` looks like a second dead handle beside MOBAPP-4, but `CADisplayLink` retaining its target is the very cycle `DisplayLinkTarget` exists to break; keeping the strong reference here is what lets the link's target stay weak-owning. Not dead.
- `MobileArrowPadState` never pruning its per-pane entries. The file states the reason (a `PaneId` is a never-reused UUID, only the selected pane's entry is read, an entry is two doubles and a flag), and pruning would add a rule about rosters and reconnects that nothing observable depends on. Agreed as written.
- `TerminalAccessoryAppearance` giving the four arrows a face that `MobileAccessoryKey.barRow` never draws. It reads as dead vocabulary but is deliberate: the `switch` has no `default`, so the arrows' absence from the row is a statement the list makes rather than a gap.
- `MobileRootViewController#pressesBegan` not overriding `pressesEnded`/`pressesCancelled`, which `UIResponder.h` warns about. It overrides none of the three, so `UIResponder`'s own forwarding applies uniformly; the warning is about overriding some but not all.
- The `"serverHost"`/`"serverPort"` `UserDefaults` keys being spelled once in `start()` and again in `perform(.storeTarget)`. Real duplication, but two adjacent literals in one file, and the launch inputs are already a tested value -- too small to spend a finding on.
- `Info.plist` declaring `CFBundleSupportedPlatforms` as `iPhoneSimulator` while `just ios-app device` exists: `scripts/ios-app.sh` rewrites both keys with `plutil` for the device path. Correct as it stands, and the build scripts are not this lane.
- `TerminalSurfaceView`'s `required init?(coder:)` lacking the `@available(*, unavailable)` every other view in the directory carries. Cosmetic inconsistency only; both forms trap.
- `PaneSheetViewController#pane(with:)` and `#tab(with:)` scanning the whole outline per configured cell. It is O(panes) per row on a phone-sized roster behind a `lazy` chain, and the sheet is transient; no plausible workload makes it matter.
- Everything the closed `2026-08-18` audit owns on this surface -- `MOBILE-1` (cell metrics off the record path), `MOBILE-2` (damage-fed frame stores), `MOBILE-4` (change-gated replica signals) -- is landed in `TerminalSurfaceView` as the guards quoted above, and `MOBILE-5`/`MOBILE-6` were explicitly skipped. Nothing from that file is still live here.


### Area: The danterm CLI, its client library, and the build scripts (`CLI`)

_Scope: `cli/` (main.swift, Doctor.swift, PaneTapeStream.swift, SkillCommand.swift), `lib/DanTermClient/Sources/DanTermClient/`, the CLI surface declarations in `lib/DanTermProtocol/Sources/DanTermProtocol/` (CLICommandCatalog, CLIParser, CLITarget, CLISkillSynopsisRegion, ReadPaneArgs, PaneTapeStream), `integrations/danterm/SKILL.md`, `justfile`, and the scripts an agent actually runs: `scripts/dev-slot-launcher.py`, `scripts/run-test-suite.sh`, `scripts/tests/danterm-cli_test.sh`._

**The auditor's read on the area.** The command surface is in genuinely good shape: one declarative catalog owns every leaf command, `routeCLI` dispatches from it, `danterm help` and the SKILL.md synopsis are both projections of it, and `DanTermSkillSynopsisGenerator --check` runs in the gate so the synopsis cannot rot. The target grammar is one shared step (`parseCLITarget`), so every subcommand words a misplaced `--pane` the same way. The slot launcher is careful in the places that matter -- occupancy is the kernel's flock, never a record, and `terminate_session` refuses any pid that does not lead its own group. The remaining defects share one shape: **a rule that is stated in two places, and only one of them is the one that runs.** The catalog states a target policy that nothing enforces; the doctor row states its identity in a title that also states its result; SKILL.md states protocol constants as prose next to a generated region that could have carried them; the grid bound is prose in the help string and a range in another module. Two are ordinary correctness bugs in the transport and in `todo edit`. I did not audit the benchmark and terminal-probe scripts (a different lane owns terminal performance), the bundle-assembly scripts beyond reading their SKILL.md contract, or the app-side IPC dispatch except where I had to read it to decide whether a CLI-side claim was true.

<a id="cli-1"></a>

#### CLI-1. Give the TCP connect the whole caller-supplied deadline instead of capping each address at one second

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/DanTermClient/Sources/DanTermClient/TCPSocketTransport.swift#TCPSocketTransport.init`, `cli/main.swift#selectSocketTimeout`, `integrations/danterm/SKILL.md`

**Problem.** The CLI resolves one duration -- `DANTERM_SOCKET_TIMEOUT`, default 5 seconds -- and hands it to `TCPSocketTransport` as `connectTimeout`. The connect loop then computes `remaining` from that deadline and immediately throws it away: it passes `min(remaining, 1)` to the per-address connect. A tailnet target is documented as an explicit IPv4 literal, and `resolutionFlags(for:)` sets `AI_NUMERICHOST` for exactly that case, so `getaddrinfo` returns one address. One address plus a one-second cap means the whole connect budget is one second, whatever the caller asked for. After that single candidate the loop runs out of `ai_next` and throws `connectTimedOut` without ever spending the remaining 4 (or 30) seconds. The number a caller sets to reach a slow or distant tailnet peer has no effect on the phase where slowness actually shows up.

**Evidence.** `TCPSocketTransport.init`:

```swift
let deadline = ProcessInfo.processInfo.systemUptime + connectTimeout
...
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else {
        throw TCPSocketTransportError.connectTimedOut(target: target)
    }
    ...
            try Self.connect(
                fd,
                address: current.pointee.ai_addr,
                length: current.pointee.ai_addrlen,
                timeout: min(remaining, 1),
                target: target
            )
```

The `1` carries no name and no comment. `Self.connect` turns it into the poll deadline: `let milliseconds = Int32(min(max(timeout * 1_000, 1), Double(Int32.max)))`. `git log -L` on that region shows it arrived whole in `6a8cbc3e feat(cli): connect directly to tailnet listeners` with no stated rationale. SKILL.md documents the opposite contract: "`DANTERM_SOCKET_TIMEOUT` -- seconds the CLI waits on the control socket, default 5. Set it ... above it when a busy instance is answering slowly."

**Ideal fix.** Delete the constant. The per-address wait is `remaining`, computed from the one deadline the caller supplied, and the loop's existing `guard remaining > 0` is what ends it. With several addresses the deadline is still shared, which is what "connect within the caller's budget" means; with one address the caller gets the budget they asked for. If a fast-fail across a multi-address host is wanted, it belongs as a declared parameter of the transport, not as an unnamed literal inside the loop.

**By construction.** A connect that ends before the caller's deadline while addresses and time both remain stops being representable: there is one clock, and one place that reads it.

**Cheaper fallback.** Name the constant and document it (`perAddressConnectBudget`). That leaves the defect exactly where it is -- it only makes it easier to find.

**Verification.** In `lib/DanTermClient` tests: bind a listening socket with a backlog of zero (or point at a black-holed address), construct `TCPSocketTransport(host:port:connectTimeout: 3, ...)`, and assert the elapsed time before `connectTimedOut` is at least ~3 seconds rather than ~1. Behaviorally: `DANTERM_SOCKET_TIMEOUT=20 danterm --tcp <unreachable-tailnet-ip>:24863 ls` must take about 20 seconds to fail, not one.

**Risk.** A multi-address hostname whose first address black-holes now consumes the whole budget before trying the second, where today it moves on after a second. That is the correct reading of "the caller's deadline", but it changes failure latency for a hostname target; a tailnet IPv4 literal (the documented form) is unaffected because it resolves to one address.

**Vetted.** I opened `TCPSocketTransport.swift:62-92` and its private `connect` helper, `cli/main.swift:180-206` (`openSession`) and `:413-422` (`selectSocketTimeout`), `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSession.swift:46-52`, and `SKILL.md:172-179`. Every quote is exact, including `let milliseconds = Int32(min(max(timeout * 1_000, 1), Double(Int32.max)))`. `git log -L 62,90` on that file confirms `min(remaining, 1)` arrived whole in `6a8cbc3e` with no rationale anywhere in the diff. With `AI_NUMERICHOST` set for a literal, `getaddrinfo` returns one address, the loop runs once, and `candidateTimedOut` sends it straight to `connectTimedOut`, so the one-second cap really is the whole budget. The finding cites no `references/` emulator, so there is no reference behavior to re-check. Rescored impact 4 -> 3: the failure is a clean early error rather than corruption, and no incident in the tree records it.

**Correction.** The CLI is the smaller of the two victims. `danterm --tcp` is a one-shot a person retries, but `MobileSession.start` hardcodes `connectTimeout: 5` and gets the same one second, and the mobile reconnect episode re-attempts under the same cap. A phone on a link whose TCP handshake needs more than a second therefore never connects, however many times it retries. That case belongs at the front of the fix, ahead of `DANTERM_SOCKET_TIMEOUT` honouring its documented meaning.

**Conflicts with.** None. `MOBKIT`'s `MobileConnectionFailure.transport` finding reads the same error values but does not touch the connect loop, and no other lane opens `TCPSocketTransport.init`.

<a id="cli-2"></a>

#### CLI-2. Make a partial write end the stream instead of throwing a recoverable-looking timeout

`correctness` &middot; impact 2, confidence 4 &middot; effort small &middot; rewritten

**Files.** `lib/DanTermClient/Sources/DanTermClient/TCPSocketTransport.swift#send`, `lib/DanTermClient/Sources/DanTermClient/UnixSocketTransport.swift#send`, `lib/DanTermClient/Sources/DanTermClient/ClientTransport.swift#DanTermClientTransport`

**Problem.** Both transports write in a loop under `SO_SNDTIMEO`. When the timeout fires part way through a request line they throw `.timedOut` and return, leaving the bytes already written on the wire and the session open. The protocol is newline-framed, so the peer now holds half a line; the next request this session sends is appended to it and the server frames one corrupt line out of two requests. The session does not cancel itself on a send failure -- `DanTermClientSession.send` just rethrows -- so a long-lived client (the iOS remote client, and the liveness watchdog's own ping path) can keep using a stream that can no longer carry a correlated request. The seam's own documentation says this must not happen: "Writes every byte, or throws. A partial write is the transport's problem to retry."

**Evidence.** `TCPSocketTransport.send` (`UnixSocketTransport.send` is the same code with its own error type):

```swift
var offset = 0
while offset < buffer.count {
    let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
    if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            throw TCPSocketTransportError.timedOut
        }
```

`offset > 0` at that point is a partial line, and nothing distinguishes it from `offset == 0`. `DanTermClientSession.send` rethrows without tearing down:

```swift
do {
    try transport.send(encodeIpcLine(request))
} catch {
    if cancellationRequested { throw endOfSessionError }
    throw error
}
```

The one-shot CLI survives this by accident -- it exits on the first error -- so only the long-lived clients pay.

**Ideal fix.** Give the transport a poisoned state reached by any write that stops after emitting a byte: close the descriptor through `SocketDescriptorLifetime.close()` and throw. A half-written frame then cannot be followed by anything, and the failure a caller sees is "the stream is gone", which is true. The transport already owns a lifetime object that makes every later operation throw `cancelled`, so this is one call, not new machinery.

**By construction.** "A stream that is open but framing-desynchronized" stops being a state the session can hold. The seam's promise ("writes every byte, or throws") becomes true rather than aspirational.

**Cheaper fallback.** Retry the remainder in the transport until the whole buffer is out, ignoring the timeout for a partial write. That preserves the stream but makes `sendTimeout` unbounded exactly when the peer is wedged, which is the case the bound exists for.

**Verification.** In `lib/DanTermClient` tests: a fake transport that accepts N bytes and then throws `.timedOut` mid-line; assert the session's next `send` throws `cancelled` (stream gone) rather than writing a second line onto the truncated one. Behaviorally, over a socketpair with a tiny `SO_SNDBUF` and a peer that never reads: write an oversized request, catch the failure, then assert a second request fails instead of reaching the peer.

**Risk.** A caller that today survives a mid-write timeout by retrying the same request now sees the connection closed. No caller in this tree does that; both the CLI and the watchdog treat a send failure as terminal already.

**Vetted.** I opened both `send` implementations (`TCPSocketTransport.swift:124-146`, `UnixSocketTransport.swift:65-88`), the quoted seam promise at `ClientTransport.swift:45`, and `DanTermClientSession.swift:164-174`. Every quote is exact, and the seam really does promise a retry neither transport performs. Then I followed every caller. `PeerLivenessMonitor.run` reads a false from `sendLivenessPing` as death and calls `peerDeclaredSilent` (`PeerLivenessMonitor.swift:141-146`), which records `deathReason` and calls `cancel()` (`DanTermClientSession.swift:346-366`). `MobileSessionController.beginStream` calls `session.cancel()` on a send failure; `MobileSessionController.send` dispatches `.connectionEnded`, which `MobileSessionModel.end` turns into `[.disconnect]` (`MobileSessionModel.swift:287-289`, `:521-528`). The CLI is one-shot. No caller in this tree writes a second line onto a truncated one. The finding cites no `references/` emulator.

**Correction.** The reachable defect is narrower than the prose says. "A long-lived client ... can keep using a stream that can no longer carry a correlated request" is not true of this tree: the watchdog and the iOS controller both tear the session down on a send failure, and the framing corruption the finding is scored on cannot happen today. What is true is that the transport breaks its own written contract and pushes the decision to close onto every caller separately -- a trap for the next caller, and work every current caller repeats by hand. Impact 4 -> 2 on that basis; confidence stays 4 because the code is exactly as quoted but the harm it was scored on is unreachable. The ideal fix is still right and still one call.

**Conflicts with.** `CLI-10`, loosely: both edit the two transports, and a stored read buffer added by `CLI-10` has to be released on the close path this finding adds. Either order works. `MOBKIT`'s `MobileConnectionFailure.transport` finding classifies a transport failure differently in the iOS model but does not change what the transport does.

<a id="cli-3"></a>

#### CLI-3. Refuse blank todo text at the request boundary instead of silently succeeding

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#parseTodoEditCommand`, `lib/DanTermCore/Sources/DanTermCore/Update.swift` (`.editTodoText`), `lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift` (`.todoEdit`)

**Problem.** `danterm todo edit --pane <id> <todo-id> "   "` exits 0, prints nothing, and changes nothing. The CLI parser checks the argument count but never the text; the reducer's `.editTodoText` guards `!trimmed.isEmpty` and returns `[]`; dispatch then replies with the *unchanged* todo and the CLI's `.none` output mode discards it. A caller has no way to tell an applied edit from a discarded one. The sibling verb disagrees: `todo add` refuses the same input with `IpcParamsError("invalid todo text")`, so the two spellings of one rule produce opposite outcomes.

**Evidence.** `parseTodoEditCommand` checks only arity:

```swift
guard rest.count >= 2, let todoId = UUID(uuidString: rest[0]) else {
    throw CLIParseError(usage)
}
let text = rest.dropFirst().joined(separator: " ")
```

`Update.swift#editTodoText` drops it on the floor:

```swift
case .editTodoText(let owner, let todoId, let text):
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          let todos = model.todos(for: owner),
          let idx = todos.firstIndex(where: { $0.id == todoId }) else { return [] }
```

and `IpcDispatch.swift` replies success regardless:

```swift
let commands = update(&model, .editTodoText(owner: owner, todoId: todoId, text: text), env: env)
let updated = model.todos(for: owner)?.first(where: { $0.id == todoId })
return commands + [.ipcReply(reqId: reqId, result: todoResult(updated))]
```

Compare `todoAdd` two cases above, which throws `IpcParamsError("invalid todo text")`.

**Ideal fix.** Make the text a validated value. A `TodoText` that only initializes from a non-blank string, trimmed at construction, carried by `IpcRequest.todoAdd` and `.todoEdit` alike. The CLI fails at parse with the command's usage line, the wire decoder fails with one message, and `editTodoText`'s `!trimmed.isEmpty` guard is deleted because a blank one cannot arrive.

**By construction.** "A todo request carrying text the model will refuse" stops existing, and with it the reducer arm that silently succeeds.

**Cheaper fallback.** Add `guard text.trimmed.isEmpty == false` to `parseTodoEditCommand`. That fixes the CLI path and leaves the wire path (the iOS client, any future caller) able to send blank text and be told it worked.

**Verification.** `DanTermProtocolTests`: `parseCLI(["todo","edit","--pane",id,todoId,"   "])` throws `CLIParseError`. `DanTermCoreTests`: dispatching a `todoEdit` with blank text returns an error reply, not a success reply naming the unchanged todo. Behaviorally: `danterm todo edit --pane P <id> "  "` exits non-zero and the todo's text is unchanged.

**Risk.** A caller that relied on a blank edit being a no-op now gets an error. Nothing in the tree or in SKILL.md documents that behavior.

**Vetted.** I opened `CLIParser.swift:713-723`, `Update.swift:1251-1257`, `IpcDispatch.swift:484-502`, and `ModelOperations.swift:743-749` -- `appendTodo` returning nil on blank text is what makes `todoAdd` throw `IpcParamsError("invalid todo text")`, so the asymmetry the finding names is real. Every quote is exact. `parseTodoEditCommand` checks arity only, `.editTodoText` returns `[]` on blank, and the `.todoEdit` arm replies `todoResult(updated)` regardless; the route's `outputMode` is `.none`, so the reply is discarded and the process exits 0. No `references/` citation to re-check. Rescored impact 3 -> 2.

**Correction.** "A caller has no way to tell an applied edit from a discarded one" is a complaint about the whole verb, not about blank text: `todo edit` prints nothing on a successful edit either, because its output mode is `.none`. The defect that blank text uniquely causes is the silent success itself, and that is an edge input. The ideal fix stands.

**Conflicts with.** `IPC-5` (`IPC.md`), which names this finding from its own side: consolidating `todoResult` onto `IpcEntityEncoder.todo` rewrites the same `.todoEdit` dispatch arm. `IPC.md` asks for `CLI-3` to land first and I agree with that order. `IPC-6` edits `CLIParser.swift#parsePaneInputCommand`, a different function in the same file, and does not conflict.

<a id="cli-4"></a>

#### CLI-4. Let `doctor` name the instance it queries, or stop calling `localOnly` a local command

`structural` &middot; impact 2, confidence 5 &middot; effort medium &middot; rescored

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/CLICommandCatalog.swift#CLICommandTargetPolicy`, `cli/main.swift#runDoctor`, `cli/main.swift#gatherDoctorPermissions`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#routeCLIInvocation`

**Problem.** `doctor` is declared `.localOnly`, whose stated meaning is "Runs in this process and rejects `--socket` and `--tcp`". It does reject them -- and then it opens a control-socket connection anyway, to whatever instance ambient resolution picks. So an agent driving slot 3 (`danterm --socket $SLOT_SOCKET ...` for every other verb) cannot ask slot 3 for its permission rows; `danterm --socket $SLOT_SOCKET doctor` is refused outright, and a bare `danterm doctor` silently answers for the production instance or for whatever `DANTERM_SOCK` names. The report never says which instance answered, so three of its rows describe an app the caller did not choose and cannot identify.

**Evidence.** The policy's own doc comment:

```swift
/// Runs in this process and rejects --socket and --tcp.
case localOnly
```

enforced in `routeCLIInvocation`:

```swift
if target != nil, routed.descriptor.targetPolicy == .localOnly {
    throw CLIParseError("\(routed.descriptor.path.joined(separator: " ")) does not accept --socket or --tcp")
}
```

while `runDoctor` reaches the network through the ordinary request path:

```swift
guard let target = try? selectConnectionTarget(
    explicit: nil,
    environment: environment,
    fallback: userControlSocketPath(identity: .production).path,
    method: .doctorPermissions
) else { return .unavailable }
```

SKILL.md repeats the fiction and its consequence in one breath: "The local `skill` and `doctor` commands do not accept a target flag ... `doctor` queries the matching running app for macOS permission state."

**Ideal fix.** Split the two facts the policy currently conflates. `skill` needs no instance at all: keep it refusing target flags. `doctor` is a local report *plus* an optional instance query, so give it the same `implicitAllowed` policy every other querying command has, pass the resolved target into `gatherDoctorPermissions`, and print the instance the app-owned rows came from (socket path or TCP endpoint) as part of those rows. Then `localOnly` means what it says -- no socket is opened -- and `skill` is its only member.

**By construction.** "A command that refuses to be told which instance to talk to, and then talks to one" stops being expressible, and a permission row can no longer be about an unnamed app.

**Cheaper fallback.** Leave the policy alone and print the resolved socket path in the three app-owned rows. That removes the silent misattribution but keeps the agent unable to ask a slot about itself.

**Verification.** `cli-tests`: `parseCLIInvocation(["--socket","/tmp/x.sock","doctor"])` returns a routed invocation with that target rather than throwing. `DoctorEvaluatorTests`: a permissions fact gathered from an explicit target renders rows naming it. Behaviorally: `danterm --socket "$SLOT_SOCKET" doctor` reports slot N's notification state while a bare `danterm doctor` in the same shell reports the ambient instance's.

**Risk.** `doctor` gains a way to fail differently (a bad `--socket`), so its "works with no app running" property must be preserved: an explicit target that cannot be reached still has to SKIP the three app-owned rows rather than fail the command.

**Vetted.** I opened `CLICommandCatalog.swift:10-18` and `:310-320`, `CLIParser.swift:141-144`, `cli/main.swift:304-331` (`runDoctor` and `gatherDoctorPermissions`) and `:424-451` (`selectConnectionTarget`), `cli/Doctor.swift#renderDoctorReport`, and `SKILL.md:36-38`. Every quote is exact. `doctor` is declared `.localOnly`, the parser refuses `--socket`/`--tcp` for it, and `gatherDoctorPermissions` then resolves an ambient target and opens a control socket. The renderer prints status prefix, title, and message only -- no instance identity anywhere in the report -- so the three app-owned rows really can describe an app the caller did not name.

**Correction.** "An agent driving slot 3 cannot ask slot 3 for its permission rows" overstates it. `gatherDoctorPermissions` passes `explicit: nil` into `selectConnectionTarget`, which reads `DANTERM_SOCK` before the identity-derived fallback, so `env DANTERM_SOCK=$SLOT_SOCKET danterm doctor` reaches the slot today. What is genuinely missing is the flag and the row that names the answering instance. The common case is also benign: a person running `danterm doctor` inside a DanTerm pane inherits that pane's `DANTERM_SOCK` and gets the right app. Impact 3 -> 2.

**Conflicts with.** `CLI-5`. Both rewrite what `targetPolicy` means and who enforces it -- `CLI-5` would compute `doctor`'s policy from its request method rather than from a hand-written `.localOnly`, which is the very classification `CLI-4` wants to change. Do both in one change, or land `CLI-4` first. `CLI-6` edits the same `evaluatePermission` rows this finding wants to carry an instance name; compatible, but the same lines.

<a id="cli-5"></a>

#### CLI-5. Enforce the catalog's target policy, or derive it from the method traits that already decide it

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/CLICommandCatalog.swift#CLICommandTargetPolicy`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#routeCLIInvocation`, `cli/main.swift#selectConnectionTarget`, `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#terminatesInstance`

**Problem.** "quit must name its instance explicitly" is written down twice. The catalog says `targetPolicy: .explicitRequired` on the `quit` entry. Nothing reads that case: `routeCLIInvocation` branches only on `.localOnly`, and the rule that actually runs lives in `cli/main.swift#selectConnectionTarget`, keyed off `IpcRequestMethod.terminatesInstance`. A second command that must be explicitly targeted could be declared `.explicitRequired` in the catalog, pass every catalog test, and still resolve a target from `DANTERM_SOCK`. The declaration reads as enforcement and is not.

**Evidence.** Every use of the case, from a tree-wide grep, is a declaration or a test of the declaration:

```
CLICommandCatalog.swift:15:    case explicitRequired
CLICommandCatalog.swift:304:            targetPolicy: .explicitRequired,
CLICommandCatalogTests.swift:80:        #expect(CLICommandCatalog.entry(for: ["quit"])?.targetPolicy == .explicitRequired)
```

The parser reads only the other case (`CLIParser.swift:142`), and the live rule is elsewhere:

```swift
if method.terminatesInstance {
    guard let explicit else {
        throw CLIError("\(method.rawValue) requires an explicit --socket <path> or --tcp <host:port>")
    }
    return explicit
}
```

`IpcRequestMethod.terminatesInstance`'s own comment claims both rules for itself: "such a method resolves its target only from an explicit `--socket`, and reads a closed connection as success".

**Ideal fix.** One authority. Make `CLICommandDescriptor.targetPolicy` a computed projection of the route's request method -- `.explicitRequired` exactly when `terminatesInstance`, `.localOnly` for the routes that send no request -- and enforce all three cases in `routeCLIInvocation`, where the descriptor and the parsed target are both in hand. `selectConnectionTarget` then only resolves; it stops re-deciding. The closed-connection-is-success rule stays with `terminatesInstance`, which is where it belongs.

**By construction.** A catalog entry whose declared policy differs from the policy applied to it stops being representable, because there is one value and one reader.

**Cheaper fallback.** Add the missing `.explicitRequired` branch beside the `.localOnly` one in `routeCLIInvocation` and delete the check in `selectConnectionTarget`. This removes the unenforced case but leaves two hand-maintained declarations that must agree.

**Verification.** `DanTermProtocolTests`: for every catalog entry, `targetPolicy == .explicitRequired` implies `parseCLIInvocation([<path>...])` with no target flag throws. Behaviorally: `danterm quit` with `DANTERM_SOCK` set still refuses, and the refusal now comes from the parser with the command's own spelling.

**Risk.** The refusal message changes wording (it would name the CLI spelling `quit` rather than the wire method, which happen to be the same string today). `cli-tests` assert the current sentence and would need updating.

**Vetted.** I grepped the whole tree for the three policy cases. `.explicitRequired` occurs exactly three times: the declaration (`CLICommandCatalog.swift:15`), the `quit` entry (`:304`), and `CLICommandCatalogTests.swift:80`. `CLIParser.swift:142` branches on `.localOnly` alone. The live rule is `cli/main.swift:436-441`, keyed on `IpcRequestMethod.terminatesInstance`, whose doc comment at `IpcRequest.swift:104-112` claims both rules for itself, exactly as quoted. Every quote is exact.

**Correction.** Nothing is wrong today. `quit` is the only `.explicitRequired` catalog entry and the only method whose `terminatesInstance` trait is true, so the two declarations agree and `danterm quit` is refused as documented even with `DANTERM_SOCK` set. The defect is entirely latent: a second command declared `.explicitRequired` would be unenforced. Impact 3 -> 2 on that basis; the fix stays cheap and stays right.

**Conflicts with.** `CLI-4`, which reclassifies `doctor` out of `.localOnly` -- the same enum, the same entries, and the same enforcement site in `routeCLIInvocation`. Whichever lands second must be written against the other's shape.

<a id="cli-6"></a>

#### CLI-6. Print the doctor row's identity, and keep the observed state out of its title

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `cli/Doctor.swift#DoctorCheckID`, `cli/Doctor.swift#evaluatePermission`, `cli/Doctor.swift#renderDoctorReport`

**Problem.** Every doctor row already has a stable identity -- `DoctorCheckID`, whose comment says it exists "so tests and renderers can find rows without depending on display order or title text" -- and the renderer prints none of it. What it prints is the title, and for the three permission rows the title *is* the result: `evaluatePermission` takes a `title` and a `deniedTitle` and picks between them. So the line a script would grep for ("Notifications enabled") is exactly the line that disappears when the answer is no. The one fact a caller wants -- which check, and what it said -- is spread across a status word and a title that encodes half the status. A caller who wants doctor's answer for one specific check cannot get it without matching on prose that varies with the answer.

**Evidence.** The id is declared for exactly this purpose and never rendered:

```swift
/// Stable identifiers for doctor checks so tests and renderers can find rows
/// without depending on display order or title text.
enum DoctorCheckID: Equatable { ... }
```

```swift
private static func evaluatePermission(
    id: DoctorCheckID,
    title: String,
    deniedTitle: String,
    ...
    case .denied:
        return DoctorCheck(id: id, title: deniedTitle, status: .warn, message: deniedMessage)
```

```swift
let body = checks.map { check -> String in
    let prefix = statusPrefix(check.status)
    ...
    return "\(prefix) \(check.title): \(message)"
}
```

SKILL.md documents the coupling as if it were a feature: "They name the observed state: `enabled` or `disabled` for notifications".

**Ideal fix.** One title per row id, chosen for the subject and not the answer ("Notifications", "Full Disk Access", "Developer Tools"), with the outcome carried by the status word and the message that already exists. Then add a machine-readable projection: `danterm doctor --json` emitting `[{id, status, title, message}]` from the same `[DoctorCheck]` the text renderer consumes, so nothing is derived twice. The `deniedTitle` parameter disappears.

**By construction.** "A row whose title contradicts its status", and "a row a script can only find by prose that changes with the result", both stop being representable: identity is a field, and it is printed.

**Cheaper fallback.** Drop `deniedTitle` and keep the text-only output. That makes grepping stable but still gives a caller no id, so any script keys on human prose.

**Verification.** `DoctorEvaluatorTests`: for each `DoctorCheckID`, the title is identical across `.granted`, `.denied`, `.unknown`, and `.unavailable` facts. For the JSON mode, assert every row of `danterm doctor --json` carries an id drawn from `DoctorCheckID` and that the id set equals the text renderer's row set. Behaviorally: `danterm doctor --json | jq -e '.[] | select(.id=="notifications") | .status'` answers whether or not the permission is granted.

**Risk.** Anything grepping today's exact titles breaks. Only this repository's own smoke script and tests do that, and both are in the tree.

**Vetted.** I read all of `cli/Doctor.swift`: the `DoctorCheckID` declaration carries the quoted comment word for word, `evaluatePermission` takes both `title` and `deniedTitle` and returns `deniedTitle` on `.denied`, and `renderDoctorReport` prints `prefix`, `title`, and `message` and never the id. `SKILL.md:906-908` carries the quoted sentence. Every quote is exact. No `references/` citation to re-check.

**Correction.** The grep instability is smaller than the prose implies. Only the three permission rows flip their title, only between two fixed variants, and each pair shares a stable prefix -- `Notifications`, `Full Disk Access`, `Developer Tools` -- so a script that greps the subject rather than the whole line already works today. The status word already carries the answer that the flipped title duplicates. Impact 3 -> 2: dropping `deniedTitle` is a real tidy-up, but `--json` is a new feature rather than a defect fix, and the feature is most of the claimed payoff.

**Conflicts with.** `CLI-4`, which wants the three app-owned rows to name the instance they were gathered from -- the same `evaluatePermission` call sites and the same renderer.

<a id="cli-7"></a>

#### CLI-7. Gate the protocol constants SKILL.md states as prose, the way its synopsis is already gated

`correctness` &middot; impact 2, confidence 5 &middot; effort medium &middot; rescored

**Files.** `integrations/danterm/SKILL.md`, `lib/DanTermProtocol/Sources/DanTermProtocol/PaneTapeStream.swift#paneTapeStreamVersion`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLISkillSynopsisRegion.swift`, `scripts/run-test-suite.sh`

**Problem.** The generated synopsis region is checked in the gate, so the command list cannot rot. Everything else in SKILL.md -- the file the repository calls "the source of truth for the CLI surface" -- is unguarded prose, and it has already rotted. The `--format inspect` example prints `"version":3` while `paneTapeStreamVersion` is 6 and the same document states 6 nine lines earlier; the document also asserts that inspect "changes only its `format` field", which makes the example self-contradicting. In the same file, the "CLI stdout shapes" table opens with "Only these subcommands print to stdout" and then omits `doctor` (which prints its whole report) and `help` (which prints the usage text). An agent that trusts either statement writes a wrong reader. The tree already knows this failure mode: `scripts/tests/danterm-cli_test.sh` reads the version from the source constant rather than a literal, with a comment saying the literal "sat at 3 while the constant reached 5".

**Evidence.** `SKILL.md:644` versus `SKILL.md:794`:

```
  `{"kind":"start","version":6,"capture":"dump"|"follow"|"snapshot",`
...
    {"kind":"start","version":3,"capture":"dump","format":"inspect",...}
```

against `public let paneTapeStreamVersion = 6`. And `SKILL.md`'s stdout table header -- "Only these subcommands print to stdout ... Everything else prints nothing on success and exits 0" -- against `cli/main.swift#runDoctor`:

```swift
print(renderDoctorReport(checks), terminator: "")
exit(doctorExitCode(for: checks))
```

**Ideal fix.** Extend the mechanism that already works. `CLISkillSynopsisRegion` proves the pattern: a marked region, a projection, and a `--check` step in `LINT_STEPS`. Add a second marked region for the protocol constants the document quotes (`paneTapeStreamVersion`, the default sync-history budget, the follow cap) rendered from their declarations, and a third projecting the stdout-shape table from `CLICommandCatalog` plus each route's `CLIOutputMode` -- which is exactly the fact the table is trying to state, and which the catalog and parser already hold. A command whose output mode changes then cannot leave the table wrong.

**By construction.** "A documented output shape that no command has" and "a documented protocol version that no producer emits" stop being representable: both become projections of the declarations the code dispatches on.

**Cheaper fallback.** Fix the two literals by hand and add a grep-based lint asserting SKILL.md contains no `"version":N` other than `paneTapeStreamVersion`. That catches this one constant and leaves the stdout table hand-synced.

**Verification.** A new gate step (beside the existing `DanTermSkillSynopsisGenerator --check`) that fails on a stale region. Test in `DanTermProtocolTests`: the rendered stdout-shape region lists exactly the routes whose `CLIOutputMode` is not `.none`, plus the two local printers.

**Risk.** Over-generating the prose would flatten wording that is deliberately explanatory (the `pane tape` sections carry real teaching). Keep the generated regions to the tables and constants; leave the prose alone.

**Vetted.** `PaneTapeStream.swift:11` is `public let paneTapeStreamVersion = 6`. `SKILL.md:644` states 6; `SKILL.md:794` prints `"version":3` in the inspect example, three lines above `SKILL.md:797-799`, which says a `start` record "changes only its `format` field; its version, capture, provenance, geometry, and cursor are unchanged". The document really does contradict itself. The stdout table at `SKILL.md:976-1001` opens with the quoted sentence and omits both `doctor` (which prints `renderDoctorReport` and exits, `cli/main.swift:318-319`) and `help`. The `scripts/tests/danterm-cli_test.sh:16-18` comment is exactly as cited, "this one sat at 3 while the constant reached 5". Rescored impact 3 -> 2: one stale literal inside an example, plus a table whose two omissions an agent discovers the first time it runs either command.

**Conflicts with.** `GATE-3` (`GATE.md`) touches `scripts/run-test-suite.sh#LINT_STEPS`, which this finding's ideal fix appends a step to, and would additionally require the new lint to carry a self-test under `scripts/tests/`. Not blocking in either direction; write the new step to satisfy `GATE-3`'s rule if that one lands first.

<a id="cli-8"></a>

#### CLI-8. Give the CLI a verb for the roster subscription the protocol already serves

`simplification` &middot; impact 2, confidence 4 &middot; effort medium &middot; rescored

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift` (`case roster`), `lib/DanTermClient/Sources/DanTermClient/PaneRosterNotification.swift#PaneRosterNotification`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLICommandCatalog.swift#entries`

**Problem.** The daemon serves a live pane roster: `roster` subscribes the connection, and every later change arrives as a `roster.event` notification with the whole roster. `DanTermClient` even ships the reader. The CLI has no verb for it, so a shell agent that wants to know when a pane appears, is renamed, closes, or changes its agent chip has exactly one option: call `ls` in a loop. That re-serializes the entire split tree of every group on every poll to observe a change that the app was already prepared to push, and it cannot observe a change that begins and ends between two polls. This is the one thing in the CLI surface where the app can do something the shell client cannot ask for.

**Evidence.** The method exists with its subscription semantics stated:

```swift
/// Subscribes this connection to the pane roster. Takes no target: the roster is
/// the whole application's ... The reply is the current roster; every later roster goes
/// out as a `roster.event` notification until the connection ends.
case roster
```

The client-side reader exists (`PaneRosterNotification`), and `CLICommandCatalog.entries` contains no entry for it -- the catalog's exhaustiveness check runs over `CLIParserRoute`, which has no roster case, so nothing notices.

**Ideal fix.** `danterm roster [--follow]`, rendered as JSON Lines by the same record-stream path `pane tape` already uses: `renderPaneTapeStream`'s structure (await the reply, then drain notifications, writing one line each) is the shape this needs, minus the tape-specific record decoding. Without `--follow` it prints one roster and exits, which also gives callers a flat pane list that does not require recursing the split tree.

**By construction.** n/a -- this removes a capability gap rather than a representable-but-invalid state. It does delete the polling loop every agent script currently writes.

**Cheaper fallback.** Document the `ls`-polling recipe in SKILL.md. That leaves the missed-transition hole and the per-poll re-serialization exactly where they are.

**Verification.** `cli-tests` against a fake server: `roster` prints the reply roster as one JSON line and exits 0; `roster --follow` prints one line per `roster.event` and ends cleanly at EOF. Behaviorally, in `scripts/tests/danterm-cli_test.sh`: start `danterm --socket $SOCKET roster --follow` into a file, `pane split`, and assert a new line naming the new pane id arrives without polling.

**Risk.** A followed roster is a second long-lived stream kind, so it inherits the tape stream's obligations (SIGPIPE ignored, per-record writes, no receive timeout). Reusing that path rather than writing a second one is what keeps the risk small.

**Vetted.** I confirmed the whole chain, server side included. `IpcRequestMethod.roster` carries the quoted doc comment (`IpcRequest.swift:32-36`); `IpcDispatch.swift:78-82` returns `.subscribeRoster(reqId:roster:)`; `AppRuntime.swift:535-552` (`pushRosterIfChanged`) writes `Methods.rosterEvent` to every subscriber whose last enqueued roster differs; `PaneRosterNotification` is the client-side reader. `CLICommandCatalog.entries` has no roster entry and `CLIParserRoute` has no roster case, so the catalog's exhaustiveness check cannot notice. The gap is exactly as described.

**Correction.** The claimed payoff is not evidenced. I grepped `integrations/danterm/SKILL.md` and all of `scripts/` and found no `ls`-polling loop, so "the polling loop every agent script currently writes" describes a script that does not exist in this tree. And a subscription would not close the missed-transition hole completely: `pushRosterIfChanged` sends only when the roster differs from the last one enqueued, so a change that begins and ends inside one scheduling pass is invisible to a subscriber too. Impact 3 -> 2, confidence 4: the capability gap is certain, the demand for it is not.

**Conflicts with.** None. No other lane proposes a CLI verb or edits `CLICommandCatalog.entries`.

<a id="cli-9"></a>

#### CLI-9. Declare the pane grid bound once, instead of stating it as help prose beside the range that enforces it

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/CLICommandCatalog.swift` (`pane resize` entry), `lib/DanTermCore/Sources/DanTermCore/PaneGridOverride.swift#paneGridOverrideColumnRange`

**Problem.** The accepted grid range is written twice: as an enforced `ClosedRange` in `DanTermCore`, and as English inside the CLI catalog's help string. The two live in different packages, and the range is internal to `DanTermCore`, so the help string cannot read it and nothing compares them. Widening the engine's minimum width leaves `danterm help` -- and, through the generated synopsis path, the agent-facing documentation -- confidently stating the old numbers.

**Evidence.** `CLICommandCatalog.swift:250`:

```swift
"Run an exact grid whatever rectangle the pane occupies, or follow the rectangle again. Columns 2-1024, rows 1-1024",
```

against `PaneGridOverride.swift`:

```swift
let paneGridOverrideColumnRange: ClosedRange<Int> = 2...1024
let paneGridOverrideRowRange: ClosedRange<Int> = 1...1024
```

`DanTermCore` depends on `DanTermProtocol` (`lib/DanTermCore/Package.swift`), so the range can move down but not up.

**Ideal fix.** Move both ranges into `DanTermProtocol` as public constants, keep `PaneGridOverride.init?` validating against them, and interpolate them into the catalog's help string. One declaration, two readers, no prose to update.

**By construction.** A help line that states a bound the model does not enforce stops being writable.

**Cheaper fallback.** Delete the numbers from the help string and let the daemon's error message state them. That removes the drift and also removes a genuinely useful hint from `danterm help`.

**Verification.** `DanTermProtocolTests`: the `pane resize` help contains the rendered bounds of the shared constants. `DanTermCoreTests` already covers rejection at the edges; those tests keep passing unchanged, which is the point.

**Risk.** Moving a constant across a package boundary is mechanical; the only care needed is that `PaneGridOverride` stays the sole validator, so the CLI does not start rejecting locally what the parser's own comment says belongs to the daemon.

**Vetted.** I opened `CLICommandCatalog.swift:248-253` -- the `pane resize` help string ends in "Columns 2-1024, rows 1-1024" exactly as quoted -- and `PaneGridOverride.swift:27-35`, where both ranges are file-scope `let`s internal to `DanTermCore`. `IpcDispatch.swift:396-401` already interpolates the same two constants into the daemon's rejection message, which is the pattern the fix should follow.

**Correction.** The generated synopsis is not affected. The region between `BEGIN`/`END GENERATED DANTERM COMMAND SYNOPSIS` in `SKILL.md` carries usage lines only, with no summaries, so this prose reaches `danterm help` and nothing else. Any drift would sit in one help line, not in the agent-facing documentation. Impact stays 2 on the strength of the duplicated declaration itself.

**Conflicts with.** None. `MODEL.md` mentions `PaneGridOverride` twice, but only as the model other findings should copy ("in the shape of `PaneGridOverride`"); it proposes no edit to this file.

<a id="cli-10"></a>

#### CLI-10. Stop allocating and zeroing a 64 KiB buffer on every socket read

`cost` &middot; impact 2, confidence 5 &middot; effort small &middot; confirmed

**Files.** `lib/DanTermClient/Sources/DanTermClient/UnixSocketTransport.swift#receive`, `lib/DanTermClient/Sources/DanTermClient/TCPSocketTransport.swift#receive`

**Problem.** Both transports allocate a fresh zero-filled 65,536-byte array per `receive()` call, then copy the bytes actually read into a `Data`. The work per call is fixed at the buffer size rather than proportional to the bytes that arrived, and `receive()` is called once per wake-up on a followed tape stream -- a busy pane produces many small notifications, each one paying a 64 KiB `calloc` plus the copy. The transport is a class with a single frame-consuming reader (the session's `readLock` guarantees that), so the buffer can simply live on the instance.

**Evidence.** Identical in both files:

```swift
public func receive() throws -> Data {
    try lifetime.withDescriptor { descriptor in
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        ...
            return Data(buffer[0..<count])
```

with `private let readBufferSize = 64 * 1024`.

**Ideal fix.** Hold one `[UInt8]` (or an `UnsafeMutableRawBufferPointer` owned by the transport and freed in `close`) as a stored property, reused across calls, and return `Data(bytes: base, count: count)` from it. The single-reader rule the seam already documents ("One read and one write may be active at the same time") is what makes this safe without a lock.

**By construction.** n/a -- this is a cost fix, not a representability one.

**Cheaper fallback.** Shrink `readBufferSize`. That trades one fixed cost for more syscalls on large syncs, which is the wrong direction for `pane snapshot`.

**Verification.** The experiment that decides it: run `scripts/terminal-pane-tape-observer-tax.py` with the follower count at the cap against a chatty workload and compare client-side CPU before and after; separately, a microbenchmark driving `receive()` over a socketpair delivering 64-byte chunks, where allocations per call must drop from one to zero (measurable with `malloc` counters or an instruments allocations trace). The number that must move is client CPU per delivered notification; nothing about the app side should change.

**Risk.** A reused buffer must not be handed out; the returned `Data` must be a copy, exactly as today. If a second thread ever reads a transport concurrently the buffer is shared state -- so the change should land with the single-reader rule restated at the property.

**Vetted.** I opened both `receive()` bodies and confirmed the quoted code and `private let readBufferSize = 64 * 1024` in each file. I also checked the single-reader premise the fix rests on rather than taking it on the seam's word: every `transport.receive()` in the module is reached through `DanTermClientSession.nextLine()`, which is private and called only from `readFrame()` or from inside a `withReadLock` block (`DanTermClientSession.swift:130`, `:181`, `:202`, `:223`, `:273`). One reader at a time is a real invariant here, so a stored buffer needs no lock. `[UInt8](repeating: 0, count: 65536)` is a fresh allocation plus a 64 KiB memset per call, paid per wake-up rather than per byte delivered. I ran no benchmark, as instructed; the structural claim needs none.

**Conflicts with.** `CLI-2`, loosely: both edit the same two transports, and a buffer stored on the instance has to be released on the close path `CLI-2` adds. Either order works.

<a id="cli-11"></a>

#### CLI-11. Say which entity `pane zoom` reports, in the one line `danterm help` prints

`correctness` &middot; impact 2, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/DanTermProtocol/Sources/DanTermProtocol/CLICommandCatalog.swift` (`pane zoom` entry), `integrations/danterm/SKILL.md`

**Problem.** The catalog's help for `pane zoom` says it "Prints the tab's resulting zoom state". SKILL.md says the opposite, and says it emphatically: the field to read is `pane.isZoomed`, because a single-pane tab reports `isZoomed: false` rather than failing, and `tab.isZoomed` is "the coarser fact that the tab is zoomed on some pane". A caller who follows `danterm help` reads the wrong field and concludes a zoom succeeded when the pane it named is not the zoomed one.

**Evidence.** `CLICommandCatalog.swift:244`:

```swift
"Zoom a pane to fill its tab, or restore the split. Prints the tab's resulting zoom state",
```

against SKILL.md: "The reply's `pane.isZoomed` is the state of the pane you named after the request, so one reply says where the zoom landed ... check the field, not the exit status."

**Ideal fix.** Change the help to name the pane: "Prints the pane's resulting zoom state." One word, in the one declaration both `danterm help` and the generated synopsis project from, so the two documents agree by construction.

**By construction.** n/a -- this is prose inside the single authority; the authority is already unique.

**Cheaper fallback.** none -- the ideal fix is small.

**Verification.** `DanTermProtocolTests`: the `pane zoom` help mentions the pane rather than the tab. Behaviorally: `danterm help` and `danterm skill` agree about which field a caller reads.

**Risk.** None beyond the help text itself.

**Vetted.** `CLICommandCatalog.swift:244` reads exactly "Zoom a pane to fill its tab, or restore the split. Prints the tab's resulting zoom state". `SKILL.md:541-545` says exactly what the finding quotes, and `SKILL.md:995` already documents the reply as carrying "the resulting `pane.isZoomed`". Confidence 4 -> 5: I found both strings.

**Correction.** Two details in the prose above are wrong. First, the help is misleading rather than false: the reply is the `pane info` shape, so it does carry `tab.isZoomed` beside `pane.isZoomed`; what the help does is point a reader at the coarser of two fields it really prints. Second, the generated `SKILL.md` synopsis region carries usage lines only, not summaries, so this string reaches `danterm help` and nothing else -- the two documents do not currently disagree inside `SKILL.md`. Impact stays 2: a one-word fix that removes a real misdirection from the CLI's own help is still worth making.

**Conflicts with.** None. `CLI-9` edits a neighbouring entry in the same array but a different string.

#### Dropped (CLI)

- **`parsePaneGridWord` and non-ASCII digits.** `allSatisfy(\.isNumber)` admits Unicode digits, but `Int(_: String)` rejects them, so `"٣x٤"` is refused. No defect.
- **`renderPaneTapeStream` ignores the notification's `subscription` field.** The CLI opens exactly one tape stream per connection and exits when it ends, so no record can be misrouted today. Worth stating in a comment, not worth a finding.
- **`just launch-slot-prime` takes no arguments** while `launch-slot` takes `*args`, so the priming path cannot be combined with `--tailnet` or `--release`. Real, but the priming path exists for a one-time human permission grant and is not an agent workflow.
- **The three `launch-slot*` recipes wrap one script's flags.** Collapsing them into `just launch-slot --release` / `--foreground` would shrink the justfile, but SKILL.md teaches the three names to agents and the aliases cost nothing to keep.
- **`stop_slot` reads a pid from an unlocked record.** A recycled pid cannot be signalled: `terminate_session` returns early unless `os.getpgid(pid) == pid`, and only the slot app leads its own group. Already safe by construction.
- **`tailLines` scans the text twice.** It runs in the app, outside this lane, and the cost is proportional to the text it was asked to tail.
- **The generated synopsis region drifting from the catalog.** Already gated: `swift run DanTermSkillSynopsisGenerator --check integrations/danterm/SKILL.md` is in `LINT_STEPS`. `IPC-2` of the closed construction audit owns this and it landed.
- **`scripts/tests/danterm-cli_test.sh` is outside the gate.** The closed audit's `IPC-2` correction already records this, and the stale usage-line assertion it named is gone -- those assertions now live in `cli-tests/UsageTextTests.swift`, which the gate runs. Nothing live.
- **`quit`'s refusal message uses the wire method name.** `IpcRequestMethod.quit.rawValue` is the string `quit`, identical to the CLI spelling, so nothing reads wrong today. Folded into CLI-5 as a risk instead.

#### Pruned (CLI)

None. Every quote in this lane was found in the tree, at the symbol named, saying what the auditor says it says. Eight findings had their impact reduced and nine carry a correction, but none rested on code that is not there.


### Area: Tests, lint rules, and the gate (`GATE`)

_Scope: `scripts/run-test-suite.sh` and its step list, all of `scripts/*-lint.sh|py` and
`scripts/*-gate.*`, `scripts/tests/`, `scripts/test-terminal-pty.sh`,
`scripts/run-with-deadline.py`, the `justfile` gate recipes, and the wall-clock values in
`lib/DanTermClient/Tests`, `lib/DanTermSupport/Tests`, `lib/TerminalPTY/Tests`,
`lib/TerminalCore/Tests`. Read first: `agent-docs/test-timing.md`, the Tests section of
`AGENTS.md`, `docs/scratch/2026-08-18-construction-audit.md`, and
`docs/scratch/2026-08-19-gate-test-rent-audit.md`._

**The auditor's read on the area.** The gate is in unusually good shape: the step list is
one file with an explanation for every ordering decision, `gate-test-coverage-lint.py`
already ties manifests and self-tests to the step list, `core-purity-lint` sweeps rather
than naming targets, and the timing discipline in `IpcConnectionWriteTests` (one named
`hangGuardSeconds = 30.0` with a comment saying it is a guard and not a threshold) is
exactly what `agent-docs/test-timing.md` asks for. The remaining defects share one shape:
**a check whose subject is named by hand, and whose absence is indistinguishable from its
success.** Three lints pass with a green line when the file they check has been renamed
away; nothing makes a lint script itself run over the tree, only its self-test; two PTY
tests turn an elapsed duration into an acceptance threshold when the fact they want is
already in a counter; and one gate deadline covers a build the gate itself forces to be
cold. I deliberately did not audit the perf-instrument self-test cluster (the 2026-08-19
rent audit priced it and found nine of twelve load-bearing) and did not re-open the
`UpdateIpcTests` / `CLIParserTests` sweeps that the same audit rewrote. I looked at
`terminal-fence-accounting-lint.sh`, which counts occurrences of a spelling, and dropped
it: it says in its own rationale that it pins shape on purpose and it fails loudly when
its source files move.

<a id="gate-1"></a>

#### GATE-1. Make a lint whose target is missing fail, not print "passed"

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rescored

**Files.** `scripts/checkpoint-off-main-lint.sh`, `scripts/terminal-exit-concurrency-lint.sh`,
`scripts/reconcile-pass-lint.sh`, `scripts/run-test-suite.sh#LINT_STEPS`

**Problem.** Three gate lints name their subject as a hardcoded path. When that path does
not exist, all three print their success line and exit 0. `rg` exits 2 on a missing path,
and `if rg ...; then` reads any non-zero status as "no violations". `reconcile-pass-lint.sh`
does it more directly, with `[[ -f "$file" ]] || continue`. So renaming `app/AppRuntime.swift`,
`app/SwiftTerminalBackend.swift`, `app/Reconcile.swift`, `app/PaneFocusReconciliation.swift`,
or `app/SidebarReconcileDriver.swift` turns the matching lint into a no-op that still
reports green. The gate discards a passing step's output, so even the `rg` error on stderr
is invisible to whoever ran `just test`. Two sibling lints in the same directory already
solved this -- `private-file-mode-lint.sh` and `ambient-identity-lint.sh` both fail on a
stale allowlist entry -- so the tree carries the fix and the rule next to the bug.

**Evidence.** `scripts/checkpoint-off-main-lint.sh`:

```
if [[ "$#" -eq 0 ]]; then
    set -- "$ROOT/app/AppRuntime.swift"
fi
...
if rg --pcre2 --glob '*.swift' -n "$PATTERN" "$@"; then
```

Run against a path that does not exist:

```
$ ./scripts/checkpoint-off-main-lint.sh app/NoSuchFile.swift
rg: app/NoSuchFile.swift: IO error ... (os error 2)
checkpoint off-main lint passed        # exit 0
```

`scripts/terminal-exit-concurrency-lint.sh` behaves identically (`terminal exit
concurrency lint passed`), and `scripts/reconcile-pass-lint.sh --whole app/Missing.swift`
prints `reconcile pass lint passed` without even an `rg` complaint, because of:

```
for file in ${WHOLE_FILES[@]+"${WHOLE_FILES[@]}"}; do
    [[ -f "$file" ]] || continue
```

Contrast `scripts/private-file-mode-lint.sh`, which states the rule this finding wants
everywhere: "An allowlist entry naming a file that no longer exists exempts nothing while
still reading as policy, so a rename must fail here rather than pass silently."
`scripts/terminal-scalar-append-lint.sh` says the same thing in one line: "A gate that
cannot find its target must fail, not pass."

**Ideal fix.** One helper beside `scripts/lib/lint-rationale.sh` -- say
`scripts/lib/lint-targets.sh#lint_require_targets` -- that takes the target list, fails
with the "this lint checked nothing" message on any path that is not a file or directory,
and is sourced by every lint that names a subject. `terminal-fence-accounting-lint.sh`
already has this function privately as `setup_fail`; promoting it makes the property
uniform instead of per-author. With it in place, a lint that reports "passed" has
provably read something.

**By construction.** "The lint ran" and "the lint found nothing" stop being the same
observation. A rename that outruns a lint becomes a red step naming the moved file rather
than a silent gap.

**Cheaper fallback.** Add three `[[ -f ]] || exit 1` guards inline. Same behavior for
these three files, but it leaves the next lint author to rediscover the trap; the shared
helper is only a few lines more.

**Verification.** Extend each lint's existing self-test (`scripts/tests/checkpoint-off-main-lint_test.sh`,
`terminal-exit-concurrency-lint_test.sh`, `reconcile-pass-lint_test.sh`) with one case:
point the lint at a path inside the fixture tree that was never created, assert exit
status 1, and assert stderr names the missing path. That case fails today for all three.

**Risk.** A lint invoked with an explicit path in some ad-hoc context would now fail
rather than skip. Nothing in `scripts/run-test-suite.sh` or the self-tests passes an
optional path, so the blast radius is limited to a person typing one by hand.

**Vetted.** I opened all three lints and reproduced the defect.
`./scripts/checkpoint-off-main-lint.sh app/NoSuchFile.swift` prints two
`rg: ... (os error 2)` lines and then `checkpoint off-main lint passed` at exit 0;
`./scripts/terminal-exit-concurrency-lint.sh app/NoSuchFile.swift` does the same once;
`./scripts/reconcile-pass-lint.sh --whole app/Missing.swift` prints
`reconcile pass lint passed` at exit 0 with no `rg` complaint at all, from
`[[ -f "$file" ]] || continue` at the head of its whole-file loop. All three
default target lists and the `set -- "$ROOT/app/AppRuntime.swift"` fallback are as quoted.
The three lints are steps 119, 122, and 123 of `LINT_STEPS`. The "output is invisible"
claim is exact: a worker writes each step's stdout and stderr to `"$log.out"` and the
supervisor `cat`s that file only for steps that left a `.rc` marker, so a passing step's
stderr is discarded with the temp dir. The sibling rationale quotes are verbatim
(`private-file-mode-lint.sh:68`, `ambient-identity-lint.sh:52`,
`terminal-scalar-append-lint.sh:32`) and `setup_fail` is real
(`terminal-fence-accounting-lint.sh:20-24`, called at lines 50-51), so the promotion the
ideal fix asks for is a move, not a design.

**Correction.** Two details the fix has to carry. First, the helper must accept a
directory, not only a file: `scripts/tests/checkpoint-off-main-lint_test.sh` points the
lint at `"$TMP/allowed"` and `"$TMP/denied"`, so a file-only guard would break the
existing self-test. Second, impact is 3, not 4. Nothing is broken today -- every named
target exists -- and the hole opens only when someone renames one of five files. That is a
real and cheap-to-close hazard, but it is latent, and `reconcile-pass-lint.sh`'s own
targets are three files that a rename would also have to survive a compile without.

**Conflicts with.** `GATE-5`, which rewrites the target selection in
`scripts/checkpoint-off-main-lint.sh` and adds a one-entry allowlist that needs exactly
this stale-entry check. Land them as one edit to that script. `GATE-3` adds a rule to
`scripts/gate-test-coverage-lint.py` and possibly a step to `LINT_STEPS`; that is
adjacent, not conflicting. `DRAW-3` and `CLI-7` also add steps beside `LINT_STEPS`, which
their own vetted notes already call adjacent.

<a id="gate-2"></a>

#### GATE-2. Take the build out from under the TerminalPTY lane's hard deadline

`correctness` &middot; impact 3, confidence 4 &middot; effort small &middot; rescored

**Files.** `scripts/test-terminal-pty.sh`, `scripts/run-with-deadline.py`,
`scripts/run-test-suite.sh#STEPS`

**Problem.** `scripts/test-terminal-pty.sh` puts a 180-second hard kill around
`swift test --package-path lib/TerminalPTY`, and the same script deletes that package's
build directory whenever `lib/TerminalCore` changed since the last run. So the deadline
covers a cold compile of TerminalCore plus TerminalPTY plus the test binaries, plus a PTY
suite that spawns real children -- on a step that holds only two CPU tokens, inside a pool
sized `hw.ncpu - 2` and shared with every other gate on the machine. `run-with-deadline.py`
SIGKILLs the whole process group on expiry, so the failure reads as a hang in the terminal
engine when what actually happened is that the compiler was slow. This is the case
`agent-docs/test-timing.md` names directly: "any deadline a passing run could approach is
a race the gate will eventually lose."

**Evidence.** `scripts/test-terminal-pty.sh`:

```
TEST_TIMEOUT_SECONDS="${DANTERM_PTY_TEST_TIMEOUT_SECONDS:-180}"
...
if [[ "$fingerprint" != "$recorded_fingerprint" ]]; then
    "$SWIFT" package --package-path "$PTY_PACKAGE" clean
fi

python3 "$SCRIPT_DIR/run-with-deadline.py" \
    "$TEST_TIMEOUT_SECONDS" "TerminalPTY test lane" \
    "$SWIFT" test --package-path "$PTY_PACKAGE" \
    --skip rapidCloseStressLeavesNoResources "$@"
```

`scripts/run-with-deadline.py`: "SIGKILL, not SIGTERM: a process wedged badly enough to
reach the deadline". The width available to this step is two tokens
(`scripts/run-test-suite.sh`: `WIDE_ASK="${DANTERM_GATE_WIDE_ASK:-2}"`, and the step is
declared `'wide: ./scripts/test-terminal-pty.sh'`). The gate's own self-test records the
cold cost of the dependency being rebuilt here: "lib/TerminalCore measured 5s with a warm
iOS portability tree and 116s cold at -j1"
(`scripts/tests/run-test-suite_test.sh`). The clean is triggered by exactly the edit that
is most common in this repo -- a change under `lib/TerminalCore/Sources`.

**Ideal fix.** Build outside the guard and time only the run. Call
`swift build --build-tests --package-path "$PTY_PACKAGE"` with no deadline (the token pool
already bounds how much compile the machine does at once), then run both lanes as
`swift test --skip-build` under `run-with-deadline.py`. The guard then bounds only what it
claims to bound: a wedged PTY test. `swift test --skip-build` exists in this toolchain
(`swift test --help`: "--skip-build   Skip building the test target").

**By construction.** A compile that is merely slow can no longer be reported as a PTY
hang, and the number 180 stops being a function of how many other gates are running.

**Cheaper fallback.** Raise 180 to, say, 900. That keeps the two costs mixed, so the
number still has to be re-guessed whenever machine load or the size of TerminalCore
changes, and a real hang now takes fifteen minutes to report.

**Verification.** `scripts/tests/test-terminal-pty_test.sh` already shims `swift`; add a
case whose shim sleeps past the deadline in its `build` invocation and returns promptly
for `test`, and assert the script still succeeds. Then a case where the `test` invocation
sleeps past the deadline and assert exit 124. The first case fails today.

**Risk.** A build that genuinely wedges (a compiler bug, a stuck manifest resolve) is no
longer killed by this script. `just test` has no global deadline either way, so the
observable change is that the operator sees a stuck compiler rather than a spurious PTY
hang report.

**Vetted.** Every quote is in the tree. `scripts/test-terminal-pty.sh` sets
`TEST_TIMEOUT_SECONDS="${DANTERM_PTY_TEST_TIMEOUT_SECONDS:-180}"`, fingerprints
`lib/TerminalCore`'s `Package.swift` and `Sources`, and runs
`"$SWIFT" package --package-path "$PTY_PACKAGE" clean` on a mismatch -- which drops the
TerminalCore artifacts built inside TerminalPTY's own `.build`, so the next command is a
cold compile of both. `run-with-deadline.py` carries the SIGKILL comment verbatim and
returns 124 after `terminate_process_tree`. `scripts/run-test-suite.sh:163` declares
`'wide: ./scripts/test-terminal-pty.sh'`, `WIDE_ASK` defaults to 2, and `BUDGET` is
`hw.ncpu - 2` shared machine-wide. `swift test --help` on this toolchain does list
`--skip-build`, and `scripts/tests/test-terminal-pty_test.sh` really does shim `swift`
through `DANTERM_SWIFT`, with a `swift_hang` fixture already in place -- so the proposed
verification is a small extension of what exists.

**Correction.** Two things. The finding understates the shape and overstates the
measurement. It understates it because the script wraps *two* deadline lanes, each at the
same 180: the cold build lands inside the first, and the second (`--filter
rapidCloseStressLeavesNoResources`) then runs warm, so the fix has to build once before
both lanes rather than once before one. It overstates it because the "116s cold at -j1"
figure is a measurement of the *iOS cross-compile* of `lib/TerminalCore`
(`run-test-suite.sh:279`, echoed in the self-test), not of this host build of TerminalCore
plus TerminalPTY plus test binaries. I have no measurement of this lane, and the audit
rules forbid taking one, so the claim "180 is tight" stays inference. What is certain from
the code alone is the structural point: the guard bounds a compile it does not claim to
bound, and the number 180 is therefore a function of machine load. Impact 3, not 4 -- the
worst outcome is a spurious red step with a misleading name on a gate the operator reruns.

**Conflicts with.** Nothing found. No other lane file edits `scripts/test-terminal-pty.sh`
or `scripts/run-with-deadline.py`. `GATE-4` edits the TerminalPTY *tests* this script
runs, which is independent of how the script is wrapped.

<a id="gate-3"></a>

#### GATE-3. Make the gate prove that each lint script runs over the tree, not just that its self-test runs

`structural` &middot; impact 3, confidence 5 &middot; effort small &middot; confirmed

**Files.** `scripts/gate-test-coverage-lint.py#tracked_script_tests`,
`scripts/run-test-suite.sh#LINT_STEPS`

**Problem.** `gate-test-coverage-lint.py` closes exactly one half of the loop. It requires
every tracked `*_test.sh` / `*_test.py` under `scripts/tests/` to appear as a command word
in the assembled gate, and every declared Swift test target to have a lane. Nothing makes
the same claim about the lint scripts themselves. Adding `scripts/foo-lint.sh` plus
`scripts/tests/foo-lint_test.sh` and wiring only the self-test into `STEPS` produces a
fully green gate in which the lint never reads the tree. That is the same failure mode the
2026-08-19 audit found in C2 ("the target list lived in the gate script, so 'nobody
remembered this module' and 'this module is exempt' were the same observation"), one level
up: the list of lints now lives in the gate script by hand.

**Evidence.** `scripts/gate-test-coverage-lint.py`, module docstring: "Tracked shell and
Python self-tests make the same coverage claim as a manifest. A matching `*_test.sh` or
`*_test.py` must occur as a command word in the assembled gate". The discovery is scoped
to that suffix alone:

```
        if raw and raw.endswith((b"_test.sh", b"_test.py"))
```

Nothing else in the file mentions a lint. The tree happens to be complete today -- sweeping
`scripts/*lint*.sh|py` and `scripts/*gate*.sh|py` against `run-test-suite.sh` leaves only
`core-purity-lint.py` and `swift-file-header-lint.py`, both of which are `exec`'d by their
same-named `.sh` wrappers -- but that completeness rests on nothing.

**Ideal fix.** Extend the same lint with the symmetric rule. Every tracked
`scripts/*-lint.{sh,py}` and `scripts/*-gate.{sh,py}` must occur as a command word in the
assembled gate or carry `# gate: opt-out -- <reason>` in its own file, reusing the opt-out
mechanism that already exists for `scripts/tests/danterm-cli_test.sh`. A script `exec`'d
by a same-stem wrapper that is itself covered counts as covered, which is the one
indirection the tree uses.

**By construction.** "This lint exists" and "this lint runs" become the same fact. A new
rule cannot ship half-wired, and retiring a lint has to be a visible deletion or a written
opt-out rather than a quiet removal of one line from `LINT_STEPS`.

**Cheaper fallback.** None -- the ideal fix is small; it is one more discovery function and
one more report block in a file that already has both shapes.

**Verification.** `scripts/tests/gate_test_coverage_lint_test.py` already drives the lint
against a fixture tree with a synthetic step list. Add two cases: a fixture lint script
absent from the step list must fail with a message naming it, and the same script carrying
the opt-out marker must pass. Both fail today for the absent case.

**Risk.** A one-off diagnostic script whose name happens to end in `-lint.sh` would have to
declare an opt-out. That cost is one line and it is the point of the rule.

**Vetted.** I read `scripts/gate-test-coverage-lint.py` end to end. The docstring quote is
verbatim, and `tracked_script_tests()` filters `git ls-files` on
`raw.endswith((b"_test.sh", b"_test.py"))` and nothing else. The whole file's only other
subject is Swift test estates read out of manifests; the word "lint" never names a
checked subject. So the asymmetry is exactly as described: a self-test must run, a lint
need not. I reproduced the completeness sweep -- every tracked `scripts/*lint*.{sh,py}` and
`scripts/*gate*.{sh,py}` outside `scripts/tests/` appears by basename in
`run-test-suite.sh` except `core-purity-lint.py` and `swift-file-header-lint.py`, and I
opened both wrappers: each is a three-line `exec python3 "$SCRIPT_DIR/<same-stem>.py"`, so
the one indirection the ideal fix names is the only one the tree uses. The opt-out
mechanism is real and already exercised: `OPT_OUT` at line 235,
`scripts/tests/danterm-cli_test.sh:3` carries `# gate: opt-out -- requires a GUI and jq;
runs through just test-cli`, and `scripts/tests/gate_test_coverage_lint_test.py` already
tests the marker's accepted and rejected forms, so the new cases drop into an existing
fixture harness. Impact and confidence stand at 3 and 5: the payoff is entirely
prospective (the tree is complete today), but the repo runs roughly forty lints and this
is the lane's own subject.

**Conflicts with.** `GATE-1`, weakly: both fixes are motivated by the same "absence looks
like success" shape, and if `GATE-1`'s shared helper lands as a new
`scripts/lib/lint-targets.sh`, `GATE-3`'s discovery must not mistake a sourced library for
an unwired lint. That is a one-line exclusion, not a redesign. `DRAW-3` and `CLI-7` each
propose a new gate step; `GATE-3`'s rule makes those steps mandatory rather than optional,
which is cooperative. No production code is shared with any other lane.

<a id="gate-4"></a>

#### GATE-4. Replace the two wall-clock acceptance thresholds in the PTY suites with the fact they are standing in for

`correctness` &middot; impact 3, confidence 5 &middot; effort small &middot; rewritten

**Files.** `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift#closeRacingPromptSpawnUsesTeardownLadder`,
`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionControllerTests.swift#applicationTerminationDrainsRegistryWithoutMainProgress`

**Problem.** Both tests measure elapsed wall time and assert it is under a small constant.
`agent-docs/test-timing.md` bans this: "No test passes or fails on whether production was
fast enough. An elapsed duration is never an acceptance threshold." In the first test the
assertion is also redundant -- the same test already asserts the counter that carries the
real fact. In the second, the intent block does not mention timing at all: the test is
about the registry draining, and 3 seconds is a hang guard promoted into a verdict. Both
run beside a chatty child or a real spawn on an oversubscribed pool, so both will lose the
race eventually, and when they do the failure will say "teardown was slow" rather than
naming anything real.

**Evidence.** `TerminalPTYHostTests.swift#closeRacingPromptSpawnUsesTeardownLadder`:

```
        let elapsed = start.duration(to: clock.now)

        let snapshot = await host.resourceSnapshot()
        #expect(elapsed < .seconds(1))
        #expect(snapshot.isReleased)
        #expect(snapshot.census.forcedQuiescenceCount == 0)
```

The bound it is protecting against is
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift`:

```
    static let defaultApplicationExitBound: DispatchTimeInterval = .seconds(2)
```

and reaching that bound is precisely what increments the counter the next line already
checks (`forcedQuiescenceCount += 1` at `TerminalPTYHost.swift:1028`). The bound is
injectable -- the initializer takes `applicationExitBound:` and its own comment says it "is
injected only so a test can drive the forced" path -- and other tests in this very file
already pass `applicationExitBound: .seconds(30)`.

`TerminalPaneSessionControllerTests.swift#applicationTerminationDrainsRegistryWithoutMainProgress`
does the same with a live flooding child:

```
        registry.requestShutdownAndWait()
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(3))
        #expect(observers.signalCount == 2)
```

Its own Intent block reads "the backend registry retains every host through native
cleanup, removes it from host-queue quiescence, and returns only after all shutdown
observers have run" -- no claim about speed.

**Ideal fix.** State the fact directly instead of inferring it from the clock. Build both
hosts with `applicationExitBound: .seconds(30)`, drop both `elapsed` assertions, and keep
`forcedQuiescenceCount == 0` plus the observer count. With a 30-second bound, completing
at all inside the suite's `.timeLimit(.minutes(1))` is by itself proof that the ladder did
not wait on the bound, and the unforced census proves it did not force. The `let clock` /
`let start` locals then delete with the assertion.

**By construction.** No assertion in either suite turns on how fast the host ran, so
scheduler noise cannot produce a red gate. The property under test is carried by a counter
production maintains, not by a measurement the test takes.

**Cheaper fallback.** Widen 1s to 10s and 3s to 20s. That buys headroom and nothing else:
the assertion still fails for a reason that is not a defect, and it still tells a future
reader that elapsed time is an acceptable thing to assert here.

**Verification.** `swift test --package-path lib/TerminalPTY --filter closeRacingPromptSpawnUsesTeardownLadder`
and the sibling filter, before and after. Ablate: make the shutdown path force quiescence
(return early from the ladder so the timer fires); the test must still fail on
`forcedQuiescenceCount == 0` with the elapsed assertion removed. That proves the counter
carries the property on its own.

**Risk.** If the ladder regressed into taking 25 seconds without ever forcing, the
rewritten test would pass where the old one failed. That regression is a performance
question, and `agent-docs/terminal-performance.md` owns it; a unit test on a shared pool
cannot measure it honestly anyway.

**Vetted.** Both tests are quoted correctly, line for line
(`TerminalPTYHostTests.swift:3142-3153`, `TerminalPaneSessionControllerTests.swift:2075-2081`),
and both Intent blocks read as the finding says. The production side checks out too:
`TerminalPTYHost.defaultApplicationExitBound` is `.seconds(2)` at line 377,
`armExitBound()` schedules the timer at `.now() + applicationExitBound` (line 912), and
`exitBoundElapsed()` opens with `forcedQuiescenceCount += 1` at line 1028 -- so reaching
the bound and incrementing the counter are the same event, and `forcedQuiescenceCount == 0`
really is the fact the elapsed assertion is standing in for. The initializer comment at
line 532 and the `.seconds(30)` call sites at 3357, 3403, 3480, 3535, 3587, and 3669 are
all present. The doc quote is exact (`agent-docs/test-timing.md:25-26`).

**Correction.** The prescribed fix is wrong in both tests, in opposite directions, and the
finding is stronger without it.

For `closeRacingPromptSpawnUsesTeardownLadder`, do **not** inject
`applicationExitBound: .seconds(30)`. The test's own title is "close racing a prompt spawn
converges inside the real host bound" -- running it against the real 2-second default is
the point, and a 30-second bound would make `forcedQuiescenceCount == 0` prove almost
nothing. Keep the default bound and delete only `let clock`, `let start`, `let elapsed`,
and `#expect(elapsed < .seconds(1))`. With the 2-second bound intact,
`forcedQuiescenceCount == 0` is the exact statement "the ladder did not wait on the
bound", which is the regression named in the Why-it-exists block. The finding also
mis-identifies the backstop: what actually catches a wedged ladder here is
`#expect(recorder.waitForAll(within: .seconds(20)))` on line 3147, not the
`.timeLimit(.minutes(1))`.

For `applicationTerminationDrainsRegistryWithoutMainProgress`, the 3-second assertion is
weaker than the finding says, which makes deleting it free. Its `makeHost`
(`TerminalPaneSessionControllerTests.swift:2523`) takes no `applicationExitBound` and so
uses the 2-second default -- meaning a run that hits the forced-quiescence path at 2s and
returns still passes `elapsed < .seconds(3)`. The assertion therefore rules out nothing
except a hang, which `.timeLimit(.minutes(1))` already reports. Delete the three timing
lines; no injected bound and no new parameter on the private helper are needed.

Net: the fix is four deletions in one test and three in the other, with no production or
helper changes at all. Impact stays 3, confidence 5.

**Conflicts with.** Nothing in another lane edits either test file. `GATE-2` changes how
`scripts/test-terminal-pty.sh` invokes the suite that contains both; the two are
independent and can land in either order.

**Done.** Landed wider than written: there were five elapsed-time assertions in the PTY
suites, not two. The three the finding and its correction missed are
`applicationTerminationClosesMultipleLivePanes` (`elapsed < .seconds(3)` around a
three-host concurrent close, against the same 2-second default bound -- so vacuous as
well as racy, in a test whose own comment records 2.6s measured for a prior step),
`applicationExitTerminationOnTornDownHostReturnsImmediately` (`< .seconds(1)` behind an
injected 30-second bound), and the `waitForOutput`-on-a-quiesced-host test
(`clock.now - start < .seconds(1)`, redundant with the `.some(.some(false))` above it).

Each deletion was paired with the fact it stood in for rather than dropped bare.
`forcedQuiescenceCount == 0` was added to the three-host close and to both hosts in the
registry-drain test, which strengthens them -- the elapsed thresholds they replace sat
*above* the 2-second bound and so could not tell a forced quiescence from a clean return.
`applicationExitTerminationOnTornDownHostReturnsImmediately` needed a fact production did
not yet expose: an unforced census cannot say "no ladder ran", since a ladder that
converged also scores zero. So `TerminalPTYLifecycleCensus` gained
`armedExitBoundCount`, incremented in `armExitBound()`; the test reads it before and after
the shutdown request and asserts the request armed nothing new. Its
`applicationExitBound: .seconds(30)` injection and the comment justifying it were deleted
-- the claim no longer depends on the bound's size. `closeRacingPromptSpawnUsesTeardownLadder`
kept the real 2-second default and lost only its four timing lines, per the correction.

Ablated all four: firing the exit bound immediately turns the three census assertions red
(`forcedQuiescenceCount -> 1`), and arming the bound ahead of `beginShutdown`'s guard
turns the arming comparison red (`2 == 1`). No assertion in either suite reads a clock
except hang guards and the two sanctioned generous bounds. Also corrected a comment that
called the per-host census "process-wide"; the process-wide thing in that test is the
descriptor count. Full `swift test --package-path lib/TerminalPTY` (301 tests) and
`just lint` pass.

<a id="gate-5"></a>

#### GATE-5. Widen checkpoint-off-main-lint to the whole `app/` tree for the three spellings that are already unique to it

`structural` &middot; impact 2, confidence 5 &middot; effort small &middot; rescored

**Files.** `scripts/checkpoint-off-main-lint.sh`, `scripts/run-test-suite.sh#LINT_STEPS`

**Problem.** The lint's rule is about a *place* -- "the runtime may build a capture and hand
its encoder to the writer, but the stages themselves must not appear where it captures" --
but its implementation is about one *file*, `app/AppRuntime.swift`. Splitting the runtime,
which is a 1000+ line file that already holds three capture sites, moves the code out of
the lint's view with no failure. Combined with GATE-1, the failure is silent in both
directions: move the code and nothing is checked; rename the file and nothing is checked.

**Evidence.** `scripts/checkpoint-off-main-lint.sh`:

```
if [[ "$#" -eq 0 ]]; then
    set -- "$ROOT/app/AppRuntime.swift"
fi

PATTERN='^(?![[:space:]]*//).*(graftScrollback\(|truncateScrollback\(|toInitFile\(|JSONEncoder\()'
...
ENCODER_PATTERN='^(?![[:space:]]*//)(?!.*encode:).*\.encoder\('
```

Three of the four banned spellings, plus the encoder rule, are already unique enough to
sweep the whole tree with zero new noise. Grepping `app/` today:
`graftScrollback(`, `truncateScrollback(`, and `toInitFile(` appear **nowhere** in `app/`,
and `.encoder(` appears at exactly three lines, all inside `AppRuntime.swift` and all
already in the legal `encode: capture.encoder()` form. Only `JSONEncoder(` is noisy --
`app/SwiftTerminalBackend.swift`, `app/SwiftTerminalSessionView.swift`, and
`app/TabTodoPopoverScope.swift` use it for unrelated reasons.

**Ideal fix.** Sweep `app/` with the three stage spellings and with `ENCODER_PATTERN`.
Keep `JSONEncoder(` scoped to the capture site, named as a one-entry allowlist with a
stale-entry check in the shape `private-file-mode-lint.sh` already uses, so the narrow
half also fails on a rename.

**By construction.** Moving a capture site to a new file no longer moves it out of the
rule. The one spelling that still needs a named subject says so, and cannot go stale.

**Cheaper fallback.** Add the existence check from GATE-1 and leave the scope at one file.
That removes the rename hole but not the "split the file" hole, and splitting `AppRuntime`
is a plausible next refactor.

**Verification.** `scripts/tests/checkpoint-off-main-lint_test.sh` already stages fixture
files. Add a case that plants `graftScrollback(` in a second file under the fixture `app/`
and asserts exit 1 naming that file; and one that plants an unrelated `JSONEncoder()` in a
second file and asserts the lint still passes. The first fails today.

**Risk.** A future legitimate use of `.encoder(` elsewhere in `app/` would trip the lint.
That is the rule working: it would have to be argued, which is what the script's header
already asks for.

**Vetted.** I re-ran every grep the finding rests on and all four results hold exactly.
`graftScrollback(`, `truncateScrollback(`, and `toInitFile(` appear nowhere under `app/`.
`.encoder(` appears at three lines, all in `AppRuntime.swift` (864, 1214, 1273) and all in
the legal `encode: capture.encoder(...)` form. `JSONEncoder(` appears at
`app/TabTodoPopoverScope.swift:370`, `app/SwiftTerminalSessionView.swift:27`, and
`app/SwiftTerminalBackend.swift:161`, so it is the one spelling that cannot sweep. The
lint's `set -- "$ROOT/app/AppRuntime.swift"` default, `PATTERN`, and `ENCODER_PATTERN` are
verbatim. `app/AppRuntime.swift` is 1849 lines, so the split the finding worries about is
plausible rather than hypothetical. One fact that helps the fix and the finding does not
mention: the lint already accepts a directory operand --
`scripts/tests/checkpoint-off-main-lint_test.sh` invokes it as `"$LINT" "$TMP/allowed"` --
so widening the default to `app/` needs no change to how targets are consumed. Confidence
raised to 5: I found the code and reproduced the sweep.

**Correction.** Impact is 2, not 3. Both halves of the payoff are prospective, and the
half `GATE-1` does not already cover is narrower than it looks: the three stage spellings
this widening would sweep for are absent from `app/` entirely, so the widened rule catches
a regression only if a *future* split of `AppRuntime.swift` also reintroduces graft,
truncate, or init-file assembly at a capture site. The `ENCODER_PATTERN` half is the part
with live subject matter -- three real call sites that a split would carry out of view --
and it is worth doing, but it is one rule over three lines.

**Conflicts with.** `GATE-1`. Both rewrite target selection in
`scripts/checkpoint-off-main-lint.sh`, and this finding's `JSONEncoder(` allowlist is
exactly the stale-entry check `GATE-1` wants to make shared. Implementing them separately
would mean editing the same twelve lines twice and would likely produce two different
existence checks in one file. Land as one edit, with `GATE-1`'s helper first.

<a id="gate-6"></a>

#### GATE-6. Retire the Swift-source text greps in the benchmark harness self-test

`simplification` &middot; impact 1, confidence 5 &middot; effort small &middot; rewritten

**Files.** `scripts/tests/terminal-benchmark-harness_test.sh`

**Problem.** This gate step contains 105 `grep -q` assertions over literal source text.
For the shell and Python harness scripts that is defensible -- they have no other test
seam. But a run of them assert that a specific expression appears in a *Swift* source file
and in the `justfile`, which is exactly the class the 2026-08-19 rent audit deleted
`terminal-benchmark-commands_test.sh` for: "Renaming a recipe breaks it with nothing
actually broken. This is a gate step violating 'a refactor that keeps the behavior must
keep the test passing.'" That audit examined this file and judged it healthy on
commit-history grounds ("31 commits since June are real co-evolution"). Reading the bodies
rather than the history gives a different answer for this subset -- which is the same
lesson section D of that audit drew about itself.

**Evidence.** `scripts/tests/terminal-benchmark-harness_test.sh`:

```
grep -q 'NSApp.activate()' "$ROOT/app/AppDelegate.swift"
grep -q 'observeTitle(title)' "$ROOT/app/SwiftTerminalSessionView.swift"
grep -q 'benchmarkStateRecorder?.windowDidChangeOcclusionState()' \
    "$ROOT/app/AppPresentationLifecycle.swift"
grep -q 'machineStateSamples' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'setFrameTopLeftPoint' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'screenVisibleFrame.contains' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'drawDurationsNanoseconds' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'pendingRedrawSequence' "$ROOT/app/TerminalBenchmark.swift"
grep -q 'benchmark-loop' "$ROOT/justfile"
grep -q 'benchmark-sample' "$ROOT/justfile"
grep -q 'benchmark-trace' "$ROOT/justfile"
```

Spelling `NSApp.activate()` as `NSApplication.shared.activate()`, or renaming a private
property, turns this step red with nothing broken.

**Ideal fix.** Delete the greps that point at `$ROOT/app/*.swift` and at `$ROOT/justfile`.
Where the underlying fact matters and is behavioral -- the recorder is notified on an
occlusion change, the window is placed inside the visible frame -- it belongs in `tests-ui/`
beside the other AppKit tests, which already cover this layer
(`tests-ui/AppPresentationLifecycleTests.swift` exists). Keep every grep whose subject is
`$HARNESS`, `$PRODUCER`, or `$PROFILE`: those scripts have no other seam and the file says
so in its header.

**By construction.** n/a -- this is a subtraction. The property it removes is "a rename in
Swift can fail a shell contract test".

**Cheaper fallback.** Leave them and accept the churn. The cost is not gate seconds (this
step runs in about a second); it is that an unrelated refactor gets a red step whose
message is a shell trace, and the reflex fix is to edit the grep, which teaches nobody
anything.

**Verification.** Delete the eleven lines, run
`./scripts/tests/terminal-benchmark-harness_test.sh` (green), then confirm the behavioral
half is covered with `swift test --filter AppPresentationLifecycleTests` on a machine with
a WindowServer, or write the missing case there first if the occlusion notification is
unpinned.

**Risk.** If any of these Swift-side facts is currently pinned *only* by the grep, deleting
it loses the last witness. That is why the fix pairs each deletion with a check in
`tests-ui/`, and why anything without a behavioral home stays until it has one.

**Vetted.** The count is right -- 105 `grep -q` calls -- and the eleven quoted lines are all
present. But the quoted eleven are a sample, not the set: 31 lines in this file grep
`$ROOT/app/*.swift` and 3 grep `$ROOT/justfile`. I opened each Swift target and the
finding's own Risk paragraph turns out to be the whole story. **Every one of those 31
greps points at code inside `#if DANTERM_TERMINAL_BENCHMARK`**: `app/TerminalBenchmark.swift`
opens its declarations with that guard, `NSApp.activate()` sits under it at
`app/AppDelegate.swift:215`, `benchmarkStateRecorder?.windowDidChangeOcclusionState()`
under it at `app/AppPresentationLifecycle.swift:109-112`, and both
`SwiftTerminalSessionView.swift` sites (`observeTitle(title)` at 1486-1488,
`damage: frame.damage` at 1695-1698) likewise. The define is set in exactly one place --
`scripts/terminal-benchmark.sh:202` and `:204`, as `-Xswiftc -DDANTERM_TERMINAL_BENCHMARK`
-- and nowhere in `Package.swift` or the `justfile`. So `DanTermUITests` (`path: "tests-ui"`)
compiles `app/` *without* the define and cannot see any of this code. The file says so
itself, at the marker block: "The observer lives in `app/`, which no test target compiles,
so these greps plus `TerminalBenchmarkMarkersTests` are the only guard."

**Correction.** The ideal fix as written does not work and would lose coverage. Moving
these facts "to `tests-ui/` beside the other AppKit tests" is impossible: the symbols do
not exist in that build. Deleting the 31 Swift greps would leave the benchmark
instrumentation -- window activation, occlusion sampling, marker scanning, the
`access` over `FileManager` choice, the plan/draw timer split -- with no witness of any
kind, in code that measures the numbers `agent-docs/terminal-performance.md` acts on.
Structure-sensitivity is a real cost here, but it is the price of asserting anything at
all about code no compiler in the gate ever sees, and it is why the 2026-08-19 rent audit
judged the file healthy.

What survives is small and specific: the three `$ROOT/justfile` greps for `benchmark-loop`,
`benchmark-sample`, and `benchmark-trace` (lines 125-127). Those recipes exist at
`justfile:236`, `:249`, and `:253`; the greps assert only that three names are spelled the
same in two files, which is precisely why the same audit deleted
`terminal-benchmark-commands_test.sh` ("Asserts literal command strings appear in the
`justfile` ... Renaming a recipe breaks it with nothing actually broken"). Delete those
three lines and nothing else. Impact drops to 1: it is a three-line subtraction that
removes one change-detector class the repo has already ruled on.

**Conflicts with.** Nothing. `PROBE-2` cites this file only as the style template for a
new probe assertion and does not edit it.

**Done.** Took the correction's scope exactly: lines 125-127 of
`scripts/tests/terminal-benchmark-harness_test.sh` are gone and nothing else changed. All
31 `$ROOT/app/*.swift` greps stay -- re-confirmed against the tree that every one of their
targets sits behind `#if DANTERM_TERMINAL_BENCHMARK` (`app/TerminalBenchmark.swift:13`,
`app/AppDelegate.swift:214`, `app/AppPresentationLifecycle.swift:110`), that the define is
set only at `scripts/terminal-benchmark.sh:202` and `:204`, and that neither
`Package.swift` nor the `justfile` sets it, so those greps really are the last witness.

The three deleted lines asserted only that `benchmark-loop`, `benchmark-sample`, and
`benchmark-trace` are spelled the same in two files that never call each other: the
recipes at `justfile:242`, `:255`, `:259` are reached from prose in
`agent-docs/terminal-performance.md` and from two `# Scenario:` comments in
`scripts/tests/terminal_btop_stimulus_test.py`, never from a script. `3d9561d0` already
deleted `terminal-benchmark-commands_test.sh` for exactly this, and `77cdabdf` reintroduced
the class here.

The deletion has no test of its own -- the property it removes is "a rename in the
`justfile` reddens the gate", which by construction has no behavioral home. Proof is the
self-test green and `just test` green. The structural fix for the surviving 31 is not this
item: give that arm a compiler by adding a type-check-only build with
`-Xswiftc -DDANTERM_TERMINAL_BENCHMARK` to the lint pass, which is the same move
[DRAW-3](#draw-3) already carries for the headless draw arm. Doing it there deletes the
whole change-detector class at once; doing it here would have widened a three-line
subtraction into a build-graph change with no shared root cause.

#### Dropped (GATE)

- **`ClientLivenessTests` sleeps 2.0-2.4s and asserts `observedPingCount >= 3`.** Looks
  like a race (the cadence is `bound / 2` per `IpcLiveness.swift#pingInterval`, so the
  margin is only about 2x), but `agent-docs/test-timing.md` explicitly permits "an
  assertion about a duration production itself defines", and the file's header already
  argues the margin choice: "The bounds are not as small as they could be, on purpose."
  Arguing it down would need a measured flake, which I have none of.
- **`terminal-fence-accounting-lint.sh` counts occurrences of `queue.sync {` and
  `countsAsProduction: true`.** Maximally structure-sensitive, and deliberately so: "So the
  shape is pinned rather than the behavior". It also has the `setup_fail` guard GATE-1
  wants everywhere, so it is the counter-example, not an instance.
- **`DanTermUITests` runs in neither `just test` nor CI** (`.github/workflows/ci.yml` never
  invokes `just test` at all). Not a defect: `gate-test-coverage-lint.py` forces the
  exclusion to be visible as a `--skip` in the step list, and `tests-ui/` was edited on
  2026-08-25, so someone is running `just test-ui`.
- **`reducer-command-discard-lint.sh:37` `[[ -e "$root" ]] || continue`.** Same shape as
  GATE-1, but its roots are `lib/DanTermCore/Sources` and `app` -- directories that cannot
  plausibly disappear without the build failing first. Folding it into GATE-1's shared
  helper is free; on its own it is not worth a finding.
- **`terminal-fence-accounting-lint.sh`'s `accounted_end` awk regex** requires the next
  declaration to be `private|package|public|internal (static )?func`, so a `func` with no
  access modifier silently widens the range check to end-of-file. Real, but the range check
  is a secondary assertion behind three exact-count checks, so nothing escapes because of
  it.
- **The 86 sub-5s gate steps that wait 559s to do 122s of work.** Already owned as an open
  item, section C of `docs/scratch/2026-08-19-gate-test-rent-audit.md` ("Batch the sub-2s
  lints and lint self-tests"). Still live in the tree; not re-reported here.
- **`scripts/tests/danterm-cli_test.sh` is not in the gate.** It carries the sanctioned
  marker (`# gate: opt-out -- requires a GUI and jq; runs through just test-cli`), which is
  the mechanism working.

