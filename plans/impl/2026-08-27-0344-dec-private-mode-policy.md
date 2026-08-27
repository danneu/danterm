# Declare each DEC private mode's policy once

Source findings: `docs/scratch/2026-08-26-improvement-audit.md#parse-4`,
`#grid-1`, `#parse-1`, `#select-4`, verified as one change with a pivot on
PARSE-4's mechanism.

## Problem

`Terminal.DECPrivateMode` names sixteen accepted DEC private modes. Three
exhaustive switches then say independently what each case means: one writes the
mode into `TerminalModes`, one reads it back for DECRQM, and one re-emits it for
state synchronization. Seven of the sixteen are a plain `Bool` on
`TerminalModes` and name the same stored property in all three. Nothing connects
those three statements, so a setter and its DECRQM answer can be wired to
different properties and every test still passes, and each new plain mode costs
three edits.

Three consequences are live in the tree:

- **Mode 47 is absent.** `CSI ? 4 7 h` and `CSI ? 4 7 l` are dropped by the
  setter's `guard let mode = DECPrivateMode(rawValue:) else { continue }`, and
  DECRQM answers "not recognized". A program that hardcodes the legacy
  alternate-screen switch draws its full-screen UI onto the primary grid and
  into scrollback, and restores nothing on exit. DanTerm publishes
  `smcup=\E[?1049h`, so the affected population is programs that hardcode `?47h`
  rather than read terminfo. All three references implement 47.
- **Mode 1047 clears the wrong edge.** `switchAlternateScreen(enabled:)` blanks
  the alternate grid on every entry and never on exit. xterm clears 1047 on exit
  (`charproc.c#srm_OPT_ALTBUF`: `if (screen->whichBuf) ClearScreen(xw)` before
  `FromAlternate`) and ghostty matches it. The deviation is observable today
  without 47, because `swapActiveScreen` retains the alternate grid in
  `.primaryLive(alternate:)` across an exit: `?1049h` + draw + `?1049l` +
  `?1047h` shows the leftover drawing under xterm and ghostty, and a blank grid
  under DanTerm.
- **Mode 1007 is absent.** `wheelRoute` converts wheel motion into cursor-key
  bytes whenever the alternate screen is active and mouse tracking is off, with
  no mode consulted. A child that resets alternate scroll still receives
  synthetic arrows. ghostty gates the same decision on
  `mouse_alternate_scroll` and foot on `alt_scrolling`; both default it on,
  which is DanTerm's current behavior.

### Load-bearing premise: why not PARSE-4's keypath table

`fea724c1 refactor(terminal): centralize mode state behind registry` had exactly
the keypath table PARSE-4 asks for -- `modeKeyPath(_:namespace:)` returning
`WritableKeyPath<TerminalModes, Bool>?` -- and `038ba535 refactor(terminal):
make mode policy exhaustive` deleted it on purpose
(`plans/impl/2026-08-23-1444-terminal-mode-catalog.md`). That table was keyed on
a raw `UInt16` and returned `nil` for anything it did not list, so a mode could
be missing from every consumer at once; exhaustive switches over a case enum fix
that.

Re-adding an optional keypath alongside the enum would undo it. A consumer that
reads `if let keyPath = mode.keyPath { ... } else { switch mode { ... } }` needs
a `default` arm to compile, and that arm is exactly the omission the exhaustive
switches prevent. The two properties are only compatible if the shortcut is
itself a total value.

## Decision

Give `DECPrivateMode` one exhaustive policy property returning a closed value
that says what the mode *is*. The three consumers switch over that policy, not
over the mode.

The policy has to separate two questions that the current switches conflate:
**where the mode's state lives**, and **what setting it additionally does**.
Keying only on "kind" would not pay off -- `origin` and `focusReporting` are
plain `Bool`s to DECRQM and to resynchronization and only their *setters* are
special (one homes the cursor, one emits a focus report), so giving them their
own kind would make all three consumers restate them again. Carrying the stored
location and the set-time effect as separate parts of one policy value absorbs
ten of the eighteen modes this change leaves declared into a single generic arm
per consumer, instead of seven.

Two things fall out of that split. The encoder's `enabled: Bool?` sentinel goes
away -- `nil` meaning "not a plain mode" becomes the policy's job. And the
encoder's hardcoded decision to skip focus reporting during an alternate-screen
replay stops naming mode 1004: it becomes the general rule that a mode whose set
emits a reply is omitted when the caller has already accounted for that reply.

