// Stable process identities shared by app and tooling.
import Foundation

/// Names one DanTerm process so every identity-derived resource follows the same fixed scheme.
public struct DanTermInstanceIdentity: Equatable, Sendable {
    /// Slot zero is the user's canonical development app; launchers may claim slots 1 through 8.
    public static let developmentSlotRange = 0...8

    /// The canonical production identity used by shipping bundle declarations.
    public static let production = DanTermInstanceIdentity(bundleIdentifier: productionBundleIdentifier)

    /// The canonical slot-zero development identity used by local bundle declarations.
    public static let development = DanTermInstanceIdentity(bundleIdentifier: developmentBundleIdentifier)

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

    /// True only for a slot the launcher pool hands out, 1 through 8.
    ///
    /// This is the allowlist behind the `quit` IPC method: an agent may end an
    /// instance it claimed from the pool, and nothing else. Production, the
    /// canonical `DanTerm Dev.app` (slot 0), and every identifier outside the
    /// scheme fall outside it without anyone naming them.
    public var isLauncherPoolSlot: Bool {
        guard let developmentSlot else { return false }
        return developmentSlot != 0
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
