// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DanTerm",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DanTerm", targets: ["DanTerm"]),
        .executable(name: "DanTermCLI", targets: ["DanTermCLI"]),
        .executable(name: "DanTermBundleLayoutTool", targets: ["DanTermBundleLayoutTool"]),
        .executable(name: "DanTermInstanceIdentityTool", targets: ["DanTermInstanceIdentityTool"]),
        .library(name: "DanTermClient", targets: ["DanTermClient"]),
    ],
    dependencies: [
        .package(path: "lib/DanTermProtocol"),
        .package(path: "lib/TerminalCore"),
        .package(path: "lib/TerminalPTY"),
    ],
    targets: [
        .target(
            name: "DanTermClient",
            dependencies: [.product(name: "DanTermProtocol", package: "DanTermProtocol")],
            path: "lib/DanTermClient/Sources/DanTermClient",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "DanTermSupport",
            dependencies: [.product(name: "DanTermProtocol", package: "DanTermProtocol")],
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
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
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
            dependencies: [
                "DanTermClient",
                "DanTermSupport",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "cli",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "DanTermBundleLayoutTool",
            dependencies: [.product(name: "DanTermProtocol", package: "DanTermProtocol")],
            path: "tools/DanTermBundleLayoutTool",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "DanTermInstanceIdentityTool",
            dependencies: [.product(name: "DanTermProtocol", package: "DanTermProtocol")],
            path: "tools/DanTermInstanceIdentityTool",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DanTermClientTests",
            dependencies: [
                "DanTermClient",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
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
            dependencies: [
                "DanTermClient",
                "DanTermSupport",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "client-tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DanTermAppTests",
            dependencies: [
                "DanTerm",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
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
            dependencies: [
                "DanTermCLI",
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
            ],
            path: "cli-tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
