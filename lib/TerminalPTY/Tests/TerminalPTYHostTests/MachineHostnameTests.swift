// Pins the machine-hostname seam to the same value the shells put in their OSC 7 reports.
import Foundation
import Testing
@testable import TerminalPTYHost

@Suite("Machine hostname seam")
struct MachineHostnameTests {
    @Test("the seam reports the POSIX hostname the shells read, not the mDNS spelling")
    func seamMatchesPOSIXHostname() throws {
        // Intent: `MachineHostname.posix` equals what `hostname(1)` prints -- the value
        //   fish, zsh, and bash interpolate into `file://<host>/...`.
        // Why it exists: the app previously read `ProcessInfo.processInfo.hostName`, whose
        //   `.local` suffix never matched a shell report, so every pane's cwd stayed nil.
        //   Asserting against an independent route rather than the string's shape keeps a
        //   legitimately fully-qualified POSIX hostname from failing this.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/hostname")
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let expected = try #require(String(data: data, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(!expected.isEmpty)
        #expect(MachineHostname.posix == expected)
    }
}
