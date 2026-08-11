// Round-trip coverage for the typed doctor permission IPC payload.
import Testing
@testable import DanTermProtocol

struct DoctorPermissionsJSONTests {
    @Test("permission facts round trip through JSON value")
    func permissionFactsRoundTrip() {
        let permissions = DoctorFacts.Permissions(
            notifications: .granted,
            fullDiskAccess: .denied,
            developerTools: .unavailable
        )

        #expect(DoctorFacts.Permissions(jsonValue: permissions.jsonValue) == permissions)
        #expect(DoctorFacts.Permissions(jsonValue: .object([:])) == nil)
    }
}
