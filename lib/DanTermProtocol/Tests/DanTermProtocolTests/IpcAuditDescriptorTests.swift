// Behavioral coverage for the IPC audit descriptor's content-redaction boundary.
import Foundation
import Testing

@testable import DanTermProtocol

struct IpcAuditDescriptorTests {
    private let pane = PaneId(rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    private let group = GroupId(rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)

    @Test("text input records UTF-8 bytes without content")
    func textInputIsRedactedToByteCount() throws {
        let request = IpcRequest.paneInput(pane: pane, input: .text("secret-pi-\u{00F1}"))

        let descriptor = request.auditDescriptor
        let encoded = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)

        #expect(descriptor.input == .textBytes(12))
        #expect(encoded.contains("\"textBytes\":12"))
        #expect(encoded.contains("_0") == false)
        #expect(encoded.contains("secret") == false)
        #expect(encoded.contains("pi-\u{00F1}") == false)
        #expect(try JSONDecoder().decode(IpcAuditRequestDescriptor.self, from: Data(encoded.utf8)) == descriptor)
    }

    @Test("event input records only the event count")
    func eventInputIsRedactedToCount() throws {
        let request = IpcRequest.paneInput(
            pane: pane,
            input: .events([.key(.character("c"), [.ctrl]), .text("hidden")])
        )

        let descriptor = request.auditDescriptor
        let encoded = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)

        #expect(descriptor.input == .eventCount(2))
        #expect(encoded.contains("\"eventCount\":2"))
        #expect(encoded.contains("_0") == false)
        #expect(encoded.contains("hidden") == false)
        #expect(encoded.contains("ctrl") == false)
        #expect(try JSONDecoder().decode(IpcAuditRequestDescriptor.self, from: Data(encoded.utf8)) == descriptor)
    }

    @Test("launch requests retain command and working directory")
    func launchAuthorityIsRetained() {
        let launch = LaunchSpec(cmd: "ssh server", cwd: "/tmp/work", title: "private title")
        let requests: [IpcRequest] = [
            .tabNew(
                target: .group(group, position: .atGroupEnd),
                launch: launch,
                background: false
            ),
            .paneSplit(
                target: .pane(pane, direction: .horizontal),
                launch: launch,
                background: false
            ),
        ]

        for request in requests {
            #expect(request.auditDescriptor.command == "ssh server")
            #expect(request.auditDescriptor.cwd == "/tmp/work")
        }
        #expect(requests[0].auditDescriptor.target == [
            "group": group.rawValue.uuidString.lowercased(),
        ])
        #expect(requests[1].auditDescriptor.target == [
            "pane": pane.rawValue.uuidString.lowercased(),
        ])

        let tab = TabId(rawValue: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        #expect(IpcRequest.paneSplit(
            target: .tab(tab),
            launch: launch,
            background: true
        ).auditDescriptor.target == ["tab": tab.rawValue.uuidString.lowercased()])
    }

    @Test("pane.resize records its method and pane, and both forms audit alike")
    func paneResizeIsAuditedByMethodAndPane() throws {
        // Intent: a resize appears in the audit log as the method and the pane it
        //   named, with no launch or input accounting attached.
        // Why it exists: any admitted remote caller can shrink a pane mid-use, so
        //   the record of which pane was resized is the only trace of that.
        // Scenario: spec-first; a grid claim and a fit on the same pane.
        for request: IpcRequest in [
            .paneResize(pane: pane, resize: .grid(columns: 60, rows: 20)),
            .paneResize(pane: pane, resize: .fit),
        ] {
            let descriptor = request.auditDescriptor
            #expect(descriptor.method == "pane.resize")
            #expect(descriptor.target == ["pane": pane.rawValue.uuidString.lowercased()])
            #expect(descriptor.command == nil)
            #expect(descriptor.cwd == nil)
            #expect(descriptor.input == nil)
        }
        #expect(IpcRequestMethod.paneResize.producesAuditRecord)
    }

    @Test("pane content reads record only method and target")
    func paneContentReadsHaveNoContentField() throws {
        let requests: [IpcRequest] = [
            .paneRead(pane: pane, lineLimit: 20),
            .paneRows(pane: pane),
            .paneTape(
                pane: pane,
                follow: false,
                start: .now,
                policy: .reconstructible(historyBudgetBytes: 1024)
            ),
            .paneSnapshot(pane: pane),
        ]

        for request in requests {
            let descriptor = request.auditDescriptor
            #expect(descriptor.target == ["pane": pane.rawValue.uuidString.lowercased()])
            #expect(descriptor.command == nil)
            #expect(descriptor.cwd == nil)
            #expect(descriptor.input == nil)
        }
    }

    @Test("a todo state change audits its state as the method and its owner as the target")
    func todoStateChangeIsAuditedByStateAndOwner() {
        // Intent: the audit record says which state the caller asked for, through the
        //   method, and names the owner plus the todo, and nothing else.
        // Why it exists: the state is carried by the wire method alone, so a request
        //   that loses it audits as the opposite action with no other trace.
        // Scenario: spec-first; the same todo completed and reopened, once under a
        //   pane owner and once under a tab owner.
        let todoId = TodoId(rawValue: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
        let tab = TabId(rawValue: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)
        let owners: [(TodoOwner, [String: String])] = [
            (.pane(pane), ["pane": pane.rawValue.uuidString.lowercased()]),
            (.tab(tab), ["tab": tab.rawValue.uuidString.lowercased()]),
        ]

        for (owner, ownerTarget) in owners {
            let expectedTarget = ownerTarget.merging(
                ["todoId": todoId.rawValue.uuidString.lowercased()]
            ) { _, new in new }

            let done = IpcRequest.todoSetDone(owner: owner, todoId: todoId, isDone: true).auditDescriptor
            #expect(done.method == "todo.done")
            #expect(done.target == expectedTarget)

            let open = IpcRequest.todoSetDone(owner: owner, todoId: todoId, isDone: false).auditDescriptor
            #expect(open.method == "todo.open")
            #expect(open.target == expectedTarget)
        }
    }
}