This keeps `038ba535`'s property -- a newly declared mode must state its policy,
and the compiler says so -- while removing the restatement. A mode that stores a
`Bool` is one row and no consumer edit. A mode that needs a new kind of state, or
a new kind of set-time effect, still fails the build where that kind is
interpreted, which is correct: that is a genuinely new behavior, not a repeated
one.

The screen-switch modes get their three answers as data in the same shape:
whether the mode saves the cursor, whether it clears the alternate grid on
entry, and whether it clears it on exit. `switchAlternateScreen` reads those
answers instead of hardcoding an entry clear.

| mode | saves cursor | clears on entry | clears on exit |
|---|---|---|---|
| 47 | no | no | no |
| 1047 | no | no | yes |
| 1049 | yes | yes | no |

These are xterm's and ghostty's edges. Only the 1047 row changes DanTerm's
behavior; 1049 already matches. foot clears all three on entry and is the
outlier.

Two consequences of the table that are easy to miss and are part of the
contract. Re-entering a mode while the alternate grid is already live does
whatever that mode's entry answer says and nothing more, so `?1047h` twice
leaves the second entry's content alone while `?1049h` twice still saves the
cursor and clears -- xterm's `ToAlternate` is a no-op when already alternate and
1049's `ClearScreen` sits outside it. And a first entry to an alternate grid
that has never existed yields blank default-styled cells, not cells in the
current erase style, because no clear ran; only a clear paints the erase style.

Modes 47 and 1007 are then rows: `47` a screen switch, `1007` a plain `Bool` on
`TerminalModes` defaulting to `true`, surfaced on `TerminalInputModes` and read
by `wheelRoute`.

### The retained inactive alternate screen becomes state worth sending

State synchronization serializes the alternate screen only while it is *live*.
Everything the inactive alternate `ScreenState` retains -- its rows, its DECSC
slot, and its Kitty keyboard stack -- is therefore dropped, and all of it
survives a later re-entry.

Part of that is already a divergence on master. A clear on entry only blanks the
grid; it never touches the screen-scoped control state. So a source can leave the
alternate with a non-default saved cursor, synchronize while the primary is live,
and then have `?1049h` + DECRC restore that cursor and style where the replica
restores defaults. `TerminalResetTests.softResetSavedCursorScope` already pins
that the inactive alternate keeps its own slot.

This change widens the gap to the rows. Once neither 47 nor 1047 clears on entry,
a grid left behind by an earlier exit is content a program can bring straight
back on screen, and the replica would come back blank where the source shows the
old frame. That half arrives with the 1047 edge whether or not mode 47 lands.

RIS has to close the same gap from the other side. `hardReset` selects the
primary screen and erases only the live rows, so the retained alternate's rows
and semantic content survive a reset -- even though the same path already
resets that screen's `control`. The encoder opens with `ESC c ESC[3J`, so a
replica that holds an old alternate frame keeps it while the source's alternate
is blank, and no zero-byte encoding can ever correct that. Making RIS drop the
retained screen is the fix: it removes the state the divergence lives in rather
than obliging the encoder to emit a blank grid to overwrite it, and it is the
reset the offscreen `control` reset already implies.

So resynchronization reproduces every value the inactive alternate screen
retains, not just the rows. Mode 47 is the primitive that makes the rows cheap:
it is the only switch that neither saves the cursor nor clears, which is exactly
what painting an offscreen grid needs. An inactive alternate that is blank *and*
holds default screen-scoped state still costs no bytes; a blank one with a
non-default saved cursor does not.

One site keeps naming a mode by hand and must go on doing so: the encoder's
re-entry into a *live* alternate screen. It has to stay 1047 -- 1049 would save
the cursor into the primary slot it has just replayed and corrupt it, and 47
would not do the job the replay depends on. That constraint belongs in a comment
at the site, because it is the one place the policy value cannot express.

## Behavioral scope

- `CSI ? 47 h` switches to the alternate grid carrying the live cursor, clears
  nothing, and shows whatever that grid last held; `CSI ? 47 l` returns to the
  primary grid; DECRQM `?47` reports the active screen.
- `CSI ? 1047 l` clears the alternate grid on the way out; `CSI ? 1047 h` no
  longer clears on the way in.
- RIS drops the retained inactive alternate screen outright instead of leaving
  its rows and semantic content behind. A reset terminal is indistinguishable
  from a fresh one.
- `CSI ? 1007 l` makes wheel motion over an active alternate screen route to the
  local viewport instead of emitting cursor keys; `CSI ? 1007 h` restores it. It
  defaults to set, is reported by DECRQM, and round-trips through state
  synchronization.
- The engine contract table in
  [docs/design/2026-08-06-swift-terminal-engine.md](../../docs/design/2026-08-06-swift-terminal-engine.md)
  gains the alternate-scroll rule beside G8, which today states only the
  mouse-reporting wheel case and leaves the alternate-screen wheel route
  unwritten.
