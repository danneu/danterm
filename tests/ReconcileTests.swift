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

    // MARK: - Effect.isPostReconcile (command-phase split, Stage 4)

    test("Effect.isPostReconcile: only focusSearchField defers past reconcile") {
        let pane = PaneId()
        // focusSearchField targets the search field reconcilePaneChrome creates, so
        // it must run after reconcile().
        try expect(Effect.focusSearchField(paneId: pane).isPostReconcile,
            "focusSearchField is post-reconcile")
        // makeFirstResponder stays pre-reconcile in Stage 4: its TerminalView is
        // still built by the effect-built container path (flips in Stage 8).
        try expect(!Effect.makeFirstResponder(paneId: pane).isPostReconcile,
            "makeFirstResponder stays pre-reconcile")
        // focusSurface acts on an already-existing surface; deferring it is wrong.
        try expect(!Effect.focusSurface(paneId: pane, focused: true).isPostReconcile,
            "focusSurface is pre-reconcile")
        // A representative sample of other commands are pre-reconcile.
        try expect(!Effect.createSurface(paneId: pane, cwd: nil, command: nil).isPostReconcile,
            "createSurface is pre-reconcile")
        try expect(!Effect.applyPaneTheme(paneId: pane).isPostReconcile,
            "applyPaneTheme is pre-reconcile")
        try expect(!Effect.sendEndSearch(paneId: pane).isPostReconcile,
            "sendEndSearch is pre-reconcile")
        try expect(!Effect.scheduleCheckpoint.isPostReconcile,
            "scheduleCheckpoint is pre-reconcile")
        try expect(!Effect.terminate.isPostReconcile,
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
