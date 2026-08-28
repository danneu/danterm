// Swift Testing migration of the legacy `tests/ReconcileTests.swift` harness
// suite. Pins the view-reconciler's pure primitives: the generic applyDiff
// (apply / remove / prune semantics), declarative pane-focus projection,
// the structure-insensitive model-apply gauntlet for computeSidebarRowOps
// (single<->multi mode flip, tab insert/remove/reorder/cross-group move,
// reload-on-changed-attrs, group churn, combined structural+attr churn),
// guardSidebarRenameOps (suppress reload of edited row; structural ops clear
// the active view session; nil target is a pass-through), advanceSidebarCache attribute
// retention, the eager desiredContainerShapes projection, the
// computeContainerOps suite (remove / build / tree / visibility-only switch /
// no-op), asserted both on the op script and via model-apply,
// containerOpsStrandVisible classification, ContainerShape
// equality (ratio + leaf metadata carveouts; structural change /
// zoom-toggle / direction / moved-leaf detected), direct tree updates, and
// sessionsToTearDown. The model-apply helpers (sbTab / sbGroup / sbProj /
// applySidebarRowOps / cShape / cSplitShape / splitNode / applyContainerOps
// / checkRowOps / checkContainerOps) move to file-private scope alongside
// the suite.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct ReconcileTests {
    // MARK: - applyDiff

    @Test("applyDiff applies only changed/new keys and skips unchanged ones")
    func applyDiffAppliesOnlyChangedOrNewKeys() {
        // Intent: applyDiff invokes apply for changed and new keys but
        //   not for unchanged ones; the cache equals the desired map
        //   after.
        // Why it exists: pins the diff-and-apply contract.
        // Scenario: spec-first diff apply.
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        let desired: [String: Int] = ["a": 1, "b": 99, "c": 3]
        applyDiff(desired, &cache, apply: { k, _ in applied.append(k) })

        #expect(Set(applied) == Set(["b", "c"]),
            "only the changed key (b) and new key (c) apply")
        #expect(!applied.contains("a"), "unchanged key (a) is skipped")
        #expect(cache == desired, "cache matches desired after the diff")
    }

    @Test("applyDiff invokes remove exactly once for a disappeared key, then prunes it")
    func applyDiffInvokesRemoveAndPrunes() {
        // Intent: applyDiff invokes remove for each disappeared key and
        //   prunes the cache.
        // Why it exists: pins the remove + prune contract.
        // Scenario: spec-first diff remove.
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        var removed: [String] = []
        let desired: [String: Int] = ["a": 1]
        applyDiff(desired, &cache,
            apply: { k, _ in applied.append(k) },
            remove: { k in removed.append(k) })

        #expect(applied.isEmpty, "no key changed, so nothing applies")
        #expect(removed == ["b"], "the disappeared key invokes remove exactly once")
        #expect(cache == ["a": 1], "the disappeared key is pruned from the cache")
    }

    @Test("applyDiff with the default no-op remove still prunes disappeared keys")
    func applyDiffDefaultNoOpRemoveStillPrunes() {
        // Intent: even with the default no-op remove closure, the cache
        //   is still pruned.
        // Why it exists: pins the default-remove prune contract.
        // Scenario: spec-first no-op remove.
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        let desired: [String: Int] = ["a": 1]
        applyDiff(desired, &cache, apply: { k, _ in applied.append(k) })

        #expect(applied.isEmpty, "no changes apply")
        #expect(cache == ["a": 1],
            "the disappeared key is pruned even when remove is the default no-op")
    }

    @Test("applyDiff in steady state invokes neither apply nor remove and leaves the cache unchanged")
    func applyDiffSteadyStateIsNoOp() {
        // Intent: when desired's keys and values equal the cache's, applyDiff
        //   invokes neither apply nor remove and leaves the cache unchanged.
        // Why it exists: pins the idempotent steady-state path -- the
        //   overwhelmingly common sweep case where no key changed or disappeared,
        //   and the one branch none of the existing tests reach (each feeds a delta).
        // Scenario: spec-first steady-state diff (no delta between desired and cache).
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        var removed: [String] = []
        let desired: [String: Int] = ["a": 1, "b": 2]
        applyDiff(desired, &cache,
            apply: { k, _ in applied.append(k) },
            remove: { k in removed.append(k) })

        #expect(applied.isEmpty, "no key changed or is new, so nothing applies")
        #expect(removed.isEmpty, "no key disappeared, so nothing is removed")
        #expect(cache == desired, "the cache is unchanged and still equals desired")
    }

    @Test("applyDiff in one pass applies the changed and new keys, removes only the dropped key, and ends equal to desired")
    func applyDiffCombinedDeltaInOnePass() {
        // Intent: a single call that changes a key, adds a key, and drops a key
        //   applies the changed+new keys, removes only the dropped key exactly once,
        //   and ends with cache == desired.
        // Why it exists: pins that the apply loop and the remove/prune loop compose --
        //   a key the apply loop adds (c) must not then be seen as "disappeared," and
        //   removing the dropped key (b) must not disturb the surviving (a) or new (c)
        //   keys. The three existing tests each exercise change/new/remove in isolation,
        //   so this interaction -- the realistic single-sweep shape, and the property
        //   any two-loop refactor is most likely to break -- is currently uncovered.
        // Scenario: spec-first combined diff (change + add + drop in one pass).
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        var removed: [String] = []
        let desired: [String: Int] = ["a": 9, "c": 3]
        applyDiff(desired, &cache,
            apply: { k, _ in applied.append(k) },
            remove: { k in removed.append(k) })

        #expect(Set(applied) == Set(["a", "c"]), "the changed key (a) and new key (c) apply")
        #expect(applied.count == 2, "each applies exactly once -- no key is applied twice")
        #expect(removed == ["b"], "only the dropped key (b) is removed, exactly once")
        #expect(cache == desired, "cache ends equal to desired -- c was not spuriously pruned")
    }

    // MARK: - Pane focus

    @Test("desired pane focus follows selected-tab policy and in-pane ownership")
    func desiredPaneFocusFollowsModelPolicy() {
        // Intent: the focus projection always names the selected tab's focused pane
        //   and chooses that pane's terminal or search field from search ownership.
        // Why it exists: this is the pure contract that lets tree reconciliation
        //   repair AppKit focus without interpreting the tree operation that ran.
        // Scenario: the 2026-08-12 split incident, plus the neighboring structural,
        //   tab-selection, zoom, and search transitions that use the same policy.
        var model = makeModel()
        createTab(&model)
        let firstPane = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(desiredPaneFocus(in: model) == .terminal(firstPane))

        update(&model, .splitFocusedPane(direction: .horizontal))
        let foregroundSplitPane = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(desiredPaneFocus(in: model) == .terminal(foregroundSplitPane))

        let selectedTabId = model.selectedTabId!
        update(&model, .createTabInSelectedGroup(background: true))
        let backgroundTab = model.groups[0].tabs.first { $0.id != selectedTabId }!
        update(&model, .splitPane(
            paneId: backgroundTab.paneTree.focusedPaneId,
            direction: .vertical,
            background: false
        ))
        #expect(desiredPaneFocus(in: model) == .terminal(foregroundSplitPane),
            "a foreground split inside a background tab must not change the selected target")

        update(&model, .toggleZoomPane(paneId: nil))
        #expect(desiredPaneFocus(in: model) == .terminal(foregroundSplitPane))
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(desiredPaneFocus(in: model) == .terminal(foregroundSplitPane))

        update(&model, .closePane(paneId: foregroundSplitPane))
        #expect(desiredPaneFocus(in: model) == .terminal(firstPane))

        update(&model, .selectTab(id: backgroundTab.id))
        let selectedBackgroundPane = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(desiredPaneFocus(in: model) == .terminal(selectedBackgroundPane))

        update(&model, .startSearch)
        #expect(desiredPaneFocus(in: model) == .searchField(selectedBackgroundPane))
        update(&model, .paneBecameFirstResponder(paneId: selectedBackgroundPane))
        #expect(desiredPaneFocus(in: model) == .terminal(selectedBackgroundPane))
        update(&model, .searchFieldBecameFirstResponder(paneId: selectedBackgroundPane))
        #expect(desiredPaneFocus(in: model) == .searchField(selectedBackgroundPane))
        update(&model, .endSearch(paneId: selectedBackgroundPane))
        #expect(desiredPaneFocus(in: model) == .terminal(selectedBackgroundPane))
    }

    @Test("reported terminal focus follows the live keyboard owner and app activation")
    func reportedTerminalFocusDecisionTable() {
        // Intent: exactly the live pane whose terminal owns the keyboard reports
        //   focus, and only while the app is active.
        // Why it exists: the reconcile pass must preserve search-field and
        //   non-pane keyboard ownership instead of guessing from model focus.
        // Scenario: two live panes exercise every claimant kind in both app
        //   activation states.
        let paneA = PaneId()
        let paneB = PaneId()
        let root = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)),
            ratio: 0.5
        )
        let tab = TabModel(id: TabId(), paneTree: PaneTree(root: root, focusedPaneId: paneA))
        var model = AppModel(groups: [GroupModel(id: GroupId(), name: "General", tabs: [tab])])
        model.selectedTabId = tab.id

        let claimants: [(PaneFocusClaimant, PaneId?)] = [
            (.pane(.terminal(paneA)), paneA),
            (.pane(.terminal(paneB)), paneB),
            (.pane(.searchField(paneA)), nil),
            (.nonPane, nil),
            (.none, nil),
        ]
        for active in [false, true] {
            model.isAppActive = active
            for (claimant, focusedPane) in claimants {
                let expectedFocusedPane = active ? focusedPane : nil
                #expect(
                    desiredReportedTerminalFocus(in: model, claimant: claimant) == [
                        paneA: expectedFocusedPane == paneA,
                        paneB: expectedFocusedPane == paneB,
                    ]
                )
            }
        }
    }

    // MARK: - computeSidebarRowOps (model-apply, Stage 5)

    @Test("computeSidebarRowOps: first build inserts all rows")
    func computeSidebarRowOpsFirstBuildInsertsAllRows() {
        // Intent: with nil old, the diff returns [.reloadAll] so the
        //   first build seeds every row.
        // Why it exists: pins the cold-start contract.
        // Scenario: spec-first first build.
        let g = GroupId()
        let new = sbProj(false, [sbGroup(g, "A", first: true, [sbTab("a"), sbTab("b")])])
        #expect(computeSidebarRowOps(old: nil, new: new) == [.reloadAll],
            "nil old -> reloadAll")
        checkRowOps(nil, new, "first build reaches new")
    }

    @Test("computeSidebarRowOps: single<->multi group-mode flip rebuilds")
    func computeSidebarRowOpsSingleMultiFlipRebuilds() {
        // Intent: flipping between single-group and multi-group mode
        //   emits [.reloadAll].
        // Why it exists: pins the mode-flip rebuild rule.
        // Scenario: spec-first mode flip.
        let g = GroupId()
        let single = sbProj(true, [sbGroup(g, "G", first: true, [sbTab("a")])])
        let multi = sbProj(false, [sbGroup(g, "G", first: true, [sbTab("a")]), sbGroup(GroupId(), "H", [sbTab("b")])])
        #expect(computeSidebarRowOps(old: single, new: multi) == [.reloadAll],
            "mode flip -> reloadAll")
        checkRowOps(single, multi, "mode flip reaches new")
    }

    @Test("computeSidebarRowOps: single-group identity change rebuilds")
    func computeSidebarRowOpsSingleGroupIdentityChangeRebuilds() {
        // Intent: replacing the lone group rebuilds the promoted root tab rows.
        // Why it exists: MODEL-2 found that hidden group-row ops could strand the
        //   outline on the removed group's tabs.
        // Scenario: a single-group sweep replaces G1 and its tab with G2 and its tab.
        let old = sbProj(true, [sbGroup(GroupId(), "Old", first: true, [sbTab("old")])])
        let new = sbProj(true, [sbGroup(GroupId(), "New", first: true, [sbTab("new")])])

        #expect(computeSidebarRowOps(old: old, new: new) == [.reloadAll])
        checkRowOps(old, new, "single-group identity change reaches new")
    }

    @Test("computeSidebarRowOps: single-group attr changes emit no group-row ops")
    func computeSidebarRowOpsSingleGroupAttrChangesEmitNoGroupRowOps() {
        // Intent: a single-group diff mutates only the promoted tab rows.
        // Why it exists: group rows are absent in single-group mode, so their ops
        //   are invalid even when the group's tab count or alert roll-up changes.
        // Scenario: the lone group gains a tab, which changes its hidden attributes.
        let group = GroupId()
        let firstTab = sbTab("first")
        let old = sbProj(true, [sbGroup(group, "Group", first: true, [firstTab])])
        let new = sbProj(true, [
            sbGroup(group, "Group", first: true, [firstTab, sbTabFull(TabId(), "second", bell: 1)]),
        ])

        let ops = computeSidebarRowOps(old: old, new: new)
        let containsGroupRowOp = ops.contains { op in
            switch op {
            case .insertGroup, .removeGroup, .reloadGroup, .setGroupCollapsed:
                true
            case .reloadAll, .insertTab, .removeTab, .reloadTab:
                false
            }
        }
        #expect(containsGroupRowOp == false)
    }

    @Test("computeSidebarRowOps: tab insert / remove / reorder / cross-group move")
    func computeSidebarRowOpsTabChurnReachesNew() {
        // Intent: a structure-insensitive diff covers tab insertion,
        //   removal, reorder, and cross-group move.
        // Why it exists: pins the model-apply gauntlet.
        // Scenario: spec-first tab churn.
        let g1 = GroupId(); let g2 = GroupId()
        let a = TabId(); let b = TabId(); let c = TabId()
        func two(_ t1: [SidebarTabProjection], _ t2: [SidebarTabProjection]) -> SidebarProjection {
            sbProj(false, [sbGroup(g1, "L", first: true, t1), sbGroup(g2, "R", t2)])
        }
        let A = sbTab2(a); let B = sbTab2(b); let C = sbTab2(c)
        checkRowOps(two([A, B], [C]), two([A, B], [C]), "no-op")
        checkRowOps(two([A], [C]),    two([A, B], [C]), "insert B into L")
        checkRowOps(two([A, B], [C]), two([A], [C]),    "remove B from L")
        checkRowOps(two([A, B, C], []), two([C, A, B], []), "reorder within L")
        checkRowOps(two([A, B], [C]), two([A], [C, B]),  "move B from L to R")
        checkRowOps(two([A, B], [C]), two([C], [A, B]),  "swap-ish across groups")
    }

    @Test("computeSidebarRowOps: reload fires on changed attrs (and tabCount badge)")
    func computeSidebarRowOpsReloadOnAttrChange() {
        // Intent: attr changes trigger per-row reloads (and group reload
        //   on bell roll-up).
        // Why it exists: pins the attr-diff branch.
        // Scenario: spec-first attr change.
        let g = GroupId(); let a = TabId(); let b = TabId()
        let old = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "x", bell: 0), sbTabFull(b, "y", bell: 0)])])
        let new = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "X", bell: 0), sbTabFull(b, "y", bell: 3)])])
        let ops = computeSidebarRowOps(old: old, new: new)
        #expect(ops.contains(.reloadTab(id: a)), "a's title change -> reloadTab(a)")
        #expect(ops.contains(.reloadTab(id: b)), "b's bell change -> reloadTab(b)")
        #expect(ops.contains(.reloadGroup(id: g)), "group bell roll-up change -> reloadGroup")
        checkRowOps(old, new, "attr changes reach new")
    }

    @Test("computeSidebarRowOps: group insert / remove / reorder / collapse")
    func computeSidebarRowOpsGroupChurnReachesNew() {
        // Intent: a structure-insensitive diff covers group insertion,
        //   removal, reorder, collapse flips, and insertion of an
        //   already-collapsed group (must emit setGroupCollapsed).
        // Why it exists: pins the group-level model-apply gauntlet.
        // Scenario: spec-first group churn.
        let g1 = GroupId(); let g2 = GroupId(); let g3 = GroupId()
        func g(_ id: GroupId, _ name: String, first: Bool = false, collapsed: Bool = false) -> SidebarGroupProjection {
            sbGroup(id, name, collapsed: collapsed, first: first, [sbTab(name.lowercased())])
        }
        let base = sbProj(false, [g(g1, "A", first: true), g(g2, "B")])
        checkRowOps(base, sbProj(false, [g(g1, "A", first: true), g(g2, "B"), g(g3, "C")]), "insert group C")
        checkRowOps(sbProj(false, [g(g1, "A", first: true), g(g2, "B"), g(g3, "C")]), base, "remove group C")
        let reordered = sbProj(false, [g(g2, "B", first: true), g(g1, "A")])
        #expect(computeSidebarRowOps(old: base, new: reordered).contains(.reloadAll) == false,
            "a plain group reorder stays incremental")
        checkRowOps(base, reordered, "reorder groups (isFirst flips)")
        checkRowOps(base, sbProj(false, [g(g1, "A", first: true), g(g2, "B", collapsed: true)]), "collapse group B")
        checkRowOps(sbProj(false, [g(g1, "A", first: true), g(g2, "B", collapsed: true)]), base, "expand group B")
        let ops = computeSidebarRowOps(old: base, new: sbProj(false, [g(g1, "A", first: true), g(g2, "B"), g(g3, "C", collapsed: true)]))
        #expect(ops.contains(.setGroupCollapsed(id: g3, collapsed: true)), "inserted collapsed group flips collapse")
        checkRowOps(base, sbProj(false, [g(g1, "A", first: true), g(g2, "B"), g(g3, "C", collapsed: true)]), "insert collapsed group")
    }

    @Test("computeSidebarRowOps: group reorder plus tab insert skips the remounted group")
    func computeSidebarRowOpsGroupReorderPlusTabInsertSkipsRemountedGroup() {
        // Intent: a group reinserted by the group-level diff receives no structural
        //   tab ops because its inserted row already carries the new child list.
        // Why it exists: MODEL-1 found that diffing those children again duplicates
        //   a newly inserted tab and breaks the sequential-script contract.
        // Scenario: spec-first future sweep that moves group B ahead of A while B gains a tab.
        let groupA = GroupId(); let groupB = GroupId()
        let tabA = sbTab("a"); let tabB = sbTab("b")
        let old = sbProj(false, [
            sbGroup(groupA, "A", first: true, [tabA]),
            sbGroup(groupB, "B", [tabB]),
        ])
        let new = sbProj(false, [
            sbGroup(groupB, "B", first: true, [tabB, sbTab("new")]),
            sbGroup(groupA, "A", [tabA]),
        ])

        let ops = computeSidebarRowOps(old: old, new: new)
        let hasStructuralTabOp = ops.contains { op in
            switch op {
            case .insertTab(_, groupB, _), .removeTab(groupB, _): true
            default: false
            }
        }
        #expect(hasStructuralTabOp == false,
            "the remounted group already contains the inserted tab")
        checkRowOps(old, new, "group reorder plus tab insert reaches new")
    }

    @Test("computeSidebarRowOps: group reorder plus tab removal skips the remounted group")
    func computeSidebarRowOpsGroupReorderPlusTabRemovalSkipsRemountedGroup() {
        // Intent: a group reinserted by the group-level diff receives no structural
        //   tab ops because its inserted row already carries the new child list.
        // Why it exists: MODEL-1 found that applying a stale-index removal after the
        //   remount can remove the wrong child or address an index that no longer exists.
        // Scenario: spec-first future sweep that moves group B ahead of A while B loses a tab.
        let groupA = GroupId(); let groupB = GroupId()
        let tabA = sbTab("a"); let tabB = sbTab("b")
        let old = sbProj(false, [
            sbGroup(groupA, "A", first: true, [tabA]),
            sbGroup(groupB, "B", [tabB, sbTab("removed")]),
        ])
        let new = sbProj(false, [
            sbGroup(groupB, "B", first: true, [tabB]),
            sbGroup(groupA, "A", [tabA]),
        ])

        let ops = computeSidebarRowOps(old: old, new: new)
        let hasStructuralTabOp = ops.contains { op in
            switch op {
            case .insertTab(_, groupB, _), .removeTab(groupB, _): true
            default: false
            }
        }
        #expect(hasStructuralTabOp == false,
            "the remounted group already excludes the removed tab")
        checkRowOps(old, new, "group reorder plus tab removal reaches new")
    }

    @Test("computeSidebarRowOps: combined structural + attr churn reaches new")
    func computeSidebarRowOpsCombinedChurnReachesNew() {
        // Intent: a worst-case churn (close+move+insert+attr+collapse)
        //   still produces ops that drive the cache to new.
        // Why it exists: pins the full integration of the row-diff
        //   primitives.
        // Scenario: spec-first combined churn.
        let g1 = GroupId(); let g2 = GroupId()
        let a = TabId(); let b = TabId(); let c = TabId(); let d = TabId()
        let old = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(a, "a", bell: 0), sbTabFull(b, "b", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0)]),
        ])
        let new = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(d, "d", bell: 0)]),
            sbGroup(g2, "R", collapsed: true, [sbTabFull(c, "c", bell: 5), sbTabFull(b, "b", bell: 0)]),
        ])
        checkRowOps(old, new, "combined churn reaches new")
    }

    // MARK: - guardSidebarRenameOps (rename-guard scope, Stage 5)

    @Test("guardSidebarRenameOps: suppresses a reload of the edited row, keeps others")
    func guardSidebarRenameOpsSuppressesReloadOfEditedRow() {
        // Intent: while editing tab A, a reload of A is suppressed (field
        //   editor owns the title) but a reload of B is preserved.
        // Why it exists: pins the guard's per-row scope.
        // Scenario: spec-first rename guard.
        let g = GroupId(); let a = TabId(); let b = TabId()
        let old = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "old", bell: 0), sbTabFull(b, "b", bell: 0)])])
        let new = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "TYPED", bell: 0), sbTabFull(b, "b", bell: 0)])])
        let ops = computeSidebarRowOps(old: old, new: new)
        let editingA = guardSidebarRenameOps(ops: ops, renameTarget: .tab(a), new: new)
        #expect(!editingA.ops.contains(.reloadTab(id: a)), "reload of the edited row suppressed")
        #expect(!editingA.clearRename, "a reload does not end the edit")
        let editingB = guardSidebarRenameOps(ops: ops, renameTarget: .tab(b), new: new)
        #expect(editingB.ops.contains(.reloadTab(id: a)), "reload of a different row applies")
    }

    @Test("guardSidebarRenameOps: structural ops apply and request ending the edit")
    func guardSidebarRenameOpsStructuralOpsApplyAndClear() {
        // Intent: structural ops (close, move) on the edited row apply
        //   normally and request that the view end its rename session.
        // Why it exists: pins the structural-ops-end-edit branch.
        // Scenario: spec-first close-while-editing + move-while-editing.
        let g1 = GroupId(); let g2 = GroupId(); let a = TabId(); let b = TabId(); let c = TabId()
        let old = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(a, "a", bell: 0), sbTabFull(b, "b", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0)]),
        ])
        let closed = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(b, "b", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0)]),
        ])
        let closeGuarded = guardSidebarRenameOps(
            ops: computeSidebarRowOps(old: old, new: closed), renameTarget: .tab(a), new: closed)
        #expect(closeGuarded.clearRename, "closing the edited row requests rename cleanup")
        #expect(applySidebarRowOps(closeGuarded.ops, to: old, new: closed) == closed,
            "the remove still applies")
        let moved = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(b, "b", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0), sbTabFull(a, "a", bell: 0)]),
        ])
        let moveGuarded = guardSidebarRenameOps(
            ops: computeSidebarRowOps(old: old, new: moved), renameTarget: .tab(a), new: moved)
        #expect(moveGuarded.clearRename, "moving the edited row requests rename cleanup")
        #expect(applySidebarRowOps(moveGuarded.ops, to: old, new: moved) == moved,
            "the move (remove + insert-by-id) still applies")
    }

    @Test("guardSidebarRenameOps: collapsing the edited row's group ends the edit")
    func guardSidebarRenameOpsCollapseEndsEdit() {
        // Intent: a setGroupCollapsed(collapsed: true) on the group holding the
        //   edited tab applies normally and requests ending the view-owned edit, exactly
        //   like close/move/reloadAll of the edited row.
        // Why it exists: collapseItem tears down the edited row's cell view with
        //   no field-editor delegate callback, so a rename left live across a
        //   collapse strands an editable cell in NSOutlineView's reuse pool; the
        //   next inserted tab row dequeues that cell and renders a blank title
        //   no matter what the model says.
        // Scenario: 2026-06-11 incident -- a tab spawned via `danterm tab new`
        //   showed an empty sidebar title even though the model title was
        //   correct; AX inspection showed its title field was a recycled
        //   still-editable rename cell.
        let g1 = GroupId(); let g2 = GroupId(); let a = TabId(); let c = TabId()
        let old = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(a, "a", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0)]),
        ])
        let collapsed = sbProj(false, [
            sbGroup(g1, "L", collapsed: true, first: true, [sbTabFull(a, "a", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0)]),
        ])
        let guarded = guardSidebarRenameOps(
            ops: computeSidebarRowOps(old: old, new: collapsed), renameTarget: .tab(a), new: collapsed)
        #expect(guarded.clearRename, "collapsing the edited row's group ends the edit")
        #expect(guarded.ops.contains(.setGroupCollapsed(id: g1, collapsed: true)),
            "the collapse still applies")
        // Collapsing an unrelated group leaves the edit alone.
        let otherCollapsed = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(a, "a", bell: 0)]),
            sbGroup(g2, "R", collapsed: true, [sbTabFull(c, "c", bell: 0)]),
        ])
        let otherGuarded = guardSidebarRenameOps(
            ops: computeSidebarRowOps(old: old, new: otherCollapsed), renameTarget: .tab(a), new: otherCollapsed)
        #expect(!otherGuarded.clearRename, "collapsing an unrelated group does not end the edit")
    }

    @Test("guardSidebarRenameOps: nil rename target is a pass-through")
    func guardSidebarRenameOpsNilRenameTargetPassThrough() {
        // Intent: a nil rename target makes the guard a no-op.
        // Why it exists: pins the nil-target branch.
        // Scenario: spec-first nil-target.
        let g = GroupId(); let a = TabId()
        let old = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "a", bell: 0)])])
        let new = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "A", bell: 0)])])
        let ops = computeSidebarRowOps(old: old, new: new)
        let guarded = guardSidebarRenameOps(ops: ops, renameTarget: nil, new: new)
        #expect(guarded.ops == ops, "no edit -> ops unchanged")
        #expect(!guarded.clearRename, "no edit -> nothing to clear")
    }

    @Test("advanceSidebarCache retains suppressed row attrs while applying structure")
    func advanceSidebarCacheRetainsSuppressedAttrs() {
        // Intent: advanceSidebarCache keeps the old attrs for the
        //   suppressed target while applying the new structure
        //   elsewhere.
        // Why it exists: pins the cache-advance contract that lets the
        //   reconciler keep a renamed row stable while everything else
        //   updates.
        // Scenario: spec-first cache-advance.
        let g1 = GroupId(); let g2 = GroupId()
        let a = TabId(); let b = TabId(); let c = TabId()
        let oldTabA = sbTabFull(a, "old-a", bell: 1)
        let newTabA = sbTabFull(a, "new-a", bell: 9)
        let old = sbProj(false, [
            sbGroup(g1, "Old G1", first: true, [oldTabA, sbTabFull(b, "old-b", bell: 2)]),
            sbGroup(g2, "Old G2", [sbTabFull(c, "old-c", bell: 3)]),
        ])
        let new = sbProj(false, [
            sbGroup(g1, "New G1", collapsed: true, [newTabA, sbTabFull(c, "new-c", bell: 4)]),
            sbGroup(g2, "New G2", first: true, [sbTabFull(b, "new-b", bell: 5)]),
        ])

        let tabSuppressed = advanceSidebarCache(old: old, new: new, suppressedRenameTarget: .tab(a))
        #expect(tabSuppressed.groups[0].tabs[0] == oldTabA,
            "suppressed tab keeps its old projection")
        #expect(tabSuppressed.groups[0].tabs[1] == new.groups[0].tabs[1],
            "sibling tab takes the new projection")

        let groupSuppressed = advanceSidebarCache(old: old, new: new, suppressedRenameTarget: .group(g1))
        let mergedGroup = groupSuppressed.groups[0]
        #expect(mergedGroup.rendered == old.groups[0].rendered,
            "a suppressed group paint keeps its complete old rendered value")
        #expect(mergedGroup.tabs == new.groups[0].tabs,
            "suppressed group applies the new tab structure")

        #expect(advanceSidebarCache(old: old, new: new, suppressedRenameTarget: nil) == new,
            "nil suppressed target leaves the cache at new")
        let removedA = sbProj(false, [
            sbGroup(g1, "New G1", collapsed: true, [sbTabFull(c, "new-c", bell: 4)]),
            sbGroup(g2, "New G2", first: true, [sbTabFull(b, "new-b", bell: 5)]),
        ])
        #expect(advanceSidebarCache(old: old, new: removedA, suppressedRenameTarget: .tab(a)) == removedA,
            "absent suppressed target leaves the cache at new")
        #expect(advanceSidebarCache(old: nil, new: new, suppressedRenameTarget: .tab(a)) == new,
            "missing old cache leaves the cache at new")
    }

    @Test("advanceSidebarCache retains unapplied row attrs for retry")
    func advanceSidebarCacheRetainsUnappliedRowAttrsForRetry() throws {
        // Intent: an in-place sidebar reload that did not paint keeps its old cache
        //   attrs so the next diff re-emits the row reload.
        // Why it exists: pins the temporal desync fix where a visible row cell could
        //   miss a reload while the toolbar bell advanced from the same model tally.
        // Scenario: a sidebar badge clear reaches the projection, but the on-screen
        //   tab cell is transiently unavailable during the row-op batch.
        let g1 = GroupId(); let g2 = GroupId()
        let a = TabId(); let b = TabId(); let c = TabId()
        let oldTabA = sbTabFull(a, "a", bell: 1)
        let oldTabB = sbTabFull(b, "b-old", bell: 2)
        let newTabA = sbTabFull(a, "a", bell: 0)
        let newTabB = sbTabFull(b, "b-new", bell: 0)
        let newTabC = sbTabFull(c, "c-new", bell: 0)
        let old = sbProj(false, [
            sbGroup(g1, "Old G1", first: true, [oldTabA, oldTabB]),
            sbGroup(g2, "Old G2", [sbTabFull(c, "c-old", bell: 3)]),
        ])
        let new = sbProj(false, [
            sbGroup(g1, "New G1", collapsed: true, [newTabA, newTabB]),
            sbGroup(g2, "New G2", first: true, [newTabC]),
        ])

        let tabRetained = advanceSidebarCache(
            old: old, new: new, suppressedRenameTarget: nil, unappliedTabIds: [a])
        let retainedTabA = try #require(tabRetained.groups.flatMap(\.tabs).first { $0.id == a })
        #expect(retainedTabA == oldTabA, "unapplied tab keeps its old projection")
        #expect(computeSidebarRowOps(old: tabRetained, new: new).contains(.reloadTab(id: a)),
            "retained tab attrs re-emit reloadTab")

        let fullyAdvanced = advanceSidebarCache(old: old, new: new, suppressedRenameTarget: nil)
        #expect(fullyAdvanced == new, "empty unapplied sets advance fully to the new projection")
        #expect(computeSidebarRowOps(old: fullyAdvanced, new: new).contains(.reloadTab(id: a)) == false,
            "fully advanced attrs do not churn reloadTab")

        let groupRetained = advanceSidebarCache(
            old: old, new: new, suppressedRenameTarget: nil, appliedGroupRenders: [:])
        let retainedGroup = try #require(groupRetained.groups.first { $0.id == g1 })
        #expect(retainedGroup.rendered == old.groups[0].rendered,
            "an unpainted group keeps its complete old rendered value")
        #expect(retainedGroup.tabs == new.groups[0].tabs,
            "unapplied group still applies tab structure")
        #expect(computeSidebarRowOps(old: groupRetained, new: new).contains(
            .setGroupCollapsed(id: g1, collapsed: true)),
            "a retained collapse repaint re-emits the structural collapse operation")

        let appliedCollapse = advanceSidebarCache(
            old: old,
            new: new,
            suppressedRenameTarget: nil,
            appliedGroupRenders: [g1: new.groups[0].rendered])
        #expect(appliedCollapse.groups[0].rendered == new.groups[0].rendered,
            "an executor-reported collapse paint advances the complete rendered value")

        var liveRenameRender = new.groups[0].rendered
        liveRenameRender.name = DisplayLine("draft owned by the field editor")
        let renamedCollapse = advanceSidebarCache(
            old: old,
            new: new,
            suppressedRenameTarget: .group(g1),
            appliedGroupRenders: [g1: liveRenameRender])
        let nextOps = computeSidebarRowOps(old: renamedCollapse, new: new)
        #expect(!nextOps.contains(.setGroupCollapsed(id: g1, collapsed: true)),
            "an applied collapse is not repeated while the live editor preserves its title")
        #expect(!guardSidebarRenameOps(
            ops: nextOps, renameTarget: .group(g1), new: new
        ).ops.contains(.reloadGroup(id: g1)),
            "the live rename suppresses the remaining title repaint")

        let composed = advanceSidebarCache(
            old: old, new: new, suppressedRenameTarget: .tab(b), unappliedTabIds: [a])
        let composedTabA = try #require(composed.groups.flatMap(\.tabs).first { $0.id == a })
        let composedTabB = try #require(composed.groups.flatMap(\.tabs).first { $0.id == b })
        let composedTabC = try #require(composed.groups.flatMap(\.tabs).first { $0.id == c })
        #expect(composedTabA == oldTabA, "dropped tab retention composes with rename retention")
        #expect(composedTabB == oldTabB, "rename-suppressed tab still keeps its old projection")
        #expect(composedTabC == newTabC, "unrelated sibling takes the new projection")
    }

    @Test("desiredContainerShapes: eager projection includes selected and background tabs")
    func desiredContainerShapesEagerProjectionIncludesBackgroundTabs() {
        // Intent: desiredContainerShapes covers every tab (selected,
        //   same-group background, collapsed-group background), and each
        //   shape carries its own visibility -- so a selection change moves
        //   `visible` between exactly two shapes and changes nothing else.
        // Why it exists: pins the eager-projection coverage net the
        //   container reconciler relies on for hidden-mounting, and the
        //   fact that visibility travels inside the diffed shape rather
        //   than beside it.
        // Scenario: spec-first eager projection.
        let selectedPaneId = PaneId(), siblingPaneId = PaneId(), otherPaneId = PaneId()
        let selectedTabId = TabId(), siblingTabId = TabId(), otherTabId = TabId()
        let selectedTab = TabModel(
            id: selectedTabId,
            paneTree: PaneTree(root: .leaf(PaneModel(id: selectedPaneId)))
        )
        let siblingTab = TabModel(
            id: siblingTabId,
            paneTree: PaneTree(root: .leaf(PaneModel(id: siblingPaneId)))
        )
        let otherTab = TabModel(
            id: otherTabId,
            paneTree: PaneTree(root: .leaf(PaneModel(id: otherPaneId)))
        )
        var model = AppModel(
            groups: [
                GroupModel(id: GroupId(), name: "Selected", tabs: [selectedTab, siblingTab]),
                GroupModel(id: GroupId(), name: "Collapsed", isCollapsed: true, tabs: [otherTab]),
            ],
            selectedTabId: selectedTabId
        )
        let expectedShapes = [
            selectedTabId: containerShape(of: selectedTab, visible: true),
            siblingTabId: containerShape(of: siblingTab, visible: false),
            otherTabId: containerShape(of: otherTab, visible: false),
        ]
        let expectedKeys = Set(expectedShapes.keys)

        let initial = desiredContainerShapes(in: model)

        #expect(Set(initial.keys) == expectedKeys,
            "projection includes selected, same-group background, and collapsed-group background tabs")
        #expect(initial == expectedShapes,
            "each projected shape matches the tab's container shape, selected one visible")

        model.selectedTabId = otherTabId
        let afterSelectionChange = desiredContainerShapes(in: model)

        #expect(Set(afterSelectionChange.keys) == expectedKeys,
            "selection changes do not change projected tab keys")
        #expect(afterSelectionChange.mapValues(\.visible)
            == [selectedTabId: false, siblingTabId: false, otherTabId: true],
            "selection moves visibility to the newly selected tab and nowhere else")
        #expect(afterSelectionChange[siblingTabId] == initial[siblingTabId],
            "a tab untouched by the selection change keeps its whole shape")
    }

    // MARK: - computeContainerOps (model-apply, Stage 8)

    @Test("computeContainerOps: remove drops a gone tab's container")
    func computeContainerOpsRemoveDropsGoneTab() {
        // Intent: removing a tab drops its container; remaining tabs
        //   keep their visibility states.
        // Why it exists: pins the remove branch of the container diff.
        // Scenario: spec-first remove.
        let a = TabId(), b = TabId(), pa = PaneId(), pb = PaneId()
        checkContainerOps(
            old: [a: cShape(pa, visible: true), b: cShape(pb)],
            new: [a: cShape(pa, visible: true)],
            "removing tab B reaches new (A visible, B gone)")
    }

    @Test("computeContainerOps: tree update on a drifted shape keeps visibility")
    func computeContainerOpsTreeUpdateOnDriftedShapeKeepsVisibility() {
        // Intent: a drifted shape updates the flat container tree and the tab
        //   stays visible.
        // Why it exists: the flat container must preserve mounted pane wrappers
        //   across structural edits.
        // Scenario: spec-first flat-container reconciliation.
        let a = TabId(), pa = PaneId(), pa2 = PaneId()
        checkContainerOps(
            old: [a: cShape(pa, visible: true)],
            new: [a: cSplitShape(pa, pa2, visible: true)],
            "updating A reaches new with A still visible")
    }

    @Test("computeContainerOps: visibility-only selected-tab switch hides old, shows new")
    func computeContainerOpsVisibilityOnlySwitchHidesOldShowsNew() {
        // Intent: a tab switch at identical shapes emits exactly one hide and
        //   one show, and nothing else.
        // Why it exists: pins the visibility-only fast path in both directions --
        //   the dropped-hide regression net, and the guarantee that a switch
        //   never touches the tab it leaves alone.
        // Scenario: spec-first visibility-only.
        let a = TabId(), b = TabId(), c = TabId()
        let pa = PaneId(), pb = PaneId(), pc = PaneId()
        let old = [a: cShape(pa, visible: true), b: cShape(pb), c: cShape(pc)]
        let new = [a: cShape(pa), b: cShape(pb, visible: true), c: cShape(pc)]
        checkContainerOps(old: old, new: new,
            "switching A->B (identical shapes) hides A and shows B -- no rebuild")

        let ops = computeContainerOps(old: old, new: new)
        #expect(ops.count == 2
            && ops.contains(.setVisible(tabId: a, visible: false))
            && ops.contains(.setVisible(tabId: b, visible: true)),
            "a selection change emits one hide, one show, and nothing for the untouched tab: \(ops)")
    }

    @Test("computeContainerOps: no-op when nothing changed (common eager path)")
    func computeContainerOpsNoOpWhenNothingChanged() {
        // Intent: an unchanged projection emits no ops at all, visibility
        //   included.
        // Why it exists: every reconcile sweep runs this diff, and an op that
        //   fires with nothing changed makes the executor relay out every
        //   mounted tab, hidden ones included, on every sweep.
        // Scenario: spec-first no-op.
        let a = TabId(), b = TabId(), pa = PaneId(), pb = PaneId()
        let shapes = [a: cShape(pa, visible: true), b: cShape(pb)]
        checkContainerOps(old: shapes, new: shapes,
            "unchanged projection -> state unchanged (A visible, B hidden)")

        #expect(computeContainerOps(old: shapes, new: shapes).isEmpty,
            "an unchanged sweep must emit no container ops")
    }

    @Test("computeContainerOps: a newly mounted tab is built and then given its visibility")
    func computeContainerOpsBuildIsFollowedByItsVisibility() {
        // Intent: a tab the cache has never seen gets a build followed by a
        //   `.setVisible` carrying its own visibility, whether it is the
        //   selected tab or a background one.
        // Why it exists: a freshly built container is mounted unhidden, so a
        //   new background tab that skipped the visibility write would appear
        //   on top of the selected tab.
        // Scenario: spec-first new-tab mount.
        let existing = TabId(), fresh = TabId()
        let pe = PaneId(), pf = PaneId()
        let old = [existing: cShape(pe, visible: true)]
        checkContainerOps(
            old: old, new: [existing: cShape(pe, visible: true), fresh: cShape(pf)],
            "mounting a background tab ends the sweep with it hidden")
        checkContainerOps(
            old: old, new: [existing: cShape(pe), fresh: cShape(pf, visible: true)],
            "mounting a selected tab ends the sweep with only it visible")

        let background = computeContainerOps(
            old: old, new: [existing: cShape(pe, visible: true), fresh: cShape(pf)])
        #expect(background == [.build(tabId: fresh), .setVisible(tabId: fresh, visible: false)],
            "a new background tab is built and then hidden")

        let selected = computeContainerOps(
            old: old, new: [existing: cShape(pe), fresh: cShape(pf, visible: true)])
        #expect(selected.firstIndex(of: .build(tabId: fresh))
            .map { $0 < selected.firstIndex(of: .setVisible(tabId: fresh, visible: true))! } == true,
            "a new selected tab is built before its visibility is written")
        #expect(selected.contains(.setVisible(tabId: existing, visible: false)),
            "the tab losing selection is hidden in the same sweep")
    }

    @Test("containerOpsStrandVisible flags only ops that strand the visible tab")
    func containerOpsStrandVisibleFlagsOnlyStrandingOps() {
        // Intent: containerOpsStrandVisible flags build/remove/hide of
        //   the previously-visible tab, but not other ops or no-ops -- and it
        //   reads which tab that was from the cached shapes alone.
        // Why it exists: pins the stranding classifier the reconciler
        //   uses to decide whether to force-show a fallback.
        // Scenario: spec-first stranding classifier.
        let visible = TabId(), background = TabId()
        let pv = PaneId(), pb = PaneId()
        let cached = [visible: cShape(pv, visible: true), background: cShape(pb)]

        #expect(
            containerOpsStrandVisible(ops: [.build(tabId: visible)], cachedShapes: cached) == true,
            "visible full build strands the visible container")
        #expect(
            containerOpsStrandVisible(ops: [.remove(tabId: visible)], cachedShapes: cached) == true,
            "visible remove strands the visible container")
        #expect(
            containerOpsStrandVisible(
                ops: [.setVisible(tabId: visible, visible: false)],
                cachedShapes: cached) == true,
            "hiding the visible container strands it")
        #expect(
            containerOpsStrandVisible(
                ops: [.build(tabId: background)],
                cachedShapes: cached
            ) == false,
            "background full build leaves the visible container mounted")
        #expect(
            containerOpsStrandVisible(
                ops: [.setVisible(tabId: visible, visible: true)],
                cachedShapes: cached) == false,
            "showing the visible container is not a stranding op")
        #expect(
            containerOpsStrandVisible(
                ops: [.setVisible(tabId: background, visible: true)],
                cachedShapes: cached) == false,
            "showing a background container is not a stranding op")
        #expect(
            containerOpsStrandVisible(ops: [], cachedShapes: cached) == false,
            "no ops do not strand the visible container")
        #expect(
            containerOpsStrandVisible(
                ops: [.remove(tabId: visible)],
                cachedShapes: [visible: cShape(pv), background: cShape(pb)]) == false,
            "a cache showing nothing has no stranded container")
    }

    @Test("containerOpsEditVisibleTree flags tree and zoom updates only on the visible tab")
    func containerOpsEditVisibleTreeFlagsTreeAndZoom() {
        // Intent: a tree or zoom update to the visible tab is classified as a
        //   live tree edit, while background and visibility ops are not.
        // Why it exists: the AppKit executor uses this boundary to cancel pane
        //   drags without dismissing pane-scoped popovers whose anchors survive.
        // Scenario: the incremental-container reconciliation performance fix.
        let visible = TabId(), background = TabId(), pane = PaneId()
        let pv = PaneId(), pb = PaneId()
        let cached = [visible: cShape(pv, visible: true), background: cShape(pb)]

        #expect(containerOpsEditVisibleTree(
            ops: [.setTree(tabId: visible)], cachedShapes: cached))
        #expect(containerOpsEditVisibleTree(
            ops: [.setZoomedPane(tabId: visible, paneId: pane)], cachedShapes: cached))
        #expect(containerOpsEditVisibleTree(
            ops: [.setTree(tabId: background), .setVisible(tabId: visible, visible: true)],
            cachedShapes: cached) == false)
    }

    @Test("computeContainerOps uses a full build only when the cached tab is absent")
    func computeContainerOpsUsesFullBuildOnlyForAbsentTab() {
        // Intent: resetting the reconciliation cache causes a clean full build,
        //   while a surviving tab's changed tree receives a direct update.
        // Why it exists: restore must never reuse stale hosts, and ordinary edits
        //   must never fall back to whole-tab reconstruction.
        // Scenario: spec-first clean-restore and live-edit cache boundary.
        let tabId = TabId(), pane = PaneId(), sibling = PaneId()
        let old = cShape(pane)
        let new = cSplitShape(pane, sibling)

        let clean = computeContainerOps(old: [:], new: [tabId: new])
        #expect(clean.contains(.build(tabId: tabId)))

        let live = computeContainerOps(old: [tabId: old], new: [tabId: new])
        #expect(live.contains(.build(tabId: tabId)) == false)
        #expect(live.contains(.setTree(tabId: tabId)))
    }

    // MARK: - ContainerShape (layout / payload excluded / structural change)

    @Test("a ratio-only container change requests layout without a tree edit")
    func containerShapeCarriesRatioIntoLayoutOnlyOp() {
        // Intent: a split ratio changes the mounted tab's layout immediately,
        //   without classifying the gesture as a structural tree edit.
        // Why it exists: a divider drag must track the mouse in foreground and
        //   background tabs without cancelling a pane drag.
        // Scenario: spec-first ratio-only reconcile.
        let p1 = PaneId(), p2 = PaneId(), sid = SplitId()
        let tabId = TabId()
        let lo = TabModel(id: tabId, paneTree: PaneTree(
            root: splitNode(sid, p1, p2, ratio: 0.3), focusedPaneId: p1))
        let hi = TabModel(id: tabId, paneTree: PaneTree(
            root: splitNode(sid, p1, p2, ratio: 0.8), focusedPaneId: p1))

        let cached = [tabId: containerShape(of: lo, visible: true)]
        let ops = computeContainerOps(
            old: cached,
            new: [tabId: containerShape(of: hi, visible: true)]
        )

        #expect(ops.contains(.setLayout(tabId: tabId)))
        #expect(ops.contains { if case .setTree = $0 { true } else { false } } == false)
        #expect(containerOpsEditVisibleTree(ops: ops, cachedShapes: cached) == false)
    }

    @Test("every structural discriminator emits a tree edit, never a layout-only op")
    func containerOpsClassifyEveryStructuralDiscriminatorAsTreeEdit() {
        // Intent: each way one pane tree can differ structurally from another --
        //   node kind, split id, split direction, leaf pane id, and a change
        //   buried in a nested descendant -- makes computeContainerOps emit
        //   `.setTree` and never `.setLayout`.
        // Why it exists: the tree-vs-ratio decision compares two layout trees
        //   while skipping their ratios. A comparison that drops one
        //   discriminator would report a real tree edit as a ratio-only change,
        //   and containerOpsEditVisibleTree would then fail to cancel a pane
        //   drag whose split no longer exists.
        // Scenario: spec-first sweep over the structural discriminators.
        let tabId = TabId()
        let p1 = PaneId(), p2 = PaneId(), p3 = PaneId()
        let sid = SplitId(), otherSid = SplitId(), innerSid = SplitId()

        func tab(_ root: SplitNodeModel) -> TabModel {
            TabModel(id: tabId, paneTree: PaneTree(root: root, focusedPaneId: p1))
        }
        func expectTreeEdit(_ old: SplitNodeModel, _ new: SplitNodeModel, _ what: String) {
            let ops = computeContainerOps(
                old: [tabId: containerShape(of: tab(old), visible: true)],
                new: [tabId: containerShape(of: tab(new), visible: true)]
            )
            #expect(ops.contains(.setTree(tabId: tabId)), "\(what) is a tree edit")
            #expect(ops.contains(.setLayout(tabId: tabId)) == false,
                "\(what) must not be reported as a ratio-only layout change")
        }

        let leaf = SplitNodeModel.leaf(PaneModel(id: p1))
        let split = splitNode(sid, p1, p2, ratio: 0.5)
        expectTreeEdit(leaf, split, "splitting a leaf")
        expectTreeEdit(split, leaf, "closing a pane")
        expectTreeEdit(split, splitNode(otherSid, p1, p2, ratio: 0.5), "a new split id")
        expectTreeEdit(
            split,
            .split(
                id: sid,
                direction: .vertical,
                first: .leaf(PaneModel(id: p1)),
                second: .leaf(PaneModel(id: p2)),
                ratio: 0.5
            ),
            "a split direction change")
        expectTreeEdit(split, splitNode(sid, p1, p3, ratio: 0.5), "a swapped leaf pane id")

        let nested = SplitNodeModel.split(
            id: sid,
            direction: .horizontal,
            first: .leaf(PaneModel(id: p1)),
            second: splitNode(innerSid, p2, p3, ratio: 0.5),
            ratio: 0.5
        )
        let nestedEdited = SplitNodeModel.split(
            id: sid,
            direction: .horizontal,
            first: .leaf(PaneModel(id: p1)),
            second: .split(
                id: innerSid,
                direction: .vertical,
                first: .leaf(PaneModel(id: p2)),
                second: .leaf(PaneModel(id: p3)),
                ratio: 0.5
            ),
            ratio: 0.5
        )
        expectTreeEdit(nested, nestedEdited, "a change confined to a nested descendant")
    }

    @Test("ContainerShape: a leaf PaneModel metadata edit compares equal")
    func containerShapeIgnoresLeafMetadata() {
        // Intent: leaf metadata (title/cwd/progress/todos/theme) is NOT
        //   part of the container shape.
        // Why it exists: pins the leaf-payload carveout so metadata
        //   edits don't rebuild the container.
        // Scenario: spec-first leaf metadata carveout.
        let p1 = PaneId(), p2 = PaneId(), sid = SplitId()
        let leftA = PaneModel(id: p1, session: SessionModel(id: SessionId(), titleState: .declared("alpha"), cwd: "/a"))
        var leftB = PaneModel(id: p1, session: SessionModel(id: SessionId(), titleState: .declared("beta"), cwd: "/b"))
        leftB.session?.progress = .set(percent: 50)
        leftB.todos = [TodoItem(id: UUID(), text: "do", isDone: false)]
        leftB.theme = "Dracula"
        let nodeA = SplitNodeModel.split(id: sid, direction: .horizontal, first: .leaf(leftA), second: .leaf(PaneModel(id: p2)), ratio: 0.5)
        let nodeB = SplitNodeModel.split(id: sid, direction: .horizontal, first: .leaf(leftB), second: .leaf(PaneModel(id: p2)), ratio: 0.5)
        let tabA = TabModel(id: TabId(), paneTree: PaneTree(root: nodeA, focusedPaneId: p1))
        let tabB = TabModel(id: TabId(), paneTree: PaneTree(root: nodeB, focusedPaneId: p1))
        #expect(containerShape(of: tabA, visible: true) == containerShape(of: tabB, visible: true),
            "leaf payload (title/cwd/progress/todo/theme) is excluded -- a metadata edit must not rebuild")
    }

    @Test("ContainerShape: structural change / zoom toggle compare unequal")
    func containerShapeStructuralChangeUnequal() {
        // Intent: structural changes (single<->split, split direction,
        //   leaf id change, zoom toggle) DO change the shape.
        // Why it exists: pins the positive case of the shape equality
        //   contract.
        // Scenario: spec-first structural unequal.
        let p1 = PaneId(), p2 = PaneId(), p3 = PaneId(), sid = SplitId()
        let single = TabModel(id: TabId(), paneTree: PaneTree(root: .leaf(PaneModel(id: p1)), focusedPaneId: p1))
        let split = TabModel(id: TabId(), paneTree: PaneTree(root: splitNode(sid, p1, p2, ratio: 0.5), focusedPaneId: p1))
        #expect(containerShape(of: single, visible: true) != containerShape(of: split, visible: true),
            "adding a leaf (single -> split) changes the shape")
        let splitV = TabModel(
            id: TabId(),
            paneTree: PaneTree(
                root: .split(
                    id: sid,
                    direction: .vertical,
                    first: .leaf(PaneModel(id: p1)),
                    second: .leaf(PaneModel(id: p2)),
                    ratio: 0.5
                ),
                focusedPaneId: p1
            )
        )
        #expect(containerShape(of: split, visible: true) != containerShape(of: splitV, visible: true),
            "changing split direction changes the shape")
        let splitMoved = TabModel(id: TabId(), paneTree: PaneTree(root: splitNode(sid, p1, p3, ratio: 0.5), focusedPaneId: p1))
        #expect(containerShape(of: split, visible: true) != containerShape(of: splitMoved, visible: true),
            "swapping a leaf id changes the shape")
        var zoomed = split; _ = zoomed.paneTree.zoom(p1)
        #expect(containerShape(of: split, visible: true) != containerShape(of: zoomed, visible: true),
            "zooming changes the shape")
    }

    // MARK: - sessionsToTearDown (migrated sessionCreationFailed net)

    @Test("sessionsToTearDown selects exactly the panes gone from the model")
    func sessionsToTearDownSelectsOnlyGonePanes() {
        // Intent: sessionsToTearDown returns only live sessions whose
        //   pane is no longer in the model.
        // Why it exists: pins the teardown net the reconciler uses to
        //   destroy orphaned sessions.
        // Scenario: spec-first teardown net.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let live = Set(model.allPaneIds)
        let dead1 = PaneId(), dead2 = PaneId()
        let teardown = sessionsToTearDown(liveSessionIds: live.union([dead1, dead2]), model: model)
        #expect(teardown == Set([dead1, dead2]),
            "only the sessions whose pane left the model are selected")
        #expect(teardown.isDisjoint(with: live),
            "surviving panes are never selected for teardown")
    }
}

