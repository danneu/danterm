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
