# Terminal mode registry

Source finding: docs/scratch/2026-08-11-simplification-audit.md S15 (ideal fix).

## Problem

The same set of terminal modes is enumerated by hand in five disjoint places in
`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`: the loose stored flags
(lines 715-728), the setter switches (`applyDECPrivateModes`, `applyANSIModes`),
the DECRQM reporters (`decPrivateModeStatus`, `ansiModeStatus`), the reset list
(`resetControlState`), and the `inputModes` projection. Nothing ties a mode
number to its storage, so adding or changing a mode means editing up to five
lists with no compiler signal when one is missed.

The drift this shape produces is already live: `isCursorBlinking` exists and is
written by DECSCUSR, but `CSI ?12h/l` (xterm/ghostty cursor-blink mode,
`references/ghostty/src/terminal/modes.zig#modes` value 12) is silently dropped
and DECRQM `?12` answers 0 even though the state it targets exists.

## Decision

Move all terminal-scoped mode state into a `TerminalModes` value type
(`Equatable`, `Sendable`), stored as one property on `Terminal`, whose default
value IS the reset state. Membership: the twelve mode flags, plus
`mouseTrackingMode`, `cursorShape`, and `isCursorBlinking` -- including the
fields with no mode code (`isApplicationKeypadMode`, `cursorShape`) -- so that
resetting mode state is a single whole-value assignment rather than a hand-kept
list.

Define one lookup mapping mode code + DEC-private/ANSI dispatch to a
`WritableKeyPath<TerminalModes, Bool>`. It must be a function, not stored state:
`WritableKeyPath` is not `Sendable`, so a `static let` table or array fails Swift
6 concurrency checking and would force a `nonisolated(unsafe)` escape hatch. Set
(DECSET/DECRST, SM/RM), DECRQM
reporting, and reset all derive from it for the Bool-backed coded modes
(DEC 1, 6, 7, 12, 25, 1004, 1006, 2004, 2026; ANSI 4, 20). The modes whose
semantics exceed a flag write stay as explicit arms layered on top: the side
effects of 6 and 7, the screen/cursor dance of 1047/1048/1049, and the
mutually exclusive mouse trio 1000/1002/1003 (which stays one enum).

Close the `?12` gap as the final, separately committed behavioral slice:
`CSI ?12h/l` toggles cursor blink and DECRQM `?12` reports it. Everything else
is behavior-neutral.

## Invariants

- I1: Every Bool-backed coded mode has exactly one registry entry from which
  set, DECRQM report, and reset all derive -- a registered mode cannot be
  settable-but-unreportable, or reportable-but-unreset.
- I2: All currently pinned mode behavior is unchanged: DECRQM replies
  (including 0 for 1005/1015/1048 and ANSI 12), mouse-mode exclusivity and
  encoding isolation, inputModes projection, and every mode fixture.
- I3: DECSTR and RIS restore every mode to its default via one whole-value
  assignment of the default `TerminalModes`; non-mode reset state (scroll
  region, tab stops, current style, kitty stacks) and the saved cursor keep
  today's behavior exactly.
- I4: Mode state stays terminal-scoped (shared across alternate-screen
  switches); the saved-cursor copies of origin/visibility/shape/blink stay
  per-screen and independent.
- I5: `Terminal` equality still distinguishes any mode change from a fresh
  terminal (synthesized `==`; the modes value participates).
- I6 (new behavior): `CSI ?12h` / `?12l` set/clear cursor blink, DECRQM `?12`
  reports 1/2, DECSCUSR continues to write shape and blink as a pair, and the
  two writers compose last-writer-wins, matching ghostty's `cursor_blinking`
  mode. Reset default stays blink-off.
- I7: The public `TerminalInputModes` surface and its consumers are untouched.

## Proof obligations

