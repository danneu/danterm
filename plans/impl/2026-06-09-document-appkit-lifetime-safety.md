# Plan: Document AppKit/Ghostty lifetime-safety invariants for future agents

## Context

On 2026-06-09 prod (v0.0.73) crashed with `EXC_BAD_ACCESS`/`SIGSEGV`: a
transient todo `NSTextView` with `allowsUndo = true` registered typing-undo in
the window's shared `UndoManager`; after the popover dismissed and the view
deallocated, Cmd-Z (`Edit > Undo`) messaged the freed text view. The fix
(`ScopedUndoTextView` in `app/TodoInputView.swift:10-14`) is in the tree.

A follow-up crash-hardening audit swept the rest of the app for the same bug
shape -- a longer-lived owner messaging/calling-back a shorter-lived
AppKit/view/controller after teardown -- across undo, NotificationCenter
observers, NSEvent monitors, timers/Tasks, popovers/sheets/controllers, AppKit
target/delegate references, and the Ghostty/C `userdata` boundary. It found **no
other crashable site**: every high-risk construct is correctly scoped
(`[weak self]` + `deinit` teardown, `weak runtime` in adapters, bridge retained
for the surface's life, etc.).

That "why each sibling is safe" knowledge currently lives only in this
conversation and scattered code comments. The need: capture it durably so the
next agent (a) doesn't re-audit `TerminalView`/`GhosttyApp`/the popovers from
scratch, and (b) doesn't reintroduce the bug class when adding a new observer,
timer, popover, undo-enabled field, or C callback. Outcome: one ADR + discovery
wiring (the existing index / Further-reading / Code-Style triggers, plus a
Ghostty-upgrade re-check hook for the one upstream-dependent claim), so the
invariants are found before the risky edit.

Scope (confirmed): **documentation only** -- no enforcement lint. Add the
single highest-value rule to the always-loaded `AGENTS.md` "Code Style" section
with a pointer to the ADR.

## Approach

Follow the repo's existing convention for durable lifecycle decisions: an
ADR in `docs/design/` (same shape as
`docs/design/2026-05-28-pure-core-support-split.md`, which records an analogous
"invariant you must keep"), made discoverable via `docs/design/index.md`, the
`AGENTS.md` "Further reading" triggers, and -- for the one claim that depends on
upstream -- a re-check hook in `docs/upgrading-ghostty.md` so the deferred-free
`nsview` assumption is re-verified exactly when a Ghostty bump can break it, plus
one always-loaded one-liner.

This is a prose change. No production code is touched. The `ScopedUndoTextView`
doc comment already explains *that one class*; the ADR is the general rule + the
map of why the siblings are safe, not a duplicate.

## Changes

### 1. New ADR: `docs/design/2026-06-09-appkit-lifetime-safety.md`

Use the house ADR header (`# Title`, then `` `Status`: Accepted ``,
`` `Date`: 2026-06-09 ``) and sections `## Context` / `## Decision` /
`## Consequences` / `## References` (matches `docs/design/index.md:15-23`).
Writing style per repo norm: ASCII `--`, straight quotes.

Suggested title: **AppKit / Ghostty Lifetime Safety: No Cross-Lifetime Use-After-Free**

- **Context** -- the 2026-06-09 Cmd-Z SIGSEGV (root cause: standalone
  `NSTextView` + `allowsUndo` registering into the window's shared `UndoManager`,
  outliving the view in a `.transient` popover) and that an audit then swept the
  rest of the app and found no second instance.

- **Decision** -- the invariants future changes must preserve (the hardening
  checklist):
  1. A standalone `NSTextView` with `allowsUndo = true` must own its
     `UndoManager` (override `undoManager`, e.g. `ScopedUndoTextView`), never a
     per-call-site `undoManager(for:)` hook. `NSTextField`/`NSSearchField` are
     exempt (window field editor; undo does not outlive the edit session).
  2. Every `NotificationCenter` observer: store the token (block form) or use
     `self` (selector form) and remove it in `deinit`; re-registration guards
     with a prior `removeObserver`.
  3. `NSEvent` monitors: store the token, `removeMonitor` in `deinit`, handler
     `[weak self]`.
  4. New popover/sheet VCs: `weak runtime`; a delegate that nils the owner's
     retained handle on close; close child-before-parent for nested popovers.
  5. C/Ghostty `userdata`: keep the `passRetained` bridge alive until after the
     matching `free`; keep the view back-reference `weak`; never assume a
     deferred-free closure's `nsview` is still alive (safe only while the free
     path does not message it -- re-verify on Ghostty upgrades, per the
     `docs/upgrading-ghostty.md` step added in Change 5).
  6. Prefer `[weak self]` for all stored escaping closures, timers, monitors,
     and async hops; avoid `unowned` (codebase currently has zero).

