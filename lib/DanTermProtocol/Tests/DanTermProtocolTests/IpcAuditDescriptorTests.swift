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
        #expect(encoded.contains("secret") == false)
        #expect(encoded.contains("pi-\u{00F1}") == false)
    }

    @Test("event input records only the event count")
    func eventInputIsRedactedToCount() throws {
        let request = IpcRequest.paneInput(
            pane: pane,
            input: .events([.key(.letter("c"), [.ctrl]), .text("hidden")])
        )

        let descriptor = request.auditDescriptor
        let encoded = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)

        #expect(descriptor.input == .eventCount(2))
        #expect(encoded.contains("hidden") == false)
        #expect(encoded.contains("ctrl") == false)
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
                pane: pane,
                direction: .horizontal,
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
    }

    @Test("pane content reads record only method and target")
    func paneContentReadsHaveNoContentField() throws {
        let requests: [IpcRequest] = [
            .paneRead(pane: pane, lineLimit: 20),
            .paneRows(pane: pane),
            .paneTape(pane: pane, follow: false, start: .now, mode: .reconstructible),
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
}
