// Behavioral tests for Phase 5's determinism seam (home, ids, time). They pin the
// inject-vs-ambient rule from `CoreEnv`/the new ADR at the exact boundaries that
// matter: the SAVED snapshot (toSnapshot abbreviates against the injected home),
// the restored model (loadValidatedInitFile expands `~/` against the injected home
// and mints ids from the injected sequence), the reducer itself (one message
// sequence replayed under two identically built envs yields equal models, and the
// ids and times it writes come from the injected env), and -- the load-bearing
// premise that keeps the seam narrow -- that `update()` stores the RAW
// shell-reported cwd/title in the model rather than abbreviating into it. Each test
// passes `home`/`env` explicitly; none reads the process HOME for its assertion
// (except model-stays-home-clean, which deliberately aligns the injected home WITH
// ambient -- see its preamble).
import Foundation
import CustomDump
import Testing

@testable import DanTermCore

@Suite struct DeterminismSeamTests {
    // A fixed, non-real home distinct from any plausible ambient home, so a test
    // that wrongly read the process HOME instead of the injected one would fail.
    private static let fakeHome = "/fake/home"

    // MARK: - restore-expand (the ASSERTED axis: ~/ -> injected home)

    @Test("resolveLaunch expands ~/ against the injected home, not the process HOME")
    func resolveLaunchExpandsTildeAgainstInjectedHome() {
        // Intent: resolveLaunch's tilde expansion uses the passed-in home.
        // Why it exists: pins the leaf of the restore home seam so a regression
        //   that reverts to bare NSHomeDirectory() fails loudly under a fake home.
        // Scenario: spec-first machine-independence check for the restore path.
        let ps = PaneSnapshot(id: nil, title: "T", cwd: "~/foo", command: nil, scrollback: nil, theme: nil)
        let (cwd, _) = resolveLaunch(ps, home: Self.fakeHome)
        #expect(cwd == Self.fakeHome + "/foo")
    }

    @Test("loadValidatedInitFile expands a saved ~/ against the env's home end-to-end")
    func restoreExpandsTildeThroughEnvHome() throws {
        // Intent: the env's homeDirectory threads loadValidatedInitFile ->
        //   validateAndBuildDetailed -> parseSplitNode -> resolveLaunch ->
        //   expandTilde, so a saved `~/foo` restores to <injectedHome>/foo.
        // Why it exists: pins the WHOLE restore chain to the injected home, not
        //   just the resolveLaunch leaf -- a missed thread anywhere in the chain
        //   would fall back to ambient and this asserts against a fake home.
        // Scenario: spec-first machine-independent restore -- an init file with a
        //   `~/foo` cwd loaded under home=/fake/home yields /fake/home/foo.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{ "rootNode": { "type": "leaf", "pane": { "title": "T", "cwd": "~/foo" } } }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        // id-less group + tab + leaf + session mint 4 ids; the values are irrelevant here.
        let env = makeTestEnv(idSequence: Self.idSequence, homeDirectory: Self.fakeHome)
        let loaded = try loadValidatedInitFile(from: data, env: env)
        let paneId = loaded.model.allPaneIds[0]
        #expect(loaded.model.pane(paneId)?.session?.cwd == Self.fakeHome + "/foo")
    }

    // MARK: - snapshot-abbreviate (the SAVED axis: injected home -> ~/)

    @Test("toSnapshot abbreviates a home-prefixed cwd against the injected home")
    func snapshotAbbreviatesAgainstInjectedHome() {
        // Intent: toSnapshot collapses a cwd under the injected home to `~/...`.
        // Why it exists: pins the save side of the home seam so the recorded
        //   snapshot payload is machine-independent -- abbreviation keys off the
        //   passed home, never the process HOME.
        // Scenario: spec-first save-path check -- a pane cwd /fake/home/foo
        //   snapshotted under home=/fake/home serializes as ~/foo.
        let paneId = PaneId()
        let tabId = TabId()
        var model = makeModel()
        model.groups[0].tabs.append(
            TabModel(id: tabId, paneTree: PaneTree(root: .leaf(PaneModel(
                    id: paneId,
                    session: SessionModel(id: SessionId(), titleState: .declared("T"), cwd: Self.fakeHome + "/foo"),
                    theme: nil
                )), focusedPaneId: paneId)))
        model.selectedTabId = tabId

        let snapshot = toSnapshot(model, home: Self.fakeHome)
        #expect(paneSnapshot(paneId, in: snapshot)?.cwd == "~/foo")
    }

