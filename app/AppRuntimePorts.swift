// Ambient effects interpreted by AppRuntime. Runtime-owned state does not belong here.
import Cocoa
import DanTermProtocol
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

/// Makes each system effect behind a Command arm replaceable without changing the Elm loop.
struct AppRuntimePorts {
    var createTerminalSession: @MainActor (TerminalSessionRequest) -> (any TerminalSession)?
    var deliverNotification: @MainActor (UNNotificationRequest) -> Void
    var selectExportDestination: @MainActor (
        NSWindow?,
        @escaping @MainActor (URL?) -> Void
    ) -> Void
    var readDoctorAppFacts: @MainActor (String) async -> DoctorFacts.AppFacts
    var terminateApp: @MainActor () -> Void
    var activateApp: @MainActor () -> Void

    /// Connects the interpreter to macOS and the concrete terminal backend in production.
    static func live(
        terminalBackend: SwiftTerminalBackend,
        notificationAuthorizationPolicy: NotificationAuthorizationPolicy = .requestIfNeeded
    ) -> Self {
        Self(
            createTerminalSession: terminalBackend.createSession,
            deliverNotification: { request in
                deliverLiveNotification(
                    request,
                    authorizationPolicy: notificationAuthorizationPolicy
                )
            },
            selectExportDestination: { window, completion in
                guard let window else {
                    completion(nil)
                    return
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "danterm-state.json"
                panel.allowedContentTypes = [.json]
                panel.canCreateDirectories = true
                panel.beginSheetModal(for: window) { response in
                    completion(response == .OK ? panel.url : nil)
                }
            },
            readDoctorAppFacts: { configFilePath in
                let permissions = await DoctorPermissionProber().gather()
                return DoctorFacts.AppFacts(
                    permissions: permissions,
                    configFilePath: configFilePath,
                    configFont: gatherDoctorConfigFontFacts(
                        configFilePath: configFilePath,
                        fileManager: .default,
                        resolveInstalledFontFamily: resolveInstalledFontFamily(named:)
                    )
                )
            },
            terminateApp: {
                (NSApp.delegate as? AppDelegate)?.quitConfirmed = true
                NSApp.terminate(nil)
            },
            activateApp: {
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }
}

/// Applies DanTerm's authorization policy before handing one alert to Notification Center.
private func deliverLiveNotification(
    _ request: UNNotificationRequest,
    authorizationPolicy: NotificationAuthorizationPolicy
) {
    let center = UNUserNotificationCenter.current()
    let permitsAuthorizationRequest = authorizationPolicy.permitsRequest
    // Notification Center invokes these completions off the main actor. They capture only
    // immutable request policy and never reach runtime-owned state.
    center.getNotificationSettings { settings in
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            center.add(request) { error in
                if let error {
                    print("Failed to enqueue notification: \(error)")
                }
            }
        case .notDetermined:
            guard permitsAuthorizationRequest else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    print("Notification authorization request failed: \(error)")
                    return
                }
                guard granted else { return }
                center.add(request) { error in
                    if let error {
                        print("Failed to enqueue notification: \(error)")
                    }
                }
            }
        case .denied:
            break
        @unknown default:
            break
        }
    }
}
