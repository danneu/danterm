# Batch A: collapse redundant whole-model tree walks in the pure core

## Context

A performance/simplification audit of DanTerm's pure core surfaced places where an
`update()` arm or helper **already holds the owning tab or pane in hand** but then
reaches back through a *whole-model* tree walk (`model.pane(_:)`, `model.allPanes`,
`model.groups.flatMap(\.tabs)`) to re-find or re-test something it could read
directly. This batch removes the *second, third, and Nth* redundant walk inside a
single arm.

This is **not** an attack on the model's deliberate single O(tree) walk per `Msg`.
That walk is intentional and documented (`Model.swift:206-235`): lookups walk the
tree because they run per-`Msg`, never per render frame, and a stored index would
reintroduce the dict/tree drift the leaf-as-single-source-of-truth design
eliminated. This batch leaves that design untouched.

Seven candidate folds were audited; four survived a single bar -- *does the change
leave the code simpler or neutral?* Perf is marginal across the batch (item 1 is the
only real speed win); each surviving item was kept because it lands the code simpler
or neutral on its own merits, needs no shared machinery, and is independently
shippable. The three cut items (and one cut sub-scope) are restated under
"Risks / out of scope" so the omissions read as intentional.

**Hard guardrails for the implementer:**

- **No new abstraction.** No new `updatePane` variant (no returning
  `updatePane<R> -> R?`), no new resolver, no shared helper beyond item 4's one
  additive computed property. Items 2 and 3 fold with a plain guard-chain or a
  value captured inside the existing `Void` closure -- that is the whole toolkit.
- **Behavior must be identical.** Every item is behavior-preserving, including the
  item-2 dead-guard deletion (the arm returns `[]` on every reachable path before
  and after). The one new test (item 3) pins currently-unpinned behavior the fold
  relies on; it does not cover a behavior change.
- **Stay in the pure core.** All edits are in
  `lib/DanTermCore/Sources/DanTermCore/`. Do not pull AppKit/GhosttyKit/Foundation-IO
  into the core or disturb the `CoreEnv` determinism seam.
- Follow the house code-style rules in `AGENTS.md`: `///` doc comment on item 4's
  new property, the three-section preamble on the new test.

Line numbers below are as-of-now references; match by content (they drift). There is
no sequencing dependency -- do them in any order or ship a subset. Ordered by
confidence: item 1 (perf + simpler), item 2 (dead-code delete), item 3 (force-unwrap
removal + one new test), item 4 (readability, the most optional -- cut first if
trimming).

---

## Item 1 -- `tabTodoRollup`: stop the per-pane whole-model walk (perf + simpler)

**File/function:** `ModelOperations.swift:595-605`, `func tabTodoRollup(_:in:)`.

**Problem:** the loop calls `model.pane(paneId)` -- a whole-model walk -- once per
pane id from `allPaneIds(tab.rootNode)`, so an N-pane tab does N full-model walks.
The panes are already inside `tab.rootNode`. This is hotter than the audit implied:
besides the close-confirm paths (`emitCloseTabsConfirmation` at
`ModelOperations.swift:578-582`), it is reached via `desiredWindowChrome`
(`Projections.swift:350`) -> `reconcileWindowChrome` (`app/Reconcile.swift:288`),
i.e. the per-`Msg` window-chrome reconcile sweep on the selected tab. Still
per-`Msg`, never per-render-frame.

**Fix:** iterate `panesInNode(tab.rootNode)` (already exists at
`ModelOperations.swift:81-88`; recurses identically to `allPaneIds`, returns the
in-hand `PaneModel`) and read `p.todos` directly. Keep the signature; only the body
changes.

Before:
```swift
  for paneId in allPaneIds(tab.rootNode) {
    guard let todos = model.pane(paneId)?.todos else { continue }
    total += todos.count
    uncompleted += todos.count { !$0.isDone }
  }
```
After:
```swift
  for pane in panesInNode(tab.rootNode) {
    total += pane.todos.count
    uncompleted += pane.todos.count { !$0.isDone }
  }
```

**Output is provably identical:** every id from `allPaneIds(tab.rootNode)` is owned
by a leaf in that same tree, so the original `guard ... else { continue }` could
never skip; `panesInNode` walks the same leaves in the same order.

