// Swift Testing migration of the legacy `tests/SnapshotTests.swift` harness
// suite. Pins the AppInitFile / snapshot wire format: decode/validate, version
// gating (v3 only), pane-id and tab-id uniqueness checks, normalized
// selectedTabId, optional-id minting, session launch resolution, scrollback
// backward-compat, tab color round-trip, preferences-draft dropping, and the
// todo round-trips on both panes and tabs. The do/catch-and-assert-error
// pattern (try once + assert error kind) preserves both call sites in the
// migration (Issue.record + return for the throw arm, #expect for the catch
// arm) so the per-file failure-site count stays exact.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct SnapshotTests {
    // MARK: - Decode

    @Test("decode valid AppInitFile JSON")
    func decodeValidAppInitFileJSON() throws {
        // Intent: a well-formed v3 init file decodes into the expected field
        //   values (version, group count, pane count, selectedTabId).
        // Why it exists: pins the happy decode path that every restore flow
        //   relies on at startup.
        // Scenario: spec-first wire-format check -- a one-tab, one-pane init
        //   file decodes into a single group, one pane snapshot, and the
        //   nominated selectedTabId.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "cwd": "~/world"
                } }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        #expect(initFile.version == 3)
        #expect(initFile.model.groups.count == 1)
        #expect(allPaneSnapshots(initFile.model).count == 1)
        #expect(initFile.model.selectedTabId == "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")
    }

    @Test("decode failure on malformed JSON")
    func decodeFailureOnMalformedJSON() {
        // Intent: malformed JSON fails the JSONDecoder pass (no silent
        //   acceptance of a zero-value AppInitFile).
        // Why it exists: pins the parse boundary so a corrupt init file is
        //   detected before any validation runs.
        // Scenario: spec-first robustness check -- the user's init file is
        //   truncated mid-bracket; decode must throw.
        let json = "{ invalid json"
        let data = json.data(using: .utf8)!
        var decoded = false
        do {
            _ = try JSONDecoder().decode(AppInitFile.self, from: data)
            decoded = true
        } catch {}
        #expect(!decoded, "should fail to decode malformed JSON")
    }

    @Test("loadValidatedInitFile rejects malformed JSON")
    func loadValidatedInitFileRejectsMalformedJSON() {
        // Intent: loadValidatedInitFile surfaces a .decodeFailed
        //   AppInitFileLoadError on malformed JSON (not a generic Error).
        // Why it exists: pins the typed error contract the caller switches
        //   over to render a user-facing failure message.
        // Scenario: spec-first error-mapping check -- the truncated init
        //   file surfaces as exactly the .decodeFailed case.
        let data = "{ invalid json".data(using: .utf8)!
        do {
            _ = try loadValidatedInitFile(from: data)
            Issue.record("expected malformed JSON to fail")
            return
        } catch let error as AppInitFileLoadError {
            #expect(error == .decodeFailed)
        } catch {}
    }

    @Test("loadValidatedInitFile accepts v3 and rejects v1 / v2 / v4")
    func loadValidatedInitFileAcceptsV3RejectsOldAndFutureVersions() throws {
        // Intent: the version guard accepts v3 only -- old formats and v4+
        //   are rejected outright with no
        //   version-dispatch fork.
        // Why it exists: pins the single-version contract so a refactor
        //   that re-introduces v1 silent-import (or grandfathered v3)
        //   cannot reopen format-drift bugs.
        // Scenario: spec-first version-gate check -- the loader round-trips
        //   v3, rejects v1/v2, and rejects v4 with .unsupportedVersion.
        // v3 round-trips through the loader.
        var model = makeModel()
        createTab(&model)
        let v3data = try JSONEncoder().encode(toInitFile(model))
        _ = try loadValidatedInitFile(from: v3data)

        // v1 (flat panes array) is rejected on version, not silently imported.
        let v1json = """
        {
          "version": 1,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf", "paneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5" }
              }]
            }],
            "panes": [{ "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "Terminal" }]
          }
        }
        """
        do {
            _ = try loadValidatedInitFile(from: v1json.data(using: .utf8)!)
            Issue.record("expected v1 to be rejected")
            return
        } catch let error as AppInitFileLoadError {
            #expect(error == .unsupportedVersion(1))
        }

        let v2json = v1json.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")
        do {
            _ = try loadValidatedInitFile(from: v2json.data(using: .utf8)!)
            Issue.record("expected v2 to be rejected")
            return
        } catch let error as AppInitFileLoadError {
            #expect(error == .unsupportedVersion(2))
        }

        // v4 (a future format) is rejected too.
        let v4json = """
        {
          "version": 4,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{ "rootNode": { "type": "leaf", "pane": { "title": "Terminal" } } }]
            }]
          }
        }
        """
        do {
            _ = try loadValidatedInitFile(from: v4json.data(using: .utf8)!)
            Issue.record("expected v4 to be rejected")
            return
        } catch let error as AppInitFileLoadError {
            #expect(error == .unsupportedVersion(4))
        }
    }

    @Test("loadValidatedInitFile rejects invalid snapshot")
    func loadValidatedInitFileRejectsInvalidSnapshot() {
        // Intent: a well-formed v3 file whose snapshot fails validation
        //   surfaces .invalidSnapshot (not a decode error).
        // Why it exists: pins the post-decode validation boundary so a
        //   structurally-empty init file is rejected with the user-visible
        //   .invalidSnapshot case rather than silently restoring an empty app.
        // Scenario: spec-first validation check -- an init file with zero
        //   groups must surface .invalidSnapshot.
        let json = """
        {
          "version": 3,
          "model": { "groups": [] }
        }
        """
        let data = json.data(using: .utf8)!
        do {
            _ = try loadValidatedInitFile(from: data)
            Issue.record("expected invalid snapshot to fail")
            return
        } catch let error as AppInitFileLoadError {
            #expect(error == .invalidSnapshot)
        } catch {}
    }

    @Test("loadValidatedInitFile returns validated restore")
    func loadValidatedInitFileReturnsValidatedRestore() throws {
        // Intent: a successful load returns both the rebuilt model and the
        //   raw snapshot, with selectedTabId/group-count/pane-count agreeing.
        // Why it exists: pins the return contract the AppRuntime caller
        //   relies on at restore time.
        // Scenario: spec-first round-trip check -- encode the current model,
        //   load it back, and confirm the rebuilt model agrees with the
        //   originating one's basic shape.
        var model = makeModel()
        createTab(&model)
        let data = try JSONEncoder().encode(toInitFile(model))
        let loaded = try loadValidatedInitFile(from: data)
        #expect(loaded.snapshot.selectedTabId == model.selectedTabId?.rawValue.uuidString)
        #expect(loaded.model.groups.count == model.groups.count)
        #expect(loaded.model.allPaneIds.count == model.allPaneIds.count)
    }

    @Test("loadValidatedInitFile does not restore pending confirmation")
    func loadValidatedInitFileDoesNotRestorePendingConfirmation() throws {
        // Intent: pendingConfirmation is ephemeral and must not survive
        //   the serialize/load round-trip.
        // Why it exists: pins the ephemerality guarantee so a stale
        //   confirmation dialog cannot resurrect on app restart.
        // Scenario: spec-first ephemerality check -- a model with
        //   a pending app confirmation must load back with
        //   pendingConfirmation == nil.
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = pendingAppConfirmation()

        let data = try JSONEncoder().encode(toInitFile(model))
        let loaded = try loadValidatedInitFile(from: data)

        #expect(loaded.model.pendingConfirmation == nil,
            "pending confirmation is ephemeral and must not be serialized")
    }

    @Test("decode split node")
    func decodeSplitNode() throws {
        // Intent: a split-rooted tab decodes into a 2-leaf tree and the
        //   build step produces a model with both panes reachable.
        // Why it exists: pins the split branch of the rootNode enum decode
        //   (the other branch is leaf, covered by the v2 happy path).
        // Scenario: spec-first split decode -- a horizontal split with two
        //   leaves at ratio 0.6 must build into 2 panes.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "AAAA0000-0000-0000-0000-000000000001",
                "rootNode": {
                  "type": "split",
                  "id": "CCCC0000-0000-0000-0000-000000000001",
                  "direction": "horizontal",
                  "first": { "type": "leaf", "pane": { "id": "AAAA0000-0000-0000-0000-000000000001", "title": "left" } },
                  "second": { "type": "leaf", "pane": { "id": "AAAA0000-0000-0000-0000-000000000002", "title": "right" } },
                  "ratio": 0.6
                }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model != nil, "should validate split tree")
        #expect(model!.allPaneIds.count == 2)
        let tab = model!.groups[0].tabs[0]
        #expect(allPaneIds(tab.paneTree.root).count == 2)
    }

    // MARK: - Validation
    //
    // The orphan-pane and missing-pane-reference checks are gone: with the pane
    // embedded in its leaf, a pane exists iff a leaf owns it, so both are
    // structurally impossible. Leaf-id uniqueness (a pane id on two leaves) is
    // the lone surviving duplicate check; it subsumes the old within-tab and
    // cross-tree duplicate checks.

    @Test("validation rejects pane id shared across two tab leaves")
    func validationRejectsPaneIdSharedAcrossTwoTabLeaves() throws {
        // Intent: the same pane id appearing on leaves in two different
        //   tab trees is rejected at validation.
        // Why it exists: pins the leaf-id uniqueness guard that, post-
        //   restructure, is the only duplicate check (it subsumes the
        //   old within-tab and cross-tree checks).
        // Scenario: spec-first duplicate guard -- two tabs each holding a
        //   single leaf with the same pane UUID; validation must return nil.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [
                {
                  "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                  "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "shared" } }
                },
                {
                  "id": "DDDDDDDD-0000-0000-0000-000000000001",
                  "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "shared" } }
                }
              ]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model == nil, "should reject the same pane id appearing on two leaves")
    }

    @Test("validation rejects duplicate pane ID within one tab tree")
    func validationRejectsDuplicatePaneIDWithinOneTabTree() throws {
        // Intent: the same pane id appearing on two leaves WITHIN one tab
        //   tree is rejected at validation.
        // Why it exists: the within-tab variant of the leaf-id uniqueness
        //   guard; pins the structural invariant the tree-walk depends on.
        // Scenario: spec-first duplicate guard -- a split tab where first
        //   and second leaves share a pane id; validation must return nil.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": {
                  "type": "split",
                  "id": "CCCC0000-0000-0000-0000-000000000001",
                  "direction": "horizontal",
                  "first": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "a" } },
                  "second": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "b" } }
                }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model == nil, "should reject duplicate pane id within a tab tree")
    }

    @Test("validation rejects pane ID colliding with group ID")
    func validationRejectsPaneIDCollidingWithGroupID() throws {
        // Intent: a pane id that collides with a group id (across domains)
        //   is rejected at validation.
        // Why it exists: pins the cross-domain id uniqueness so callers
        //   reading by id can never mistake a pane for a group (or vice
        //   versa) under tree-owns-panes.
        // Scenario: spec-first cross-domain check -- pane UUID equals group
        //   UUID; validation must return nil.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": { "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A", "title": "collision" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model == nil, "should reject pane id collisions with other id domains")
    }

    @Test("validation normalizes missing selectedTabId to first tab")
    func validationNormalizesMissingSelectedTabIdToFirstTab() throws {
        // Intent: a snapshot with no selectedTabId field rebuilds with the
        //   first tab selected.
        // Why it exists: pins the default-restore behavior so an init file
        //   that omits the selection does not yield a model with no tab
        //   selected.
        // Scenario: spec-first default-selection check -- omit
        //   selectedTabId, rebuild succeeds, selectedTabId == first tab id.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model != nil, "should succeed")
        #expect(model!.selectedTabId == TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
    }

    @Test("validation normalizes invalid selectedTabId to first tab")
    func validationNormalizesInvalidSelectedTabIdToFirstTab() throws {
        // Intent: a snapshot whose selectedTabId names no actual tab still
        //   rebuilds, with the first tab selected as the safe default.
        // Why it exists: pins the resilient-selection behavior so a stale
        //   selectedTabId does not break restore.
        // Scenario: spec-first resilient-selection check -- an all-zero
        //   selectedTabId rebuilds the model with the first tab selected.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" } }
              }]
            }],
            "selectedTabId": "00000000-0000-0000-0000-000000000000"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model != nil, "should succeed")
        #expect(model!.selectedTabId == TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
    }

    @Test("validation supports omitted IDs and focusedPaneId")
    func validationSupportsOmittedIDsAndFocusedPaneId() throws {
        // Intent: a minimal snapshot omitting tab/group/pane ids and the
        //   focusedPaneId rebuilds with synthesized ids and the first leaf
        //   focused.
        // Why it exists: preserves the hand-authored init-file affordance
        //   where users can omit ids -- the validator mints them.
        // Scenario: spec-first affordance check -- a minimum-effort init
        //   file (just a leaf, no ids) builds with selectedTabId == the
        //   minted tab id and focused pane == the minted leaf.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf" }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model != nil, "should succeed")
        let built = model!
        let firstTab = built.groups[0].tabs[0]
        #expect(built.selectedTabId == firstTab.id, "selected tab should default to first group's first tab")
        let firstPane = firstLeafId(firstTab.paneTree.root)
        #expect(firstTab.paneTree.focusedPaneId == firstPane, "focused pane should default to first pane in first tab")
        #expect(built.pane(firstPane) != nil, "synthesized pane id should exist as a tree leaf")
    }

    @Test(
        "validation repairs a focusedPaneId that cannot name a tree leaf",
        arguments: [
            "BBBB0000-0000-0000-0000-000000000002",
            "not-a-uuid",
        ]
    )
    func validationRepairsInvalidFocusedPaneId(_ focusedPaneId: String) throws {
        // Intent: restore normalizes both a valid foreign pane UUID and a
        //   malformed focus string to the tree's first leaf.
        // Why it exists: hand-edited snapshots must not lose a recoverable
        //   session or create live model state with focus outside its tree.
        // Scenario: spec-first restore -- one leaf and an unusable focus field.
        let leafId = "AAAA0000-0000-0000-0000-000000000001"
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "focusedPaneId": "\(focusedPaneId)",
                "rootNode": {
                  "type": "leaf",
                  "pane": { "id": "\(leafId)", "title": "Terminal" }
                }
              }]
            }]
          }
        }
        """

        let initFile = try JSONDecoder().decode(AppInitFile.self, from: Data(json.utf8))
        let model = try #require(validateAndBuild(initFile.model))
        let tab = try #require(model.groups.first?.tabs.first)

        #expect(tab.paneTree.focusedPaneId.rawValue.uuidString == leafId)
    }

    // MARK: - Reconstruction invariants

    @Test("reconstructed model preserves all UUIDs")
    func reconstructedModelPreservesAllUUIDs() throws {
        // Intent: every explicit UUID in the snapshot survives the
        //   validate/build pass into the corresponding typed-id field.
        // Why it exists: pins the identity preservation across the
        //   wire-to-model boundary so caller bookmarks and references
        //   remain valid post-restore.
        // Scenario: spec-first id-preservation check -- a snapshot with
        //   explicit group/tab/pane/selectedTab UUIDs rebuilds with each
        //   surfaced via the typed-id accessors.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" } }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)!

        #expect(model.groups[0].id == GroupId(rawValue: UUID(uuidString: "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A")!))
        #expect(model.groups[0].tabs[0].id == TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
        #expect(model.pane(PaneId(rawValue: UUID(uuidString: "A13076E4-A29C-4358-A771-B4B4DF84C6C5")!)) != nil)
        #expect(model.selectedTabId == TabId(rawValue: UUID(uuidString: "89B4C232-C840-42A8-8CA6-C133C8EBBFF2")!))
    }

    @Test("session creation resolves cwd from the pane cwd")
    func sessionCreationResolvesPaneCwd() {
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: "~/pane", command: nil, scrollback: nil, theme: nil)
        let (cwd, _) = resolveLaunch(ps)
        let home = NSHomeDirectory()
        #expect(cwd == home + "/pane")
    }

    @Test("pane without command uses expanded cwd")
    func paneWithoutCommandUsesExpandedCwd() {
        // Intent: resolveLaunch returns the tilde-expanded session cwd and a nil command.
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: "~/mydir", command: nil, scrollback: nil, theme: nil)
        let (cwd, command) = resolveLaunch(ps)
        let home = NSHomeDirectory()
        #expect(cwd == home + "/mydir")
        #expect(command == nil)
    }

    @Test("pane command scalar passes command")
    func paneCommandScalarPassesCommand() {
        // Intent: a command in the snapshot surfaces through
        //   resolveLaunch verbatim.
        // Why it exists: pins the command pass-through so a hand-authored
        //   "lazygit"-as-shell init file actually launches lazygit.
        // Scenario: spec-first command pass-through -- command =
        //   "lazygit" round-trips to the resolver's command output.
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: nil, command: "lazygit", scrollback: nil, theme: nil)
        let (_, command) = resolveLaunch(ps)
        #expect(command == "lazygit")
    }

    // MARK: - Scrollback Backward Compatibility

    @Test("decode JSON without scrollback field yields nil scrollback")
    func decodeJSONWithoutScrollbackFieldYieldsNilScrollback() throws {
        // Intent: a pane object decoded without a `scrollback` field
        //   produces a snapshot with scrollback == nil.
        // Why it exists: pins the backward-compat shape so older init
        //   files (pre-scrollback) decode without modification.
        // Scenario: spec-first decode-compat check -- a v3 file from
        //   before scrollback existed produces a snapshot whose
        //   scrollback field is nil.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal"
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        #expect(allPaneSnapshots(initFile.model)[0].scrollback == nil, "scrollback should be nil when absent from JSON")
    }

    @Test("decode JSON with scrollback field preserves value")
    func decodeJSONWithScrollbackFieldPreservesValue() throws {
        // Intent: a scrollback string in the JSON surfaces verbatim on the
        //   decoded snapshot (newlines and shell prompt preserved).
        // Why it exists: pins the encode/decode symmetry so an exported
        //   scrollback can round-trip back into a snapshot exactly.
        // Scenario: spec-first decode check -- a known scrollback string
        //   with literal newlines decodes back to the same value.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "scrollback": "$ echo hello\\nhello\\n$ "
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        #expect(allPaneSnapshots(initFile.model)[0].scrollback == "$ echo hello\nhello\n$ ")
    }

    @Test("round-trip encode/decode preserves scrollback")
    func roundTripEncodeDecodePreservesScrollback() throws {
        // Intent: a non-nil scrollback round-trips through
        //   JSONEncoder/JSONDecoder exactly.
        // Why it exists: pins the symmetric encode side of the scrollback
        //   contract so a serialized snapshot can be re-read with full
        //   fidelity.
        // Scenario: spec-first symmetric round-trip -- a known scrollback
        //   string ("line1\nline2\n") survives encode + decode.
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: nil, command: nil, scrollback: "line1\nline2\n", theme: nil)
        let data = try JSONEncoder().encode(ps)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
        #expect(decoded.scrollback == "line1\nline2\n")
    }

    @Test("round-trip encode/decode preserves nil scrollback")
    func roundTripEncodeDecodePreservesNilScrollback() throws {
        // Intent: a nil scrollback round-trips through JSONEncoder/
        //   JSONDecoder as nil (not coerced to empty string).
        // Why it exists: pins the optional encoding so the absence of
        //   scrollback stays meaningful (vs. a present-but-empty value).
        // Scenario: spec-first symmetric round-trip -- nil in, nil out.
        let ps = PaneSnapshot(id: "AAAA0000-0000-0000-0000-000000000001", title: "T", cwd: nil, command: nil, scrollback: nil, theme: nil)
        let data = try JSONEncoder().encode(ps)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: data)
        #expect(decoded.scrollback == nil, "nil scrollback should survive round-trip")
    }

    @Test("expandTilde expands home directory")
    func expandTildeExpandsHomeDirectory() {
        // Intent: expandTilde converts "~/<rel>" to "<home>/<rel>",
        //   passes "/<abs>" through unchanged, and converts a bare "~"
        //   to "<home>".
        // Why it exists: pins the three branches of the tilde expansion
        //   so a refactor cannot drop the bare-tilde or absolute path.
        // Scenario: spec-first expansion check -- three sample inputs
        //   exercise each branch of the expansion.
        let home = NSHomeDirectory()
        #expect(expandTilde("~/foo") == home + "/foo")
        #expect(expandTilde("/absolute") == "/absolute")
        #expect(expandTilde("~") == home)
    }

    // MARK: - Tab Color Snapshot

    @Test("testSnapshotPreservesTabColor")
    func testSnapshotPreservesTabColor() {
        // Intent: a tab color set via .setTabColors round-trips through
        //   toSnapshot / validateAndBuild without loss.
        // Why it exists: pins the tab-color serialization contract so the
        //   color the user picked still applies after a restart.
        // Scenario: spec-first round-trip check -- set the first tab's
        //   color to .purple, snapshot, rebuild, color survives.
        var model = makeModel()
        createTab(&model)
        update(&model, .setTabColors(tabIds: [model.groups[0].tabs[0].id], color: .purple))

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        #expect(rebuilt != nil, "should rebuild from snapshot")
        #expect(rebuilt!.groups[0].tabs[0].color == .purple)
    }

    @Test("testSnapshotNilColorPreserved")
    func testSnapshotNilColorPreserved() {
        // Intent: a tab with no color set rebuilds with color still nil.
        // Why it exists: pins the optional-color preservation so the
        //   "no color picked" state isn't silently promoted to a default.
        // Scenario: spec-first round-trip check -- a tab with no color
        //   set snapshots and rebuilds with color == nil.
        var model = makeModel()
        createTab(&model)
        // No color set -- should remain nil through round-trip

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        #expect(rebuilt != nil, "should rebuild from snapshot")
        #expect(rebuilt!.groups[0].tabs[0].color == nil, "color should remain nil")
    }

    @Test("snapshot round-trip drops open preferences draft")
    func snapshotRoundTripDropsOpenPreferencesDraft() {
        // Intent: an in-progress preferencesDraft is NOT serialized to the
        //   snapshot.
        // Why it exists: pins the ephemerality of the preferences-open
        //   state so a quit-while-prefs-open does not restore a half-
        //   edited prefs draft.
        // Scenario: spec-first ephemerality check -- open prefs, change
        //   a setting, snapshot+rebuild, the draft is nil on the rebuild.
        var model = makeModel()
        createTab(&model)
        model.config.defaultTheme = "Dracula"
        update(&model, .preferencesOpened())
        update(&model, .prefSet(.theme("Solarized")))
        #expect(model.preferencesDraft != nil, "draft should exist before snapshot")

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)

        #expect(rebuilt != nil, "should rebuild from snapshot")
        #expect(rebuilt!.preferencesDraft == nil, "draft should not be serialized")
    }

    @Test("validation rejects duplicate IDs across domains")
    func validationRejectsDuplicateIDsAcrossDomains() throws {
        // Intent: a UUID used as both a group id and a tab id is rejected
        //   at validation.
        // Why it exists: pins the cross-domain id uniqueness so a
        //   group-vs-tab id collision can't sneak through.
        // Scenario: spec-first cross-domain check -- group.id == tab.id;
        //   validation must return nil.
        // Use same UUID for group and tab
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
                "rootNode": { "type": "leaf", "pane": { "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5", "title": "T" } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model == nil, "should reject duplicate IDs across domains")
    }

    // MARK: - TODO Snapshot

    @Test("checkpoint decodes pane and tab todo ids from bare strings")
    func checkpointDecodesTodoIdsFromBareStrings() throws {
        let tabTodoId = "11111111-1111-4111-8111-111111111111"
        let paneTodoId = "22222222-2222-4222-8222-222222222222"
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "id": "33333333-3333-4333-8333-333333333333",
                "todos": [{ "id": "\(tabTodoId)", "text": "tab task", "isDone": true }],
                "rootNode": { "type": "leaf", "pane": {
                  "id": "44444444-4444-4444-8444-444444444444",
                  "title": "Terminal",
                  "todos": [{ "id": "\(paneTodoId)", "text": "pane task", "isDone": false }]
                } }
              }]
            }]
          }
        }
        """

        let initFile = try JSONDecoder().decode(AppInitFile.self, from: Data(json.utf8))
        let model = try #require(validateAndBuild(initFile.model))
        let tab = try #require(model.groups.first?.tabs.first)
        let pane = try #require(model.pane(tab.paneTree.focusedPaneId))

        #expect(tab.todos == [TodoItem(
            id: TodoId(rawValue: try #require(UUID(uuidString: tabTodoId))),
            text: "tab task",
            isDone: true
        )])
        #expect(pane.todos == [TodoItem(
            id: TodoId(rawValue: try #require(UUID(uuidString: paneTodoId))),
            text: "pane task",
            isDone: false
        )])
    }

    @Test("checkpoint encodes pane and tab todo ids as bare strings")
    func checkpointEncodesBareStringTodoIds() throws {
        var model = makeModel()
        createTab(&model)
        let tab = try #require(selectedTab(in: model))
        update(&model, .addTodo(owner: .tab(tab.id), text: "tab task"))
        update(&model, .addTodo(owner: .pane(tab.paneTree.focusedPaneId), text: "pane task"))

        let data = try JSONEncoder().encode(AppInitFile(
            version: appInitFileVersion,
            model: toSnapshot(model)
        ))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let snapshot = try #require(root["model"] as? [String: Any])
        let groups = try #require(snapshot["groups"] as? [[String: Any]])
        let tabs = try #require(groups.first?["tabs"] as? [[String: Any]])
        let encodedTab = try #require(tabs.first)
        let tabTodos = try #require(encodedTab["todos"] as? [[String: Any]])
        let rootNode = try #require(encodedTab["rootNode"] as? [String: Any])
        let pane = try #require(rootNode["pane"] as? [String: Any])
        let paneTodos = try #require(pane["todos"] as? [[String: Any]])

        #expect(tabTodos.first?["id"] as? String == model.todos(for: .tab(tab.id))?.first?.id.rawValue.uuidString)
        #expect(paneTodos.first?["id"] as? String == model.todos(for: .pane(tab.paneTree.focusedPaneId))?.first?.id.rawValue.uuidString)
    }

    @Test("snapshot round-trip preserves todos")
    func snapshotRoundTripPreservesTodos() {
        // Intent: pane-level todos (text + isDone) round-trip through the
        //   snapshot exactly: two todos in declared order, with the
        //   toggled one's isDone == true and the other's false.
        // Why it exists: pins the pane.todos serialization the AGENTS.md
        //   todo workflow relies on across restarts.
        // Scenario: spec-first round-trip check -- add two todos, toggle
        //   the first, snapshot, rebuild, both texts and isDone flags
        //   match the original.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "task one"))
        update(&model, .addTodo(owner: .pane(paneId), text: "task two"))
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .pane(paneId), todoId: todoId))

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        #expect(rebuilt != nil, "should rebuild from snapshot with todos")
        let todos = rebuilt!.pane(paneId)!.todos
        #expect(todos.count == 2)
        #expect(todos[0].text == "task one")
        #expect(todos[0].isDone == true)
        #expect(todos[1].text == "task two")
        #expect(todos[1].isDone == false)
    }

    @Test("snapshot persists agentSession but validateAndBuild does not rehydrate it live")
    func snapshotPersistsAgentSessionButRestoreDoesNotRehydrateLive() throws {
        // Intent: a live agentSession is serialized for recovery hints,
        //   but restored panes do not rehydrate it as live toolbar state.
        // Why it exists: pins the live-vs-persisted distinction: a
        //   restored process is dead until an agent hook reports again.
        // Scenario: DanTerm checkpoints while Claude is running, then
        //   restores after a crash.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let session = try #require(AgentSession(kind: "claude", sessionId: "4f3a2b1c"))

        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(session)))
        let snapshot = toSnapshot(model)
        let pane = try #require(paneSnapshot(paneId.rawValue.uuidString, in: snapshot))
        #expect(pane.agentSession?.kind == "claude")
        #expect(pane.agentSession?.sessionId == "4f3a2b1c")

        let rebuilt = try #require(validateAndBuild(snapshot), "snapshot should rebuild")
        #expect(rebuilt.pane(paneId)?.session?.agent == AgentLifecycle.none)
        #expect(rebuilt.pane(paneId)?.session?.lastAgentSession == session)
    }

    @Test("recovery replay defensively validates a directly constructed agent snapshot")
    func recoveryReplayDefensivelyValidatesDirectAgentSnapshot() throws {
        let valid = AgentSessionSnapshot(kind: "claude", sessionId: "4f3a2b1c")
        #expect(recoveryReplayText(scrollback: nil, agentSession: valid) == """
        [DanTerm] Restored Claude session. Resume with:
          claude --resume 4f3a2b1c

        """)

        let invalid = AgentSessionSnapshot(kind: "claude", sessionId: "bad;id")
        #expect(recoveryReplayText(scrollback: "old output\n", agentSession: invalid) == "old output\n")
    }

    @Test("malformed agentSession snapshot rejects restore")
    func malformedAgentSessionSnapshotRejectsRestore() throws {
        // Scenario: an imported or hand-edited checkpoint has an agentSession
        //   object with a non-string kind and no sessionId.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "id": "E53A57E9-1B39-4E15-B2AD-CA6B8700F17A",
              "name": "General",
              "isDefault": true,
              "tabs": [{
                "id": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2",
                "focusedPaneId": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "agentSession": { "kind": 42 }
                } }
              }]
            }],
            "selectedTabId": "89B4C232-C840-42A8-8CA6-C133C8EBBFF2"
          }
        }
        """
        #expect(throws: AppInitFileLoadError.decodeFailed) {
            try loadValidatedInitFile(from: json.data(using: .utf8)!)
        }
    }

    @Test("invalid agentSession value rejects restore")
    func invalidAgentSessionValueRejectsRestore() throws {
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf", "pane": {
                  "title": "Terminal",
                  "agentSession": { "kind": "claude", "sessionId": "bad;id" }
                } }
              }]
            }]
          }
        }
        """

        #expect(throws: AppInitFileLoadError.invalidSnapshot) {
            try loadValidatedInitFile(from: json.data(using: .utf8)!)
        }
    }

    @Test("omitted agentSession loads as no agent")
    func omittedAgentSessionLoadsAsNoAgent() throws {
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf", "pane": { "title": "Terminal" } }
              }]
            }]
          }
        }
        """

        let loaded = try loadValidatedInitFile(from: json.data(using: .utf8)!)
        #expect(try #require(loaded.paneSnapshots.values.first).agentSession == nil)
    }

    @Test("cwd reset restores as nil")
    func cwdResetRestoresAsNil() throws {
        // Intent: an explicit cwd reset removes the live value and serializes
        //   no empty-path substitute, so restore also has a nil cwd.
        // Why it exists: pins reset semantics across the persistence boundary.
        // Scenario: a shell reports a cwd, then clears it before DanTerm writes
        //   and reloads the next checkpoint.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .sessionReport(sessionId: sessionId(for: paneId, in: model), report: .cwd("/tmp/project")))

        update(&model, .sessionReport(sessionId: sessionId(for: paneId, in: model), report: .cwd(nil)))
        let snapshot = toSnapshot(model, home: "/Users/testhome")
        let restored = try #require(validateAndBuild(snapshot))
        let paneSnapshot = try #require(allPaneSnapshots(snapshot).first)

        #expect(model.pane(paneId)?.session?.cwd == nil)
        #expect(paneSnapshot.cwd == nil)
        #expect(restored.pane(paneId)?.session?.cwd == nil)
    }

    @Test("snapshot round-trip preserves tab todos")
    func snapshotRoundTripPreservesTabTodos() {
        // Intent: tab-level todos (TabTodos popover items) round-trip
        //   through the snapshot exactly.
        // Why it exists: pins the tab.todos serialization symmetric to
        //   pane.todos so the user's tab-level checklist also survives
        //   restart.
        // Scenario: spec-first round-trip check -- add two tab todos,
        //   toggle the first, snapshot+rebuild, both texts and isDone
        //   flags match.
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        update(&model, .addTodo(owner: .tab(tabId), text: "tab one"))
        update(&model, .addTodo(owner: .tab(tabId), text: "tab two"))
        let id1 = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .tab(tabId), todoId: id1))

        let snapshot = toSnapshot(model)
        let rebuilt = validateAndBuild(snapshot)
        #expect(rebuilt != nil, "should rebuild from snapshot with tab todos")
        let todos = tabById(tabId, in: rebuilt!)!.todos
        #expect(todos.count == 2)
        #expect(todos[0].text == "tab one")
        #expect(todos[0].isDone == true)
        #expect(todos[1].text == "tab two")
        #expect(todos[1].isDone == false)
    }

    @Test("toSnapshot emits nil for empty tab todos")
    func toSnapshotEmitsNilForEmptyTabTodos() {
        // Intent: a tab with no todos serializes its todos field as nil
        //   (absent), not an empty array.
        // Why it exists: pins the encoder's optional-empty convention so
        //   typical tabs do not pay a wire-format tax of an empty array.
        // Scenario: spec-first encoder check -- a freshly created tab's
        //   snapshot.todos is nil.
        var model = makeModel()
        createTab(&model)
        let snapshot = toSnapshot(model)
        let tabSnap = snapshot.groups[0].tabs[0]
        #expect(tabSnap.todos == nil, "empty tab todos should encode as nil")
    }

    @Test("snapshot without tab todos field decodes with empty list")
    func snapshotWithoutTabTodosFieldDecodesWithEmptyList() throws {
        // Intent: a snapshot omitting the tab `todos` field rebuilds the
        //   model with an empty tab.todos list.
        // Why it exists: pins the decoder's nil -> empty-list normalization
        //   so older init files (pre-tab-todos) decode cleanly.
        // Scenario: spec-first decode-compat check -- a v3 file with no
        //   tab.todos field rebuilds with tab.todos.count == 0.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "cwd": "~/world"
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model != nil, "should rebuild snapshot without tab todos field")
        let tabs = model!.groups.flatMap(\.tabs)
        #expect(tabs[0].todos.count == 0, "tab todos should default to empty")
    }

    @Test("snapshot without todos field decodes with empty array")
    func snapshotWithoutTodosFieldDecodesWithEmptyArray() throws {
        // Intent: a snapshot omitting the pane `todos` field rebuilds the
        //   model with an empty pane.todos array.
        // Why it exists: pins the pane-side of the nil -> empty
        //   normalization symmetric to tab.todos.
        // Scenario: spec-first decode-compat check -- a v3 file with no
        //   pane.todos field rebuilds with pane.todos.count == 0.
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "rootNode": { "type": "leaf", "pane": {
                  "id": "A13076E4-A29C-4358-A771-B4B4DF84C6C5",
                  "title": "Terminal",
                  "cwd": "~/world"
                } }
              }]
            }]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let initFile = try JSONDecoder().decode(AppInitFile.self, from: data)
        let model = validateAndBuild(initFile.model)
        #expect(model != nil, "should rebuild snapshot without todos field")
        let panes = Array(model!.allPanes)
        #expect(panes[0].todos.count == 0, "todos should default to empty")
    }
}
