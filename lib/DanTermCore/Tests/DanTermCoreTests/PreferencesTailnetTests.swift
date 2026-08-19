// Pins the pure half of the Preferences panel's read-only tailnet section: the
// committed config base, this instance's derived endpoint, and the live listener
// status, each projected as the finished sentence the panel shows. The section is
// read-only because the listener is launch-frozen, so the projection has to keep
// the committed config and the running listener apart -- a config edit after
// launch must read as "next launch", not as the current endpoint. The AppKit rows
// these values drive live in the UI harness (PreferencesPanelTests).
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct PreferencesTailnetTests {
    private let endpoint = DanTermTailnetEndpoint(
        base: "100.64.0.1:7000",
        offset: 1,
        address: "100.64.0.1",
        port: 7001
    )

    private func projection(
        config: DanTermTailnetConfig?,
        status: DanTermTailnetStatus
    ) throws -> PreferencesPanelProjection {
        var model = makeModel()
        model.config.tailnet = config
        model.tailnetStatus = status
        _ = update(&model, .preferencesOpened(installedFontFamilies: []))
        return try #require(desiredPreferencesPanel(in: model))
    }

    @Test("an instance with no tailnet config names every field as absent")
    func absentConfigProjectsAbsentFields() throws {
        let projection = try projection(
            config: nil,
            status: .disabled(reason: "no tailnet endpoint is configured")
        )

        #expect(projection.tailnetConfiguredText == "Not configured")
        #expect(projection.tailnetEndpointText == "None")
        #expect(projection.tailnetStatusText == "Disabled -- no tailnet endpoint is configured")
    }

    @Test("a bound listener shows its base, its derived endpoint, and that it is serving")
    func listeningProjectsEndpoint() throws {
        let projection = try projection(
            config: DanTermTailnetConfig(listen: "100.64.0.1:7000", admittedNodeIds: ["nodeA"]),
            status: .listening(endpoint: endpoint)
        )

        #expect(projection.tailnetConfiguredText == "100.64.0.1:7000")
        #expect(projection.tailnetEndpointText == "100.64.0.1:7001")
        #expect(projection.tailnetStatusText == "Listening")
    }

    @Test("a listener that has not bound yet shows the endpoint it wants and why it failed")
    func waitingProjectsReason() throws {
        let projection = try projection(
            config: DanTermTailnetConfig(listen: "100.64.0.1:7000", admittedNodeIds: ["nodeA"]),
            status: .waiting(endpoint: endpoint, reason: "no local interface holds 100.64.0.1")
        )

        #expect(projection.tailnetEndpointText == "100.64.0.1:7001")
        #expect(
            projection.tailnetStatusText
                == "Waiting -- no local interface holds 100.64.0.1"
        )
    }

    // A config edit after launch never moves the running listener, so the panel
    // has to show the two apart: the config row follows the edit while the
    // endpoint row keeps the base the listener froze at launch.
    @Test("an edited config diverges from the listener the instance is running")
    func editedConfigDivergesFromTheRunningListener() throws {
        let projection = try projection(
            config: DanTermTailnetConfig(listen: "100.64.0.1:9000", admittedNodeIds: ["nodeA"]),
            status: .listening(endpoint: endpoint)
        )

        #expect(projection.tailnetConfiguredText == "100.64.0.1:9000")
        #expect(projection.tailnetEndpointText == "100.64.0.1:7001")
    }
}
