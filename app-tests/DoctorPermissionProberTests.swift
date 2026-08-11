// Tests for the app-owned permission probe that feeds `danterm doctor`.
import Testing
import DanTermProtocol

@testable import DanTerm

@Suite struct DoctorPermissionProberTests {
    @MainActor
    @Test("permission prober composes independently gathered states")
    func permissionProberComposesStates() async {
        let prober = DoctorPermissionProber(dependencies: DoctorPermissionProbeDependencies(
            notifications: { .granted },
            fullDiskAccess: { .denied },
            developerTools: { .unknown }
        ))

        let facts = await prober.gather()

        #expect(facts == DoctorFacts.Permissions(
            notifications: .granted,
            fullDiskAccess: .denied,
            developerTools: .unknown
        ))
    }
}
