// Headless proof that the four dialog passes present only through the surfaces
// the runtime was given, and that a runtime given recording surfaces reaches no
// window at all.
import Cocoa
import Testing

@testable import DanTerm

@MainActor
struct AppRuntimeDialogSurfaceTests {
    /// The window classes the reconcile sweep used to conjure for itself. None of
    /// them may exist in a process that only ever built recording surfaces.
    private static func dialogWindowsOnScreen() -> [NSWindow] {
        NSApplication.shared.windows.filter {
            $0 is NoticePanel || $0 is ConfirmationPanel
                || $0 is PreferencesPanel || $0 is SwitcherPanel
        }
    }

    @Test("a runtime given recording surfaces presents every dialog and builds no window")
    func headlessRuntimeBuildsNoDialogWindow() throws {
        // Intent: driving a notice, a confirmation, and a preferences open through
        //   a runtime with no presentation surface leaves nothing on screen.
        // Why it exists: `just test` used to leave a config-error panel and three
        //   restore prompts sitting on the developer's desktop, because the three
        //   self-creating passes built their own panels on every send().
        // Scenario: the reported defect, driven headlessly.
        let surfaces = RecordingDialogSurfaces()
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts(), dialogSurfaces: surfaces)
        defer { runtime.shutdown() }

        runtime.send(.noticeReported(.message(title: "Import Failed", message: "Invalid file.")))
        runtime.send(.requestQuit)
        runtime.send(.preferencesOpened())

