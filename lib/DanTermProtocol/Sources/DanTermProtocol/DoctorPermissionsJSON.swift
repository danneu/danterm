// JSON representation of app-owned permission facts sent to `danterm doctor`.

extension DoctorFacts.Permissions {
    /// Keeps the internal doctor IPC payload typed at both endpoints.
    public var jsonValue: JSONValue {
        .object([
            "notifications": .string(notifications.rawValue),
            "fullDiskAccess": .string(fullDiskAccess.rawValue),
            "developerTools": .string(developerTools.rawValue),
        ])
    }

    /// Rejects missing or future fields instead of converting an incomplete reply into denials.
    public init?(jsonValue: JSONValue) {
        guard case .object(let object) = jsonValue,
              case .string(let notifications)? = object["notifications"],
              case .string(let fullDiskAccess)? = object["fullDiskAccess"],
              case .string(let developerTools)? = object["developerTools"],
              let notificationState = DoctorFacts.PermissionState(rawValue: notifications),
              let fullDiskAccessState = DoctorFacts.PermissionState(rawValue: fullDiskAccess),
              let developerToolsState = DoctorFacts.PermissionState(rawValue: developerTools)
        else { return nil }

        self.init(
            notifications: notificationState,
            fullDiskAccess: fullDiskAccessState,
            developerTools: developerToolsState
        )
    }
}