// MARK: - Sidebar projection test builders + op model-apply

private func sbTab(_ name: String) -> SidebarTabProjection {
    SidebarTabProjection(id: TabId(), displayTitle: DisplayLine(name), unreadAlertCount: 0, jumpKey: nil, color: nil)
}
private func sbTab2(_ id: TabId) -> SidebarTabProjection {
    SidebarTabProjection(id: id, displayTitle: "t", unreadAlertCount: 0, jumpKey: nil, color: nil)
}
private func sbTabFull(_ id: TabId, _ title: String, bell: Int) -> SidebarTabProjection {
    SidebarTabProjection(id: id, displayTitle: DisplayLine(title), unreadAlertCount: bell, jumpKey: nil, color: nil)
}
private func sbGroup(_ id: GroupId, _ name: String, collapsed: Bool = false, first: Bool = false, _ tabs: [SidebarTabProjection]) -> SidebarGroupProjection {
    SidebarGroupProjection(
        id: id,
        rendered: SidebarGroupProjection.Rendered(
            isCollapsed: collapsed,
            name: DisplayLine(name),
            unreadAlertCount: tabs.reduce(0) { $0 + $1.unreadAlertCount },
            tabCount: tabs.count,
            isFirst: first),
        tabs: tabs)
}
private func sbProj(_ single: Bool, _ groups: [SidebarGroupProjection]) -> SidebarProjection {
    SidebarProjection(isSingleGroupMode: single, groups: groups)
}