        #expect(surfaces.notice.applied.count == 1)
        #expect(surfaces.confirmation.applied.count == 1)
        #expect(surfaces.preferences.applied.count == 1)
        #expect(Self.dialogWindowsOnScreen().isEmpty)
    }

    @Test("the first message a runtime receives presents through its surfaces")
    func firstMessagePresentsThroughSurfaces() throws {
        // Intent: a surface is in place before the runtime can be sent anything,
        //   so the very first message's projection is applied rather than dropped.
        // Why it exists: a pass that applied to a surface that had not arrived yet
        //   would still advance its cache, leaving the model claiming a dialog
        //   nobody can see and no later sweep able to notice.
        // Scenario: a config error reported before anything else happens.
        let surfaces = RecordingDialogSurfaces()
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts(), dialogSurfaces: surfaces)
        defer { runtime.shutdown() }

        #expect(surfaces.notice.bindCount == 1, "bound during init, before any message")

        runtime.send(.noticeReported(.message(title: "Bad Config", message: "Line 3.")))

        let cached = try #require(runtime.caches.notice)
        #expect(surfaces.notice.applied == [cached], "the cache advanced only with a matching apply")
    }

    @Test("a failed session-lock claim reaches the user as a notice")
    func sessionLockClaimFailurePresentsANotice() throws {
        // Intent: a launch whose lock claim failed says so through the notice surface,
        //   and the runtime keeps working afterwards.
        // Why it exists: the write used to swallow every error, so a lock that was never
        //   created disabled crash detection for the whole run with no signal at all.
        // Scenario: a launch whose recovery directory could not be created, reported once
        //   the window exists.
        let surfaces = RecordingDialogSurfaces()
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts(), dialogSurfaces: surfaces)
        defer { runtime.shutdown() }

        runtime.reportSessionLockClaimFailure(POSIXError(.EACCES))

        let notice = try #require(surfaces.notice.applied.last)
        #expect(surfaces.notice.applied.count == 1)
        #expect(notice.title.text == "Crash Detection Unavailable")

        runtime.send(.noticeAnswered(id: notice.id, answer: .dismiss))
        runtime.send(.createTabInSelectedGroup())

        #expect(runtime.caches.notice == nil)
        #expect(runtime.model.groups[0].tabs.count == 1, "the runtime is still usable")
    }

    @Test("answering a notice hides it and clears the cache")
    func answeringNoticeHidesIt() throws {
        // Intent: a dialog is on screen exactly when its projection is non-nil.
        // Why it exists: the hide transition is the only thing that takes a panel
        //   off screen, so a retract that skipped it would strand a dialog.
        // Scenario: spec-first report-then-answer.
        let surfaces = RecordingDialogSurfaces()
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts(), dialogSurfaces: surfaces)
        defer { runtime.shutdown() }

        runtime.send(.noticeReported(.message(title: "Import Failed", message: "Invalid file.")))
        let projection = try #require(runtime.caches.notice)
        #expect(surfaces.notice.events == [.apply(projection), .raise])

        runtime.send(.noticeAnswered(id: projection.id, answer: .dismiss))

        #expect(runtime.caches.notice == nil)
        #expect(surfaces.notice.hideCount == 1)
    }

    @Test("shutting a runtime down retracts a dialog that is still up")
    func shutdownRetractsOpenDialog() throws {
        // Intent: a released runtime cannot leave a panel on screen.
        // Why it exists: the surfaces reach the runtime weakly, so a dialog left
        //   up after shutdown would answer into nothing.
        // Scenario: spec-first shutdown with an unanswered notice.
        let surfaces = RecordingDialogSurfaces()
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts(), dialogSurfaces: surfaces)

        runtime.send(.noticeReported(.message(title: "Import Failed", message: "Invalid file.")))
        #expect(surfaces.notice.hideCount == 0)

        runtime.shutdown()

        #expect(surfaces.notice.hideCount == 1)
    }

    @Test("a restore commit discards the dialog that answered it")
    func restoreCommitDiscardsOpenDialog() async throws {
        // Intent: session teardown discards a dialog before the caches reset, so
        //   nil still means "already hidden" for the first post-restore sweep.
        // Why it exists: a surviving panel plus a cleared cache would leave the
        //   restore prompt on screen with nothing able to retract it.
        // Scenario: the launch restore prompt, answered Restore.
        let surfaces = RecordingDialogSurfaces()
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts(), dialogSurfaces: surfaces)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        let built = try #require(validateAndBuildDetailed(makeCommandSnapshot(paneId: paneId)))
        let restore = ValidatedAppRestore(
            model: built.model,
            paneSnapshots: built.paneSnapshots
        )

        runtime.requestRestorePrompt(restore, message: "1 tab, 1 pane.")
        let id = try #require(runtime.model.noticeQueue.first?.id)
        runtime.send(.noticeAnswered(id: id, answer: .restore))
        await Task.yield()

        #expect(surfaces.notice.discardCount == 1)
        #expect(runtime.caches.notice == nil)
    }

    @Test("refreshing a visible dialog applies again and raises no second time")
    func refreshDoesNotReRaise() throws {
        // Intent: a projection change while a dialog is open must not pull key
        //   focus off the terminal pane underneath it.
        // Why it exists: the notice panel refreshes when the FIFO head changes and
        //   the confirmation panel refreshes as its rollup follows the model.
        // Scenario: a second queued notice taking the head, and a re-requested quit.
        let surfaces = RecordingDialogSurfaces()
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts(), dialogSurfaces: surfaces)
        defer { runtime.shutdown() }

        runtime.send(.noticeReported(.message(title: "First", message: "One.")))
        runtime.send(.noticeReported(.message(title: "Second", message: "Two.")))
        let head = try #require(runtime.caches.notice)
        runtime.send(.noticeAnswered(id: head.id, answer: .dismiss))

        #expect(surfaces.notice.applied.map(\.title.text) == ["First", "Second"])
        #expect(surfaces.notice.raiseCount == 1, "the second notice took over an open panel")
        #expect(surfaces.notice.hideCount == 0)

        runtime.send(.requestQuit)
        runtime.send(.requestQuit)

        #expect(surfaces.confirmation.applied.count == 2)
        #expect(surfaces.confirmation.raiseCount == 1)
    }

    @Test("reopening preferences raises the panel even when the projection is unchanged")
    func reopeningPreferencesRaisesAgain() throws {
        // Intent: asking for preferences twice brings the panel forward twice.
        // Why it exists: the second open produces the same projection, so the
        //   dialog pass has nothing to do and the raise has to come from the open
        //   itself.
        // Scenario: spec-first double open.
        let surfaces = RecordingDialogSurfaces()
        let runtime = makeCommandTestRuntime(RecordingAppRuntimePorts(), dialogSurfaces: surfaces)
        defer { runtime.shutdown() }

        runtime.showPreferencesPanel()
        let first = try #require(runtime.caches.preferencesPanel)
        let afterFirstOpen = surfaces.preferences.raiseCount
        runtime.showPreferencesPanel()

        #expect(afterFirstOpen > 0, "the first open raised the panel")
        #expect(runtime.caches.preferencesPanel == first, "the second open changed nothing")
        #expect(surfaces.preferences.raiseCount > afterFirstOpen,
                "the second open raised again despite an unchanged projection")
    }

    @Test("every MRU cycle step re-applies the overlay and none of them raises it")
    func mruCycleReAppliesWithoutRaising() throws {
        // Intent: the switcher re-renders on every step and never takes key focus.
        // Why it exists: key focus would pull first responder out of the focused
        //   pane, and the row count sets the overlay height, so every step has to
        //   re-apply.
        // Scenario: two steps of a cycle over three tabs, then Escape.
        let surfaces = RecordingDialogSurfaces()
        var model = AppModel(groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")])
        for _ in 0..<3 {
            _ = update(&model, .createTabInSelectedGroup())
        }
        let runtime = makeCommandTestRuntime(
            RecordingAppRuntimePorts(),
            dialogSurfaces: surfaces,
            initialModel: model
        )
        defer { runtime.shutdown() }

        runtime.send(.mruCycleStepped(direction: .older))
        runtime.send(.mruCycleStepped(direction: .older))
        runtime.send(.mruCycleCanceled)

        #expect(surfaces.switcher.applied.map(\.cursorIndex) == [1, 2])
        #expect(surfaces.switcher.raiseCount == 0, "the overlay pass has no raise to call")
        #expect(surfaces.switcher.hideCount == 1)
    }
}
