// Stable process identities and bundle-declared capabilities shared by app and tooling.
import Foundation

/// Names one DanTerm process so every identity-derived resource follows the same fixed scheme.
public struct DanTermInstanceIdentity: Equatable, Sendable {
    /// Slot zero is the user's canonical development app; launchers may claim slots 1 through 8.
    public static let developmentSlotRange = 0...8

    /// The bundle identifier that namespaces OS registration and process-owned state.
    public let bundleIdentifier: String

    /// The fixed development slot, or nil for production and purpose-built harness bundles.
    public var developmentSlot: Int? {
        if bundleIdentifier == Self.developmentBundleIdentifier {
            return 0
        }
        let prefix = Self.developmentBundleIdentifier + "."
        let suffix = bundleIdentifier.dropFirst(prefix.count)
        guard bundleIdentifier.hasPrefix(prefix),
              let slot = Int(suffix),
              String(slot) == suffix,
              Self.developmentSlotRange.contains(slot),
              slot != 0
        else { return nil }
        return slot
    }

    /// The user-visible application name for a fixed development slot.
    public var displayName: String {
        guard let developmentSlot, developmentSlot != 0 else {
            return bundleIdentifier == Self.developmentBundleIdentifier ? "DanTerm Dev" : "DanTerm"
        }
        return "DanTerm Dev (\(developmentSlot))"
    }

    /// The executable name mirrors the display name so process-targeted tooling can distinguish slots.
    public var executableName: String { displayName }

    /// Preserves arbitrary bundle identifiers used by production and isolated test harnesses.
    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    /// Resolves the current process identity at the common bundle boundary.
    public init(bundle: Bundle = .main) {
        self.init(bundleIdentifier: bundle.bundleIdentifier ?? Self.productionBundleIdentifier)
    }

    /// Constructs one identity from the bounded development pool.
    public init?(developmentSlot: Int) {
        guard Self.developmentSlotRange.contains(developmentSlot) else { return nil }
        bundleIdentifier = developmentSlot == 0
            ? Self.developmentBundleIdentifier
            : "\(Self.developmentBundleIdentifier).\(developmentSlot)"
    }

    private static let productionBundleIdentifier = "com.danneu.danterm"
    private static let developmentBundleIdentifier = "com.danneu.danterm-dev"
}

/// Reads opt-in runtime features from bundle metadata so cloned identities retain capabilities.
public enum DanTermBundleCapabilities {
    /// Info.plist key whose true value enables the Swift terminal's pane flight tape.
    public static let recordsFlightTapeKey = "DanTermRecordsFlightTape"

    /// Treats true as opted in and false, missing, or ill-typed values as opted out.
    public static func recordsFlightTape(infoDictionary: [String: Any]?) -> Bool {
        infoDictionary?[recordsFlightTapeKey] as? Bool == true
    }
}
