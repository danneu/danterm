# Design Decision Docs

## Summary

Create a lightweight ADR-style design-doc system under `docs/design/`, migrate
the existing display-scaling design doc into it with a backdated filename, add a
new focus/display-link decision note, and keep operational runbooks
(`docs/ci.md`, `docs/upgrading-ghostty.md`) at the docs root.

## Key Changes

- Add `docs/design/index.md` as the entry point for design decisions.
  - Document filename format: `YYYY-MM-DD-slug.md`.
  - Document required note shape: title, `Status`, `Date`, `Context`,
    `Decision`, `Consequences`, `References`.
  - Document default statuses: `Accepted`, `Superseded`, `Draft`.
  - List notes in chronological order so the backdated March 5 note appears
    before the May 27 note.

- Move and refactor `docs/scaling.md` into
  `docs/design/2026-03-05-display-scaling.md`.
  - Preserve the current display-scaling invariants and zero-frame guard
    rationale.
  - Convert the content into the new ADR-style structure.
  - Use `Status: Accepted` and `Date: 2026-03-05`, matching when
    `docs/scaling.md` entered the repo.
  - Remove the old `docs/scaling.md` path.

- Add `docs/design/2026-05-27-terminal-focus-display-link.md`.
  - Document the decision that focus is the recovery path for a
    reparent-stalled Ghostty display link.
  - Document that visibility is also part of the display-link lifecycle:
    `AppRuntime.syncSurfaceVisibility` sends occlusion changes, and Ghostty's
    renderer `setVisible` starts the link only when the surface is visible and
    already focused.
  - State that `set_display_id` only retargets the display link and belongs in
    display/screen sync paths.
  - State that `refresh` is not a reliable forced recovery path when Ghostty
    sees vsync as running.
  - Reference relevant local sources: `AppRuntime.focusPaneSurface`,
    `AppRuntime.syncSurfaceVisibility`, `TerminalView.becomeFirstResponder`,
    and the local `.ghostty-src` renderer focus/visibility paths.

- Update `AGENTS.md`.
  - Update the docs tree to include `docs/design/index.md`.
  - Replace the current "Design Docs" list with a pointer to
    `docs/design/index.md`.
  - Keep `docs/ci.md` and `docs/upgrading-ghostty.md` documented as
    operational/release docs, not ADRs.
  - Update the old `docs/scaling.md` link to the new design-note path.

- Include the planned code-comment fix in `app/AppRuntime.swift`.
  - Replace the current long comment with a shorter invariant comment and a
    reference to `docs/design/2026-05-27-terminal-focus-display-link.md`.
  - Do not claim focus is the only display-link restart path; qualify it as the
    recovery path for this reparent/focus transition.
  - Keep behavior unchanged.

## Planned Focus/Display-Link ADR Body

`docs/design/2026-05-27-terminal-focus-display-link.md` should contain:

```md
# Terminal Focus and Display Link Recovery

Status: Accepted
Date: 2026-05-27

## Context

DanTerm hosts libghostty surfaces inside AppKit views. When a terminal pane is
rebuilt, reparented, or shown again after a tab/split transition, the AppKit
first-responder transition is also the point where the live Ghostty surface
learns that it is focused again.

Ghostty renders through a per-surface display link on macOS. A pane can appear
mounted but stop repainting if that display link is running from Ghostty's point
of view while no useful callbacks are reaching the surface after a reparenting
transition. This makes the tempting fixes misleading:

- `ghostty_surface_set_display_id` retargets the display link to a display, but
  it does not restart the focus lifecycle.
- `ghostty_surface_refresh` queues render work, but Ghostty skips ordinary
  draw-frame work while `hasVsync()` reports that the display link is running.
- Visibility is a separate lifecycle input. DanTerm sends effective visibility
  through `syncSurfaceVisibility`, and Ghostty's renderer starts the display
  link from `setVisible` only when the surface is visible and already focused.

## Decision

For a reparent/focus transition, DanTerm treats AppKit focus as the display-link
recovery path. Code that needs to activate a terminal pane should make the
`TerminalView` first responder and let `TerminalView.becomeFirstResponder` call
`ghostty_surface_set_focus(surface, true)`.

DanTerm should keep display-id synchronization in screen-change paths and
visibility synchronization in occlusion/model-visibility paths. It should not add
ad hoc `set_display_id` or `refresh` nudges to terminal focus code to recover a
stalled display link.

## Consequences

Terminal focus helpers should stay small: they should make the pane's
`TerminalView` first responder and rely on the responder callback to push focus
into Ghostty.

Future fixes for repaint stalls should first identify which lifecycle input is
wrong: focus, visibility, display ID, content scale, or size. A repaint issue
should not be fixed by stacking all Ghostty surface calls together unless the
underlying lifecycle inputs are actually wrong.

Comments near focus code should qualify the rule as the reparent/focus recovery
path. They should not claim focus is the only display-link restart path because
Ghostty also starts/stops the link from visibility when the surface is already
focused.

## References

- `app/AppRuntime.swift`: `focusPaneSurface`, `syncSurfaceVisibility`,
  `syncSurfaceDisplayID`
- `app/TerminalView.swift`: `becomeFirstResponder`, `resignFirstResponder`
- `.ghostty-src/src/apprt/embedded.zig`: `ghostty_surface_set_focus`,
  `ghostty_surface_set_display_id`, `ghostty_surface_refresh`
- `.ghostty-src/src/renderer/generic.zig`: `setFocus`, `setVisible`,
  `hasVsync`, `setMacOSDisplayID`
- `.ghostty-src/src/renderer/Thread.zig`: `drawFrame`
```

## Test Plan

- No automated tests are required because this is documentation plus a
  comment-only Swift change.
- Verify with
  `rg 'docs/scaling.md|docs/design' AGENTS.md docs app/AppRuntime.swift` that
  old links are removed and new links are present.
- Verify with `test ! -e docs/scaling.md` that the old migrated doc path was
  removed.
- Optionally run `just test` only if the implementation touches behavior, which
  this plan should not do.

## Assumptions

- Only `docs/scaling.md` is migrated into ADR form; CI and Ghostty upgrade docs
  remain runbooks.
- The first new design note is narrowly scoped to terminal focus/display-link
  recovery.
- New design notes use plain Markdown and ASCII-only punctuation.
