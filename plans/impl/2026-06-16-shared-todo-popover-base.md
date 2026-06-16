# Plan: Extract a shared base for the two TODO popover controllers

## Context

`app/TodoPopoverView.swift` (880 lines, `TodoPopoverViewController`, pane-scoped flat
list) and `app/TabTodoPopoverView.swift` (1305 lines, `TabTodoPopoverViewController`,
tab-scoped sectioned multi-bucket list) duplicate ~80% of their *controller plumbing*
near-verbatim. The duplication is not cosmetic and it is actively drifting:

- `restoreFirstResponder(...)` is **byte-identical** (pane 346-381 vs tab 465-500).
- `textView(_:doCommandBy:)` (NSTextViewDelegate) is identical across 72 lines **except
  one comment line** -- the visible scar of drift (pane 757-828 vs tab 1142-1212).
- The two `*PopoverRootView` NSView subclasses, the two `*TableView` NSTableView
  subclasses, and the `keyModifiers`/`listKey` vs `tabKeyModifiers`/`tabListKey` free
  functions are byte-identical except their names.
- Lifecycle, the edit-key-loop, `focusComposeInput`, the shortcut-help trio, and the
  `@objc` button actions differ only by scope/Msg routing.

Git history shows the cost: `848bf1c`, `7710621`, `c37628d` had to touch both files in
lockstep; single-file commits (`df6480b`, `e1f14c4`) are exactly where drift enters. A
shared base collapses the duplication to one copy and makes future popover changes a
single edit.

The model/update layer is already pure and well-factored (`TodoPopoverState<Target>`,
`classifyInputAction`, `classifyListAction`, `firstSelectableRow`/`nextSelectableRow`/
`sectionLocalIndex`, the `resolveTabTodo*` family -- all in `lib/DanTermCore/` with unit
tests). The remaining duplication lives entirely in the AppKit controller layer; this
plan targets exactly that.

## Goal & non-goals

**Goal:** one shared base class owning the duplicated controller chrome + AppKit-dispatched
plumbing, with the two controllers reduced to their genuinely-divergent parts (generic
state, projection, table data source, drag, action routing). Plus the sibling reconciler
dedup on the runtime side.

**Non-goals:**
- `app/AlertsPopoverView.swift` -- shares only ~40 lines of outer chrome (320x400
  wrapper/header/scroll/empty-label), none of the edit/compose/shortcut machinery. Out of
  scope. If the chrome itself ever becomes annoying, the right tool is a free factory
  helper (mirroring `makeTodoShortcutHintLabel`), not this base class. Noted as future work.
- No behavior change. This is a structure-only, behavior-preserving refactor.

## Mechanism decision: a NON-GENERIC base class (not a protocol, not a generic base)

**Why a base class, not a protocol-with-defaults.** The heaviest duplicated method,
`textView(_:doCommandBy:)`, plus `textDidChange` and the table data-source/delegate
methods, are dispatched by AppKit through the ObjC runtime (`respondsToSelector:` +
`objc_msgSend`). A Swift protocol-extension default is invisible to ObjC dispatch, so it
would be silently dead. An inherited base-class method is ObjC-visible. A base class is the
only seam that works for these.

**Why non-generic, despite the two `Target`/`Projection`/`Row` types differing.** Putting
`@objc` members on a *generic* NSObject subclass is the most fragile corner of Swift/ObjC
interop:
- `@objc` is a hard compile error inside extensions of generic classes (Swift SR-857) --
  and `doCommandBy`/`textDidChange` live in `extension` blocks today.
- `respondsToSelector:` has silently returned false for `@objc` protocol methods on
  generic-class hierarchies in a whole-module-vs-incremental-build-dependent way
  (SR-11073 / SR-10257) -- a dead delegate in release builds, invisible in a quick check.
- Zero precedent in the local reference apps: both Ghostty (`.ghostty-src/macos/`) and cmux
  (`.refs/cmux/`) use generics only for value/utility wrappers and keep every ObjC-dispatched
  class non-generic.

A generic base would also buy almost nothing: the data-source methods are genuinely
divergent (flat `[TodoItem]` vs sectioned `[TabTodoRow]` with group rows + multi-bucket
drag) and stay per-subclass regardless; `apply()` diverges structurally; `composeDraft` is
a plain `String`. The type-parametric logic that *does* benefit from generics is already
generic as free functions (`firstSelectableRow<R>`, `TodoPopoverState<Target>`), outside any
NSObject subclass. So: **non-generic base, with the generic state reached through a small
hook façade.** This matches the codebase's AppKit-correctness-first, predictability-over-
cleverness posture (`app/AGENTS.md`, `docs/design/2026-06-09-appkit-lifetime-safety.md`).

