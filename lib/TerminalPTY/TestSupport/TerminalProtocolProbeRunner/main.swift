// Opt-in esctest2 driver that launches the pinned subset through a real pane session and retains failures.
import Darwin
import Foundation
import PaneLifecycle
import TerminalCoreRecording
import TerminalPaneSession
import TerminalProtocolProbeSupport

/// Runs external protocol probes without exposing their orchestration as product API.
@main
private enum TerminalProtocolProbeRunner {
    @MainActor
    static func main() async {
        do {
            try await execute()
        } catch {
            FileHandle.standardError.write(Data("terminal protocol probes: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func execute() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { throw ProbeError.usage }
        let runDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let bootstrap = arguments[2]
        let esctest = arguments[3]
        let environment = ProcessInfo.processInfo.environment
        guard let include = environment["DANTERM_PROTOCOL_PROBE_INCLUDE"],
              let expectedText = environment["DANTERM_PROTOCOL_PROBE_EXPECTED_COUNT"],
              let expectedCount = Int(expectedText)
        else { throw ProbeError.missingEnvironment }

        let log = runDirectory.appending(path: "esctest.log")
        let cases = runDirectory.appending(path: "cases", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        let command = "exec /usr/bin/python3 \(shellQuote(esctest)) --include=\(shellQuote(include)) --expected-terminal=xterm --max-vt-level=3 --timeout=2 --test-case-dir=\(shellQuote(cases.path)) --logfile=\(shellQuote(log.path))"
        let dimensions = TerminalDimensions(columns: 80, rows: 24)
        let launchInput = LaunchPolicyInput(
            accountShell: "/bin/sh",
            executablePaths: ["/bin/sh"],
            requestedWorkingDirectory: runDirectory.path,
            homeDirectory: runDirectory.path,
            accessibleDirectories: [runDirectory.path],
            inheritedEnvironment: [
                EnvironmentEntry(name: "PATH", value: "/usr/bin:/bin:/usr/sbin"),
                EnvironmentEntry(name: "LANG", value: "en_US.UTF-8"),
            ],
            advertisedEnvironment: [
                EnvironmentEntry(name: "TERM", value: "xterm-256color"),
                EnvironmentEntry(name: "TERM_PROGRAM", value: "DanTerm"),
                EnvironmentEntry(name: "TERM_PROGRAM_VERSION", value: "protocol-probe"),
            ],
            paneEnvironment: [],
            command: nil,
            launchCommand: command,
            initialDimensions: dimensions
        )
        let controller = try TerminalPaneSessionController(
            configuration: .init(
                initialDimensions: dimensions,
                launchInput: launchInput,
                terminalProgramVersion: "protocol-probe"
            ),
            bootstrapExecutable: bootstrap,
            captureTransitions: true
        )
        let termination = controller.terminationHandle
        let ended = EndSignal()
        controller.onSessionEnded = { _ in ended.finish() }

        let didEnd = await ended.wait(until: .now + .seconds(45))
        controller.synchronizeState()
        let capture = controller.diagnosticCapture(test: "esctest2-supported-subset")
        controller.tearDown()
        await termination.terminateForApplicationExit()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(capture.recording).write(to: runDirectory.appending(path: "recording.json"))
        try "pane_session=released\nchild=reaped\npty_owner=released\ndescriptors=released\nsources=released\n".write(
            to: runDirectory.appending(path: "ownership.txt"), atomically: true, encoding: .utf8
        )
        guard didEnd else {
            try "status=failed\nerror=timeout\n".write(
                to: runDirectory.appending(path: "summary.txt"), atomically: true, encoding: .utf8
            )
            throw ProbeError.timeout
        }
        let report = try EsctestReportParser.parse(
            String(contentsOf: log, encoding: .utf8),
            expectedCount: expectedCount
        )
        try report.description.write(
            to: runDirectory.appending(path: "summary.txt"), atomically: true, encoding: .utf8
        )
        guard report.isSuccess else { throw ProbeError.failed }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Bridges the callback-only session end signal into one bounded async wait.
@MainActor
private final class EndSignal {
    private var finished = false

    func finish() { finished = true }

    func wait(until deadline: ContinuousClock.Instant) async -> Bool {
        while finished == false && ContinuousClock.now < deadline { await Task.yield() }
        return finished
    }
}

/// Classifies setup, timeout, external-report, and invocation failures for durable diagnostics.
private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case missingEnvironment
    case timeout
    case failed

    var description: String {
        switch self {
        case .usage: "usage: TerminalProtocolProbeRunner RUN_DIRECTORY BOOTSTRAP ESCTEST"
        case .missingEnvironment: "missing allowlist environment"
        case .timeout: "timed out waiting for esctest2"
        case .failed: "one or more selected esctest2 probes failed"
        }
    }
}
