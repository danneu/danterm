// Process-wide Swift terminal backend: gathers launch facts, creates AppKit
// session adapters, and retains native teardown handles through app exit.
import Cocoa
import Darwin
import PaneLifecycle
#if DANTERM_TERMINAL_CHARACTERIZATION
import TerminalCoreRecording
#endif
import TerminalPaneSession

/// Constructs the Swift engine adapter selected by DANTERM_TERMINAL_BACKEND=swift.
@MainActor
func makeSwiftTerminalBackend() -> any TerminalBackend {
    SwiftTerminalBackend()
}

/// Owns process-level Swift terminal launch and teardown policy outside the Elm runtime.
@MainActor
final class SwiftTerminalBackend: TerminalBackend {
    private static let applicationExitTimeout: DispatchTimeInterval = .seconds(2)

    private let bootstrapExecutable: String
    #if DANTERM_TERMINAL_CHARACTERIZATION
    private let recordingDirectory: URL?
    #endif
    private var activeHosts: [UUID: TerminalPaneTerminationHandle] = [:]

    var onEvent: ((TerminalBackendEvent) -> Void)?
    var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: bootstrapExecutable)
    }
    var preferences: GhosttyPrefs {
        GhosttyPrefs(theme: nil, fontSize: nil)
    }
    var configFilePath: String? { nil }
    var recoveryScheduling: TerminalRecoveryScheduling { .eventDriven }

    init(bundle: Bundle = .main) {
        bootstrapExecutable = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/PTYSessionBootstrap")
            .path
        #if DANTERM_TERMINAL_CHARACTERIZATION
        if let path = ProcessInfo.processInfo.environment["DANTERM_PTY_RECORDING_DIR"],
           path.isEmpty == false {
            recordingDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            recordingDirectory = nil
        }
        #endif
    }

    func createSession(_ request: TerminalSessionRequest) -> (any TerminalSession)? {
        let launchRequest = TerminalPaneLaunchRequest(
            workingDirectory: request.workingDirectory,
            command: request.command,
            launchCommand: request.launchCommand,
            environment: request.environment.map(EnvironmentEntry.init(name:value:))
        )
        let configuration = assembleTerminalPaneLaunch(
            request: launchRequest,
            facts: Self.launchFacts(requestedWorkingDirectory: request.workingDirectory)
        )
        let controller: TerminalPaneSessionController
        do {
            #if DANTERM_TERMINAL_CHARACTERIZATION
            controller = try TerminalPaneSessionController(
                configuration: configuration,
                bootstrapExecutable: bootstrapExecutable,
                machineHostname: ProcessInfo.processInfo.hostName,
                shellIntegrationToken: request.shellIntegrationToken,
                captureTransitions: recordingDirectory != nil
            )
            #else
            controller = try TerminalPaneSessionController(
                configuration: configuration,
                bootstrapExecutable: bootstrapExecutable,
                machineHostname: ProcessInfo.processInfo.hostName,
                shellIntegrationToken: request.shellIntegrationToken
            )
            #endif
        } catch {
            return nil
        }

        let id = UUID()
        activeHosts[id] = controller.terminationHandle
        controller.onTeardownCompleted = { [weak self] in
            self?.activeHosts.removeValue(forKey: id)
        }
        #if DANTERM_TERMINAL_CHARACTERIZATION
        return SwiftTerminalSessionView(
            controller: controller,
            onSessionEnded: { [weak self, weak controller] result in
                guard case .exited = result, let self, let controller else { return }
                self.writeRecording(from: controller, id: id)
            }
        )
        #else
        return SwiftTerminalSessionView(controller: controller)
        #endif
    }

    func setAppFocused(_ focused: Bool) {}
    func reloadConfig() {}

    func terminateForApplicationExit() {
        let handles = Array(activeHosts.values)
        guard handles.isEmpty == false else { return }
        let completion = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for handle in handles {
                    group.addTask { await handle.terminateForApplicationExit() }
                }
            }
            completion.signal()
        }
        _ = completion.wait(timeout: .now() + Self.applicationExitTimeout)
    }

    #if DANTERM_TERMINAL_CHARACTERIZATION
    /// Persists child-complete evidence before the close event can begin pane teardown.
    private func writeRecording(from controller: TerminalPaneSessionController, id: UUID) {
        guard let recordingDirectory,
              let recording = controller.capturedRecording(test: "milestone-4-viability")
        else { return }

        do {
            try FileManager.default.createDirectory(
                at: recordingDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(recording)
            data.append(0x0A)
            let url = recordingDirectory
                .appendingPathComponent("pane-\(id.uuidString.lowercased()).json")
            try data.write(to: url, options: .atomic)
        } catch {
            print("[characterization] Failed to write terminal recording: \(error)")
        }
    }
    #endif

    private static func launchFacts(
        requestedWorkingDirectory: String?
    ) -> TerminalPaneLaunchFacts {
        let environment = scrubbedTerminalProcessEnvironment(ProcessInfo.processInfo.environment)
        let accountShell = accountShell(environment: environment)
        let executablePaths = [accountShell, "/bin/zsh", "/bin/sh"]
            .compactMap { $0 }
            .reduce(into: [String]()) { paths, path in
                if paths.contains(path) == false,
                   FileManager.default.isExecutableFile(atPath: path) {
                    paths.append(path)
                }
            }
        let homeDirectory = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let accessibleDirectories = [requestedWorkingDirectory, homeDirectory, "/"]
            .compactMap { $0 }
            .reduce(into: [String]()) { paths, path in
                if paths.contains(path) == false,
                   access(path, R_OK | X_OK) == 0 {
                    paths.append(path)
                }
            }
        let inheritedEnvironment = environment
            .sorted { $0.key < $1.key }
            .map(EnvironmentEntry.init(name:value:))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return TerminalPaneLaunchFacts(
            accountShell: accountShell,
            executablePaths: executablePaths,
            homeDirectory: homeDirectory,
            accessibleDirectories: accessibleDirectories,
            inheritedEnvironment: inheritedEnvironment,
            terminalProgramVersion: version
        )
    }

    private static func accountShell(environment: [String: String]) -> String? {
        if let record = getpwuid(getuid()), record.pointee.pw_shell.pointee != 0 {
            return String(cString: record.pointee.pw_shell)
        }
        return environment["SHELL"]
    }

}
