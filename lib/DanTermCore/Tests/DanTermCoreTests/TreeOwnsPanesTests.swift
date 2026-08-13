// Swift Testing migration of the legacy `tests/TreeOwnsPanesTests.swift`
// harness suite. Pins the structural guarantees of the tree-owns-panes model
// restructure: pane content lives in the leaf, lookups go through
// `model.pane(_:)` / `allPaneIds`, and the move/split/swap helpers thread the
// FULL `PaneModel` payload (not a fresh default rebuilt from a bare id). The
// payload-threading tests below are the net for the "Tree-helper carry-through"
// risk. Large-value equality checks use `expectNoDifference` so a regression
// surfaces a field-level diff instead of a wall of opaque struct dump.
import Foundation
import CustomDump
import Testing

@testable import DanTermCore

@Suite struct TreeOwnsPanesTests {
    @Test("v3 snapshot decodes embedded panes into leaf-owned panes and re-encodes identically")
    func v3SnapshotDecodesEmbeddedPanesAndReencodesIdentically() throws {
        // Intent: a v3 snapshot (panes nested in tree leaves) decodes into
        //   leaf-owned panes -- each reachable via model.pane(id) with its
        //   title/cwd/theme/todos -- and re-encodes back to an identical model.
        // Why it exists: pins the embedded native round-trip the format
        //   restructure rests on; a regression that re-introduced a separate
        //   top-level panes dict would silently desync from the tree.
        // Scenario: spec-first on-disk contract -- the user's persisted init
        //   file (v3 format) must round-trip without losing pane state.
        let paneAId = "A13076E4-A29C-4358-A771-B4B4DF84C6C5"
        let paneBId = "B2222222-0000-4000-8000-000000000002"
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "\(paneAId)",
                "rootNode": {
                  "type": "split", "direction": "horizontal",
                  "first": { "type": "leaf", "pane": {
                    "id": "\(paneAId)", "title": "Editor", "cwd": "/work", "theme": "Dracula",
                    "todos": [{ "id": "C3333333-0000-4000-8000-000000000003", "text": "ship it", "isDone": false }] } },
                  "second": { "type": "leaf", "pane": { "id": "\(paneBId)", "title": "Shell" } }
                }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = try #require(validateAndBuild(initFile.model), "v3 snapshot should validate")
        let a = PaneId(rawValue: UUID(uuidString: paneAId)!)
        let b = PaneId(rawValue: UUID(uuidString: paneBId)!)

        // Each pane reachable via model.pane(id) with the decoded content.
        #expect(model.pane(a)?.session?.title == "Editor")
        #expect(model.pane(a)?.session?.cwd == "/work")
        #expect(model.pane(a)?.theme == "Dracula")
        #expect(model.pane(a)?.todos.count == 1)
        #expect(model.pane(a)?.todos.first?.text == "ship it")
        #expect(model.pane(b)?.session?.title == "Shell")

        // allPaneIds == the tab tree's leaves (no separate dict).
        #expect(Set(model.allPaneIds) == Set([a, b]))
        #expect(Set(model.allPaneIds) == Set(allPaneIds(model.groups[0].tabs[0].paneTree.root)))

        // Re-encode and rebuild: persisted pane data round-trips identically while
        // restore deliberately mints fresh, unpersisted session identities.
        let snapshot = toSnapshot(model)
        let rebuilt = try #require(validateAndBuild(snapshot))
        expectNoDifference(toSnapshot(rebuilt), snapshot)
    }

