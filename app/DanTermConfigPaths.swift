// App-side filesystem boundary for DanTerm's versioned JSON configuration:
// path resolution, launch/reload reads, seeding, and atomic save transactions.
import Foundation

/// App-level resolver for DanTerm's config file location.
enum DanTermConfigPaths {
    /// Standard config file path: ~/.config/danterm/config.json
    static func configFilePath() -> String {
        "\(NSHomeDirectory())/.config/danterm/config.json"
    }
}

/// Distinguishes invalid documents from filesystem failures for user-visible reports.
enum DanTermConfigStoreError: LocalizedError {
    case invalidDocument(URL)
    case readFailed(URL, String)
    case writeFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument(let url):
            "DanTerm could not use \(url.path). The file must be valid JSON with schemaVersion 1. Defaults remain active, and Preferences saves are disabled until the file is fixed."
        case .readFailed(let url, let message):
            "DanTerm could not read \(url.path): \(message). Defaults remain active."
        case .writeFailed(let url, let message):
            "DanTerm could not save \(url.path): \(message). The running settings remain active, but the file was not changed."
        }
    }
}

/// Performs each Preferences save as one fresh, atomic read-modify-write transaction.
struct DanTermConfigStore {
    let url: URL
    private let fileManager: FileManager
    private let readData: (URL) throws -> Data
    private let writeData: (Data, URL) throws -> Void

    init(
        url: URL = URL(fileURLWithPath: DanTermConfigPaths.configFilePath()),
        fileManager: FileManager = .default,
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
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
        return document.config
    }

    /// Creates a missing file as a valid writable v1 document without touching an existing file.
    func seedIfMissing() throws {
        guard fileManager.fileExists(atPath: url.path) == false else { return }
        try write(DanTermConfigDocument.seedData)
    }

    /// Re-reads the latest file, mutates every modeled setting, and writes at most once.
    func save(_ config: DanTermConfig) throws {
        let original: Data
        if fileManager.fileExists(atPath: url.path) {
            do {
                original = try readData(url)
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
        let encoded = document.encoded()
        guard encoded != original || fileManager.fileExists(atPath: url.path) == false else { return }
        try write(encoded)
    }

    private func write(_ data: Data) throws {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeData(data, url)
        } catch {
            throw DanTermConfigStoreError.writeFailed(url, error.localizedDescription)
        }
    }
}
