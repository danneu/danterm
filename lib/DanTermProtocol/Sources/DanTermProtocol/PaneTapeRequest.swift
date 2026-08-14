// Shared pane-tape request values. The app, CLI, and client all use this one cursor and
// start-position vocabulary so a resume cannot be transcribed differently at each boundary.
import Foundation

/// Identifies one resumable position in the lifetime of one pane recorder.
public struct PaneTapeCursor: Equatable, Sendable {
    /// Distinguishes recorder coordinates that happen to have the same numeric offsets.
    public let recorderLifetimeId: UUID
    /// Names the first event the client has not received.
    public let nextSequence: UInt64
    /// Counts feed bytes before `nextSequence`.
    public let feedBytesBeforeNextSequence: Int
    /// Counts write bytes before `nextSequence`.
    public let writeBytesBeforeNextSequence: Int

    /// Keeps all recorder coordinates together when a cursor crosses the protocol boundary.
    public init(
        recorderLifetimeId: UUID,
        nextSequence: UInt64,
        feedBytesBeforeNextSequence: Int,
        writeBytesBeforeNextSequence: Int
    ) {
        self.recorderLifetimeId = recorderLifetimeId
        self.nextSequence = nextSequence
        self.feedBytesBeforeNextSequence = feedBytesBeforeNextSequence
        self.writeBytesBeforeNextSequence = writeBytesBeforeNextSequence
    }
}

/// Selects exact state recovery or an evidence-only view of retained recorder events.
public enum PaneTapeStreamMode: String, Equatable, Sendable {
    /// Repairs unavailable history with an exact terminal-state synchronization.
    case reconstructible
    /// Preserves recorder evidence without synthesizing terminal state.
    case raw
}

/// Names the position a tape request asks the producer to continue from.
public enum PaneTapeStartPosition: Equatable, Sendable {
    /// Starts at the recorder's zero origin, reporting any evicted prefix.
    case beginning
    /// Starts at an atomic fence of current pane state.
    case now
    /// Continues after the last state or event a client applied.
    case cursor(PaneTapeCursor)
}

/// Encodes a cursor in the shape published by start and synchronization records.
public func paneTapeCursorJSON(_ cursor: PaneTapeCursor) -> JSONValue {
    .object([
        "recorderLifetimeId": .string(cursor.recorderLifetimeId.uuidString),
        "sequence": .number(Double(cursor.nextSequence)),
        "feedByteOffset": .number(Double(cursor.feedBytesBeforeNextSequence)),
        "writeByteOffset": .number(Double(cursor.writeBytesBeforeNextSequence)),
    ])
}

/// Validates an untrusted cursor before the app can offer it to a recorder.
public func decodePaneTapeCursor(_ value: JSONValue?) -> PaneTapeCursor? {
    guard let object = value?.asObject,
          case .string(let rawLifetime)? = object["recorderLifetimeId"],
          let lifetime = UUID(uuidString: rawLifetime),
          let sequence = wholeUInt64(object["sequence"]),
          let feed = wholeNonnegativeInt(object["feedByteOffset"]),
          let write = wholeNonnegativeInt(object["writeByteOffset"])
    else { return nil }
    return PaneTapeCursor(
        recorderLifetimeId: lifetime,
        nextSequence: sequence,
        feedBytesBeforeNextSequence: feed,
        writeBytesBeforeNextSequence: write
    )
}

private func wholeUInt64(_ value: JSONValue?) -> UInt64? {
    guard case .number(let number)? = value,
          number.isFinite,
          number.rounded(.towardZero) == number,
          number >= 0,
          number < 18_446_744_073_709_551_616.0
    else { return nil }
    return UInt64(number)
}

private func wholeNonnegativeInt(_ value: JSONValue?) -> Int? {
    guard case .number(let number)? = value,
          number.isFinite,
          number.rounded(.towardZero) == number,
          number >= 0,
          number < 9_223_372_036_854_775_808.0
    else { return nil }
    return Int(number)
}
