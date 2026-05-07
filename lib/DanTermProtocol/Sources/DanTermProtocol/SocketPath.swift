// Shared control-socket path resolution for the DanTerm IPC protocol.
import Foundation

public func controlSocketPath(
    bundleId: String = Bundle.main.bundleIdentifier ?? "com.danneu.danterm"
) -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(bundleId, isDirectory: true)
        .appendingPathComponent("control.sock", isDirectory: false)
}
