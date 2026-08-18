# iOS shell: full-bleed terminal, floating chrome, session-controller extraction

## Context

The iOS client (`ios/DanTermMobileApp`) stacks five permanent bands:
connection header, pane table (80-150pt), terminal, claim bar, composer. The
terminal — the thing the user reads constantly — pays permanent vertical
chrome for controls used occasionally. The goal: the terminal fills the full
width and runs from the physical top of the viewport down to the bottom
controls, following the iOS full-bleed-content convention (chrome floats over
content or lives in sheets, as in Maps and shipping iOS terminals).

A second, structural problem: `MobileRootViewController` (678 lines) owns both
the connection lifecycle (policies, runner, checkpointing, input mapping) and
all view wiring. Splitting the UI into a terminal screen plus transient sheets
requires several surfaces to observe the same facts, which single-VC ownership
cannot serve.

CI context: `scripts/ios-portability-gate.sh` already cross-compiles the whole
app package for the iOS device triple on every `just test`, and the
`DanTermMobileKit` test suite runs in the gate. The app target has no unit
tests; behavioral proof is `scripts/ios-app.sh simulator` with
`DANTERM_IOS_HOST/PORT/SMOKE_INPUT`.

## Decision

Terminal-first, sheet-based navigation. No UINavigationController /
NavigationStack: there is one terminal the user lives in and two transient
pickers — the full-bleed-plus-sheets shape, not a drill-down. All new UI is
programmatic UIKit, matching the shell.

1. **Session decision core in MobileKit.** `MobileRootViewController`'s
   session half moves into a pure `DanTermMobileKit` boundary shaped like the
   Mac core: a session model plus
   `update(&model, event, env) -> [MobileSessionEffect]`. Every input becomes
   an event — UI (draft edits, connect, pane selection, claim/release, input),
   lifecycle (foreground, background), timer expiry, network path change,
   runner frames and failures, and surface layout. The model owns the connect
   target, reconnect/resume policy state, `MobileStatus`, pane list and
   selection, and pane replicas; it composes the existing MobileKit policies
   rather than replacing them. Effects are the only way anything leaves the
   model: send a request, connect, disconnect, flush a checkpoint, arm or
   cancel a timer, redraw. Resize authority is a type, not a convention: the
   ordinary event type is handled by an entry point whose effect type has no
   resize case, and only the claim/release event type reaches the entry point
   whose effect type adds one. The interpreter's array is the wider type, and
   ordinary results are widened into it, so there is still one effect stream
   and one perform loop — but no ordinary branch can return a resize, because
   its return type cannot hold one (I10). Policy state stays model state: the
   background event updates the reconnect policy in place and is never asked
   to announce it as an effect.
2. **Thin app-shell interpreter.** A `@MainActor` `MobileSessionController`
   holds what cannot be pure — runner thread, deadline timer, path monitor,
   checkpoint file IO, and the `TerminalSurfaceView` — and does one job: turn
   a callback into an event, call `update`, and perform the returned effects
   in array order in a single loop. It makes no decision of its own, holds no
   session fact the model owns, and never touches a view's text or layout
   outside of performing a redraw effect. UI surfaces send events in and
   render projections the model publishes. This keeps every invariant the gate
   must prove inside MobileKit, which matters because the app package is an
   iOS-only executable with no test target.
3. **Shared content-box value.** A new pure `DanTermMobileKit` type computes
   the pixel content box (bounds, safe-area insets, display scale → pixel
   size and origin offsets). Both grid readings in `TerminalSurfaceView` —
   the claim's `nativeGrid` and the drawing fit — plus the layer position
   consume this one value, so the claim/draw agreement (I3) holds by
   construction rather than by two call sites agreeing.
4. **Full-bleed terminal.** Terminal top anchors to the window's top edge,
   100% width, bottom to the bottom bar. Background paints edge to edge; grid
   cells inset by top/side safe-area insets. Status bar content stays legible
   over the dark surface.
5. **Status pill + connect sheet.** `ConnectionHeaderView` is deleted. A
   floating pill overlays the top safe area showing the connection status
   line plus the selected pane's title (composed in the shell —
   `MobileStatus` keeps its four facts and is not extended). Tapping the pill
   presents a connect sheet (`UISheetPresentationController`) holding
   host/port/Go, the draft-problem label, and status detail. Draft problems
   render only inside the sheet, beside their fields.
