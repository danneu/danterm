# Hide MRU Switcher on Session Restore

## Summary

Fix the restore/import edge case by restoring the reconciler invariant before
cache reset: `caches.switcher == nil` must mean the persistent switcher panel is
already hidden. The correct fix is to hide the existing `SwitcherPanel` during
session teardown, not to change switcher projection semantics.

## Key Changes

- In `AppRuntime.tearDownCurrentSession()`, call `switcherPanel?.orderOut(nil)`
  before `caches = ReconcilerCaches()`, near the other persistent UI teardown
  calls.
- Add a short intent comment: the switcher panel persists across sessions, so it
  must be hidden before resetting `caches.switcher` to nil.
- Do not nil out or recreate `switcherPanel`; it is launch-created and should
  remain reusable after restore/import.
- Do not change `reconcileSwitcher()` or `desiredSwitcher(in:)`; normal MRU
  show/hide should still be driven only by `model.mruCycle`.

## Public Interfaces

No public API, CLI, snapshot, protocol, command, or model changes.

## Test Plan

- Run `just test` to confirm pure model/update/projection behavior is unchanged.
- Run `just build` to compile the AppKit runtime path that pure tests do not
  cover.
- Manual QA:
  - Open two or more tabs, show the MRU switcher, then commit/cancel; verify it
    still hides normally.
  - Import or restore a valid state after using the switcher; verify no floating
    switcher panel remains and invoking MRU again shows rows for the restored
    tabs.

## Assumptions

- No new automated test is added for `tearDownCurrentSession()` because the
  current test harness does not compile `AppRuntime`/GhosttyKit, and adding a
  runtime test seam for one AppKit `orderOut` call would be disproportionate.
- The implementation plan file is historical context; the durable documentation
  should be the code comment beside the teardown call.
