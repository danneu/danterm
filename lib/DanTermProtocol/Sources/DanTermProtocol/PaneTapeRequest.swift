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

/// Selects exact state recovery or an evidence-only view of retained recorder events. This is
/// the spelling the wire carries; the policy a stream actually runs under is
/// `PaneTapeSyncPolicy`, which a request boundary resolves this mode into.
public enum PaneTapeStreamMode: String, Equatable, Sendable {
    /// Repairs unavailable history with an exact terminal-state synchronization.
    case reconstructible
    /// Preserves recorder evidence without synthesizing terminal state.
    case raw
}

/// The synchronization policy one pane-tape stream runs under: whether the producer may
/// replace lost recorder evidence with terminal state, and how much retained history such a
/// replacement carries.
///
/// It is one value rather than a mode beside an unrelated number because a raw stream never
/// emits a synchronization, so a budget on one would bound nothing. Making that combination
/// unrepresentable keeps the rule out of every site that reads a stream's mode.
public enum PaneTapeSyncPolicy: Equatable, Sendable {
    /// Preserves recorder evidence without synthesizing terminal state.
    case raw
    /// Repairs unavailable history with a state synchronization that spends at most
    /// `historyBudgetBytes` on retained history; `nil` carries every retained row, which is
    /// what an exact consumer such as `pane.snapshot` asks for.
    case reconstructible(historyBudgetBytes: Int?)

    /// What a `pane.tape` stream bounds its syncs by when the request names no budget. A
    /// screen is worth a couple of kilobytes, so this carries a usable scrollback depth while
    /// staying two orders of magnitude below the payload a full retained history costs.
    public static let defaultHistoryBudgetBytes = 262_144

    /// The wire spelling this policy reports as its mode.
    public var mode: PaneTapeStreamMode {
        switch self {
        case .raw: return .raw
        case .reconstructible: return .reconstructible
        }
    }
}

/// Why a requested mode and history budget do not name a policy.
public enum PaneTapeSyncPolicyError: Error, Equatable {
    /// A raw stream emits no synchronization, so a history budget has nothing to bound.
    case budgetOnRawStream
    /// A budget must be a whole, non-negative byte count.
    case budgetNotWholeBytes
}

/// Resolves the mode and optional budget a request stated into the stream's one policy.
///
/// Both request boundaries -- the IPC decode and the CLI parser -- go through here, so the
/// rules about which combinations exist are stated once rather than at each door.
public func paneTapeSyncPolicy(
    mode: PaneTapeStreamMode,
    requestedHistoryBudgetBytes: Int?
) throws(PaneTapeSyncPolicyError) -> PaneTapeSyncPolicy {
    if let requestedHistoryBudgetBytes, requestedHistoryBudgetBytes < 0 {
        throw PaneTapeSyncPolicyError.budgetNotWholeBytes
    }
    switch mode {
    case .raw:
        guard requestedHistoryBudgetBytes == nil else {
            throw PaneTapeSyncPolicyError.budgetOnRawStream
        }
        return .raw
    case .reconstructible:
        return .reconstructible(
            historyBudgetBytes: requestedHistoryBudgetBytes
                ?? PaneTapeSyncPolicy.defaultHistoryBudgetBytes
        )
    }
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

/// Reads the optional history budget a tape request states, rejecting any value outside the
/// whole non-negative byte domain rather than rounding it into one.
public func decodePaneTapeSyncHistoryBytes(
    _ value: JSONValue?
) throws(PaneTapeSyncPolicyError) -> Int? {
    guard let value, value != .null else { return nil }
    guard let bytes = wholeNonnegativeInt(value) else {
        throw PaneTapeSyncPolicyError.budgetNotWholeBytes
    }
    return bytes
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
