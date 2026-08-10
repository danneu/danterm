// Golden-master coverage for DanTermCore's deterministic CoreEnv seam. The test
// drives a fixed message sequence through top-level update(), recursive update()
// calls, IPC dispatch, navigation, and alert-clock paths, then snapshots the
// entire AppModel via the same custom-dump style used elsewhere in the suite.
import Foundation
import Testing
import SnapshotTesting
import SnapshotTestingCustomDump
import DanTermProtocol

@testable import DanTermCore

@Suite struct GoldenMasterTests {
    @Test("deterministic env produces deterministic AppModel across update paths")
    func deterministicEnvProducesDeterministicAppModelAcrossUpdatePaths() {
        // Intent: a fixed Msg sequence under a deterministic CoreEnv produces
        //   the same full AppModel every run.
        // Why it exists: pins the env seam across top-level mints, recursive
        //   update() forwarding, IPC forwarding, navigateToPane, and alert
        //   createdAt/notification throttle clock reads.
        // Scenario: spec-first deterministic replay across splitPane,
        //   createGroup -> createTab recursion, IPC pane.split, IPC
        //   pane.focus -> navigateToPane, and inactive-app sessionBell.
        let ids = (0..<64).map { i in
            UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", i))")!
        }
        let env = makeTestEnv(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            idSequence: ids
        )

        var model = makeModel(env: env)

        _ = update(&model, .createTab(inGroupId: nil), env: env)
        let firstPane = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPane, direction: .horizontal), env: env)

        _ = update(&model, .createGroup(name: "Golden"), env: env)

        let secondGroupPane = model.groups[1].tabs[0].focusedPaneId
        _ = update(&model, .ipcRequest(
            reqId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            method: Methods.paneSplit,
            params: .object(["direction": .string("vertical")]),
            context: IpcRequestContext(paneId: secondGroupPane.rawValue.uuidString)
        ), env: env)

        _ = update(&model, .ipcRequest(
            reqId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            method: Methods.paneFocus,
            params: .object(["paneId": .string(firstPane.rawValue.uuidString)]),
            context: IpcRequestContext(paneId: nil)
        ), env: env)

        _ = update(&model, .appResignedActive, env: env)
        _ = update(&model, .sessionBell(paneId: firstPane), env: env)

        assertSnapshot(of: model, as: .customDump)
    }
}
