// JSON representation of the app-owned facts sent to `danterm doctor`: the macOS
// permission results, config file, and instance-resolved config-font verdict.

extension DoctorFacts.AppFacts {
    /// Keeps the internal doctor IPC payload typed at both endpoints.
    public var jsonValue: JSONValue {
        .object([
            "permissions": permissions.jsonValue,
            "configFilePath": .string(configFilePath),
            "configFont": configFont.jsonValue,
        ])
    }

    /// Rejects a partial reply instead of reporting on a file no instance named.
    public init?(jsonValue: JSONValue) {
        guard case .object(let object) = jsonValue,
              let permissionsValue = object["permissions"],
              let permissions = DoctorFacts.Permissions(jsonValue: permissionsValue),
              case .string(let configFilePath)? = object["configFilePath"],
              let configFontValue = object["configFont"],
              let configFont = DoctorFacts.ConfigFont(jsonValue: configFontValue)
        else { return nil }

        self.init(
            permissions: permissions,
            configFilePath: configFilePath,
            configFont: configFont
        )
    }
}

extension DoctorFacts.ConfigFont {
    /// Preserves the config-font ladder across the internal doctor IPC boundary.
    public var jsonValue: JSONValue {
        switch self {
        case .unset:
            .object(["status": .string("unset")])
        case .unreadableConfig:
            .object(["status": .string("unreadableConfig")])
        case .installed:
            .object(["status": .string("installed")])
        case .notInstalled(let requested):
            .object([
                "status": .string("notInstalled"),
                "requested": .string(requested),
            ])
        }
    }

    /// Rejects incomplete or unknown verdicts instead of inventing an app-owned fact.
    public init?(jsonValue: JSONValue) {
        guard case .object(let object) = jsonValue,
              case .string(let status)? = object["status"]
        else { return nil }
        switch status {
        case "unset": self = .unset
        case "unreadableConfig": self = .unreadableConfig
        case "installed": self = .installed
        case "notInstalled":
            guard case .string(let requested)? = object["requested"] else { return nil }
            self = .notInstalled(requested: requested)
        default: return nil
        }
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