    @Test("updatePane mutates only the target leaf, leaving structure and siblings intact")
    func updatePaneMutatesOnlyTargetLeaf() {
        // Intent: updatePane mutates only the target leaf; sibling panes and
        //   the surrounding split ids/directions/ratios are byte-identical
        //   afterward.
        // Why it exists: pins the surgical-mutation contract so a refactor of
        //   the tree-walk path cannot accidentally rebuild siblings or wipe
        //   structural metadata around them.
        // Scenario: spec-first surgical-mutation check -- the user renames pane
        //   B in a 3-pane (A | (B,C)) layout; A, C, and the splits stay frozen.
        let a = PaneId(), b = PaneId(), c = PaneId()
        let s1 = SplitId(), s2 = SplitId()
        let paneA = PaneModel(id: a, session: SessionModel(id: SessionId(), title: "A"))
        let paneB = PaneModel(id: b, session: SessionModel(id: SessionId(), title: "B"))
        let paneC = PaneModel(id: c, session: SessionModel(id: SessionId(), title: "C"))
        let root = SplitNodeModel.split(
            id: s1, direction: .horizontal,
            first: .leaf(paneA),
            second: .split(id: s2, direction: .vertical, first: .leaf(paneB), second: .leaf(paneC), ratio: 0.3),
            ratio: 0.7
        )
        var model = makeModel()
        model.groups[0].tabs.append(TabModel(id: TabId(), paneTree: PaneTree(root: root, focusedPaneId: a)))

        model.updatePane(b) { $0.session?.title = "B-changed" }

        // B changed; A and C untouched (full payload equality).
        #expect(model.pane(b)?.session?.title == "B-changed")
        expectNoDifference(model.pane(a), paneA)
        expectNoDifference(model.pane(c), paneC)
        #expect(model.allPaneIds == [a, b, c])

        // Split ids/directions/ratios identical.
        guard case .split(let rid, .horizontal, _, let rsecond, let rratio) = model.groups[0].tabs[0].paneTree.root else {
            Issue.record("root should still be a horizontal split")
            return
        }
        #expect(rid == s1)
        #expect(rratio == 0.7)
        guard case .split(let r2id, .vertical, _, _, let r2ratio) = rsecond else {
            Issue.record("inner should still be a vertical split")
            return
        }
        #expect(r2id == s2)
        #expect(r2ratio == 0.3)
    }

    @Test("closePane removes the pane and allPaneIds tracks the surviving leaves")
    func closePaneRemovesAndAllPaneIdsTracksLeaves() {
        // Intent: after closePane the closed pane is gone from model.pane(_:)
        //   and allPaneIds exactly tracks the surviving tree leaves.
        // Why it exists: pins the structural drift invariant -- closing a pane
        //   used to risk a separate id-list desyncing from the actual tree,
        //   and this asserts the new shape can't drift.
        // Scenario: spec-first close check -- after split+close, the survivor
        //   remains and the closed pane is gone from every projection.
        var model = makeModel()
        createTab(&model)
        let original = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let added = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(added != original, "split should add a pane")

        update(&model, .closePane(paneId: added))

        #expect(model.pane(added) == nil, "closed pane should not be reachable")
        #expect(!model.allPaneIds.contains(added), "closed pane should be gone from allPaneIds")
        #expect(model.allPaneIds.contains(original), "surviving pane should remain")
        // Structural: allPaneIds equals the union of every tab tree's leaves.
        let leaves = model.groups.flatMap { $0.tabs.flatMap { allPaneIds($0.paneTree.root) } }
        #expect(Set(model.allPaneIds) == Set(leaves))
    }

