// Filesystem integration coverage for DanTerm's atomic JSON config transaction.
import Foundation
import DanTermProtocol

@MainActor
func danTermConfigStoreTests() {
    print("DanTermConfigStore")

    uiTest("open-config seed is writable v1 and immediately accepts Preferences save") {
        let fixture = try ConfigStoreFixture()
        defer { fixture.remove() }
        let store = DanTermConfigStore(url: fixture.url)

        try store.seedIfMissing()
        try uiExpect(try store.load() == .default, "seed did not load as writable v1")

        var config = DanTermConfig.default
        config.defaultTheme = "Dracula"
        config.fontSize = 16
        try store.save(config)

        try uiExpect(try store.load() == config, "seed refused the first Preferences save")
    }

    uiTest("save re-reads external edits and preserves unknown exact numbers") {
        let fixture = try ConfigStoreFixture()
        defer { fixture.remove() }
        let source = Data(
            """
            {"schemaVersion":1,"font":{"size":13,"future":0.10000000000000001},"theme":{"future":"kept"},"ui":{"future":true},"huge":9007199254740993}
            """.utf8
        )
        try source.write(to: fixture.url)
        let store = DanTermConfigStore(url: fixture.url)
        _ = try store.load()

        var config = DanTermConfig.default
        config.defaultTheme = "Dracula"
        config.fontSize = 18
        config.alertClearMode = .manual
        try store.save(config)
        let saved = try String(contentsOf: fixture.url, encoding: .utf8)

        try uiExpect(saved.contains("9007199254740993"), "large external number was coerced")
        try uiExpect(saved.contains("0.10000000000000001"), "fraction token was reformatted")
        try uiExpect(saved.contains("\"future\": \"kept\""), "nested external edit was lost")
    }

    uiTest("invalid documents fall back at load and refuse every save") {
        for source in [
            Data("{".utf8),
            Data("{\"theme\":{}}".utf8),
            Data("{\"schemaVersion\":1.0}".utf8),
            Data("{\"schemaVersion\":2}".utf8),
        ] {
            let fixture = try ConfigStoreFixture()
            defer { fixture.remove() }
            try source.write(to: fixture.url)
            let store = DanTermConfigStore(url: fixture.url)

            do {
                _ = try store.load()
                throw UITestFailure(message: "invalid config loaded")
            } catch is DanTermConfigStoreError {}
            do {
                try store.save(.default)
                throw UITestFailure(message: "invalid config was overwritten")
            } catch is DanTermConfigStoreError {}
            try uiExpect(try Data(contentsOf: fixture.url) == source,
                         "refused save changed invalid source bytes")
        }
    }

    uiTest("failed multi-field write leaves the original file byte-identical") {
        let fixture = try ConfigStoreFixture()
        defer { fixture.remove() }
        let original = DanTermConfigDocument.seedData
        try original.write(to: fixture.url)
        let store = DanTermConfigStore(
            url: fixture.url,
            writeData: { _, _ in throw ConfigStoreFixture.WriteFailure() }
        )
        var config = DanTermConfig.default
        config.defaultTheme = "Dracula"
        config.remoteTheme = "Grape"
        config.fontSize = 18
        config.alertClearMode = .manual

        do {
            try store.save(config)
            throw UITestFailure(message: "injected write failure unexpectedly succeeded")
        } catch let error as DanTermConfigStoreError {
            try uiExpect(
                error.errorDescription?.contains(fixture.url.path) == true,
                "write failure did not identify the config file"
            )
        }

        try uiExpect(try Data(contentsOf: fixture.url) == original,
                     "failed transaction partially changed the file")
    }

    uiTest("save through a config symlink updates its target and preserves the link") {
        // Intent: a Preferences save through the home-manager config link rewrites
        //   the repo-owned target without replacing the link.
        // Why it exists: Foundation's atomic replacement otherwise consumes the
        //   symlink and disconnects DanTerm from the nix-managed config location.
        // Scenario: a nix user changes Preferences after pointing configPath at a
        //   tracked config.json in their dotfiles repo.
        let fixture = try ConfigStoreFixture()
        defer { fixture.remove() }
        let targetURL = fixture.directory.appendingPathComponent("tracked-config.json")
        try DanTermConfigDocument.seedData.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: targetURL)
        let store = DanTermConfigStore(url: fixture.url)
        var config = DanTermConfig.default
        config.defaultTheme = "Dracula"

        try store.save(config)

        try uiExpect(try store.load() == config, "saved config did not reach the symlink target")
        try uiExpect(
            try fixture.isSymbolicLink(at: fixture.url),
            "atomic save replaced the config symlink"
        )
    }

    uiTest("seeding a dangling config symlink creates its target and preserves the link") {
        // Intent: opening a config whose out-of-store link target is absent seeds
        //   the target as a writable v1 document and retains the link.
        // Why it exists: file-existence checks follow symlinks, so a dangling link
        //   looks absent even though its path must not become the write destination.
        // Scenario: configPath names a repo file that has not been created yet and
        //   the user chooses Open DanTerm Config for the first time.
        let fixture = try ConfigStoreFixture()
        defer { fixture.remove() }
        let targetURL = fixture.directory.appendingPathComponent("new-config.json")
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: targetURL)
        let store = DanTermConfigStore(url: fixture.url)

        try store.seedIfMissing()

        try uiExpect(
            try Data(contentsOf: targetURL) == DanTermConfigDocument.seedData,
            "seed did not create the dangling link target"
        )
        try uiExpect(
            try fixture.isSymbolicLink(at: fixture.url),
            "seeding replaced the dangling config symlink"
        )
    }

    uiTest("refused save through a config symlink leaves target bytes unchanged") {
        // Intent: invalid linked config documents remain byte-identical when a save
        //   is refused.
        // Why it exists: resolving the transaction address must not weaken the
        //   existing invalid-document refusal guarantee.
        // Scenario: a tracked config contains malformed JSON when Preferences tries
        //   to save through the home-manager link.
        let fixture = try ConfigStoreFixture()
        defer { fixture.remove() }
        let targetURL = fixture.directory.appendingPathComponent("invalid-config.json")
        let original = Data("{".utf8)
        try original.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: targetURL)
        let store = DanTermConfigStore(url: fixture.url)

        do {
            try store.save(.default)
            throw UITestFailure(message: "invalid linked config was overwritten")
        } catch is DanTermConfigStoreError {}

        try uiExpect(
            try Data(contentsOf: targetURL) == original,
            "refused save changed linked target bytes"
        )
    }

    uiTest("failed save through a config symlink leaves target bytes unchanged") {
        // Intent: an atomic write failure against a resolved config target leaves
        //   its original bytes intact.
        // Why it exists: moving the write from the visible link to its target must
        //   preserve the transaction's all-or-nothing behavior.
        // Scenario: the filesystem rejects a multi-field Preferences save to the
        //   repo-owned target behind configPath.
        let fixture = try ConfigStoreFixture()
        defer { fixture.remove() }
        let targetURL = fixture.directory.appendingPathComponent("tracked-config.json")
        let original = DanTermConfigDocument.seedData
        try original.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: targetURL)
        var attemptedURL: URL?
        let store = DanTermConfigStore(
            url: fixture.url,
            writeData: { _, url in
                attemptedURL = url
                throw ConfigStoreFixture.WriteFailure()
            }
        )
        var config = DanTermConfig.default
        config.defaultTheme = "Dracula"
        config.fontSize = 18

        do {
            try store.save(config)
            throw UITestFailure(message: "injected linked write failure unexpectedly succeeded")
        } catch is DanTermConfigStoreError {}

        try uiExpect(attemptedURL == targetURL, "save did not attempt the resolved target URL")
        try uiExpect(
            try Data(contentsOf: targetURL) == original,
            "failed save changed linked target bytes"
        )
    }

    uiTest("retargeting a config symlink during save cannot modify the new target") {
        // Intent: one save reads and writes one resolved file even if the visible
        //   config link changes mid-transaction.
        // Why it exists: resolving separately for read and write creates a race that
        //   can apply a document derived from one target to another target.
        // Scenario: home-manager switches configPath while Preferences is saving;
        //   the in-flight save finishes against the old repo file only.
        let fixture = try ConfigStoreFixture()
        defer { fixture.remove() }
        let originalTargetURL = fixture.directory.appendingPathComponent("original-config.json")
        let newTargetURL = fixture.directory.appendingPathComponent("new-config.json")
        try DanTermConfigDocument.seedData.write(to: originalTargetURL)
        let newTargetData = Data(
            """
            {"schemaVersion":1,"font":{"size":22}}
            """.utf8
        )
        try newTargetData.write(to: newTargetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.url,
            withDestinationURL: originalTargetURL
        )
        let store = DanTermConfigStore(
            url: fixture.url,
            readData: { url in
                let data = try Data(contentsOf: url)
                try FileManager.default.removeItem(at: fixture.url)
                try FileManager.default.createSymbolicLink(
                    at: fixture.url,
                    withDestinationURL: newTargetURL
                )
                return data
            }
        )
        var config = DanTermConfig.default
        config.defaultTheme = "Dracula"

        try store.save(config)

        try uiExpect(
            DanTermConfigDocument.decode(try Data(contentsOf: originalTargetURL))?.config == config,
            "in-flight save did not update the file it read"
        )
        try uiExpect(
            try Data(contentsOf: newTargetURL) == newTargetData,
            "in-flight save modified the symlink's new target"
        )
    }
}

private struct ConfigStoreFixture {
    struct WriteFailure: Error {}

    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-config-tests-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values.isSymbolicLink == true
    }
}
