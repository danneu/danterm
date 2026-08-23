# Terminal mode enums

Source finding: `docs/scratch/2026-08-18-construction-audit.md#parse-3`,
verified as an ideal pivot.

## Problem

DanTerm declares terminal mode behavior in several shapes. Bool-backed ANSI and
DEC modes share `modeKeyPath` for set and query, but special modes still repeat
their numbers across set, query, and state synchronization. `appendModes`
separately lists the Bool-backed modes and repeats the mouse-tracking mapping.
Nothing requires every consumer of a newly accepted mode to state its policy.

The earlier registry work in `fea724c1` already made reset exhaustive through
one `TerminalModes` default value. The remaining problem is not reset storage;
it is the absence of one declaration of each accepted numeric mode and
exhaustive consumers of that declaration.

## Decision

Represent the supported modes as one raw-value enum for ANSI modes and one for
DEC-private modes. Each numeric value appears exactly once. An unknown raw value
fails enum initialization, which preserves the current ignore-on-set and
DECRQM-status-0 behavior.

Set/reset dispatch, DECRQM, and state synchronization each use an exhaustive
switch over the enums. Adding a case therefore requires all three consumers to
state their policy, while side effects and their ordering remain ordinary code
rather than table data or hooks. State synchronization iterates the enum cases
and uses the same exhaustive policy.

The enums cover ANSI 4 and 20, and DEC 1, 6, 7, 12, 25, 1000, 1002, 1003,
1004, 1006, 1047, 1048, 1049, 2004, 2026, and 2027. They preserve genuine
differences rather than forcing every mode into a Bool:

- The mouse trio remains one mutually exclusive state.
- Modes 1047 and 1049 report the active screen but retain their distinct screen
  transition behavior.
- Mode 1048 remains an action whose DECRQM status is unrecognized.
- Mode 2027 remains permanently set and inert.
- Alternate-screen reconstruction remains owned by the state encoder rather
  than generic mode emission.

Keep whole-value `TerminalModes` reset. Keypad mode and cursor-style controls
stay outside the enums because they are not ANSI/DEC set/reset modes.

Mode parameters continue to apply from left to right. Any pending-motion clear
caused by an earlier parameter must happen before a 1047, 1048, or 1049
cursor/screen side effect.

Synchronization emits mode 6 before the final live-cursor address, so origin
mode controls how that address is interpreted. Mode 12 and the cursor-style
sequence continue to share `isCursorBlinking`; mode 12 is emitted first so the
later cursor-style sequence remains the final shape-and-blink writer. Mouse
tracking continues to reset all three mutually exclusive modes before enabling
the active one.

PARSE-3 lands before PARSE-6. The later encoder extraction moves the
enum-driven synchronization code without changing its ownership or mode
policy.

## Invariants

- **I1. Exhaustive policy:** Every accepted numeric mode is one enum case, and
  exhaustive set/reset, query, and synchronization switches require its policy.
  A deliberate unsupported operation is explicit rather than an omitted arm.
- **I2. Existing behavior:** Mode state, replies, focus-enable reporting, mouse
  exclusivity, alternate-screen transitions, and reset defaults do not change.
- **I3. Ordered effects:** Compound mode parameters keep their left-to-right
  behavior, including clearing pending motion before the 1047/1048/1049 side
  effects.
- **I4. Synchronization fidelity:** A fresh terminal fed state-synchronization
  bytes has the source's terminal-scoped ANSI/DEC mode state and reaches it with
  the alternate screen active when the source's is.
- **I5. Protocol status:** DECRQM keeps reporting 0 for 1048 and 3 for 2027.
- **I6. Reset ownership:** DECSTR and RIS reset all terminal-scoped mode state
  through the default `TerminalModes` value, not through an enum walk.

## Proof obligations

- **PO1 (I1, I2, I5):** An independent literal query contract covers every
  accepted mode, both values where meaningful, permanent modes, and unknown
  modes. Tests must not derive their cases from the production enums.
- **PO2 (I2, I3):** Existing saved-cursor, alternate-screen, focus, mouse,
  reset, dispatch-order, and chunk-invariance suites pass unchanged. Behavioral
  coverage proves that pending wrap is not saved or retained when mode 6
  precedes 1048 or 1049 in one compound sequence.
- **PO3 (I4):** State synchronization round-trips both ANSI modes, every
  Bool-backed DEC mode including non-default values of modes 7 and 25, every
  mouse-tracking state, SGR mouse encoding, application-keypad mode, a
  non-default cursor shape, a non-empty kitty keyboard stack, and an active
  alternate screen. The mode-6 proof uses a non-default scroll region and a
  cursor row whose origin-relative and absolute addresses differ. Source and
  replica produce the same cursor position, input and presentation state,
  DECRQM replies, and continuation behavior.
- **PO4 (I6):** Existing DECSTR and RIS mode-default tests pass without adding
  a parallel reset list.
- **PO5:** The targeted TerminalCore suites and `just lint` pass during the
  refactor; `just test` passes before commit.

## Non-goals

- Change the supported mode set or add terminal behavior.
- Change DECRQM 1048 compatibility.
- Move the state-synchronization encoder out of `Terminal`; PARSE-6 owns that
  extraction.
- Put keypad, cursor-style, or kitty keyboard controls into the ANSI/DEC mode
  enums.

## Rejected ideas

- **RI1. One Bool per mode:** This loses mouse exclusivity and invents state for
  action-only or permanent modes.
- **RI2. Enum-driven reset:** The existing whole-value reset is smaller and
  makes every stored mode default exhaustive, including state with no numeric
  mode.

## Implementation discretion

- Exact test grouping is discretionary; tests must prove the obligations above
  through public behavior rather than private enum structure.

## Dependencies and conflicts

The completed mode registry (`fea724c1`) and cursor-blink mode (`d3574ddb`) are
the foundation. PARSE-2 is already complete in `c5057591` and is not a blocker.
PARSE-6 directly conflicts in `appendModes`, `appendControlState`, and the
state-synchronization encoder, so it must follow this work. Any concurrent mode
addition is a semantic conflict even when Git merges it cleanly.

## Follow-up: DECRQM 1048

DanTerm accepts DECSET/DECRST 1048 as cursor save/restore but reports it as
unrecognized. The references do not supply one shared state model: xterm
reports saved-slot validity, VTE and Ghostty retain a mode bit, and kitty does
not report 1048. Keep status 0 in this change. A separate compatibility
investigation must choose and behaviorally define a state model before changing
that reply.

## Implementation notes

- Active-alternate synchronization now neutralizes row-affecting modes before it
  reconstructs the alternate grid, then restores the cataloged modes. The second
  restoration omits mode 1004 because the primary restoration already set it and
  a repeated DECSET would enqueue an extra focus reply.
