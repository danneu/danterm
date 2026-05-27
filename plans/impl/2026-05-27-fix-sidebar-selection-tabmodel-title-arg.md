# Fix `just test-ui` compile break: stale `title:` arg in `sidebarSelectionTab`

## Context

`just test-ui` (-> `./test-ui.sh`, compiles the UI-test target with swiftc + Cocoa)
fails to compile before any test runs:

```
tests-ui/SidebarSelectionCacheTests.swift:203:16: error: extra argument 'title' in call
```

This is a pre-existing latent bug, unrelated to recent work. `TabModel` was
refactored so the focused leaf owns the pane chrome and `title` became a
**computed, read-only** property (`app/Model.swift:126`), not a stored property
or init parameter. The test helper `sidebarSelectionTab` still passes the old
stored `title:` to the synthesized memberwise init, which no longer accepts it.

`TabModel` (`app/Model.swift:111-129`) has no custom init. Its memberwise init's
required params are `id`, `focusedPaneId`, `rootNode`; `customTitle` is optional
(defaults `nil`) and `isZoomed`/`color`/`todos` have defaults. `title` and
`displayTitle` are both computed.

## Decision: drop the argument (don't switch to `customTitle:`)

Investigated whether the helper needs a distinct per-tab display title.
**It does not.** The helper is called from exactly one place
(`tests-ui/SidebarSelectionCacheTests.swift:192`,
`tabs: tabIds.map(sidebarSelectionTab)`), and the two tests in that file assert
only on sidebar **row selection / highlight by tab identity** -- no assertion
reads `.title`, `.displayTitle`, or `.customTitle`, and nothing compares against
a uuid-prefix string. The `title:` value was a cosmetic/debugging label only.

So the fix is to remove the `title:` argument and let chrome derive, rather than
preserving it via `customTitle:`.

## The fix

File: `tests-ui/SidebarSelectionCacheTests.swift` (lines 199-207).

Delete the single `title:` line (203). The helper becomes:

```swift
private func sidebarSelectionTab(_ id: TabId) -> TabModel {
    let paneId = PaneId()
    return TabModel(
        id: id,
        focusedPaneId: paneId,
        rootNode: .leaf(PaneModel(id: paneId))
    )
}
```

This matches the memberwise init exactly (`id`, `focusedPaneId`, `rootNode`;
remaining params take their defaults). No trailing-comma cleanup is needed --
`id: id,` already ends in a comma and `focusedPaneId:` follows.

### Notes / conventions

- No new product test: per DanTerm TDD norms this is a fix to a **test helper**,
  and the "failing test" is the compile error itself. The validation is the
  suite compiling and passing.
- No doc comment / test preamble needed -- it's a `private` test-only fixture
  helper, which the repo conventions explicitly exempt.
- Grep-confirmed this is the only `TabModel(` call site in the repo passing a
  `title:` argument, so no other call sites need touching.

## Out of scope

- No changes to `TabModel` / app code (`app/Model.swift` etc.).
- No changes to `test-ui.sh`'s source list or any other test file.
- Fix stays entirely within the `sidebarSelectionTab` helper.

## Verification

Implementer is on macOS with a display.

1. `just test-ui` -- must compile cleanly (the original error is gone) and run.
   Confirm no further `extra argument`/compile errors were hiding behind the
   first one.
2. All UI tests pass, including the two in `SidebarSelectionCacheTests.swift`
   (cross-group-move highlight preservation; survivor-highlighted-after-close).
3. Sanity: `just test` (pure unit tests) remains green -- it does not exercise
   this file, but confirms nothing else regressed.

## Implementation notes

- Source plan lived outside this checkout at
  `/Users/dan/Code/braid/plans/wip/plan-a-fix-for-quirky-emerson.md`, so
  promotion added this repo-local `plans/impl/` copy and left the external
  source file untouched.
