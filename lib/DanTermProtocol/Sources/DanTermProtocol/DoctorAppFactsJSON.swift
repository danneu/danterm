// JSON representation of the app-owned facts sent to `danterm doctor`: the macOS
// permission results, and the config file this instance was launched against.

extension DoctorFacts.AppFacts {
    /// Keeps the internal doctor IPC payload typed at both endpoints.
    public var jsonValue: JSONValue {
        .object([
            "permissions": permissions.jsonValue,
            "configFilePath": .string(configFilePath),
        ])
    }

    /// Rejects a partial reply instead of reporting on a file no instance named.
    public init?(jsonValue: JSONValue) {
        guard case .object(let object) = jsonValue,
              let permissionsValue = object["permissions"],
              let permissions = DoctorFacts.Permissions(jsonValue: permissionsValue),
              case .string(let configFilePath)? = object["configFilePath"]
        else { return nil }

        self.init(permissions: permissions, configFilePath: configFilePath)
    }
}

extension DoctorFacts.Permissions {
    /// Keeps the permission half of the app-facts payload typed at both endpoints.
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
