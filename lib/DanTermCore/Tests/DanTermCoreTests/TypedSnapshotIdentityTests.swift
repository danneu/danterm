// Pins typed snapshot identities while preserving the version 3 wire format
// and the deliberately repairable parts of recovery decoding.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

/// Proves snapshot identity typing and its version 3 recovery contract together.
@Suite struct TypedSnapshotIdentityTests {
    private static let fixture = #"{"model":{"groups":[{"id":"11111111-1111-4111-8111-111111111111","isCollapsed":false,"name":"General","tabs":[{"focusedPaneId":"33333333-3333-4333-8333-333333333333","id":"22222222-2222-4222-8222-222222222222","rootNode":{"direction":"horizontal","first":{"pane":{"id":"33333333-3333-4333-8333-333333333333","title":"Left","todos":[{"id":"66666666-6666-4666-8666-666666666666","isDone":false,"text":"pane task"}]},"type":"leaf"},"id":"55555555-5555-4555-8555-555555555555","ratio":0.5,"second":{"pane":{"id":"44444444-4444-4444-8444-444444444444","title":"Right"},"type":"leaf"},"type":"split"},"todos":[{"id":"77777777-7777-4777-8777-777777777777","isDone":true,"text":"tab task"}]}]}],"selectedTabId":"22222222-2222-4222-8222-222222222222"},"version":3}"#

    @Test("version 3 identity fixture round-trips byte for byte")
    func version3IdentityFixtureRoundTripsByteForByte() throws {
        let decoded = try JSONDecoder().decode(AppInitFile.self, from: Data(Self.fixture.utf8))

        let group: GroupId? = decoded.model.groups[0].id
        let tab: TabId? = decoded.model.groups[0].tabs[0].id
        let selected: TabId? = decoded.model.selectedTabId
        let focused: PaneId? = decoded.model.groups[0].tabs[0].focusedPaneId
        let split: SplitId? = {
            guard case .split(let id, _, _, _, _) = decoded.model.groups[0].tabs[0].rootNode else { return nil }
            return id
        }()
        let panes: [PaneId?] = paneSnapshots(in: decoded.model.groups[0].tabs[0].rootNode).map(\.id)
        let paneTodo: TodoId? = paneSnapshots(in: decoded.model.groups[0].tabs[0].rootNode)[0].todos?[0].id
        let tabTodo: TodoId? = decoded.model.groups[0].tabs[0].todos?[0].id

        #expect(group?.rawValue.uuidString == "11111111-1111-4111-8111-111111111111")
        #expect(tab?.rawValue.uuidString == "22222222-2222-4222-8222-222222222222")
        #expect(selected == tab)
        #expect(focused == panes[0])
        #expect(split?.rawValue.uuidString == "55555555-5555-4555-8555-555555555555")
        #expect(paneTodo?.rawValue.uuidString == "66666666-6666-4666-8666-666666666666")
        #expect(tabTodo?.rawValue.uuidString == "77777777-7777-4777-8777-777777777777")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(decoded), as: UTF8.self) == Self.fixture)
    }

    @Test("malformed repairable references fall back to the first valid identities")
    func malformedRepairableReferencesFallBack() throws {
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "focusedPaneId": "not-a-uuid",
                "rootNode": { "type": "leaf", "pane": { "title": "Terminal" } }
              }]
            }],
            "selectedTabId": "also-not-a-uuid"
          }
        }
        """
        let ids = (1...4).map { UUID(uuidString: "00000000-0000-4000-8000-00000000000\($0)")! }

        let snapshot = try JSONDecoder().decode(AppInitFile.self, from: Data(json.utf8)).model
        let model = try #require(validateAndBuild(snapshot, env: makeTestEnv(idSequence: ids)))
        let tab = try #require(model.groups.first?.tabs.first)

        #expect(model.selectedTabId == tab.id)
        #expect(tab.paneTree.focusedPaneId == firstLeafId(tab.paneTree.root))
    }

    @Test("wrong JSON types are not repaired as missing references")
    func wrongReferenceTypesRejectDecoding() {
        let selected = #"{"version":3,"model":{"groups":[{"name":"General","tabs":[{"rootNode":{"type":"leaf"}}]}],"selectedTabId":42}}"#
        let focused = #"{"version":3,"model":{"groups":[{"name":"General","tabs":[{"focusedPaneId":42,"rootNode":{"type":"leaf"}}]}]}}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppInitFile.self, from: Data(selected.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppInitFile.self, from: Data(focused.utf8))
        }
    }

    @Test("malformed todo UUIDs drop only their own todo")
    func malformedTodoUUIDsDropOnlyTheirOwnTodo() throws {
        let json = """
        {
          "version": 3,
          "model": {
            "groups": [{
              "name": "General",
              "tabs": [{
                "todos": [
                  { "id": "11111111-1111-4111-8111-111111111111", "text": "tab first", "isDone": false },
                  { "id": "bad-tab", "text": "tab bad", "isDone": false },
                  { "id": "22222222-2222-4222-8222-222222222222", "text": "tab last", "isDone": true }
                ],
                "rootNode": { "type": "leaf", "pane": {
                  "todos": [
                    { "id": "33333333-3333-4333-8333-333333333333", "text": "pane first", "isDone": false },
                    { "id": "bad-pane", "text": "pane bad", "isDone": false },
                    { "id": "44444444-4444-4444-8444-444444444444", "text": "pane last", "isDone": true }
                  ]
                } }
              }]
            }]
          }
        }
        """

        let snapshot = try JSONDecoder().decode(AppInitFile.self, from: Data(json.utf8)).model
        let model = try #require(validateAndBuild(snapshot))
        let tab = try #require(model.groups.first?.tabs.first)
        let pane = try #require(model.pane(tab.paneTree.focusedPaneId))

        #expect(tab.todos.map(\.text) == ["tab first", "tab last"])
        #expect(pane.todos.map(\.text) == ["pane first", "pane last"])
    }

    @Test("malformed required todo fields still reject the whole file")
    func malformedRequiredTodoFieldsRejectWholeFile() {
        let wrongType = #"{"version":3,"model":{"groups":[{"name":"General","tabs":[{"todos":[{"id":42,"text":"task","isDone":false}],"rootNode":{"type":"leaf"}}]}]}}"#
        let missingText = #"{"version":3,"model":{"groups":[{"name":"General","tabs":[{"todos":[{"id":"11111111-1111-4111-8111-111111111111","isDone":false}],"rootNode":{"type":"leaf"}}]}]}}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppInitFile.self, from: Data(wrongType.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppInitFile.self, from: Data(missingText.utf8))
        }
    }

    @Test("malformed defining UUIDs reject decoding")
    func malformedDefiningUUIDsRejectDecoding() {
        let json = #"{"version":3,"model":{"groups":[{"id":"not-a-uuid","name":"General","tabs":[{"rootNode":{"type":"leaf"}}]}]}}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AppInitFile.self, from: Data(json.utf8))
        }
    }
}