## Architecture

New file `app/TodoPopoverControllerBase.swift` holds the three collapsed standalone types
plus the base class:

- `final class TodoPopoverRootView: NSView` -- the shared `performKeyEquivalent` wrapper
  (collapses `PaneTodoPopoverRootView` + `TabTodoPopoverRootView`).
- `final class TodoPopoverTableView: NSTableView` -- shared `keyDown`/`cancelOperation`
  hooks (collapses `PaneTodoTableView` + `TabTodoTableView`).
- `todoKeyModifiers(from:)` / `todoListKey(from:)` -- one shared copy of the byte-identical
  key-event mappers.
- `class TodoPopoverControllerBase: NSViewController` conforming to `NSTableViewDataSource`,
  `NSTableViewDelegate`, `NSTextViewDelegate`. `NSTextViewDelegate` is implemented in an
  `extension TodoPopoverControllerBase` (legal: `@objc`-in-extension is fine for a
  *non-generic* class).

### What the base owns (concrete, shared verbatim)

- **Stored chrome:** `tableView` (`TodoPopoverTableView`), `scrollView`, `headerLabel`,
  `clearButton`, `helpButton`, `addInput` (`lazy`, see hooks), `composeHintLabel`,
  `editTitleLabel`, `editInput`, `editHintLabel`, `saveButton`, `cancelButton`,
  `bottomStack`, `editContainer`, `isSyncingTableSelection`, `shortcutHelpPopover`,
  `weak var runtime`. (The base does *not* own `emptyLabel` (pane-only), `newButton`
  (tab-only), the scope id, `popoverState`, or `projection`.)
- **Access control (these are `private` in both controllers today; subclasses live in
  separate files, so `private`/`fileprivate` would be invisible to them):** every base-owned
  control/flag a subclass override touches must be module-`internal` -- `tableView`, `addInput`,
  `editInput`, `saveButton`, `cancelButton`, `clearButton`, `scrollView`, `editContainer`,
  `bottomStack`, `editTitleLabel`, `isSyncingTableSelection` (the pane/tab `syncModeVisibility`
  and `apply` overrides read/toggle these). Base-only chrome stays `private` (`headerLabel`,
  `helpButton`, `composeHintLabel`, `editHintLabel`). `shortcutHelpPopover` stays **`private` to
  the base** (the base owns its full open/close lifecycle); expose a narrow internal read-only
  `var hasShortcutHelpPopover: Bool { shortcutHelpPopover != nil }` as the test seam rather than
  widening the handle.
- **`loadView()`** -- the full view-tree assembly + the single shared
  `NSLayoutConstraint.activate([...])` block, parameterized by the loadView hooks below.
  This collapses the gnarliest duplication (the ~90-line constraint block).
- **Concrete methods (moved verbatim, divergence behind hooks):** `init(runtime:)`,
  lifecycle (`viewWillAppear` -> `applyStoredProjection()`, `viewDidAppear` ->
  `focusInitialMode()`, `viewWillDisappear` -> `closeShortcutHelpPopover()`),
  `restoreFirstResponder(...)`, `focusComposeInput()`, `focusInitialMode()`,
  `installEditKeyLoop()`/`tearDownEditKeyLoop()`, `saveEditThenFocusCompose(clearingDraft:)`,
  the shortcut-help trio (`toggleShortcutHelp`, `closeShortcutHelpPopover`,
  `showShortcutHelpPopover`), the `@objc` actions `saveEditButtonClicked` /
  `cancelEditButtonClicked` / `tableRowDoubleClicked`, and the NSTextViewDelegate pair
  `textView(_:doCommandBy:)` + `textDidChange` (incl. the selector->`InputKey` mapping).

### The hook / override surface

Express "abstract" with `fatalError("subclass must override")` default bodies for hooks
with no sensible shared default, and real default bodies where noted. The base stays
module-internal and is never instantiated directly. Mark each with `// override point`.

**(A) Generic-state facade** (base can't name `Target`; each subclass backs these with its
own `popoverState`/`projection`):

| Hook | Signature | Default |
|---|---|---|
| `composeDraft` | `var composeDraft: String { get set }` | fatalError |
| `clearComposeDraft()` | `func clearComposeDraft()` | fatalError |
| `isEditing` | `var isEditing: Bool { get }` | fatalError |
| `applyStoredProjection()` | `func applyStoredProjection()` | fatalError (calls subclass `apply(projection)`) |

