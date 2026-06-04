# Fix: `.paneBecameFirstResponder` must reject panes from other tabs

## Context

DanTerm sometimes seems to miss Claude Code stop-hook alerts for tabs the user
believes are background tabs. Read-only investigation surfaced one concrete
invariant hole: the `.paneBecameFirstResponder(paneId:)` handler trusts any pane
id and writes it into the **currently selected** tab without verifying the pane
belongs to that tab.

Current handler (`lib/DanTermCore/Sources/DanTermCore/Update.swift:487-498`):

```swift
case .paneBecameFirstResponder(let paneId):
    guard let tab = selectedTab(in: model) else { return [] }
    let oldFocusedId = tab.focusedPaneId
    guard paneId != oldFocusedId else { return [] }

    if model.config.alertClearMode == .focus {
        markAlertsReadForPane(paneId, in: &model)
    }
    updateSelectedTab(&model) { t in t.focusedPaneId = paneId }

    // Persist focused pane so restore opens the right pane within each tab.
    return [.scheduleCheckpoint]
```

If a hidden/background `TerminalView` ever fires `becomeFirstResponder`, this
sets the selected tab's `focusedPaneId` to a pane that lives in a *different*
tab and (in the default `.focus` clear mode) clears that background pane's unread
alerts. Later notification logic can then misclassify the background pane as the
focused pane. The intended outcome of this fix: a foreign pane id is a no-op.

### Desired invariant

`.paneBecameFirstResponder(paneId:)` only updates the selected tab's
`focusedPaneId` when `paneId` belongs to the selected tab's `rootNode`. If
`paneId` belongs to another tab, return `[]` and mutate nothing — no
`focusedPaneId` change, no `markAlertsReadForPane`, no `.scheduleCheckpoint`.

## Step 1 — Failing test (write first)

**Placement:** `lib/DanTermCore/Tests/DanTermCoreTests/UpdatePaneTests.swift`,
immediately after `testPaneBecameFirstResponderSamePane` (ends at line 324),
next to the other `testPaneBecameFirstResponder*` tests. This test is primarily
about focus-membership corruption (alert preservation is a secondary
assertion), so it belongs in `UpdatePaneTests.swift`, not `UpdateAlertTests.swift`.

Mirrors the existing cross-tab setup at `UpdatePaneTests.swift:739-764`
(`createTab` x2, capture ids/panes, `selectTab` back to A, fetch via `tabById`).
Default `alertClearMode` is `.focus` (proven by `testPaneBecameFirstResponder`
clearing an alert with no config change), so the current buggy code *would*
clear tab B's alert — making the unread assertion a real red/green signal.

```swift
    @Test("testPaneBecameFirstResponderIgnoresPaneFromAnotherTab")
    func testPaneBecameFirstResponderIgnoresPaneFromAnotherTab() {
        // Intent: a paneBecameFirstResponder callback carrying a pane id that
        //   belongs to a DIFFERENT tab must not touch the selected tab's
        //   focusedPaneId, must not clear that background pane's alerts, and
        //   must emit no commands.
        // Why it exists: guards the invariant that the handler only adopts a
        //   pane that actually lives in the selected tab. A stray
        //   becomeFirstResponder from a hidden/background TerminalView would
        //   otherwise corrupt the selected tab's focusedPaneId and let later
        //   notification logic misclassify a background pane as focused.
        // Scenario: spec-first cross-tab callback -- tab A is selected, an
        //   unread alert sits on a pane in tab B, and tab B's pane fires the
        //   callback while hidden.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tabBPane = model.groups[0].tabs[1].focusedPaneId

        _ = update(&model, .selectTab(id: tabAId))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tabBPane,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .paneBecameFirstResponder(paneId: tabBPane))

        let tabA = tabById(tabAId, in: model)!
        #expect(model.selectedTabId == tabAId, "selection should be unchanged")
        #expect(tabA.focusedPaneId == paneA, "selected tab focus must not adopt a foreign pane")
        #expect(model.alerts[0].isUnread == true, "background tab's alert must stay unread")
        #expect(commands.isEmpty, "cross-tab callback should emit no commands")
    }
```

Notes:
- `model.selectedTabId == tabAId` is a sanity assertion (this handler never
  changes selection, so it stays green either way) — keep it for documentation.
- The three red-driving assertions are `tabA.focusedPaneId`, `alerts[0].isUnread`,
  and `commands.isEmpty`.

## Step 2 — Verify it fails red

```
swift test --package-path lib/DanTermCore --filter testPaneBecameFirstResponderIgnoresPaneFromAnotherTab
```

Expected failure (current code): `tabA.focusedPaneId` becomes `tabBPane`
(not `paneA`), `alerts[0].isUnread` is `false` (cleared by `markAlertsReadForPane`),
and `commands` is `[.scheduleCheckpoint]` (not empty). All three assertions fail
for the expected reason; the `selectedTabId` assertion passes.

## Step 3 — Minimal fix

In `lib/DanTermCore/Sources/DanTermCore/Update.swift`, add one membership guard
immediately after `guard let tab = selectedTab(in: model)` (line 488), before the
same-pane guard and `markAlertsReadForPane`:

```swift
    case .paneBecameFirstResponder(let paneId):
        guard let tab = selectedTab(in: model) else { return [] }
        // Only adopt a pane that actually lives in the selected tab. A stray
        // becomeFirstResponder from a hidden/background surface must not
        // corrupt this tab's focusedPaneId or clear the foreign pane's alerts.
        guard allPaneIds(tab.rootNode).contains(paneId) else { return [] }
        let oldFocusedId = tab.focusedPaneId
        guard paneId != oldFocusedId else { return [] }
        ...
```

- `allPaneIds(_ node: SplitNodeModel) -> [PaneId]` is a same-module free function
  (`ModelOperations.swift:48`), already used throughout `Update.swift`/tests — no
  new helper needed.
- The legitimate same-tab path is unaffected: the focused pane and its siblings
  are members of `tab.rootNode`, so they pass. (The existing same-pane guard
  already implies membership, so placing the new guard before or after it is
  behaviorally identical; placing it first reads as input validation.)

## Step 4 — Verify green

```
swift test --package-path lib/DanTermCore --filter testPaneBecameFirstResponderIgnoresPaneFromAnotherTab
swift test --package-path lib/DanTermCore --filter UpdatePaneTests
```

Both new test and the surrounding suite (incl. `testPaneBecameFirstResponder`
and `testPaneBecameFirstResponderSamePane`) must pass. If cheap enough, finish
with the full local gate:

```
just test
```

## Hard boundaries / non-goals

- Do **not** change Claude hook scripts.
- Do **not** change notification throttle behavior.
- Do **not** change focused-pane `.desktopNotification` suppression.
- Do **not** change `alert-clear-mode` semantics except by preserving the
  existing rule for valid same-tab focus changes.
- Scope is exactly: one membership guard in `Update.swift` + one test in
  `UpdatePaneTests.swift`.
