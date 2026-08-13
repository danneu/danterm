// Declares each app bundle variant as data shared by packaging and runtime path consumers.

/// Owns one complete app bundle shape so producers and consumers cannot invent paths independently.
public struct BundleLayout: Equatable, Sendable {
    /// Names a bundle shape whose identity and entry set differ from its siblings.
    public enum Variant: String, Equatable, Sendable {
        /// The unsigned bundle that later release stages sign and publish.
        case release

        /// The canonical local development bundle.
        case development

        /// The optimized app used for isolated terminal performance measurements.
        case benchmark

        /// The opt-in app used for end-to-end terminal behavior checks.
        case viability
    }

    /// Carries every plist identity field together with the matching executable name.
    public struct Identity: Equatable, Sendable {
        /// The identifier written to `CFBundleIdentifier`.
        public let bundleIdentifier: String

        /// The short bundle name written to `CFBundleName`.
        public let name: String

        /// The user-visible name written to `CFBundleDisplayName`.
        public let displayName: String

        /// The name shared by `CFBundleExecutable` and the file under `Contents/MacOS`.
        public let executableName: String

        /// The asset-catalog name written to `CFBundleIconName`, or nil when a variant has no icon.
        public let iconName: String?

        /// Creates one indivisible identity for plist writes and the app executable path.
        public init(
            bundleIdentifier: String,
            name: String,
            displayName: String,
            executableName: String,
            iconName: String?
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.displayName = displayName
            self.executableName = executableName
            self.iconName = iconName
        }

        /// Extends the process identity's shared names with the bundle-only icon field.
        init(instanceIdentity: DanTermInstanceIdentity, iconName: String?) {
            self.init(
                bundleIdentifier: instanceIdentity.bundleIdentifier,
                name: instanceIdentity.displayName,
                displayName: instanceIdentity.displayName,
                executableName: instanceIdentity.executableName,
                iconName: iconName
            )
        }
    }

    /// Gives each declared entry a stable role that runtime and packaging code can share.
    public enum EntryID: String, Equatable, Hashable, Sendable {
        /// The main app executable named by the bundle identity.
        case appExecutable

        /// The bundled `danterm` command-line executable.
        case commandLineExecutable

        /// The development-only slot identity helper.
        case instanceIdentityTool

        /// The process bootstrap used to establish pane PTY sessions.
        case ptySessionBootstrap

        /// The bundle property list patched with the selected identity.
        case infoPlist

        /// The compiled icon asset catalog.
        case iconAssets

        /// The skill that documents the bundled `danterm` command.
        case commandSkill

        /// The Claude Code notification hook.
        case claudeNotifyHook

        /// The Claude Code session lifecycle hook.
        case claudeSessionHook

        /// The Codex session lifecycle hook.
        case codexSessionHook

        /// The complete shell integration resource tree.
        case shellIntegration

        /// The generated runtime theme catalog.
        case themeCatalog

        /// The renderer's bundled symbols font.
        case symbolsFont

        /// The license shipped beside the symbols font.
        case symbolsLicense
    }

    /// Names the input that must produce a declared destination.
    public enum Source: Equatable, Sendable {
        /// A named executable produced by a Swift build.
        case product(String)

        /// One byte-identical file relative to the repository root.
        case repositoryFile(String)

        /// One byte-identical directory tree relative to the repository root.
        case repositoryTree(String)

        /// A repository plist template transformed with the selected bundle identity.
        case propertyListTemplate(String)

        /// A theme source tree transformed into the runtime catalog.
        case generatedThemeCatalog(String)
    }

    /// Couples one bundle-relative destination to its required permissions and source.
    public struct Entry: Equatable, Sendable {
        /// The semantic role used to find this entry without matching path text.
        public let id: EntryID

        /// The destination below the app bundle root.
        public let relativePath: String

        /// The exact POSIX permission bits the destination must have.
        public let mode: Int

        /// The product, repository content, or deterministic transform that supplies the bytes.
        public let source: Source

        /// Declares one destination without relying on a producer's copy logic.
        public init(id: EntryID, relativePath: String, mode: Int, source: Source) {
            self.id = id
            self.relativePath = relativePath
            self.mode = mode
            self.source = source
        }
    }

    /// Owns fixed bundle-relative paths used by both entry declarations and runtime consumers.
    public enum Paths {
        /// The bundled command-line executable installed into the user's PATH.
        public static let commandLineExecutable = "Contents/Helpers/danterm"

