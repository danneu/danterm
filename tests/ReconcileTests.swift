// Tests for the view reconciler's pure primitives (Stage 3+): the generic
// `applyDiff` diff/apply/prune helper. Reconcile *passes* themselves touch
// AppKit and are manual-QA-only; this file covers the structure-insensitive
// pure plumbing the passes are built on.
import Foundation

func reconcileTests() {
    print("Reconcile Tests...")

    // MARK: - applyDiff

    test("applyDiff applies only changed/new keys and skips unchanged ones") {
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        let desired: [String: Int] = ["a": 1, "b": 99, "c": 3]
        applyDiff(desired, &cache, apply: { k, _ in applied.append(k) })

        try expectEqual(Set(applied), Set(["b", "c"]),
            "only the changed key (b) and new key (c) apply")
        try expect(!applied.contains("a"), "unchanged key (a) is skipped")
        try expectEqual(cache, desired, "cache matches desired after the diff")
    }

    test("applyDiff invokes remove exactly once for a disappeared key, then prunes it") {
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        var removed: [String] = []
        let desired: [String: Int] = ["a": 1]  // 'b' left the desired set
        applyDiff(desired, &cache,
            apply: { k, _ in applied.append(k) },
            remove: { k in removed.append(k) })

        try expect(applied.isEmpty, "no key changed, so nothing applies")
        try expectEqual(removed, ["b"], "the disappeared key invokes remove exactly once")
        try expectEqual(cache, ["a": 1], "the disappeared key is pruned from the cache")
    }

    test("applyDiff with the default no-op remove still prunes disappeared keys") {
        var cache: [String: Int] = ["a": 1, "b": 2]
        var applied: [String] = []
        let desired: [String: Int] = ["a": 1]
        applyDiff(desired, &cache, apply: { k, _ in applied.append(k) })

        try expect(applied.isEmpty, "no changes apply")
        try expectEqual(cache, ["a": 1],
            "the disappeared key is pruned even when remove is the default no-op")
    }

    // MARK: - Command.isPostReconcile (command-phase split, Stage 4)

    test("Command.isPostReconcile: exactly makeFirstResponder + focusSearchField defer past reconcile") {
        let pane = PaneId()
        // focusSearchField targets the search field reconcilePaneChrome creates, so
        // it must run after reconcile().
        try expect(Command.focusSearchField(paneId: pane).isPostReconcile,
            "focusSearchField is post-reconcile")
        // makeFirstResponder is post-reconcile as of Stage 8: reconcileContainers now mounts
        // the pane's TerminalView during reconcile, so first responder must be set after.
        try expect(Command.makeFirstResponder(paneId: pane).isPostReconcile,
            "makeFirstResponder is post-reconcile (Stage 8)")
        // focusSurface acts on an already-existing surface; deferring it is wrong.
        try expect(!Command.focusSurface(paneId: pane, focused: true).isPostReconcile,
            "focusSurface is pre-reconcile")
        // A representative sample of other commands are pre-reconcile.
        try expect(!Command.createSurface(paneId: pane, cwd: nil, command: nil).isPostReconcile,
            "createSurface is pre-reconcile")
        try expect(!Command.sendEndSearch(paneId: pane).isPostReconcile,
            "sendEndSearch is pre-reconcile")
        try expect(!Command.scheduleCheckpoint.isPostReconcile,
            "scheduleCheckpoint is pre-reconcile")
        try expect(!Command.terminate.isPostReconcile,
            "terminate is pre-reconcile")
    }

    // MARK: - computeSidebarRowOps (model-apply, Stage 5)
    //
    // NOT an exact-sequence assertion: we apply the emitted ops in order to an in-memory
    // model of the old projection and assert the result equals the new projection. This
    // is structure-insensitive (a valid but differently-ordered diff still passes) and is
    // the form that actually catches NSOutlineView-invalid index ordering -- an exact
    // expectEqual on the op list would instead bless a crashing order.

    /// old -> apply(computeSidebarRowOps(old,new)) must equal new.
    func checkRowOps(_ old: SidebarProjection?, _ new: SidebarProjection, _ name: String) throws {
        let ops = computeSidebarRowOps(old: old, new: new)
        let result = applySidebarRowOps(ops, to: old ?? SidebarProjection(isSingleGroupMode: new.isSingleGroupMode, groups: []), new: new)
        try expectEqual(result, new, name)
    }

    test("computeSidebarRowOps: first build inserts all rows") {
        let g = GroupId()
        let new = sbProj(false, [sbGroup(g, "A", first: true, [sbTab("a"), sbTab("b")])])
        try expectEqual(computeSidebarRowOps(old: nil, new: new), [.reloadAll],
            "nil old -> reloadAll")
        try checkRowOps(nil, new, "first build reaches new")
    }

    test("computeSidebarRowOps: single<->multi group-mode flip rebuilds") {
        let g = GroupId()
        let single = sbProj(true, [sbGroup(g, "G", first: true, [sbTab("a")])])
        let multi = sbProj(false, [sbGroup(g, "G", first: true, [sbTab("a")]), sbGroup(GroupId(), "H", [sbTab("b")])])
        try expectEqual(computeSidebarRowOps(old: single, new: multi), [.reloadAll],
            "mode flip -> reloadAll")
        try checkRowOps(single, multi, "mode flip reaches new")
    }

    test("computeSidebarRowOps: tab insert / remove / reorder / cross-group move") {
        let g1 = GroupId(); let g2 = GroupId()
        let a = TabId(); let b = TabId(); let c = TabId()
        func two(_ t1: [SidebarTabProjection], _ t2: [SidebarTabProjection]) -> SidebarProjection {
            sbProj(false, [sbGroup(g1, "L", first: true, t1), sbGroup(g2, "R", t2)])
        }
        let A = sbTab2(a); let B = sbTab2(b); let C = sbTab2(c)
        try checkRowOps(two([A, B], [C]), two([A, B], [C]), "no-op")
        try checkRowOps(two([A], [C]),    two([A, B], [C]), "insert B into L")
        try checkRowOps(two([A, B], [C]), two([A], [C]),    "remove B from L")
        try checkRowOps(two([A, B, C], []), two([C, A, B], []), "reorder within L")
        try checkRowOps(two([A, B], [C]), two([A], [C, B]),  "move B from L to R")
        try checkRowOps(two([A, B], [C]), two([C], [A, B]),  "swap-ish across groups")
    }

    test("computeSidebarRowOps: reload fires on changed attrs (and tabCount badge)") {
        let g = GroupId(); let a = TabId(); let b = TabId()
        let old = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "x", bell: 0), sbTabFull(b, "y", bell: 0)])])
        // a's title changed, b's bell changed -> both reload; group's bell rolls up.
        let new = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "X", bell: 0), sbTabFull(b, "y", bell: 3)])])
        let ops = computeSidebarRowOps(old: old, new: new)
        try expect(ops.contains(.reloadTab(id: a)), "a's title change -> reloadTab(a)")
        try expect(ops.contains(.reloadTab(id: b)), "b's bell change -> reloadTab(b)")
        try expect(ops.contains(.reloadGroup(id: g)), "group bell roll-up change -> reloadGroup")
        try checkRowOps(old, new, "attr changes reach new")
    }

    test("computeSidebarRowOps: group insert / remove / reorder / collapse") {
        let g1 = GroupId(); let g2 = GroupId(); let g3 = GroupId()
        func g(_ id: GroupId, _ name: String, first: Bool = false, collapsed: Bool = false) -> SidebarGroupProjection {
            sbGroup(id, name, collapsed: collapsed, first: first, [sbTab(name.lowercased())])
        }
        let base = sbProj(false, [g(g1, "A", first: true), g(g2, "B")])
        try checkRowOps(base, sbProj(false, [g(g1, "A", first: true), g(g2, "B"), g(g3, "C")]), "insert group C")
        try checkRowOps(sbProj(false, [g(g1, "A", first: true), g(g2, "B"), g(g3, "C")]), base, "remove group C")
        try checkRowOps(base, sbProj(false, [g(g2, "B", first: true), g(g1, "A")]), "reorder groups (isFirst flips)")
        try checkRowOps(base, sbProj(false, [g(g1, "A", first: true), g(g2, "B", collapsed: true)]), "collapse group B")
        try checkRowOps(sbProj(false, [g(g1, "A", first: true), g(g2, "B", collapsed: true)]), base, "expand group B")
        // Inserting an already-collapsed group must emit setGroupCollapsed (default is expanded).
        let ops = computeSidebarRowOps(old: base, new: sbProj(false, [g(g1, "A", first: true), g(g2, "B"), g(g3, "C", collapsed: true)]))
        try expect(ops.contains(.setGroupCollapsed(id: g3, collapsed: true)), "inserted collapsed group flips collapse")
        try checkRowOps(base, sbProj(false, [g(g1, "A", first: true), g(g2, "B"), g(g3, "C", collapsed: true)]), "insert collapsed group")
    }

    test("computeSidebarRowOps: combined structural + attr churn reaches new") {
        let g1 = GroupId(); let g2 = GroupId()
        let a = TabId(); let b = TabId(); let c = TabId(); let d = TabId()
        let old = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(a, "a", bell: 0), sbTabFull(b, "b", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0)]),
        ])
        // close a, move b to R, insert d into L, change c's bell, collapse R.
        let new = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(d, "d", bell: 0)]),
            sbGroup(g2, "R", collapsed: true, [sbTabFull(c, "c", bell: 5), sbTabFull(b, "b", bell: 0)]),
        ])
        try checkRowOps(old, new, "combined churn reaches new")
    }

    // MARK: - guardSidebarRenameOps (rename-guard scope, Stage 5)

    test("guardSidebarRenameOps: suppresses a reload of the edited row, keeps others") {
        let g = GroupId(); let a = TabId(); let b = TabId()
        let old = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "old", bell: 0), sbTabFull(b, "b", bell: 0)])])
        let new = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "TYPED", bell: 0), sbTabFull(b, "b", bell: 0)])])
        let ops = computeSidebarRowOps(old: old, new: new)   // [.reloadTab(a)]
        // Editing tab A: its reload is suppressed (the field editor owns the title).
        let editingA = guardSidebarRenameOps(ops: ops, renameTarget: .tab(a), new: new)
        try expect(!editingA.ops.contains(.reloadTab(id: a)), "reload of the edited row suppressed")
        try expect(!editingA.clearRename, "a reload does not end the edit")
        // A reload of a DIFFERENT row is applied.
        let editingB = guardSidebarRenameOps(ops: ops, renameTarget: .tab(b), new: new)
        try expect(editingB.ops.contains(.reloadTab(id: a)), "reload of a different row applies")
    }

    test("guardSidebarRenameOps: structural ops on the edited row apply AND clear the sidecar") {
        let g1 = GroupId(); let g2 = GroupId(); let a = TabId(); let b = TabId(); let c = TabId()
        let old = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(a, "a", bell: 0), sbTabFull(b, "b", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0)]),
        ])
        // Close A (the edited row) -> it leaves the new projection: remove applies, edit ends.
        let closed = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(b, "b", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0)]),
        ])
        let closeGuarded = guardSidebarRenameOps(
            ops: computeSidebarRowOps(old: old, new: closed), renameTarget: .tab(a), new: closed)
        try expect(closeGuarded.clearRename, "closing the edited row clears the sidecar")
        try expectEqual(applySidebarRowOps(closeGuarded.ops, to: old, new: closed), closed,
            "the remove still applies")
        // Move A to group R (the QA-13 "move from another path") -> A is re-inserted by id
        // into R, so its cell is recreated: structural ops apply and the edit ends.
        let moved = sbProj(false, [
            sbGroup(g1, "L", first: true, [sbTabFull(b, "b", bell: 0)]),
            sbGroup(g2, "R", [sbTabFull(c, "c", bell: 0), sbTabFull(a, "a", bell: 0)]),
        ])
        let moveGuarded = guardSidebarRenameOps(
            ops: computeSidebarRowOps(old: old, new: moved), renameTarget: .tab(a), new: moved)
        try expect(moveGuarded.clearRename, "moving the edited row to another group clears the sidecar")
        try expectEqual(applySidebarRowOps(moveGuarded.ops, to: old, new: moved), moved,
            "the move (remove + insert-by-id) still applies")
    }

    test("guardSidebarRenameOps: nil rename target is a pass-through") {
        let g = GroupId(); let a = TabId()
        let old = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "a", bell: 0)])])
        let new = sbProj(false, [sbGroup(g, "G", first: true, [sbTabFull(a, "A", bell: 0)])])
        let ops = computeSidebarRowOps(old: old, new: new)
        let guarded = guardSidebarRenameOps(ops: ops, renameTarget: nil, new: new)
        try expectEqual(guarded.ops, ops, "no edit -> ops unchanged")
        try expect(!guarded.clearRename, "no edit -> nothing to clear")
    }

    test("advanceSidebarCache retains suppressed row attrs while applying structure") {
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
        try expectEqual(tabSuppressed.groups[0].tabs[0], oldTabA,
            "suppressed tab keeps its old projection")
        try expectEqual(tabSuppressed.groups[0].tabs[1], new.groups[0].tabs[1],
            "sibling tab takes the new projection")

        let groupSuppressed = advanceSidebarCache(old: old, new: new, suppressedRenameTarget: .group(g1))
        let mergedGroup = groupSuppressed.groups[0]
        try expectEqual(mergedGroup.name, old.groups[0].name,
            "suppressed group keeps its old name")
        try expectEqual(mergedGroup.unreadAlertCount, old.groups[0].unreadAlertCount,
            "suppressed group keeps its old unread badge")
        try expectEqual(mergedGroup.tabCount, old.groups[0].tabCount,
            "suppressed group keeps its old tab-count badge")
        try expectEqual(mergedGroup.isFirst, old.groups[0].isFirst,
            "suppressed group keeps its old first-row attrs")
        try expectEqual(mergedGroup.isCollapsed, new.groups[0].isCollapsed,
            "suppressed group applies the new collapse structure")
        try expectEqual(mergedGroup.tabs, new.groups[0].tabs,
            "suppressed group applies the new tab structure")

        try expectEqual(advanceSidebarCache(old: old, new: new, suppressedRenameTarget: nil), new,
            "nil suppressed target leaves the cache at new")
        let removedA = sbProj(false, [
            sbGroup(g1, "New G1", collapsed: true, [sbTabFull(c, "new-c", bell: 4)]),
            sbGroup(g2, "New G2", first: true, [sbTabFull(b, "new-b", bell: 5)]),
        ])
        try expectEqual(advanceSidebarCache(old: old, new: removedA, suppressedRenameTarget: .tab(a)), removedA,
            "absent suppressed target leaves the cache at new")
        try expectEqual(advanceSidebarCache(old: nil, new: new, suppressedRenameTarget: .tab(a)), new,
            "missing old cache leaves the cache at new")
    }

    test("desiredContainerShapes: eager projection includes selected and background tabs") {
        let selectedPaneId = PaneId(), siblingPaneId = PaneId(), otherPaneId = PaneId()
        let selectedTabId = TabId(), siblingTabId = TabId(), otherTabId = TabId()
        let selectedTab = TabModel(
            id: selectedTabId,
            focusedPaneId: selectedPaneId,
            rootNode: .leaf(PaneModel(id: selectedPaneId))
        )
        let siblingTab = TabModel(
            id: siblingTabId,
            focusedPaneId: siblingPaneId,
            rootNode: .leaf(PaneModel(id: siblingPaneId))
        )
        let otherTab = TabModel(
            id: otherTabId,
            focusedPaneId: otherPaneId,
            rootNode: .leaf(PaneModel(id: otherPaneId))
        )
        var model = AppModel(
            groups: [
                GroupModel(id: GroupId(), name: "Selected", tabs: [selectedTab, siblingTab]),
                GroupModel(id: GroupId(), name: "Collapsed", isCollapsed: true, tabs: [otherTab]),
            ],
            selectedTabId: selectedTabId
        )
        let expectedShapes = [
            selectedTabId: containerShape(of: selectedTab),
            siblingTabId: containerShape(of: siblingTab),
            otherTabId: containerShape(of: otherTab),
        ]
        let expectedKeys = Set(expectedShapes.keys)

        let initial = desiredContainerShapes(in: model)

        try expectEqual(Set(initial.keys), expectedKeys,
            "projection includes selected, same-group background, and collapsed-group background tabs")
        try expectEqual(initial, expectedShapes,
            "each projected shape matches the tab's container shape")

        model.selectedTabId = otherTabId
        let afterSelectionChange = desiredContainerShapes(in: model)

        try expectEqual(Set(afterSelectionChange.keys), expectedKeys,
            "selection changes do not change projected tab keys")
        try expectEqual(afterSelectionChange, initial,
            "selection changes do not change projected container shapes")
    }

    // MARK: - computeContainerOps (model-apply, Stage 8)
    //
    // Like the sidebar diff, this is a model-apply test, NOT an exact-sequence assert:
    // apply the ops in order to a plain [TabId: Bool] presence+visibility map and assert
    // it equals new's keys with (tabId == selectedTabId) visibility. This catches a
    // dropped-hide regression (leaving two containers visible) that an exact-sequence
    // assert would bless.

    test("computeContainerOps: remove drops a gone tab's container") {
        let a = TabId(), b = TabId(), pa = PaneId(), pb = PaneId()
        try checkContainerOps(
            old: [a: cShape(pa), b: cShape(pb)], oldVisible: [a: true, b: false],
            new: [a: cShape(pa)], newSelected: a,
            "removing tab B reaches new (A visible, B gone)")
    }

    test("computeContainerOps: rebuild on a drifted shape keeps visibility") {
        let a = TabId(), pa = PaneId(), pa2 = PaneId()
        // A's shape drifts (single leaf -> split): the op list must rebuild A and keep it visible.
        try checkContainerOps(
            old: [a: cShape(pa)], oldVisible: [a: true],
            new: [a: cSplitShape(pa, pa2)], newSelected: a,
            "rebuilding A reaches new with A still visible")
    }

    test("computeContainerOps: visibility-only selected-tab switch hides old, shows new") {
        // The dropped-hide net: A visible + B mounted-hidden at IDENTICAL shapes, switch to B.
        // The ops must hide A and show B (not leave both visible).
        let a = TabId(), b = TabId(), pa = PaneId(), pb = PaneId()
        try checkContainerOps(
            old: [a: cShape(pa), b: cShape(pb)], oldVisible: [a: true, b: false],
            new: [a: cShape(pa), b: cShape(pb)], newSelected: b,
            "switching A->B (identical shapes) hides A and shows B -- no rebuild")
    }

    test("computeContainerOps: no-op when the selected tab is unchanged (common eager path)") {
        let a = TabId(), b = TabId(), pa = PaneId(), pb = PaneId()
        try checkContainerOps(
            old: [a: cShape(pa), b: cShape(pb)], oldVisible: [a: true, b: false],
            new: [a: cShape(pa), b: cShape(pb)], newSelected: a,
            "unchanged selection + shapes -> state unchanged (A visible, B hidden)")
    }

    test("reconcilePopover clears the record only when container ops strand the visible tab") {
        let visible = TabId(), background = TabId(), pane = PaneId(), tab = TabId()

        try expectEqual(
            reconcilePopover(current: .pane(pane), ops: [.rebuild(tabId: visible)], previouslyVisibleTabId: visible),
            StrandedPopoverOutcome(popover: nil, dismissStranded: true),
            "visible rebuild clears a pane popover and requests AppKit teardown")
        try expectEqual(
            reconcilePopover(current: .tab(tab), ops: [.remove(tabId: visible)], previouslyVisibleTabId: visible),
            StrandedPopoverOutcome(popover: nil, dismissStranded: true),
            "visible remove clears a tab popover and requests AppKit teardown")
        try expectEqual(
            reconcilePopover(current: .pane(pane), ops: [.setVisible(tabId: visible, visible: false)], previouslyVisibleTabId: visible),
            StrandedPopoverOutcome(popover: nil, dismissStranded: true),
            "hiding the visible container clears the popover")
        try expectEqual(
            reconcilePopover(
                current: .pane(pane),
                ops: [.rebuild(tabId: background), .setVisible(tabId: visible, visible: true)],
                previouslyVisibleTabId: visible
            ),
            StrandedPopoverOutcome(popover: .pane(pane), dismissStranded: false),
            "background rebuild and visible show leave the popover alone")
        try expectEqual(
            reconcilePopover(current: nil, ops: [.remove(tabId: visible)], previouslyVisibleTabId: visible),
            StrandedPopoverOutcome(popover: nil, dismissStranded: true),
            "a stranding op still requests AppKit teardown when no model record is open")
        try expectEqual(
            reconcilePopover(current: nil, ops: [], previouslyVisibleTabId: visible),
            StrandedPopoverOutcome(popover: nil, dismissStranded: false),
            "no stranding op leaves nil unchanged")
        try expectEqual(
            reconcilePopover(current: .tab(tab), ops: [.remove(tabId: visible)], previouslyVisibleTabId: nil),
            StrandedPopoverOutcome(popover: .tab(tab), dismissStranded: false),
            "without a previously-visible tab there is no stranded container")
    }

    // MARK: - ContainerShape (ratio carveout / payload excluded / structural change)

    test("ContainerShape: same leaves+splits with different ratios compare equal") {
        let p1 = PaneId(), p2 = PaneId(), sid = SplitId()
        let lo = TabModel(id: TabId(), focusedPaneId: p1, rootNode: splitNode(sid, p1, p2, ratio: 0.3))
        let hi = TabModel(id: TabId(), focusedPaneId: p1, rootNode: splitNode(sid, p1, p2, ratio: 0.8))
        try expectEqual(containerShape(of: lo), containerShape(of: hi),
            "split ratio is excluded -- splitRatioChanged must not rebuild")
    }

    test("ContainerShape: a leaf PaneModel metadata edit compares equal") {
        let p1 = PaneId(), p2 = PaneId(), sid = SplitId()
        var leftA = PaneModel(id: p1); leftA.title = "alpha"; leftA.cwd = "/a"
        var leftB = PaneModel(id: p1); leftB.title = "beta"; leftB.cwd = "/b"
        leftB.progress = .set(percent: 50)
        leftB.todos = [TodoItem(id: UUID(), text: "do", isDone: false)]
        leftB.theme = "Dracula"
        let nodeA = SplitNodeModel.split(id: sid, direction: .horizontal, first: .leaf(leftA), second: .leaf(PaneModel(id: p2)), ratio: 0.5)
        let nodeB = SplitNodeModel.split(id: sid, direction: .horizontal, first: .leaf(leftB), second: .leaf(PaneModel(id: p2)), ratio: 0.5)
        let tabA = TabModel(id: TabId(), focusedPaneId: p1, rootNode: nodeA)
        let tabB = TabModel(id: TabId(), focusedPaneId: p1, rootNode: nodeB)
        try expectEqual(containerShape(of: tabA), containerShape(of: tabB),
            "leaf payload (title/cwd/progress/todo/theme) is excluded -- a metadata edit must not rebuild")
    }

    test("ContainerShape: structural change / zoom toggle compare unequal") {
        let p1 = PaneId(), p2 = PaneId(), p3 = PaneId(), sid = SplitId()
        let single = TabModel(id: TabId(), focusedPaneId: p1, rootNode: .leaf(PaneModel(id: p1)))
        let split = TabModel(id: TabId(), focusedPaneId: p1, rootNode: splitNode(sid, p1, p2, ratio: 0.5))
        try expect(containerShape(of: single) != containerShape(of: split),
            "adding a leaf (single -> split) changes the shape")
        // Change direction.
        let splitV = TabModel(id: TabId(), focusedPaneId: p1,
            rootNode: .split(id: sid, direction: .vertical, first: .leaf(PaneModel(id: p1)), second: .leaf(PaneModel(id: p2)), ratio: 0.5))
        try expect(containerShape(of: split) != containerShape(of: splitV),
            "changing split direction changes the shape")
        // Move a leaf (different leaf id).
        let splitMoved = TabModel(id: TabId(), focusedPaneId: p1, rootNode: splitNode(sid, p1, p3, ratio: 0.5))
        try expect(containerShape(of: split) != containerShape(of: splitMoved),
            "swapping a leaf id changes the shape")
        // Zoom toggle.
        var zoomed = split; zoomed.isZoomed = true
        try expect(containerShape(of: split) != containerShape(of: zoomed),
            "toggling zoom changes the shape")
    }

    // MARK: - chromeInvalidation

    test("chromeInvalidation: rebuild contributes its leaves, setVisible-only is empty") {
        let a = TabId(), b = TabId(), pa = PaneId(), pa2 = PaneId(), pb = PaneId()
        let newShapes: [TabId: ContainerShape] = [a: cSplitShape(pa, pa2), b: cShape(pb)]
        // Rebuild A + show both: only A's two leaves are invalidated.
        let ops: [ContainerOp] = [.rebuild(tabId: a), .setVisible(tabId: a, visible: true), .setVisible(tabId: b, visible: false)]
        try expectEqual(chromeInvalidation(ops: ops, newShapes: newShapes), Set([pa, pa2]),
            "a rebuilt container invalidates every one of its leaf panes")
        // Visibility-only (a tab switch with no rebuild): nothing invalidated.
        let visOnly: [ContainerOp] = [.setVisible(tabId: a, visible: false), .setVisible(tabId: b, visible: true)]
        try expect(chromeInvalidation(ops: visOnly, newShapes: newShapes).isEmpty,
            "a visibility-only switch invalidates no chrome (wrappers survive)")
    }

    // MARK: - surfacesToTearDown (migrated surfaceCreationFailed net)

    test("surfacesToTearDown selects exactly the panes gone from the model") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let live = Set(model.allPaneIds)
        let dead1 = PaneId(), dead2 = PaneId()
        // Live surfaces = the model's panes plus two whose panes no longer exist.
        let teardown = surfacesToTearDown(liveSurfaceIds: live.union([dead1, dead2]), model: model)
        try expectEqual(teardown, Set([dead1, dead2]),
            "only the surfaces whose pane left the model are selected")
        try expect(teardown.isDisjoint(with: live),
            "surviving panes are never selected for teardown")
    }
}

