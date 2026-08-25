// Defines the compact, integrity-checked replica checkpoint and its one-file atomic store.
// Terminal state synthesis stays in PaneReplica; this file owns only the portable envelope and IO.
import CryptoKit
import DanTermProtocol
import Foundation
import PrivateFile

/// Names each reason an untrusted checkpoint cannot become exact terminal state.
public enum PaneReplicaCheckpointError: Error, Equatable, Sendable {
    /// The file does not contain the private checkpoint envelope.
    case invalidEncoding
    /// At least one decoded field differs from the state covered by the digest.
    case integrityMismatch
    /// The app has no migration for the decoded private format.
    case unsupportedFormatVersion(Int)
    /// The checkpoint belongs to a pane other than the requested pane.
    case paneMismatch
    /// A cursor byte offset cannot name a recorder position.
    case invalidCursor
    /// The engine cannot construct the geometry stored in the checkpoint.
    case invalidGeometry(columns: Int, rows: Int)
}

/// Couples bounded terminal-state bytes to the one pane and recorder cursor they describe.
public struct PaneReplicaCheckpoint: Equatable, Sendable {
    /// Rejects private checkpoint formats from any other app version without a migration.
    ///
    /// Version 2 added pinnedness and version 3 added focus. A record that cannot state one
    /// of those facts is discarded rather than restored with a guessed value.
    public static let currentFormatVersion = 3

    /// Identifies the private on-disk format.
    public let formatVersion: Int
    /// Carries an exact terminal reset stream without per-byte JSON inflation.
    public let stateBytes: [UInt8]
    /// Gives the terminal width used to synthesize the state.
    public let columns: Int
    /// Gives the terminal height used to synthesize the state.
    public let rows: Int
    /// States whether that grid was pinned, so a resumed replica restores the whole
    /// geometry fact instead of inferring a claim from the grid it happens to hold.
    public let pinned: Bool
    /// States the pane's effective terminal focus, which is retained terminal state: a
    /// restored replica that guessed it would answer the next mode-1004 enable with focus
    /// the pane never had.
    public let focused: Bool
    /// Prevents one last-subscribed pane's state from restoring into another pane.
    public let paneId: PaneId
    /// Names the first recorder event needed after this state.
    public let cursor: PaneTapeCursor
    /// Detects a still-decodable mutation of any other envelope field.
    public let integrity: [UInt8]

    init(
        stateBytes: [UInt8],
        columns: Int,
        rows: Int,
        pinned: Bool,
        focused: Bool,
        paneId: PaneId,
        cursor: PaneTapeCursor,
        formatVersion: Int = currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.stateBytes = stateBytes
        self.columns = columns
        self.rows = rows
        self.pinned = pinned
        self.focused = focused
        self.paneId = paneId
        self.cursor = cursor
        integrity = Self.digest(
            formatVersion: formatVersion,
            stateBytes: stateBytes,
            columns: columns,
            rows: rows,
            pinned: pinned,
            focused: focused,
            paneId: paneId,
            cursor: cursor
        )
    }

    private init(envelope: Envelope) {
        formatVersion = envelope.formatVersion
        stateBytes = Array(envelope.stateBytes)
        columns = envelope.columns
        rows = envelope.rows
        pinned = envelope.pinned
        focused = envelope.focused
        paneId = PaneId(rawValue: envelope.paneId)
        cursor = PaneTapeCursor(
            recorderLifetimeId: envelope.recorderLifetimeId,
            nextSequence: envelope.nextSequence,
            feedBytesBeforeNextSequence: envelope.feedBytesBeforeNextSequence,
            writeBytesBeforeNextSequence: envelope.writeBytesBeforeNextSequence
        )
        integrity = Array(envelope.integrity)
    }

