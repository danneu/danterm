// Behavioral coverage for the canonical release and development bundle declarations.
import Testing
@testable import DanTermProtocol

struct BundleLayoutTests {
    @Test("release layout keeps plist identity and executable destination together")
    func releaseLayoutKeepsIdentityAndExecutableDestinationTogether() throws {
        let layout = BundleLayout.release

        #expect(layout.variant == .release)
        #expect(layout.identity == BundleLayout.Identity(
            bundleIdentifier: "com.danneu.danterm",
            name: "DanTerm",
            displayName: "DanTerm",
            executableName: "DanTerm",
            iconName: "AppIcon"
        ))
        let appExecutable = try #require(layout.entry(.appExecutable))
        #expect(appExecutable.relativePath == "Contents/MacOS/\(layout.identity.executableName)")
        #expect(appExecutable.mode == 0o755)
        #expect(appExecutable.source == .product("DanTerm"))
        #expect(Set(layout.entries.map(\.id)).count == layout.entries.count)
        #expect(Set(layout.entries.map(\.relativePath)).count == layout.entries.count)
        #expect(layout.exactSetDirectories == [
            "Contents/MacOS",
            "Contents/Helpers",
            "Contents/Resources/danterm-hooks",
        ])
    }

    @Test("development layout changes identity, icon, executable, and build-only helper")
    func developmentLayoutChangesOnlyVariantSpecificEntries() {
        let layout = BundleLayout.development

        #expect(layout.variant == .development)
        #expect(layout.identity == BundleLayout.Identity(
            bundleIdentifier: "com.danneu.danterm-dev",
            name: "DanTerm Dev",
            displayName: "DanTerm Dev",
            executableName: "DanTerm Dev",
            iconName: "AppIcon-dev"
        ))
        #expect(layout.entry(.appExecutable)?.relativePath == "Contents/MacOS/DanTerm Dev")
        #expect(layout.entry(.iconAssets)?.source == .repositoryFile("icon/AppIcon-dev/Assets.car"))
        #expect(layout.entry(.instanceIdentityTool) == .init(
            id: .instanceIdentityTool,
            relativePath: "Contents/Helpers/danterm-instance-identity",
            mode: 0o755,
            source: .product("DanTermInstanceIdentityTool")
        ))
        #expect(layout.entries.count == BundleLayout.release.entries.count + 1)
    }
}