- The windows-terminal conformance ledger
  (`lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/windows-terminal-manifest.json`)
  stops recording alternate scroll as a deviation, and its
  `AlternateScrollModeTests` case stops being out-of-scope.
- Nothing else about mode set/reset, DECRQM, replies, mouse exclusivity, reset
  defaults, or synchronization ordering changes.

## Invariants

- **I1. One declaration.** Each accepted DEC private mode states its policy in
  exactly one place. No consumer restates what a mode means, and none carries a
  catch-all arm that would let a declared mode go unanswered.
- **I1b. The mouse trio is one unit.** The three mouse-tracking modes are
  mutually exclusive, so resynchronization emits them as a single
  neutralize-then-select block exactly once, not once per mode. Emitting them
  independently is wrong, not merely redundant: a per-mode walk in declaration
  order resets the very mode it just selected for every state except the last
  one declared. The block's correctness does not depend on the declaration
  order of the three modes.
- **I2. Exhaustive policy.** Adding a mode whose state and set-time effect are
  both kinds that already exist requires no consumer edit. Introducing a new
  kind of either fails to compile until the consumers that interpret that kind
  answer it.
- **I2b. Reply-emitting modes.** A mode whose set emits a reply is identified as
  such by its policy, and resynchronization omits exactly those modes when its
  caller says the reply is already accounted for. No consumer names a specific
  mode to get that behavior.
- **I3. Screen-switch answers.** The three alternate-screen modes differ only in
  the three answers of the table above, read from one declaration by both the
  set/reset path and the query path.
- **I3b. A switch that switches nothing still has effects.** Whether or not a
  grid swap happens, a recognized screen-switch sequence records full damage and
  ends deferred wrap and grapheme attachment -- so `?1047l` on the primary
  screen still lets the next character wrap. Selection and search are discarded
  only when the alternate is being entered or is currently live, so `?1049l` on
  the primary preserves them. Entering saves the cursor and clears the grid
  according to the mode's answers even when the alternate is already live, so
  `?1049h` twice clears twice. The semantic-content reset to `.output` belongs
  to the clear, not to the entry: a mode that clears nothing leaves the entered
  screen's semantic content as it was, so `?47h` carries back a retained
  prompt-owned region and `?1049h` does not.
- **I4. Alternate scroll.** While the alternate screen is active and mouse
  tracking is off, the wheel emits cursor keys only when mode 1007 is set; the
  mode is set by default.
- **I5. Existing behavior.** Mode state, replies, focus-enable reporting, mouse
  exclusivity, alternate-screen cursor handling, mode reset defaults, and
  compound left-to-right parameter effects are unchanged. RIS is the one reset
  edge that changes: it drops the retained inactive alternate screen.
- **I5b. Synchronization emission order.** The order carries four constraints:
  mouse-tracking neutralization precedes the selected mouse mode; the
  cursor-blink mode precedes the cursor-style sequence that shares its state;
  origin mode precedes the final live-cursor address that it reinterprets; and
  the inactive-alternate replay completes before any of the primary's live
  cursor, pending wrap, pen, or mode reconstruction. The last one is not
  cosmetic: a screen switch carries the live cursor across and drops pending
  wrap, and painting an offscreen grid needs neutral wrap, origin, and insert
  modes and a default pen, so a replay placed after the primary's
  reconstruction silently corrupts it.
- **I6. Synchronization completeness.** A replica fed
  `stateSynchronization().bytes` reaches the source's mode state, mode 1007
  included, and both of the source's screens. That includes an alternate screen
  the source retains but is not currently showing, and for it every value that
  survives re-entry: its rows, its DECSC slot, its Kitty keyboard stack, and its
  semantic state. Convergence is judged by what later public wire operations can
  observe, not by the rows alone.
- **I7. Reset ownership.** DECSTR and RIS keep resetting mode state through the
  default `TerminalModes` value, not through a policy walk.

## Proof obligations

- **PO1 (I1, I2).** The DECRQM contract test keeps hand-written literal
  expectations for every mode -- so an expectation can never be derived from the
  code under test -- and additionally asserts that the set of declared
  `DECPrivateMode` raw values equals the set the table covers. A mode declared
  with no row fails; a mode whose DECRQM answer reads a different property than
  its setter writes fails.
- **PO2 (I3).** Behavioral coverage of the three clear edges through wire
  sequences alone: entering 47 after an exit shows the retained alternate
  content; exiting 1047 blanks it; entering 1047 does not; 1049 still saves and
  restores the cursor and clears on entry. `?47h` carries the live cursor and
  `?47l` returns the primary text.