    @Test("movePaneToTab carries the pane's payload to the target leaf")
    func movePaneToTabCarriesPayload() {
        // Intent: movePaneToTab physically carries the moved pane's
        //   distinctive payload into the target tab's tree; the source tree no
        //   longer holds it and the pane is not duplicated.
        // Why it exists: pins the cross-tab move's payload-preservation -- a
        //   regression that rebuilt a fresh default leaf from the bare id
        //   would silently drop cwd/theme/todos.
        // Scenario: spec-first cross-tab move -- the user drags a pane with a
        //   "carry me" todo into another tab; that todo must appear there.
        var model = makeModel()
        createTab(&model)
        let sourceTabId = selectedTab(in: model)!.id
        let movable = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))  // keep source tab alive after the move

        model.updatePane(movable) {
            $0.session?.title = "Movable"
            $0.todos = [TodoItem(id: UUID(), text: "carry me", isDone: false)]
        }

        createTab(&model)
        let targetTabId = selectedTab(in: model)!.id

        update(&model, .movePaneToTab(paneId: movable, targetTabId: targetTabId))

        // Payload preserved on the moved pane.
        #expect(model.pane(movable)?.session?.title == "Movable")
        #expect(model.pane(movable)?.todos.count == 1)
        #expect(model.pane(movable)?.todos.first?.text == "carry me")
        // Lands in the target tree, leaves the source tree, appears exactly once.
        #expect(allPaneIds(tabById(targetTabId, in: model)!.paneTree.root).contains(movable), "moved pane should be in target tab")
        #expect(!allPaneIds(tabById(sourceTabId, in: model)!.paneTree.root).contains(movable), "moved pane should leave source tab")
        #expect(model.allPaneIds.filter { $0 == movable }.count == 1, "moved pane must not be duplicated")
    }

    @Test("swapLeaves swaps full payloads between positions")
    func swapLeavesSwapsFullPayloads() {
        // Intent: swapLeaves swaps WHOLE PaneModel payloads -- each pane's
        //   full content lands at the other's tree position.
        // Why it exists: pins the swap's payload-completeness so a regression
        //   that only swapped ids (leaving stale title/cwd/theme behind) is
        //   caught.
        // Scenario: spec-first swap check -- two distinct panes (A with /a +
        //   Dracula, B with /b + Nord) swap and each ends up with the other's
        //   full payload at the other's tree slot.
        let a = PaneId(), b = PaneId()
        let paneA = PaneModel(
            id: a,
            session: SessionModel(id: SessionId(), title: "A", cwd: "/a"),
            theme: "Dracula"
        )
        let paneB = PaneModel(
            id: b,
            session: SessionModel(id: SessionId(), title: "B", cwd: "/b"),
            theme: "Nord"
        )
        let node = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(paneA), second: .leaf(paneB), ratio: 0.5
        )

        guard let result = swapLeaves(node, a, b) else {
            Issue.record("swap should succeed")
            return
        }
        guard case .split(_, _, .leaf(let first), .leaf(let second), _) = result else {
            Issue.record("result should be a split of two leaves")
            return
        }
        // First position now holds B's full payload; second holds A's.
        expectNoDifference(first, paneB)
        expectNoDifference(second, paneA)
    }

    @Test("movePane(.splitRight) threads the moved pane's payload through insertAtLeaf")
    func movePaneSplitRightThreadsPayloadThroughInsertAtLeaf() {
        // Intent: moving a pane via .splitRight preserves the moved pane's
        //   full payload (cwd, theme, todos) at its new split position.
        // Why it exists: locks down the moveLeaf -> insertAtLeaf path -- the
        //   only route through insertAtLeaf -- against silently dropping pane
        //   state when a refactor rebuilt a fresh default leaf from the id.
        // Scenario: regression -- earlier code rebuilt a default leaf from the
        //   bare pane id, so a split-right drag wiped its cwd/theme/todos;
        //   this is the test pinned against that fix.
        var model = makeModel()
        createTab(&model)
        let target = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .vertical))
        let source = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(source != target, "split should create a distinct source pane")

        model.updatePane(source) {
            $0.session?.cwd = "/src"
            $0.theme = "Dracula"
            $0.todos = [TodoItem(id: UUID(), text: "stay attached", isDone: false)]
        }

        update(&model, .movePane(source: source, target: target, intent: .splitRight))

        // Payload preserved on the moved pane.
        #expect(model.pane(source)?.session?.cwd == "/src")
        #expect(model.pane(source)?.theme == "Dracula")
        #expect(model.pane(source)?.todos.count == 1)
        #expect(model.pane(source)?.todos.first?.text == "stay attached")
        #expect(model.allPaneIds.filter { $0 == source }.count == 1, "moved pane must not be duplicated")

        // splitRight -> horizontal split with target on the left, source on the right.
        guard case .split(_, .horizontal, .leaf(let left), .leaf(let right), _) = selectedTab(in: model)!.paneTree.root else {
            Issue.record("tab should be a horizontal split of two leaves")
            return
        }
        #expect(left.id == target, "target keeps the left position")
        #expect(right.id == source, "moved pane lands at the new right position")
    }

    @Test("sessionCreationFailed in a split tab removes the tab and cleans up siblings")
    func sessionCreationFailedInSplitRemovesTabAndCleansSiblings() {
        // Intent: sessionCreationFailed for a pane in a SPLIT tab removes the
        //   whole tab, drops every sibling pane from pane()/allPaneIds, and
        //   prunes id-keyed side tables; reconcileSessionExistence's pure
        //   teardown set selects exactly the sibling panes that vanished.
        // Why it exists: Stage 8 moved session teardown into the reconciler,
        //   so this asserts the structural model change PLUS the pure
        //   teardown-selection diff (sessionsToTearDown) instead of the old
        //   per-sibling teardown command path.
        // Scenario: spec-first failure-cascade check -- pane A in a 2-pane
        //   tab fails to create its session; both A and B vanish, a second
        //   tab survives, and the teardown set names exactly {A, B}.
        var model = makeModel()
        createTab(&model)
        let failingTabId = selectedTab(in: model)!.id
        let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = selectedTab(in: model)!.paneTree.focusedPaneId
        createTab(&model)  // a second tab so removing the failing one doesn't terminate

        // Seed id-keyed side tables for both panes.
        model.searchState[paneA] = SearchModel(needle: "x")
        model.searchState[paneB] = SearchModel(needle: "y")
        model.lastNotificationTime[paneA] = [.bell: Date()]
        model.lastNotificationTime[paneB] = [.bell: Date()]

        // Sessions live before the failure = every pane currently in the model.
        let liveSessionIds = Set(model.allPaneIds)
        #expect(liveSessionIds.isSuperset(of: [paneA, paneB]), "both split panes were live")

        let sessionId = model.pane(paneA)!.session!.id
        update(&model, .sessionCreationFailed(sessionId: sessionId))

        // Whole tab removed: both panes gone.
        #expect(model.pane(paneA) == nil, "failed pane should be gone")
        #expect(model.pane(paneB) == nil, "sibling pane should be gone")
        #expect(!model.allPaneIds.contains(paneA))
        #expect(!model.allPaneIds.contains(paneB))
        #expect(tabById(failingTabId, in: model) == nil, "failing tab should be removed")

        // id-keyed side tables pruned for every sibling.
        #expect(model.searchState[paneA] == nil, "searchState should be pruned for paneA")
        #expect(model.searchState[paneB] == nil, "searchState should be pruned for paneB")
        #expect(model.lastNotificationTime[paneA] == nil, "lastNotificationTime should be pruned for paneA")
        #expect(model.lastNotificationTime[paneB] == nil, "lastNotificationTime should be pruned for paneB")

        // reconcileSessionExistence tears down exactly the two siblings (now absent from
        // allPaneIds); the surviving second-tab pane is never selected.
        let teardown = sessionsToTearDown(liveSessionIds: liveSessionIds, model: model)
        #expect(teardown == Set([paneA, paneB]), "every sibling pane is selected for teardown")
        #expect(teardown.isDisjoint(with: Set(model.allPaneIds)), "surviving panes are never torn down")
    }

    @Test("sessionCreationFailed for an unknown pane is a no-op")
    func sessionCreationFailedForUnknownPaneIsNoop() {
        // Intent: sessionCreationFailed with an id owned by no tree (which is
        //   structurally impossible under tree-owns-panes, but still defended
        //   against) emits no commands and leaves structure-only state unchanged.
        // Why it exists: pins the safe-no-op guard for a stray async failure
        //   callback after the pane and its side tables were already cleaned up.
        // Scenario: spec-first defensive-noop -- a session-failed Msg arrives
        //   for an unknown pane id; the model and commands are byte-equal to
        //   before.
        var model = makeModel()
        createTab(&model)
        let before = model

        let commands = update(&model, .sessionCreationFailed(sessionId: SessionId()))

        #expect(commands.isEmpty, "unknown session should emit no commands")
        expectNoDifference(model, before)
    }

    // MARK: - Leaf-embedded v3 wire format

    @Test("toInitFile writes version 3")
    func toInitFileWritesVersion3() throws {
        // Intent: the written init file's top-level `version` field is 3.
        // Why it exists: pins the on-disk version contract independent of the
        //   snapshot Swift types -- a refactor that bumped the version
        //   silently would break older builds reading newer files.
        // Scenario: spec-first wire-format check -- inspecting the raw JSON
        //   bytes confirms the version stamp.
        var model = makeModel()
        createTab(&model)
        let data = try JSONEncoder().encode(toInitFile(model))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((obj?["version"] as? Int) == 3, "init file version should be 3")
    }

    @Test("toSnapshot JSON embeds panes in tree leaves with no top-level panes array")
    func toSnapshotJSONEmbedsPanesInLeaves() throws {
        // Intent: the ls/export JSON has the embedded shape -- no top-level
        //   `panes` array, and each tab's rootNode leaf carries its pane
        //   inline under `pane`.
        // Why it exists: pins the export wire shape independent of the Swift
        //   snapshot types, so an external consumer parsing the JSON sees
        //   the leaf-embedded contract.
        // Scenario: spec-first wire-format check -- inspect the raw export
        //   bytes for the absent top-level `panes` key and the inline
        //   `rootNode.pane` payload.
        var model = makeModel()
        createTab(&model)
        let data = try JSONEncoder().encode(toSnapshot(model))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["panes"] == nil, "top-level panes array should be gone")
        let groups = obj?["groups"] as? [[String: Any]]
        let tabs = groups?[0]["tabs"] as? [[String: Any]]
        let rootNode = tabs?[0]["rootNode"] as? [String: Any]
        #expect((rootNode?["type"] as? String) == "leaf")
        let pane = rootNode?["pane"] as? [String: Any]
        #expect(pane != nil, "leaf should embed a pane object")
        #expect(pane?["id"] != nil, "embedded pane should carry its id")
    }

    @Test("an id-less leaf decodes with a freshly-minted pane id and keeps its content")
    func idlessLeafDecodesWithMintedIdAndKeepsContent() throws {
        // Intent: a leaf with no `id` in the snapshot decodes with a freshly-
        //   minted pane id, and the leaf's content (title/cwd/theme) rides
        //   along onto the minted pane.
        // Why it exists: preserves the omitted-id hand-authoring affordance
        //   through the autoPaneIds deletion -- users can still write
        //   minimal id-less leaves in init files.
        // Scenario: spec-first affordance check -- a user authors an init
        //   file with an id-less leaf and expects the app to mint an id and
        //   honor the rest of the leaf.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{ "rootNode": { "type": "leaf", "pane": { "title": "Minty", "cwd": "/x", "theme": "Nord" } } }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = try #require(validateAndBuild(initFile.model), "id-less leaf should validate")
        #expect(model.allPaneIds.count == 1, "should mint exactly one pane")
        let minted = model.allPaneIds[0]
        #expect(model.pane(minted)?.session?.title == "Minty", "title survives the mint")
        #expect(model.pane(minted)?.session?.cwd == "/x")
        #expect(model.pane(minted)?.theme == "Nord")
        #expect(model.groups[0].tabs[0].paneTree.focusedPaneId == minted, "focus defaults to the minted leaf")
    }

    @Test("restore chrome derives from the focused leaf's pane cwd and ignores siblings")
    func restoreChromeDerivesFromFocusedLeafPaneCwd() throws {
        // Intent: tab chrome (title/subtitle) is recomputed at decode from
        //   the FOCUSED leaf's embedded PaneSnapshot cwd; a non-focused
        //   sibling's cwd must not leak into the chrome.
        // Why it exists: chrome is derived, not stored, so the encode/decode
        //   round-trip test cannot catch a mis-relocated read -- this test
        //   is its dedicated net.
        // Scenario: spec-first chrome derivation -- a split tab whose
        //   focused leaf must surface its cwd in the chrome, never the
        //   sibling's cwd.
        let focusedId = "F1111111-0000-4000-8000-000000000001"
        let siblingId = "55555555-0000-4000-8000-000000000002"
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "\(focusedId)",
                "rootNode": {
                  "type": "split", "direction": "horizontal",
                  "first": { "type": "leaf", "pane": { "id": "\(siblingId)", "title": "Sibling", "cwd": "~/sibling" } },
                  "second": { "type": "leaf", "pane": {
                    "id": "\(focusedId)", "title": "Editor",
                    "cwd": "~/focused-pane" } }
                }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = try #require(validateAndBuild(initFile.model), "split snapshot should validate")
        let tab = model.groups[0].tabs[0]

        // The focused pane's session cwd supplies the subtitle.
        #expect(tabTitle(tab) == "Editor")
        #expect(tabSubtitle(tab) == "~/focused-pane")
        // The sibling's cwd never bleeds into the tab chrome.
        #expect(tabSubtitle(tab) != "~/sibling", "sibling cwd must not leak into the tab subtitle")
    }

    @Test("graftScrollback embeds scrollback into the matching tree leaves only")
    func graftScrollbackEmbedsScrollbackIntoMatchingLeavesOnly() {
        // Intent: graftScrollback walks the embedded tree and sets each
        //   matching leaf's PaneSnapshot.scrollback from the map; leaves
        //   with no map entry stay nil.
        // Why it exists: pins the encode-side enrichment for export + the
        //   enriched checkpoint so a refactor of the tree-walk cannot stamp
        //   scrollback onto every leaf or miss a matching one.
        // Scenario: spec-first enrichment check -- a 2-pane tree with a
        //   scrollback map only for p1 produces a grafted snapshot where p1
        //   has scrollback and p2 still has nil.
        var model = makeModel()
        createTab(&model)
        let p1 = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let p2 = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(p1 != p2, "split should add a second pane")

        let snapshot = toSnapshot(model)
        #expect(allPaneSnapshots(snapshot).allSatisfy { $0.scrollback == nil }, "pure snapshot leaves start with nil scrollback")

        let grafted = graftScrollback(onto: snapshot, scrollbackByPaneId: [p1: "hello\nworld"])
        #expect(paneSnapshot(p1.rawValue.uuidString, in: grafted)?.scrollback == "hello\nworld", "matched leaf gets scrollback")
        #expect(paneSnapshot(p2.rawValue.uuidString, in: grafted)?.scrollback == nil, "unmatched leaf stays nil")
    }
}
