// Build-time bridge from a development slot number to the launch facts the slot
// launcher must not derive for itself: DanTermProtocol's canonical identity, naming,
// and socket-path seam, plus the standard per-user config path a `--tailnet` launch
// seeds a slot's own config from. The launcher is a Python process, so a path it
// spelled would be a second resolution no Swift lint can see. It is bundled only in
// development apps.
import DanTermProtocol
import DanTermSupport
import Foundation

guard CommandLine.arguments.count == 2,
      let slot = Int(CommandLine.arguments[1]),
      let identity = DanTermInstanceIdentity(developmentSlot: slot)
else {
    fputs("usage: DanTermLaunchFactsTool <development-slot>\n", stderr)
    exit(2)
}

// The slot launcher stamps CFBundleIconName and swaps the asset catalog, so it
// needs the icon name from the same seam that produced every other identity
// field. Every slot the guard above admitted names one, so this cannot fail
// unless that invariant breaks.
guard let iconName = identity.iconName else {
    fputs("DanTermLaunchFactsTool: slot \(slot) names no icon\n", stderr)
    exit(3)
}

let payload: [String: Any] = [
    "slot": slot,
    "bundleId": identity.bundleIdentifier,
    "displayName": identity.displayName,
    "executableName": identity.executableName,
    "iconName": iconName,
    "socketPath": userControlSocketPath(identity: identity).path,
    // Reported, not used here: this tool owns no config file. It is the same
    // bare-executable carve-out `userControlSocketPath` already has, and it resolves
    // the home the same way the `danterm` CLI does so an overridden home reaches both.
    "standardConfigPath": DanTermConfigPaths.standardConfigFilePath(
        home: danTermProcessHomeDirectory(environment: ProcessInfo.processInfo.environment).path
    ),
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