    // MARK: - id-less-restore (reproducible minting from an injected sequence)

    @Test("id-less restore mints group/tab/pane/session ids from the injected sequence in order")
    func idLessRestoreMintsFromInjectedSequence() throws {
        // Intent: id-less snapshot entries mint ids via env.newId(), in
        //   group -> tab -> pane -> session order, so restore is reproducible.
        // Why it exists: pins the restore id seam (the 4 bare XxxId() mints became
        //   env.newId()); a deterministic sequence must produce matching ids.
        // Scenario: spec-first reproducibility -- an id-less group/tab/leaf loaded
        //   with [g, t, p, s] yields exactly those ids on the group, tab, pane,
        //   and nested session.
        let g = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let t = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let p = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let s = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{ "rootNode": { "type": "leaf", "pane": { "title": "T" } } }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let env = makeTestEnv(idSequence: [g, t, p, s], homeDirectory: Self.fakeHome)
        let loaded = try loadValidatedInitFile(from: data, env: env)

        #expect(loaded.model.groups[0].id.rawValue == g, "group id minted from sequence[0]")
        #expect(loaded.model.groups[0].tabs[0].id.rawValue == t, "tab id minted from sequence[1]")
        #expect(loaded.model.allPaneIds == [PaneId(rawValue: p)], "pane id minted from sequence[2]")
        #expect(loaded.model.allPanes[0].session?.id == SessionId(rawValue: s), "session id minted from sequence[3]")
    }

    // MARK: - replay determinism (the model is a pure function of (messages, env))

    private static let replayNow = Date(timeIntervalSince1970: 1_700_000_000)

    // The reqIds the driver puts on its IPC messages. These are caller-supplied,
    // NOT env-minted: the reducer parks the split's reqId in
    // pendingSessionCreations, so it is deliberately outside the id assertion.
    private static let splitReqId = UUID(uuidString: "11111111-1111-4111-8111-000000000001")!
    private static let focusReqId = UUID(uuidString: "11111111-1111-4111-8111-000000000002")!

    // 64 fixed ids under one prefix, with headroom over what the driver consumes.
    // Two sequences from different prefixes share no value, so an id-axis
    // comparison cannot pass on an incidental collision.
    private static func replayIds(prefix: String) -> [UUID] {
        (0..<64).map {
            UUID(uuidString: "\(prefix)-0000-4000-8000-\(String(format: "%012x", $0))")!
        }
    }

    /// Drives the message sequence every replay test shares. It covers top-level
    /// mints, recursive `update()` forwarding (createGroup -> createTab), IPC
    /// dispatch, `navigateToPane`, and both alert clock sites, and it forwards
    /// `env` on every `update()` call -- the `TestSupport` helpers do not, so
    /// routing through them would silently drop the seam under test.
    ///
    /// Takes the base model by value so callers can replay one env-free base
    /// twice. Starting from `makeModel(env:)` instead would mint the seed group id
    /// from the sequence, and two runs would then differ for a reason outside the
    /// reducer.
    private static func replay(_ base: AppModel, env: CoreEnv) -> AppModel {
        var model = base
        _ = update(&model, .createTabInSelectedGroup(), env: env)
        let firstPane = model.groups[0].tabs[0].paneTree.focusedPaneId
        _ = update(&model, .splitPane(paneId: firstPane, direction: .horizontal), env: env)

        _ = update(&model, .createGroup(name: "Replay"), env: env)
        let secondGroupPane = model.groups[1].tabs[0].paneTree.focusedPaneId

        // The raw request message, not UpdateIpcTests' private `sendIpc` helper:
        // that helper auto-fires sessionProcessStarted for every createSession
        // command, which would retire pendingSessionCreations before the
        // comparison sees it mid-flight.
        _ = update(&model, .ipcRequest(
            reqId: splitReqId,
            caller: .local,
            request: .paneSplit(
                target: .pane(secondGroupPane, direction: .vertical),
                launch: nil,
                background: false
            )
        ), env: env)

        _ = update(&model, .ipcRequest(
            reqId: focusReqId,
            caller: .local,
            request: .paneFocus(pane: firstPane)
        ), env: env)

        // Inactive, so the focused pane still follows the normal alert path.
        _ = update(&model, .appResignedActive, env: env)
        _ = update(&model, .sessionBell(sessionId: sessionId(for: firstPane, in: model)), env: env)
        _ = update(&model, .sessionNotification(
            sessionId: sessionId(for: firstPane, in: model),
            title: "Done",
            body: "Task finished"
        ), env: env)
        return model
    }