**Tests (existing, no new test):** `tabTodoRollupEmptyTabReturnsZero` and
`tabTodoRollupSumsTabAndPanesIgnoresOtherTabs` in
`ModelOperationsTests.swift:1944-1991` already pin the contract (empty-tab zero;
sums tab + every pane, ignores other tabs' panes). Both must stay green.

---

## Item 2 -- `remoteSessionReported`: delete the dead guard, fold two walks to one

**File/function:** `Update.swift:533-547`, the `.remoteSessionReported` arm.

**Problem (confirmed dead, not speculative):** the arm reads the pane via
`model.pane(paneId)` (walk 1), captures `wasRemote` and `oldSession`, then writes
via `updatePane` (walk 2). `wasRemote` is live (used in the closure). `oldSession`
is read **only** to feed the guard at `:546`
(`guard !wasRemote || oldSession != session else { return [] }`), and the arm
returns `[]` on *every* reachable path -- so the guard mutates nothing and emits
nothing, and `oldSession` is a dead read. Git archaeology pins why: the guard was
load-bearing when introduced in `a9b04e4` (it gated `return [.applyPaneTheme(...)]`),
then `a66de1f` moved theme application into the
`desiredPaneConfig`/`reconcilePaneConfig` projection and deleted that return,
orphaning the guard.

**Fix:** delete the dead guard and `oldSession`, drop the existence guard (the arm
returns `[]` regardless and `updatePane` is already a no-op on a missing id), and
capture `wasRemote` inside the closure -- collapsing both walks into one.

Before:
```swift
    case .remoteSessionReported(let paneId, let session):
        guard let existing = model.pane(paneId) else { return [] }
        let wasRemote = existing.isRemote
        let oldSession = existing.remoteSession
        let remoteTheme = model.config.remoteTheme
        model.updatePane(paneId) { p in
            p.isRemote = true
            p.remoteSession = session
            if !wasRemote {
                p.remoteThemeOverride = remoteTheme
            }
        }

        guard !wasRemote || oldSession != session else { return [] }
        return []
```
After:
```swift
    case .remoteSessionReported(let paneId, let session):
        let remoteTheme = model.config.remoteTheme
        model.updatePane(paneId) { p in
            let wasRemote = p.isRemote
            p.isRemote = true
            p.remoteSession = session
            if !wasRemote {
                p.remoteThemeOverride = remoteTheme
            }
        }
        return []
```
(`remoteTheme` is a config read, not a tree walk -- leave it outside the closure.)

**Tests (existing, no new test):** all 27 `@Test`s in `UpdateRemoteTests.swift` pin
the contract -- returns `[]`, session stored, `remoteThemeOverride` set only on the
first remote transition. All must stay green.

---

## Item 3 -- `setTodoDone`: remove the only `model.pane(...)!` in `Update.swift`

**File/function:** `Update.swift:1363-1367`, the `.setTodoDone` arm.

**Problem:** the arm walks the model three times and force-unwraps
`model.pane(paneId)!` at `:1365` -- the only `model.pane(...)!` in `Update.swift`.
It is currently guarded by the non-nil read on the line above, so it is a latent
(not live) crash, but a force-unwrap in the pure model is a red flag a future edit
could trip.

**Fix:** read the pane once into a single guard-chain; collapse to one read + one
write. Removes the force-unwrap *and* a redundant walk (3 -> 2, matching the clean
sibling arms `toggleTodoDone`/`editTodoText`). No captured-var smell, no new
machinery.

Before:
```swift
    case .setTodoDone(let paneId, let todoId, let isDone):
        guard let idx = model.pane(paneId)?.todos.firstIndex(where: { $0.id == todoId }) else { return [] }
        guard model.pane(paneId)!.todos[idx].isDone != isDone else { return [] }
        model.updatePane(paneId) { $0.todos[idx].isDone = isDone }
        return [.scheduleCheckpoint]
```
After:
```swift
    case .setTodoDone(let paneId, let todoId, let isDone):
        guard let pane = model.pane(paneId),
              let idx = pane.todos.firstIndex(where: { $0.id == todoId }),
              pane.todos[idx].isDone != isDone else { return [] }
        model.updatePane(paneId) { $0.todos[idx].isDone = isDone }
        return [.scheduleCheckpoint]
```

**New test (the only new test in this batch).** Write it first, in
`UpdateTodoTests.swift` under the `// MARK: - toggleTodoDone` neighbours (after the
existing `toggleTodoDoneFlipsIsDone` at `:73-92`). It mirrors the already-pinned
tab-level `setTabTodoDoneSetsExplicitValue` (`UpdateTabTodoTests.swift:97-112`) and
uses the file's pane-todo idioms (`createTab`, `selectedTab(in:)!.focusedPaneId`,
`model.pane(paneId)!.todos`, the `hasEffect` helper):

