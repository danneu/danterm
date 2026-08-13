# One walk per session lookup

## Problem

The pure core resolves "which pane owns this session" by materializing every
pane in the app and searching the array. Handling one admitted session report
does this twice and walks the model five times, and the four lookups that make
up the arm can each answer independently.

Evidence, all current:

- `AppModel.pane(owning:)` (`lib/DanTermCore/Sources/DanTermCore/Model.swift`)
  is `allPanes.first { $0.session?.id == sessionId }`. `allPanes` flat-maps
  `panesInNode`, which allocates a fresh array at every recursion level, and
  every element is a full `PaneModel` copy carrying its session and todo array.
- `AppModel.updateSession` calls `pane(owning:)` and then `updatePane`, so one
  nested mutation walks the trees twice.
- The `.sessionReport` arm in `Update.swift` adds three more traversals:
  `pane(owning:)` for the pane id, `pane(_:)` for the previous session value,
  and `pane(_:)` again to compare after the mutation.
- Four more arms -- `.sessionBell`, `.sessionNotification`, `.sessionEnded`,
  `.sessionCreationFailed` -- each pay a whole-model materialization for a
  single `pane(owning:)`.
- `AppModel.allPaneIds` is `allPanes.map(\.id)`: it copies every `PaneModel`
  only to read its id, while `ModelOperations.swift` already has a free
  `allPaneIds(_ node:)` that walks ids directly.

Session reports carry terminal-reported title, cwd, progress, and agent
activity, so this runs per semantic event. The cost is pure bookkeeping:
nothing about the operation needs more than one walk.

## Desired outcome

Resolving or mutating a session touches the tree once, allocates no
intermediate pane array, and produces a single answer that the rest of the arm
reads instead of re-deriving.

## Decision

Give the split tree one predicate-based leaf finder and one predicate-based
leaf mutator, in `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`,
alongside the existing `paneInNode` / `updatePaneInNode`. Both pane-by-id and
pane-by-owned-session become uses of that one primitive rather than two
near-identical recursions.

On top of it:

- `AppModel.pane(_:)` and `AppModel.pane(owning:)` both become direct tree
  walks. `pane(owning:)` stops allocating `allPanes`, which also fixes the four
  other session arms with no change at their call sites.
- `AppModel.updateSession` finds the owning leaf and mutates it in one walk,
  and returns what it found: the owning pane id, and whether the session value
  actually changed. The `.sessionReport` arm consumes that result instead of
  performing its own before/after lookups.
- `AppModel.allPaneIds` walks ids directly through the existing free
  `allPaneIds(_ node:)`, copying no `PaneModel`.

`AppModel.allPanes` stays as it is. Its remaining callers in `Projections.swift`
genuinely iterate every pane.

This is a behavior-preserving refactor. Its value is that four lookups that can
disagree collapse into one that cannot, and that a per-event path stops
allocating proportionally to the number of open panes.

## Invariants

- **I1.** A session report reaches exactly the pane whose live session carries
  the reported id. A report naming a session that no pane owns, or a session
  that has since been replaced, mutates nothing and produces no commands.
- **I2.** The pane id the `.sessionReport` arm acts on and the pane the mutation
  wrote to are the same pane, by construction rather than by agreement between
  separate lookups.
- **I3.** "The session changed" means the owning pane's session value differs
  before and after the reducer ran. A report that leaves the value identical
  reports no change, and the background agent-waiting alert fires only on a
  change.
- **I4.** `allPaneIds` and `allPanes` keep their existing order: tabs in group
  order, then panes left to right within each tab's tree.
- **I5.** The tree stays the only place a pane or a session lives. No lookup
  result is cached across mutations.

## Proof obligations

Existing tests in `lib/DanTermCore/Tests/DanTermCoreTests/` already carry most
of this contract; the refactor must keep them green without editing their
assertions.

- **PO1** (I1): unknown-session and replaced-session reports are dropped, for
  the report arm and for bell, notification, end, and creation-failure --
  `SessionReportTests`.
- **PO2** (I1, I3): value and lifecycle reports reduce into the identified
  session -- `SessionReportTests`, `UpdateSessionEventTests`.
- **PO3** (I3): repeated agent-waiting activity raises one background alert,
  and a waiting report for a focused pane raises none -- `SessionReportTests`,
  `UpdateSessionEventTests`.
- **PO4** (I2): a new update-level test -- send a change-producing session
  report to a pane in a non-selected tab while other panes hold their own
  sessions, then assert that only the owning session changed and that every
  resulting command and alert names that same pane. Asserted through `update()`
  and the model, never against the mutator's return type, which is reserved to
  implementation discretion.
- **PO5** (I4): a new exact-order test over a model with several groups, several
  tabs per group, and a nested split tree -- `allPaneIds` equals the full
  expected sequence in group, then tab, then left-to-right leaf order. The
  existing order assertions in `TreeOwnsPanesTests`, `SessionStoreTests`, and
  `DeterminismSeamTests` stay green but each cover a single tab, so none of
  them constrains group or tab order today.
- **PO6** (I5): session mutation follows identity to the owning pane, and
  removing a pane structurally removes its session -- `SessionStoreTests`.

## Non-goals

- Changing any observable behavior. No message, command, alert, or projection
  output differs.
- Touching the `allPanes` iteration in `Projections.swift`.
- Adding a performance benchmark. The core has no perf harness and this plan
  does not introduce one; the win is structural and allocation-level, not a
  number this repo currently measures.

## Rejected ideas

- **RI1. A stored pane-id or session-id index on `AppModel`.** It would make
  every lookup O(1), but it reintroduces exactly the drift the tree-owns-panes
  refactor removed: the index must be rebuilt on every split, close, move,
  restore, and tab or group mutation, and a missed rebuild is a silent wrong
  answer. `Model.swift` states this exclusion in prose today. One walk per
  mutation is the ideal available while the tree remains the single source of
  truth.

## Implementation discretion

- The concrete shape of the mutation result -- named struct, tuple, or optional
  pair -- and whether the predicate primitives are generic over the match or
  take a closure.

## Implementation notes

- `AppModel.allPaneIds` calls the existing tree walk through `paneIdsInNode`.
  The forwarding name avoids a collision with the property when these core
  sources compile same-module into the app, where `DanTermCore` is not an
  available module namespace.