// MARK: - Sidebar projection test builders + op model-apply

private func sbTab(_ name: String) -> SidebarTabProjection {
    SidebarTabProjection(id: TabId(), displayTitle: name, subtitle: nil, unreadAlertCount: 0, jumpKey: nil, color: nil)
}
private func sbTab2(_ id: TabId) -> SidebarTabProjection {
    SidebarTabProjection(id: id, displayTitle: "t", subtitle: nil, unreadAlertCount: 0, jumpKey: nil, color: nil)
}
private func sbTabFull(_ id: TabId, _ title: String, bell: Int) -> SidebarTabProjection {
    SidebarTabProjection(id: id, displayTitle: title, subtitle: nil, unreadAlertCount: bell, jumpKey: nil, color: nil)
}
private func sbGroup(_ id: GroupId, _ name: String, collapsed: Bool = false, first: Bool = false, _ tabs: [SidebarTabProjection]) -> SidebarGroupProjection {
    SidebarGroupProjection(id: id, isCollapsed: collapsed, name: name,
        unreadAlertCount: tabs.reduce(0) { $0 + $1.unreadAlertCount }, tabCount: tabs.count, isFirst: first, tabs: tabs)
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
    func newGroup(_ id: GroupId) -> SidebarGroupProjection { new.groups.first { $0.id == id }! }
    func newTab(_ id: TabId) -> SidebarTabProjection { new.groups.flatMap(\.tabs).first { $0.id == id }! }
    func groupIndex(_ id: GroupId) -> Int { work.groups.firstIndex { $0.id == id }! }
    for op in ops {
        switch op {
        case .reloadAll:
            work = new
        case .insertGroup(let id, let index):
            var g = newGroup(id)
            g.isCollapsed = false   // inserts default expanded; a collapse op flips it
            work.groups.insert(g, at: index)
        case .removeGroup(let index):
            work.groups.remove(at: index)
        case .reloadGroup(let id):
            let gi = groupIndex(id); let src = newGroup(id)
            work.groups[gi].name = src.name
            work.groups[gi].unreadAlertCount = src.unreadAlertCount
            work.groups[gi].tabCount = src.tabCount
            work.groups[gi].isFirst = src.isFirst
        case .setGroupCollapsed(let id, let collapsed):
            work.groups[groupIndex(id)].isCollapsed = collapsed
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

// MARK: - Container shape + op model-apply (Stage 8)

/// A single-leaf container shape (deterministic: no random split id, so two calls
/// with the same pane id compare equal -- needed for the visibility-only test).
private func cShape(_ p: PaneId) -> ContainerShape {
    ContainerShape(tree: .leaf(p), isZoomed: false, zoomedLeaf: nil)
}
/// A two-leaf split container shape (carries a fresh split id, so it never equals a
/// single-leaf shape -- used as the "drifted" shape in the rebuild test).
private func cSplitShape(_ a: PaneId, _ b: PaneId) -> ContainerShape {
    ContainerShape(tree: .split(id: SplitId(), direction: .horizontal, first: .leaf(a), second: .leaf(b)), isZoomed: false, zoomedLeaf: nil)
}
/// A horizontal split SplitNodeModel of two single-pane leaves.
private func splitNode(_ sid: SplitId, _ a: PaneId, _ b: PaneId, ratio: CGFloat) -> SplitNodeModel {
    .split(id: sid, direction: .horizontal, first: .leaf(PaneModel(id: a)), second: .leaf(PaneModel(id: b)), ratio: ratio)
}

/// Apply a ContainerOp script to a [TabId: Bool] presence+visibility map (key present
/// == container mounted; value == isVisible). Mirrors the executor: rebuild mounts a
/// fresh (hidden-by-default) container, setVisible toggles, remove detaches.
private func applyContainerOps(_ ops: [ContainerOp], to old: [TabId: Bool]) -> [TabId: Bool] {
    var state = old
    for op in ops {
        switch op {
        case .remove(let t): state[t] = nil
        case .rebuild(let t): if state[t] == nil { state[t] = false }
        case .setVisible(let t, let v): state[t] = v
        }
    }
    return state
}

/// old(+visibility) -> apply(computeContainerOps(old,new,selected)) must equal new's
/// keys, each visible iff it is the selected tab.
private func checkContainerOps(
    old: [TabId: ContainerShape], oldVisible: [TabId: Bool],
    new: [TabId: ContainerShape], newSelected: TabId?, _ name: String
) throws {
    let ops = computeContainerOps(old: old, new: new, selectedTabId: newSelected)
    let result = applyContainerOps(ops, to: oldVisible)
    var expected: [TabId: Bool] = [:]
    for t in new.keys { expected[t] = (t == newSelected) }
    try expectEqual(result, expected, name)
}