**(B) Behavior / intent hooks** (called from shared `doCommandBy`, key handlers, actions;
bodies differ by Msg routing / bucket logic):

| Hook | Signature |
|---|---|
| `saveEditThenReturnToList()` | `@discardableResult func -> Bool` |
| `addTodoAndStayInCompose()` | `func` |
| `cancelEditAndReturnToList()` | `func` |
| `enterEditForSelectedRow()` | `func` |
| `focusListFromInput()` | `@discardableResult func -> Bool` |
| `closePopoverFromList()` | `func` |
| `handleListKeyDown(_:)` | `func (NSEvent) -> Bool` (installed as the tableView closure in base `loadView`) |
| `performTodoKeyEquivalent(with:)` | `func (NSEvent) -> Bool` -- **genuine override** (tab has an extra cmd+shift h/l swallow branch and a different `.n` body) |
| `syncModeVisibility()` | `func` -- **genuine override** (pane gates scroll/empty-label on `todos.isEmpty`; tab always shows scroll, toggles `newButton`) |

**(C) Lifetime + chrome hooks:**

| Hook | Signature | Pane | Tab |
|---|---|---|---|
| `parentTodoPopover` | `var NSPopover? { get }` | `runtime?.todoPopover` | `runtime?.tabTodoPopover` |
| `shortcutHelpScope` | `var TodoShortcutScope { get }` | `.pane` | `.tab` |
| `clearCompleted()` | `@objc func` (fatalError default; `@objc` so `#selector` in base `loadView` resolves, body overridden) | sends `clearCompletedTodos` | sends `clearCompletedTabTodos` |

`parentTodoPopover` is **invariant #4-critical**: it must be a hook, never hardcoded (see
Risks). The base reads it through the hook each time and never retains it; `shortcutHelpPopover`
remains the only popover the base stores.

**(D) loadView hooks** (real defaults so the pane overrides little):

| Hook | Signature | Default / Pane | Tab |
|---|---|---|---|
| `headerTitle` | `var String { get }` | `"Pane To-Do"` (no default) | `"Tab To-Do"` |
| `headerActionButtons()` | `func -> [NSView]` | default `[clearButton]` | `[clearButton, newButton]` (creates/configures `newButton`) |
| `composePlaceholder` | `var String? { get }` | default `nil` | `"Add a tab task..."` |
| `tableColumnIdentifier` | `var String { get }` | `"todo"` (no default) | `"tabtodo"` |
| `registerDragTypes(on:)` | `func (NSTableView)` | `[todoRowDragType]` | `[tabTodoRowDragType]` |
| `installEmptyState(in:)` | `func (NSView)` | adds `emptyLabel` + its 2 center constraints | default no-op |

`addInput` becomes `lazy var addInput = TodoInputView(placeholder: composePlaceholder ...)`
so the placeholder is set once at first access (in `loadView`), after `self` is fully
initialized. Table wiring split: the base's `loadView` does everything identical
(`dataSource = self`, `delegate = self`, `doubleAction`, the three handler closures,
`style`/`headerView`/etc.) and calls `registerDragTypes(on:)` + `tableColumnIdentifier`.
**Delegate/data-source rule (avoid a false `responds(to:)`):** the base declares ONLY
`numberOfRows(in:)` -- the one *required* `NSTableViewDataSource` member -- as an abstract stub
(safe: both subclasses already implement it and always override, so the base body is never
reached). Every *optional* table method (`tableView(_:viewFor:row:)`, `shouldSelectRow`,
`tableViewSelectionDidChange`, the drag trio, and tab-only `tableView(_:isGroupRow:)` at
`TabTodoPopoverView.swift:760`) is declared on the subclass(es) that implement it, **never** on
the base -- a base stub would make the *pane* advertise tab-only selectors through
`responds(to:)`, and AppKit would then call a fatal/empty default. The base still *conforms* to
both protocols (so `dataSource = self` / `delegate = self` typecheck) but contributes no optional
method.

### What stays in each subclass

