# Plan: Record the menu-on-ephemeral-view lifetime rule in the AppKit lifetime ADR

## Context

Commit `8da7613` (feat(pane): unify pane context menus into one builder) fixed a
latent AppKit lifetime bug: `NSMenuItem.target` is weak, so a menu built by a
reconcile-ephemeral view (`PaneWrapperView`, recreated per reconcile by
`app/SplitContainerView.swift:94`) could have its targets nil out mid-track,
turning menu actions into silent no-ops. The fix is the `wrapperItem` helper in
`makePaneMenu` (`app/PaneWrapperView.swift:429-437`): every wrapper-targeted
item sets `representedObject = self` (strong) to anchor the owner for the
menu's lifetime.

The rule is unrecorded in the lifetime ADR
(`docs/design/2026-06-09-appkit-lifetime-safety.md`), and worse, the code
comment at `app/PaneWrapperView.swift:431` already cites the doc by a section
name that does not exist in it -- `"AppKit target that can outlive its
referent"` appears only in `AGENTS.md:286`. This change adds the rule to the
ADR so the citation resolves and future menu code doesn't reintroduce the bug
class.

`SidebarView` is the existing precedent for the other safe shape: long-lived
target (the sidebar itself), typed model ids in `representedObject`
(`group.id.rawValue`, `TabIdsBox`, `SetTabColorsInfo`;
`app/SidebarView.swift:751-773,848-951`), and handlers that re-resolve ids
against the live model (`app/SidebarView.swift:954-1045`). Note: not every
stale id fails closed -- a stale group id sent via `.createTab(inGroupId:)`
follows core's documented fallback to the selected tab's group
(`lib/DanTermCore/Sources/DanTermCore/Update.swift:51-60`) -- so the ADR rule
must not overclaim "stale always drops".

