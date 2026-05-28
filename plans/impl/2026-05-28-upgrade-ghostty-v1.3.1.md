# Upgrade pinned Ghostty: v1.3.0 -> v1.3.1

## Context

DanTerm builds on libghostty (the Zig library from Ghostty), vendored as a
cached `GhosttyKit.xcframework` built from a pinned source tag. We pin
`v1.3.0`; upstream has released `v1.3.1`. This is a routine patch bump to pick
up upstream bug fixes.

It is *not* a no-op. The upgrade requires two DanTerm code changes:

- A **breaking C API change**: the clipboard-read callback now returns `bool`,
  so the Swift app will not even compile against the regenerated header until we
  update our callback.
- A new **app-owned behavioral semantic**: v1.3.1 adds a `progress-style` config
  that DanTerm must honor itself. libghostty does *not* gate on it -- it still
  fires the progress action and expects the apprt to suppress the UI -- so
  without a change DanTerm silently ignores `progress-style = false`.

There is also one additive, non-breaking C API change (a new tab-title action).
Everything else in the 100-commit/53-file delta is upstream's own macOS app, GTK
apprt, CI, Nix packaging, and internal fixes that DanTerm inherits transparently
on rebuild.

The lesson the second item encodes: a patch-bump audit cannot stop at
"compile-breaking C API." It must also cover **app-owned semantics newly exposed
through existing embedded actions** -- a new config key that the apprt (not
libghostty) is responsible for honoring is invisible to the compiler yet changes
correct behavior.

Intended outcome: `.ghostty-version` points at `v1.3.1`, the Swift app compiles
and links against the regenerated header, copy/paste still works, progress
reports honor `progress-style`, and CI rebuilds its GhosttyKit cache
automatically.

## What changed upstream that touches us

