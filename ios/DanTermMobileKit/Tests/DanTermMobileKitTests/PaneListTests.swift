// Behavioral tests for the flat phone projection of the `ls` reply.
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

@Test("Nested split leaves appear once in display order with tab state")
func nestedPaneProjection() throws {
    let list = try projectPaneList(from: .object([
        "selectedTabId": .string(wireId(102)),
        "groups": .array([
            .object([
                "id": .string(wireId(1)),
                "name": .string("Work"),
                "tabs": .array([
                    tab(
                        id: wireId(101),
                        customTitle: "Pinned",
                        focused: wireId(202),
                        root: split(
                            leaf(wireId(201), title: "one"),
                            leaf(wireId(202), title: "two")
                        )
                    ),
                    tab(
                        id: wireId(102),
                        focused: wireId(203),
                        root: leaf(wireId(203), title: "three", command: "vim README.md")
                    ),
                ]),
            ]),
        ]),
    ]))

    #expect(list.map(\.paneId) == [paneId(201), paneId(202), paneId(203)])
    #expect(list.map(\.tabTitle) == ["Pinned", "Pinned", "three"])
    #expect(list.map(\.isFocused) == [false, true, true])
    #expect(list.map(\.isSelectedTab) == [false, false, true])
}

@Test("Tab title falls back from custom title to focused title to running command")
func titleFallbacks() throws {
    let result = try projectPaneList(from: .object([
        "groups": .array([.object([
            "id": .string(wireId(2)),
            "name": .string("Group"),
            "tabs": .array([
                tab(id: wireId(111), customTitle: "Custom", focused: wireId(211), root: leaf(wireId(211), title: "shell", command: "ignored")),
                tab(id: wireId(112), focused: wireId(212), root: leaf(wireId(212), title: "project", command: "ignored")),
                tab(id: wireId(113), focused: wireId(213), root: leaf(wireId(213), title: "Terminal", command: "htop")),
            ]),
        ])]),
    ]))
    #expect(result.map(\.tabTitle) == ["Custom", "project", "htop"])
}

private func tab(
    id: String,
    customTitle: String? = nil,
    focused: String,
    root: JSONValue
) -> JSONValue {
    var object: [String: JSONValue] = [
        "id": .string(id),
        "focusedPaneId": .string(focused),
        "rootNode": root,
    ]
    if let customTitle { object["customTitle"] = .string(customTitle) }
    return .object(object)
}

private func leaf(_ id: String, title: String, command: String? = nil) -> JSONValue {
    var pane: [String: JSONValue] = ["id": .string(id), "title": .string(title)]
    if let command {
        pane["command"] = .object(["state": .string("running"), "text": .string(command)])
    } else {
        pane["command"] = .object(["state": .string("idle")])
    }
    return .object(["type": .string("leaf"), "pane": .object(pane)])
}

private func split(_ first: JSONValue, _ second: JSONValue) -> JSONValue {
    .object([
        "type": .string("split"),
        "direction": .string("horizontal"),
        "first": first,
        "second": second,
    ])
}

private func wireId(_ value: Int) -> String {
    "00000000-0000-0000-0000-" + String(format: "%012d", value)
}

private func paneId(_ value: Int) -> PaneId {
    PaneId(rawValue: UUID(uuidString: wireId(value))!)
}
