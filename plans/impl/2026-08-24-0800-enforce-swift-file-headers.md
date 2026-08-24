# Enforce Swift file headers

## Problem

`AGENTS.md` requires every Swift file to start with an ordinary `//` file
comment, not a `///` declaration comment or an Xcode filename banner. The gate
does not enforce this rule.

The current tracked tree has seven violations: detached `///` blocks in
`app/Todo{RowView,ShortcutHelpView,ToolbarButton}.swift` and
`lib/DanTermCore/Sources/DanTermCore/Todo{InputCommand,PopoverState,ShortcutCatalog}.swift`,
plus no header in `DragDropInput.swift`. The six detached blocks are style
drift. Their blank-line separation means they are not attached declaration
documentation.

## Decision

Add a repository lint over every tracked `.swift` file. It rejects a first line
that is not an ordinary `//` comment, starts with `///`, or is only the file's
name. It fails when tracked Swift discovery checks nothing and reports all
violations with the rule's rationale.

Give the lint a test-only repository-root seam. Its self-test uses that seam to
scan a throwaway tracked inventory, so intentionally bad Swift fixtures never
enter the production inventory.

Make the seven files conform with real file comments. Register the lint in the
rule-check subset used by both `just lint` and `just test`, and register its
self-test in the full gate.

## Invariants

- **I1:** Every tracked Swift file starts on line 1 with an ordinary `//`
  comment that is neither a declaration doc comment nor only the file's own
  name. A `// swift-tools-version:` directive satisfies this rule and remains
  the first line of each package manifest.
- **I2:** The lint derives its inventory from tracked files. No source-root list
  or expected violation count can drift from the repository.
- **I3:** One run reports every bad file and explains how file comments differ
  from declaration documentation.
- **I4:** `just lint` and `just test` enforce the live tree, while the full gate
  also proves the lint's behavior through its self-test.

## Proof obligations

- **PO1 (I1, I3):** The self-test accepts an ordinary file comment and a Swift
  tools-version directive, and rejects a detached `///` block, a missing header,
  and a filename-only banner. Failure output identifies each bad file and
  explains the rule.
- **PO2 (I2):** Through the repository-root seam, the self-test proves a
  throwaway tracked inventory discovers nested files safely, including a path
  with spaces, and that an empty tracked Swift inventory fails.
- **PO3 (I4):** The assembled lint-only gate contains the production lint, the
  full gate contains its self-test, and the existing gate-coverage check accepts
  that wiring.
- **PO4 (I1):** After the seven repairs, the lint passes over the checked-in tree;
  `just lint` and `just test` pass.

## Non-goals

- Enforcing or repairing declaration-level `///` coverage.
- Checking ignored build outputs, reference checkouts, or other untracked files.
- Changing Swift APIs or runtime behavior.

## Implementation discretion

- The lint language, parsing mechanics, diagnostic wording, and placement within
  the existing gate lists are free choices as long as the invariants and proof
  obligations hold.
