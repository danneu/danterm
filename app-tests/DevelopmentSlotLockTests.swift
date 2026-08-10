// Verifies that a launcher-held development slot lock stays app-owned instead of
// leaking through later execs into pane processes.
import Darwin
import Testing
@testable import DanTerm

struct DevelopmentSlotLockTests {
    @Test("development slot lock closes on child exec")
    func developmentSlotLockClosesOnExec() throws {
        // Intent: the app retains its inherited slot descriptor, but every later
        //   executable launched from the app closes that descriptor automatically.
        // Why it exists: a pane child retaining the lock could keep a slot occupied
        //   after SIGKILL has already ended the owning DanTerm app.
        // Scenario: the direct-exec launcher hands its claim to DanTerm before the
        //   app begins launching shells and terminal applications.
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        try configureDevelopmentSlotLock(arguments: [
            "DanTerm Dev (3)",
            "--development-slot-lock-fd=\(descriptors[0])",
        ])

        #expect(fcntl(descriptors[0], F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
    }
}