- PO1 (I2, I3, I4, I5, I7 -- behavior neutrality): the existing suites pass
  without expectation edits -- TerminalModeTests, TerminalQueryTests,
  TerminalMouseModeTests, TerminalPresentationModeTests, TerminalResetTests,
  TerminalKittyKeyboardTests, and the fixture suite (state-mode, state-mouse,
  state-input, state-save, the alacritty inputModes recordings).
- PO2 (I1): every registry-covered code appears in a DECRQM set/reset
  assertion; extend the literal tables in TerminalQueryTests where a registered
  code is not already asserted there or in TerminalMouseModeTests. The tables
  stay literal, independent of the registry.
- PO3 (I6): failing-first tests for `?12` -- set/report/reset round-trip and
  the DECSCUSR interaction -- written before the behavior lands (repo TDD
  rule).

## Non-goals

- Cursor blink animation. DanTerm does not blink the cursor and this plan
  does not add rendering for it: `isCursorBlinking` stays tracked and
  reported only (`RenderPresentation` already omits it), and `?12` changes
  what is stored and answered, not what is drawn.
- ANSI mode 12 (SRM / send-receive) stays unrecognized; DECRQM keeps
  answering 0 (already test-pinned).
- No DECRQM entry for keypad mode (DECNKM 66); `ESC =` / `ESC >` remain the
  only writers.
- Mouse encodings 1005/1015/1016 stay unrecognized.
- The mouse trio stays collapsed into one `TerminalMouseTrackingMode`
  (deliberate, test-pinned simplification per the audit).
- No change to S14's territory: screen boxing and the per-screen kitty
  keyboard stacks are out of scope.

## Accepted risks

- Hot-path mode reads (`isAutoWrapMode`, `isInsertMode` in the print path)
  move from loose stored properties to fields of a nested stored struct.
  Same-module stored access is expected to be zero-cost; the bound is no
  regression in the terminal performance gates
  (agent-docs/terminal-performance.md).

## Rejected ideas

- RI1: Registry drives only report + reset, setters stay hand-written (the
  audit's cheaper fallback) -- still lets a new mode be added to the setter
  alone; the full registry costs little more.
- RI2: Forcing the side-effectful modes (6, 7, 1047/1048/1049, mouse trio)
  into the table via hooks/closures -- these are exactly the modes that
  genuinely differ; explicit arms keep that visible.

## Implementation discretion

- Whether `TerminalModes` and the registry live in a new sibling file (the
  `extension Terminal` precedent: TerminalSearch.swift, LogicalLineStore.swift)
  or inside Terminal.swift, and any visibility widening that entails.
- The lookup's internal shape (switch, computed table built per call, ...) within
  the non-stored constraint above, and whether hot-path call sites read `modes.x`
  directly or through forwarding accessors.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- flag declarations
  (715-728), `inputModes` (966), mode appliers/reporters (6099-6241),
  `applyCursorStyle` (6243), `dispatchEscape` (`ESC =`/`ESC >`),
  `saveCursor`/`restoreCursor` (6690-6715), `resetControlState` (6858).
- Possibly new `lib/TerminalCore/Sources/TerminalCore/TerminalModes.swift`.
- Tests: `lib/TerminalCore/Tests/TerminalCoreTests/TerminalQueryTests.swift`
  (table extensions, `?12`), plus a new `?12` behavioral test alongside the
  existing mode suites.

## Verification

1. TDD the `?12` slice: write the failing DECRQM/set/reset/DECSCUSR tests
   first, confirm they fail for the expected reason.
2. `swift test --package-path lib/TerminalCore` for the fast loop;
   `just test` as the full gate.
3. Confirm PO1's suites pass with zero expectation edits before the `?12`
   slice lands, so neutrality and the behavior change are separable in
   history.

## Commit progress

- [x] 1. Refactor terminal modes behind one registry
- [ ] 2. Add DEC cursor-blink mode 12

## Implementation notes

- `TerminalModes` and its registry stay nested in `Terminal.swift`, preserving private access
  without widening engine internals solely to create a sibling file.
