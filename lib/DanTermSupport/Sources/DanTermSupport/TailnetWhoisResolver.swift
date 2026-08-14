// Tailscale peer identity resolution. Process execution is isolated behind an
// injected query, and parsing fails closed when any admitted identity fact is absent.
import Foundation

/// Holds the stable Tailscale identity minted once for an accepted peer.
struct TailnetPeerIdentity: Equatable, Sendable {
    let nodeId: String
    let user: String
    let machineName: String
}

/// Resolves a captured peer host through an injectable Tailscale whois query.
struct TailnetWhoisResolver: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case binaryUnavailable
        case timedOut
        case commandFailed(Int32)
        case invalidOutput
    }

    private let query: @Sendable (String) throws -> TailnetPeerIdentity

    /// Injects the whole query so admission tests never spawn a live process.
    init(_ query: @escaping @Sendable (String) throws -> TailnetPeerIdentity) {
        self.query = query
    }

    /// Uses the installed Tailscale CLI with a short fail-closed timeout.
    static let live = TailnetWhoisResolver { host in
        try parse(runWhois(peerHost: host))
    }

    /// Resolves only the host captured at accept time.
    func resolve(peerHost: String) throws -> TailnetPeerIdentity {
        try query(peerHost)
    }

    /// Parses the stable fields from Tailscale's JSON whois response.
    static func parse(_ data: Data) throws -> TailnetPeerIdentity {
        struct Response: Decodable {
            struct Node: Decodable {
                let stableId: String?
                let name: String?

                enum CodingKeys: String, CodingKey {
                    case stableId = "StableID"
                    case name = "Name"
                }
            }
            struct UserProfile: Decodable {
                let loginName: String?

                enum CodingKeys: String, CodingKey {
                    case loginName = "LoginName"
                }
            }
            let node: Node?
            let userProfile: UserProfile?

            enum CodingKeys: String, CodingKey {
                case node = "Node"
                case userProfile = "UserProfile"
            }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let nodeId = nonempty(response.node?.stableId),
              let rawMachineName = nonempty(response.node?.name),
              let user = nonempty(response.userProfile?.loginName)
        else { throw Error.invalidOutput }
        return TailnetPeerIdentity(
            nodeId: nodeId,
            user: user,
            machineName: rawMachineName.hasSuffix(".")
                ? String(rawMachineName.dropLast())
                : rawMachineName
        )
    }
}

/// Finds a usable Tailscale command without treating absence as admission.
private func runWhois(peerHost: String) throws -> Data {
    let candidates: [(URL, [String])] = [
        (URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale"), []),
        (URL(fileURLWithPath: "/opt/homebrew/bin/tailscale"), []),
        (URL(fileURLWithPath: "/usr/local/bin/tailscale"), []),
        (URL(fileURLWithPath: "/usr/bin/env"), ["tailscale"]),
    ]
    guard let candidate = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.0.path)
    }) else { throw TailnetWhoisResolver.Error.binaryUnavailable }
    let output = Pipe()
    let process = Process()
    process.executableURL = candidate.0
    process.arguments = candidate.1 + ["whois", "--json", peerHost]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw TailnetWhoisResolver.Error.binaryUnavailable
    }
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard process.isRunning == false else {
        process.terminate()
        process.waitUntilExit()
        throw TailnetWhoisResolver.Error.timedOut
    }
    guard process.terminationStatus == 0 else {
        throw TailnetWhoisResolver.Error.commandFailed(process.terminationStatus)
    }
    return output.fileHandleForReading.readDataToEndOfFile()
}

/// Rejects absent and empty identity fields uniformly.
private func nonempty(_ value: String?) -> String? {
    guard let value, value.isEmpty == false else { return nil }
    return value
}