Docs change plus one core test. The ADR records the `.createTab(inGroupId:)`
stale-group fallback as intentional, so that contract gets an executable pin --
especially since IPC deliberately pins the opposite rule for unknown explicit
groups (`UpdateIpcTests.swift:869`, "tab.new malformed or unknown explicit
group does not fall back or create"), making the direct-Msg vs IPC distinction
easy to silently break. No behavior changes.

## Change

Two files: `docs/design/2026-06-09-appkit-lifetime-safety.md` and
`lib/DanTermCore/Tests/DanTermCoreTests/UpdateTabTests.swift`.

### 1. Decision list -- append invariant 7 (after item 6, line 56)

Use the exact phrase "AppKit target that can outlive its referent" so the
existing code-comment citation resolves verbatim:

> 7. `NSMenuItem.target` is weak -- an AppKit target that can outlive its
>    referent must not be the only thing keeping the action alive. A menu owned
>    by a reconcile-ephemeral view (for example `PaneWrapperView`) must anchor
>    that owner for the menu's lifetime by setting `representedObject` to it on
>    every owner-targeted item; otherwise a reconcile mid-track deallocates the
>    target and the actions become silent no-ops. Menu actions identify
>    subjects with stable model ids rather than row indices and resolve those
>    ids against the live model at fire time. Stale ids must either fail closed
>    or use an intentional fallback documented at the handler/core boundary.

(Exact wording may be lightly edited during implementation to match the doc's
voice; keep the quoted anchor phrase and both halves of the rule: anchor the
owner, carry ids not indices with fail-closed-or-documented-fallback
resolution.)

### 2. Consequences list -- add one "safe for these specific reasons" bullet

Place it after the "Field-editor undo ..." bullet (line ~81), keeping menu
material adjacent to the other per-site entries:

> - Context menus are safe in two shapes. `SidebarView` menus target the
>   long-lived sidebar and carry model ids or id boxes in `representedObject`;
>   tab actions re-resolve/filter live ids through `currentModel` and core
>   update paths (`app/SidebarView.swift:751-773,848-951,954-1045`). Group
>   "New Tab" is not a fail-closed stale-id example: a stale group id follows
>   `createTab`'s existing fallback to the selected tab's group
>   (`lib/DanTermCore/Sources/DanTermCore/Update.swift:51-60`).
>   `PaneWrapperView.makePaneMenu` targets the reconcile-ephemeral wrapper and
>   anchors it via `representedObject = self` on each wrapper-targeted item
>   (`app/PaneWrapperView.swift:429-437`); its clipboard items target the
>   reconcile-stable `TerminalView` and need no anchor.

### 3. References list -- add one entry

> - `app/PaneWrapperView.swift:425-485` -- `makePaneMenu` / `wrapperItem`, the
>   representedObject anchor for menus owned by a reconcile-ephemeral view.

### 4. Core test -- pin the stale-group fallback the ADR blesses

Add one spec-first test to
`lib/DanTermCore/Tests/DanTermCoreTests/UpdateTabTests.swift`, next to the
existing explicit-`inGroupId` tests (~line 258):

- Setup: model with two groups, selection on a tab in the second (non-first)
  group.
- Act: `update(&model, .createTab(inGroupId: GroupId(rawValue: <fresh UUID>)))`
  with an id matching no group (test-only id inits live in
  `TypedIdTestInit.swift`).
- Assert: the new tab lands in the selected tab's group (the second group),
  not group 0 and not the unknown id -- pinning the fallback at
  `Update.swift:51-60`.
- Preamble per AGENTS.md test-preamble format. Why-it-exists: the lifetime ADR
  documents this fallback as intentional for menu actions, while IPC `tab.new`
  pins no-fallback for unknown explicit groups (`UpdateIpcTests.swift:869`);
  this test keeps the two contracts from drifting silently.
- Red/green check (the behavior already exists, so make the red state by
  mutation): after writing the test, temporarily mutate the unknown-`inGroupId`
  fallback in `lib/DanTermCore/Sources/DanTermCore/Update.swift:53-60` to
  route to group 0 (skip the selected-tab-group branch), run
  `swift test --package-path lib/DanTermCore --filter UpdateTabTests`, confirm
  the new test fails for that reason, revert the mutation, and confirm it
  passes. This satisfies AGENTS.md's fail-first rule and proves the test is
  not vacuous.

In the ADR Consequences bullet (section 2 above), cite the new test alongside
the `Update.swift:51-60` reference so the doc points at its executable
contract.

## Notes / decisions baked in

- Do NOT describe the wrapper as "ids in representedObject": in the wrapper
  shape, `representedObject` holds the *anchor* (self) and the subject
  (`paneId`) is a stored property; only the sidebar carries ids in
  `representedObject`. The text above keeps the two shapes distinct.
- Do NOT claim stale ids always drop. `.createTab(inGroupId:)` intentionally
  falls back to the selected tab's group when the id is unknown
  (`lib/DanTermCore/Sources/DanTermCore/Update.swift:51-60`), so the rule is
  "fail closed or documented fallback", and the Consequences bullet names the
  group "New Tab" item as the fallback case. The new core test (Change 4) pins
  that fallback as the executable contract; it changes no behavior. If a
  stronger fail-closed invariant for stale explicit group ids is ever wanted,
  that is a separate code+test plan (change `.createTab(inGroupId:)` or the
  sidebar handler) -- out of scope here.
- Line-number citations in the doc follow its existing style
  (`file.swift:NN-MM`); re-verify the cited ranges against the working tree at
  edit time in case the files have shifted.
- Plain ASCII, `--` not em-dash, per global writing style.
- No lint/enforcement added, consistent with the ADR's existing "no enforcement
  lint" stance (line 108).

## Verification

- Re-read the edited ADR for flow: Decision item 7 reads as one rule with two
  halves; Consequences bullet sits among the per-site entries; References entry
  matches the doc's format.
- `grep -n "outlive its referent" docs/design/2026-06-09-appkit-lifetime-safety.md app/PaneWrapperView.swift`
  -- both hit, confirming the code comment's citation now resolves.
- `swift test --package-path lib/DanTermCore --filter UpdateTabTests` -- new
  fallback test passes alongside the existing suite.
- `just test` -- full local gate stays green.
