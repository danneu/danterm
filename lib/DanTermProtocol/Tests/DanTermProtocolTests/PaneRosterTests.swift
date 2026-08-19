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
                chip: .terminal,
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
                chip: .claude,
                isSelectedTab: true,
                isFocused: true
            ),
        ])

        #expect(PaneRoster(jsonValue: roster.jsonValue) == roster)
    }

    @Test("Every chip kind survives a round trip through its wire spelling")
    func everyChipKindRoundTrips() throws {
        // Intent: each chip a server can send is the chip the client reads back.
        // Why it exists: the chip is the one roster field with a vocabulary of its
        //   own, so a spelling that encodes but does not decode would silently fail
        //   the whole roster for exactly the panes running that agent.
        // Scenario: a roster carrying one pane per chip kind crosses the wire.
        let roster = PaneRoster(panes: ChipKind.allCases.enumerated().map { index, chip in
            PaneRosterItem(
                groupId: GroupId(rawValue: uuid(1)),
                groupName: "Work",
                tabId: TabId(rawValue: uuid(2)),
                tabTitle: "Pinned",
                paneId: PaneId(rawValue: uuid(index + 10)),
                paneTitle: "pane",
                chip: chip,
                isSelectedTab: true,
                isFocused: false
            )
        })

        #expect(PaneRoster(jsonValue: roster.jsonValue)?.panes.map(\.chip) == ChipKind.allCases)
    }

    @Test("A roster item whose encoding omits or misspells the chip decodes to nil")
    func missingOrUnknownChipDecodesToNil() throws {
        // Intent: the chip is required, and only a spelling this build knows counts.
        // Why it exists: a client that defaulted an absent or unreadable chip would
        //   draw a terminal mark over a pane running an agent, which is worse than
        //   refusing the roster and saying so.
        // Scenario: a Mac too old to send a chip, and one sending a kind this build
        //   does not have.
        var fields: [String: JSONValue] = [
            "groupId": .string(uuid(1).uuidString),
            "groupName": .string("Work"),
            "tabId": .string(uuid(2).uuidString),
            "tabTitle": .string("Pinned"),
            "paneId": .string(uuid(3).uuidString),
            "paneTitle": .string("zsh"),
            "isSelectedTab": .bool(true),
            "isFocused": .bool(false),
        ]

        #expect(PaneRoster(jsonValue: .object(["panes": .array([.object(fields)])])) == nil)

        fields["chip"] = .string("gemini")
        #expect(PaneRoster(jsonValue: .object(["panes": .array([.object(fields)])])) == nil)

        fields["chip"] = .string("codex")
        #expect(PaneRoster(jsonValue: .object(["panes": .array([.object(fields)])]))?
            .panes.map(\.chip) == [.codex])
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
            "chip": .string("terminal"),
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
