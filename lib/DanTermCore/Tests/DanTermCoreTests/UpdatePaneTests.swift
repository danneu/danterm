// Swift Testing migration of the legacy `tests/UpdatePaneTests.swift` harness
// suite. Pins the pane-domain Msg paths: splitPane (incl. targeted +
// background variants and theme inheritance), closePane (sibling promotion,
// chrome sync, zoom normalization, container/fallback behavior),
// focusDirection / paneBecameFirstResponder (eager intent, callback ownership, alert
// clear modes), toggleZoomPane, movePane (split/swap intents, zoom + same-
// pane guards), movePaneToTab (cross-tab + cross-group, source-emptying,
// chrome update, defocus, alert clear), and movePaneToNewTab (single-tab
// guard, path A reparenting + path B extraction, alert clear, derived chrome).
// Compound `guard case` destructuring patterns convert to `Issue.record +
// return` to preserve the failure-site count.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdatePaneTests {
    @Test("testSplitPaneProducesCorrectTree")
    func testSplitPaneProducesCorrectTree() {
        // Intent: splitPane on a single leaf turns the root into a horizontal
        //   split with the original pane as the first leaf and the new pane
        //   as the focused second leaf.
        // Why it exists: pins the canonical splitPane shape the runtime
        //   relies on.
        // Scenario: spec-first split -- a fresh tab gains a horizontal split
        //   with two leaves.
        var model = makeModel()
        createTab(&model)
        let originalPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let tab = model.groups[0].tabs[0]

        guard case .split(_, let direction, let first, let second, _) = tab.paneTree.root else {
            Issue.record("root should be a split after splitting")
            return
        }
        #expect(direction == .horizontal)
        if case .leaf(let fid) = first {
            #expect(fid.id == originalPaneId, "first child should be original pane")
        } else {
            Issue.record("first child should be a leaf")
            return
        }
        if case .leaf(let sid) = second {
            #expect(sid.id == tab.paneTree.focusedPaneId, "second child should be new focused pane")
        } else {
            Issue.record("second child should be a leaf")
            return
        }
        #expect(model.allPaneIds.count == 2)
    }

    @Test("testClosePanePromotesSibling")
    func testClosePanePromotesSibling() {
        // Intent: closing one of two siblings collapses the split, leaving
        //   the surviving sibling as the new root leaf.
        // Why it exists: pins the sibling-promotion path closePane relies
        //   on.
        // Scenario: spec-first sibling-promote -- close the newly created
        //   pane in a two-pane tab; the original pane survives.
        var model = makeModel()
        createTab(&model)
        let firstPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let newPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        #expect(newPaneId != firstPaneId, "split should create new pane")

        update(&model, .closePane(paneId: newPaneId))
        let updatedTab = model.groups[0].tabs[0]
        #expect(model.pane(newPaneId) == nil, "closed pane should be removed from panes dict")
        if case .leaf(let remainingId) = updatedTab.paneTree.root {
            #expect(remainingId.id == firstPaneId)
        } else {
            Issue.record("root should be a leaf after closing one of two panes")
            return
        }
    }

    @Test("focusDirection records the neighboring pane eagerly")
    func focusDirectionRecordsNeighborEagerly() {
        // Intent: focusDirection records the neighboring pane before update returns.
        // Why it exists: the declarative responder pass must see the complete focus
        //   decision during the same reconciliation cycle.
        // Scenario: spec-first directional focus -- move left, then right.
        var model = makeModel()
        createTab(&model)
        let leftPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let rightPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        #expect(rightPaneId != leftPaneId)
        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: leftPaneId,
            title: "DanTerm", body: "waiting", createdAt: Date(), isUnread: true
        )]

        let effectsLeft = update(&model, .focusDirection(direction: .horizontal, side: .first))
        #expect(effectsLeft.isEmpty)
        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == leftPaneId)
        #expect(model.alerts[0].isUnread == false,
            "directional focus should clear the target alert eagerly")

        let effectsRight = update(&model, .focusDirection(direction: .horizontal, side: .second))
        #expect(effectsRight.isEmpty)
        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == rightPaneId)
    }

    @Test("testSplitRatioChangedNoEffects")
    func testSplitRatioChangedNoEffects() {
        // Intent: splitRatioChanged updates the targeted split's ratio without a
        //   side-effect command.
        // Why it exists: pins the divider-drag mutation against accidental commands.
        // Scenario: spec-first ratio drag.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))

        guard case .split(let splitId, _, _, _, _) = model.groups[0].tabs[0].paneTree.root else {
            Issue.record("should be a split")
            return
        }

        let commands = update(&model, .splitRatioChanged(splitId: splitId, ratio: 0.3))
        #expect(commands.isEmpty)

        guard case .split(_, _, _, _, let ratio) = model.groups[0].tabs[0].paneTree.root else {
            Issue.record("should still be a split")
            return
        }
        #expect(ratio == 0.3, "ratio should be updated")
    }

    @Test("splitRatioChanged mutates the split's own tab")
    func splitRatioChangedMutatesSplitOwnTab() {
        // Intent: splitRatioChanged resolves the tab that owns the split id,
        //   even when that tab is not selected.
        // Why it exists: hidden but mounted split containers can report ratio
        //   changes for background tabs during window resize, and those changes
        //   need to persist to the tab that actually owns the split.
        // Scenario: spec-first background resize -- tab A has a horizontal split,
        //   tab B is selected, and a resize callback arrives for tab A's split.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        update(&model, .splitFocusedPane(direction: .horizontal))

        guard case .split(let tabASplitId, _, _, _, _) = model.groups[0].tabs[0].paneTree.root else {
            Issue.record("tab A should have a split")
            return
        }

        createTab(&model)
        let tabBId = model.selectedTabId
        let commands = update(&model, .splitRatioChanged(splitId: tabASplitId, ratio: 0.3))

        #expect(commands.isEmpty)

        guard let tabA = tabById(tabAId, in: model) else {
            Issue.record("tab A should still exist")
            return
        }
        guard case .split(_, _, _, _, let ratio) = tabA.paneTree.root else {
            Issue.record("tab A should still have a split")
            return
        }
        #expect(ratio == 0.3, "tab A's split ratio should be updated")

        guard let tabBId, let tabB = tabById(tabBId, in: model) else {
            Issue.record("tab B should still be selected")
            return
        }
        if case .leaf = tabB.paneTree.root {
            // expected
        } else {
            Issue.record("selected tab B should remain a leaf")
        }
    }

    @Test("splitRatioChanged with an unknown split id is a no-op")
    func splitRatioChangedUnknownSplitIdNoOp() {
        // Intent: splitRatioChanged ignores ids that no live tab owns.
        // Why it exists: resize and reconcile paths can race with teardown, and
        //   unknown split ids must not dirty the model or schedule persistence.
        // Scenario: spec-first stale callback -- a split tree exists, but the
        //   callback carries an id that is not present in that tree.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let snapshot = model

        let commands = update(&model, .splitRatioChanged(splitId: SplitId(), ratio: 0.25))

        #expect(commands.isEmpty, "unknown split ids should not schedule persistence")
        #expect(model == snapshot, "unknown split ids should leave the model unchanged")
    }

    @Test("testClosePaneDeepTree")
    func testClosePaneDeepTree() {
        // Intent: closing an inner leaf in a nested tree (here B in
        //   [A, [B, C]]) collapses its parent split and surfaces the
        //   sibling at the outer split level.
        // Why it exists: pins the multi-level collapse path.
        // Scenario: spec-first inner-leaf close.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .vertical))
        let paneC = model.groups[0].tabs[0].paneTree.focusedPaneId

        #expect(model.allPaneIds.count == 3)

        update(&model, .closePane(paneId: paneB))
        #expect(model.pane(paneB) == nil, "paneB should be removed")
        #expect(model.allPaneIds.count == 2)

        let tab = model.groups[0].tabs[0]
        guard case .split(_, .horizontal, let first, let second, _) = tab.paneTree.root else {
            Issue.record("root should be a horizontal split")
            return
        }
        if case .leaf(let fid) = first {
            #expect(fid.id == paneA, "first should be paneA")
        } else {
            Issue.record("first child should be a leaf")
            return
        }
        if case .leaf(let sid) = second {
            #expect(sid.id == paneC, "second should be paneC")
        } else {
            Issue.record("second child should be a leaf")
            return
        }
    }

    @Test("testFocusDirectionNoNeighbor")
    func testFocusDirectionNoNeighbor() {
        // Intent: focusDirection on a single-pane tab emits no commands.
        // Why it exists: pins the no-neighbor guard.
        // Scenario: spec-first single-pane focus.
        var model = makeModel()
        createTab(&model)

        let commands = update(&model, .focusDirection(direction: .horizontal, side: .first))
        #expect(commands.count == 0, "no commands when no neighbor exists")
    }

    @Test("testQuadrantFocusRightPreservesTopRowDespiteLastFocused")
    func testQuadrantFocusRightPreservesTopRowDespiteLastFocused() {
        // Intent: in a 2x2 grid, focus-right from the top-left pane lands on
        //   the top-right pane (same row), even when the bottom-right pane was
        //   the most recently focused pane in the right column.
        // Why it exists: locks in the "directional move preserves the
        //   perpendicular position" invariant ahead of a planned last-focused
        //   tie-breaker. That tie-breaker must only fire when the source pane
        //   spans the whole perpendicular extent (no row hint); in a full grid
        //   the row hint must always win, so this guards against the new
        //   behavior leaking into the grid case.
        // Scenario: spec-first grid-navigation guard. Build TL/BL | TR/BR so BR
        //   is the last-focused pane in the right column, then focus-right from
        //   TL must still pick TR, not BR.
        var model = makeModel()
        createTab(&model)
        let tl = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let tr = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .paneBecameFirstResponder(paneId: tl))
        update(&model, .splitFocusedPane(direction: .vertical))  // TL -> TL/BL, focus BL
        update(&model, .paneBecameFirstResponder(paneId: tr))
        update(&model, .splitFocusedPane(direction: .vertical))  // TR -> TR/BR, focus BR
        let br = model.groups[0].tabs[0].paneTree.focusedPaneId
        // BR is now the most-recently focused pane in the right column.

        update(&model, .paneBecameFirstResponder(paneId: tl))
        let effects = update(&model, .focusDirection(direction: .horizontal, side: .second))

        #expect(effects.isEmpty)
        #expect(selectedTab(in: model)?.paneTree.focusedPaneId == tr,
            "focus-right from TL must preserve the top row (-> TR), not jump to BR \(br)")
    }

    @Test("testQuadrantFocusRightPreservesBottomRowDespiteLastFocused")
    func testQuadrantFocusRightPreservesBottomRowDespiteLastFocused() {
        // Intent: in a 2x2 grid, focus-right from the bottom-left pane lands on
        //   the bottom-right pane (same row), even when the top-right pane was
        //   the most recently focused pane in the right column.
        // Why it exists: the mirror of the top-row guard -- ensures the planned
        //   last-focused tie-breaker never overrides the row hint for either
        //   row of the grid.
        // Scenario: spec-first grid-navigation guard. Make TR the last-focused
        //   pane in the right column, move to BL, then focus-right must pick
        //   BR, not TR.
        var model = makeModel()
        createTab(&model)
        let tl = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let tr = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .paneBecameFirstResponder(paneId: tl))
        update(&model, .splitFocusedPane(direction: .vertical))  // TL -> TL/BL, focus BL
        let bl = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .paneBecameFirstResponder(paneId: tr))
        update(&model, .splitFocusedPane(direction: .vertical))  // TR -> TR/BR, focus BR
        let br = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .paneBecameFirstResponder(paneId: tr))  // TR last-focused in right column
        update(&model, .paneBecameFirstResponder(paneId: bl))
        let effects = update(&model, .focusDirection(direction: .horizontal, side: .second))

        #expect(effects.isEmpty)
        #expect(selectedTab(in: model)?.paneTree.focusedPaneId == br,
            "focus-right from BL must preserve the bottom row (-> BR), not jump to TR \(tr)")
    }

    @Test("testPaneBecameFirstResponder")
    func testPaneBecameFirstResponder() {
        // Intent: paneBecameFirstResponder updates focusedPaneId, marks the
        //   new pane's alerts read (default focus mode), without a command.
        // Why it exists: pins the AppKit callback path the runtime relies
        //   on to converge on the new pane.
        // Scenario: spec-first callback -- paneB focused, callback hands
        //   focus to paneA; paneA's alert clears.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId

        model.updatePane(paneA) { $0.session?.title = "my-title" }
        model.updatePane(paneA) { $0.session?.cwd = "/tmp/foo" }
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        // paneB is focused. Simulate paneA becoming first responder.
        let commands = update(&model, .paneBecameFirstResponder(paneId: paneA))
        _ = paneB

        let tab = model.groups[0].tabs[0]
        #expect(tab.paneTree.focusedPaneId == paneA, "focused pane should change")
        #expect(model.alerts[0].isUnread == false, "alert should be marked read")
        #expect(commands.isEmpty)
    }

    @Test("a focus report for the pane the model already targets changes nothing")
    func testPaneBecameFirstResponderForDesiredTarget() {
        // Intent: dispatching the focus report for the target `desiredPaneFocus`
        //   already names leaves the whole model unchanged.
        // Why it exists: this is the premise that let the responder echo be deleted
        //   rather than routed. The pane-focus pass only ever moves the responder to
        //   the target this projection names, so an echo from that move could carry
        //   no new fact -- there was nothing to route, only a sweep to re-enter.
        // Scenario: spec-first. One pane holds focus, an unread alert, and search
        //   state the terminal owns; the report names that same pane.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.updatePane(paneId) {
            $0.live.search = SearchModel(needle: "hit", focusOwner: .terminal)
        }
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        #expect(desiredPaneFocus(in: model) == .terminal(paneId))

        let commands = update(&model, .paneBecameFirstResponder(paneId: paneId))

        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == paneId)
        #expect(model.alerts[0].isUnread == true, "the report cleared alerts nobody read")
        #expect(model.pane(paneId)?.live.search?.focusOwner == .terminal)
        #expect(desiredPaneFocus(in: model) == .terminal(paneId))
        #expect(commands.isEmpty)
    }

    @Test("testPaneBecameFirstResponderSamePane")
    func testPaneBecameFirstResponderSamePane() {
        // Intent: callback for the already-focused pane emits no commands.
        // Why it exists: pins the idempotence guard.
        // Scenario: spec-first idempotent callback.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        let commands = update(&model, .paneBecameFirstResponder(paneId: paneId))
        #expect(commands.count == 0, "same pane should return no commands")
    }

    @Test("testPaneBecameFirstResponderIgnoresPaneFromAnotherTab")
    func testPaneBecameFirstResponderIgnoresPaneFromAnotherTab() {
        // Intent: a paneBecameFirstResponder callback carrying a pane id that
        //   belongs to a different tab must not touch the selected tab's
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
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let tabBPane = model.groups[0].tabs[1].paneTree.focusedPaneId

        _ = update(&model, .selectTab(id: tabAId))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tabBPane,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .paneBecameFirstResponder(paneId: tabBPane))

        let tabA = tabById(tabAId, in: model)!
        #expect(model.selectedTabId == tabAId, "selection should be unchanged")
        #expect(tabA.paneTree.focusedPaneId == paneA, "selected tab focus must not adopt a foreign pane")
        #expect(model.alerts[0].isUnread == true, "background tab's alert must stay unread")
        #expect(commands.isEmpty, "cross-tab callback should emit no commands")
    }

    @Test("testPaneBecameFirstResponderLeavesAlertUnreadInManualMode")
    func testPaneBecameFirstResponderLeavesAlertUnreadInManualMode() {
        // Intent: in manual alert-clear mode, focus does not clear alerts.
        // Why it exists: pins the per-config gating of the alert clear
        //   path.
        // Scenario: spec-first manual mode -- focus paneA with an unread
        //   alert; the alert stays unread.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .paneBecameFirstResponder(paneId: paneA))

        #expect(model.alerts[0].isUnread == true, "manual mode should leave alert unread")
    }

    @Test("testClosePaneSyncsTabChromeFromSurvivingPane")
    func testClosePaneSyncsTabChromeFromSurvivingPane() {
        // Intent: after a pane close, the surviving session's title/cwd flow
        //   onto the tab (chrome resync).
        // Why it exists: pins the title/subtitle sync the window chrome
        //   reads.
        // Scenario: spec-first survivor-chrome -- paneA has title +cwd;
        //   close paneB; tab adopts paneA's chrome.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        model.updatePane(paneA) { $0.session?.title = "pane-a-title" }
        model.updatePane(paneA) { $0.session?.cwd = "/tmp/pane-a" }
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .closePane(paneId: paneB))

        let tab = model.groups[0].tabs[0]
        #expect(tab.paneTree.focusedPaneId == paneA)
        #expect(tabTitle(tab) == "pane-a-title")
        #expect(tabSubtitle(tab) == "/tmp/pane-a")
    }

    @Test("testClosePaneInCollapsedGroupCloses")
    func testClosePaneInCollapsedGroupCloses() {
        // Intent: closing a pane inside a collapsed group still mutates the model.
        // Why it exists: pins that collapse is purely a view concern -- it
        //   does not gate model mutations.
        // Scenario: spec-first collapsed close.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        model.updatePane(paneA) { $0.session?.title = "pane-a-title" }
        model.groups[0].isCollapsed = true

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .closePane(paneId: paneB))

        #expect(model.pane(paneB) == nil, "paneB should be closed")
        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == paneA, "paneA should refocus")
    }

    @Test("closePane with remaining panes rebuilds the visible tab")
    func closePaneWithRemainingPanesRebuildsVisibleTab() {
        // Intent: closing a pane that still has a sibling keeps the tab
        //   alive (selection stays on the tab; sibling pane survives).
        // Why it exists: pins the "tab survives sibling-close" rule.
        // Scenario: spec-first sibling-survives.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneToClose = model.groups[0].tabs[0].paneTree.focusedPaneId
        let sibling = allPaneIds(model.groups[0].tabs[0].paneTree.root).first { $0 != paneToClose }!

        update(&model, .closePane(paneId: paneToClose))

        #expect(model.pane(paneToClose) == nil, "closed pane's leaf is gone")
        #expect(model.pane(sibling) != nil, "sibling survives, so selection stays on this tab")
    }

    @Test("closePane closing selected tab removes container and shows fallback")
    func closePaneClosingSelectedTabRemovesContainerShowsFallback() {
        // Intent: closing the last pane of the selected tab selects the
        //   fallback tab; the session-existence net tears down only the
        //   closed pane.
        // Why it exists: pins the "selected-tab closes -> fallback shown"
        //   path with the session teardown invariant.
        // Scenario: spec-first selected-tab close.
        var model = makeModel()
        createTab(&model)
        let fallbackTabId = model.groups[0].tabs[0].id
        createTab(&model)
        let closingPaneId = model.groups[0].tabs[1].paneTree.focusedPaneId
        let liveBefore = Set(model.allPaneIds)

        update(&model, .closePane(paneId: closingPaneId))

        #expect(model.selectedTabId == fallbackTabId, "closing selected tab should select fallback")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model) == Set([closingPaneId]),
            "closed tab's pane session is torn down")
    }

    // MARK: - Zoom Tests

    @Test("testToggleZoomOnSplit")
    func testToggleZoomOnSplit() {
        // Intent: toggleZoomPane flips a split tab's isZoomed to true.
        // Why it exists: pins the zoom mutation the container reconciler
        //   reads to rebuild.
        // Scenario: spec-first zoom on.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))

        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)
    }

    @Test("testToggleZoomOff")
    func testToggleZoomOff() {
        // Intent: a second toggle clears isZoomed.
        // Why it exists: pins the symmetric off branch.
        // Scenario: spec-first zoom off.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .toggleZoomPane(paneId: nil))

        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == false)
    }

    @Test("testToggleZoomNoOpOnSinglePane")
    func testToggleZoomNoOpOnSinglePane() {
        // Intent: toggleZoomPane is a no-op on a single-pane tab.
        // Why it exists: pins the no-op guard so zoom has no meaning when
        //   there's nothing to hide.
        // Scenario: spec-first single-pane zoom.
        var model = makeModel()
        createTab(&model)

        let commands = update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == false)
        #expect(commands.count == 0, "no commands on single pane")
    }

    @Test("testCloseZoomedPaneNormalizesZoom")
    func testCloseZoomedPaneNormalizesZoom() {
        // Intent: closing a pane in a zoomed split that leaves only one
        //   pane normalizes isZoomed to false.
        // Why it exists: pins the "single pane can't be zoomed" invariant.
        // Scenario: spec-first zoom-normalize.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)

        update(&model, .closePane(paneId: paneB))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == false, "zoom should normalize when single pane remains")
        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == paneA)
    }

    @Test("testCloseZoomedPaneClearsZoomWithMultiplePanesRemaining")
    func testCloseZoomedPaneClearsZoomWithMultiplePanesRemaining() {
        // Intent: closing the zoomed pane clears isZoomed even when other
        //   panes remain (focus moves to a sibling).
        // Why it exists: pins the "close zoomed pane -> unzoom" rule.
        // Scenario: spec-first close zoomed multi-remain.
        var model = makeModel()
        createTab(&model)

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .vertical))
        let paneC = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)

        update(&model, .closePane(paneId: paneC))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == false, "zoom should clear when zoomed pane is closed")
        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == paneB, "focus should move to sibling")
    }

    @Test("testSplitWhileZoomedClearsZoom")
    func testSplitWhileZoomedClearsZoom() {
        // Intent: splitPane while zoomed clears isZoomed.
        // Why it exists: pins the zoom-clear interaction with new layout.
        // Scenario: spec-first split-while-zoomed.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)

        update(&model, .splitFocusedPane(direction: .vertical))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == false, "split should clear zoom")
    }

    @Test("testFocusDirectionWhileZoomedClearsZoom")
    func testFocusDirectionWhileZoomedClearsZoom() {
        // Intent: focusDirection while zoomed clears isZoomed.
        // Why it exists: pins the zoom-clear interaction with directional
        //   focus.
        // Scenario: spec-first focus-while-zoomed.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)

        update(&model, .focusDirection(direction: .horizontal, side: .first))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == false, "focus direction should clear zoom")
    }

    // MARK: - Pane-Scoped Tab Resolution Tests

    @Test("closePane removes a background-tab pane from its own tab")
    func closePaneBackgroundTabRemovesFromOwnTab() {
        // Intent: .closePane for a pane living in a non-selected tab removes
        //   the leaf from THAT tab's tree and leaves the selected tab (tree,
        //   isZoomed) untouched.
        // Why it exists: pins closePane's tab resolution to the pane's own
        //   tab (mirroring .splitPane) so a pane-scoped close can never act
        //   on whatever tab happens to be selected. Spec-first.
        var fx = makeTwoTabFixture()
        let selectedBefore = fx.model.groups[0].tabs.first { $0.id == fx.tabB }!

        update(&fx.model, .closePane(paneId: fx.a1))

        let tabA = fx.model.groups[0].tabs.first { $0.id == fx.tabA }!
        if case .leaf(let survivor) = tabA.paneTree.root {
            #expect(survivor.id == fx.a2, "tab A should collapse to its surviving sibling")
        } else {
            Issue.record("tab A's root should be a leaf after the background close")
            return
        }
        let tabB = fx.model.groups[0].tabs.first { $0.id == fx.tabB }!
        #expect(tabB == selectedBefore, "selected tab must be untouched by a background-tab close")
    }

    @Test("closePane on a background tab's last pane closes that tab, not the selected one")
    func closePaneBackgroundLastPaneClosesOwnTab() {
        // Intent: when the closed pane was its tab's last pane, the close
        //   cascades to .closeTab of the pane's OWN tab; the selected tab
        //   survives and stays selected.
        // Why it exists: pins the last-pane cascade against resolving the
        //   selected tab's id, which would close the wrong tab. Spec-first.
        var fx = makeTwoTabFixture(tabAIsSplit: false)
        let selectedBefore = fx.model.groups[0].tabs.first { $0.id == fx.tabB }!

        update(&fx.model, .closePane(paneId: fx.a1))

        #expect(fx.model.groups[0].tabs.map(\.id) == [fx.tabB], "only the pane's own tab should close")
        #expect(fx.model.selectedTabId == fx.tabB, "selection must stay on the surviving tab")
        #expect(fx.model.groups[0].tabs[0] == selectedBefore, "selected tab must be untouched")
    }

    @Test("sessionEnded for a background-tab pane removes it and preserves the selected tab's zoom")
    func sessionEndedBackgroundTabPaneIsRemoved() {
        // Intent: .sessionEnded for a pane in a non-selected tab removes the
        //   pane from its own tab's tree and does not clear the selected
        //   tab's isZoomed.
        // Why it exists: regression test for the ghost-pane bug. .sessionEnded
        //   routes into .closePane, which resolved selectedTab(in:); for a
        //   background-tab pane removeLeaf missed, so the dead pane stayed in
        //   its real tab as a ghost and the selected tab's isZoomed was
        //   clobbered to false.
        // Scenario: a shell in a split background tab exits (e.g. the user ran
        //   `exit` and switched tabs before it fired); switching back showed
        //   the dead pane still in the layout, and the selected tab lost its
        //   zoom state.
        var fx = makeTwoTabFixture()

        let sessionId = fx.model.pane(fx.a1)!.session!.id
        update(&fx.model, .sessionEnded(sessionId: sessionId))

        #expect(fx.model.pane(fx.a1) == nil, "the dead pane must leave its tab's tree, not linger as a ghost")
        let tabB = fx.model.groups[0].tabs.first { $0.id == fx.tabB }!
        #expect(tabB.paneTree.isZoomed == true, "selected tab's zoom must survive a background-tab session close")
    }

    @Test("toggleZoomPane(paneId:) toggles the pane's own tab; nil keeps selected-tab behavior")
    func toggleZoomPanePaneScoped() {
        // Intent: a non-nil paneId toggles isZoomed on the tab owning that
        //   pane, leaving the selected tab alone; paneId: nil keeps acting on
        //   the selected tab (the menubar path).
        // Why it exists: pins the pane-scoped zoom so a stale context menu
        //   acts on the pane it was built for, while the menubar's
        //   selected-tab semantics stay intact. Spec-first.
        var fx = makeTwoTabFixture()

        update(&fx.model, .toggleZoomPane(paneId: fx.a1))

        let tabA = fx.model.groups[0].tabs.first { $0.id == fx.tabA }!
        let tabB = fx.model.groups[0].tabs.first { $0.id == fx.tabB }!
        #expect(tabA.paneTree.isZoomed == true, "pane-scoped zoom should toggle the pane's own tab")
        #expect(tabB.paneTree.isZoomed == true, "selected tab's zoom must be untouched by a pane-scoped toggle")

        update(&fx.model, .toggleZoomPane(paneId: nil))
        let tabBAfterNil = fx.model.groups[0].tabs.first { $0.id == fx.tabB }!
        #expect(tabBAfterNil.paneTree.isZoomed == false, "nil paneId should keep toggling the selected tab")
    }

    @Test("a zoom request zooms and focuses the pane it names")
    func toggleZoomPaneZoomsTheNamedPane() {
        // Intent: naming a pane that does not hold its tab's focus zooms that
        //   pane and moves focus to it; naming a second pane in an
        //   already-zoomed tab moves the zoom rather than leaving the tab; a
        //   request naming the zoomed pane clears the zoom.
        // Why it exists: `paneId` used to select only the tab, so the zoom
        //   landed on whichever pane already held focus. Once every pane's
        //   toolbar offers a zoom button, clicking pane B while pane A holds
        //   focus would have zoomed A. Spec-first.
        var fx = makeTwoTabFixture()
        let a2 = fx.a2!

        update(&fx.model, .toggleZoomPane(paneId: a2))

        var tabA = fx.model.groups[0].tabs.first { $0.id == fx.tabA }!
        #expect(tabA.paneTree.zoomedPaneId == a2, "the named pane should be the zoomed one")
        #expect(tabA.paneTree.focusedPaneId == a2, "a zoomed pane must hold its tab's focus")

        update(&fx.model, .toggleZoomPane(paneId: fx.a1))

        tabA = fx.model.groups[0].tabs.first { $0.id == fx.tabA }!
        #expect(
            tabA.paneTree.zoomedPaneId == fx.a1,
            "zooming a sibling of the zoomed pane should move the zoom, not leave the tab")

        update(&fx.model, .toggleZoomPane(paneId: fx.a1))

        tabA = fx.model.groups[0].tabs.first { $0.id == fx.tabA }!
        #expect(tabA.paneTree.zoomedPaneId == nil, "naming the zoomed pane should clear the zoom")
        #expect(tabA.paneTree.focusedPaneId == fx.a1, "unzoom leaves focus where the zoom put it")
    }

    @Test("a zoom request naming a single-pane tab's pane is refused")
    func toggleZoomPaneRefusesSinglePaneByName() {
        // Intent: the single-pane guard holds on the pane-scoped path too.
        // Why it exists: the reducer now writes focus before zoom, so a tab
        //   with nothing to hide must still come out unzoomed. Spec-first.
        var fx = makeTwoTabFixture(tabAIsSplit: false)

        let commands = update(&fx.model, .toggleZoomPane(paneId: fx.a1))

        let tabA = fx.model.groups[0].tabs.first { $0.id == fx.tabA }!
        #expect(tabA.paneTree.isZoomed == false, "a lone pane has nothing to hide")
        #expect(commands.isEmpty, "a refused zoom asks for no side effects")
    }

    @Test("a zoom request's focus move clears alerts only in the selected tab")
    func toggleZoomPaneFocusMoveClearsAlertsInSelectedTabOnly() {
        // Intent: under the focus alert-clear mode, zooming a pane in the
        //   selected tab marks that pane's alerts read; the same request aimed
        //   at a background tab leaves them unread.
        // Why it exists: the zoom's focus move is a real focus change on the
        //   selected tab, but a background tab's pane never becomes visible, so
        //   its alerts must survive until the user opens that tab. Spec-first.
        var fx = makeTwoTabFixture()
        fx.model.config.alertClearMode = .focus
        let a2 = fx.a2!
        let b2 = allPaneIds(
            fx.model.groups[0].tabs.first { $0.id == fx.tabB }!.paneTree.root
        ).first { $0 != fx.b1 }!

        for paneId in [a2, b2] {
            fx.model.alerts.insert(
                AlertModel(
                    id: AlertId(), kind: .bell, paneId: paneId,
                    title: "DanTerm", body: "alert", createdAt: Date(), isUnread: true),
                at: 0)
        }

        update(&fx.model, .toggleZoomPane(paneId: a2))
        update(&fx.model, .toggleZoomPane(paneId: b2))

        #expect(
            fx.model.alerts.first { $0.paneId == b2 }?.isUnread == false,
            "the selected tab's newly focused pane should have its alerts cleared")
        #expect(
            fx.model.alerts.first { $0.paneId == a2 }?.isUnread == true,
            "a background tab's pane gains no visible focus, so its alerts stay unread")
    }

    @Test("closing a background-tab pane preserves the successor's unread alert")
    func closePaneBackgroundTabPreservesSuccessorAlert() {
        // Intent: in focus alert-clear mode, closing a pane in a non-selected
        //   tab removes the pane but leaves the successor pane's unread alert
        //   unread; the same close on the selected tab still marks the
        //   successor's alerts read.
        // Why it exists: the focus-mode markAlertsReadForPane(nextFocus) call
        //   must be gated on the close happening in the selected tab -- a
        //   background survivor never actually gains user-visible focus, so
        //   its alerts must survive until the user views the tab. The
        //   pane-removal assertion is what makes this red pre-fix (the
        //   background close used to no-op against the wrong tree, so the
        //   alert leg alone would pass trivially). Spec-first.
        var fx = makeTwoTabFixture()
        #expect(fx.model.config.alertClearMode == .focus)
        fx.model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: fx.a2!,
            title: "DanTerm", body: "bell", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isUnread: true
        )]

        update(&fx.model, .closePane(paneId: fx.a1))

        #expect(fx.model.pane(fx.a1) == nil, "the closed pane must actually leave its tab's tree")
        #expect(fx.model.alerts[0].isUnread == true,
                "background successor's alert must stay unread until the user views the tab")

        // Selected-tab leg: same close with tab A selected marks the successor read.
        var selected = makeTwoTabFixture()
        selected.model.selectedTabId = selected.tabA
        selected.model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: selected.a2!,
            title: "DanTerm", body: "bell", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isUnread: true
        )]

        update(&selected.model, .closePane(paneId: selected.a1))

        #expect(selected.model.alerts[0].isUnread == false,
                "selected-tab successor gains focus, so its alert is marked read")
    }

    @Test("closing a non-focused pane preserves focus and its unread alert")
    func closePaneNonFocusedPanePreservesFocusAndAlert() {
        // Intent: closing a background pane in the selected tab keeps focus on
        //   the pane the user is viewing and leaves the successor's alert unread.
        // Why it exists: closePane used removeLeaf's successor unconditionally,
        //   so closing a non-focused pane stole focus and acknowledged its alert.
        // Scenario: spec-first selected-tab close -- pane A stays focused while
        //   pane B closes and pane C, B's successor, has an unread alert.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .vertical))
        let paneC = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .paneBecameFirstResponder(paneId: paneA))
        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: paneC,
            title: "DanTerm", body: "bell", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isUnread: true
        )]

        update(&model, .closePane(paneId: paneB))

        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == paneA,
                "closing a non-focused pane must not steal focus")
        #expect(model.alerts[0].isUnread == true,
                "the successor's alert must remain unread when focus did not move")
    }

    @Test("closePane for a vanished pane is a pure no-op")
    func closePaneVanishedPaneIsNoOp() {
        // Intent: .closePane for a paneId present in no tab returns [] and leaves the
        //   model unchanged, including zoom state.
        // Why it exists: pins the guard-return branch for the fully-stale
        //   case (e.g. a retained context menu firing after its pane was
        //   already closed). Pre-fix this input clobbered the selected tab's
        //   zoom and emitted a checkpoint. Spec-first.
        var fx = makeTwoTabFixture()
        let before = fx.model

        let commands = update(&fx.model, .closePane(paneId: PaneId()))

        #expect(commands.isEmpty, "vanished pane should produce no commands")
        #expect(fx.model == before, "vanished pane must not mutate the model")
    }

    // MARK: - movePane Tests

    @Test("testMovePaneSplitIntent")
    func testMovePaneSplitIntent() {
        // Intent: movePane with split intent rearranges the tree, focuses
        //   the source pane, and clears any prior zoom.
        // Why it exists: pins the split-intent payload threading.
        // Scenario: spec-first split-move.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .movePane(source: paneA, target: paneB, intent: .splitBottom))
        let tab = model.groups[0].tabs[0]
        #expect(tab.paneTree.focusedPaneId == paneA, "source should be focused after move")
        #expect(tab.paneTree.isZoomed == false, "zoom should be cleared")
        let ids = allPaneIds(tab.paneTree.root)
        #expect(ids.count == 2)
        #expect(ids.contains(paneA))
        #expect(ids.contains(paneB))
    }

    @Test("testMovePaneSwapIntent")
    func testMovePaneSwapIntent() {
        // Intent: movePane with swap intent swaps the leaves and focuses
        //   the source.
        // Why it exists: pins the swap-intent path.
        // Scenario: spec-first swap.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .movePane(source: paneA, target: paneB, intent: .swap))
        let tab = model.groups[0].tabs[0]
        #expect(tab.paneTree.focusedPaneId == paneA, "source should be focused after swap")
        #expect(lastLeafId(tab.paneTree.root) == paneA, "A should now be last (swapped to right)")
    }

    @Test("testMovePaneSameSourceTarget")
    func testMovePaneSameSourceTarget() {
        // Intent: movePane with source == target is a no-op.
        // Why it exists: pins the identity guard against drag-onto-self.
        // Scenario: spec-first identity guard.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let pane = model.groups[0].tabs[0].paneTree.focusedPaneId

        let commands = update(&model, .movePane(source: pane, target: pane, intent: .swap))
        #expect(commands.count == 0, "same source/target is no-op")
    }

    @Test("testMovePaneNoSelectedTab")
    func testMovePaneNoSelectedTab() {
        // Intent: movePane with no selected tab is a no-op.
        // Why it exists: pins the no-selection guard.
        // Scenario: spec-first no-selection guard.
        var model = makeModel()
        model.selectedTabId = nil

        let commands = update(&model, .movePane(source: PaneId(), target: PaneId(), intent: .swap))
        #expect(commands.count == 0, "no selected tab is no-op")
    }

    @Test("testMovePaneZoomedTab")
    func testMovePaneZoomedTab() {
        // Intent: movePane is a no-op when the selected tab is zoomed.
        // Why it exists: pins the zoom-locks-layout rule.
        // Scenario: spec-first zoomed-no-op.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)

        let paneB = allPaneIds(model.groups[0].tabs[0].paneTree.root).first(where: { $0 != paneA })!
        let commands = update(&model, .movePane(source: paneA, target: paneB, intent: .swap))
        #expect(commands.count == 0, "zoomed tab is no-op")
    }

    @Test("movePane ignores panes that are only present in a background tab")
    func movePaneBackgroundTabPanesAreNoOp() throws {
        // Intent: .movePane whose source and target live outside the selected tab returns []
        //   and leaves the model unchanged, including focus and zoom state.
        // Why it exists: pins the selected-tab-scoped invariant documented by
        //   the .movePane handler comment.
        // Scenario: spec-first; a pane drop dispatch races a tab switch, so
        //   the drag's panes are still in the old tab while a different tab is
        //   now selected.
        var swap = makeTwoTabFixture()
        swap.model.groups[0].tabs[1].paneTree.unzoom()
        let swapTarget = try #require(swap.a2, "fixture should provide a second pane in tab A")
        let beforeSwap = swap.model

        let swapCommands = update(&swap.model, .movePane(source: swap.a1, target: swapTarget, intent: .swap))

        #expect(swapCommands.isEmpty, "background-tab swap should produce no commands")
        #expect(swap.model == beforeSwap, "background-tab swap must not mutate the model")

        var split = makeTwoTabFixture()
        split.model.groups[0].tabs[1].paneTree.unzoom()
        let splitTarget = try #require(split.a2, "fixture should provide a second pane in tab A")
        let beforeSplit = split.model

        let splitCommands = update(&split.model, .movePane(source: split.a1, target: splitTarget, intent: .splitRight))

        #expect(splitCommands.isEmpty, "background-tab split move should produce no commands")
        #expect(split.model == beforeSplit, "background-tab split move must not mutate the model")
    }

    @Test("testSplitPaneTargetsByPaneId")
    func testSplitPaneTargetsByPaneId() {
        // Intent: splitPane(paneId:) targets that pane regardless of
        //   current focus.
        // Why it exists: pins the explicit-target route the IPC uses.
        // Scenario: spec-first targeted-split -- B focused, split A by
        //   id; outer split keeps direction; inner split appears under A.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        #expect(paneB != paneA)

        update(&model, .splitPane(paneId: paneA, direction: .vertical))
        let tab = model.groups[0].tabs[0]

        guard case .split(_, .horizontal, let first, let second, _) = tab.paneTree.root else {
            Issue.record("root should be horizontal split")
            return
        }

        guard case .split(_, .vertical, let innerFirst, let innerSecond, _) = first else {
            Issue.record("first child should be vertical split (pane A was split)")
            return
        }
        if case .leaf(let fid) = innerFirst {
            #expect(fid.id == paneA, "inner first should be pane A")
        } else {
            Issue.record("inner first should be a leaf")
            return
        }
        let paneC = tab.paneTree.focusedPaneId
        if case .leaf(let sid) = innerSecond {
            #expect(sid.id == paneC, "inner second should be new pane C")
        } else {
            Issue.record("inner second should be a leaf")
            return
        }

        if case .leaf(let bid) = second {
            #expect(bid.id == paneB, "second child should still be pane B")
        } else {
            Issue.record("second child should be a leaf")
            return
        }

        #expect(model.allPaneIds.count == 3)
    }

    @Test("testSplitPaneBackgroundOnSelectedTabRebuildsButPreservesFocus")
    func testSplitPaneBackgroundOnSelectedTabRebuildsButPreservesFocus() {
        // Intent: background split on the selected tab adds a pane, leaves focus on the
        //   existing pane, and emits only createSession.
        // Why it exists: pins the background-split contract.
        // Scenario: spec-first background-split-selected.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let existingFocusedPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let beforePaneIds = Set(model.allPaneIds)

        let commands = update(
            &model,
            .splitPane(paneId: existingFocusedPaneId, direction: .horizontal, background: true)
        )
        let newPaneIds = Set(model.allPaneIds).subtracting(beforePaneIds)
        let tab = tabById(tabId, in: model)!

        #expect(newPaneIds.count == 1, "background split should create one pane")
        #expect(allPaneIds(tab.paneTree.root).contains(newPaneIds.first!), "tab tree should contain new pane")
        #expect(tab.paneTree.focusedPaneId == existingFocusedPaneId, "background split should preserve focused pane")
        #expect(model.selectedTabId == tabId, "background split should not change selected tab")
        #expect(hasEffect(commands) {
            if case .createSession(_, let paneId, _, _, _) = $0 {
                return newPaneIds.contains(paneId)
            }
            return false
        }, "should create a session for the new pane")
        #expect(allPaneIds(model.groups[0].tabs[0].paneTree.root).contains { newPaneIds.contains($0) },
            "new pane lands in the selected tab's tree (rendered on the rebuild)")
    }

    @Test("testSplitPaneBackgroundOnUnselectedTabEmitsScopedRebuild")
    func testSplitPaneBackgroundOnUnselectedTabEmitsScopedRebuild() {
        // Intent: background split on a non-selected tab adds a pane there
        //   without changing selection.
        // Why it exists: pins the scoped-rebuild contract for the IPC's
        //   non-foreground splits.
        // Scenario: spec-first background-split-unselected.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        createTab(&model)
        let tabBId = model.groups[0].tabs[1].id
        let tabBFocusedPaneId = model.groups[0].tabs[1].paneTree.focusedPaneId
        _ = update(&model, .selectTab(id: tabAId))
        let beforePaneIds = Set(model.allPaneIds)

        let commands = update(
            &model,
            .splitPane(paneId: tabBFocusedPaneId, direction: .horizontal, background: true)
        )
        let newPaneIds = Set(model.allPaneIds).subtracting(beforePaneIds)
        let tabB = tabById(tabBId, in: model)!

        #expect(newPaneIds.count == 1, "background split should create one pane")
        #expect(allPaneIds(tabB.paneTree.root).contains(newPaneIds.first!), "background tab tree should contain new pane")
        #expect(tabB.paneTree.focusedPaneId == tabBFocusedPaneId, "background split should preserve target tab focus")
        #expect(model.selectedTabId == tabAId, "background split should not change selected tab")
        #expect(hasEffect(commands) {
            if case .createSession(_, let paneId, _, _, _) = $0 {
                return newPaneIds.contains(paneId)
            }
            return false
        }, "should create a session for the new pane")
    }

    @Test("testSplitPaneBackgroundInheritsTheme")
    func testSplitPaneBackgroundInheritsTheme() {
        // Intent: a background split inherits the target pane's theme.
        // Why it exists: pins theme inheritance during the background
        //   split.
        // Scenario: spec-first background-split-theme.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.updatePane(paneId) { $0.theme = "Tokyo Night" }
        let beforePaneIds = Set(model.allPaneIds)

        update(&model, .splitPane(paneId: paneId, direction: .horizontal, background: true))
        let newPaneId = Set(model.allPaneIds).subtracting(beforePaneIds).first!

        #expect(model.pane(newPaneId)?.theme == "Tokyo Night", "background split should inherit target theme")
        #expect(desiredPaneConfig(in: model)[newPaneId]?.theme == "Tokyo Night")
    }

    @Test("testSplitPaneForegroundStillMovesFocus")
    func testSplitPaneForegroundStillMovesFocus() {
        // Intent: a foreground split moves focus to the new pane.
        // Why it exists: pins the foreground default contract against
        //   regressions toward the background path.
        // Scenario: spec-first foreground-split.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let focusedPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let beforePaneIds = Set(model.allPaneIds)

        update(&model, .splitPane(paneId: focusedPaneId, direction: .horizontal))
        let newPaneId = Set(model.allPaneIds).subtracting(beforePaneIds).first!
        let tab = tabById(tabId, in: model)!

        #expect(tab.paneTree.focusedPaneId == newPaneId, "foreground split should focus new pane")
    }

    @Test("focusDirection and responder callback converge idempotently")
    func focusDirectionAndResponderCallbackConvergeIdempotently() {
        // Intent: focusDirection records focus eagerly and the matching AppKit
        //   callback leaves that model decision unchanged.
        // Why it exists: pins the declarative focus round-trip.
        // Scenario: spec-first focus convergence.
        var model = makeModel()
        createTab(&model)
        let leftPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let rightPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        #expect(rightPaneId != leftPaneId)

        let focusEffects = update(&model, .focusDirection(direction: .horizontal, side: .first))
        #expect(focusEffects.isEmpty)
        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == leftPaneId)

        let callbackEffects = update(&model, .paneBecameFirstResponder(paneId: leftPaneId))
        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == leftPaneId)
        #expect(callbackEffects.isEmpty)
    }

    @Test("focusDirection clears the target pane's alert in focus mode")
    func focusDirectionClearsTargetPaneAlertInFocusMode() {
        // Intent: directional focus marks the pane it reveals as read in focus
        //   alert-clear mode.
        // Why it exists: the shared reconcile pass replaces the directional
        //   focus arm's route-specific alert handling.
        // Scenario: spec-first -- the right pane holds focus and the left pane
        //   has an unread alert before focus moves left.
        var model = makeModel()
        model.config.alertClearMode = .focus
        createTab(&model)
        let leftPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: leftPaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        )]

        update(&model, .focusDirection(direction: .horizontal, side: .first))

        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == leftPaneId)
        #expect(model.alerts[0].isUnread == false)
    }

    @Test("testMovePaneSwapUpdatesVisibleTabChrome")
    func testMovePaneSwapUpdatesVisibleTabChrome() {
        // Intent: after a swap, the tab's displayTitle reflects the new
        //   focused pane.
        // Why it exists: pins the chrome-follows-focus rule across a swap.
        // Scenario: spec-first swap-chrome.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .sessionReport(sessionId: sessionId(for: paneA, in: model), report: .title("alpha")))
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .sessionReport(sessionId: sessionId(for: paneB, in: model), report: .title("beta")))

        update(&model, .movePane(source: paneA, target: paneB, intent: .swap))

        let tab = model.groups[0].tabs[0]
        #expect(tab.paneTree.focusedPaneId == paneA)
        #expect(tabDisplayTitle(tab) == "alpha", "swapping focus to pane A should show pane A chrome")
    }

    // MARK: - movePaneToTab Tests

    @Test("testMovePaneToTabBasicCrossTab")
    func testMovePaneToTabBasicCrossTab() {
        // Intent: movePaneToTab reparents the pane to the target tab,
        //   selects the target, focuses the moved pane, clears zoom, and
        //   removes an emptied source tab; session-existence tears down
        //   nothing.
        // Why it exists: pins the full cross-tab move contract.
        // Scenario: spec-first cross-tab move -- two single-pane tabs;
        //   move tab1's pane to tab2.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id
        let paneB = model.groups[0].tabs[1].paneTree.focusedPaneId
        let liveBefore = Set(model.allPaneIds)

        _ = update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        #expect(model.groups[0].tabs.count == 1, "source tab should be removed when empty")
        #expect(model.groups[0].tabs[0].id == tab2Id, "remaining tab should be target")

        let targetTab = model.groups[0].tabs[0]
        let targetPaneIds = allPaneIds(targetTab.paneTree.root)
        #expect(targetPaneIds.count == 2, "target tab should have 2 panes")
        #expect(targetPaneIds.contains(paneA), "target should contain moved pane")
        #expect(targetPaneIds.contains(paneB), "target should contain original pane")

        #expect(model.selectedTabId == tab2Id, "should select target tab")
        #expect(targetTab.paneTree.focusedPaneId == paneA, "should focus moved pane")
        #expect(targetTab.paneTree.isZoomed == false, "target zoom should be cleared")

        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model).isEmpty,
            "a cross-tab move tears down no sessions")
        #expect(tabById(tab1Id, in: model) == nil, "emptied source tab is removed")

        #expect(desiredPaneFocus(in: model) == .terminal(paneA))
    }

    @Test("testMovePaneToTabSourceHasMultiplePanes")
    func testMovePaneToTabSourceHasMultiplePanes() {
        // Intent: movePaneToTab from a multi-pane source leaves the source
        //   as a single-leaf surviving tab with the remaining pane focused.
        // Why it exists: pins the survival branch of the cross-tab move.
        // Scenario: spec-first source-survives.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id
        let paneC = model.groups[0].tabs[1].paneTree.focusedPaneId

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        #expect(model.groups[0].tabs.count == 2, "source tab should remain")
        let srcTab = model.groups[0].tabs.first(where: { $0.id == tab1Id })!
        if case .leaf(let id) = srcTab.paneTree.root {
            #expect(id.id == paneB, "source tab should have paneB as leaf")
        } else {
            Issue.record("source tab should be a single leaf")
            return
        }
        #expect(srcTab.paneTree.focusedPaneId == paneB, "source tab should focus paneB")

        let dstTab = model.groups[0].tabs.first(where: { $0.id == tab2Id })!
        let dstPaneIds = allPaneIds(dstTab.paneTree.root)
        #expect(dstPaneIds.count == 2)
        #expect(dstPaneIds.contains(paneA))
        #expect(dstPaneIds.contains(paneC))
        #expect(dstTab.paneTree.focusedPaneId == paneA, "target tab should focus moved pane")
        #expect(tabById(tab1Id, in: model) != nil, "surviving source tab is not removed")
    }

    @Test("testMovePaneToTabUpdatesSourceTabChrome")
    func testMovePaneToTabUpdatesSourceTabChrome() {
        // Intent: after movePaneToTab the source tab's chrome reflects the
        //   surviving focused session's title.
        // Why it exists: pins the chrome-follows-survivor rule on the
        //   source side.
        // Scenario: spec-first source-chrome.
        var model = makeModel()
        createTab(&model)
        let sourceTabId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .sessionReport(sessionId: sessionId(for: paneA, in: model), report: .title("alpha")))
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .sessionReport(sessionId: sessionId(for: paneB, in: model), report: .title("beta")))
        update(&model, .paneBecameFirstResponder(paneId: paneA))

        createTab(&model)
        let targetTabId = model.groups[0].tabs[1].id

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: targetTabId))

        let sourceTab = tabById(sourceTabId, in: model)!
        #expect(sourceTab.paneTree.focusedPaneId == paneB)
        #expect(tabDisplayTitle(sourceTab) == "beta", "source tab should show the surviving focused pane")
    }

    @Test("testMovePaneToTabSameTabIsNoOp")
    func testMovePaneToTabSameTabIsNoOp() {
        // Intent: movePaneToTab where the target is the source's tab is a
        //   no-op.
        // Why it exists: pins the identity guard.
        // Scenario: spec-first identity guard.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        let commands = update(&model, .movePaneToTab(paneId: paneId, targetTabId: tabId))
        #expect(commands.count == 0, "same tab should be no-op")
    }

    @Test("testMovePaneToTabSourceTabClosedWhenEmpty")
    func testMovePaneToTabSourceTabClosedWhenEmpty() {
        // Intent: a movePaneToTab that empties the source tab removes that
        //   tab.
        // Why it exists: pins the auto-prune branch of the move.
        // Scenario: spec-first source-empty-prune.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        #expect(!model.groups[0].tabs.contains(where: { $0.id == tab1Id }), "empty source tab should be removed")
        #expect(model.groups[0].tabs.count == 1)
    }

    @Test("testMovePaneToTabCrossGroup")
    func testMovePaneToTabCrossGroup() {
        // Intent: movePaneToTab across groups prunes the now-empty source
        //   group when applicable.
        // Why it exists: pins the cross-group + auto-prune interaction.
        // Scenario: spec-first cross-group-prune.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .createGroup(name: "Work"))
        let group1Id = model.groups[1].id
        let tab2Id = model.groups[1].tabs[0].id
        let paneB = model.groups[1].tabs[0].paneTree.focusedPaneId

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        #expect(model.groups.count == 1, "empty source group should be pruned")
        #expect(model.groups[0].id == group1Id, "only Work group should remain")

        let targetTab = model.groups[0].tabs.first(where: { $0.id == tab2Id })!
        let targetPanes = allPaneIds(targetTab.paneTree.root)
        #expect(targetPanes.count == 2)
        #expect(targetPanes.contains(paneA))
        #expect(targetPanes.contains(paneB))
    }

    @Test("testMovePaneToTabDefocusesOldTabSessions")
    func testMovePaneToTabDefocusesOldTabSessions() {
        // Intent: movePaneToTab into an already-selected target defocuses
        //   the target's previous focused pane.
        // Why it exists: pins the focus-handoff side effect.
        // Scenario: spec-first defocus-old-sessions.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id
        let paneB = model.groups[0].tabs[1].paneTree.focusedPaneId

        let commands = update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        #expect(hasEffect(commands) {
            if case .focusSession(let pid, let focused) = $0, pid == paneB, !focused { return true }
            return false
        }, "should defocus old tab's panes")
    }

    @Test("movePaneToTab projects the moved pane as desired focus")
    func movePaneToTabProjectsMovedPaneAsDesiredFocus() {
        // Intent: movePaneToTab selects the moved pane as the declarative target.
        // Why it exists: pins focus policy across cross-tab reparenting.
        // Scenario: spec-first focus projection after a move.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id

        _ = update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        #expect(desiredPaneFocus(in: model) == .terminal(paneA))
    }

    @Test("testMovePaneToTabTargetZoomCleared")
    func testMovePaneToTabTargetZoomCleared() {
        // Intent: a movePaneToTab into a zoomed target clears the target's
        //   zoom.
        // Why it exists: pins the zoom-clear rule on the destination side.
        // Scenario: spec-first target-zoom-clear.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[1].paneTree.isZoomed == true)

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        let targetTab = model.groups[0].tabs.first(where: { $0.id == tab2Id })!
        #expect(targetTab.paneTree.isZoomed == false, "target zoom should be cleared after move")
    }

    @Test("testMovePaneToTabZoomedSourceUnzooms")
    func testMovePaneToTabZoomedSourceUnzooms() {
        // Intent: moving a pane out of a zoomed source tab via movePaneToTab
        //   unzooms the source and repoints its focus onto the surviving pane,
        //   while the moved pane lands in the target.
        // Why it exists: locks down the pure-core contract that the AppKit
        //   "drag a zoomed pane to another tab" capability rides on, so a future
        //   refactor of the move handlers can't silently re-break zoomed-pane drags.
        // Scenario: spec-first -- a tab is split into two panes and zoomed (the
        //   zoomed/focused pane is the one dragged); dropping it onto another tab
        //   row merges it there and the source tab unzooms to show its survivor.
        var model = makeModel()
        createTab(&model)
        let srcTabId = model.groups[0].tabs[0].id
        let survivor = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let zoomedPane = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)

        createTab(&model)
        let targetTabId = model.groups[0].tabs[1].id

        update(&model, .movePaneToTab(paneId: zoomedPane, targetTabId: targetTabId))

        let srcTab = tabById(srcTabId, in: model)!
        #expect(srcTab.paneTree.isZoomed == false, "source zoom should be cleared after move")
        #expect(srcTab.paneTree.focusedPaneId == survivor, "source focus should repoint to the survivor")

        let targetTab = tabById(targetTabId, in: model)!
        #expect(allPaneIds(targetTab.paneTree.root).contains(zoomedPane), "moved pane should land in the target")
    }

    // MARK: - movePaneToNewTab Tests

    @Test("testMovePaneToNewTabPathB_SplitTabCreatesNewTab")
    func testMovePaneToNewTabPathBSplitTabCreatesNewTab() {
        // Intent: in path B (multi-pane source), movePaneToNewTab extracts
        //   the pane into a fresh tab while leaving the source intact.
        // Why it exists: pins the extraction branch of movePaneToNewTab.
        // Scenario: spec-first path B -- source has [A,B]; move A to a
        //   new tab at index 1.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        let groupId = model.groups[0].id

        _ = update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 1))

        #expect(model.groups[0].tabs.count == 2, "should have 2 tabs")
        let srcTab = model.groups[0].tabs[0]
        #expect(srcTab.id == tab1Id)
        if case .leaf(let id) = srcTab.paneTree.root {
            #expect(id.id == paneB, "source tab should have paneB")
        } else {
            Issue.record("source tab should be a single leaf")
            return
        }
        #expect(srcTab.paneTree.focusedPaneId == paneB)

        let newTab = model.groups[0].tabs[1]
        if case .leaf(let id) = newTab.paneTree.root {
            #expect(id.id == paneA, "new tab should have paneA")
        } else {
            Issue.record("new tab should be a single leaf")
            return
        }
        #expect(newTab.paneTree.focusedPaneId == paneA)
        #expect(model.selectedTabId == newTab.id, "new tab should be selected")

        #expect(desiredPaneFocus(in: model) == .terminal(paneA))
    }

    @Test("testMovePaneToNewTabPathB_ZoomedSourceUnzooms")
    func testMovePaneToNewTabPathBZoomedSourceUnzooms() {
        // Intent: extracting a pane out of a zoomed source tab via
        //   movePaneToNewTab (path B) unzooms the source and repoints its focus
        //   onto the survivor, and the freshly built tab holding the moved pane
        //   is itself unzoomed.
        // Why it exists: locks down the pure-core contract that the AppKit
        //   "drag a zoomed pane into a sidebar gap" capability rides on, so a
        //   future refactor of path B can't silently re-break zoomed-pane drags.
        // Scenario: spec-first -- a tab is split into two panes and zoomed (the
        //   zoomed/focused pane is the one dragged); dropping it into a gap
        //   between sidebar tabs extracts it into a new unzoomed tab and the
        //   source tab unzooms to show its survivor.
        var model = makeModel()
        createTab(&model)
        let srcTabId = model.groups[0].tabs[0].id
        let survivor = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let zoomedPane = model.groups[0].tabs[0].paneTree.focusedPaneId
        let groupId = model.groups[0].id
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)

        update(&model, .movePaneToNewTab(paneId: zoomedPane, inGroupId: groupId, atIndex: 1))

        #expect(model.groups[0].tabs.count == 2, "should have 2 tabs")
        let srcTab = tabById(srcTabId, in: model)!
        #expect(srcTab.paneTree.isZoomed == false, "source zoom should be cleared after move")
        #expect(srcTab.paneTree.focusedPaneId == survivor, "source focus should repoint to the survivor")

        let newTab = model.groups[0].tabs.first(where: { $0.id != srcTabId })!
        #expect(allPaneIds(newTab.paneTree.root).contains(zoomedPane), "moved pane should land in the new tab")
        #expect(newTab.paneTree.focusedPaneId == zoomedPane, "new tab should focus the moved pane")
        #expect(newTab.paneTree.isZoomed == false, "new tab should start unzoomed")
    }

    @Test("testMovePaneToNewTabPathA_SinglePaneMoveTab")
    func testMovePaneToNewTabPathASinglePaneMoveTab() {
        // Intent: in path A (single-pane source), the whole tab entity is
        //   reparented to the requested index, preserving id/color/custom
        //   title.
        // Why it exists: pins the path-A no-clone reparent.
        // Scenario: spec-first path A reparent.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .setTabColors(tabIds: [tab1Id], color: .red))
        update(&model, .renameTab(id: tab1Id, name: "MyTab"))

        createTab(&model)
        let groupId = model.groups[0].id

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 2))

        #expect(model.groups[0].tabs.count == 2, "tab count should be same (tab was moved, not cloned)")
        let movedTab = model.groups[0].tabs[1]
        #expect(movedTab.id == tab1Id, "tab entity should be preserved (same ID)")
        #expect(movedTab.color == .red, "color should be preserved")
        #expect(movedTab.customTitle == "MyTab", "custom title should be preserved")
        #expect(model.selectedTabId == tab1Id, "moved tab should be selected")
    }

    @Test("testMovePaneToNewTabPathA_SameGroupIndexAdjust")
    func testMovePaneToNewTabPathASameGroupIndexAdjust() {
        // Intent: same-group reparent compensates for the source removal
        //   when computing the destination index.
        // Why it exists: pins the index-adjustment math.
        // Scenario: spec-first same-group index adjust -- move tab at
        //   index 0 to target 2; ends up at index 1.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let pane1 = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        createTab(&model)
        let groupId = model.groups[0].id

        update(&model, .movePaneToNewTab(paneId: pane1, inGroupId: groupId, atIndex: 2))

        #expect(model.groups[0].tabs.count == 3)
        #expect(model.groups[0].tabs[1].id == tab1Id)
        #expect(model.selectedTabId == tab1Id)
    }

    @Test("testMovePaneToNewTabCrossGroup")
    func testMovePaneToNewTabCrossGroup() {
        // Intent: movePaneToNewTab into a different group lands the new
        //   tab at the requested index inside that group.
        // Why it exists: pins the cross-group path B extraction.
        // Scenario: spec-first cross-group extract.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))

        update(&model, .createGroup(name: "Work"))
        let group1Id = model.groups[1].id

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: group1Id, atIndex: 0))

        #expect(model.groups[0].tabs.count == 1)
        #expect(model.groups[0].tabs[0].id == tab1Id)

        #expect(model.groups[1].tabs.count == 2, "group1 should have 2 tabs")
        let newTab = model.groups[1].tabs[0]
        if case .leaf(let id) = newTab.paneTree.root {
            #expect(id.id == paneA)
        } else {
            Issue.record("new tab should be a leaf")
            return
        }
    }

    @Test("testMovePaneToNewTabSinglePaneSingleTabGuard")
    func testMovePaneToNewTabSinglePaneSingleTabGuard() {
        // Intent: extracting the only pane of the only tab is a no-op
        //   (nothing to reparent to).
        // Why it exists: pins the corner-case guard.
        // Scenario: spec-first single-tab guard.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        let groupId = model.groups[0].id

        let commands = update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 0))
        #expect(commands.count == 0, "should be no-op for single-pane single-tab")
        #expect(model.groups[0].tabs.count == 1)
    }

    @Test("testMovePaneToNewTabPathB_SourceFocusUpdated")
    func testMovePaneToNewTabPathBSourceFocusUpdated() {
        // Intent: after extracting the focused pane, the source tab's
        //   focusedPaneId moves to the remaining pane.
        // Why it exists: pins the focus-resync after a path B extraction.
        // Scenario: spec-first source-focus-update.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId

        let groupId = model.groups[0].id
        update(&model, .movePaneToNewTab(paneId: paneB, inGroupId: groupId, atIndex: 1))

        let srcTab = model.groups[0].tabs[0]
        #expect(srcTab.paneTree.focusedPaneId == paneA, "source tab should focus remaining pane")
    }

    @Test("testMovePaneToNewTabUpdatesSourceTabChrome")
    func testMovePaneToNewTabUpdatesSourceTabChrome() {
        // Intent: after extraction the source's chrome reflects the
        //   surviving focused pane.
        // Why it exists: pins the source-chrome update mirror to
        //   testMovePaneToTabUpdatesSourceTabChrome.
        // Scenario: spec-first source-chrome update.
        var model = makeModel()
        createTab(&model)
        let sourceTabId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .sessionReport(sessionId: sessionId(for: paneA, in: model), report: .title("alpha")))
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .sessionReport(sessionId: sessionId(for: paneB, in: model), report: .title("beta")))
        update(&model, .paneBecameFirstResponder(paneId: paneA))
        let groupId = model.groups[0].id

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 1))

        let sourceTab = tabById(sourceTabId, in: model)!
        #expect(sourceTab.paneTree.focusedPaneId == paneB)
        #expect(tabDisplayTitle(sourceTab) == "beta", "source tab should show the surviving focused pane")
    }

    @Test("testMovePaneToNewTabPathB_ChromeDerived")
    func testMovePaneToNewTabPathBChromeDerived() {
        // Intent: the new tab in path B derives its title/subtitle from
        //   the moved pane's session title/cwd (with abbreviateHome applied).
        // Why it exists: pins the chrome-derivation rule on the new tab.
        // Scenario: spec-first new-tab-chrome.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.updatePane(paneA) { $0.session?.title = "/Users/dan/projects" }
        model.updatePane(paneA) { $0.session?.cwd = "/Users/dan/projects" }
        update(&model, .splitFocusedPane(direction: .horizontal))
        let groupId = model.groups[0].id

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 1))

        let newTab = model.groups[0].tabs[1]
        #expect(tabTitle(newTab) == abbreviateHome("/Users/dan/projects"), "title should be derived from pane")
        #expect(tabSubtitle(newTab) == abbreviateHome("/Users/dan/projects"), "subtitle should be derived from pane cwd")
    }

    @Test("testMovePaneToNewTabAlertsClearedOnMove")
    func testMovePaneToNewTabAlertsClearedOnMove() {
        // Intent: extracting a pane via movePaneToNewTab marks its unread
        //   alerts read.
        // Why it exists: pins the alert-clear side effect of the
        //   extraction.
        // Scenario: spec-first new-tab alert clear.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let groupId = model.groups[0].id

        let alert = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alert, at: 0)

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 1))

        let movedAlert = model.alerts.first(where: { $0.paneId == paneA })!
        #expect(movedAlert.isUnread == false, "alert should be marked read")
    }

    @Test("testMovePaneToNewTabBeforeSourceIndex")
    func testMovePaneToNewTabBeforeSourceIndex() {
        // Intent: extracting a pane to an index before the source still
        //   lands the new tab at the requested slot.
        // Why it exists: pins the negative-direction index handling.
        // Scenario: spec-first before-source extract.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneA = allPaneIds(model.groups[0].tabs[0].paneTree.root).first!
        let groupId = model.groups[0].id

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 0))

        #expect(model.groups[0].tabs.count == 2)
        let newTab = model.groups[0].tabs[0]
        if case .leaf(let id) = newTab.paneTree.root {
            #expect(id.id == paneA)
        } else {
            Issue.record("new tab should be a leaf with paneA")
            return
        }
    }

    @Test("testMovePaneToTabAlertsClearedOnMove")
    func testMovePaneToTabAlertsClearedOnMove() {
        // Intent: movePaneToTab marks the moved pane's unread alerts read
        //   without touching unrelated panes' alerts.
        // Why it exists: pins the per-pane alert-clear scope of the
        //   cross-tab move.
        // Scenario: spec-first move-alert clear.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id
        let paneB = model.groups[0].tabs[1].paneTree.focusedPaneId

        let alertA = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "alert A", createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alertA, at: 0)

        let alertB = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "alert B", createdAt: Date(), isUnread: true
        )
        model.alerts.insert(alertB, at: 0)

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))

        let movedAlert = model.alerts.first(where: { $0.paneId == paneA })!
        #expect(movedAlert.isUnread == false, "moved pane's alert should be marked read")

        let otherAlert = model.alerts.first(where: { $0.paneId == paneB })!
        #expect(otherAlert.isUnread == true, "unrelated alert should remain unread")
    }
}

