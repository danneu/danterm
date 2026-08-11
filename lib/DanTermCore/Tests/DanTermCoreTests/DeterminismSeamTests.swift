// Behavioral tests for Phase 5's determinism seam (home, ids, time). They pin the
// inject-vs-ambient rule from `CoreEnv`/the new ADR at the exact boundaries that
// matter: the SAVED snapshot (toSnapshot abbreviates against the injected home),
// the restored model (loadValidatedInitFile expands `~/` against the injected home
// and mints ids from the injected sequence), and -- the load-bearing premise that
// keeps the seam narrow -- that `update()` stores the RAW shell-reported cwd/title
// in the model rather than abbreviating into it. Each test passes `home`/`env`
// explicitly; none reads the process HOME for its assertion (except
// model-stays-home-clean, which deliberately aligns the injected home WITH ambient
// -- see its preamble).
import Foundation
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
            TabModel(id: tabId, focusedPaneId: paneId,
                rootNode: .leaf(PaneModel(
                    id: paneId,
                    session: SessionModel(id: SessionId(), title: "T", cwd: Self.fakeHome + "/foo"),
                    theme: nil
                ))))
        model.selectedTabId = tabId

        let snapshot = toSnapshot(model, home: Self.fakeHome)
        #expect(paneSnapshot(paneId.rawValue.uuidString, in: snapshot)?.cwd == "~/foo")
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

    // MARK: - model-stays-home-clean (the premise that justifies the narrow seam)

    @Test("update() stores the raw cwd/title in the model, never abbreviating into it")
    func modelStaysHomeCleanUnderAmbientHome() {
        // Intent: cwd and title reports write the shell-reported path verbatim
        //   into the model; HOME never enters AppModel, only its saved/sent output.
        // Why it exists: this is the load-bearing premise of the WHOLE narrow home
        //   seam -- because the model is home-clean, only save/send/restore needed
        //   threading, and GoldenMasterTests (asserting on the model) stays
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
            TabModel(
                id: tabId,
                focusedPaneId: paneId,
                rootNode: .leaf(PaneModel(id: paneId, session: SessionModel(id: SessionId())))
            ))
        model.selectedTabId = tabId

        _ = update(&model, .sessionReport(sessionId: sessionId(for: paneId, in: model), report: .cwd(h + "/sentinel")), env: env)
        _ = update(&model, .sessionReport(sessionId: sessionId(for: paneId, in: model), report: .title(h + "/sentinel")), env: env)

        #expect(model.pane(paneId)?.session?.cwd == h + "/sentinel", "cwd stored raw, not abbreviated into the model")
        #expect(model.pane(paneId)?.session?.title == h + "/sentinel", "title stored raw, not abbreviated into the model")
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
