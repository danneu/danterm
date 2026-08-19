// Durable JSONL audit storage for IPC connection and request events. The writer
// serializes append, rotation, permissions, and fsync behind one synchronous API.
import DanTermProtocol
import Darwin
import Foundation
import Synchronization

/// Uses a stable JSON vocabulary for every connection and request lifecycle record.
struct IpcAuditEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case listenerBound
        case listenerFailed
        case connectionOpened
        case connectionRefused
        case connectionClosed
        case requestStarted
        case requestCompleted
        case localRequest
        case requestDecodeFailed
        case requestDropped
    }

    let kind: Kind
    let transport: String?
    let peerAddress: String?
    let caller: IpcAuditCaller?
    let request: IpcAuditRequestDescriptor?
    let rawMethod: String?
    let outcome: String?
    /// How many requests a closing connection was served. Absent on every other kind.
    let servedRequests: Int?
    /// The `address:port` a listener took. Absent on every kind but `listenerBound`.
    let endpoint: String?
    let reason: String?

    /// Records the address a listener took, so the log says which instance owns which port.
    static func listenerBound(endpoint: String) -> IpcAuditEvent {
        IpcAuditEvent(kind: .listenerBound, endpoint: endpoint)
    }

    /// Records a listener failure without pretending that a connection existed.
    static func listenerFailed(reason: String) -> IpcAuditEvent {
        IpcAuditEvent(kind: .listenerFailed, reason: reason)
    }

    /// Records the admitted identity before remote service begins.
    static func connectionOpened(
        transport: String,
        peerAddress: String,
        caller: IpcCallerIdentity
    ) -> IpcAuditEvent {
        IpcAuditEvent(
            kind: .connectionOpened,
            transport: transport,
            peerAddress: peerAddress,
            caller: IpcAuditCaller(caller)
        )
    }

    /// Records why an accepted peer did not reach service.
    static func connectionRefused(
        transport: String,
        peerAddress: String,
        reason: String
    ) -> IpcAuditEvent {
        IpcAuditEvent(
            kind: .connectionRefused,
            transport: transport,
            peerAddress: peerAddress,
            reason: reason
        )
    }

    /// Records the final lifecycle edge for a serviced connection, why it ended, and how
    /// many requests it was served.
    ///
    /// The count includes heartbeats, which earn no record of their own, so a connection
    /// that was admitted and then never read stays distinguishable from one that talked.
    static func connectionClosed(
        transport: String,
        peerAddress: String,
        caller: IpcCallerIdentity,
        reason: IpcConnectionCloseReason,
        servedRequests: Int
    ) -> IpcAuditEvent {
        IpcAuditEvent(
            kind: .connectionClosed,
            transport: transport,
            peerAddress: peerAddress,
            caller: IpcAuditCaller(caller),
            servedRequests: servedRequests,
            reason: reason.rawValue
        )
    }

    /// Records a write-ahead remote request before dispatch can run its effect.
    static func requestStarted(
        caller: IpcCallerIdentity,
        request: IpcAuditRequestDescriptor
    ) -> IpcAuditEvent {
        IpcAuditEvent(kind: .requestStarted, caller: IpcAuditCaller(caller), request: request)
    }

    /// Records the known outcome after a remote request effect finishes.
    static func requestCompleted(
        caller: IpcCallerIdentity,
        request: IpcAuditRequestDescriptor,
        outcome: String
    ) -> IpcAuditEvent {
        IpcAuditEvent(
            kind: .requestCompleted,
            caller: IpcAuditCaller(caller),
            request: request,
            outcome: outcome
        )
    }

    /// Records a best-effort local request and its outcome as one event.
    static func localRequest(
        request: IpcAuditRequestDescriptor,
        outcome: String
    ) -> IpcAuditEvent {
        IpcAuditEvent(
            kind: .localRequest,
            caller: IpcAuditCaller(.local),
            request: request,
            outcome: outcome
        )
    }

    /// Records a request line that named a method but failed typed decoding.
    static func requestDecodeFailed(
        caller: IpcCallerIdentity,
        rawMethod: String,
        outcome: String
    ) -> IpcAuditEvent {
        IpcAuditEvent(
            kind: .requestDecodeFailed,
            caller: IpcAuditCaller(caller),
            rawMethod: rawMethod,
            outcome: outcome
        )
    }

    /// Records an id-less request line that dispatch deliberately drops.
    static func requestDropped(
        caller: IpcCallerIdentity,
        rawMethod: String
    ) -> IpcAuditEvent {
        IpcAuditEvent(
            kind: .requestDropped,
            caller: IpcAuditCaller(caller),
            rawMethod: rawMethod,
            outcome: "dropped"
        )
    }

    private init(
        kind: Kind,
        transport: String? = nil,
        peerAddress: String? = nil,
        caller: IpcAuditCaller? = nil,
        request: IpcAuditRequestDescriptor? = nil,
        rawMethod: String? = nil,
        outcome: String? = nil,
        servedRequests: Int? = nil,
        endpoint: String? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.transport = transport
        self.peerAddress = peerAddress
        self.caller = caller
        self.request = request
        self.rawMethod = rawMethod
        self.outcome = outcome
        self.servedRequests = servedRequests
        self.endpoint = endpoint
        self.reason = reason
    }
}