    /// Encodes state bytes as binary-plist data instead of a JSON array of numbers.
    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(Envelope(checkpoint: self))
    }

    /// Decodes and verifies the complete envelope before any terminal can consume it.
    public static func decode(_ data: Data) throws -> Self {
        let envelope: Envelope
        do {
            envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
        } catch {
            throw PaneReplicaCheckpointError.invalidEncoding
        }
        let checkpoint = Self(envelope: envelope)
        try checkpoint.verifyIntegrity()
        guard checkpoint.formatVersion == currentFormatVersion else {
            throw PaneReplicaCheckpointError.unsupportedFormatVersion(checkpoint.formatVersion)
        }
        return checkpoint
    }

    /// Validates every non-byte field before PaneReplica constructs a terminal.
    func validate(for expectedPaneId: PaneId) throws {
        try verifyIntegrity()
        guard formatVersion == Self.currentFormatVersion else {
            throw PaneReplicaCheckpointError.unsupportedFormatVersion(formatVersion)
        }
        guard paneId == expectedPaneId else {
            throw PaneReplicaCheckpointError.paneMismatch
        }
        guard cursor.feedBytesBeforeNextSequence >= 0,
              cursor.writeBytesBeforeNextSequence >= 0
        else { throw PaneReplicaCheckpointError.invalidCursor }
        guard columns >= 2, rows >= 1 else {
            throw PaneReplicaCheckpointError.invalidGeometry(columns: columns, rows: rows)
        }
    }

    private func verifyIntegrity() throws {
        let expected = Self.digest(
            formatVersion: formatVersion,
            stateBytes: stateBytes,
            columns: columns,
            rows: rows,
            pinned: pinned,
            focused: focused,
            paneId: paneId,
            cursor: cursor
        )
        guard integrity == expected else {
            throw PaneReplicaCheckpointError.integrityMismatch
        }
    }

    private static func digest(
        formatVersion: Int,
        stateBytes: [UInt8],
        columns: Int,
        rows: Int,
        pinned: Bool,
        focused: Bool,
        paneId: PaneId,
        cursor: PaneTapeCursor
    ) -> [UInt8] {
        var input = Data("DanTerm mobile replica checkpoint".utf8)
        appendInteger(Int64(formatVersion), to: &input)
        appendInteger(UInt64(stateBytes.count), to: &input)
        input.append(contentsOf: stateBytes)
        appendInteger(Int64(columns), to: &input)
        appendInteger(Int64(rows), to: &input)
        appendInteger(Int64(pinned ? 1 : 0), to: &input)
        appendInteger(Int64(focused ? 1 : 0), to: &input)
        appendUUID(paneId.rawValue, to: &input)
        appendUUID(cursor.recorderLifetimeId, to: &input)
        appendInteger(cursor.nextSequence, to: &input)
        appendInteger(Int64(cursor.feedBytesBeforeNextSequence), to: &input)
        appendInteger(Int64(cursor.writeBytesBeforeNextSequence), to: &input)
        return Array(SHA256.hash(data: input))
    }
}

/// Owns one atomically replaced checkpoint for the last-subscribed pane.
public struct PaneReplicaCheckpointStore: Sendable {
    /// Exposes the sole file to same-module fault-injection tests.
    let fileURL: URL
    private let atomicWrite: @Sendable (Data, URL) throws -> Void

    /// Places the single checkpoint at a stable name inside an injected directory.
    public init(directory: URL) {
        self.init(directory: directory) { data, url in
            try PrivateFile.writeAtomically(data, to: url)
        }
    }

    init(
        directory: URL,
        atomicWrite: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        fileURL = directory.appendingPathComponent("pane-replica-checkpoint.plist")
        self.atomicWrite = atomicWrite
    }

    /// Encodes and atomically replaces the sole checkpoint file.
    public func save(_ checkpoint: PaneReplicaCheckpoint) throws {
        try PrivateFile.createDirectory(at: fileURL.deletingLastPathComponent())
        try atomicWrite(checkpoint.encoded(), fileURL)
    }

    /// Returns one usable checkpoint, deleting any corrupt or foreign-pane record.
    public func load(for paneId: PaneId) -> PaneReplicaCheckpoint? {
        do {
            let checkpoint = try PaneReplicaCheckpoint.decode(Data(contentsOf: fileURL))
            try checkpoint.validate(for: paneId)
            return checkpoint
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }
}

/// Keeps property-list encoding separate from the checkpoint's protocol-facing value types.
private struct Envelope: Codable {
    let formatVersion: Int
    let stateBytes: Data
    let columns: Int
    let rows: Int
    let pinned: Bool
    let focused: Bool
    let paneId: UUID
    let recorderLifetimeId: UUID
    let nextSequence: UInt64
    let feedBytesBeforeNextSequence: Int
    let writeBytesBeforeNextSequence: Int
    let integrity: Data

    init(checkpoint: PaneReplicaCheckpoint) {
        formatVersion = checkpoint.formatVersion
        stateBytes = Data(checkpoint.stateBytes)
        columns = checkpoint.columns
        rows = checkpoint.rows
        pinned = checkpoint.pinned
        focused = checkpoint.focused
        paneId = checkpoint.paneId.rawValue
        recorderLifetimeId = checkpoint.cursor.recorderLifetimeId
        nextSequence = checkpoint.cursor.nextSequence
        feedBytesBeforeNextSequence = checkpoint.cursor.feedBytesBeforeNextSequence
        writeBytesBeforeNextSequence = checkpoint.cursor.writeBytesBeforeNextSequence
        integrity = Data(checkpoint.integrity)
    }
}

/// Adds one fixed-width integer to the digest input without text-encoding ambiguity.
private func appendInteger<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

/// Adds one UUID's 16 raw bytes to the digest input.
private func appendUUID(_ value: UUID, to data: inout Data) {
    var bytes = value.uuid
    withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
}
