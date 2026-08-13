// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DanTerm",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DanTerm", targets: ["DanTerm"]),
        .executable(name: "DanTermCLI", targets: ["DanTermCLI"]),
        .executable(name: "DanTermInstanceIdentityTool", targets: ["DanTermInstanceIdentityTool"]),
        .library(name: "DanTermProtocol", targets: ["DanTermProtocol"]),
        .library(name: "DanTermClient", targets: ["DanTermClient"]),
    ],
    dependencies: [
        .package(path: "lib/TerminalCore"),
        .package(path: "lib/TerminalPTY"),
    ],
    targets: [
        .target(
            name: "DanTermProtocol",
            path: "lib/DanTermProtocol/Sources/DanTermProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DanTermClient",
            dependencies: ["DanTermProtocol"],
            path: "lib/DanTermClient/Sources/DanTermClient",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DanTermSupport",
            dependencies: ["DanTermProtocol"],
            path: "lib/DanTermSupport/Sources/DanTermSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("CoreText"),
            ]
        ),
        .executableTarget(
            name: "DanTerm",
            dependencies: [
                "DanTermProtocol",
                .product(name: "PaneProcessLifecycle", package: "TerminalPTY"),
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalPaneSession", package: "TerminalPTY"),
                .product(name: "TerminalPTYHost", package: "TerminalPTY"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
                .product(name: "TerminalBenchmarkMarkers", package: "TerminalCore"),
                .product(name: "TerminalBenchmarkTopology", package: "TerminalCore"),
                .product(name: "TerminalBenchmarkCoverage", package: "TerminalCore"),
            ],
            path: "app",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "DanTermCLI",
            dependencies: ["DanTermClient", "DanTermProtocol", "DanTermSupport"],
            path: "cli",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "DanTermInstanceIdentityTool",
            dependencies: ["DanTermProtocol"],
            path: "tools/DanTermInstanceIdentityTool",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DanTermProtocolTests",
            dependencies: ["DanTermProtocol"],
            path: "lib/DanTermProtocol/Tests/DanTermProtocolTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DanTermClientTests",
            dependencies: ["DanTermClient", "DanTermProtocol"],
            path: "lib/DanTermClient/Tests/DanTermClientTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Pairs the pane-tape producer, which is a Mac-host role, with the client's
        // reader. Neither package can host this on its own: the producer is internal to
        // DanTermSupport, and DanTermClient must not depend on the host layer.
        .testTarget(
            name: "DanTermPaneTapeRoundTripTests",
            dependencies: ["DanTermClient", "DanTermProtocol", "DanTermSupport"],
            path: "client-tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DanTermAppTests",
            dependencies: [
                "DanTerm",
                "DanTermProtocol",
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
            ],
            path: "app-tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DanTermCLITests",
            dependencies: ["DanTermCLI", "DanTermProtocol"],
            path: "cli-tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