/// Flattens caller identity into readable JSON fields without changing the wire identity type.
struct IpcAuditCaller: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable { case local, remote }

    let kind: Kind
    let nodeId: String?
    let user: String?
    let machineName: String?

    init(_ caller: IpcCallerIdentity) {
        switch caller {
        case .local:
            self.init(kind: .local)
        case .remote(let nodeId, let user, let machineName):
            self.init(kind: .remote, nodeId: nodeId, user: user, machineName: machineName)
        }
    }

    private init(
        kind: Kind,
        nodeId: String? = nil,
        user: String? = nil,
        machineName: String? = nil
    ) {
        self.kind = kind
        self.nodeId = nodeId
        self.user = user
        self.machineName = machineName
    }
}

/// Wraps each event with the writer's injected wall-clock time.
struct IpcAuditLogEntry: Codable, Equatable, Sendable {
    let timestamp: Date
    let event: IpcAuditEvent
}

/// Appends private, durable JSON lines and retains at most one rotated predecessor.
final class IpcAuditLogWriter: Sendable {
    /// Refuses records that cannot fit without violating the configured size bound.
    enum Error: Swift.Error, Equatable, Sendable {
        case entryTooLarge
    }

    let logURL: URL
    let rotatedLogURL: URL
    private let now: @Sendable () -> Date
    private let maximumBytes: Int
    private let lock = Mutex<Void>(())

    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        maximumBytes: Int = 4 * 1024 * 1024
    ) {
        self.logURL = directory.appendingPathComponent("ipc-audit.jsonl")
        self.rotatedLogURL = directory.appendingPathComponent("ipc-audit.jsonl.1")
        self.now = now
        self.maximumBytes = max(1, maximumBytes)
    }

    /// Creates and fsyncs the private sink so listener startup can fail closed.
    func prepare() throws {
        try lock.withLock { _ in
            try prepareDirectory()
            let fileDescriptor = try openLogFile()
            defer { Darwin.close(fileDescriptor) }
            guard fsync(fileDescriptor) == 0 else { throw auditPOSIXError() }
        }
    }

    /// Appends and fsyncs one complete line, rotating before it would cross the bound.
    func append(_ event: IpcAuditEvent) throws {
        let entry = IpcAuditLogEntry(timestamp: now(), event: event)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        guard line.count <= maximumBytes else { throw Error.entryTooLarge }
        try lock.withLock { _ in
            let fileManager = FileManager.default
            try prepareDirectory()
            let existingBytes = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size]
                as? NSNumber)?.intValue ?? 0
            if existingBytes > 0, existingBytes + line.count > maximumBytes {
                try? fileManager.removeItem(at: rotatedLogURL)
                try fileManager.moveItem(at: logURL, to: rotatedLogURL)
            }
            let fileDescriptor = try openLogFile()
            defer { Darwin.close(fileDescriptor) }
            try line.withUnsafeBytes { bytes in
                var remaining = bytes.count
                var cursor = bytes.baseAddress!
                while remaining > 0 {
                    let written = Darwin.write(fileDescriptor, cursor, remaining)
                    guard written > 0 else { throw auditPOSIXError() }
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                }
            }
            guard fsync(fileDescriptor) == 0 else { throw auditPOSIXError() }
        }
    }

    private func prepareDirectory() throws {
        let directory = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, 0o700) == 0 else { throw auditPOSIXError() }
    }

    private func openLogFile() throws -> Int32 {
        let fileDescriptor = Darwin.open(
            logURL.path,
            O_WRONLY | O_CREAT | O_APPEND,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else { throw auditPOSIXError() }
        guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(fileDescriptor)
            throw auditPOSIXError()
        }
        return fileDescriptor
    }
}

/// Captures errno before close or cleanup can overwrite it.
private func auditPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