        /// The development-only helper that resolves slot identities.
        public static let instanceIdentityTool = "Contents/Helpers/danterm-instance-identity"

        /// The helper that establishes each pane's PTY session before exec.
        public static let ptySessionBootstrap = "Contents/Helpers/PTYSessionBootstrap"

        /// The app bundle property list patched from the selected identity.
        public static let infoPlist = "Contents/Info.plist"

        /// The compiled asset catalog selected by the bundle variant.
        public static let iconAssets = "Contents/Resources/Assets.car"

        /// The command skill distributed for agents that drive DanTerm.
        public static let commandSkill = "Contents/Resources/danterm/SKILL.md"

        /// The last path component used to recognize bundled agent hook commands.
        public static let agentHooksDirectoryName = "danterm-hooks"

        /// The directory that owns every bundled agent hook script.
        public static let agentHooksDirectory = "Contents/Resources/\(agentHooksDirectoryName)"

        /// The shell integration tree advertised to every pane.
        public static let shellIntegrationDirectory = "Contents/Resources/shell-integration"

        /// The generated theme catalog loaded by the app.
        public static let themeCatalog = "Contents/Resources/themes/catalog.json"

        /// The bundled font resource directory used by the renderer.
        public static let symbolsDirectory = "Contents/Resources/NerdFontsSymbolsOnly"
    }

    /// The declared producer shape.
    public let variant: Variant

    /// The indivisible identity used for the plist and main executable path.
    public let identity: Identity

    /// The complete ordered entry set for this variant.
    public let entries: [Entry]

    /// Directories whose immediate children must match the declared entry set exactly.
    public let exactSetDirectories: [String]

    /// Creates a variant from its complete identity and declared entry set.
    public init(
        variant: Variant,
        identity: Identity,
        entries: [Entry],
        exactSetDirectories: [String]
    ) {
        self.variant = variant
        self.identity = identity
        self.entries = entries
        self.exactSetDirectories = exactSetDirectories
    }