From `git compare v1.3.0...v1.3.1` on `ghostty-org/ghostty`, three files affect a
libghostty consumer: `include/ghostty.h` and `src/apprt/embedded.zig` (the C
API), plus `src/config/Config.zig` (a new config key the apprt must honor --
see #3).

### 1. BREAKING -- clipboard-read callback now returns `bool`

`include/ghostty.h`:

```c
-typedef void (*ghostty_runtime_read_clipboard_cb)(void*,
+typedef bool (*ghostty_runtime_read_clipboard_cb)(void*,
                                                   ghostty_clipboard_e,
                                                   void*);
```

`src/apprt/embedded.zig` defines the contract: libghostty allocates a request
`state` pointer, calls our callback with it, then:

```zig
const started = self.app.opts.read_clipboard(self.userdata, ..., state_ptr);
if (!started) { alloc.destroy(state_ptr); return false; }
return true;
```

So the rule is crisp:
- Return **`true`** when we have called (or will call)
  `ghostty_surface_complete_clipboard_request` with `state` -- libghostty then
  leaves `state` alone.
- Return **`false`** when we did *not* complete the request -- libghostty frees
  `state` itself. Completing **and** returning `false` would double-free.

(Note: the old `void` API leaked `state` in our early-return guards because
libghostty always assumed completion. The `bool` return lets us signal "not
started" so libghostty can free it -- the fix below also closes that latent
leak.)

### 2. ADDITIVE (non-breaking) -- new `SET_TAB_TITLE` action

`include/ghostty.h` inserts a new action enum case + union field:

```c
   GHOSTTY_ACTION_SET_TITLE,
+  GHOSTTY_ACTION_SET_TAB_TITLE,
   GHOSTTY_ACTION_PROMPT_TITLE,
...
+  ghostty_action_set_title_s set_tab_title;
```

This shifts the raw values of every enum case after `SET_TITLE` by +1. DanTerm
is unaffected because it switches on the enum **by name** (`handleAction` in
`app/GhosttyApp.swift:226`) and recompiles against the regenerated header; the
switch has a `default:` (line 485) so the new case falls through harmlessly.
Wiring up `SET_TAB_TITLE` is a separate feature (see Out of scope).

### 3. BEHAVIORAL -- new `progress-style` config, gated apprt-side

v1.3.1 adds a config key (`src/config/Config.zig`, `@"progress-style": bool = true`):

> If `true` (default), applications running in the terminal can show graphical
> progress bars using the ConEmu OSC 9;4 escape sequence. If `false`, progress
> bar sequences are silently ignored.

The C API did **not** change -- there is no new field on the progress action and
no new getter; `progress-style` is read through the existing `ghostty_config_get`.
The catch is that **libghostty does not gate on it**: it still fires
`GHOSTTY_ACTION_PROGRESS_REPORT` regardless, and expects the apprt to suppress the
UI. Both reference apprts do exactly that, then return early:

- macOS `Ghostty.App.swift`: `guard config.progressStyle else { ...; surfaceView.progressReport = nil; return }` -- clears any in-flight progress, then bails.
- GTK `surface.zig`: `if (!config.get().@"progress-style") { ...; progress_bar_overlay.setVisible(false); return; }`

DanTerm's `GHOSTTY_ACTION_PROGRESS_REPORT` handler (`app/GhosttyApp.swift:411`)
unconditionally builds a `ProgressState` and sends `.surfaceProgress`, with no
config check -- so it would ignore `progress-style = false` and keep showing
progress. Edit 3 closes this.

### Not relevant to DanTerm

- `build.zig.zon`: version 1.3.0 -> 1.3.1 only; `minimum_zig_version` stays
  `0.15.2`. **No Zig bump.**
- `flake.nix` / `flake.lock` / `nix/package.nix`: upstream's *own* dev/Nix
  build. DanTerm builds via `build-lib.sh`, not Ghostty's flake.
- `macos/...`, `src/apprt/gtk/...`: upstream's SwiftUI app and GTK apprt.
- `src/font/*`, `src/input/*`, `src/terminal/PageList.zig`, shell-integration
  scripts, themes: internal fixes inherited transparently on rebuild.
- `src/config/Config.zig` is *mostly* inherited, but it also adds `progress-style`
  -- an app-owned semantic, handled in #3 / Edit 3, not transparent.
- `src/apprt/embedded.zig` also now runs the inherited working directory
  through `WorkingDirectory.finalize` (validates + warns instead of failing
  late). Internal robustness change, no C API impact -- covered by the cwd
  smoke check below.

## Required changes (3 edits)

### Edit 1 -- bump the pin

`.ghostty-version`: `v1.3.0` -> `v1.3.1` (single source of truth; validated by
`scripts/load-ghostty-version.sh`, format strictly `vX.Y.Z`).

### Edit 2 -- update the clipboard-read callback

`app/GhosttyApp.swift`, the `read_clipboard_cb` closure (currently lines
157-165). Make it return `Bool`: `false` on the two early guards (we did not
complete the request), `true` after completing.

Before:

```swift
            read_clipboard_cb: { userdata, location, state in
                guard let userdata = userdata else { return }
                let bridge = Unmanaged<SurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
                guard let view = bridge.view, let surface = view.surface else { return }
                let str = NSPasteboard.general.string(forType: .string) ?? ""
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
            },
```

After:

```swift
            read_clipboard_cb: { userdata, location, state in
                // ghostty_runtime_read_clipboard_cb returns bool as of Ghostty v1.3.1.
                // true: we completed the request (below), so libghostty leaves `state`.
                // false: we did NOT complete it, so libghostty frees `state` -- returning
                // false here also avoids leaking `state` on the guard-failure paths.
                guard let userdata = userdata else { return false }
                let bridge = Unmanaged<SurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
                guard let view = bridge.view, let surface = view.surface else { return false }
                let str = NSPasteboard.general.string(forType: .string) ?? ""
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
                return true
            },
```

`confirm_read_clipboard_cb` (lines 166-171) is unchanged -- its typedef still
returns `void` in v1.3.1.

### Edit 3 -- honor `progress-style` when gating progress reports

`app/GhosttyApp.swift`. DanTerm already reads config from its retained clone
(`self.config`) with typed helpers `readConfigString(key:)` (line 27) and
`readConfigFloat(key:)` (line 37), and exposes `scrollbarEnabled` (line 23) the
same way. There is no bool reader yet, so add one mirroring those helpers, plus a
`progressStyleEnabled` accessor:

```swift
/// Read a bool config value from the retained app config.
/// Only valid for keys whose C export type is bool (e.g. progress-style).
func readConfigBool(key: String, default def: Bool) -> Bool {
    guard let config = config else { return def }
    var v = def
    guard ghostty_config_get(config, &v, key, UInt(key.utf8.count)) else { return def }
    return v
}

/// Whether progress reports (ConEmu OSC 9;4) should surface, per `progress-style`.
var progressStyleEnabled: Bool { readConfigBool(key: "progress-style", default: true) }
```

Then gate the `GHOSTTY_ACTION_PROGRESS_REPORT` case (line 411): when disabled,
clear any in-flight progress and return early, matching the reference apprts.

```swift
case GHOSTTY_ACTION_PROGRESS_REPORT:
    if let surface = Self.targetSurface(target),
       let bridge = Self.surfaceBridge(from: surface),
       let paneId = bridge.paneId {
        guard progressStyleEnabled else {
            // progress-style = false: libghostty still fires this action, so we
            // suppress it here and clear any progress already shown for the pane.
            DispatchQueue.main.async { [weak self] in
                self?.runtime?.send(.surfaceProgress(paneId: paneId, state: nil))
            }
            return true
        }
        // ... existing raw/state decode + .surfaceProgress send, unchanged ...
    }
    return true
```

`state: nil` is the existing "remove progress" signal -- it is exactly what
`GHOSTTY_PROGRESS_STATE_REMOVE` already maps to in this same switch. No model or
`DanTermCore` change is needed; this is purely an apprt-side gate.

Freshness is automatic: `self.config` is re-cloned on
`GHOSTTY_ACTION_CONFIG_CHANGE` (line 371) and `scrollbarEnabled` already relies on
this, so toggling `progress-style` and reloading takes effect with no extra
wiring.

## What does NOT need to change (and why)

- `build-lib.sh`: the libtool shim (lines 87-95) already documents that
  v1.3.1 lacks the upstream archive-normalization fix, so the workaround stays
  as-is. `ZIG_PKG="$SCRIPT_DIR#zig_0_15"` is unchanged.
- `flake.nix`: Zig pin (`zig_0_15 = ...brew."0.15.2"`, line 107) already
  satisfies `minimum_zig_version = "0.15.2"`.
- CI workflows: the cache key in `ci.yml`, `cache-ghosttykit.yml`, and
  `release-stable.yml` is
  `ghosttykit-v2-${tag}-${hashFiles('build-lib.sh','flake.nix','flake.lock')}-${os}-${arch}`.
  Bumping `.ghostty-version` changes `${tag}`, so the cache auto-invalidates;
  `cache-ghosttykit.yml` is also path-triggered on `.ghostty-version`. First CI
  run after the bump rebuilds the cache (~5-10 min); subsequent runs hit it.
- `docs/upgrading-ghostty.md`: the documented procedure is generic and still
  accurate; no Zig-version section update needed.

## Why no new unit test

The changed code (`read_clipboard_cb`) lives in the impure AppKit/GhosttyKit
C-interop layer (`app/GhosttyApp.swift`), not the pure `DanTermCore` that the
project unit-tests. Exercising it requires libghostty driving a real C callback,
which the project deliberately leaves to compile-time checking + manual smoke
tests rather than mocking GhosttyKit. The fix is compiler-enforced: the closure
must match `ghostty_runtime_read_clipboard_cb` (now `-> Bool`), so omitting the
change is a hard build failure, not a silent regression. `just test` (pure core
+ protocol + shell self-tests) is expected to pass unchanged.

The `read_clipboard_cb` `false` guard paths (no userdata / no surface) are
likewise compile- and review-covered: they only trigger when the surface is torn
down mid-request, which a manual smoke test cannot reliably stage. Exercising the
"return `false` without completing, no double-free" path directly would need a
targeted harness that fakes a missing surface -- out of scope for this bump, but
flagged here so the gap is explicit rather than silently claimed as tested.

Edit 3 (the `progress-style` gate) sits in the same impure layer -- it reads
`ghostty_config_get` and dispatches a `Msg` -- so it has no pure-core seam
either; it is validated by the `progress-style = false` smoke check above.

## Verification

1. `./build-lib.sh` -- fetches/checks out `v1.3.1` into `.ghostty-src/` and
   rebuilds `GhosttyKit.xcframework`. Confirm the regenerated header reflects
   v1.3.1:
   - `lib/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h` shows
     `typedef bool (*ghostty_runtime_read_clipboard_cb)` and
     `GHOSTTY_ACTION_SET_TAB_TITLE`.
2. `just build` -- compiles the Swift app against the new header. This is the
   proof of Edit 2: without it, the build fails on the `read_clipboard_cb`
   return-type mismatch.
3. `just test` -- local gate (protocol XCTest + core Swift Testing + purity
   lint + shell self-tests, including `load-ghostty-version_test.sh` and
   `build-lib-stale-guard_test.sh`). Expected green.
4. `just build-run`, then smoke-test in the running app:
   - Type and render in a terminal (exercises the `ghostty_app_tick` /
     `TickCoalescer` path).
   - Select text + copy, then paste (Cmd-V) into the terminal -- pasted text
     appears (read_clipboard -> complete -> true path).
   - Clear the clipboard, then paste -- no crash. This exercises the
     empty-clipboard *true* path (we complete with an empty string and return
     `true`). It does **not** exercise the `false` guard paths -- those need a
     torn-down surface -- so the no-double-free behavior on `false` is covered by
     the compiler + code review, not this step (see "Why no new unit test").
   - Open a new tab and a new split pane -- each opens in the expected cwd
     (validates the working-directory `finalize` change in embedded.zig).
   - With `progress-style = false` in the loaded Ghostty config, run a progress
     sequence (e.g. `printf '\e]9;4;1;50\a'`): no progress UI appears, and any
     progress already showing for that pane clears (Edit 3). Flip back to the
     default (`true`) and confirm progress shows again.
5. Open a PR. CI rebuilds the GhosttyKit cache from scratch (cache miss on the
   new tag) and builds the Swift app. After merge, `cache-ghosttykit.yml`
   re-warms the cache on `macos-26`.

## Out of scope / optional follow-ups

- **Adopt `GHOSTTY_ACTION_SET_TAB_TITLE` (new in v1.3.1).** Worth understanding
  before treating it as a gap: it is *not* an escape sequence. In v1.3.1 it is
  fired only by a keybinding / command-palette action `set_tab_title:<value>`
  (added upstream in commit `86c2a2e8`, wired in `src/Surface.zig`
  `performBindingAction`; registered as a command in `src/input/command.zig`).
  OSC 0/2 titles emitted by programs still flow through the existing `SET_TITLE`
  action DanTerm already handles. So `SET_TAB_TITLE` only fires for a user who
  has explicitly bound it in the Ghostty config DanTerm loads -- a running
  program cannot reach it.

  How it maps to DanTerm: DanTerm already models two title layers --
  `PaneModel.title` (OSC-driven, via `SET_TITLE` -> `.surfaceTitle`,
  `GhosttyApp.swift:237`, stored per pane in `Update.swift:705`) and
  `TabModel.customTitle`, the tab-level override set through DanTerm's *own*
  inline rename (`.renameTab`, `Update.swift:462`), with
  `displayTitle = customTitle ?? derived(focusedPane.title)` (`Model.swift`).
  `SET_TAB_TITLE` is just the libghostty-routed equivalent of that override, so
  adopting it is small: a `case GHOSTTY_ACTION_SET_TAB_TITLE` that reads
  `action.action.set_tab_title.title`, resolves the target surface to its owning
  tab, and dispatches the existing `.renameTab(tabId, title)` (an empty value
  already maps to "clear the override").

  Why it is optional, not required by the bump: the app compiles and runs
  without it -- the new enum case falls through the `default:` at
  `GhosttyApp.swift:485`. Its value is low and conditional: it only matters to
  users who configure a `set_tab_title` keybind, and those users already have
  DanTerm's richer native rename into the same `customTitle`. Track separately
  as a product decision (do we want Ghostty keybinds to drive DanTerm tab
  names?), not as part of this version bump.
- **Return `false` from `read_clipboard_cb` on an empty paste.** v1.3.1's new
  semantics allow signaling "no text available for a paste request." This is an
  optional optimization and a behavior change (paste-nothing vs paste-empty);
  the plan keeps the behavior-preserving always-complete-then-`true` path.

## Follow Up

- `build-lib.sh`'s fetch step (`git fetch --tags --depth 1 origin "$GHOSTTY_TAG"`,
  build-lib.sh:48) pulls *all* upstream tags, including the rolling `tip` tag. With a
  stale local `tip` in `.ghostty-src/`, git rejects it ("would clobber existing tag")
  and, under `set -euo pipefail`, `./build-lib.sh all` aborts before the version
  checkout -- even though the requested `vX.Y.Z` tag fetched fine. This tripped the
  v1.3.1 bump (worked around by checking out the tag manually, then `./build-lib.sh
  build`). CI is unaffected (it clones fresh via `--branch`). Consider hardening the
  fetch to target only the pinned tag (drop `--tags`, or add `--force`) so local
  re-bumps don't trip on moving tags.
