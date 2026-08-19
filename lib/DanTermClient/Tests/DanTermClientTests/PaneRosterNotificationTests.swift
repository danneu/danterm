// Coverage for reading `roster.event` off a conversation that also carries tape records.
//
// The roster's own wire shape is proved in DanTermProtocol's PaneRosterTests; this file is
// only about a client picking the roster notification out of the frames it reads.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermClient

struct PaneRosterNotificationTests {
    @Test("a roster notification is recognized by method and carries its roster")
    func rosterNotificationCarriesItsRoster() throws {
        let notification = try #require(PaneRosterNotification(
            method: Methods.rosterEvent,
            params: roster(paneTitle: "zsh").jsonValue
        ))

        #expect(notification.roster.panes.map(\.paneTitle) == ["zsh"])
    }

    @Test("a notification of another method is not a roster")
    func foreignMethodIsNotARoster() {
        // Intent: the initializer answers nil for a method it does not own, rather than
        //   failing the read.
        // Why it exists: one connection carries tape records and rosters at the same time,
        //   so every decoder on it must be able to say "not mine" and let the next one look.
        #expect(PaneRosterNotification(
            method: Methods.paneTapeEvent,
            params: .object(["subscription": .string("s1"), "records": .array([])])
        ) == nil)
        #expect(PaneRosterNotification(method: Methods.rosterEvent, params: nil) == nil)
        #expect(PaneRosterNotification(
            method: Methods.rosterEvent,
            params: .object(["panes": .string("not a list")])
        ) == nil)
    }

    @Test("rosters and tape records interleave on one conversation in arrival order")
    func rostersAndTapeRecordsInterleave() throws {
        // Intent: a session carrying both notification kinds hands them back in the order
        //   the peer sent them, and each kind's decoder claims only its own.
        // Why it exists: the phone holds one socket for the tape stream and the roster
        //   subscription together, so a roster arriving mid-burst must neither be dropped
        //   nor consume the record beside it.
        let session = DanTermClientSession(transport: ScriptedTransport(lines: [
            tapeNotification(record: "first"),
            rosterNotification(paneTitle: "zsh"),
            tapeNotification(record: "second"),
            rosterNotification(paneTitle: "vim"),
        ]))

        var arrivals: [String] = []
        while let next = try session.nextNotification() {
            if let tape = PaneTapeEventNotification<JSONValue>(
                method: next.method,
                params: next.params
            ) {
                arrivals.append(
                    "tape:" + (try #require(tape.records.first?["kind"]?.asString))
                )
            } else if let carried = PaneRosterNotification(
                method: next.method,
                params: next.params
            ) {
                arrivals.append("roster:" + (try #require(carried.roster.panes.first).paneTitle))
            }
        }

        #expect(arrivals == ["tape:first", "roster:zsh", "tape:second", "roster:vim"])
    }

    private func roster(paneTitle: String) -> PaneRoster {
        PaneRoster(panes: [PaneRosterItem(
            groupId: GroupId(rawValue: uuid(1)),
            groupName: "Work",
            tabId: TabId(rawValue: uuid(2)),
            tabTitle: "Tab",
            paneId: PaneId(rawValue: uuid(3)),
            paneTitle: paneTitle,
            chip: .terminal,
            isSelectedTab: true,
            isFocused: true
        )])
    }

    private func rosterNotification(paneTitle: String) -> String {
        encoded(JsonRpcRequest(
            method: Methods.rosterEvent,
            params: roster(paneTitle: paneTitle).jsonValue
        ))
    }

    private func tapeNotification(record kind: String) -> String {
        encoded(JsonRpcRequest(
            method: Methods.paneTapeEvent,
            params: .object([
                "subscription": .string("s1"),
                "records": .array([.object(["kind": .string(kind)])]),
            ])
        ))
    }

    private func encoded<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", value))!
    }
}