    /// Finds a destination by semantic role so callers do not search by path text.
    public func entry(_ id: EntryID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Declares the unsigned production bundle assembled by the release producer.
    public static let release = makeShippingLayout(
        variant: .release,
        identity: Identity(instanceIdentity: .production, iconName: "AppIcon"),
        iconSource: "icon/AppIcon/Assets.car",
        includesIdentityTool: false
    )

    /// Declares the signed canonical development bundle assembled by the local producer.
    public static let development = makeShippingLayout(
        variant: .development,
        identity: Identity(instanceIdentity: .development, iconName: "AppIcon-dev"),
        iconSource: "icon/AppIcon-dev/Assets.car",
        includesIdentityTool: true
    )

    /// Declares a benchmark bundle while preserving the harness's stable A/B suffix.
    public static func benchmark(bundleSuffix: String) -> BundleLayout {
        makeHarnessLayout(
            variant: .benchmark,
            identity: Identity(
                bundleIdentifier: "com.danneu.danterm-terminal-benchmark\(bundleSuffix)",
                name: "DanTerm Benchmark",
                displayName: "DanTerm Benchmark",
                executableName: "DanTerm Benchmark",
                iconName: nil
            )
        )
    }

    /// Declares the isolated bundle used by the opt-in terminal viability harness.
    public static let viability = makeHarnessLayout(
        variant: .viability,
        identity: Identity(
            bundleIdentifier: "com.danneu.danterm-terminal-viability",
            name: "DanTerm Terminal Viability",
            displayName: "DanTerm Terminal Viability",
            executableName: "DanTerm Terminal Viability",
            iconName: nil
        )
    )

    private static func makeShippingLayout(
        variant: Variant,
        identity: Identity,
        iconSource: String,
        includesIdentityTool: Bool
    ) -> BundleLayout {
        var entries = [
            Entry(
                id: .appExecutable,
                relativePath: "Contents/MacOS/\(identity.executableName)",
                mode: 0o755,
                source: .product("DanTerm")
            ),
            Entry(
                id: .commandLineExecutable,
                relativePath: Paths.commandLineExecutable,
                mode: 0o755,
                source: .product("DanTermCLI")
            ),
            Entry(
                id: .ptySessionBootstrap,
                relativePath: Paths.ptySessionBootstrap,
                mode: 0o755,
                source: .product("PTYSessionBootstrap")
            ),
            Entry(
                id: .infoPlist,
                relativePath: Paths.infoPlist,
                mode: 0o644,
                source: .propertyListTemplate("app/Info.plist")
            ),
            Entry(id: .iconAssets, relativePath: Paths.iconAssets, mode: 0o644, source: .repositoryFile(iconSource)),
            Entry(id: .commandSkill, relativePath: Paths.commandSkill, mode: 0o644, source: .repositoryFile("integrations/danterm/SKILL.md")),
            Entry(
                id: .claudeNotifyHook,
                relativePath: "\(Paths.agentHooksDirectory)/danterm-claude-notify-osc777",
                mode: 0o755,
                source: .repositoryFile("integrations/claude-code/claude-notify-osc777.sh")
            ),
            Entry(
                id: .claudeSessionHook,
                relativePath: "\(Paths.agentHooksDirectory)/danterm-claude-agent-session",
                mode: 0o755,
                source: .repositoryFile("integrations/claude-code/danterm-agent-session.sh")
            ),
            Entry(
                id: .codexSessionHook,
                relativePath: "\(Paths.agentHooksDirectory)/danterm-codex-agent-session",
                mode: 0o755,
                source: .repositoryFile("integrations/codex/danterm-agent-session.sh")
            ),
            Entry(
                id: .shellIntegration,
                relativePath: Paths.shellIntegrationDirectory,
                mode: 0o755,
                source: .repositoryTree("integrations/shell-integration")
            ),
            Entry(
                id: .themeCatalog,
                relativePath: Paths.themeCatalog,
                mode: 0o644,
                source: .generatedThemeCatalog("themes")
            ),
            Entry(
                id: .symbolsFont,
                relativePath: "\(Paths.symbolsDirectory)/SymbolsNerdFontMono-Regular.ttf",
                mode: 0o644,
                source: .repositoryFile("lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf")
            ),
            Entry(
                id: .symbolsLicense,
                relativePath: "\(Paths.symbolsDirectory)/LICENSE",
                mode: 0o644,
                source: .repositoryFile("lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/LICENSE")
            ),
        ]
        if includesIdentityTool {
            entries.append(Entry(
                id: .instanceIdentityTool,
                relativePath: Paths.instanceIdentityTool,
                mode: 0o755,
                source: .product("DanTermInstanceIdentityTool")
            ))
        }
        return BundleLayout(
            variant: variant,
            identity: identity,
            entries: entries,
            exactSetDirectories: [
                "Contents/MacOS",
                "Contents/Helpers",
                Paths.agentHooksDirectory,
            ]
        )
    }

    private static func makeHarnessLayout(
        variant: Variant,
        identity: Identity
    ) -> BundleLayout {
        BundleLayout(
            variant: variant,
            identity: identity,
            entries: [
                Entry(
                    id: .appExecutable,
                    relativePath: "Contents/MacOS/\(identity.executableName)",
                    mode: 0o755,
                    source: .product("DanTerm")
                ),
                Entry(
                    id: .commandLineExecutable,
                    relativePath: Paths.commandLineExecutable,
                    mode: 0o755,
                    source: .product("DanTermCLI")
                ),
                Entry(
                    id: .ptySessionBootstrap,
                    relativePath: Paths.ptySessionBootstrap,
                    mode: 0o755,
                    source: .product("PTYSessionBootstrap")
                ),
                Entry(
                    id: .infoPlist,
                    relativePath: Paths.infoPlist,
                    mode: 0o644,
                    source: .propertyListTemplate("app/Info.plist")
                ),
                Entry(
                    id: .themeCatalog,
                    relativePath: Paths.themeCatalog,
                    mode: 0o644,
                    source: .generatedThemeCatalog("themes")
                ),
                Entry(
                    id: .symbolsFont,
                    relativePath: "\(Paths.symbolsDirectory)/SymbolsNerdFontMono-Regular.ttf",
                    mode: 0o644,
                    source: .repositoryFile("lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf")
                ),
                Entry(
                    id: .symbolsLicense,
                    relativePath: "\(Paths.symbolsDirectory)/LICENSE",
                    mode: 0o644,
                    source: .repositoryFile("lib/TerminalCore/Sources/TerminalRenderExecution/Resources/NerdFontsSymbolsOnly/LICENSE")
                ),
            ],
            exactSetDirectories: [
                "Contents/MacOS",
                "Contents/Helpers",
            ]
        )
    }
}