    @Test("one message sequence replayed under two identically built envs yields equal models")
    func replayUnderIdenticalEnvsYieldsEqualModels() {
        // Intent: the whole AppModel is a pure function of (messages, env).
        // Why it exists: this is the total guard against an ambient UUID() or
        //   Date() read anywhere in the reducer. AppModel's Equatable is
        //   compiler-synthesized, so it covers every field -- including fields
        //   added long after this test -- with nothing recorded to bless.
        // Scenario: spec-first. Two runs of one sequence, each against its own
        //   freshly built but identically parameterized env, from one shared
        //   env-free base model.
        let base = makeModel()
        let first = Self.replay(base, env: makeTestEnv(
            now: Self.replayNow, idSequence: Self.replayIds(prefix: "5eed0001")))
        let second = Self.replay(base, env: makeTestEnv(
            now: Self.replayNow, idSequence: Self.replayIds(prefix: "5eed0001")))

        expectNoDifference(first, second)
    }

    @Test("varying only the injected id sequence changes the replayed model")
    func replayDependsOnTheInjectedIdSequence() {
        // Intent: the id axis of the env still reaches the model.
        // Why it exists: keeps the replay-equality test from going vacuous. If a
        //   later refactor stopped threading env.newId() through these handlers,
        //   equality would pass for the wrong reason and only this test would fail.
        // Scenario: spec-first. Two runs differing in id sequence alone -- the
        //   clock is held constant, so the two axes cannot mask each other.
        let base = makeModel()
        let a = Self.replay(base, env: makeTestEnv(
            now: Self.replayNow, idSequence: Self.replayIds(prefix: "5eed0001")))
        let b = Self.replay(base, env: makeTestEnv(
            now: Self.replayNow, idSequence: Self.replayIds(prefix: "5eed0002")))

        // The Bool is computed first on purpose: `#expect(a != b)` captures both
        // operands and dumps two whole AppModels into the failure message.
        let differs = a != b
        #expect(differs, "a different injected id sequence must produce a different model")
    }

    @Test("varying only the injected clock changes the replayed model")
    func replayDependsOnTheInjectedClock() {
        // Intent: the clock axis of the env still reaches the model.
        // Why it exists: the id axis alone would keep replay-equality honest about
        //   ids while the clock quietly went ambient. Varying the clock on its own
        //   is what makes the two axes independent.
        // Scenario: spec-first. Two runs differing in `now` alone; the id sequence
        //   is identical.
        let base = makeModel()
        let ids = Self.replayIds(prefix: "5eed0001")
        let a = Self.replay(base, env: makeTestEnv(now: Self.replayNow, idSequence: ids))
        let b = Self.replay(
            base, env: makeTestEnv(now: Self.replayNow.addingTimeInterval(3600), idSequence: ids))

        let differs = a != b
        #expect(differs, "a different injected clock must produce a different model")
    }

