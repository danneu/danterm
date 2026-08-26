// swift-tools-version: 6.2
import PackageDescription

// The smallest real embedding of DanTerm's terminal engine: one window, one
// pane, no model layer. It exists to prove the engine packages are usable from
// outside the DanTerm app module, and to make every gap in that story fail as a
// compile error rather than an opinion.
let package = Package(
    name: "MiniTerm",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MiniTerm", targets: ["MiniTerm"]),
    ],
    dependencies: [
        .package(path: "../../lib/TerminalCore"),
        .package(path: "../../lib/TerminalPTY"),
    ],
    targets: [
        .executableTarget(
            name: "MiniTerm",
            dependencies: [
                .product(name: "PaneProcessLifecycle", package: "TerminalPTY"),
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalPaneSession", package: "TerminalPTY"),
                .product(name: "TerminalPTYHost", package: "TerminalPTY"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
            ],
            path: "Sources/MiniTerm",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("Cocoa")]
        ),
    ]
)