- **PO3 (I4).** With the alternate screen active and mouse tracking off, a wheel
  sample routes to the child as cursor keys with 1007 set and to the local
  viewport with 1007 reset, and DECRQM reports 1007 as set on a fresh terminal.
- **PO4 (I2b, I3b, I5, I5b).** The existing mode, query, mouse, saved-cursor,
  alternate-screen, dispatch-order and reset suites pass. Only assertions that
  state one of the changed behaviors may be edited: the ones pinning 47 as
  inert, any pinning RIS as leaving the retained alternate rows, the ones
  pinning 1047's entry clear -- including its erase style, since a first entry
  now yields default-styled cells where the clear painted the background erase
  style -- and the conformance ledger's alternate-scroll entries. Every other
  `?1047h` in the suites must keep passing untouched, since they enter a
  never-used alternate grid under a default pen. Mode 47 is
  the larger share of that churn, because several suites use `?47h` / `?47l` as
  a known-inert pair to prove that something else survives; each of those needs
  a different inert sequence rather than a relaxed assertion.
- **PO4b.** An assertion that survives the change only by becoming vacuous is
  not evidence. Any test whose subject was reachable only because the alternate
  grid was cleared on entry keeps exercising its subject, or says in its
  preamble what it now proves instead.
- **PO5 (I6).** The synchronization round-trip proof covers a non-default 1007
  alongside the modes it already covers -- non-default, because a mode both
  sides default to and the encoder emits unconditionally would compare equal
  without proving anything. It also covers two inactive-alternate scenarios,
  both judged through later public wire operations rather than by inspecting the
  encoded bytes:
  - A source that drew on the alternate screen and left it, with non-default
    semantic state at the point of exit -- prompt- or input-owned rows, not
    `.output`. Its primary is not quiet: pending wrap set, a non-default pen,
    origin mode on, and a non-default primary DECSC slot, so a replay ordered
    after the primary's reconstruction (I5b) fails here. Source and replica must
    agree on what a later `?47h` shows, on the primary's own live state, and
    must still agree after the resize that reflows prompt-owned rows
    differently, which is what makes the semantic value observable.
  - A replica pre-dirtied with its own alternate content before it is fed the
    bytes, against a source whose alternate is blank. They must agree on what a
    later `?47h` shows. This is what proves the zero-byte rule: it fails unless
    RIS drops the retained screen.
  - A source that left the alternate screen *blank* but with non-default
    screen-scoped state -- a saved cursor at a non-default position and style,
    and a non-empty Kitty keyboard stack. Source and replica must agree after a
    later `?47h` followed by DECRC and a Kitty keyboard query. This scenario
    fails on master, so it also pins the pre-existing half of the gap.
- **PO6 (I1b).** The round-trip proof already walks every mouse-tracking state;
  it must keep doing so, since that is what catches a per-mode emission of the
  exclusive trio.
- **PO7 (I4).** The alternate-scroll field is proved through the projected input
  modes as well as through the wheel route, so the projection does not pass
  merely by both sides holding the default.
- **PO8.** `just test` passes before each commit.

## Non-goals

- XTSAVE / XTRESTORE (`CSI ? Ps s` / `CSI ? Ps r`). DanTerm implements neither;
  foot saves 1007 there, and adding that surface is separate work.
- Changing DECRQM's status 0 for 1048 or status 3 for 2027.
- Gating the keyboard scroll route (`decideTerminalKey`) on 1007. ghostty gates
  only the wheel.
- Making the alternate-scroll default configurable. xterm's `alternateScroll`
  resource defaults false; DanTerm keeps the current always-on behavior as the
  default, matching ghostty and foot.
- Reworking `TerminalModes` storage or the ANSI mode enum beyond what the policy
  value needs.

## Accepted risks

- **AR1. A program using 47 changes behavior.** Its output moves from the
  primary grid and scrollback to the alternate grid, and is no longer retained.
  That is the fix, and it is why the change is visible.
- **AR1b. DECSTR resets alternate scroll to on.** DanTerm resets every mode
  through the default `TerminalModes` value (I7), so a soft reset restores 1007
  along with everything else. In xterm the mode is backed by a resource that
  DECSTR does not touch. Keeping the house rule is deliberate; a mode whose
  reset behavior must differ would have to split the one reset path, which is
  not worth it for this mode.
- **AR2. The 1047 clear edge is a behavior change with no reference-independent
  proof.** xterm and ghostty agree and foot disagrees; the plan takes the
  majority and records it here so a future report of "1047 does not clear on
  entry" is answered by this decision rather than reopened.

