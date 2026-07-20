// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalPTY",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PaneLifecycle", targets: ["PaneLifecycle"]),
        .library(name: "TerminalPTYHost", targets: ["TerminalPTYHost"]),
        .library(name: "TerminalPaneSession", targets: ["TerminalPaneSession"]),
        .executable(name: "PTYSessionBootstrap", targets: ["PTYSessionBootstrap"]),
    ],
    dependencies: [
        .package(path: "../TerminalCore"),
    ],
    targets: [
        .target(
            name: "PaneLifecycle",
            path: "Sources/PaneLifecycle",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalPTYHost",
            dependencies: [
                "PaneLifecycle",
                .product(name: "TerminalCore", package: "TerminalCore"),
            ],
            path: "Sources/TerminalPTYHost",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalPaneSession",
            dependencies: [
                "PaneLifecycle",
                "TerminalPTYHost",
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
            ],
            path: "Sources/TerminalPaneSession",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PTYSessionBootstrap",
            path: "Sources/PTYSessionBootstrap"
        ),
        .executableTarget(
            name: "PTYProbe",
            path: "Sources/PTYProbe"
        ),
        .testTarget(
            name: "PaneLifecycleTests",
            dependencies: ["PaneLifecycle"],
            path: "Tests/PaneLifecycleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalPTYHostTests",
            dependencies: [
                "PaneLifecycle",
                "TerminalPTYHost",
                "PTYSessionBootstrap",
                "PTYProbe",
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
            ],
            path: "Tests/TerminalPTYHostTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalPaneSessionTests",
            dependencies: [
                "PaneLifecycle",
                "TerminalPTYHost",
                "TerminalPaneSession",
                "PTYSessionBootstrap",
                "PTYProbe",
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "TerminalRenderPlanning", package: "TerminalCore"),
            ],
            path: "Tests/TerminalPaneSessionTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
