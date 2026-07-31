# Make malformed SGR colon groups effect-free (`CSI 58:4:`)

## Context

An SGR sequence can carry colon-joined subparameter groups (`38:2::r:g:b`,
`58:5:n`, `4:3`). A group whose selector is not understood -- e.g. `58:4:`,
where `4` is not a valid color selector for SGR 58 -- must be inert: it must not
mutate the pen, and the `4` inside it must not leak out and be reinterpreted as
flat SGR 4 (underline). Recovery must still work: a valid parameter later in the
same CSI sequence (`\e[58:4:;31m`) has to apply.

Nothing pins this case today. The nearest coverage in
`lib/TerminalCore/Tests/TerminalCoreTests/TerminalStyleTests.swift` is
`underlineColorRetention` (a *truncated* `58:2:1:2` group) and
`malformedRecovery` (foreground recovery only). Neither covers an unknown color
selector, and neither asserts that underline was left alone.

Reading the current source (`EscapeAbsorber#dispatchCSI`, `Terminal#applySGR`,
`#applyColonSGR`, `#colonColor`) suggests the desired behavior already holds:
grouping is separator-driven and consumes the whole group before interpreting
it, and an unknown color selector returns `nil`. That is a code-reading
expectation, not a measurement -- the test run settles it.

## Contract to pin

One new regression in `TerminalStyleTests.swift`, following the suite's existing
idiom and the repo's three-section test preamble. It must establish a known
non-default pen first (otherwise "no mutation" passes vacuously), then assert:

1. **Atomicity** -- the malformed group is consumed whole; no member of it is
   reinterpreted as a standalone SGR parameter (specifically, underline is
   unchanged).
2. **Inertness** -- feeding the malformed group alone leaves the pen identical.
3. **Recovery** -- a valid parameter after the malformed group in the same CSI
   sequence still applies.

Existing parser and chunk-invariance tests already cover the colon/mixed-separator
machinery underneath; no additional split-point test is needed.

## Sequencing

Write the test and run it before touching any production source.

- **If it fails**, diagnose which layer actually produced the failure (parse,
  grouping, or application) and make the smallest fix there. The fix must
  preserve maximal colon-group consumption -- an unrecognized group is dropped
  whole, never partially applied and never resumed mid-group.
- **If it passes**, the premise does not hold and the deliverable is the pinning
  test alone. Report that plainly; do not manufacture a production change or
  refactor working code under a green test.

Report changed files and test output either way.

## Verification

- Targeted: `swift test --package-path lib/TerminalCore --filter TerminalStyleTests`
- Wider net for the SGR/parser surface:
  `swift test --package-path lib/TerminalCore --filter 'TerminalStyleTests|CSIParserTests|TerminalCellStyleTests|TerminalFixtureTests'`
- If production source changed, run the full package once:
  `swift test --package-path lib/TerminalCore`

## Implementation discretion

- Test placement within the suite, exact byte sequences, and which style fields
  carry each assertion.
- If a fix is needed, which layer it lands in and its exact shape -- constrained
  only by the maximal-consumption rule above.
