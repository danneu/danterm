// Phantom-typed identifiers shared by IPC producers and the application model.
import Foundation

/// Wraps UUID identity so the compiler rejects mixing different entity kinds.
public struct TypedId<Tag>: Hashable, RawRepresentable, Codable, Sendable {
    public let rawValue: UUID

    /// Restores a typed identity from its UUID representation.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Distinguishes tab identifiers from every other UUID-backed identity.
public enum TabTag {}

/// Distinguishes pane identifiers from every other UUID-backed identity.
public enum PaneTag {}

/// Distinguishes group identifiers from every other UUID-backed identity.
public enum GroupTag {}

/// Identifies one tab across the IPC and model boundary.
public typealias TabId = TypedId<TabTag>

/// Identifies one pane across the IPC and model boundary.
public typealias PaneId = TypedId<PaneTag>

/// Identifies one group across the IPC and model boundary.
public typealias GroupId = TypedId<GroupTag>