Everything generic, scoped, or row-shape-specific: the scope id + `init`, `popoverState`/
`projection`/the `rows`/`todos` accessor, the typed `apply(_:)` (a non-overriding method --
different param type), all `NSTableViewDataSource`/`Delegate` method bodies, all drag
methods + payload types (`TabTodoDragPayload` and the tab drag helpers stay in the tab file),
the `@objc` cell actions (`checkboxToggled`/`deleteTask`; `tab*`/`pane*` variants),
row-lookup/selection helpers, `saveEdit(...)`, `editTitle`/`paneTitle`/`sectionItemCount`
(tab), and the hook overrides from (A)-(D). The tab-only view subclasses
`TabTodoHeaderRowView`/`TabTodoEmptyRowView` and their row ids stay untouched in the tab file.

## Staging (one branch, separately-reviewable commits)

1. **Collapse the root NSView subclasses** -> one `TodoPopoverRootView`, in the new
   `app/TodoPopoverControllerBase.swift`. Pure rename+dedup. **Add the new file to
   `test-ui.sh`'s app-file list (before the two concrete popover files at test-ui.sh:43-44):**
   the UI harness compiles an explicit file list, not a glob, so a new app file is invisible to
   `just test-ui` (and the link fails) until listed. (`just build` uses SwiftPM, which globs
   `app/`, so it needs no change.)
2. **Collapse the NSTableView subclasses** -> one `TodoPopoverTableView`. Pure rename+dedup.
3. **Collapse the key-event functions** -> `todoKeyModifiers`/`todoListKey`. Repoint the
   call sites in both files. No behavior change. (Steps 1-3 are mechanical and create the
   shared file.)
4. **Introduce `TodoPopoverControllerBase` and reparent the pane controller.** Add the base
   (concretes + all hook declarations), change `TodoPopoverViewController`'s superclass,
   delete the now-duplicated members, add the pane hook overrides. Reparent the pane *alone*
   so the base is first exercised by one subclass.
5. **Reparent the tab controller.** Same: change superclass, delete duplicates, add tab hook
   overrides (the cmd+shift h/l branch in its `performTodoKeyEquivalent`; `newButton` in
   `headerActionButtons`). After this, both files contain only divergent parts.
6. **Fold in the reconciler dedup** (`app/Reconcile.swift:387-420`). Extract one generic
   helper and reduce both reconcilers to a 3-line call. Pure Swift, no `@objc` -- generics
   are safe here. Shape:

   ```swift
   private func reconcileTodoPopover<P: Equatable, VC: AnyObject>(
       handle: NSPopover?,
       cache: WritableKeyPath<ReconcilerCaches, P?>,
       as _: VC.Type,
       desired: () -> P?,
       apply: (VC, P) -> Void
   ) {
       let new = (handle?.isShown == true) ? desired() : nil
       guard caches[keyPath: cache] != new else { return }
       if let proj = new, let vc = handle?.contentViewController as? VC { apply(vc, proj) }
       caches[keyPath: cache] = new
   }
   ```
   The scope-match (`case .pane`/`.tab` = `model.todoPopover`) stays inside each `desired:`
   closure -- the one truly varying bit beyond the types.

Runtime call sites need no changes: `AppRuntime` (669-680/688-699 construct + `apply`,
274/279 `closeShortcutHelpPopover`) and `Reconcile` downcast to the concrete subclasses and
call inherited methods -- which still resolve. Leave those downcasts as-is (cosmetic to
widen them to the base; skip to keep blast radius minimal).

## Test plan

Behavior is preserved, so the existing safety net carries most of the load; add exactly one
test for the single genuinely-untested, lifetime-critical path this refactor moves.

- **Existing UI harness is the regression net.** `tests-ui/TodoPopoverViewTests.swift` (747)
  and `tests-ui/TabTodoPopoverViewTests.swift` (617) instantiate the **real** controllers in
  real `NSWindow`s and assert structure-insensitive behavior (row order, empty-state,
  emitted `Msg`s via `runtime.sentMessages`, selection restoration across `apply`,
  compose/edit transitions, keyboard paths via synthesized `keyDownEvent`, pasteboard
  payloads, first-responder restoration). These survive the move to a base class unchanged.
  Run `just test-ui` after step 4 and again after step 5 -- those are the steps that could
  regress first-responder/popover behavior; steps 1-3 and 6 are mechanical.
- **Pure layer already covered, untouched:** `classifyInputAction`/`classifyListAction`/
  `TodoPopoverState`/`resolveTabTodo*` have core unit tests (`lib/DanTermCore/Tests/`). Do
  not add tests for the byte-identical key-table merge (structure-insensitive identity).