- **Consequences** -- the cleared-candidate "safe map" so the reasoning is not
  lost (condense to one line each, with file refs):
  - Deferred `ghostty_surface_free` + `nsview = passUnretained(self)`
    (`TerminalView.swift:74,152-169`): safe because the Metal renderer stores no
    `view` field and `Metal.deinit` releases only `queue`/`device`/`layer`
    (`.ghostty-src/src/renderer/Metal.zig:158-161`) -- nothing messages the
    possibly-freed `nsview` during free.
  - `SurfaceBridge` `passRetained` userdata (`TerminalView.swift:68-70,159-164`):
    +1 held for the surface's life, released only after free; `bridge.view` weak.
  - `GhosttyApp` `passUnretained` app userdata (`GhosttyApp.swift:150`):
    app-lifetime owner; async hops `[weak self]` or strong-capture the resolved value.
  - Field-editor undo: sidebar rename / Preferences / search
    (`SidebarView.swift:1367-1434`, `PreferencesPanel.swift:94-118`,
    `SearchOverlayView.swift:86`) -- window-owned editor, no `allowsUndo`.
  - Menu `undo:`/`redo:` (`AppDelegate.swift:246-249`): responder-chain dispatch,
    no window-level `registerUndo` anywhere.
  - `WindowChromeView` selector observers (`:173,181,185-187`) and
    `ScrollableTerminalView` block observers (`:74-122`): removed in `deinit`.
  - `AppRuntime` switcher monitor (`:104-106,111-198`): `removeMonitor` in `deinit`.
  - Popover delegate adapters (`AppRuntime.swift:1414-1464`) + shortcut-help child
    popover (`TodoShortcutHelpView.swift:146-201`): weak runtime/parent, close
    cascade, handle nilled on close.
  - Debouncers / `DispatchSourceTimer`s (`AppRuntime.swift:842-900`,
    `Debouncer.swift`) and IPC actor (`IpcServer.swift`): `[weak self]`,
    cancel/cleanup paths.
  - Known asymmetry (non-crashing, intentionally left): `AppRuntime.deinit`
    cancels the event monitor but not its two `DispatchSourceTimer`s -- benign
    for the app-lifetime singleton (`[weak self]` handlers, `.terminate` cancels
    the enriched timer), but would need a `deinit` cancel if the runtime ever
    becomes per-window. Record it so it is a known trade-off, not a latent bug.

- **References** -- keep these durable and self-contained, so the ADR survives a
  fresh clone: the crash itself is narrated in **Context** above -- do *not* cite
  the user-local `~/Library/Logs/DiagnosticReports/*.ips` (not in the repo, gone
  on any other machine). Durable, in-tree: the fix (`app/TodoInputView.swift`
  `ScopedUndoTextView`) and its test (`tests-ui/TodoInputViewTests.swift`).
  External: Apple "Using Undo in AppKit-Based Applications". The originating plan
  (`plans/wip/sparkling-juggling-gizmo.md`) is a *local, untracked* note
  (`plans/wip/` is not committed -- only `plans/impl/` is), so mention it as
  optional historical context, not a load-bearing link.

### 2. Index it: `docs/design/index.md`

Append to the Notes list (after `:37`), matching the existing line format:

```
- [2026-06-09: AppKit / Ghostty Lifetime Safety](2026-06-09-appkit-lifetime-safety.md)
```

### 3. Discovery trigger: `AGENTS.md` "Further reading"

Add one bullet to the `## Further reading` list in the house
"path -- desc. Read when <trigger>" style, e.g.:

```
- [docs/design/2026-06-09-appkit-lifetime-safety.md](docs/design/2026-06-09-appkit-lifetime-safety.md) -- AppKit/Ghostty lifetime invariants that prevent cross-lifetime use-after-free (the 2026-06-09 Cmd-Z SIGSEGV). Read before adding an `allowsUndo` text view, a NotificationCenter observer, an NSEvent monitor, a timer, a popover/sheet/view-controller, a stored escaping closure, an AppKit target/delegate that can outlive its referent, or any `Unmanaged`/C `userdata` callback.
```

### 4. Always-loaded one-liner: `AGENTS.md` "Code Style"

