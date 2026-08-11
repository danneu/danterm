// App-owned probes for the macOS permissions that affect DanTerm's alerts and
// developer-terminal workflows. Probes stay here so TCC evaluates DanTerm.app,
// never whichever terminal happened to invoke the `danterm` helper.
import Foundation
import Darwin
@preconcurrency import UserNotifications
import DanTermProtocol

/// Injects each ambient permission operation so composition is testable without changing TCC.
struct DoctorPermissionProbeDependencies {
    var notifications: @MainActor () async -> DoctorFacts.PermissionState
    var fullDiskAccess: @MainActor () -> DoctorFacts.PermissionState
    var developerTools: @MainActor () async -> DoctorFacts.PermissionState

    static let live = DoctorPermissionProbeDependencies(
        notifications: notificationPermissionState,
        fullDiskAccess: fullDiskAccessPermissionState,
        developerTools: developerToolsPermissionState
    )
}

/// Gathers one coherent app-side permission snapshot for a pending doctor request.
@MainActor
struct DoctorPermissionProber {
    var dependencies: DoctorPermissionProbeDependencies = .live

    func gather() async -> DoctorFacts.Permissions {
        let notifications = await dependencies.notifications()
        let fullDiskAccess = dependencies.fullDiskAccess()
        let developerTools = await dependencies.developerTools()
        return DoctorFacts.Permissions(
            notifications: notifications,
            fullDiskAccess: fullDiskAccess,
            developerTools: developerTools
        )
    }
}

/// Reads DanTerm's supported notification status without requesting authorization.
@MainActor
private func notificationPermissionState() async -> DoctorFacts.PermissionState {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
        return settings.alertSetting == .disabled ? .denied : .granted
    case .denied, .notDetermined:
        return .denied
    @unknown default:
        return .unknown
    }
}

/// Tests a stable TCC-protected file whose Unix ownership still permits this user to read it.
@MainActor
private func fullDiskAccessPermissionState() -> DoctorFacts.PermissionState {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        .path
    let descriptor = Darwin.open(path, O_RDONLY)
    guard descriptor < 0 else {
        Darwin.close(descriptor)
        return .granted
    }
    return errno == EPERM || errno == EACCES ? .denied : .unknown
}

/// Uses LLDB against a disposable child because macOS exposes no Developer Tools status API.
@MainActor
private func developerToolsPermissionState() async -> DoctorFacts.PermissionState {
    let lldbPath = "/usr/bin/lldb"
    guard FileManager.default.isExecutableFile(atPath: lldbPath) else { return .unknown }

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    do {
        try child.run()
    } catch {
        return .unknown
    }

    return await withCheckedContinuation { continuation in
        let debugger = Process()
        debugger.executableURL = URL(fileURLWithPath: lldbPath)
        debugger.arguments = [
            "-b", "-p", String(child.processIdentifier),
            "-o", "detach", "-o", "quit",
        ]
        debugger.standardInput = FileHandle.nullDevice
        debugger.standardOutput = FileHandle.nullDevice
        debugger.standardError = FileHandle.nullDevice
        debugger.terminationHandler = { process in
            if child.isRunning { child.terminate() }
            continuation.resume(returning: process.terminationStatus == 0 ? .granted : .denied)
        }
        do {
            try debugger.run()
        } catch {
            if child.isRunning { child.terminate() }
            continuation.resume(returning: .unknown)
        }
    }
}
