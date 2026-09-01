// swift-tools-version: 6.2
import PackageDescription

// The Mac-host entry points of the terminal engine: a debug AppKit glyph viewer and
// a memory probe that shells out to `/usr/bin/vmmap`. They live here, not in
// `TerminalCore`, because a `platforms:` pin is a claim about every target in a
// package -- so one AppKit window or one `Process` in `TerminalCore` would make its
// iOS pin false. Only a target that genuinely cannot build for iOS belongs here;
// anything portable stays in `TerminalCore` and is covered by that package's pin.
let package = Package(
    name: "TerminalHostTools",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "GlyphPreview", targets: ["GlyphPreview"]),
        .executable(name: "TerminalMemoryProbe", targets: ["TerminalMemoryProbe"]),
    ],
    dependencies: [
        .package(path: "../TerminalCore"),
    ],
    targets: [
        .executableTarget(
            name: "GlyphPreview",
            dependencies: [
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
                .product(name: "TerminalSpriteGeometry", package: "TerminalCore"),
            ],
            path: "Sources/GlyphPreview",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GlyphPreviewTests",
            dependencies: [
                "GlyphPreview",
                .product(name: "TerminalSpriteGeometry", package: "TerminalCore"),
            ],
            path: "Tests/GlyphPreviewTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalMemoryProbe",
            dependencies: [
                .product(name: "TerminalMemoryProbeSupport", package: "TerminalCore"),
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalProbeArguments", package: "TerminalCore"),
            ],
            path: "Sources/TerminalMemoryProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