/// Apply an ordered SidebarRowOp script to a working copy of `old`, sourcing inserted/
/// reloaded row *content* from `new` -- the executable spec the model-apply test checks.
/// Mirrors how reconcileSidebar's executor mutates its backing store: indices are
/// structural (a wrong index yields a wrong list) while content comes from new. Inserted
/// groups default to expanded (like NSOutlineView), so a collapsed inserted group must
/// be flipped by a setGroupCollapsed op -- exactly what the executor relies on.
private func applySidebarRowOps(_ ops: [SidebarRowOp], to old: SidebarProjection, new: SidebarProjection) -> SidebarProjection {
    var work = old
    work.isSingleGroupMode = new.isSingleGroupMode
    work.selectedTabId = new.selectedTabId
    work.singleGroupDropTargetId = new.singleGroupDropTargetId
    work.canDeleteGroups = new.canDeleteGroups
    work.rename = new.rename
    func newGroup(_ id: GroupId) -> SidebarGroupProjection { new.groups.first { $0.id == id }! }
    func newTab(_ id: TabId) -> SidebarTabProjection { new.groups.flatMap(\.tabs).first { $0.id == id }! }
    func groupIndex(_ id: GroupId) -> Int { work.groups.firstIndex { $0.id == id }! }
    for op in ops {
        switch op {
        case .reloadAll:
            work = new
        case .insertGroup(let id, let index):
            var g = newGroup(id)
            g.rendered.isCollapsed = false
            work.groups.insert(g, at: index)
        case .removeGroup(let index):
            work.groups.remove(at: index)
        case .reloadGroup(let id):
            let gi = groupIndex(id); let src = newGroup(id)
            work.groups[gi].rendered = src.rendered
        case .setGroupCollapsed(let id, let collapsed):
            work.groups[groupIndex(id)].rendered = newGroup(id).rendered
            work.groups[groupIndex(id)].rendered.isCollapsed = collapsed
        case .insertTab(let id, let groupId, let index):
            work.groups[groupIndex(groupId)].tabs.insert(newTab(id), at: index)
        case .removeTab(let groupId, let index):
            work.groups[groupIndex(groupId)].tabs.remove(at: index)
        case .reloadTab(let id):
            for gi in work.groups.indices {
                if let ti = work.groups[gi].tabs.firstIndex(where: { $0.id == id }) {
                    work.groups[gi].tabs[ti] = newTab(id)
                    break
                }
            }
        }
    }
    return work
}

