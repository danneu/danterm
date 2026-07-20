// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DanTerm",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DanTerm", targets: ["DanTerm"]),
        .executable(name: "DanTermCLI", targets: ["DanTermCLI"]),
        .library(name: "DanTermProtocol", targets: ["DanTermProtocol"]),
    ],
    dependencies: [
        .package(path: "lib/TerminalCore"),
        .package(path: "lib/TerminalPTY"),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "lib/GhosttyKit.xcframework"
        ),
        .target(
            name: "DanTermProtocol",
            path: "lib/DanTermProtocol/Sources/DanTermProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "DanTerm",
            dependencies: [
                "GhosttyKit",
                "DanTermProtocol",
                .product(name: "PaneLifecycle", package: "TerminalPTY"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalPaneSession", package: "TerminalPTY"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
                .product(name: "TerminalRenderExecution", package: "TerminalCore"),
            ],
            path: "app",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "DanTermCLI",
            dependencies: ["DanTermProtocol"],
            path: "cli",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "DanTermProtocolTests",
            dependencies: ["DanTermProtocol"],
            path: "lib/DanTermProtocol/Tests/DanTermProtocolTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
