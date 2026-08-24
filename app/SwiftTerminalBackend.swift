// Process-wide Swift terminal backend: gathers launch facts, creates AppKit
// session adapters, and retains native teardown handles through app exit.
import Cocoa
import DanTermProtocol
import Darwin
import PaneProcessLifecycle
#if DANTERM_TERMINAL_CHARACTERIZATION
import TerminalCoreRecording
#endif
import TerminalPTYHost
import TerminalPaneSession
import xlocale

/// Owns process-level Swift terminal launch and teardown policy outside the Elm runtime.
@MainActor
final class SwiftTerminalBackend {
    private let bundle: Bundle
    private let bootstrapExecutable: String
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
            .appendingPathComponent(BundleLayout.Paths.ptySessionBootstrap)
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

    /// Builds one pane's terminal session, or nil when the child process cannot start.
    func createSession(_ request: TerminalSessionRequest) -> (any TerminalSession)? {
        let theme = request.themeName.flatMap(ThemeCatalog.shared.renderTheme(named:)) ?? .dark
        let launchRequest = TerminalPaneLaunchRequest(
            workingDirectory: request.workingDirectory,
            command: request.command,
            launchCommand: request.launchCommand,
            environment: request.environment.map(EnvironmentEntry.init(name:value:)),
            initialDimensions: request.gridOverride.map {
                TerminalDimensions(columns: $0.columns, rows: $0.rows)
            }
        )
        let configuration = assembleTerminalPaneLaunch(
            request: launchRequest,
            facts: Self.launchFacts(
                bundle: bundle,
                requestedWorkingDirectory: request.workingDirectory,
                localeFallbackEnabled: request.localeFallbackEnabled
            )
        )
        let onLaunchInputCompletion: (@MainActor @Sendable (
            PaneInputSubmissionResult
        ) -> Void)?
        if let completion = request.onLaunchInputCompletion {
            onLaunchInputCompletion = { result in
                completion(Self.inputResult(result))
            }
        } else {
            onLaunchInputCompletion = nil
        }
        let controller: TerminalPaneSessionController
        do {
            #if DANTERM_TERMINAL_CHARACTERIZATION
            let host = try TerminalPTYHost(
                launchInput: configuration.launchInput,
                initialGridPinned: configuration.initialGridPinned,
                bootstrapExecutable: bootstrapExecutable,
                programVersion: configuration.terminalProgramVersion,
                defaultColors: theme.defaultColors,
                recordsCompleteTape: recordingDirectory != nil
            )
            controller = TerminalPaneSessionController(
                host: host,
                theme: theme,
                onLaunchInputCompletion: onLaunchInputCompletion
            )
            #else
            let host = try TerminalPTYHost(
                launchInput: configuration.launchInput,
                initialGridPinned: configuration.initialGridPinned,
                bootstrapExecutable: bootstrapExecutable,
                programVersion: configuration.terminalProgramVersion,
                defaultColors: theme.defaultColors
            )
            controller = TerminalPaneSessionController(
                host: host,
                theme: theme,
                onLaunchInputCompletion: onLaunchInputCompletion
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
            optionAsAlt: request.optionAsAlt,
            gridOverride: request.gridOverride,
            onSessionEnded: { [weak self, weak controller] result in
                guard case .exited = result, let self, let controller else { return }
                self.writeRecording(from: controller, id: id)
            }
        )
        #else
        return SwiftTerminalSessionView(
            controller: controller,
            fontSize: request.fontSize,
            fontFamily: request.fontFamily,
            optionAsAlt: request.optionAsAlt,
            gridOverride: request.gridOverride
        )
        #endif
    }

    private static func inputResult(
        _ result: PaneInputSubmissionResult
    ) -> TerminalInputSubmissionResult {
        switch result {
        case .delivered: .delivered
        case .rejected(.bufferLimitExceeded): .rejected(.bufferLimitExceeded)
        case .rejected(.canonicalModeTimeout): .rejected(.canonicalModeTimeout)
        case .rejected(.launchFailed): .rejected(.launchFailed)
        case .rejected(.processEnded): .rejected(.processEnded)
        case .rejected(.writeFailed(let code)): .rejected(.writeFailed(code))
        }
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
        requestedWorkingDirectory: String?,
        localeFallbackEnabled: Bool,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalPaneLaunchFacts {
        let environment = scrubbedTerminalProcessEnvironment(processEnvironment)
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
            .appendingPathComponent(BundleLayout.Paths.shellIntegrationDirectory, isDirectory: true)
            .path
        let locale = Locale.current
        let localeFallback = localeFallbackEnabled ? Self.localeFallback(
            languageCode: locale.language.languageCode?.identifier,
            regionCode: locale.region?.identifier,
            accepts: Self.acceptsLocale
        ) : nil
        return TerminalPaneLaunchFacts(
            accountShell: accountShell,
            executablePaths: executablePaths,
            homeDirectory: homeDirectory,
            accessibleDirectories: accessibleDirectories,
            inheritedEnvironment: inheritedEnvironment,
            localeFallback: localeFallback,
            terminalProgramVersion: version,
            shellIntegrationDirectory: shellIntegrationDirectory
        )
    }

    /// Selects the first machine-supported UTF-8 locale without depending on ICU suffixes.
    static func localeFallback(
        languageCode: String?,
        regionCode: String?,
        accepts: (String) -> Bool
    ) -> String? {
        var candidates: [String] = []
        if let languageCode, languageCode.isEmpty == false,
           let regionCode, regionCode.isEmpty == false {
            candidates.append("\(languageCode)_\(regionCode).UTF-8")
        }
        if candidates.contains("en_US.UTF-8") == false {
            candidates.append("en_US.UTF-8")
        }
        return candidates.first(where: accepts)
    }

    /// Probes LC_CTYPE support through an isolated locale object owned by this call.
    static func acceptsLocale(_ identifier: String) -> Bool {
        guard let locale = newlocale(LC_CTYPE_MASK, identifier, nil) else { return false }
        freelocale(locale)
        return true
    }

    private static func accountShell(environment: [String: String]) -> String? {
        if let record = getpwuid(getuid()), record.pointee.pw_shell.pointee != 0 {
            return String(cString: record.pointee.pw_shell)
        }
        return environment["SHELL"]
    }

}