    /// The ids the replay's actions minted, grouped by entity kind, so the
    /// provenance test can assert membership per kind without pinning mint order
    /// or mint count -- neither of which is observable behavior.
    private struct MintedIds {
        var groups: [UUID] = []
        var tabs: [UUID] = []
        var panes: [UUID] = []
        var sessions: [UUID] = []
        var splits: [UUID] = []
        var alerts: [UUID] = []

        var byKind: [(kind: String, ids: [UUID])] {
            [("group", groups), ("tab", tabs), ("pane", panes),
             ("session", sessions), ("split", splits), ("alert", alerts)]
        }
    }

    private static func collectMints(_ node: SplitNodeModel, into minted: inout MintedIds) {
        switch node {
        case .leaf(let pane):
            minted.panes.append(pane.id.rawValue)
            if let session = pane.session { minted.sessions.append(session.id.rawValue) }
        case .split(let id, _, let first, let second, _):
            minted.splits.append(id.rawValue)
            collectMints(first, into: &minted)
            collectMints(second, into: &minted)
        }
    }

    @Test("the entities the replay creates draw their ids from the injected sequence")
    func replayMintsCreatedEntityIdsFromInjectedSequence() {
        // Intent: pane, session, split, tab, group, and alert ids created during
        //   the replay are values of the injected id sequence.
        // Why it exists: replay-equality proves the model is a function of the env;
        //   it does not prove the values came from the INJECTED env rather than
        //   some other deterministic source. This settles provenance.
        // Scenario: spec-first. Membership only -- which of pane, session, and
        //   split is minted first is not observable (all three are opaque UUIDs),
        //   so reordering the mints must keep this passing while a bare UUID()
        //   must fail it.
        let base = makeModel()
        let ids = Self.replayIds(prefix: "5eed0001")
        let model = Self.replay(base, env: makeTestEnv(now: Self.replayNow, idSequence: ids))
        let injected = Set(ids)

        // The base model's seed group is minted env-free on purpose (the
        // sensitivity tests need an env-free base), so it is not a created entity.
        let seedGroupIds = Set(base.groups.map(\.id.rawValue))
        var minted = MintedIds()
        for group in model.groups {
            if !seedGroupIds.contains(group.id.rawValue) { minted.groups.append(group.id.rawValue) }
            for tab in group.tabs {
                minted.tabs.append(tab.id.rawValue)
                Self.collectMints(tab.paneTree.root, into: &minted)
            }
        }
        minted.alerts = model.alerts.map(\.id.rawValue)

        for (kind, kindIds) in minted.byKind {
            #expect(!kindIds.isEmpty, "the replay must create at least one \(kind)")
            #expect(
                kindIds.allSatisfy(injected.contains),
                "every created \(kind) id must come from the injected sequence"
            )
        }
    }

    @Test("both alert sources write the injected now into createdAt and lastNotificationTime")
    func alertClockSitesWriteTheInjectedNow() throws {
        // Intent: the bell and desktop-notification sources write the shared
        //   pane-alert path's injected instant into the alert's createdAt and
        //   into the pane's live throttle state.
        // Why it exists: no other test in the suite asserts a createdAt against an
        //   injected clock, and the retired golden reached only the bell site.
        // Scenario: spec-first. One replay under a frozen clock raises a bell alert
        //   and a desktop-notification alert on the same pane.
        let base = makeModel()
        let model = Self.replay(base, env: makeTestEnv(
            now: Self.replayNow, idSequence: Self.replayIds(prefix: "5eed0001")))

        for kind in [AlertKind.bell, .desktopNotification] {
            let alert = try #require(
                model.alerts.first { $0.kind == kind }, "the replay must raise a \(kind) alert")
            #expect(alert.createdAt == Self.replayNow, "\(kind) createdAt from the injected clock")
            #expect(
                model.pane(alert.paneId)?.live.lastNotificationTime[kind] == Self.replayNow,
                "\(kind) lastNotificationTime from the injected clock"
            )
        }
    }

    // MARK: - model-stays-home-clean (the premise that justifies the narrow seam)

    @Test("update() stores the raw cwd/title in the model, never abbreviating into it")
    func modelStaysHomeCleanUnderAmbientHome() {
        // Intent: cwd and title reports write the shell-reported path verbatim
        //   into the model; HOME never enters AppModel, only its saved/sent output.
        // Why it exists: this is the load-bearing premise of the WHOLE narrow home
        //   seam -- because the model is home-clean, only save/send/restore needed
        //   threading, and the replay tests above (which assert on the model) stay
        //   home-independent. If a handler ever abbreviated into the model the seam
        //   would be unsound.
        // Scenario: spec-first model-purity check. The env's home is bound to the
        //   REAL ambient home and the input cwd/title placed UNDER it, so ANY
        //   abbreviation-into-the-model -- via the injected env.homeDirectory() OR
        //   via a leaf-default abbreviateHome(cwd) reading ambient NSHomeDirectory()
        //   -- would collapse the stored value to ~/sentinel. Aligning all three
        //   homes is deliberate (do NOT swap in a fake home: a fake home unequal to
        //   ambient lets a leaf-default leak slip through undetected). The assertion
        //   stays machine-independent in form -- it compares against whatever `h` is
        //   at runtime.
        let h = NSHomeDirectory()
        let env = makeTestEnv(homeDirectory: h)
        let paneId = PaneId()
        let tabId = TabId()
        var model = makeModel()
        model.groups[0].tabs.append(
            TabModel(id: tabId, paneTree: PaneTree(root: .leaf(PaneModel(id: paneId, session: SessionModel(id: SessionId()))), focusedPaneId: paneId)))
        model.selectedTabId = tabId

        _ = update(&model, .sessionReport(sessionId: sessionId(for: paneId, in: model), report: .cwd(h + "/sentinel")), env: env)
        _ = update(&model, .sessionReport(sessionId: sessionId(for: paneId, in: model), report: .title(h + "/sentinel")), env: env)

        #expect(model.pane(paneId)?.session?.cwd == h + "/sentinel", "cwd stored raw, not abbreviated into the model")
        #expect(model.pane(paneId)?.session?.titleState.declared == h + "/sentinel", "title stored raw, not abbreviated into the model")
    }

    // MARK: - path-helper boundary (travels with the boundary-aware abbreviateHome / expandTilde fixes)

    @Test("abbreviateHome is boundary-aware: a sibling-home prefix is left intact")
    func abbreviateHomeBoundaryAware() {
        // Intent: abbreviateHome only collapses `home` itself or a path under
        //   `home + "/"`, not an arbitrary string-prefix match.
        // Why it exists: guards a later "simplification" back to the bare
        //   hasPrefix(home) from reintroducing the ~ielle/foo display glitch.
        // Scenario: spec-first boundary check.
        #expect(abbreviateHome("/Users/dan/foo", home: "/Users/dan") == "~/foo")
        #expect(abbreviateHome("/Users/dan", home: "/Users/dan") == "~")
        #expect(abbreviateHome("/Users/danielle/foo", home: "/Users/dan") == "/Users/danielle/foo")
    }

    @Test("expandTilde is boundary-aware: a ~user prefix is left intact")
    func expandTildeBoundaryAware() {
        // Intent: expandTilde only expands a bare "~" or a "~/"-rooted path;
        //   a "~user/..." form is left intact (DanTerm does not resolve other
        //   users' homes).
        // Why it exists: guards a later "simplification" back to the bare
        //   hasPrefix("~") from reintroducing the /Users/dandanielle/foo
        //   concat-corruption -- the inverse twin of the abbreviateHome
        //   boundary bug pinned just above.
        // Scenario: spec-first boundary check.
        #expect(expandTilde("~/foo", home: "/Users/dan") == "/Users/dan/foo")
        #expect(expandTilde("~", home: "/Users/dan") == "/Users/dan")
        #expect(expandTilde("~danielle/foo", home: "/Users/dan") == "~danielle/foo")
    }

    // Five distinct fixed ids -- enough to cover an id-less group/tab/leaf/session (4 mints)
    // with headroom, for tests that do not assert on the minted values.
    private static let idSequence: [UUID] = (1...5).map {
        UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-00000000000\($0)")!
    }
}