// MARK: - Pane-scoped fixture

private struct TwoTabFixture {
    var model: AppModel
    let tabA: TabId
    let a1: PaneId
    let a2: PaneId?  // nil when tab A is a single leaf
    let tabB: TabId
    let b1: PaneId
}

/// Two tabs in one group for the pane-scoped resolution tests: tab A holds the
/// pane under test (split a1|a2, or a lone a1 leaf), tab B is a zoomed split
/// and SELECTED -- so any handler that wrongly resolves the selected tab
/// mutates B's tree or zoom where the assertions will catch it.
private func makeTwoTabFixture(tabAIsSplit: Bool = true) -> TwoTabFixture {
    var model = makeModel()
    func pane(_ id: PaneId) -> PaneModel {
        PaneModel(id: id, session: SessionModel(id: SessionId()))
    }
    let a1 = PaneId()
    let b1 = PaneId()
    let tabAId = TabId()
    let tabBId = TabId()

    var a2: PaneId?
    let rootA: SplitNodeModel
    if tabAIsSplit {
        let sibling = PaneId()
        a2 = sibling
        rootA = .split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(pane(a1)), second: .leaf(pane(sibling)), ratio: 0.5)
    } else {
        rootA = .leaf(pane(a1))
    }
    let tabA = TabModel(id: tabAId, paneTree: PaneTree(root: rootA, focusedPaneId: a1))

    let tabB = TabModel(id: tabBId, paneTree: PaneTree(root: .split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(pane(b1)), second: .leaf(pane(PaneId())), ratio: 0.5), focusedPaneId: b1, isZoomed: true))

    model.groups[0].tabs = [tabA, tabB]
    model.selectedTabId = tabBId
    // Hand-built models start MRU-unreconciled, but update() canonicalizes
    // mruOrder in a defer on EVERY message -- pre-seed the canonical order
    // (selected first, then display order) so the vanished-pane no-op test can
    // compare whole models without tripping on that bookkeeping.
    model.mruOrder = [tabBId, tabAId]
    return TwoTabFixture(model: model, tabA: tabAId, a1: a1, a2: a2, tabB: tabBId, b1: b1)
}
