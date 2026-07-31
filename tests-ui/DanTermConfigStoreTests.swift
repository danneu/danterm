// Filesystem integration coverage for DanTerm's atomic JSON config transaction.
import Foundation

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
}
