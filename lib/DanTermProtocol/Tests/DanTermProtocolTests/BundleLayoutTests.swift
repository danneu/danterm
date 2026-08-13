// Behavioral coverage for every declared app bundle variant.
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

    @Test(
        "benchmark layout preserves every accepted stable bundle suffix",
        arguments: ["", ".a", ".b", ".bystander", ".isolation"]
    )
    func benchmarkLayoutPreservesStableIdentity(bundleSuffix: String) throws {
        let layout = BundleLayout.benchmark(bundleSuffix: bundleSuffix)

        #expect(layout.variant == .benchmark)
        #expect(layout.identity == BundleLayout.Identity(
            bundleIdentifier: "com.danneu.danterm-terminal-benchmark\(bundleSuffix)",
            name: "DanTerm Benchmark",
            displayName: "DanTerm Benchmark",
            executableName: "DanTerm Benchmark",
            iconName: nil
        ))
        #expect(try #require(layout.entry(.appExecutable)).relativePath ==
            "Contents/MacOS/DanTerm Benchmark")
        #expect(layout.entry(.iconAssets) == nil)
        #expect(layout.entry(.commandSkill) == nil)
        #expect(layout.entry(.shellIntegration) == nil)
    }

    @Test("viability layout preserves its isolated identity and reduced entry set")
    func viabilityLayoutPreservesIdentity() throws {
        let layout = BundleLayout.viability

        #expect(layout.variant == .viability)
        #expect(layout.identity == BundleLayout.Identity(
            bundleIdentifier: "com.danneu.danterm-terminal-viability",
            name: "DanTerm Terminal Viability",
            displayName: "DanTerm Terminal Viability",
            executableName: "DanTerm Terminal Viability",
            iconName: nil
        ))
        #expect(try #require(layout.entry(.appExecutable)).relativePath ==
            "Contents/MacOS/DanTerm Terminal Viability")
        let expectedIDs: Set<BundleLayout.EntryID> = [
            .appExecutable,
            .commandLineExecutable,
            .ptySessionBootstrap,
            .infoPlist,
            .themeCatalog,
            .symbolsFont,
            .symbolsLicense,
        ]
        #expect(Set(layout.entries.map(\.id)) == expectedIDs)
    }
}
