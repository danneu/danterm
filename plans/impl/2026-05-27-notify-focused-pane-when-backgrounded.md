# Notify the focused pane when DanTerm is backgrounded

## Context

Today DanTerm suppresses bell/desktop notifications for the **focused pane of the
selected tab unconditionally** — see the early returns in `app/Update.swift`:

```swift
case .surfaceBell(let paneId):
    // No alert for bell on the focused pane of the selected tab
    if let tab = selectedTab(in: model), tab.focusedPaneId == paneId { return [] }

case .desktopNotification(let paneId, let title, let body):
    if let tab = selectedTab(in: model), tab.focusedPaneId == paneId { return [] }
```

The rationale for suppression is "you're looking right at it, so a notification is
noise." That rationale only holds when DanTerm is frontmost. When DanTerm is
**backgrounded**, the user cannot see the focused pane, so a completion bell / OSC-9
notification on it is exactly when a macOS notification is most useful — yet today it
is dropped. There is no `NSApp.isActive`/frontmost check anywhere downstream.

**Goal:** suppress the focused-pane notification *only* when DanTerm is frontmost.
When backgrounded, the focused pane should behave like any other unseen pane.

**Chosen approach (Option 1 — "auto-clear on return"):** reuse the existing
background-pane path so the backgrounded focused pane gets a macOS notification **and**
an in-app unread alert (the latter is what makes the notification *click* navigate —
`activateAlert` looks the alert up in `model.alerts` and no-ops if it's missing). To
avoid leaving a stale badge on the pane the user is now looking at, clear the selected
tab's focused-pane alerts when the app becomes active, gated on the existing
`.focus` clear mode (manual mode still requires an explicit ack).

Why not the alternatives: a notification with no backing alert makes the click a dead
no-op (fights the "notif click focuses the originating pane" design goal); relying only
on `paneBecameFirstResponder` to clear the badge on return depends on uncertain AppKit
first-responder re-firing, whereas clearing in `appBecameActive` is deterministic and
unit-testable in the pure model.

## Design

App-active state must live in the model because `update()` is pure (no AppKit). The
`.appBecameActive` / `.appResignedActive` Msgs already exist (`app/Msg.swift:131-132`)
and are already dispatched from `AppDelegate.applicationDidBecomeActive(_:)` /
`applicationDidResignActive(_:)` (`app/AppDelegate.swift:727-733`). They currently only
push `.setAppFocus` to Ghostty; we extend them to also record state in the model. **No
new Msg, no new AppDelegate wiring.**

### Changes

1. **`app/Model.swift`** (AppModel struct, ~line 187): add an ephemeral field
   ```swift
   var isAppActive: Bool = true  // ephemeral — excluded from snapshots; gates focused-pane notification suppression
   ```
   Default `true` = frontmost-at-launch (the common case) and preserves the existing
   focused-pane-suppression tests that build models via `makeModel()`. It is **not**
   serialized: `AppModelSnapshot` (`app/Persistence.swift` `toSnapshot()`) maps only
   `groups` + `selectedTabId`, so adding this field cannot break snapshot decode — same
   pattern as the other `// ephemeral` fields (`searchState`, `showAllAlerts`, etc.).

2. **`app/Update.swift` lifecycle handlers** (~lines 815-822):
   - `.appBecameActive`: set `model.isAppActive = true`; then, if
     `model.config.alertClearMode == .focus`, mark the selected tab's focused pane
     alerts read via the existing `markAlertsReadForPane(_:in:)` (`Update.swift:2370`).
     Still return `[.setAppFocus(true)]` (no new command — `markAlertsReadForPane`
     only mutates the model). This mirrors the existing focus-clear call sites
     (`Update.swift:228, 313, 385, 483`), so manual mode is respected for free.
   - `.appResignedActive`: set `model.isAppActive = false` (keep the existing
     `jumpMode` clear and `[.setAppFocus(false)]` return).

3. **`app/Update.swift` suppression guards** (`.surfaceBell` ~714, `.desktopNotification`
   ~745): prepend the active check so suppression only applies when frontmost:
   ```swift
   if model.isAppActive, let tab = selectedTab(in: model), tab.focusedPaneId == paneId {
       return []
   }
   ```
   When `!model.isAppActive`, control falls through to the existing background-pane
   logic (create unread `AlertModel`, insert into `model.alerts`, then
   `throttledNotification(...)`) — no other change needed; throttling and the
   notification-click path are reused as-is.

### Notes / edge cases
- **Background launch** (rare: login item / `open -g` / restore while another app is
  frontmost): `applicationDidBecomeActive` won't fire until first focus, so
  `isAppActive` stays at its `true` default and a focused-pane notification would be
  suppressed during that window. It corrects on the first `applicationDidBecomeActive`
  (by which point suppression is desired anyway). Acceptable; out of scope to seed from
  `NSApp.isActive` at startup.
- **Minimized / occluded while active** (Cmd-M, or DanTerm fully covered without
  switching apps): the app stays active, so `isAppActive` remains `true` and a
  focused-pane bell/OSC-9 is still suppressed even though the pane isn't visible — the
  frontmost proxy doesn't model window visibility. Narrow in practice: minimize is
  usually followed by activating another app (→ `applicationDidResignActive` → notifies),
  and Cmd-H resigns active outright; only "minimized/occluded while still active" slips
  through. Known limitation of the frontmost proxy. Gating on `window.occlusionState`
  (already computed in `syncSurfaceVisibility`) would close it precisely, but threading
  live AppKit visibility into the pure model for a rare transient state isn't worth it.
- No CLI surface change, so `integrations/danterm/SKILL.md` needs no update.

## TDD implementation order

Write the tests first and confirm they fail for the expected reason, then implement
§Design, then confirm green with `just test`. Every new test gets the 3-section
`// Intent / Why it exists / Scenario` preamble (these are spec-first — no incident to
cite). Use the harness helpers: `makeModel()`, `createTab(&model)`,
`hasEffect(commands) { ... }`, `expect`, `expectEqual` (`tests/TestHarness.swift`).

**`tests/UpdateGhosttyTests.swift`** (new — the core behavior):
- `testBellOnFocusedPaneWhileInactiveCreatesAlertAndNotification`: `model.isAppActive =
  false`; `createTab`; bell on the tab's focused pane → assert one unread `.bell` alert
  for that pane **and** a `.sendNotification` command is emitted.
- `testDesktopNotificationOnFocusedPaneWhileInactiveCreatesAlertAndNotification`: same
  with `.desktopNotification(paneId:title:body:)` → assert unread alert + a
  `.sendNotification(_, title, body)` carrying the OSC title/body.
- The existing `testBellOnFocusedPaneIsIgnored` and
  `testDesktopNotificationOnFocusedPaneIsIgnored` stay green unchanged (default
  `isAppActive == true` → still suppressed); they now pin the *frontmost-suppresses*
  branch. Tighten their preambles to say "while app is active."

**`tests/UpdateLifecycleTests.swift`** (new — flag + auto-clear):
- `testAppResignedActiveClearsActiveFlag`: dispatch `.appResignedActive` → assert
  `model.isAppActive == false` (and still returns `[.setAppFocus(false)]`).
- `testAppBecameActiveSetsActiveFlag`: set `isAppActive = false`; dispatch
  `.appBecameActive` → assert `model.isAppActive == true` (and `[.setAppFocus(true)]`).
- `testAppBecameActiveMarksFocusedPaneAlertReadInFocusMode`: `createTab`;
  `isAppActive = false`; bell the focused pane (now creates an unread alert); dispatch
  `.appBecameActive` → that pane's alert `isUnread == false`.
- `testAppBecameActiveDoesNotMarkReadInManualMode`: same but
  `model.config.alertClearMode = .manual` → alert stays `isUnread == true`.
- `testAppBecameActiveLeavesBackgroundPaneAlertUnread`: two tabs; `isAppActive = false`;
  bell both the selected tab's focused pane and a background tab's pane; dispatch
  `.appBecameActive` → only the selected tab's focused-pane alert clears; the background
  pane's alert stays unread. (Pins that we clear only the visible pane.)
- The existing `testAppBecameActive` / `testAppResignedActive` (assert the
  `setAppFocus` command) remain valid — command output is unchanged.

## Verification

- **Unit:** `just test` — all of the above plus the existing suite green.
- **Manual** (`just build-run`, then in the focused pane):
  - **Frontmost, suppressed:** `printf '\a'` (bell) and `printf '\e]9;Build done\a'`
    (OSC-9 desktop notification) with DanTerm in front → no macOS notification.
  - **Backgrounded, notifies:** `sleep 3; printf '\e]9;Build done\a'`, immediately
    Cmd-Tab to another app → after 3s a macOS notification appears for the focused pane.
  - **Click navigates + clears:** click the notification → DanTerm comes forward, the
    originating tab/pane is focused, badge cleared.
  - **Return without clicking (focus mode):** trigger as above, Cmd-Tab back to DanTerm
    instead of clicking → the focused pane's badge auto-clears on activation.
  - **Manual mode:** set `alertClearMode = manual` in the init file → on return the
    badge persists until an explicit ack (Cmd+. / Cmd+Shift+.).
