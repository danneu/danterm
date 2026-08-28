// Round-trip coverage for the typed app-facts IPC payload `danterm doctor` reads.
import Testing
@testable import DanTermProtocol

struct DoctorAppFactsJSONTests {
    @Test("app facts round trip through JSON value")
    func appFactsRoundTrip() {
        let facts = DoctorFacts.AppFacts(
            permissions: DoctorFacts.Permissions(
                notifications: .granted,
                fullDiskAccess: .denied,
                developerTools: .unavailable
            ),
            configFilePath: "/slot-3/config/slot-3.json",
            configFont: .notInstalled(requested: "Slot Mono")
        )

        #expect(DoctorFacts.AppFacts(jsonValue: facts.jsonValue) == facts)
    }

    // Intent: an incomplete app-facts reply decodes as no instance answer.
    // Why it exists: accepting a path without its verdict would let the CLI invent
    //   an instance-owned font result from local state.
    @Test("an app-facts reply missing any required fact decodes as nothing")
    func incompleteAppFactsDecodeAsNothing() {
        let permissions = DoctorFacts.Permissions.unavailable

        #expect(DoctorFacts.AppFacts(jsonValue: .object([:])) == nil)
        #expect(DoctorFacts.AppFacts(jsonValue: .object([
            "permissions": permissions.jsonValue,
        ])) == nil)
        #expect(DoctorFacts.AppFacts(jsonValue: .object([
            "configFilePath": .string("/slot-3/config/slot-3.json"),
        ])) == nil)
        #expect(DoctorFacts.AppFacts(jsonValue: .object([
            "permissions": permissions.jsonValue,
            "configFilePath": .string("/slot-3/config/slot-3.json"),
        ])) == nil)
    }
}
