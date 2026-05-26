// Stage-1 behavioral tests for the tree-owns-panes model restructure.
// These pin the structural guarantees the refactor exists to provide: pane
// content lives in the leaf, lookups go through model.pane(_:)/allPaneIds, and
// the move/split/swap helpers thread the full PaneModel payload (not a fresh
// default rebuilt from a bare id). The payload-threading tests are the net for
// the "Tree-helper carry-through" risk.
import Foundation

func treeOwnsPanesTests() {
    print("Tree-Owns-Panes Tests...")

    // A v1 snapshot (flat `panes` array) decodes into leaf-owned panes: each is
    // reachable via model.pane(id) with its title/cwd/theme/todos, and
    // allPaneIds equals exactly the tab's tree leaves.
    test("v1 snapshot decodes flat panes into leaf-owned panes") {
        let paneAId = "A13076E4-A29C-4358-A771-B4B4DF84C6C5"
        let paneBId = "B2222222-0000-4000-8000-000000000002"
        let json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "\(paneAId)",
                "rootNode": {
                  "type": "split", "direction": "horizontal",
                  "first": { "type": "leaf", "paneId": "\(paneAId)" },
                  "second": { "type": "leaf", "paneId": "\(paneBId)" }
                }
              }]
            }],
            "panes": [
              { "id": "\(paneAId)", "title": "Editor", "cwd": "/work", "theme": "Dracula",
                "todos": [{ "id": "C3333333-0000-4000-8000-000000000003", "text": "ship it", "isDone": false }] },
              { "id": "\(paneBId)", "title": "Shell" }
            ]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        guard let model = validateAndBuild(initFile.model) else {
            throw TestFailure(message: "v1 snapshot should validate")
        }
        let a = PaneId(rawValue: UUID(uuidString: paneAId)!)
        let b = PaneId(rawValue: UUID(uuidString: paneBId)!)

        // Each pane reachable via model.pane(id) with the decoded content.
        try expectEqual(model.pane(a)?.title, "Editor")
        try expectEqual(model.pane(a)?.cwd, "/work")
        try expectEqual(model.pane(a)?.theme, "Dracula")
        try expectEqual(model.pane(a)?.todos.count, 1)
        try expectEqual(model.pane(a)?.todos.first?.text, "ship it")
        try expectEqual(model.pane(b)?.title, "Shell")

        // allPaneIds == the tab tree's leaves (no separate dict).
        try expectEqual(Set(model.allPaneIds), Set([a, b]))
        try expectEqual(Set(model.allPaneIds), Set(allPaneIds(model.groups[0].tabs[0].rootNode)))
    }

    // updatePane mutates only the target leaf; sibling panes and the surrounding
    // split ids/directions/ratios are byte-identical afterward.
    test("updatePane mutates only the target leaf, leaving structure and siblings intact") {
        let a = PaneId(), b = PaneId(), c = PaneId()
        let s1 = SplitId(), s2 = SplitId()
        let paneA = PaneModel(id: a, title: "A")
        let paneB = PaneModel(id: b, title: "B")
        let paneC = PaneModel(id: c, title: "C")
        let root = SplitNodeModel.split(
            id: s1, direction: .horizontal,
            first: .leaf(paneA),
            second: .split(id: s2, direction: .vertical, first: .leaf(paneB), second: .leaf(paneC), ratio: 0.3),
            ratio: 0.7
        )
        var model = makeModel()
        model.groups[0].tabs.append(TabModel(id: TabId(), focusedPaneId: a, rootNode: root))

        model.updatePane(b) { $0.title = "B-changed" }

        // B changed; A and C untouched (full payload equality).
        try expectEqual(model.pane(b)?.title, "B-changed")
        try expectEqual(model.pane(a), paneA)
        try expectEqual(model.pane(c), paneC)
        try expectEqual(model.allPaneIds, [a, b, c])

        // Split ids/directions/ratios identical.
        guard case .split(let rid, .horizontal, _, let rsecond, let rratio) = model.groups[0].tabs[0].rootNode else {
            throw TestFailure(message: "root should still be a horizontal split")
        }
        try expectEqual(rid, s1)
        try expectEqual(rratio, 0.7)
        guard case .split(let r2id, .vertical, _, _, let r2ratio) = rsecond else {
            throw TestFailure(message: "inner should still be a vertical split")
        }
        try expectEqual(r2id, s2)
        try expectEqual(r2ratio, 0.3)
    }

    // After closePane the closed pane is gone from model.pane(_:) and the set of
    // allPaneIds exactly tracks the surviving tree leaves (the old drift
    // invariant, now structural).
    test("closePane removes the pane and allPaneIds tracks the surviving leaves") {
        var model = makeModel()
        createTab(&model)
        let original = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let added = selectedTab(in: model)!.focusedPaneId
        try expect(added != original, "split should add a pane")

        update(&model, .closePane(paneId: added))

        try expect(model.pane(added) == nil, "closed pane should not be reachable")
        try expect(!model.allPaneIds.contains(added), "closed pane should be gone from allPaneIds")
        try expect(model.allPaneIds.contains(original), "surviving pane should remain")
        // Structural: allPaneIds equals the union of every tab tree's leaves.
        let leaves = model.groups.flatMap { $0.tabs.flatMap { allPaneIds($0.rootNode) } }
        try expectEqual(Set(model.allPaneIds), Set(leaves))
    }

    // movePaneToTab physically carries the moved pane's distinctive payload into
    // the target tab's tree; the source tree no longer holds it and it is not
    // duplicated.
    test("movePaneToTab carries the pane's payload to the target leaf") {
        var model = makeModel()
        createTab(&model)
        let sourceTabId = selectedTab(in: model)!.id
        let movable = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(direction: .horizontal))  // keep source tab alive after the move

        model.updatePane(movable) {
            $0.title = "Movable"
            $0.todos = [TodoItem(id: UUID(), text: "carry me", isDone: false)]
        }

        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id

        update(&model, .movePaneToTab(paneId: movable, targetTabId: targetTabId))

        // Payload preserved on the moved pane.
        try expectEqual(model.pane(movable)?.title, "Movable")
        try expectEqual(model.pane(movable)?.todos.count, 1)
        try expectEqual(model.pane(movable)?.todos.first?.text, "carry me")
        // Lands in the target tree, leaves the source tree, appears exactly once.
        try expect(allPaneIds(tabById(targetTabId, in: model)!.rootNode).contains(movable), "moved pane should be in target tab")
        try expect(!allPaneIds(tabById(sourceTabId, in: model)!.rootNode).contains(movable), "moved pane should leave source tab")
        try expectEqual(model.allPaneIds.filter { $0 == movable }.count, 1, "moved pane must not be duplicated")
    }

    // swapLeaves swaps whole PaneModel payloads: each pane's full content lands
    // at the other's tree position.
    test("swapLeaves swaps full payloads between positions") {
        let a = PaneId(), b = PaneId()
        let paneA = PaneModel(id: a, title: "A", cwd: "/a", theme: "Dracula")
        let paneB = PaneModel(id: b, title: "B", cwd: "/b", theme: "Nord")
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(paneA), second: .leaf(paneB), ratio: 0.5
        )

        guard let result = swapLeaves(node, a, b) else {
            throw TestFailure(message: "swap should succeed")
        }
        guard case .split(_, _, .leaf(let first), .leaf(let second), _) = result else {
            throw TestFailure(message: "result should be a split of two leaves")
        }
        // First position now holds B's full payload; second holds A's.
        try expectEqual(first, paneB)
        try expectEqual(second, paneA)
    }

    // The .movePane(.splitRight) path runs moveLeaf -> insertAtLeaf, the only
    // route through insertAtLeaf. The moved pane's full payload (cwd/theme/todos)
    // must land at the new split position; a regression that rebuilt a fresh
    // default leaf from the bare id would silently drop it.
    test("movePane(.splitRight) threads the moved pane's payload through insertAtLeaf") {
        var model = makeModel()
        createTab(&model)
        let target = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(direction: .vertical))
        let source = selectedTab(in: model)!.focusedPaneId
        try expect(source != target, "split should create a distinct source pane")

        model.updatePane(source) {
            $0.cwd = "/src"
            $0.theme = "Dracula"
            $0.todos = [TodoItem(id: UUID(), text: "stay attached", isDone: false)]
        }

        update(&model, .movePane(source: source, target: target, intent: .splitRight))

        // Payload preserved on the moved pane.
        try expectEqual(model.pane(source)?.cwd, "/src")
        try expectEqual(model.pane(source)?.theme, "Dracula")
        try expectEqual(model.pane(source)?.todos.count, 1)
        try expectEqual(model.pane(source)?.todos.first?.text, "stay attached")
        try expectEqual(model.allPaneIds.filter { $0 == source }.count, 1, "moved pane must not be duplicated")

        // splitRight -> horizontal split with target on the left, source on the right.
        guard case .split(_, .horizontal, .leaf(let left), .leaf(let right), _) = selectedTab(in: model)!.rootNode else {
            throw TestFailure(message: "tab should be a horizontal split of two leaves")
        }
        try expectEqual(left.id, target, "target keeps the left position")
        try expectEqual(right.id, source, "moved pane lands at the new right position")
    }

    // surfaceCreationFailed for a pane in a SPLIT tab removes the whole tab,
    // drops every sibling pane from pane()/allPaneIds, prunes id-keyed side
    // tables, and (stage-1 form) still emits a .destroySurface per sibling.
    test("surfaceCreationFailed in a split tab removes the tab and cleans up siblings") {
        var model = makeModel()
        createTab(&model)
        let failingTabId = selectedTab(in: model)!.id
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let paneB = selectedTab(in: model)!.focusedPaneId
        createTab(&model)  // a second tab so removing the failing one doesn't terminate

        // Seed id-keyed side tables for both panes.
        model.searchState[paneA] = SearchModel(needle: "x")
        model.searchState[paneB] = SearchModel(needle: "y")
        model.lastNotificationTime[paneA] = [.bell: Date()]
        model.lastNotificationTime[paneB] = [.bell: Date()]

        let effects = update(&model, .surfaceCreationFailed(paneId: paneA))

        // Whole tab removed: both panes gone.
        try expect(model.pane(paneA) == nil, "failed pane should be gone")
        try expect(model.pane(paneB) == nil, "sibling pane should be gone")
        try expect(!model.allPaneIds.contains(paneA))
        try expect(!model.allPaneIds.contains(paneB))
        try expect(tabById(failingTabId, in: model) == nil, "failing tab should be removed")

        // id-keyed side tables pruned for every sibling.
        try expect(model.searchState[paneA] == nil, "searchState should be pruned for paneA")
        try expect(model.searchState[paneB] == nil, "searchState should be pruned for paneB")
        try expect(model.lastNotificationTime[paneA] == nil, "lastNotificationTime should be pruned for paneA")
        try expect(model.lastNotificationTime[paneB] == nil, "lastNotificationTime should be pruned for paneB")

        // Stage-1 form: still emits a .destroySurface per sibling pane.
        let destroyed: Set<PaneId> = Set(effects.compactMap {
            if case .destroySurface(let pid) = $0 { return pid }
            return nil
        })
        try expectEqual(destroyed, Set([paneA, paneB]), "should destroy every sibling surface")
    }

    // An unknown pane (owned by no tree -- impossible to orphan now) is a safe
    // no-op: no effects and the model is unchanged.
    test("surfaceCreationFailed for an unknown pane is a no-op") {
        var model = makeModel()
        createTab(&model)
        let before = model

        let effects = update(&model, .surfaceCreationFailed(paneId: PaneId()))

        try expect(effects.isEmpty, "unknown pane should emit no effects")
        try expectEqual(model, before, "model should be unchanged")
    }
}
