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
    ],
    dependencies: [
        .package(path: "lib/ChipArtwork"),
        .package(path: "lib/DanTermClient"),
        .package(path: "lib/DanTermCore"),
        .package(path: "lib/DanTermProtocol"),
        .package(path: "lib/DanTermSupport"),
        .package(path: "lib/TerminalCore"),
        .package(path: "lib/TerminalPTY"),
    ],
    targets: [
        .executableTarget(
            name: "DanTerm",
            dependencies: [
                .product(name: "ChipArtwork", package: "ChipArtwork"),
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
                .product(name: "DanTermClient", package: "DanTermClient"),
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
                .product(name: "DanTermSupport", package: "DanTermSupport"),
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
        // Pairs the pane-tape producer with the client's reader. Neither package can host
        // this on its own: the producer is internal to DanTermCore, and DanTermClient must
        // not depend on the host layer.
        .testTarget(
            name: "DanTermPaneTapeRoundTripTests",
            dependencies: [
                .product(name: "DanTermClient", package: "DanTermClient"),
                .product(name: "DanTermCore", package: "DanTermCore"),
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
        // The AppKit UI suite. Every case drives real AppKit views, so the target
        // declares that it needs a WindowServer connection; the gate's coverage check
        // reads that declaration and requires the gate to skip this estate rather than
        // keeping a list of excluded names of its own.
        .testTarget(
            name: "DanTermUITests",
            dependencies: [
                "DanTerm",
                .product(name: "ChipArtwork", package: "ChipArtwork"),
                .product(name: "DanTermProtocol", package: "DanTermProtocol"),
                .product(name: "PaneProcessLifecycle", package: "TerminalPTY"),
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalPaneSession", package: "TerminalPTY"),
                .product(name: "TerminalPTYHost", package: "TerminalPTY"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
            ],
            path: "tests-ui",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Every case here drives AppKit views, and the runner is main-actor
                // isolated end to end. Saying so once beats annotating each helper.
                .defaultIsolation(MainActor.self),
                .define("DANTERM_REQUIRES_WINDOWSERVER"),
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