```swift
    @Test("setTodoDone sets explicit value; same value is a no-op")
    func setTodoDoneSetsExplicitValueNoOpWhenUnchanged() {
        // Intent: setTodoDone(paneId:todoId:isDone:) assigns isDone explicitly and
        //   emits scheduleCheckpoint, but returns no commands when the value is
        //   already what was requested.
        // Why it exists: pins the value-unchanged guard the item-3 fold relies on
        //   -- the rewrite reads the pane once and bails on `isDone != isDone`
        //   before mutating, so the no-op contract must be locked first.
        // Scenario: spec-first -- no incident; the pane-level arm mirrors the
        //   already-pinned tab-level `setTabTodoDoneSetsExplicitValue`.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "task"))
        let todoId = model.pane(paneId)!.todos[0].id

        let setCommands = update(&model, .setTodoDone(paneId: paneId, todoId: todoId, isDone: true))
        #expect(model.pane(paneId)!.todos[0].isDone == true)
        #expect(hasEffect(setCommands) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "expected scheduleCheckpoint on a real change")

        let noopCommands = update(&model, .setTodoDone(paneId: paneId, todoId: todoId, isDone: true))
        #expect(noopCommands.isEmpty, "no-op when value unchanged")
    }
```

**TDD note -- this is a pinning test, so "fail-first" needs a deliberate step.**
The no-op guard already exists at `Update.swift:1365`, so this test **passes against
the current code**. To confirm it is non-vacuous (the brief's "verify it fails for
the right reason"), temporarily remove or invert the
`guard ... .isDone != isDone else { return [] }` line, run the test, and confirm the
`noopCommands.isEmpty` assertion fails (the arm then emits `.scheduleCheckpoint`);
restore the guard, then apply the item-3 fold and confirm the test stays green. Do
**not** report this test as "failing before the change" in the normal sense -- it
characterizes behavior the fold preserves.

**Leave the sibling TODO arms alone:** `toggleTodoDone` (`:1358-1361`),
`editTodoText` (`:1369-1374`), `reorderTodo`, and the tab-todo arms
(`:1239-1276`) are out of scope (see "Risks / out of scope").

---

## Item 4 -- `hasAnyTab`: de-dup the `groups.flatMap(\.tabs)` emptiness tests (readability, zero perf)

**Files:** new property in `Model.swift`; call sites in `Update.swift`.

**Problem:** several close/quit arms materialize `groups.flatMap(\.tabs)` only to
test `.isEmpty`. The cost is marginal (one array alloc + N struct-header copies on a
cold, user-initiated event), so the justification is **readability / de-duplication
only** -- replacing the bare `.flatMap(\.tabs).isEmpty` test with a named intent.
**Scope:** this item swaps *only* the pure-emptiness sites. The first-id
(`.first?.id`) and contains (`.contains(where:)`) sites are deliberately left as
their existing eager `.flatMap(\.tabs)` -- see "Deliberately left eager" below.

**Fix step 1 -- add the property** to `AppModel` (e.g. just below the stored
properties in `Model.swift:187-204`), with a `///` doc comment:
```swift
    /// Whether any group holds at least one tab. Short-circuits on the first
    /// non-empty group without materializing `groups.flatMap(\.tabs)`, which
    /// several close/quit arms previously did only to test emptiness.
    var hasAnyTab: Bool { groups.contains { !$0.tabs.isEmpty } }
```

**Fix step 2 -- route the pure-emptiness sites** (these collapse any local
`let allTabs = ...` that exists only to feed `.isEmpty`):

- `Update.swift:146-147` (`.closeTab`): `let allTabs = model.groups.flatMap(\.tabs)`
  + `if allTabs.isEmpty` -> `if !model.hasAnyTab`.
- `Update.swift:812` (`.surfaceCreationFailed`): `if model.groups.flatMap(\.tabs).isEmpty`
  -> `if !model.hasAnyTab`.
- `Update.swift:948-949` (`.confirmCloseTabs`): `let allTabs = ...` + `if allTabs.isEmpty`
  -> `if !model.hasAnyTab`.
- `Update.swift:992` (`.deleteGroup`): `if model.groups.flatMap(\.tabs).isEmpty`
  -> `if !model.hasAnyTab`.

**Deliberately left eager (do NOT rewrite these).** The first-id / contains sites --
`Update.swift:810` (`.surfaceCreationFailed` selection repair), `:998`
(`.deleteGroup` selection repair), and `:997` (`.deleteGroup` selection-validity
check) -- keep their existing eager `model.groups.flatMap(\.tabs).first?.id` /
`.contains(where:)`. A `.lazy.flatMap(...)` rewrite was considered and dropped: it is
a perf short-circuit on paths this item explicitly declares perf-irrelevant; it does
**not** de-duplicate (the literal `.flatMap(\.tabs)` text still appears at each
site); and `.lazy.` has **zero first-party precedent** anywhere in `app/` or `lib/`,
so it would introduce a novel idiom that makes a future reader ask "why is this one
lazy and no other?" on a path that doesn't matter. That fails this batch's bar
("simpler or neutral; no perf-only change that worsens readability; no novel
machinery"), so it is out of scope.

**Do NOT touch `totalTabCount`.** `ModelOperations.swift:536-538`
(`model.groups.flatMap(\.tabs).count`) must keep returning the true Int -- five
sites need it: `== 1` last-tab detection at `Update.swift:118`, `:363`, `:1401` and
in `wouldQuitFromClose` (`ModelOperations.swift:540-542`); `== group.tabs.count` at
`Update.swift:975`; `== ids.count` for `isQuit` at `ModelOperations.swift:589`. A
Bool would silently break `isLastTab`/`isQuit`/`wouldQuitFromClose`. If
`totalTabCount` is touched at all, the only safe flatMap-free rewrite is
`model.groups.reduce(0) { $0 + $1.tabs.count }` -- but this batch leaves it alone.

**Tests (existing, no new test):** the close/quit/delete-group paths are covered by
`UpdateTabTests`, `UpdateGroupTests`, and `UpdateLifecycleTests` (terminate when the
last tab/group closes; selection repair after a close). The `:812`
**`.surfaceCreationFailed`** emptiness swap is covered by `UpdateGhosttyTests` --
specifically `testSurfaceCreationFailedCleansUp` (`UpdateGhosttyTests.swift:86`) and
`surfaceCreationFailedRemovesSplitTabSiblings` (`:110`), which exercise
terminate-on-last-tab and sibling cleanup after a failed surface. All must stay
green; behavior is identical.

---

## Risks / out of scope

**Deliberately cut -- do NOT re-add (each re-introduces the cost/benefit problem it
was cut for):**

- **bell/notify resolver** (orig. audit item 2): smallest perf gain
  (`.sendNotification` is already throttled 1/sec per pane+kind); the obvious single
  `(TabModel, PaneModel)?` resolver is *not* cleanly simpler -- the focused-pane
  suppression check needs the **selected** tab while the resolver returns the pane's
  **owning** tab (two different tabs) -- and it would need a new stale-pane test for
  a change that alters nothing observable.
- **`commandEnded` fold** (orig. audit item 3): once-per-shell-prompt; with the
  pre-read captured in the closure the fold is a readability wash and the perf is
  negligible.
- **`currentCwd` swap** (orig. audit item 6): `paneInNode(tab.rootNode, id:)` for
  `model.pane(...)` is behavior-preserving but sits on a doubly-guarded cold path
  (single caller `.createTab`, only when `launch?.cwd` is nil *and* the focused pane
  has no cwd) and would need a new fallback test. *Allowed only* as a zero-cost,
  no-new-test drive-by **if** the implementer is already editing
  `ModelOperations.swift` for item 1 (same applies to the `focusedPane` read at
  `:482`). Not a planned task.
- **Returning `updatePane<R> -> R?` variant:** not needed by anything in scope.
- **`toggleTodoDone` / `editTodoText` / `reorderTodo`** (rest of orig. audit item
  5): already clean 2-walk arms with no force-unwrap; folding them needs the
  captured-var smell for negligible perf. The tab-todo arms at `Update.swift:1239-1276`
  are also out of scope (`tabById`/`updateTab` are direct `(group, tab)` index
  lookups, not tree walks).

**This batch does not touch:** the deliberate single-walk-per-`Msg` design
(`Model.swift:206-235`), the reconcile/projection layer (read by item 1 only to
explain hotness, not modified), or any AppKit/GhosttyKit code.

---

## Verification

1. **TDD for item 3:** add the new test first; confirm it is non-vacuous via the
   temporary-guard-removal step above; apply the fold; confirm green.
2. `swift test --package-path lib/DanTermCore` -- full core suite. Targeted runs
   while iterating: `--filter ModelOperationsTests` (item 1),
   `--filter UpdateRemoteTests` (item 2), `--filter UpdateTodoTests` (item 3),
   `--filter UpdateTabTests`/`UpdateGroupTests`/`UpdateLifecycleTests`/`UpdateGhosttyTests`
   (item 4 -- `UpdateGhosttyTests` covers the `.surfaceCreationFailed` emptiness swap).
3. **Grep gates** (expect zero matches after the changes):
   - `grep -n 'model.pane([^)]*)!' lib/DanTermCore/Sources/DanTermCore/Update.swift`
     (item 3 -- the force-unwrap is gone).
   - `grep -n 'oldSession' lib/DanTermCore/Sources/DanTermCore/Update.swift`
     (item 2 -- the dead read is gone).
   - Confirm `totalTabCount` body is unchanged (item 4 guardrail).
4. `just test` -- the full local gate (protocol + core + support + lints + shell
   self-tests) before declaring done. (The core-purity lint must still pass -- no
   impure imports were added.)
