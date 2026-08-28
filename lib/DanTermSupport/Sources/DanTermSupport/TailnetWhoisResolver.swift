// Tailscale peer identity resolution through tailscaled's local Unix socket.
// The whole query stays injectable, and every transport or response failure
// remains distinct for diagnostics while admission fails closed.
import Darwin
import Foundation
import PrivateFile

/// Holds the stable Tailscale identity minted once for an accepted peer.
struct TailnetPeerIdentity: Equatable, Sendable {
    let nodeId: String
    let user: String
    let machineName: String
}

/// Resolves a captured peer address through an injectable Tailscale whois query.
struct TailnetWhoisResolver: Sendable {
    /// Classifies LocalAPI failures without exposing them as admission decisions.
    enum Error: Swift.Error, Equatable, Sendable {
        case socketPathTooLong
        case connectionFailed(Int32)
        case timedOut
        case invalidResponse
        case httpStatus(Int)
        case invalidOutput
    }

    private let query: @Sendable (String) throws -> TailnetPeerIdentity

    /// Injects the whole query so admission tests need no live tailscaled daemon.
    init(_ query: @escaping @Sendable (String) throws -> TailnetPeerIdentity) {
        self.query = query
    }

    /// Connects a resolver to a LocalAPI socket with bounded IO waits.
    init(socketPath: URL, timeout: TimeInterval = 3) {
        self.init { peerAddress in
            try Self.queryLocalAPI(
                peerAddress: peerAddress,
                socketPath: socketPath,
                timeout: timeout
            )
        }
    }

    /// Uses the open-source tailscaled LocalAPI available on this Mac.
    static let live = TailnetWhoisResolver(
        socketPath: URL(fileURLWithPath: "/var/run/tailscaled.socket")
    )

    /// Resolves only the address captured at accept time.
    func resolve(peerAddress: String) throws -> TailnetPeerIdentity {
        try query(peerAddress)
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

    private static func queryLocalAPI(
        peerAddress: String,
        socketPath: URL,
        timeout: TimeInterval
    ) throws -> TailnetPeerIdentity {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw connectionError() }
        defer { Darwin.close(fileDescriptor) }

        try configure(fileDescriptor: fileDescriptor, timeout: timeout)
        var address: sockaddr_un
        do {
            address = try PrivateFile.unixSocketAddress(for: socketPath)
        } catch {
            throw Error.socketPathTooLong
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else { throw connectionError() }

        let encodedAddress = peerAddress.addingPercentEncoding(
            withAllowedCharacters: .init(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-")
        ) ?? peerAddress
        let request = Data((
            "GET /localapi/v0/whois?addr=\(encodedAddress) HTTP/1.1\r\n" +
            "Host: local-tailscaled.sock\r\n" +
            "Connection: close\r\n\r\n"
        ).utf8)
        try write(request, to: fileDescriptor)
        let response = try readResponse(from: fileDescriptor)
        guard response.status == 200 else { throw Error.httpStatus(response.status) }
        return try parse(response.body)
    }

    private static func configure(fileDescriptor: Int32, timeout: TimeInterval) throws {
        let seconds = floor(max(0, timeout))
        var timeValue = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((max(0, timeout) - seconds) * 1_000_000)
        )
        if timeValue.tv_sec == 0 && timeValue.tv_usec == 0 {
            timeValue.tv_usec = 1
        }
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                option,
                &timeValue,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else { throw connectionError() }
        }
        var noSignal: Int32 = 1
        guard setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw connectionError() }
    }

    private static func write(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    fileDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw Error.timedOut }
                    throw connectionError()
                }
                guard count > 0 else { throw Error.invalidResponse }
                offset += count
            }
        }
    }

    private static func readResponse(from fileDescriptor: Int32) throws -> HTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        var received = Data()
        var parsedHeaders: (status: Int, bodyOffset: Int, contentLength: Int?)?
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.count <= 1_048_576 {
            if let parsedHeaders,
               let contentLength = parsedHeaders.contentLength,
               received.count >= parsedHeaders.bodyOffset + contentLength {
                return HTTPResponse(
                    status: parsedHeaders.status,
                    body: received.subdata(in: parsedHeaders.bodyOffset ..< parsedHeaders.bodyOffset + contentLength)
                )
            }
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Error.timedOut }
                throw connectionError()
            }
            if count == 0 {
                guard let parsedHeaders else { throw Error.invalidResponse }
                return HTTPResponse(
                    status: parsedHeaders.status,
                    body: received.subdata(in: parsedHeaders.bodyOffset ..< received.count)
                )
            }
            received.append(contentsOf: buffer.prefix(count))
            if parsedHeaders == nil, let headerRange = received.range(of: separator) {
                parsedHeaders = try parseHeaders(
                    received.subdata(in: received.startIndex ..< headerRange.lowerBound),
                    bodyOffset: headerRange.upperBound
                )
            }
        }
        throw Error.invalidResponse
    }

    private static func parseHeaders(
        _ data: Data,
        bodyOffset: Int
    ) throws -> (status: Int, bodyOffset: Int, contentLength: Int?) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.invalidResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/1."),
              let status = Int(statusParts[1])
        else { throw Error.invalidResponse }
        var contentLength: Int?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                guard let length = Int(parts[1].trimmingCharacters(in: .whitespaces)), length >= 0 else {
                    throw Error.invalidResponse
                }
                contentLength = length
            }
        }
        return (status, bodyOffset, contentLength)
    }

    private static func connectionError() -> Error {
        Error.connectionFailed(errno)
    }

    private struct HTTPResponse {
        let status: Int
        let body: Data
    }
}

/// Rejects absent and empty identity fields uniformly.
private func nonempty(_ value: String?) -> String? {
    guard let value, value.isEmpty == false else { return nil }
    return value
}