- **One new test (the real gap):** no existing test exercises the shortcut-help child popover
  or invariant #4. Add a `uiTest` in both `todoPopoverViewTests()` and
  `tabTodoPopoverViewTests()`. **Setup matters or the test false-passes:**
  `showShortcutHelpPopover` early-returns unless the matching runtime handle is set (`guard let
  parentPopover = runtime?.todoPopover` / `tabTodoPopover`), and the current fixtures leave those
  nil -- so a naive open-then-close test never exercises the parent-popover hook (help never
  opens; the "cleared" assertion passes vacuously). The test must install a real parent
  `NSPopover` into the matching `runtime` handle (a bare `NSPopover()` suffices -- it need not
  host `vc.view`, which already lives in the fixture window) and order the fixture window front
  so the child has a visible anchor, then: (1) trigger help (`toggleShortcutHelp(nil)` / help
  button / `Cmd-/`) and assert it opened via `hasShortcutHelpPopover == true`; (2) drive the
  parent-close path (`vc.viewWillDisappear()`, or the runtime teardown), pumping the run loop if
  the close animates, and assert `hasShortcutHelpPopover == false`. This pins the invariant the
  base's `parentTodoPopover` hook must preserve, against future hook mistakes. (Registration for
  the *test*: it lives inside the existing `todoPopoverViewTests()`/`tabTodoPopoverViewTests()`
  functions, so no new test file or runner entry is needed -- distinct from the new *base class*
  file, which must be listed in `test-ui.sh` per Staging step 1.)

## Risks & how the design preserves behavior

- **ObjC dispatch (core constraint):** `doCommandBy`/`textDidChange` + the `@objc` actions
  live on the concrete non-generic base, inherited by both subclasses; AppKit's runtime sees
  them on the class chain exactly as today. `#selector(clearCompleted)` written in the base
  resolves and dynamic-dispatches to the subclass override.
- **First-responder restoration:** `restoreFirstResponder` is byte-identical and depends only
  on base-visible objects + `isEditing` (hook). It is moved verbatim and still called *last*
  from each subclass's `apply(...)` (which is not extracted), with the same five
  `*WasFirstResponder` flags. No behavior change.
- **Invariant #4 (nested popover, child-before-parent; `docs/design/2026-06-09-appkit-
  lifetime-safety.md:45-47`):** `showShortcutHelpPopover` reaches the parent **only** through
  `parentTodoPopover` (hook), never hardcoded; `closeShortcutHelpPopover()`/`viewWillDisappear`
  still close the child first; the runtime's `dismissTodoPopoverPair`/`dismissTabTodoPopoverPair`
  (`AppRuntime.swift:283-296`) call the inherited `closeShortcutHelpPopover()`. Ordering and
  weak-ref shape are unchanged. The new test locks this down.
- **Two genuine overrides (`performTodoKeyEquivalent`, `syncModeVisibility`):** copied into
  subclass overrides **unchanged** (not merged), so zero drift; the `fatalError` default makes
  a forgotten override fail loudly in the harness immediately.
- **`apply(_:)` dispatch:** each subclass keeps a non-overriding typed `apply(_:)` (distinct
  param type -> not an override; base has none). `applyStoredProjection()` is the only
  base->subclass trampoline. Runtime calls `vc.apply(projection)` on the concrete type.

## Verification

- `just test` -- protocol XCTest + core Swift Testing + DanTermSupport + purity lints + shell
  self-tests (must stay green; this refactor doesn't touch the pure core).
- `just test-ui` -- the AppKit UI harness (run after steps 4 and 5; this is the real
  regression gate for popover/first-responder behavior). Requires a logged-in GUI session.
- `just build` -- confirm the app target compiles and links.
- `just build-run` -- manual smoke: open a pane TODO popover and a tab TODO popover; verify
  compose/edit modes, keyboard nav (j/k, Tab, Cmd-Enter, Cmd-N, Cmd-Backspace), drag-reorder,
  and -- critically -- open shortcut help (Cmd-/) then dismiss the parent popover and confirm
  no crash (invariant #4).

## Future work (out of scope)

- A `makePopoverChrome(size:title:)` free factory if the 320x400 wrapper/header/scroll/empty
  chrome shared with `AlertsPopoverView` ever justifies it. Not a base-class candidate.

## Implementation notes

- `TodoPopoverControllerBase.closeShortcutHelpPopover()` clears the stored child-popover handle before calling `performClose(nil)`, because the UI harness showed AppKit does not synchronously fire the close delegate on this path; `TodoShortcutHelpViewController` still restores the parent popover behavior when AppKit closes the child.
