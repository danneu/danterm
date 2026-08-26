// App-side filesystem boundary for DanTerm's versioned JSON configuration:
// launch/reload reads, seeding, and atomic save transactions. These need the
// shared config contract, so they stay in the app; the store never resolves which
// file it means -- launch names it and hands it down.
import Foundation
import DanTermProtocol

/// Distinguishes invalid documents from filesystem failures for user-visible reports.
enum DanTermConfigStoreError: LocalizedError {
    case invalidDocument(URL)
    case readFailed(URL, String)
    case writeFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument(let url):
            "DanTerm could not use \(url.path). The file must be valid JSON with schemaVersion 1. Defaults remain active, and Settings changes cannot be saved until the file is fixed."
        case .readFailed(let url, let message):
            "DanTerm could not read \(url.path): \(message). Defaults remain active."
        case .writeFailed(let url, let message):
            "DanTerm could not save \(url.path): \(message). The running settings remain active, but the file was not changed."
        }
    }
}

/// Resolves the config's requested `font.family` to a canonical installed family,
/// or nil when it names nothing installed (or was never set) and the system
/// monospace font applies.
///
/// Lives in the app because it is the composition of two layers that never see
/// each other: the core's config type and DanTermSupport's CoreText probe. Every
/// config-apply path routes through this one function so a requested name can
/// only ever reach the model as a verified verdict.
func resolveConfiguredFontFamily(_ config: DanTermConfig) -> String? {
    config.fontFamily.flatMap(resolveInstalledFontFamily(named:))
}

/// Performs each Preferences save as one fresh, atomic read-modify-write transaction.
///
/// `url` has no default, for the same reason `AppRuntime` takes its store: which file
/// the process owns is decided once at launch. A store that was not told which file it
/// means does not exist, so no caller can fall back to the user's config by omission.
struct DanTermConfigStore {
    let url: URL
    private let fileManager: FileManager
    private let readData: (URL) throws -> Data
    private let writeData: (Data, URL) throws -> Void

    init(
        url: URL,
        fileManager: FileManager = .default,
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
        // Umask default, deliberately: `~/.config/danterm/config.json` is a file the user
        // opens, edits, and diffs, and it carries no terminal content. It is one of the three
        // artifacts the private-write seam does not govern.
        writeData: @escaping (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        self.url = url
        self.fileManager = fileManager
        self.readData = readData
        self.writeData = writeData
    }

    /// Loads defaults for an absent file and refuses malformed or unsupported documents.
    func load() throws -> DanTermConfig {
        guard fileManager.fileExists(atPath: url.path) else { return .default }
        let data: Data
        do {
            data = try readData(url)
        } catch {
            throw DanTermConfigStoreError.readFailed(url, error.localizedDescription)
        }
        guard let document = DanTermConfigDocument.decode(data) else {
            throw DanTermConfigStoreError.invalidDocument(url)
        }
        var config = document.config
        switch document.projectKeybindings(knownActionIDs: knownKeybindingActionIDs) {
        case .absent:
            break
        case .replacement(let overrides):
            config.keybindingOverrides = overrides
        case .rejected:
            throw DanTermConfigStoreError.invalidDocument(url)
        }
        return config
    }

    /// Creates a missing file as a valid writable v1 document without touching an existing file.
    func seedIfMissing() throws {
        let transactionURL = resolvedTransactionURL()
        guard fileManager.fileExists(atPath: transactionURL.path) == false else { return }
        try write(DanTermConfigDocument.seedData, to: transactionURL)
    }

    /// Re-reads the latest file, mutates every modeled setting, and writes at most once.
    func save(_ config: DanTermConfig) throws {
        let transactionURL = resolvedTransactionURL()
        let original: Data
        if fileManager.fileExists(atPath: transactionURL.path) {
            do {
                original = try readData(transactionURL)
            } catch {
                throw DanTermConfigStoreError.readFailed(url, error.localizedDescription)
            }
        } else {
            original = DanTermConfigDocument.seedData
        }
        guard var document = DanTermConfigDocument.decode(original) else {
            throw DanTermConfigStoreError.invalidDocument(url)
        }
        document.apply(config)
        document.applyKeybindings(
            config.keybindingOverrides,
            knownActionIDs: knownKeybindingActionIDs
        )
        let encoded = document.encoded()
        guard encoded != original
            || fileManager.fileExists(atPath: transactionURL.path) == false
        else { return }
        try write(encoded, to: transactionURL)
    }

    private var knownKeybindingActionIDs: Set<KeybindingActionID> {
        Set(commandCatalog.map(\.id))
    }

    private func resolvedTransactionURL() -> URL {
        let parentURL = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path)
        else { return url.resolvingSymlinksInPath() }
        return URL(fileURLWithPath: destination, relativeTo: parentURL)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func write(_ data: Data, to transactionURL: URL) throws {
        do {
            // Umask default, deliberately, for the reason the config file itself is: the
            // user browses `~/.config/danterm`, and an owner-only directory there would be a
            // surprise no privacy gain pays for.
            try fileManager.createDirectory(
                at: transactionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeData(data, transactionURL)
        } catch {
            throw DanTermConfigStoreError.writeFailed(url, error.localizedDescription)
        }
    }
}