Add a short subsection under `## Code Style` (this file is `@`-imported into
every session, so keep it tight -- a lead rule plus one specifics sentence, with
the pointer carrying detail). State it as an **owner-lifetime** rule, not "every
construct uses `[weak self]` and tears down in `deinit`" -- that over-claims and
contradicts the code: per the ADR, `AppRuntime`'s two timers are deliberately
*not* cancelled in `deinit`, and C `userdata` is `passRetained`/`passUnretained`
(retained or app-lifetime), not `[weak self]`.

```
### Object lifetime (no use-after-free)

Never let a longer-lived owner message a shorter-lived AppKit object after
teardown. Concretely: a standalone `NSTextView` with `allowsUndo` owns its
`UndoManager` (not the window's shared one); NotificationCenter observers and
NSEvent monitors remove their tokens in `deinit`; timers, stored escaping
closures, and async hops use `[weak self]` or a documented owner-bound lifetime;
`Unmanaged`/C `userdata` is app-lifetime or stays retained until after the
matching `free`. See
[docs/design/2026-06-09-appkit-lifetime-safety.md](docs/design/2026-06-09-appkit-lifetime-safety.md).
```

### 5. Ghostty-upgrade re-verification hook: `docs/upgrading-ghostty.md`

The deferred-`ghostty_surface_free` safety claim (Decision item 5 / the first
Consequences bullet) is the one invariant here that depends on *upstream* code:
it holds only while the Metal renderer's teardown does not message the embedded
`nsview`. A Ghostty bump can silently break it, and none of the discovery wiring
above (index / Further reading / Code Style) fires during an upgrade -- agents
read `docs/upgrading-ghostty.md` for that. So wire the re-check into that doc.

Extend the existing "Steps" -> Step 1 ("Check Ghostty release notes ... Re-audit
...") -- the established "upstream changed, re-audit our assumptions" slot -- with
a parallel re-audit paragraph (ASCII `--`, straight quotes, to match the file):

```
Also re-check the embedded-view lifetime assumption that the AppKit/Ghostty
lifetime-safety ADR ([design/2026-06-09-appkit-lifetime-safety.md](design/2026-06-09-appkit-lifetime-safety.md))
relies on: DanTerm frees surfaces with a deferred `ghostty_surface_free` while
the surface's `nsview` is `passUnretained` and may already be gone. That is safe
only while the renderer's teardown never touches the view -- confirm the new
tag's `src/renderer/Metal.zig` `deinit` still stores no `view` field and releases
only its own GPU objects, and that no other free path messages the `nsview`. If
upstream now touches the view during free, switch to `passRetained` (or otherwise
keep the view alive across the free).
```

Note the link is doc-relative (`design/...`) because `upgrading-ghostty.md` lives
in `docs/`, so the ADR is one level down -- *not* the repo-root-relative
`docs/design/...` form the `AGENTS.md` bullets use. This makes the dependency
bidirectional: Decision item 5 points here, and this step points back at the ADR.

## Out of scope

- No enforcement lint (a `core-purity-lint.sh`-style heuristic over `app/`) --
  explicitly deferred. The ADR notes it as a possible future hardening if the
  bug class recurs.
- No production-code changes; the `AppRuntime.deinit` timer asymmetry is
  documented as a known trade-off, not fixed here.

## Verification

Docs-only, so verification is review + link/format integrity:

1. `just test` -- confirm the prose change does not affect the gate (it must
   stay green; nothing in the test target reads these files).
2. Link check: every relative link resolves --
   `docs/design/index.md` -> the new ADR; both new `AGENTS.md` links -> the new
   ADR; the new `docs/upgrading-ghostty.md` link -> the ADR (doc-relative
   `design/...`, *not* root-relative `docs/design/...`); the ADR's intra-repo
   references (`TodoInputView.swift`, `.ghostty-src/.../Metal.zig`, etc.) point at
   real paths, and the ADR does *not* link the user-local `.ips` crash report.
3. Spot-read the rendered ADR for the house ADR shape (Status/Date header +
   Context/Decision/Consequences/References) and ASCII writing style
   (`--`, straight quotes), matching `2026-05-28-pure-core-support-split.md`.
4. Discoverability sanity check: grep `AGENTS.md` for the new ADR path and
   confirm it appears in both "Further reading" and "Code Style".
5. Upgrade-hook check: `docs/upgrading-ghostty.md` Step 1 now names the
   deferred-free `nsview` re-audit and links the ADR, and the ADR's Decision
   item 5 points back at that step (the dependency is bidirectional).
