# Refactor SGR Extended-Color Interpretation

## Summary

Replace the duplicate colon and semicolon extended-color paths with one
decoder and one color-target application path. Preserve all current terminal
behavior, especially the intentional grammar difference: only colon RGB
accepts a colorspace field.

No public API changes.

## Implementation Changes

- Introduce one typed target derived from SGR 38, 48, or 58. Apply the decoded
  color to foreground, background, or underline color through one switch.
- Decode indexed and RGB colors through one shared walker over the concrete
  bounded CSI parameters.
- Pass the separator syntax explicitly:
  - Colon accepts `target:5:n`, `target:2:r:g:b`, and
    `target:2:cs:r:g:b`.
  - Semicolon accepts `target;5;n` and `target;2;r;g;b`. It never skips a
    colorspace field.
- Preserve each syntax's consumption rules:
  - A colon group is consumed atomically.
  - A truncated semicolon color consumes the available expected payload
    without applying a color.
  - An unknown semicolon selector consumes only that selector, allowing later
    SGR parameters to apply.
- Leave colon underline-style groups such as `4:3` unchanged.
- Keep the implementation on concrete CSI storage and index ranges. It must
  pass the existing type-check budget.

## Invariants and Proof

- I1: All five supported indexed/RGB forms produce the same colors for targets
  38, 48, and 58 as before. Colon selection remains minimum-length: once the
  required fields exist, trailing colon subparameters are ignored.
- I2: A semicolon RGB sequence with an apparent colorspace field treats its
  first three payload values as RGB and leaves the extra value as an ordinary
  SGR parameter.
- I3: Malformed or truncated colors leave their target unchanged and retain
  current recovery behavior.
- I4: Component values still truncate modulo 256.
- I5: Every extended-color attempt advances past at least its selector,
  including unknown and truncated selectors, so no parameter stream can stall
  SGR interpretation.

Add a green-before/green-after parameterized characterization test for I1 and
I2, including the over-long colon group `38:2:1:2:3:4:5`. Retain the existing
extended-color, malformed-recovery,
component-truncation, underline-color, fixture, state-synchronization, and
chunk-invariance tests as the remaining behavioral safety net. Do not add a
test for private helper structure.

Verification:

- `swift test --package-path lib/TerminalCore --filter TerminalStyleTests`
- `just lint`
- `just test` before committing

## Boundaries and Delivery

- Do not change the CSI parser, parameter capacity, wire grammar, public
  interfaces, fixture deviations, or state-synchronization encoding.
- Reject a unified grammar that permits `target;2;cs;r;g;b`; that would change
  external compatibility.
- The work has no prerequisite. If the broader PARSE-6 `Terminal.swift`
  extraction starts concurrently, land this focused refactor first to avoid
  same-file churn.
- After the implementation commit exists, mark PARSE-4 complete in the
  construction audit with that commit hash.
- Exact private names and helper signatures remain implementation discretion.

## Follow Up

- Mark PARSE-4 complete in `docs/scratch/2026-08-18-construction-audit.md`
  with this implementation commit's hash.
