// Behavioral proofs for pane-nested terminal sessions and their identity lookup.
import Foundation
import Testing

@testable import DanTermCore

/// Proves that the pane tree is the only owner and lookup path for live sessions.
struct SessionStoreTests {
    @Test("create and split mint distinct sessions owned by their panes")
    func createAndSplitMintDistinctOwnedSessions() throws {
        let ids = (0..<7).map { index in
            UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012x", index))")!
        }
        let env = makeTestEnv(idSequence: ids)
        var model = makeModel(env: env)

        _ = update(&model, .createTabInSelectedGroup(), env: env)
        let firstPane = try #require(model.allPanes.first)
        let firstSession = try #require(firstPane.session)

        _ = update(
            &model,
            .splitPane(paneId: firstPane.id, direction: .horizontal),
            env: env
        )
        let sessions = model.allPanes.compactMap(\.session)

        #expect(sessions.count == 2)
        #expect(Set(sessions.map(\.id)).count == 2)
        #expect(model.pane(owning: firstSession.id)?.id == firstPane.id)
        for pane in model.allPanes {
            let session = try #require(pane.session)
            #expect(model.pane(owning: session.id)?.id == pane.id)
        }
    }

    @Test("session mutation follows identity to the owning pane")
    func sessionMutationFollowsIdentityToOwningPane() throws {
        let ids = (0..<7).map { index in
            UUID(uuidString: "10000000-0000-4000-8000-\(String(format: "%012x", index))")!
        }
        let env = makeTestEnv(idSequence: ids)
        var model = makeModel(env: env)

        _ = update(&model, .createTabInSelectedGroup(), env: env)
        let pane = try #require(model.allPanes.first)
        let sessionId = try #require(pane.session?.id)
        let replacementId = SessionId(rawValue: UUID(uuidString: "20000000-0000-4000-8000-000000000000")!)
        var mutationCount = 0

        model.updateSession(sessionId) { session in
            mutationCount += 1
            session = SessionModel(id: replacementId)
        }

        #expect(mutationCount == 1)
        #expect(model.pane(owning: sessionId) == nil)
        #expect(model.pane(owning: replacementId)?.id == pane.id)
    }

    @Test("removing a pane structurally removes its session")
    func removingPaneStructurallyRemovesSession() throws {
        let ids = (0..<7).map { index in
            UUID(uuidString: "30000000-0000-4000-8000-\(String(format: "%012x", index))")!
        }
        let env = makeTestEnv(idSequence: ids)
        var model = makeModel(env: env)

        _ = update(&model, .createTabInSelectedGroup(), env: env)
        let firstPaneId = try #require(model.allPanes.first?.id)
        _ = update(
            &model,
            .splitPane(paneId: firstPaneId, direction: .horizontal),
            env: env
        )
        let removedPane = try #require(model.allPanes.last)
        let removedSessionId = try #require(removedPane.session?.id)

        _ = update(&model, .closePane(paneId: removedPane.id), env: env)

        #expect(model.pane(removedPane.id) == nil)
        #expect(model.pane(owning: removedSessionId) == nil)
        #expect(model.allPanes.count == 1)
    }

    @Test("allPaneIds preserves group tab and leaf order")
    func allPaneIdsPreservesModelOrder() {
        // Intent: allPaneIds returns panes in group order, tab order, and
        //   left-to-right leaf order within each split tree.
        // Why it exists: callers depend on stable display order, but the prior
        //   tests constrained only one tab at a time.
        // Scenario: two groups each contain two tabs, including nested split
        //   trees whose leaf order differs from their tree depth.
        let paneIds = (0..<7).map { _ in PaneId() }
        let firstRoot = SplitNodeModel.split(
            id: SplitId(),
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneIds[0])),
            second: .split(
                id: SplitId(),
                direction: .vertical,
                first: .leaf(PaneModel(id: paneIds[1])),
                second: .leaf(PaneModel(id: paneIds[2])),
                ratio: 0.4
            ),
            ratio: 0.6
        )
        let secondRoot = SplitNodeModel.split(
            id: SplitId(),
            direction: .vertical,
            first: .split(
                id: SplitId(),
                direction: .horizontal,
                first: .leaf(PaneModel(id: paneIds[4])),
                second: .leaf(PaneModel(id: paneIds[5])),
                ratio: 0.5
            ),
            second: .leaf(PaneModel(id: paneIds[6])),
            ratio: 0.7
        )
        let firstGroup = GroupModel(id: GroupId(), name: "First", tabs: [
            TabModel(id: TabId(), paneTree: PaneTree(root: firstRoot, focusedPaneId: paneIds[0])),
            TabModel(id: TabId(), paneTree: PaneTree(root: .leaf(PaneModel(id: paneIds[3])), focusedPaneId: paneIds[3])),
        ])
        let secondGroup = GroupModel(id: GroupId(), name: "Second", tabs: [
            TabModel(id: TabId(), paneTree: PaneTree(root: secondRoot, focusedPaneId: paneIds[4])),
        ])
        let model = AppModel(groups: [firstGroup, secondGroup])

        #expect(model.allPaneIds == paneIds)
    }

    @Test("restore mints and nests a fresh session for every leaf")
    func restoreMintsAndNestsFreshSessionForEveryLeaf() throws {
        let groupId = UUID(uuidString: "40000000-0000-4000-8000-000000000000")!
        let tabId = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
        let splitId = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
        let firstPaneId = UUID(uuidString: "40000000-0000-4000-8000-000000000003")!
        let firstSessionId = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
        let secondPaneId = UUID(uuidString: "40000000-0000-4000-8000-000000000005")!
        let secondSessionId = UUID(uuidString: "40000000-0000-4000-8000-000000000006")!
        let env = makeTestEnv(idSequence: [
            groupId,
            tabId,
            splitId,
            firstPaneId,
            firstSessionId,
            secondPaneId,
            secondSessionId,
        ])
        let firstPane = PaneSnapshot(
            id: nil,
            title: "Restored A",
            cwd: nil,
            command: nil,
            scrollback: nil,
            theme: nil
        )
        let secondPane = PaneSnapshot(
            id: nil,
            title: "Restored B",
            cwd: nil,
            command: nil,
            scrollback: nil,
            theme: nil
        )
        let snapshot = AppModelSnapshot(
            groups: [
                GroupSnapshot(
                    id: nil,
                    name: "General",
                    isCollapsed: nil,
                    tabs: [
                        TabSnapshot(
                            id: nil,
                            customTitle: nil,
                            focusedPaneId: nil,
                            rootNode: .split(
                                id: nil,
                                direction: "horizontal",
                                first: .leaf(firstPane),
                                second: .leaf(secondPane),
                                ratio: nil
                            ),
                            color: nil
                        ),
                    ]
                ),
            ],
            selectedTabId: nil
        )

        let model = try #require(validateAndBuild(snapshot, env: env))
        let sessions = model.allPanes.compactMap(\.session)

        #expect(model.allPaneIds == [PaneId(rawValue: firstPaneId), PaneId(rawValue: secondPaneId)])
        #expect(sessions.map(\.id) == [
            SessionId(rawValue: firstSessionId),
            SessionId(rawValue: secondSessionId),
        ])
        #expect(Set(sessions.map(\.id)).count == model.allPanes.count)
        #expect(model.pane(owning: SessionId(rawValue: firstSessionId))?.id == PaneId(rawValue: firstPaneId))
        #expect(model.pane(owning: SessionId(rawValue: secondSessionId))?.id == PaneId(rawValue: secondPaneId))
    }
}
