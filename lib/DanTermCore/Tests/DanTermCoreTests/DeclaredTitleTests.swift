// Behavioral proofs for the split between a program's declared title and the
// display fallbacks DanTerm resolves around it: the cwd a pane shows when no
// program has spoken, and the recovered label a restored pane carries until its
// own session declares something.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct DeclaredTitleTests {
    /// One tab, one pane, with the given reports already applied. Every test
    /// here starts from a real `update` sequence rather than a hand-built
    /// model, so the reducer path under test is the one the app runs.
    private func makeOnePaneModel(
        reports: [SessionReport] = []
    ) -> (model: AppModel, paneId: PaneId, tabId: TabId) {
        var model = makeModel()
        _ = createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.paneTree.focusedPaneId
        let id = sessionId(for: paneId, in: model)
        for report in reports {
            _ = update(&model, .sessionReport(sessionId: id, report: report))
        }
        return (model, paneId, tab.id)
    }

    // MARK: - PO2: no declared title reads as the abbreviated cwd

    @Test("a pane that declared nothing shows its abbreviated cwd")
    func undeclaredPaneShowsAbbreviatedCwd() throws {
        // Intent: the cwd fallback is resolved at display, not stored as a title.
        // Why it exists: the whole plan removes the manufactured cwd title, and
        //   an idle pane must keep reading exactly as it did before.
        // Scenario: a shell reports its cwd and never declares a title.
        let home = NSHomeDirectory()
        let (model, paneId, tabId) = makeOnePaneModel(reports: [.cwd(home + "/Code/danterm")])
        let tab = try #require(tabById(tabId, in: model))
        let pane = try #require(model.pane(paneId))

        #expect(paneResolvedTitle(pane) == "~/Code/danterm")
        #expect(tabTitle(tab) == "~/Code/danterm")
        #expect(tabDisplayTitle(tab) == "~/Code/danterm")
        // The pane toolbar shows the cwd once, not beside a title repeating it.
        #expect(desiredPaneToolbar(in: model)[paneId]?.label.text == "~/Code/danterm")
    }

    @Test("a pane with neither a title nor a cwd falls back to Terminal")
    func undeclaredPaneWithoutCwd() throws {
        let (model, paneId, tabId) = makeOnePaneModel()
        let tab = try #require(tabById(tabId, in: model))
        let pane = try #require(model.pane(paneId))

        #expect(paneResolvedTitle(pane) == "Terminal")
        #expect(tabTitle(tab) == "Terminal")
    }

    @Test("a declared title outranks the cwd")
    func declaredTitleOutranksCwd() throws {
        let home = NSHomeDirectory()
        let (model, paneId, _) = makeOnePaneModel(
            reports: [.cwd(home + "/Code/danterm"), .title("vim")]
        )
        let pane = try #require(model.pane(paneId))

        #expect(pane.session?.titleState.declared == "vim")
        #expect(paneResolvedTitle(pane) == "vim")
        #expect(desiredPaneToolbar(in: model)[paneId]?.label.text == "vim \u{2013} ~/Code/danterm")
    }

    // MARK: - PO3: the recovered label

    /// Restores a one-pane model whose checkpoint carried `title`, then hands
    /// back the live pane so a test can drive reports into it.
    private func restoreOnePane(
        checkpointTitle: String?,
        cwd: String? = nil
    ) throws -> (model: AppModel, paneId: PaneId, tabId: TabId) {
        var source = makeModel()
        _ = createTab(&source)
        let paneId = source.groups[0].tabs[0].paneTree.focusedPaneId
        source.updatePane(paneId) { pane in
            pane.session?.titleState = SessionTitleState(declared: checkpointTitle)
            pane.session?.cwd = cwd
        }
        let snapshot = toSnapshot(source, home: NSHomeDirectory())
        let restored = try #require(validateAndBuild(snapshot))
        return (restored, paneId, restored.groups[0].tabs[0].id)
    }

    @Test("a restored pane shows its predecessor's title until its own session declares one")
    func inheritedLabelSurvivesTheFirstPromptClear() throws {
        // Intent: the checkpointed title is shown as a recovered label, survives
        //   the empty clear a fresh shell sends at its first prompt, is replaced
        //   by a real declaration, and never returns after that.
        // Why it exists: the reported bug -- every recovered tab read as its cwd
        //   within a second of restore, losing the only way to tell the tabs apart.
        // Scenario: a crash recovery whose checkpoint carried "claude --resume".
        let home = NSHomeDirectory()
        let restored = try restoreOnePane(
            checkpointTitle: "claude --resume",
            cwd: home + "/Code/danterm"
        )
        var model = restored.model
        let (paneId, tabId) = (restored.paneId, restored.tabId)
        let id = sessionId(for: paneId, in: model)

        #expect(model.pane(paneId)?.session?.titleState == .inherited("claude --resume"))
        #expect(paneResolvedTitle(try #require(model.pane(paneId))) == "claude --resume")
        #expect(tabTitle(try #require(tabById(tabId, in: model))) == "claude --resume")

        // The replacement shell's first prompt clears the title.
        _ = update(&model, .sessionReport(sessionId: id, report: .title("")))
        #expect(paneResolvedTitle(try #require(model.pane(paneId))) == "claude --resume")

        // A real declaration takes over, and the label is gone for good.
        _ = update(&model, .sessionReport(sessionId: id, report: .title("sleep 3")))
        #expect(paneResolvedTitle(try #require(model.pane(paneId))) == "sleep 3")

        _ = update(&model, .sessionReport(sessionId: id, report: .title("")))
        #expect(paneResolvedTitle(try #require(model.pane(paneId))) == "~/Code/danterm")
    }

    // MARK: - PO4: what a checkpoint stores

    @Test("a checkpoint stores the declared title, else the recovered label, else nothing")
    func checkpointStoresOneTitleSlot() throws {
        // Intent: a tab's identity survives repeated crashes, because the second
        //   checkpoint writes the recovered label the first one restored.
        // Why it exists: without it a second crash before any program declares a
        //   title would drop the name for good.
        // Scenario: restore a checkpointed title, checkpoint again untouched.
        let declared = makeOnePaneModel(reports: [.title("vim")]).model
        #expect(allPaneSnapshots(toSnapshot(declared, home: NSHomeDirectory()))[0].title == "vim")

        let (recovered, _, _) = try restoreOnePane(checkpointTitle: "vim")
        #expect(allPaneSnapshots(toSnapshot(recovered, home: NSHomeDirectory()))[0].title == "vim")

        let bare = makeOnePaneModel(reports: [.cwd("/tmp")]).model
        #expect(allPaneSnapshots(toSnapshot(bare, home: NSHomeDirectory()))[0].title == nil)
    }

    // MARK: - PO5: the replacement session inherits nothing

    @Test("a replacement session declares no title and ignores its predecessor's reports")
    func replacementSessionInheritsNoTitle() throws {
        // Intent: the checkpointed title never enters the replacement session, so
        //   a late report addressed to the dead session cannot rename the pane.
        // Why it exists: D3 of the session-owned-facts design -- a delayed report
        //   from a dead session cannot rename the replacement.
        // Scenario: restore, then replay a title report under the old session id.
        var source = makeModel()
        _ = createTab(&source)
        let paneId = source.groups[0].tabs[0].paneTree.focusedPaneId
        let deadSessionId = sessionId(for: paneId, in: source)
        source.updatePane(paneId) { $0.session?.titleState = .declared("claude --resume") }

        var model = try #require(validateAndBuild(toSnapshot(source, home: NSHomeDirectory())))
        let livePane = try #require(model.pane(paneId))
        #expect(livePane.session?.titleState == .inherited("claude --resume"))
        #expect(livePane.session?.id != deadSessionId)

        _ = update(&model, .sessionReport(sessionId: deadSessionId, report: .title("stale")))
        #expect(paneResolvedTitle(try #require(model.pane(paneId))) == "claude --resume")
    }

    // MARK: - PO6: IPC reports the declared title only

    @Test("IPC reports null for a pane with no declared title")
    func ipcReportsNullTitle() throws {
        // Intent: `ls` and `pane info` speak only for programs -- an inherited
        //   label is DanTerm's memo, not a claim, so it reports as null too.
        // Why it exists: the display and the checkpoint read the same slot, and
        //   a single reading rule would have leaked the label onto the wire.
        let home = NSHomeDirectory()
        let (undeclared, _, _) = makeOnePaneModel(reports: [.cwd(home + "/Code/danterm")])
        #expect(ipcPaneTitleField(undeclared) == .null)

        let (declared, _, _) = makeOnePaneModel(reports: [.title("vim")])
        #expect(ipcPaneTitleField(declared) == .string("vim"))

        let (inherited, _, _) = try restoreOnePane(checkpointTitle: "claude --resume")
        #expect(ipcPaneTitleField(inherited) == .null)
    }

    // MARK: - PO7: the checkpoint and the display read the same slot

    @Test("a pane checkpoints exactly the name it displays")
    func checkpointedTitleMatchesTheDisplayedOne() throws {
        // Intent: the string a checkpoint stores and the string a pane calls
        //   itself are one value, for a declared title and an inherited label
        //   alike.
        // Why it exists: the two used to be separate `declared ?? inherited`
        //   expressions in two files, free to drift apart with nothing to catch
        //   it. One reading rule makes them equal by construction; this pins it.
        for model in [
            makeOnePaneModel(reports: [.title("vim")]).model,
            try restoreOnePane(checkpointTitle: "claude --resume").model,
        ] {
            let pane = try #require(model.allPaneIds.first.flatMap { model.pane($0) })
            let stored = allPaneSnapshots(toSnapshot(model, home: NSHomeDirectory()))[0].title
            #expect(stored == paneClaimedTitle(pane))
            #expect(stored == paneResolvedTitle(pane))
        }
    }

    /// Reads the `title` field the `ls` encoder writes for the model's only pane.
    private func ipcPaneTitleField(_ model: AppModel) -> JSONValue? {
        let encoded = IpcEntityEncoder(home: NSHomeDirectory()).list(model)
        return encoded["groups"]?.asArray?.first?["tabs"]?.asArray?
            .first?["rootNode"]?["pane"]?["title"]
    }
}
