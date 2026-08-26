// Proves the app bundle selected for a Swift terminal backend supplies the child
// environment's shell-integration directory instead of a reconstructed install path.
import Foundation
import PaneProcessLifecycle
import Testing
import xlocale
@testable import DanTerm
import TerminalPaneSession

struct SwiftTerminalBackendLaunchTests {
    @Test("Swift launch advertises readable shell assets from the selected app bundle")
    @MainActor
    func launchAdvertisesSelectedBundleShellIntegration() throws {
        // Intent: bundle-derived launch facts flow through launch assembly into the
        //   resolved child environment, naming readable per-shell assets and vendor files.
        // Why it exists: reading Bundle.main or reconstructing /Applications silently
        //   breaks development slots even though pure forwarding tests continue to pass.
        // Scenario: a synthetic DanTerm Dev slot bundle launches a pane from its own copy
        //   of Contents/Resources/shell-integration.
        let fixture = try SyntheticDanTermBundle()
        defer { fixture.remove() }
        let bundle = try #require(Bundle(url: fixture.bundleURL))
        let request = TerminalPaneLaunchRequest(
            workingDirectory: "/",
            command: nil,
            launchCommand: nil,
            environment: []
        )

        let facts = SwiftTerminalBackend.launchFacts(
            bundle: bundle,
            localeFallbackEnabled: true
        )
        #expect(facts.localeFallback != nil)
        let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)
        let launch = try resolveLaunchPlan(configuration.launchInput).get()
        let environment = Dictionary(uniqueKeysWithValues: launch.spec(shell: 0, workingDirectory: 0).environment.map {
            ($0.name, $0.value)
        })
        let advertised = try #require(environment["DANTERM_SHELL_INTEGRATION_DIR"])

        #expect(advertised == fixture.integrationURL.path)
        for relativePath in [
            "danterm.zsh",
            "danterm.bash",
            "danterm.fish",
            "vendor/bash-preexec.sh",
        ] {
            #expect(FileManager.default.isReadableFile(
                atPath: fixture.integrationURL.appendingPathComponent(relativePath).path
            ))
        }
    }

    @Test("a claimed grid becomes the child's spawn geometry, and no claim keeps the default")
    @MainActor
    func claimedGridBecomesSpawnGeometry() throws {
        // Intent: the grid a request names is installed on the PTY before the child
        //   starts, and a request that names none still spawns at 80x24.
        // Why it exists: a restored claimed pane's child must never observe the
        //   default grid. Only spawn geometry can prevent that -- a submitted grid
        //   after launch is already one size the child saw.
        // Scenario: spec-first -- restore builds one claimed pane and one plain one.
        let fixture = try SyntheticDanTermBundle()
        defer { fixture.remove() }
        let bundle = try #require(Bundle(url: fixture.bundleURL))
        let facts = SwiftTerminalBackend.launchFacts(
            bundle: bundle,
            localeFallbackEnabled: true
        )

        func spawnDimensions(_ dimensions: TerminalDimensions?) throws -> TerminalDimensions {
            let request = TerminalPaneLaunchRequest(
                workingDirectory: "/",
                command: nil,
                launchCommand: nil,
                environment: [],
                initialDimensions: dimensions
            )
            let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)
            let launch = try resolveLaunchPlan(configuration.launchInput).get()
            return launch.spec(shell: 0, workingDirectory: 0).initialDimensions
        }

        #expect(try spawnDimensions(TerminalDimensions(columns: 60, rows: 30))
            == TerminalDimensions(columns: 60, rows: 30))
        #expect(try spawnDimensions(nil) == TerminalDimensions(columns: 80, rows: 24))
    }

    @Test("locale selection prefers the regional candidate and falls back only when needed", arguments: [
        (accepted: ["fr_CA.UTF-8"], expected: "fr_CA.UTF-8"),
        (accepted: ["en_US.UTF-8"], expected: "en_US.UTF-8"),
        (accepted: [], expected: nil),
    ])
    @MainActor
    func localeSelectionUsesFirstAcceptedCandidate(
        accepted: [String],
        expected: String?
    ) {
        let selected = SwiftTerminalBackend.localeFallback(
            languageCode: "fr",
            regionCode: "CA",
            accepts: accepted.contains
        )

        #expect(selected == expected)
    }

    @Test("disabled locale fallback does not reach the child environment")
    @MainActor
    func disabledLocaleFallbackDoesNotReachChildEnvironment() throws {
        let fixture = try SyntheticDanTermBundle()
        defer { fixture.remove() }
        let bundle = try #require(Bundle(url: fixture.bundleURL))
        let request = TerminalPaneLaunchRequest(
            workingDirectory: "/",
            command: nil,
            launchCommand: nil,
            environment: []
        )

        let facts = SwiftTerminalBackend.launchFacts(
            bundle: bundle,
            localeFallbackEnabled: false,
            processEnvironment: [:]
        )
        #expect(facts.localeFallback == nil)
        let configuration = assembleTerminalPaneLaunch(request: request, facts: facts)
        let launch = try resolveLaunchPlan(configuration.launchInput).get()
        let environment = Dictionary(uniqueKeysWithValues: launch.spec(shell: 0, workingDirectory: 0).environment.map {
            ($0.name, $0.value)
        })

        #expect(environment["LANG"] == nil)
    }

    @Test("real locale acceptance does not mutate the process locale")
    @MainActor
    func realLocaleAcceptanceDoesNotMutateProcessLocale() throws {
        let before = String(cString: try #require(setlocale(LC_CTYPE, nil)))

        #expect(SwiftTerminalBackend.acceptsLocale("en_US.UTF-8"))

        let after = String(cString: try #require(setlocale(LC_CTYPE, nil)))
        #expect(after == before)
    }
}

private struct SyntheticDanTermBundle {
    let bundleURL: URL
    let integrationURL: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-bundle-\(UUID().uuidString)", isDirectory: true)
        bundleURL = root.appendingPathComponent("DanTerm Dev (7).app", isDirectory: true)
        integrationURL = bundleURL
            .appendingPathComponent("Contents/Resources/shell-integration", isDirectory: true)
        try FileManager.default.createDirectory(
            at: integrationURL.appendingPathComponent("vendor", isDirectory: true),
            withIntermediateDirectories: true
        )
        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.danneu.danterm-dev.7</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>7.8.9</string>
        </dict></plist>
        """
        try Data(info.utf8).write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        for relativePath in [
            "danterm.zsh",
            "danterm.bash",
            "danterm.fish",
            "vendor/bash-preexec.sh",
        ] {
            try Data("fixture\n".utf8).write(
                to: integrationURL.appendingPathComponent(relativePath)
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent())
    }
}
