// Behavioral coverage for the shared pane-roster value: its wire encoding, its
// decoding, and what it rejects. The projection that builds a roster from the
// model lives in DanTermCore and is asserted there.
import DanTermProtocol
import Foundation
import Testing

struct PaneRosterTests {
    @Test("A roster survives a round trip through its wire form")
    func rosterRoundTrips() throws {
        let roster = PaneRoster(panes: [
            PaneRosterItem(
                groupId: GroupId(rawValue: uuid(1)),
                groupName: "Work",
                tabId: TabId(rawValue: uuid(2)),
                tabTitle: "Pinned",
                paneId: PaneId(rawValue: uuid(3)),
                paneTitle: "zsh",
                isSelectedTab: true,
                isFocused: false
            ),
            PaneRosterItem(
                groupId: GroupId(rawValue: uuid(1)),
                groupName: "Work",
                tabId: TabId(rawValue: uuid(2)),
                tabTitle: "Pinned",
                paneId: PaneId(rawValue: uuid(4)),
                paneTitle: "vim",
                isSelectedTab: true,
                isFocused: true
            ),
        ])

        #expect(PaneRoster(jsonValue: roster.jsonValue) == roster)
    }

    @Test("An empty roster is a roster, not a decode failure")
    func emptyRosterRoundTrips() throws {
        let roster = PaneRoster(panes: [])

        #expect(PaneRoster(jsonValue: roster.jsonValue) == roster)
    }

    @Test("A roster missing a required item field decodes to nil")
    func malformedItemDecodesToNil() throws {
        let item: JSONValue = .object([
            "groupId": .string(uuid(1).uuidString),
            "groupName": .string("Work"),
            "tabId": .string(uuid(2).uuidString),
            "tabTitle": .string("Pinned"),
            "paneId": .string(uuid(3).uuidString),
            // paneTitle omitted
            "isSelectedTab": .bool(true),
            "isFocused": .bool(false),
        ])

        #expect(PaneRoster(jsonValue: .object(["panes": .array([item])])) == nil)
    }

    @Test("A value carrying no pane list decodes to nil")
    func missingPaneListDecodesToNil() throws {
        #expect(PaneRoster(jsonValue: .object([:])) == nil)
        #expect(PaneRoster(jsonValue: .string("panes")) == nil)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", value))!
    }
}
