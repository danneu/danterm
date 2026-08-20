// Build-time bridge from development slot numbers to DanTermProtocol's canonical
// identity, naming, and socket-path seam. It is bundled only in development apps.
import DanTermProtocol
import Foundation

guard CommandLine.arguments.count == 2,
      let slot = Int(CommandLine.arguments[1]),
      let identity = DanTermInstanceIdentity(developmentSlot: slot)
else {
    fputs("usage: DanTermInstanceIdentityTool <development-slot>\n", stderr)
    exit(2)
}

let payload: [String: Any] = [
    "slot": slot,
    "bundleId": identity.bundleIdentifier,
    "displayName": identity.displayName,
    "executableName": identity.executableName,
    "socketPath": userControlSocketPath(identity: identity).path,
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
