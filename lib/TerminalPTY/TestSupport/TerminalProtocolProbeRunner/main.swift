// Opt-in external protocol driver that launches pinned probes through a real pane session.
import Darwin
import Foundation
import PaneProcessLifecycle
import TerminalCore
import TerminalCoreRecording
import TerminalPaneSession
import TerminalProtocolProbeSupport
import TerminalPTYHost
import TerminalPTYWaitSupport

/// The one identity this runner advertises, so the child environment it hand-builds
/// and the terminal's query replies cannot name two different products.
private let productIdentity = TerminalProductIdentity(
    name: "DanTerm",
    version: "protocol-probe"
)

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
        guard arguments.count == 4 || arguments.count == 5 else { throw ProbeError.usage }
        let runDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let bootstrap = arguments[2]
        let environment = ProcessInfo.processInfo.environment
        let probe = try probeConfiguration(arguments: arguments, environment: environment)

        let log = runDirectory.appending(path: probe.logName)
        let cases = runDirectory.appending(path: "cases", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        let command = probe.command(log: log, cases: cases)
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
                EnvironmentEntry(name: "TERM_PROGRAM", value: productIdentity.name),
                EnvironmentEntry(name: "TERM_PROGRAM_VERSION", value: productIdentity.version),
            ],
            paneEnvironment: [],
            command: nil,
            launchCommand: command,
            initialDimensions: dimensions
        )
        let host = try TerminalPTYHost(
            launchInput: launchInput,
            bootstrapExecutable: bootstrap,
            productIdentity: productIdentity,
            flightTapeConfiguration: .complete
        )
        let controller = TerminalPaneSessionController(host: host)
        let termination = controller.terminationHandle
        let ended = EndSignal()
        controller.onSessionEnded = { _ in ended.finish() }

        let didEnd = await ended.wait(until: .now + .seconds(45))
        controller.synchronizeState()
        let capture = controller.diagnosticCapture(test: probe.captureName)
        controller.tearDown()
        // The record below is a claim that the pane released everything and reaped
        // its child, and only quiescence supports it. Awaiting quiescence through a
        // continuation would park here for good when it never comes, and the wrapper
        // script imposes no timeout that would end the run from outside.
        let quiesced = await termination.quiesced(within: .seconds(30))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(capture.recording).write(to: runDirectory.appending(path: "recording.json"))
        let state = quiesced ? "released" : "live"
        try "pane_session=\(state)\nchild=\(quiesced ? "reaped" : "live")\npty_owner=\(state)\ndescriptors=\(state)\nsources=\(state)\n".write(
            to: runDirectory.appending(path: "ownership.txt"), atomically: true, encoding: .utf8
        )
        // The probe's own verdict first: a probe that never ended explains a pane that
        // never quiesced, so reporting the other way round would name the symptom.
        guard didEnd else {
            try "status=failed\nerror=timeout\n".write(
                to: runDirectory.appending(path: "summary.txt"), atomically: true, encoding: .utf8
            )
            throw ProbeError.timeout
        }
        guard quiesced else {
            try "status=failed\nerror=quiescence timeout\n".write(
                to: runDirectory.appending(path: "summary.txt"), atomically: true, encoding: .utf8
            )
            throw ProbeError.timeout
        }
        let result = try probe.parse(String(contentsOf: log, encoding: .utf8))
        try result.summary.write(
            to: runDirectory.appending(path: "summary.txt"), atomically: true, encoding: .utf8
        )
        guard result.isSuccess else { throw ProbeError.failed }
    }

    private static func probeConfiguration(
        arguments: [String],
        environment: [String: String]
    ) throws -> ProbeConfiguration {
        if arguments.count == 4 {
            guard let include = environment["DANTERM_PROTOCOL_PROBE_INCLUDE"],
                  let expectedText = environment["DANTERM_PROTOCOL_PROBE_EXPECTED_COUNT"],
                  let expectedCount = Int(expectedText)
            else { throw ProbeError.missingEnvironment }
            return .esctest(program: arguments[3], include: include, expectedCount: expectedCount)
        }

        guard let sessionName = environment["DANTERM_VTTEST_SESSION"],
              let session = VttestSession(rawValue: sessionName)
        else { throw ProbeError.missingEnvironment }
        return .vttest(program: arguments[3], replay: arguments[4], session: session)
    }

    fileprivate static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}

/// Bridges the callback-only session end signal into one bounded async wait.
@MainActor
private final class EndSignal {
    private var finished = false

    func finish() { finished = true }

    func wait(until deadline: ContinuousClock.Instant) async -> Bool {
        while finished == false && ContinuousClock.now < deadline {
            // Sleeping, not yielding: a spin here competes with the probe it awaits.
            // A cancelled sleep ends the wait rather than leaving an unpaced loop.
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
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
        case .usage: "usage: TerminalProtocolProbeRunner RUN_DIRECTORY BOOTSTRAP PROGRAM [VTTEST_REPLAY]"
        case .missingEnvironment: "missing external-probe environment"
        case .timeout: "timed out waiting for external protocol probe"
        case .failed: "one or more selected external protocol probes failed"
        }
    }
}

/// Keeps suite-specific commands and report semantics outside pane-session orchestration.
private enum ProbeConfiguration {
    case esctest(program: String, include: String, expectedCount: Int)
    case vttest(program: String, replay: String, session: VttestSession)

    var logName: String {
        switch self {
        case .esctest: "esctest.log"
        case .vttest: "vttest.log"
        }
    }

    var captureName: String {
        switch self {
        case .esctest: "esctest2-supported-subset"
        case let .vttest(_, _, session): "vttest-\(session.rawValue)"
        }
    }

    func command(log: URL, cases: URL) -> String {
        switch self {
        case let .esctest(program, include, _):
            "exec /usr/bin/python3 \(TerminalProtocolProbeRunner.shellQuote(program)) --include=\(TerminalProtocolProbeRunner.shellQuote(include)) --expected-terminal=xterm --max-vt-level=3 --timeout=2 --test-case-dir=\(TerminalProtocolProbeRunner.shellQuote(cases.path)) --logfile=\(TerminalProtocolProbeRunner.shellQuote(log.path))"
        case let .vttest(program, replay, _):
            "exec \(TerminalProtocolProbeRunner.shellQuote(program)) 24x80.80 -u -c \(TerminalProtocolProbeRunner.shellQuote(replay)) -l \(TerminalProtocolProbeRunner.shellQuote(log.path))"
        }
    }

    func parse(_ text: String) throws -> (summary: String, isSuccess: Bool) {
        switch self {
        case let .esctest(_, _, expectedCount):
            let report = try EsctestReportParser.parse(text, expectedCount: expectedCount)
            return (report.description, report.isSuccess)
        case let .vttest(_, _, session):
            let report = try VttestReportParser.parse(text, session: session)
            return (report.description, report.isSuccess)
        }
    }
}
