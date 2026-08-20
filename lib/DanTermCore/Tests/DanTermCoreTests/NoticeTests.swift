// Behavioral coverage for the model-owned FIFO notice queue and its projection.
import Foundation
import Testing

@testable import DanTermCore

struct NoticeTests {
    @Test("an error notice projects its copy and one dismiss action")
    func errorNoticeProjection() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let env = makeTestEnv(idSequence: [id])
        var model = makeModel()

        let commands = update(
            &model,
            .noticeReported(.message(title: "Import Failed", message: "The file is invalid.")),
            env: env
        )

        #expect(commands.isEmpty)
        let projection = try #require(desiredNotice(in: model))
        #expect(projection.id == NoticeId(rawValue: id))
        #expect(projection.title == "Import Failed")
        #expect(projection.message == "The file is invalid.")
        #expect(projection.primary == NoticeChoice(title: "OK", answer: .dismiss))
        #expect(projection.secondary == nil)
    }

    @Test("a recovery notice projects Restore and Start Fresh")
    func restoreNoticeProjection() throws {
        let id = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let env = makeTestEnv(idSequence: [id])
        var model = makeModel()

        _ = update(
            &model,
            .noticeReported(.restorePrompt(
                message: "DanTerm did not exit cleanly last time.\n2 tabs, 3 panes."
            )),
            env: env
        )

        let projection = try #require(desiredNotice(in: model))
        #expect(projection.title == "Restore Previous Session?")
        #expect(projection.message == "DanTerm did not exit cleanly last time.\n2 tabs, 3 panes.")
        #expect(projection.primary == NoticeChoice(title: "Restore", answer: .restore))
        #expect(projection.secondary == NoticeChoice(title: "Start Fresh", answer: .startFresh))
    }

    @Test("notices remain FIFO and a queued recovery prompt still resolves launch")
    func fifoAndRecoveryAnswer() throws {
        let firstId = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let restoreId = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let env = makeTestEnv(idSequence: [firstId, restoreId])
        var model = makeModel()
        _ = update(
            &model,
            .noticeReported(.message(title: "Config Error", message: "Could not load config.")),
            env: env
        )
        _ = update(
            &model,
            .noticeReported(.restorePrompt(message: "2 tabs, 3 panes.")),
            env: env
        )

        #expect(desiredNotice(in: model)?.id == NoticeId(rawValue: firstId))
        #expect(update(
            &model,
            .noticeAnswered(id: NoticeId(rawValue: restoreId), answer: .restore),
            env: env
        ).isEmpty, "an answer for a queued notice must not skip the visible notice")
        #expect(desiredNotice(in: model)?.id == NoticeId(rawValue: firstId))

        #expect(update(
            &model,
            .noticeAnswered(id: NoticeId(rawValue: firstId), answer: .dismiss),
            env: env
        ).isEmpty)
        #expect(desiredNotice(in: model)?.id == NoticeId(rawValue: restoreId))

        let commands = update(
            &model,
            .noticeAnswered(id: NoticeId(rawValue: restoreId), answer: .restore),
            env: env
        )
        #expect(commands.count == 1)
        guard case .resolveLaunchRestore(restore: true) = commands[0] else {
            Issue.record("Restore must resolve the retained launch recovery")
            return
        }
        #expect(desiredNotice(in: model) == nil)
    }

    @Test("Start Fresh resolves launch without restoring")
    func startFreshAnswer() {
        let id = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        let env = makeTestEnv(idSequence: [id])
        var model = makeModel()
        _ = update(
            &model,
            .noticeReported(.restorePrompt(message: "1 tab, 1 pane.")),
            env: env
        )

        let commands = update(
            &model,
            .noticeAnswered(id: NoticeId(rawValue: id), answer: .startFresh),
            env: env
        )

        #expect(commands.count == 1)
        guard case .resolveLaunchRestore(restore: false) = commands[0] else {
            Issue.record("Start Fresh must resolve launch without recovery")
            return
        }
        #expect(model.noticeQueue.isEmpty)
    }
}
