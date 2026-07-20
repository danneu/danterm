// Process-wide Swift terminal backend: gathers launch facts, creates AppKit
// session adapters, and retains native teardown handles through app exit.
import Cocoa
import Darwin
import PaneLifecycle
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
    private var activeHosts: [UUID: TerminalPaneTerminationHandle] = [:]

    var onEvent: ((TerminalBackendEvent) -> Void)?
    var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: bootstrapExecutable)
    }
    var preferences: GhosttyPrefs {
        GhosttyPrefs(theme: nil, fontSize: nil)
    }
    var configFilePath: String? { nil }

    init(bundle: Bundle = .main) {
        bootstrapExecutable = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/PTYSessionBootstrap")
            .path
    }

    func createSession(_ request: TerminalSessionRequest) -> (any TerminalSession)? {
        let launchRequest = TerminalPaneLaunchRequest(
            workingDirectory: request.workingDirectory,
            command: request.command,
            launchCommand: request.launchCommand,
            restoreCommandBehavior: Self.restoreBehavior(request.restoreCommandBehavior),
            environment: request.environment.map(EnvironmentEntry.init(name:value:))
        )
        let configuration = assembleTerminalPaneLaunch(
            request: launchRequest,
            facts: Self.launchFacts(requestedWorkingDirectory: request.workingDirectory)
        )
        guard let controller = try? TerminalPaneSessionController(
            configuration: configuration,
            bootstrapExecutable: bootstrapExecutable
        ) else {
            return nil
        }

        let id = UUID()
        activeHosts[id] = controller.terminationHandle
        controller.onTeardownCompleted = { [weak self] in
            self?.activeHosts.removeValue(forKey: id)
        }
        return SwiftTerminalSessionView(controller: controller)
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

    private static func launchFacts(
        requestedWorkingDirectory: String?
    ) -> TerminalPaneLaunchFacts {
        let environment = ProcessInfo.processInfo.environment
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

    private static func restoreBehavior(
        _ behavior: RestoreCommandBehavior
    ) -> PaneLifecycle.RestoreCommandBehavior {
        switch behavior {
        case .prefill: .prefill
        case .execute: .execute
        }
    }
}
