# Add pure test for eager container shape projection

## Summary

Add a narrow test-only fix that pins `desiredContainerShapes(in:)` as
an eager, all-tabs projection. No production code should change because
the implementation already loops over every group and tab.

## Key changes

- Add one test in `tests/ReconcileTests.swift` near the container
  reconciler tests, before `computeContainerOps`.
- Test name: `desiredContainerShapes: eager projection includes selected
  and background tabs`.
- Build an `AppModel` directly with two groups and at least three tabs:
  one selected tab, one background tab in the selected tab's group, and
  one background tab in a different group. Mark the non-selected
  background group `isCollapsed: true`.
- Assert `Set(desiredContainerShapes(in: model).keys)` equals the set of
  every model tab id.
- Assert each returned value equals `containerShape(of:)` for the
  corresponding tab.
- Change `model.selectedTabId` to another tab and assert the projection
  keys and values do not change.

## Test plan

- Mutation-check the new test: temporarily make
  `desiredContainerShapes(in:)` selected-only, selected-group-only, or
  expanded-groups-only, run `just test`, and confirm the new test fails
  for the expected missing-key reason. Restore the implementation.
- Run `just test` with the real implementation and confirm the full
  suite passes.
- Do not add GUI tests; this invariant is pure model projection behavior.

## Assumptions

- Keep the fix test-only.
- Place the test in `ReconcileTests.swift` because that file already owns
  container reconciler pure primitives: `ContainerShape`,
  `computeContainerOps`, and `chromeInvalidation`.
- Use set and dictionary equality, not row or order assertions, so the
  test remains structure-insensitive.
