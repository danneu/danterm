// Emits BundleLayout as stable JSON for bundle assembly and verification scripts.
import DanTermProtocol
import Foundation

/// Defines the versioned JSON boundary consumed by repository build scripts.
private struct LayoutPayload: Encodable {
    let schemaVersion: Int
    let variant: String
    let identity: IdentityPayload
    let exactSetDirectories: [String]
    let entries: [EntryPayload]

    init(layout: BundleLayout) {
        schemaVersion = 1
        variant = layout.variant.rawValue
        identity = IdentityPayload(identity: layout.identity)
        exactSetDirectories = layout.exactSetDirectories
        entries = layout.entries.map(EntryPayload.init)
    }
}

/// Preserves the indivisible plist identity in the emitted plan.
private struct IdentityPayload: Encodable {
    let bundleIdentifier: String
    let name: String
    let displayName: String
    let executableName: String
    let iconName: String?

    init(identity: BundleLayout.Identity) {
        bundleIdentifier = identity.bundleIdentifier
        name = identity.name
        displayName = identity.displayName
        executableName = identity.executableName
        iconName = identity.iconName
    }
}

/// Couples one emitted destination to its semantic role, mode, and source.
private struct EntryPayload: Encodable {
    let id: String
    let path: String
    let mode: Int
    let source: SourcePayload

    init(entry: BundleLayout.Entry) {
        id = entry.id.rawValue
        path = entry.relativePath
        mode = entry.mode
        source = SourcePayload(source: entry.source)
    }
}

/// Gives each source case a stable tag and value that non-Swift consumers can read.
private struct SourcePayload: Encodable {
    let kind: String
    let value: String

    init(source: BundleLayout.Source) {
        switch source {
        case let .product(value):
            kind = "product"
            self.value = value
        case let .repositoryFile(value):
            kind = "repositoryFile"
            self.value = value
        case let .repositoryTree(value):
            kind = "repositoryTree"
            self.value = value
        case let .propertyListTemplate(value):
            kind = "propertyListTemplate"
            self.value = value
        case let .generatedThemeCatalog(value):
            kind = "generatedThemeCatalog"
            self.value = value
        }
    }
}

guard (2...3).contains(CommandLine.arguments.count),
      let variant = BundleLayout.Variant(rawValue: CommandLine.arguments[1]),
      variant == .benchmark || CommandLine.arguments.count == 2
else {
    fputs("usage: DanTermBundleLayoutTool <release|development|viability> | benchmark [bundle-suffix]\n", stderr)
    exit(2)
}

let layout: BundleLayout = switch variant {
case .release: .release
case .development: .development
case .benchmark: .benchmark(bundleSuffix: CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "")
case .viability: .viability
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(LayoutPayload(layout: layout)))
FileHandle.standardOutput.write(Data("\n".utf8))