/// old -> apply(computeSidebarRowOps(old,new)) must equal new.
private func checkRowOps(_ old: SidebarProjection?, _ new: SidebarProjection, _ name: String) {
    let ops = computeSidebarRowOps(old: old, new: new)
    let result = applySidebarRowOps(ops, to: old ?? SidebarProjection(isSingleGroupMode: new.isSingleGroupMode, groups: []), new: new)
    #expect(result == new, "\(name)")
}

// MARK: - Container shape + op model-apply (Stage 8)

private func cShape(_ p: PaneId, visible: Bool = false) -> ContainerShape {
    ContainerShape(layout: .leaf(p), zoomedLeaf: nil, visible: visible)
}
private func cSplitShape(_ a: PaneId, _ b: PaneId, visible: Bool = false) -> ContainerShape {
    ContainerShape(
        layout: .split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(a),
            second: .leaf(b),
            ratio: 0.5
        ),
        zoomedLeaf: nil,
        visible: visible
    )
}
private func splitNode(_ sid: SplitId, _ a: PaneId, _ b: PaneId, ratio: SplitRatio) -> SplitNodeModel {
    .split(id: sid, direction: .horizontal, first: .leaf(PaneModel(id: a)), second: .leaf(PaneModel(id: b)), ratio: ratio)
}

private func applyContainerOps(_ ops: [ContainerOp], to old: [TabId: Bool]) -> [TabId: Bool] {
    var state = old
    for op in ops {
        switch op {
        case .remove(let t): state[t] = nil
        // buildAndInsertContainer mounts a container unhidden, so a script that
        // never writes visibility after a build leaves a background tab showing.
        case .build(let t): state[t] = true
        case .setTree: break
        case .setLayout: break
        case .setZoomedPane: break
        case .setVisible(let t, let v): state[t] = v
        }
    }
    return state
}

/// Applies the diffed script to the visibility state the cache describes and
/// checks it reproduces exactly what `new` asks for.
private func checkContainerOps(
    old: [TabId: ContainerShape], new: [TabId: ContainerShape], _ name: String
) {
    let ops = computeContainerOps(old: old, new: new)
    let result = applyContainerOps(ops, to: old.mapValues(\.visible))
    #expect(result == new.mapValues(\.visible), "\(name)")
}