6. **Pane sheet + claim menu.** The pane table is deleted; a pane-picker
   sheet opens from the bottom bar and dismisses on selection. The claim bar
   is deleted; Claim/Release become menu items in the bottom bar, projected
   from the existing `MobileClaimControl`.
7. **Composer retired.** `TerminalComposerView` is deleted. A focus-owning
   view adopting `UIKeyInput` makes the terminal the text-input target: tap
   terminal to raise the keyboard, paste via the responder edit actions,
   hardware keys handled on the same responder. The accessory key row
   (Esc/Ctrl/Tab/arrows/`|`/`~`//) survives as the bottom bar, joined by the
   pane-sheet button, the overflow menu, and keyboard dismissal. The bar
   stays pinned above the keyboard via `keyboardLayoutGuide`.

Sequencing constraints (each step leaves the app shippable via
`scripts/ios-app.sh simulator`): the session model and its interpreter land
first, with the existing views wired to events unchanged; the content-box type
lands and is adopted (with all-zero insets) before the terminal goes
full-bleed; composer retirement goes last, so the proven input path survives
until everything else works.

## Invariants

- I1: The terminal surface spans the window's full width and runs from the
  window's top edge to the top of the bottom bar; no persistent chrome
  occupies vertical space above it.
- I2: The terminal background paints to the physical edges; grid cells never
  render under the top or side safe-area insets, including after inset
  changes that arrive without a bounds change.
- I3: The grid a claim names and the grid the surface draws derive from the
  same content-box value at the same metrics.
- I4: Connection, pane, and status facts have one owner, the pure session
  model. The app-shell interpreter stores no such fact and makes no session
  decision; every visible control is a projection recomputed from the model,
  never remembered UI state.
- I5: Input parity: typed text (including the return key's `"\n"` text
  form), accessory keys, the Ctrl latch (accessory keys only, as today),
  paste, scroll, and hardware keys keep their exact wire effect; no
  autocorrect, smart punctuation, or capitalization is introduced. The one
  intentional addition: backspace from the software keyboard maps to the
  existing `bspace` key encoding.
- I6: Claim/Release are offered exactly when `MobileClaimControl` offers
  them, and a menu item carries an event, never a request built when the menu
  was opened. The model decides at the moment it handles the event, from the
  facts it holds then, so a tap after the pinned or connection state changed
  either recomputes the request or returns nothing.
- I7: The bottom bar's height is constant regardless of which actions are
  offered, so the terminal extent — and with it the claimable grid — never
  moves when an action appears or disappears.
- I8: The connection status line is visible whenever the terminal screen is,
  including while a sheet is presented.
- I9: Launch behavior: a host supplied by `DANTERM_IOS_HOST` or stored from a
  prior session auto-connects with no sheet (the smoke path must not stall
  behind a sheet); only a missing host presents the connect sheet. An empty
  `DANTERM_IOS_HOST` counts as absent, not as an authoritative empty host:
  `scripts/ios-app.sh simulator` always installs the variable and passes an
  empty string when the caller omits it, so a present-but-empty value must
  fall through to the stored host.
- I10: A pane resize leaves the phone only as an effect returned from the
  claim/release entry point, and the compiler is what enforces it: a layout,
  keyboard, reconnect, lifecycle, timer, or frame event is handled by an entry
  point whose effect type has no resize case, so such a branch cannot return
  one whatever it constructs. The interpreter sends only what the model
  returns (the existing claim-gesture contract survives the migration).
- I11: Backgrounding behavior is unchanged. The background event updates the
  reconnect policy in the model — the drop was the app's own, so a reconnect
  is owed on foreground — and returns exactly two external effects in order:
  checkpoint flush, then disconnect. The interpreter performs the effect array
  in order, so the performed order is the returned order. Policy state is
  never an effect; the interpreter mutates no model state.

## Proof obligations

- PO1 (I3): MobileKit test that the claim grid and the drawing fit agree for
  content boxes with non-zero insets across display scales, and that
  degenerate boxes (no room for a whole cell) yield no claim.
- PO2 (I2): MobileKit test that the content box contains the drawn cells
  conservatively at fractional insets and non-integral scales — no drawn
  pixel falls inside a top or side inset after rounding — and that
  recomputing at unchanged bounds with new insets yields a different box, so
  an inset-only update cannot return a stale value.
- PO3 (I9): MobileKit test pinning the launch decision over four cases: env
  host, empty env host with a stored host, empty env host with none stored,
  and no env var at all.
- PO4 (I5): MobileKit test for the backspace mapping, written before the
  shell adopts it; existing `InputMappingTests` stay green as the parity pin.
- PO5 (I11): MobileKit test that the background event returns exactly
  checkpoint flush then disconnect, in that order, and leaves the model's
  reconnect policy owing a reconnect on foreground — proved by then handling
  the foreground event and observing the reconnect. Existing policy suites
  stay green unchanged.
- PO6 (I10): the negative half needs no test — an ordinary event's effect
  type has no resize case, so a branch that tried to return one would not
  compile. MobileKit tests cover the positive half: a claim event returns the
  resize carrying the grid the surface draws, a release returns the fit form,
  and neither returns one when the claim control offers nothing.
- PO7 (I6): MobileKit test that handles a claim event after the facts that
  offered it changed (pane unpinned by the Mac, pane gone, connection
  dropped) and asserts the model recomputes the request from current facts or
  returns none — never the request the earlier facts would have produced.
- PO8 (I5): simulator probe that enters through the new responder instead of
  the mapper: `DANTERM_IOS_SMOKE_INPUT` drives `insertText`, the return key,
  `deleteBackward`, and a paste on the terminal's input responder, and the
  resulting pane input is observed. Hardware-key forwarding is verified
  manually in the same run.
- PO9 (I1, I2, I7, I8): manual verification on the simulator (see
  Verification); these are visual claims with no unit surface.

## Non-goals

- iPad layout, multiple windows, multiple saved servers, todos or
  agent-activity screens.
- SwiftUI adoption.
- IME/marked-text composition and dictation quality: the current composer
  already defeats marked text (it rejects every text change and forwards
  keystrokes immediately), so `UIKeyInput` preserves the status quo.
- Fixing the stale retry-countdown rendering between events (pre-existing).
- Changing the return-key encoding or making the Ctrl latch apply to typed
  text (each would be its own tested change).
- Any change to the wire protocol, the Mac side, or MobileKit policy
  semantics.

## Accepted risks

- AR1: A pane pinned to the phone's old grid keeps it after the layout makes
  the terminal taller, until the user re-claims. The claim is a deliberate
  gesture by contract, so no automatic re-claim is added.
- AR2: While a sheet's own keyboard is up, the presenting screen's bottom bar
  tracks it and the hidden terminal refits. Cosmetic and idempotent; only
  worth code if it proves noisy on device.
- AR3: The gate cross-compiles the device triple only; simulator-only
  breakage is unprotected (same source, low likelihood).

## Rejected ideas

- RI1: Navigation stack with a pushed terminal — the interactive pop gesture
  fights terminal input, and the nav bar spends the pixels being reclaimed.
- RI2: Extending `MobileStatus` with the pane title — it deliberately owns
  four facts with one writer each; the pill composes title + status in the
  shell.
- RI3: Sheet-aware pausing of the display link — the presentation policy
  already damage-gates ticks; a second pause authority risks stale frames on
  dismissal.
- RI4: Full `UITextInput` with a client-side composition buffer is the ideal
  input path (real IME support) and remains the named follow-up; deferred
  because today's composer already breaks composition, so it is not a
  regression gate for this migration.

## Verification

- `just test` — MobileKit tests (PO1-PO7), iOS device-triple cross-compile of
  the app package, portable-profile purity lint on MobileKit.
- Manual, per shippable step and at the end: enable the `tailnet` listener on
  a dev slot, run `DANTERM_IOS_HOST=<host> scripts/ios-app.sh simulator`
  (with `DANTERM_IOS_SMOKE_INPUT`, which after composer retirement enters
  through the terminal's input responder — PO7), and verify:
  full-bleed terminal with no cells under the Dynamic Island and a legible
  status bar; pill status + pane title, visible during sheets; connect sheet
  auto-presents only with no host; pane switch via sheet; Claim/Release via
  menu reflecting current facts, including a menu left open while the Mac
  releases the pane; keyboard raises on terminal tap and the key row rides
  above it; hardware-keyboard mode still delivers named keys and
  Ctrl-modified characters; rotation, including one that changes only the
  safe-area insets, after which every cell stays clear of them.

## Implementation discretion

- Event and effect case names, how the model publishes projections
  (observation callback shape), pill and sheet visual styling, menu
  construction details, first-responder restore choreography around sheet
  presentation.

## Commit progress

- [x] 1. refactor(ios): give the phone session one pure decision core
- [x] 2. refactor(ios): derive the phone's grid from one content box
- [x] 3. feat(ios): run the terminal full-bleed under a floating status pill
- [ ] 4. feat(ios): move pane choice and claim into the bottom bar
- [ ] 5. feat(ios): make the terminal itself the text-input target

## Implementation notes

- Commit 1: two effects that act on a view or a file answer back as events rather
  than returning a value, because the model has to decide what follows them.
  `attachPane` is answered by `paneAttached`, which carries the cursor the surface
  resumed at and is what the tape subscription is built from; `applyRecord` is
  answered by `recordApplied`, which is where the stream's own end record ends the
  connection. The alternative -- letting the interpreter read the cursor and build
  the subscription -- would move the history budget and the resume decision out of
  the model.
- Commit 1: `MobileOrdinaryRequest` is what makes I10 a compile-time fact rather
  than a convention. An ordinary effect carrying a bare `IpcRequest` would let any
  branch construct a resize and send it through the ordinary channel, so the
  ordinary effects carry a wrapper whose only constructors are pane input and the
  tape subscription.
- Commit 1: the interpreter queues events and drains them in one loop. A perform
  can produce an event (a failed write, a record the replica refused, a layout the
  surface reports from inside `apply`), and without the queue those would re-enter
  `handle` in the middle of an effect array.
- Commit 1: `MobileSessionController.deinit` writes the checkpoint unconditionally
  instead of consulting the model's dirty bit, because the model cannot be advanced
  from a deinit. The snapshot is only taken when the replica is exact, so the cost
  is one repeated write at process teardown.
- Commit 1: the target fields are still filled once from the launch plan and left
  alone afterwards. The draft is a model fact, but the field is its editor, and a
  redraw arriving mid-edit must not rewrite what the user is typing. Commit 3 moves
  the fields into the connect sheet, which is where that gets its own answer.
- Commit 2: `MobileObserveSurface`'s pixel-extent initializer was replaced by the
  content-box form rather than joined by it. Keeping both would leave the view a second
  way to describe its own extent, which is the exact split I3 exists to close.
- Commit 2: the box takes four named inset values rather than a `UIEdgeInsets`, because
  MobileKit is portable and links no UIKit. It applies all four, though I2 only names the
  top and the sides; the shell passes zero for the bottom, so the extra axis costs
  nothing and the type does not have to know which edges the layout happens to use.
- Commit 2: `TerminalSurfaceView` passes all-zero insets for now, per the plan's
  sequencing constraint. Commit 3 is where the real safe-area insets arrive.
- Commit 3: the pane table had to leave the top of the window for the terminal to reach
  it, so it moved into the bottom stack between the terminal and the claim bar. It is
  deleted in commit 4; until then the terminal's bottom is the table's top rather than
  the bottom bar's, which is the one part of I1 this commit cannot finish.
- Commit 3: the surface reports its own layout now, through a `didLayout` callback the
  session controller wires, instead of the view controller calling in from
  `viewDidLayoutSubviews`. A subview's safe-area insets are resolved after its superview
  lays out, so the controller's callback would read the grid one pass stale -- harmless
  while the insets were zero, and wrong now that they decide the claimable grid.
- Commit 3: the launch offers the connect sheet when the model holds no host *or* holds a
  draft problem. The plan names only the missing host (I9), but with the problem label
  moved into the sheet, a launch whose stored or environment port is unusable would report
  a problem with no surface to read it on. Both cases are the same fact: the launch could
  not name a server.
- Commit 3: the pill sits just below the status bar, which puts it over the first rows of
  cells rather than inside the top inset -- the inset itself is where the clock and the
  Dynamic Island are. It takes no layout space, which is what I1 requires; floating over
  content is the shape the plan's context asks for.
- Commit 3: the connect sheet states `overrideUserInterfaceStyle = .dark` itself and paints
  an explicit near-black rather than `.systemBackground`. A presented controller does not
  inherit the presenter's override, and a system background color under a sheet resolved
  light over the terminal's black.

## Follow Up

- `scripts/ios-portability-gate.sh` reported a false failure twice in a row for
  `ios/DanTermMobileApp`: its cached build plan under
  `ios/DanTermMobileApp/.build-ios-gate/debug.yaml` kept a stale source list for the
  `DanTermMobileKit` path dependency, so a newly added file in that package was never
  compiled and every reference to it failed. Deleting `debug.yaml` fixed it. The gate
  reuses a per-package scratch path on purpose (step isolation), so it needs a way to
  force a re-plan when a path dependency's source list changes.