## Rejected ideas

- **RI1. An optional keypath on the enum** (PARSE-4 as written). Restores the
  `default` arm that `038ba535` removed; see the premise above.
- **RI2. A separate side table for the screen-switch modes.** Two competing
  side tables over one enum is the shape the audit warns against; the screen
  answers are one `ModePolicy` case.
- **RI3. Add 47 by routing it to the existing `switchAlternateScreen`.** The
  named cheaper fallback. It clears the alternate grid on entry, which is
  precisely what 47 must not do.
- **RI4. Drop mode 47 to avoid the resynchronization gap.** The gap arrives with
  the 1047 clear edge on its own, so dropping 47 does not close it -- it only
  removes the primitive that makes closing it cheap.
- **RI5. Give the alternate-scroll mode storage outside `TerminalModes` so soft
  reset leaves it alone.** It would buy xterm's DECSTR behavior at the price of
  a bespoke policy kind for one mode, losing the one-row property this change
  exists for. See AR1b.
- **RI6. Drive the DECRQM roster from `allCases` alone.** The expected values
  would then come from the code under test; the completeness assertion in PO1
  buys the coverage without that.

## Implementation discretion

- Where the mode vocabulary lives. `Terminal.swift` is ~8.8k lines and the
  policy value, the two mode enums and the screen-switch answers are one
  cohesive unit; extracting them to their own file is fine and so is leaving
  them nested.
- Test grouping. The obligations above must be proved through public behavior
  and wire sequences, not through the policy value's shape.

## Commit progress

- [x] **1. The policy value.** `ModePolicy`, `DECPrivateMode.policy`, and the
  three consumers rewritten to switch over it. No behavior change; every
  existing suite passes unedited, and PO1's completeness assertion lands here.
- [x] **2. The screen-switch answers, mode 47, the 1047 edge, and the inactive
  alternate screen in state synchronization.** Proves PO2 and the
  inactive-alternate half of PO5, and replaces the test that pins 47 as
  unrecognized. One commit, not two: the same edge that makes the retained rows
  observable is the edge that makes the replica diverge, so splitting them would
  ship a commit that is known not to converge. The RIS drop of the retained
  screen lands here too, for the same reason.
- [ ] **3. Mode 1007.** The mode row, the `TerminalInputModes` field,
  `wheelRoute`, the engine contract row, and the conformance ledger entries --
  both the manifest JSON and the `TerminalFixtureTests` assertion that pins its
  deviation wording.
  Proves PO3, PO7, and the 1007 half of PO5.

## Implementation notes

- Commit 1's screen-switch policy carries only the `savesCursor` answer, not the
  full three-answer table. That is the minimum the three consumers need to stop
  restating 1047 against 1049 while the commit stays behavior-preserving; the
  clear-on-entry and clear-on-exit answers belong to commit 2, which is where
  they first change anything.
- `ModeSetEffect.emitsReply` is derived with a `switch`, not an `==` against
  `.reportFocus`, so a new kind of set-time effect fails to compile there rather
  than silently answering "no reply" (I2).
- Synchronization emits the mouse trio at the first mouse-tracking mode the
  catalog walk reaches, guarded by a flag, and the block itself reads the trio
  back out of the catalog instead of naming the three modes. That satisfies I1b
  without depending on declaration order, and reproduces master's byte order
  exactly.
- The encoder now names a mode by hand at two sites, not one. The retained
  inactive alternate is replayed through mode 47 by name, for the same reason
  1047 is named at the live re-entry: the policy value says what each mode
  *does*, not which mode an encoder should use as an instrument. Reading the
  47-shaped switch back out of the catalog would need a partial lookup with a
  crash path, which buys less than it costs; the round-trip proofs fail if that
  mode's answers ever change under it.
- The zero-byte rule for a pristine retained alternate is a comparison against a
  freshly created `ScreenState`, taken in `Terminal` rather than in the encoder,
  which has no way to build a blank row. Cursor and pending wrap are excluded
  because a screen switch carries the live cursor and drops pending wrap, so
  neither can differ observably after re-entry.
- Two existing suites used `?47h` / `?47l` as a known-inert pair to prove that
  something else survives; both moved to `?2047h` / `?2047l`, which no reference
  implements. The byte-exact synchronization expectation in
  `TerminalViewportRotationTests` gained the mode-47 replay block, because that
  terminal retains an alternate screen.
- The DECRQM roster test's unknown-mode row (42) moved out of the literal table
  into the loop's input, so PO1's completeness assertion can compare the table
  against `allCases` directly. The assertion was confirmed to fail, and to fail
  alone, with one declared mode's row removed.
