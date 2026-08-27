// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalPTY",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PaneProcessLifecycle", targets: ["PaneProcessLifecycle"]),
        .library(name: "TerminalPTYHost", targets: ["TerminalPTYHost"]),
        .library(name: "TerminalPaneSession", targets: ["TerminalPaneSession"]),
        .executable(name: "PTYSessionBootstrap", targets: ["PTYSessionBootstrap"]),
        .executable(name: "TerminalWorkflowRunner", targets: ["TerminalWorkflowRunner"]),
        .executable(name: "TerminalProtocolProbeRunner", targets: ["TerminalProtocolProbeRunner"]),
    ],
    dependencies: [
        .package(path: "../TerminalCore"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
    ],
    targets: [
        .target(
            name: "PTYSessionBootstrapABI",
            path: "Sources/PTYSessionBootstrapABI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PaneProcessLifecycle",
            path: "Sources/PaneProcessLifecycle",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalPTYHost",
            dependencies: [
                "PaneProcessLifecycle",
                "PTYSessionBootstrapABI",
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
                .product(name: "DequeModule", package: "swift-collections"),
            ],
            path: "Sources/TerminalPTYHost",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalPaneSession",
            dependencies: [
                "PaneProcessLifecycle",
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
            dependencies: ["PTYSessionBootstrapABI"],
            path: "Sources/PTYSessionBootstrap"
        ),
        .testTarget(
            name: "TerminalWorkflowSupportTests",
            dependencies: ["TerminalWorkflowSupport"],
            path: "Tests/TerminalWorkflowSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalWorkflowSupport",
            path: "TestSupport/TerminalWorkflowSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalProtocolProbeSupportTests",
            dependencies: ["TerminalProtocolProbeSupport"],
            path: "Tests/TerminalProtocolProbeSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalProtocolProbeSupport",
            path: "TestSupport/TerminalProtocolProbeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalPTYWaitSupport",
            dependencies: ["TerminalPaneSession"],
            path: "TestSupport/TerminalPTYWaitSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TerminalPTYTestSupport",
            dependencies: [
                "PaneProcessLifecycle",
                "TerminalPTYHost",
                "TerminalPTYWaitSupport",
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
            ],
            path: "TestSupport/TerminalPTYTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PTYProbe",
            path: "Sources/PTYProbe"
        ),
        .executableTarget(
            name: "TerminalWorkflowRunner",
            dependencies: [
                "TerminalPaneSession",
                "TerminalPTYWaitSupport",
                "TerminalWorkflowSupport",
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
            ],
            path: "TestSupport/TerminalWorkflowRunner",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TerminalProtocolProbeRunner",
            dependencies: [
                "TerminalPaneSession",
                "TerminalPTYWaitSupport",
                "TerminalProtocolProbeSupport",
                .product(name: "TerminalCore", package: "TerminalCore"),
                .product(name: "TerminalCoreRecording", package: "TerminalCore"),
            ],
            path: "TestSupport/TerminalProtocolProbeRunner",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PaneProcessLifecycleTests",
            dependencies: ["PaneProcessLifecycle"],
            path: "Tests/PaneProcessLifecycleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TerminalPTYHostTests",
            dependencies: [
                "PaneProcessLifecycle",
                "TerminalPTYHost",
                "TerminalPTYTestSupport",
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
                "PaneProcessLifecycle",
                "TerminalPTYHost",
                "TerminalPTYTestSupport",
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
