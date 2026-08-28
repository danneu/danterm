// Runtime coverage for notice reconciliation and deferred launch-recovery answers.
import Foundation
import Testing

@testable import DanTerm

@MainActor
struct AppRuntimeNoticeTests {
    @Test("Restore builds no pane before assent and commits recovered panes after the answer")
    func restoreAnswerBuildsAfterAssent() async throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        let restore = try validatedRestore(makeCommandSnapshot(paneId: paneId))

        runtime.requestRestorePrompt(restore, message: "1 tab, 1 pane.")

        #expect(fixture.sessionRequests.isEmpty)
        #expect(runtime.paneHosts.isEmpty)
        let id = try #require(runtime.model.noticeQueue.first?.id)
        runtime.send(.noticeAnswered(id: id, answer: .restore))
        await Task.yield()

        #expect(fixture.sessionRequests.count == 1)
        #expect(runtime.paneHosts.keys.contains(paneId))
    }

    @Test("Start Fresh discards recovery data and creates only a fresh tab")
    func startFreshBuildsNoRecoveredPane() async throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let recoveredPaneId = PaneId(rawValue: UUID())
        let restore = try validatedRestore(makeCommandSnapshot(paneId: recoveredPaneId))

        runtime.requestRestorePrompt(restore, message: "1 tab, 1 pane.")
        let id = try #require(runtime.model.noticeQueue.first?.id)
        runtime.send(.noticeAnswered(id: id, answer: .startFresh))
        await Task.yield()

        #expect(fixture.sessionRequests.count == 1)
        #expect(runtime.paneHosts.keys.contains(recoveredPaneId) == false)
        #expect(runtime.model.allPaneIds.count == 1)
    }

    @Test("failed recovered session build falls back to a fresh tab")
    func failedRestoreFallsBackToFresh() async throws {
        let fixture = RecordingAppRuntimePorts()
        fixture.failedSessionRequestNumbers = [1]
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let recoveredPaneId = PaneId(rawValue: UUID())
        let restore = try validatedRestore(makeCommandSnapshot(paneId: recoveredPaneId))

        runtime.requestRestorePrompt(restore, message: "1 tab, 1 pane.")
        let id = try #require(runtime.model.noticeQueue.first?.id)
        runtime.send(.noticeAnswered(id: id, answer: .restore))
        await Task.yield()

        #expect(fixture.sessionRequests.count == 2)
        #expect(runtime.paneHosts.keys.contains(recoveredPaneId) == false)
        #expect(runtime.model.allPaneIds.count == 1)
    }

    @Test("a notice queued before restore remains projected after commit")
    func queuedNoticeSurvivesRestore() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        runtime.send(.noticeReported(.message(title: "Queued", message: "Keep me")))
        let notice = try #require(desiredNotice(in: runtime.model))

        runtime.bootstrapFromTestSnapshot(
            makeCommandSnapshot(paneId: PaneId(rawValue: UUID()))
        )

        #expect(runtime.model.noticeQueue.first?.id == notice.id)
        #expect(desiredNotice(in: runtime.model) == notice)
    }
}

private func validatedRestore(_ snapshot: AppModelSnapshot) throws -> ValidatedAppRestore {
    let built = try #require(validateAndBuildDetailed(snapshot))
    return ValidatedAppRestore(
        model: built.model,
        paneSnapshots: built.paneSnapshots
    )
}
