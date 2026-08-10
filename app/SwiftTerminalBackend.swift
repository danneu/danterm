// Process-wide Swift terminal backend: gathers launch facts, creates AppKit
// session adapters, and retains native teardown handles through app exit.
import Cocoa
import DanTermProtocol
import Darwin
import PaneLifecycle
#if DANTERM_TERMINAL_CHARACTERIZATION
import TerminalCoreRecording
#endif
import TerminalPaneSession

/// Owns process-level Swift terminal launch and teardown policy outside the Elm runtime.
@MainActor
final class SwiftTerminalBackend {
    private let bundle: Bundle
    private let bootstrapExecutable: String
    private let recordsFlightTape: Bool
    #if DANTERM_TERMINAL_CHARACTERIZATION
    private let recordingDirectory: URL?
    #endif
    private let activeHosts = TerminalPaneTerminationRegistry()

    /// Whether the bundled PTY bootstrap helper is present; nothing can launch without it.
    var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: bootstrapExecutable)
    }

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        bootstrapExecutable = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/PTYSessionBootstrap")
            .path
        recordsFlightTape = DanTermBundleCapabilities.recordsFlightTape(
            infoDictionary: bundle.infoDictionary
        )
        #if DANTERM_TERMINAL_CHARACTERIZATION
        if let path = ProcessInfo.processInfo.environment["DANTERM_PTY_RECORDING_DIR"],
           path.isEmpty == false {
            recordingDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            recordingDirectory = nil
        }
        #endif
    }

    /// Builds one pane's terminal session, or nil when the child process cannot start.
    func createSession(_ request: TerminalSessionRequest) -> (any TerminalSession)? {
        let theme = request.themeName.flatMap(ThemeCatalog.shared.renderTheme(named:)) ?? .dark
        let launchRequest = TerminalPaneLaunchRequest(
            workingDirectory: request.workingDirectory,
            command: request.command,
            launchCommand: request.launchCommand,
            environment: request.environment.map(EnvironmentEntry.init(name:value:))
        )
        let configuration = assembleTerminalPaneLaunch(
            request: launchRequest,
            facts: Self.launchFacts(
                bundle: bundle,
                requestedWorkingDirectory: request.workingDirectory
            )
        )
        let controller: TerminalPaneSessionController
        do {
            #if DANTERM_TERMINAL_CHARACTERIZATION
            controller = try TerminalPaneSessionController(
                configuration: configuration,
                bootstrapExecutable: bootstrapExecutable,
                theme: theme,
                captureTransitions: recordingDirectory != nil,
                recordsFlightTape: recordsFlightTape
            )
            #else
            controller = try TerminalPaneSessionController(
                configuration: configuration,
                bootstrapExecutable: bootstrapExecutable,
                theme: theme,
                recordsFlightTape: recordsFlightTape
            )
            #endif
        } catch {
            return nil
        }

        let id = UUID()
        activeHosts.retain(controller.terminationHandle)
        #if DANTERM_TERMINAL_CHARACTERIZATION
        return SwiftTerminalSessionView(
            controller: controller,
            fontSize: request.fontSize,
            fontFamily: request.fontFamily,
            onSessionEnded: { [weak self, weak controller] result in
                guard case .exited = result, let self, let controller else { return }
                self.writeRecording(from: controller, id: id)
            }
        )
        #else
        return SwiftTerminalSessionView(
            controller: controller,
            fontSize: request.fontSize,
            fontFamily: request.fontFamily
        )
        #endif
    }

    /// Runs the bounded process teardown after the final checkpoint is captured.
    func terminateForApplicationExit() {
        activeHosts.requestShutdownAndWait()
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

    /// Resolves app-owned bundle facts and ambient account state at the child-launch seam.
    static func launchFacts(
        bundle: Bundle,
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
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let shellIntegrationDirectory = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/shell-integration", isDirectory: true)
            .path
        return TerminalPaneLaunchFacts(
            accountShell: accountShell,
            executablePaths: executablePaths,
            homeDirectory: homeDirectory,
            accessibleDirectories: accessibleDirectories,
            inheritedEnvironment: inheritedEnvironment,
            terminalProgramVersion: version,
            shellIntegrationDirectory: shellIntegrationDirectory
        )
    }

    private static func accountShell(environment: [String: String]) -> String? {
        if let record = getpwuid(getuid()), record.pointee.pw_shell.pointee != 0 {
            return String(cString: record.pointee.pw_shell)
        }
        return environment["SHELL"]
    }

}
