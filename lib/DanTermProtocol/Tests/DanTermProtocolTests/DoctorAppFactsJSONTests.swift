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
            configFilePath: "/slot-3/config/slot-3.json"
        )

        #expect(DoctorFacts.AppFacts(jsonValue: facts.jsonValue) == facts)
    }

    // Intent: an app-facts reply that names no config file decodes as no reply.
    // Why it exists: the config path is the whole point of asking, and doctor's
    //   fallback is the standard file. Accepting a reply without one would make
    //   doctor report the standard file while claiming the instance named it.
    @Test("an app-facts reply missing either half decodes as nothing")
    func incompleteAppFactsDecodeAsNothing() {
        let permissions = DoctorFacts.Permissions.unavailable

        #expect(DoctorFacts.AppFacts(jsonValue: .object([:])) == nil)
        #expect(DoctorFacts.AppFacts(jsonValue: .object([
            "permissions": permissions.jsonValue,
        ])) == nil)
        #expect(DoctorFacts.AppFacts(jsonValue: .object([
            "configFilePath": .string("/slot-3/config/slot-3.json"),
        ])) == nil)
    }
}
